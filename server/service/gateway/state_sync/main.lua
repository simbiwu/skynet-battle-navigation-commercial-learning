--- 职责：State Gateway进程启动入口；依赖Ready的Battle后才监听客户端。
--- 边界：网络接入；不加载Battle Native或地图。
--- 输入/输出：监听配置 -> FlyWow TCP/Protobuf长连接服务。
local skynet = require("skynet")
local conf = require("config.state_sync")
skynet.start(function()
    local proxy = skynet.newservice("gateway/state_sync/proxy")
    assert(skynet.call(proxy, "lua", "start"))
    local gateway = skynet.newservice("flywow_gateway")
    assert(skynet.call(proxy, "lua", "bind", { gateway = gateway }))
    assert(skynet.call(gateway, "lua", "start", {
        handler_service  = ".state_proxy",
        host             = "127.0.0.1",
        port             = conf.gateway_port,
        transport        = "tcp",
        protocol_version = 4,
    }))
    skynet.error("STATE_GATEWAY_READY port=", conf.gateway_port)
    skynet.exit()
end)
