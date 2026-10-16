--- 职责：把FlyWow Gateway已解码请求转发给Frame Dispatch，并接收定向FramePush。
--- 边界：Gateway OS进程；不解释技能、Navigation或权威状态。
--- 输入/输出：Gateway record和断线事件 -> Cluster；Battle record -> Gateway发送。
--- ownership：gateway handle由组合根bind一次，网络fd只由FlyWow Gateway持有。
local skynet  = require "skynet.manager"
local cluster = require "skynet.cluster"
local conf    = require "config.frame_sync"
local gateway = nil
local shutdown_coordinator = nil
local diagnostics =
{
    client_messages_to_battle  = 0, -- 从 FlyWow Gateway 向 Battle 转交的已解码消息数。
    disconnects_to_battle      = 0, -- 向 Battle 转交的断线事件数。
    battle_messages_to_gateway = 0, -- 从 Battle 转交给 FlyWow Gateway 的响应或推送数。
    cluster_send_errors        = 0, -- 同步 cluster.send 调用抛出的错误数。
}

local function forward(command, payload)
    if command == "disconnect" then
        diagnostics.disconnects_to_battle = diagnostics.disconnects_to_battle + 1
    else
        diagnostics.client_messages_to_battle = diagnostics.client_messages_to_battle + 1
    end

    local ok, err = pcall(cluster.send, conf.battle_node,
        "@frame_dispatch", command, payload)
    if not ok then
        diagnostics.cluster_send_errors = diagnostics.cluster_send_errors + 1
        skynet.error("FRAME_PROXY_FORWARD_FAILED ", tostring(err))
    end
end

skynet.start(function()
    skynet.info_func(function()
        return
        {
            gateway_bound              = gateway ~= nil,
            gateway_handle             = gateway and skynet.address(gateway) or "unbound",
            gateway_node               = conf.gateway_node,
            battle_node                = conf.battle_node,
            client_messages_to_battle  = diagnostics.client_messages_to_battle,
            disconnects_to_battle      = diagnostics.disconnects_to_battle,
            battle_messages_to_gateway = diagnostics.battle_messages_to_gateway,
            cluster_send_errors        = diagnostics.cluster_send_errors,
        }
    end)

    skynet.dispatch("lua", function(_, source, command, payload)
        if command == "start" then
            cluster.reload({ [conf.battle_node] = conf.battle_address,
                             [conf.gateway_node] = conf.gateway_address })
            cluster.open(conf.gateway_node, 64)
            cluster.register("frame_proxy", skynet.self())
            assert(cluster.call(conf.battle_node, "@frame_dispatch", "ready"))
            skynet.name(".frame_proxy", skynet.self())
            skynet.retpack(true)
        elseif command == "bind" then
            assert(gateway == nil and payload.gateway)
            gateway = payload.gateway
            skynet.retpack(true)
        elseif command == "set_shutdown_coordinator" then
            assert(shutdown_coordinator == nil, "shutdown coordinator already set")
            assert(math.type(payload) == "integer" and payload == source,
                "shutdown coordinator must configure itself")
            shutdown_coordinator = source
            skynet.retpack(true)
        elseif command == "shutdown" then
            assert(source == shutdown_coordinator and shutdown_coordinator ~= nil,
                "untrusted shutdown caller")
            skynet.retpack(true)
            skynet.exit()
        elseif command == "send_data" then
            assert(gateway and type(payload.data) == "table")
            if source == gateway then
                forward("send_data", payload)
            else
                -- FlyWow Gateway支持无请求关联的定向push；跨实例会重验epoch/id。
                diagnostics.battle_messages_to_gateway =
                    diagnostics.battle_messages_to_gateway + 1
                skynet.send(gateway, "lua", "send_data", payload)
            end
        elseif command == "gateway_disconnect" then
            assert(source == gateway)
            forward("disconnect", payload)
        else
            error("unknown frame proxy command: " .. tostring(command))
        end
    end)
end)
