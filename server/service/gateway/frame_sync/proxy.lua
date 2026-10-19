--- 职责：把FlyWow Gateway已解码请求转发给Frame Dispatch，并接收定向FramePush。
--- 边界：Gateway OS进程；不解释技能、Navigation或权威状态。
--- 输入/输出：Gateway record和断线事件 -> Cluster；Battle record -> Gateway发送。
--- ownership：gateway handle由组合根bind一次，网络fd只由FlyWow Gateway持有。
local skynet  = require "skynet.manager"
local cluster = require "skynet.cluster"
local frame_sync_config = require "config.frame_sync"
local module_state =
{
    gateway_service_handle = nil, -- 组合根绑定的本地 Gateway Service，只由此 Proxy 投递消息。
    shutdown_coordinator_handle = nil, -- 唯一被授权关闭 Proxy 的本进程 Service。
    diagnostics =
    {
    client_messages_to_battle  = 0, -- 从 FlyWow Gateway 向 Battle 转交的已解码消息数。
    disconnects_to_battle      = 0, -- 向 Battle 转交的断线事件数。
    battle_messages_to_gateway = 0, -- 从 Battle 转交给 FlyWow Gateway 的响应或推送数。
    cluster_send_errors        = 0, -- 同步 cluster.send 调用抛出的错误数。
    },
}

local function forward(command, payload)
    if command == "disconnect" then
        module_state.diagnostics.disconnects_to_battle = module_state.diagnostics.disconnects_to_battle + 1
    else
        module_state.diagnostics.client_messages_to_battle = module_state.diagnostics.client_messages_to_battle + 1
    end

    local ok, err = pcall(cluster.send, frame_sync_config.battle_node,
        "@frame_dispatch", command, payload)
    if not ok then
        module_state.diagnostics.cluster_send_errors = module_state.diagnostics.cluster_send_errors + 1
        skynet.error("FRAME_PROXY_FORWARD_FAILED ", tostring(err))
    end
end

skynet.start(function()
    skynet.info_func(function()
        return
        {
            gateway_bound              = module_state.gateway_service_handle ~= nil,
            gateway_handle             = module_state.gateway_service_handle and skynet.address(module_state.gateway_service_handle) or "unbound",
            gateway_node               = frame_sync_config.gateway_node,
            battle_node                = frame_sync_config.battle_node,
            client_messages_to_battle  = module_state.diagnostics.client_messages_to_battle,
            disconnects_to_battle      = module_state.diagnostics.disconnects_to_battle,
            battle_messages_to_gateway = module_state.diagnostics.battle_messages_to_gateway,
            cluster_send_errors        = module_state.diagnostics.cluster_send_errors,
        }
    end)

    skynet.dispatch("lua", function(_, source, command, payload)
        if command == "start" then
            cluster.reload({ [frame_sync_config.battle_node] = frame_sync_config.battle_address,
                             [frame_sync_config.gateway_node] = frame_sync_config.gateway_address })
            cluster.open(frame_sync_config.gateway_node, 64)
            cluster.register("frame_proxy", skynet.self())
            assert(cluster.call(frame_sync_config.battle_node, "@frame_dispatch", "ready"))
            skynet.name(".frame_proxy", skynet.self())
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
                -- FlyWow Gateway支持无请求关联的定向push；跨实例会重验epoch/id。
                module_state.diagnostics.battle_messages_to_gateway =
                    module_state.diagnostics.battle_messages_to_gateway + 1
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
