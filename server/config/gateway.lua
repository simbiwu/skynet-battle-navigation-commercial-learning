-- 职责：声明 FlyWow Gateway 的宿主默认配置，集中管理监听、协议产物和资源上限。
-- 边界：Server Runtime Config；由 flywow_gateway Service 在启动时只读加载。
-- 输入/输出：无运行时输入 -> Gateway 默认配置 table；start 覆盖项可临时替换顶层字段。
-- 生命周期：Gateway 启动时读取一次；启动后不可修改，不持有连接或业务状态。
-- 不负责：不创建 Service、不生成协议、不注册 command、不处理 Socket。
return {
    host = "127.0.0.1",                         -- 监听地址；默认只接受本机连接。
    port = 19001,                                -- TCP/WebSocket 监听端口；范围 1..65535。
    backlog = 128,                               -- OS accept backlog；不等于 max_clients。
    transport = "tcp",                          -- 接入模式：tcp 或 websocket。
    websocket_protocol = "ws",                   -- 当前只支持 ws；TLS 由宿主前置终止。

    descriptor_path = "../shared/protocol/generated/server/navigation_query.pb", -- FileDescriptorSet 运行路径。
    registry_module = "gateway.protocol.navigation_registry",                            -- FlyWow 构建生成的 command registry。
    protocol_version = 3,                          -- WorldPosition 统一为 sint64 后的 Envelope 兼容版本。

    max_frame_bytes = 0xffff,                     -- TCP uint16 framing 上限；WebSocket 复用同一业务上限。
    read_timeout_ticks = 3000,                    -- 每次 TCP 定长读取/WS 握手最多 30 秒，不等待业务响应。
    idle_timeout_ticks = 30000,                   -- WS 完整消息空闲最多 300 秒。
    max_requests_per_second = 200,                -- 单连接入站帧速率；超限关闭。
    max_total_requests_per_second = 10000,        -- Gateway 实例总入站帧速率；超限关闭来源连接。
    max_pending_handshakes = 128,                -- 同时进行应用握手的连接上限，计入max_clients。
    handshake_timeout_ticks = 1000,              -- 从接纳到ready总期限10秒，不随握手消息刷新。
    max_clients = 1024,                           -- 当前 Gateway 最大在线连接数。
    write_warning_close_kb = 1024,                -- 写缓冲 warning 达到该 KB 时关闭慢连接。
}
