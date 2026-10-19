--- 职责：Battle Process的帧同步路由、Worker分片与跨进程FramePush发送。
--- 边界：Skynet Service Adapter；不打开fd，不解Proto bytes，不持有Native State。
--- 输入/输出：Proxy信任的route record -> Worker控制调用/输入转发/定向Gateway消息。
--- ownership：本Service独占next_id和Worker handles；控制call允许yield。
--- 不负责：连接身份的最终授权（Worker通过Session绑定验证）、Navigation和玩法。
local skynet  = require "skynet"
local cluster = require "skynet.cluster"
local frame_sync_config    = require "config.frame_sync"
local ids     = require("gateway.protocol.protocol_registry_lesson_03_frame_sync").command_ids

local module_state =
{
    worker_handles = {}, -- 本 Dispatch 独占的固定 Worker Service handle 池。 -- 固定数量的长期Service handles。
    next_battle_id = 0, -- 本 Battle 进程内单调分配且不重用的 Battle ID。 -- 本Battle OS进程内单调BattleID；不重用。
    shutdown_coordinator_handle = nil, -- 被授权执行关闭和 drain 的本地 Service。 -- 唯一允许关闭Dispatch/Worker池的本地Service。
    is_draining = false, -- drain 屏障开始后拒绝新的客户端业务请求。 -- drain屏障后拒绝新的客户端业务消息。
    control_requests_in_flight = 0, -- 正在等待 Worker 控制调用返回的请求数。 -- 正在等待Worker控制调用完成的请求数。
    diagnostics =
    {
        input_batches_received     = 0, -- 从 Gateway 收到的输入批次数，不是单条输入数。
        control_requests_received  = 0, -- 收到的入场、恢复、离开、回放等非输入请求数。
        control_errors             = 0, -- control 调用失败并转成 INTERNAL 的次数。
        disconnects_received       = 0, -- 收到的 Gateway 断线事件数。
        frame_pushes_received      = 0, -- 从 Worker 收到并准备回推的帧推送数。
        gateway_messages_attempted = 0, -- 尝试发送给 Gateway 的响应或推送数。
        gateway_send_errors        = 0, -- 同步 cluster.send 调用抛出的错误数。
    }
}

