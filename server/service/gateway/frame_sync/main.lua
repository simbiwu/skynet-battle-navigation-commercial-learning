--- 职责：Frame Gateway进程启动入口；依赖Ready的Battle后才监听客户端。
--- 边界：网络接入；不加载Battle Native或地图。
--- 输入/输出：监听配置 -> FlyWow TCP/Protobuf长连接服务。
local skynet = require "skynet"
local conf = require "config.gateway_frame_sync"
skynet.start(function()
    local proxy = skynet.newservice("gateway/frame_sync/proxy")
    assert(skynet.call(proxy, "lua", "start"))
    local gateway = skynet.newservice("flywow_gateway")
    assert(skynet.call(proxy, "lua", "bind", { gateway = gateway }))
    local gateway_options = {}
    for key, value in pairs(conf) do
        gateway_options[key] = value
    end
    gateway_options.handler_service = ".frame_proxy"
    assert(skynet.call(gateway, "lua", "start", gateway_options))
    skynet.error("FRAME_GATEWAY_READY port=", conf.port)
    skynet.exit()
end)
