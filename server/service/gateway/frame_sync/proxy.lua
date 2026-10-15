--- 职责：把FlyWow Gateway已解码请求转发给Frame Dispatch，并接收定向FramePush。
--- 边界：Gateway OS进程；不解释技能、Navigation或权威状态。
--- 输入/输出：Gateway record和断线事件 -> Cluster；Battle record -> Gateway发送。
--- ownership：gateway handle由组合根bind一次，网络fd只由FlyWow Gateway持有。
local skynet  = require "skynet.manager"
local cluster = require "skynet.cluster"
local conf    = require "config.frame_sync"
local gateway = nil

local function forward(command, payload)
    local ok, err = pcall(cluster.send, conf.battle_node,
        "@frame_dispatch", command, payload)
    if not ok then skynet.error("FRAME_PROXY_FORWARD_FAILED ", tostring(err)) end
end

skynet.start(function()
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
        elseif command == "send_data" then
            assert(gateway and type(payload.data) == "table")
            if source == gateway then
                forward("send_data", payload)
            else
                -- FlyWow Gateway支持无请求关联的定向push；跨实例会重验epoch/id。
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
