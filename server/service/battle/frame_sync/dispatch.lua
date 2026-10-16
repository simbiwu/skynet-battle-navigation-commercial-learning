--- 职责：Battle Process的帧同步路由、Worker分片与跨进程FramePush发送。
--- 边界：Skynet Service Adapter；不打开fd，不解Proto bytes，不持有Native State。
--- 输入/输出：Proxy信任的route record -> Worker控制调用/输入转发/定向Gateway消息。
--- ownership：本Service独占next_id和Worker handles；控制call允许yield。
--- 不负责：连接身份的最终授权（Worker通过Session绑定验证）、Navigation和玩法。
local skynet  = require "skynet"
local cluster = require "skynet.cluster"
local conf    = require "config.frame_sync"
local ids     = require("gateway.protocol.protocol_registry_lesson_03_frame_sync").command_ids

local workers = {}  -- 固定数量的长期Service handles。
local next_id = 0  -- 本Battle OS进程内单调BattleID；不重用。
local shutdown_coordinator = nil -- 唯一允许关闭Dispatch/Worker池的本地Service。
local draining = false -- drain屏障后拒绝新的客户端业务消息。
local control_in_flight = 0 -- 正在等待Worker控制调用完成的请求数。
local diagnostics =
{
    input_batches_received     = 0, -- 从 Gateway 收到的输入批次数，不是单条输入数。
    control_requests_received  = 0, -- 收到的入场、恢复、离开、回放等非输入请求数。
    control_errors             = 0, -- control 调用失败并转成 INTERNAL 的次数。
    disconnects_received       = 0, -- 收到的 Gateway 断线事件数。
    frame_pushes_received      = 0, -- 从 Worker 收到并准备回推的帧推送数。
    gateway_messages_attempted = 0, -- 尝试发送给 Gateway 的响应或推送数。
    gateway_send_errors        = 0, -- 同步 cluster.send 调用抛出的错误数。
}