--- id路由是battle_id%worker_count+1；不同Battle不会因join落到另一Worker。
local function worker_for(battle_id)
    if math.type(battle_id) ~= "integer" or battle_id < 1 or battle_id > 0x7fffffff then
        return nil
    end
    return module_state.worker_handles[battle_id % #module_state.worker_handles + 1]
end

--- 请求/回推只带跨进程纯值record；不传fd、buffer借用或Lua userdata。
local function reply(route, response)
    module_state.diagnostics.gateway_messages_attempted =
        module_state.diagnostics.gateway_messages_attempted + 1
    local ok, err = pcall(cluster.send, frame_sync_config.gateway_node, "@frame_proxy", "send_data",
    {
        gateway_epoch = route.gateway_epoch,
        connection_id = route.connection_id,
        command_id    = route.command_id,
        data          = response,
    })
    if not ok then
        module_state.diagnostics.gateway_send_errors = module_state.diagnostics.gateway_send_errors + 1
        skynet.error("FRAME_REPLY_FAILED ", tostring(err))
    end
end

local function control(route)
    local request = route.data
    local worker_command =
    {
        battle_id = request.battle_id,
        request = request,
        session = { gateway_epoch = route.gateway_epoch,
                    connection_id = route.connection_id },
    }
    if route.command_id == ids.FRAME_JOIN then
        if request.scenario_id ~= 1001 then return { code = "BAD_SCENARIO" } end
        if request.battle_id == 0 then
            if module_state.next_battle_id >= 0x7fffffff then return { code = "ID_EXHAUSTED" } end
            module_state.next_battle_id = module_state.next_battle_id + 1
            worker_command.battle_id = module_state.next_battle_id
            return skynet.call(worker_for(module_state.next_battle_id), "lua", "create", worker_command)
        end
        return skynet.call(worker_for(request.battle_id), "lua", "join", worker_command)
    end
    local worker_handle = worker_for(request.battle_id)
    if not worker_handle then return { code = "NOT_FOUND" } end
    if route.command_id == ids.FRAME_RECOVER then
        return { state = skynet.call(worker_handle, "lua", "recover", worker_command) }
    elseif route.command_id == ids.FRAME_LEAVE then
        return skynet.call(worker_handle, "lua", "leave", worker_command)
    elseif route.command_id == ids.FRAME_REPLAY then
        return skynet.call(worker_handle, "lua", "replay", worker_command)
    end
    return { code = "BAD_COMMAND" }
end

local function incoming(route)
    assert(type(route) == "table" and type(route.data) == "table")
    assert(type(route.gateway_epoch) == "string" and route.connection_id > 0, "invalid gateway route")
    if module_state.is_draining then
        return
    end
    if route.command_id == ids.FRAME_INPUT then
        module_state.diagnostics.input_batches_received = module_state.diagnostics.input_batches_received + 1
        local worker_handle = worker_for(route.data.battle_id)
        if worker_handle then
            skynet.send(worker_handle, "lua", "inputs",
            {
                battle_id = route.data.battle_id,
                request = route.data,
                session = { gateway_epoch = route.gateway_epoch,
                            connection_id = route.connection_id },
            })
        end
        return
    end
    module_state.diagnostics.control_requests_received = module_state.diagnostics.control_requests_received + 1
    -- skynet.call可能yield；route只保存已经解码的值record，不保存fd或Socket buffer。
    module_state.control_requests_in_flight = module_state.control_requests_in_flight + 1
    local ok, response = pcall(control, route)
    module_state.control_requests_in_flight = module_state.control_requests_in_flight - 1
    if not ok then
        module_state.diagnostics.control_errors = module_state.diagnostics.control_errors + 1
        skynet.error("FRAME_CONTROL_FAILED ", tostring(response))
        response = route.command_id == ids.FRAME_RECOVER and
            { state = { code = "INTERNAL" } } or { code = "INTERNAL" }
    end
    reply(route, response)
end

skynet.start(function()
    for index = 1, frame_sync_config.workers do
        module_state.worker_handles[index] = skynet.newservice("battle/frame_sync/worker")
        assert(skynet.call(module_state.worker_handles[index], "lua", "configure",
            { dispatcher = skynet.self() }))
    end
    skynet.info_func(function()
        return
        {
            workers                    = #module_state.worker_handles,
            next_battle_id             = module_state.next_battle_id,
                input_batches_received     = module_state.diagnostics.input_batches_received,
                control_requests_received  = module_state.diagnostics.control_requests_received,
                control_errors             = module_state.diagnostics.control_errors,
                disconnects_received       = module_state.diagnostics.disconnects_received,
                frame_pushes_received      = module_state.diagnostics.frame_pushes_received,
                gateway_messages_attempted = module_state.diagnostics.gateway_messages_attempted,
                gateway_send_errors        = module_state.diagnostics.gateway_send_errors,
        }
    end)

    skynet.dispatch("lua", function(_, source, command, payload)
        if command == "configure_shutdown" then
            assert(module_state.shutdown_coordinator_handle == nil, "shutdown coordinator already configured")
            assert(math.type(payload) == "integer" and payload == source,
                "shutdown coordinator must configure itself")
            module_state.shutdown_coordinator_handle = source
            skynet.retpack(true)
        elseif command == "drain_complete" then
            assert(module_state.is_draining and source == skynet.self(), "untrusted drain barrier")
            skynet.retpack(true)
        elseif command == "ready" then
            skynet.retpack(true)
        elseif command == "send_data" then
            incoming(payload)
        elseif command == "disconnect" then
            module_state.diagnostics.disconnects_received = module_state.diagnostics.disconnects_received + 1
            for _, handle in ipairs(module_state.worker_handles) do
                skynet.send(handle, "lua", "disconnect", payload)
            end
        elseif command == "frame_push" then
            module_state.diagnostics.frame_pushes_received = module_state.diagnostics.frame_pushes_received + 1
            local trusted = false
            for _, handle in ipairs(module_state.worker_handles) do
                if source == handle then trusted = true; break end
            end
            assert(trusted, "untrusted frame source")
            if not module_state.is_draining then
                reply(
                {
                    gateway_epoch = payload.session.gateway_epoch,
                    connection_id = payload.session.connection_id,
                    command_id = ids.FRAME_PUSH,
                }, payload.data)
            end
        elseif command == "shutdown" then
            assert(source == module_state.shutdown_coordinator_handle and module_state.shutdown_coordinator_handle ~= nil,
                "untrusted shutdown caller")
            module_state.is_draining = true
            while module_state.control_requests_in_flight > 0 do
                skynet.sleep(1)
            end
            -- Worker owns each Native Runtime; wait for every Worker to release it.
            for _, handle in ipairs(module_state.worker_handles) do
                assert(skynet.call(handle, "lua", "shutdown"))
            end
            assert(skynet.call(skynet.self(), "lua", "drain_complete"))
            skynet.retpack(true)
            skynet.exit()
        else
            error("unknown frame dispatch command: " .. tostring(command))
        end
    end)
end)
