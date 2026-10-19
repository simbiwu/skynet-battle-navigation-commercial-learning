--- 状态同步固定Worker分片；只处理业务值record，不处理fd/Proto字节。
local skynet = require("skynet")
local cluster = require("skynet.cluster")
local state_sync_config = require("config.state_sync")
local ids = require("gateway.protocol.protocol_registry_lesson_03_state_sync").command_ids
local module_state =
{
    worker_handles = {}, -- 本 Dispatch 独占的固定 Worker Service handle 池。
    next_battle_id = 0, -- 本 Battle 进程内单调分配且不重用的 Battle ID。
    control_requests_in_flight = 0, -- 正在等待 Worker 控制调用返回的请求数。
    shutdown_coordinator_handle = nil, -- 被授权执行关闭和 drain 的本地 Service。
    is_draining = false, -- drain 屏障开始后拒绝新的客户端业务请求。
    action_by_command_id = {}, -- 将已登记的协议命令映射为 Worker 控制动作。
}
local function worker_for(id)
    if math.type(id) ~= "integer" or id < 1 or id > 0x7fffffff then
        return nil
    end
    return module_state.worker_handles[id % #module_state.worker_handles + 1]
end
local function reply(route, data)
    local ok, err = pcall(cluster.send, state_sync_config.gateway_node, "@state_proxy", "send_data", {
        gateway_epoch = route.gateway_epoch,
        connection_id = route.connection_id,
        command_id    = route.command_id,
        data          = data,
    })
    if not ok then
        skynet.error("STATE_SEND_FAILED ", tostring(err))
    end
end
local function incoming(route)
    if
        type(route) ~= "table"
        or type(route.data) ~= "table"
        or type(route.gateway_epoch) ~= "string"
        or math.type(route.connection_id) ~= "integer"
        or route.connection_id <= 0
    then
        return
    end
    local action_name = module_state.action_by_command_id[route.command_id]
    if not action_name or module_state.is_draining then
        return
    end
    if module_state.control_requests_in_flight >= 64 then
        reply(route, action_name == "recover" and { state = { code = "BUSY" } } or { code = "BUSY" })
        return
    end
    local battle_id = route.data.battle_id
    if action_name == "create" then
        if module_state.next_battle_id >= 0x7fffffff then
            reply(route, { code = "ID_EXHAUSTED" })
            return
        end
        module_state.next_battle_id = module_state.next_battle_id + 1
        battle_id = module_state.next_battle_id
    end
    local worker_handle = worker_for(battle_id)
    if not worker_handle then
        reply(
            route,
            action_name == "recover" and { state = { code = "NOT_FOUND" } } or { code = "NOT_FOUND" }
        )
        return
    end
    module_state.control_requests_in_flight = module_state.control_requests_in_flight + 1
    local worker_command = {
        action    = action_name,
        battle_id = battle_id,
        request   = route.data,
        session   = { gateway_epoch = route.gateway_epoch, connection_id = route.connection_id },
    }
    local ok, worker_result = pcall(skynet.call, worker_handle, "lua", "control", worker_command)
    module_state.control_requests_in_flight = module_state.control_requests_in_flight - 1
    if not ok then
        skynet.error("STATE_CONTROL_FAILED ", tostring(worker_result))
        worker_result = action_name == "recover" and { state = { code = "INTERNAL" } } or { code = "INTERNAL" }
    end
    reply(route, worker_result)
    if action_name == "inputs" and worker_result.code ~= "OK" then
        reply({
            gateway_epoch = route.gateway_epoch,
            connection_id = route.connection_id,
            command_id    = ids.STATE_PUSH,
        }, { battle_id = battle_id, generation = route.data.generation, code = worker_result.code })
    end
end
skynet.start(function()
    module_state.action_by_command_id[ids.STATE_JOIN] = "create"
    module_state.action_by_command_id[ids.STATE_INPUT] = "inputs"
    module_state.action_by_command_id[ids.STATE_CAST] = "cast"
    module_state.action_by_command_id[ids.STATE_RECOVER] = "recover"
    module_state.action_by_command_id[ids.STATE_RESYNC] = "resync"
    module_state.action_by_command_id[ids.STATE_LEAVE] = "leave"
    module_state.action_by_command_id[ids.STATE_REPLAY] = "replay"
    for i = 1, state_sync_config.workers do
        module_state.worker_handles[i] = skynet.newservice("battle/state_sync/worker")
        assert(skynet.call(module_state.worker_handles[i], "lua", "configure", { dispatcher = skynet.self() }))
    end
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
            for _, worker in ipairs(module_state.worker_handles) do
                skynet.send(worker, "lua", "disconnect", payload)
            end
        elseif command == "state_push" then
            local trusted = false
            for _, worker in ipairs(module_state.worker_handles) do
                if worker == source then
                    trusted = true
                    break
                end
            end
            assert(trusted, "STATE_PUSH_SOURCE")
            if not module_state.is_draining then
                reply({
                    gateway_epoch = payload.session.gateway_epoch,
                    connection_id = payload.session.connection_id,
                    command_id    = ids.STATE_PUSH,
                }, payload.data)
            end
        elseif command == "shutdown" then
            assert(source == module_state.shutdown_coordinator_handle and module_state.shutdown_coordinator_handle ~= nil,
                "untrusted shutdown caller")
            module_state.is_draining = true
            while module_state.control_requests_in_flight > 0 do
                skynet.sleep(1)
            end
            for _, worker in ipairs(module_state.worker_handles) do
                assert(skynet.call(worker, "lua", "shutdown"))
            end
            assert(skynet.call(skynet.self(), "lua", "drain_complete"))
            skynet.retpack(true)
            skynet.exit()
        else
            error("STATE_DISPATCH_BAD_COMMAND")
        end
    end)
end)
