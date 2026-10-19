--- 职责：把FlyWow Gateway已解码请求转发给State Dispatch，并接收定向StatePush。
--- 边界：Gateway OS进程；不解释技能、Navigation或权威状态。
--- 输入/输出：Gateway record和断线事件 -> Cluster；Battle record -> Gateway发送。
--- ownership：gateway handle由组合根bind一次，网络fd只由FlyWow Gateway持有。
local skynet = require("skynet.manager")
local cluster = require("skynet.cluster")
local state_sync_config = require("config.state_sync")
local gateway = nil
local shutdown_coordinator = nil

local function forward(command, payload)
    local ok, err = pcall(cluster.send, state_sync_config.battle_node, "@state_dispatch", command, payload)
    if not ok then
        skynet.error("STATE_PROXY_FORWARD_FAILED ", tostring(err))
    end
end

skynet.start(function()
    skynet.dispatch("lua", function(_, source, command, payload)
        if command == "start" then
            cluster.reload({
                [state_sync_config.battle_node] = state_sync_config.battle_address,
                [state_sync_config.gateway_node] = state_sync_config.gateway_address,
            })
            cluster.open(state_sync_config.gateway_node, 64)
            cluster.register("state_proxy", skynet.self())
            assert(cluster.call(state_sync_config.battle_node, "@state_dispatch", "ready"))
            skynet.name(".state_proxy", skynet.self())
            skynet.retpack(true)
        elseif command == "bind" then
            assert(module_state.gateway_service_handle == nil and payload.gateway)
            module_state.gateway_service_handle = payload.gateway
            skynet.retpack(true)
        elseif command == "set_shutdown_coordinator" then
            assert(module_state.shutdown_coordinator_handle == nil, "shutdown coordinator already set")
            assert(math.type(payload) == "integer" and payload == source,
                "shutdown coordinator must configure itself")
            module_state.shutdown_coordinator_handle = source
            skynet.retpack(true)
        elseif command == "shutdown" then
            assert(source == module_state.shutdown_coordinator_handle and module_state.shutdown_coordinator_handle ~= nil,
                "untrusted shutdown caller")
            skynet.retpack(true)
            skynet.exit()
        elseif command == "send_data" then
            assert(module_state.gateway_service_handle and type(payload.data) == "table")
            if source == module_state.gateway_service_handle then
                forward("send_data", payload)
            else
                -- Gateway只按epoch和连接身份投递，业务确认字段在data内。
                skynet.send(module_state.gateway_service_handle, "lua", "send_data", payload)
            end
        elseif command == "gateway_disconnect" then
            assert(source == module_state.gateway_service_handle)
            forward("disconnect", payload)
        else
            error("unknown frame proxy command: " .. tostring(command))
        end
    end)
end)
