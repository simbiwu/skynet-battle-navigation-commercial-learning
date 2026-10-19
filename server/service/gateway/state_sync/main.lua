--- 职责：State Gateway进程启动入口；依赖Ready的Battle后才监听客户端。
--- 边界：网络接入；不加载Battle Native或地图。
--- 输入/输出：监听配置 -> FlyWow TCP/Protobuf长连接服务。
local skynet = require("skynet")
local gateway_state_sync_config = require("config.gateway_state_sync")
skynet.start(function()
    local proxy = skynet.newservice("gateway/state_sync/proxy")
    assert(skynet.call(proxy, "lua", "start"))
    local gateway = skynet.newservice("flywow_gateway")
    assert(skynet.call(proxy, "lua", "bind", { gateway = gateway }))
    local gateway_options = {}
    for key, value in pairs(gateway_state_sync_config) do
        gateway_options[key] = value
    end
    gateway_options.handler_service = ".state_proxy"
    assert(skynet.call(gateway, "lua", "start", gateway_options))
    local shutdown_coordinator = skynet.newservice("admin/lesson3_shutdown_coordinator")
    assert(skynet.call(shutdown_coordinator, "lua", "configure", {
        profile = "state_sync",
        role = "gateway",
        endpoint = "state_gateway_shutdown",
        gateway = gateway,
        proxy = proxy,
    }))
    assert(skynet.call(shutdown_coordinator, "lua", "ready"))
    skynet.error("STATE_GATEWAY_READY port=", gateway_state_sync_config.port)
    skynet.exit()
end)
