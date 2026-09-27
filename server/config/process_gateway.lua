-- 职责：声明 Lesson 2 Gateway Process 的集群端点和业务 Gateway 监听端口。
-- 边界：Server Runtime Config；只被 gateway_main、gateway_proxy 读取，不保存连接或战斗状态。
-- 输入/输出：固定部署配置 -> 当前进程的 cluster/port 参数。
-- 生命周期：Gateway Process 启动时只读加载；修改后必须重启该进程。
-- 不负责：不加载 BMAP、不创建 BattleWorker、不解析协议源码。
return {
    gateway = {
        host = "127.0.0.1",       -- 对外监听地址。
        port = 19011,              -- 双进程模式 Gateway 端口。
        transport = "tcp",        -- 当前验收先使用 TCP。
    },
    cluster = {
        local_listen = 2527,              -- 本进程 cluster 监听端口；Skynet 默认绑定 0.0.0.0。
        remote_node = "battle",          -- Battle Process 节点名。
        remote_service = "battle_dispatch", -- Battle Process 的显式 cluster Service 名。
        remote_address = "127.0.0.1:2528", -- Battle Process cluster 地址。
        max_clients = 64,                -- cluster 连接上限。
    },
}