--- id路由是battle_id%worker_count+1；不同Battle不会因join落到另一Worker。
local function worker_for(battle_id)
    if math.type(battle_id) ~= "integer" or battle_id < 1 or battle_id > 0x7fffffff then
        return nil
    end
    return workers[battle_id % #workers + 1]
end

--- 请求/回推只带跨进程纯值record；不传fd、buffer借用或Lua userdata。
local function reply(route, response)
    diagnostics.gateway_messages_attempted =
        diagnostics.gateway_messages_attempted + 1
    local ok, err = pcall(cluster.send, conf.gateway_node, "@frame_proxy", "send_data",
    {
        gateway_epoch = route.gateway_epoch,
        connection_id = route.connection_id,
        command_id    = route.command_id,
        data          = response,
    })
    if not ok then
        diagnostics.gateway_send_errors = diagnostics.gateway_send_errors + 1
        skynet.error("FRAME_REPLY_FAILED ", tostring(err))
    end
end

local function control(route)
    local req = route.data
    local args =
    {
        battle_id = req.battle_id,
        request = req,
        session = { gateway_epoch = route.gateway_epoch,
                    connection_id = route.connection_id },
    }
    if route.command_id == ids.FRAME_JOIN then
        if req.scenario_id ~= 1001 then return { code = "BAD_SCENARIO" } end
        if req.battle_id == 0 then
            if next_id >= 0x7fffffff then return { code = "ID_EXHAUSTED" } end
            next_id = next_id + 1
            args.battle_id = next_id
            return skynet.call(worker_for(next_id), "lua", "create", args)
        end
        return skynet.call(worker_for(req.battle_id), "lua", "join", args)
    end
    local target = worker_for(req.battle_id)
    if not target then return { code = "NOT_FOUND" } end
    if route.command_id == ids.FRAME_RECOVER then
        return { state = skynet.call(target, "lua", "recover", args) }
    elseif route.command_id == ids.FRAME_LEAVE then
        return skynet.call(target, "lua", "leave", args)
    elseif route.command_id == ids.FRAME_REPLAY then
        return skynet.call(target, "lua", "replay", args)
    end
    return { code = "BAD_COMMAND" }
end

local function incoming(route)
    assert(type(route) == "table" and type(route.data) == "table")
    assert(type(route.gateway_epoch) == "string" and route.connection_id > 0, "invalid gateway route")
    if draining then
        return
    end
    if route.command_id == ids.FRAME_INPUT then
        diagnostics.input_batches_received = diagnostics.input_batches_received + 1
        local target = worker_for(route.data.battle_id)
        if target then
            skynet.send(target, "lua", "inputs",
            {
                battle_id = route.data.battle_id,
                request = route.data,
                session = { gateway_epoch = route.gateway_epoch,
                            connection_id = route.connection_id },
            })
        end
        return
    end
    diagnostics.control_requests_received = diagnostics.control_requests_received + 1
    -- skynet.call可能yield；route只保存已经解码的值record，不保存fd或Socket buffer。
    control_in_flight = control_in_flight + 1
    local ok, response = pcall(control, route)
    control_in_flight = control_in_flight - 1
    if not ok then
        diagnostics.control_errors = diagnostics.control_errors + 1
        skynet.error("FRAME_CONTROL_FAILED ", tostring(response))
        response = route.command_id == ids.FRAME_RECOVER and
            { state = { code = "INTERNAL" } } or { code = "INTERNAL" }
    end
    reply(route, response)
end

skynet.start(function()
    for index = 1, conf.workers do
        workers[index] = skynet.newservice("battle/frame_sync/worker")
        assert(skynet.call(workers[index], "lua", "configure",
            { dispatcher = skynet.self() }))
    end
    skynet.info_func(function()
        return
        {
            workers                    = #workers,
            next_battle_id             = next_id,
            input_batches_received     = diagnostics.input_batches_received,
            control_requests_received  = diagnostics.control_requests_received,
            control_errors             = diagnostics.control_errors,
            disconnects_received       = diagnostics.disconnects_received,
            frame_pushes_received      = diagnostics.frame_pushes_received,
            gateway_messages_attempted = diagnostics.gateway_messages_attempted,
            gateway_send_errors        = diagnostics.gateway_send_errors,
        }
    end)

    skynet.dispatch("lua", function(_, source, command, payload)
        if command == "configure_shutdown" then
            assert(shutdown_coordinator == nil, "shutdown coordinator already configured")
            assert(math.type(payload) == "integer" and payload == source,
                "shutdown coordinator must configure itself")
            shutdown_coordinator = source
            skynet.retpack(true)
        elseif command == "drain_complete" then
            assert(draining and source == skynet.self(), "untrusted drain barrier")
            skynet.retpack(true)
        elseif command == "ready" then
            skynet.retpack(true)
        elseif command == "send_data" then
            incoming(payload)
        elseif command == "disconnect" then
            diagnostics.disconnects_received = diagnostics.disconnects_received + 1
            for _, handle in ipairs(workers) do
                skynet.send(handle, "lua", "disconnect", payload)
            end
        elseif command == "frame_push" then
            diagnostics.frame_pushes_received = diagnostics.frame_pushes_received + 1
            local trusted = false
            for _, handle in ipairs(workers) do
                if source == handle then trusted = true; break end
            end
            assert(trusted, "untrusted frame source")
            if not draining then
                reply(
                {
                    gateway_epoch = payload.session.gateway_epoch,
                    connection_id = payload.session.connection_id,
                    command_id = ids.FRAME_PUSH,
                }, payload.data)
            end
        elseif command == "shutdown" then
            assert(source == shutdown_coordinator and shutdown_coordinator ~= nil,
                "untrusted shutdown caller")
            draining = true
            while control_in_flight > 0 do
                skynet.sleep(1)
            end
            -- Worker owns each Native Runtime; wait for every Worker to release it.
            for _, handle in ipairs(workers) do
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
