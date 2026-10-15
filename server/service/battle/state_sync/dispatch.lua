--- 状态同步固定Worker分片；只处理业务值record，不处理fd/Proto字节。
local skynet = require("skynet")
local cluster = require("skynet.cluster")
local conf = require("config.state_sync")
local ids = require("gateway.protocol.protocol_registry_lesson_03_state_sync").command_ids
local workers, next_id, controls = {}, 0, 0
local actions = {}
local function worker_for(id)
    if math.type(id) ~= "integer" or id < 1 or id > 0x7fffffff then
        return nil
    end
    return workers[id % #workers + 1]
end
local function reply(route, data)
    local ok, err = pcall(cluster.send, conf.gateway_node, "@state_proxy", "send_data", {
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
    local action = actions[route.command_id]
    if not action then
        return
    end
    if controls >= 64 then
        reply(route, action == "recover" and { state = { code = "BUSY" } } or { code = "BUSY" })
        return
    end
    local id = route.data.battle_id
    if action == "create" then
        if next_id >= 0x7fffffff then
            reply(route, { code = "ID_EXHAUSTED" })
            return
        end
        next_id = next_id + 1
        id      = next_id
    end
    local worker = worker_for(id)
    if not worker then
        reply(
            route,
            action == "recover" and { state = { code = "NOT_FOUND" } } or { code = "NOT_FOUND" }
        )
        return
    end
    controls = controls + 1
    local ok, result = pcall(skynet.call, worker, "lua", "control", {
        action    = action,
        battle_id = id,
        request   = route.data,
        session   = { gateway_epoch = route.gateway_epoch, connection_id = route.connection_id },
    })
    controls = controls - 1
    if not ok then
        skynet.error("STATE_CONTROL_FAILED ", tostring(result))
        result = action == "recover" and { state = { code = "INTERNAL" } } or { code = "INTERNAL" }
    end
    reply(route, result)
    if action == "inputs" and result.code ~= "OK" then
        reply({
            gateway_epoch = route.gateway_epoch,
            connection_id = route.connection_id,
            command_id    = ids.STATE_PUSH,
        }, { battle_id = id, generation = route.data.generation, code = result.code })
    end
end
skynet.start(function()
    actions[ids.STATE_JOIN] = "create"
    actions[ids.STATE_INPUT] = "inputs"
    actions[ids.STATE_CAST] = "cast"
    actions[ids.STATE_RECOVER] = "recover"
    actions[ids.STATE_RESYNC] = "resync"
    actions[ids.STATE_LEAVE] = "leave"
    actions[ids.STATE_REPLAY] = "replay"
    for i = 1, conf.workers do
        workers[i] = skynet.newservice("battle/state_sync/worker")
        assert(skynet.call(workers[i], "lua", "configure", { dispatcher = skynet.self() }))
    end
    skynet.dispatch("lua", function(_, source, command, payload)
        if command == "ready" then
            skynet.retpack(true)
        elseif command == "send_data" then
            incoming(payload)
        elseif command == "disconnect" then
            for _, worker in ipairs(workers) do
                skynet.send(worker, "lua", "disconnect", payload)
            end
        elseif command == "state_push" then
            local trusted = false
            for _, worker in ipairs(workers) do
                if worker == source then
                    trusted = true
                    break
                end
            end
            assert(trusted, "STATE_PUSH_SOURCE")
            reply({
                gateway_epoch = payload.session.gateway_epoch,
                connection_id = payload.session.connection_id,
                command_id    = ids.STATE_PUSH,
            }, payload.data)
        elseif command == "shutdown" then
            for _, worker in ipairs(workers) do
                assert(skynet.call(worker, "lua", "shutdown"))
            end
            skynet.retpack(true)
            skynet.exit()
        else
            error("STATE_DISPATCH_BAD_COMMAND")
        end
    end)
end)
