-- 职责：声明 Lesson 2 Map/Battle Process 的 cluster 端点和远程 Service 名。
-- 边界：Server Runtime Config；只被 battle_main 读取，不保存地图或战斗动态状态。
-- 输入/输出：固定部署配置 -> 当前进程的 cluster 监听参数。
-- 生命周期：Battle Process 启动时只读加载；修改后必须重启该进程。
-- 不负责：不监听 Unity TCP/WebSocket，不持有 Gateway fd。
return {
    cluster = {
        local_listen = 2528,             -- 本进程 cluster 监听端口；Skynet 默认绑定 0.0.0.0。
        service_name = "battle_dispatch", -- 跨进程发现的明确入口。
        max_clients = 64,                 -- cluster 连接上限。
    },
}
