-- 职责：组装 Lesson 2 Map/Battle Process，并注册跨进程 cluster Service。
-- 边界：Server Runtime Composition Root；拥有本进程的地图查询和后续战斗 Service 生命周期。
-- 输入/输出：Skynet 启动本文件 -> battle_dispatch cluster 入口和 READY 日志。
-- 生命周期：进程启动时创建查询 Service；本入口完成接线后退出，子 Service 继续运行。
-- 不负责：不监听 Unity TCP/WebSocket，不拥有 Gateway fd，不解析网络协议。

local cluster = require "skynet.cluster"
local skynet = require "skynet"
local process = require "config.process_battle"

-- 先等待地图查询加载完成，再开放 cluster 端点；这样 Gateway 看到 READY 时，QueryCell 已可用。
-- 参数：无。返回值：无；执行 Service 创建、cluster I/O 和 yield，失败会终止进程启动。
skynet.start(function()
    local query_service = skynet.newservice("navigation_query")
    assert(skynet.call(query_service, "lua", "ready"), "navigation query did not become ready")

    -- cluster.open 只拥有本进程的 RPC 监听端口；它不暴露地图对象或任何 Socket fd。
    cluster.open(process.cluster.local_listen, process.cluster.max_clients)
    cluster.register(process.cluster.service_name, query_service)

    skynet.error("LESSON2_BATTLE_PROCESS_READY node=", process.cluster.service_name,
                 " query=", skynet.address(query_service),
                 " cluster=", process.cluster.local_listen)
    skynet.exit()
end)
