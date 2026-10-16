--- 职责：把FlyWow Gateway已解码请求转发给State Dispatch，并接收定向StatePush。
--- 边界：Gateway OS进程；不解释技能、Navigation或权威状态。
--- 输入/输出：Gateway record和断线事件 -> Cluster；Battle record -> Gateway发送。
--- ownership：gateway handle由组合根bind一次，网络fd只由FlyWow Gateway持有。
local skynet = require("skynet.manager")
local cluster = require("skynet.cluster")
local conf = require("config.state_sync")
local gateway = nil
local shutdown_coordinator = nil

local function forward(command, payload)
    local ok, err = pcall(cluster.send, conf.battle_node, "@state_dispatch", command, payload)
    if not ok then
        skynet.error("STATE_PROXY_FORWARD_FAILED ", tostring(err))
    end
end

skynet.start(function()
    skynet.dispatch("lua", function(_, source, command, payload)
        if command == "start" then
            cluster.reload({
                [conf.battle_node] = conf.battle_address,
                [conf.gateway_node] = conf.gateway_address,
            })
            cluster.open(conf.gateway_node, 64)
            cluster.register("state_proxy", skynet.self())
            assert(cluster.call(conf.battle_node, "@state_dispatch", "ready"))
            skynet.name(".state_proxy", skynet.self())
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
                -- Gateway只按epoch和连接身份投递，业务确认字段在data内。
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
