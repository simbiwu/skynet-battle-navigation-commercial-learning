-- 职责：组装 Lesson 2 Gateway Process，把 FlyWow 接入层绑定到远程 Battle Proxy。
-- 边界：Server Runtime Composition Root；拥有 Proxy/Gateway Service 的启动顺序和显式 handle 注入。
-- 输入/输出：process_gateway + config.gateway -> 已监听 Gateway 和 READY 日志。
-- 生命周期：进程启动时创建两个子 Service；本入口完成接线后退出。
-- 不负责：不保存连接、不解析协议、不加载地图、不调用 Battle 业务实现。

local skynet = require "skynet"
local process = require "config.process_gateway"

-- 先启动 Proxy 并完成远程 ready，再让 FlyWow 绑定端口；端口可用意味着两条进程链路都已就绪。
-- 参数：无。返回值：无；执行 Service 创建、跨进程 call 和 Gateway bind，失败终止启动。
skynet.start(function()
    local proxy_service = skynet.newservice("gateway/gateway_proxy")
    assert(skynet.call(proxy_service, "lua", "start"))

    local gateway_service = skynet.newservice("flywow_gateway")
    local gateway = assert(skynet.call(gateway_service, "lua", "start", {
        handler_service = proxy_service,
        host = process.gateway.host,
        port = process.gateway.port,
        transport = process.gateway.transport,
    }))

    skynet.error("LESSON2_GATEWAY_PROCESS_READY gateway=", skynet.address(gateway_service),
                 " listen=", gateway.address, ":", gateway.port,
                 " transport=", gateway.transport,
                 " remote=", process.cluster.remote_node)
    skynet.exit()
end)
