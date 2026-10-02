-- 职责：Gateway 运行配置；供 Gateway Service 通过 require config.gateway 读取。
-- 边界：Server Runtime；只保存监听、协议、资源上限和 Cluster 运行参数。
-- 使用：修改配置后重启 Gateway 进程；启动入口使用同目录的 gateway_process.lua。
-- 不负责：不设置 start、luaservice、lua_path 等 Skynet 进程启动参数。
return {
    host = "127.0.0.1",                                     -- Gateway 监听地址；127.0.0.1 只允许本机客户端连接。
    port = 19011,                                            -- Gateway 业务端口；客户端和集成测试连接此端口。
    backlog = 128,                                           -- OS accept 队列长度；不等于 max_clients。
    transport = "tcp",                                       -- 接入协议；当前生产验收使用 tcp，也可由 FlyWow 支持 websocket。
    websocket_protocol = "ws",                              -- transport=websocket 时使用的协议标识；TLS 由外部终止。
    descriptor_path = "../shared/protocol/generated/server/navigation_query.pb", -- FileDescriptorSet 路径；相对 Server 工作目录。
    registry_module = "gateway.protocol.navigation_registry", -- Registry Lua 模块；由 FlyWow 脚本生成，不手工维护。
    protocol_version = 3,                                    -- Envelope 协议版本；必须与客户端握手合同一致。
    max_frame_bytes = 0xffff,                                -- 单帧最大字节数；TCP uint16 framing 的上限。
    read_timeout_ticks = 3000,                               -- TCP 定长读取或 WS 握手最长等待 30 秒。
    idle_timeout_ticks = 30000,                              -- WebSocket 完整消息空闲最长等待 300 秒。
    max_requests_per_second = 200,                           -- 单连接每秒最大入站请求数；超限关闭连接。
    max_total_requests_per_second = 10000,                   -- Gateway 实例总入站速率上限；超限拒绝来源连接。
    max_pending_handshakes = 128,                            -- 同时进行应用握手的连接数上限。
    handshake_timeout_ticks = 1000,                          -- 从接纳到握手完成的最长时间，单位为 10ms tick。
    max_clients = 1024,                                      -- Gateway 允许保持的最大在线连接数。
    write_warning_close_kb = 1024,                           -- 写缓冲达到 1 MiB 时关闭慢连接，防止内存持续增长。

    cluster = {
        local_node = "gateway",                              -- 本进程在 Skynet Cluster 中注册的节点名。
        proxy_service = "gateway_proxy",                     -- Battle 回推结果的本地接收 Service 名。
        local_listen = 2527,                                 -- Gateway Cluster 监听端口；Battle 通过此端口回推。
        remote_node = "battle",                              -- Battle 进程的 Cluster 节点名。
        remote_service = "battle_dispatch",                  -- Battle 进程公开的 Cluster Service 名。
        remote_address = "127.0.0.1:2528",                   -- Battle Cluster 地址；格式为 host:port。
        max_clients = 64,                                    -- Cluster 连接上限；不等于 Gateway 客户端上限。
    },
}
