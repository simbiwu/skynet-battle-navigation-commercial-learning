--- 职责：Frame Gateway进程启动入口；依赖Ready的Battle后才监听客户端。
--- 边界：网络接入；不加载Battle Native或地图。
--- 输入/输出：监听配置 -> FlyWow TCP/Protobuf长连接服务。
local skynet = require "skynet"
local gateway_frame_sync_config = require "config.gateway_frame_sync"
local debug_console_port = tonumber(skynet.getenv("debug_console_port") or "0")

skynet.start(function()
    if debug_console_port > 0 then
        skynet.newservice("debug_console", debug_console_port)
    end
    
    local proxy = skynet.newservice("gateway/frame_sync/proxy")
    assert(skynet.call(proxy, "lua", "start"))
    local gateway = skynet.newservice("flywow_gateway")
    assert(skynet.call(proxy, "lua", "bind", { gateway = gateway }))
    local gateway_options = {}
    for key, value in pairs(gateway_frame_sync_config) do
        gateway_options[key] = value
    end
    gateway_options.handler_service = ".frame_proxy"
    assert(skynet.call(gateway, "lua", "start", gateway_options))
    local shutdown_coordinator = skynet.newservice("admin/lesson3_shutdown_coordinator")
    assert(skynet.call(shutdown_coordinator, "lua", "configure", {
        profile = "frame_sync",
        role = "gateway",
        endpoint = "frame_gateway_shutdown",
        gateway = gateway,
        proxy = proxy,
    }))
    assert(skynet.call(shutdown_coordinator, "lua", "ready"))
    skynet.error("FRAME_GATEWAY_READY port=", gateway_frame_sync_config.port)
    skynet.exit()
end)
