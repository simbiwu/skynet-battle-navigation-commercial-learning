-- 职责：第三课 frame sync Gateway 独立运行配置。
-- 边界：由该课程 Gateway composition root 显式传给通用 FlyWow Gateway。
-- 路径：descriptor 相对 Server 根目录；Registry 由专属 build_protocol 脚本生成。
return {
    host = "127.0.0.1",
    port = 19021,
    transport = "tcp",
    descriptor_path = "../shared/protocol/generated/server/lesson_03_frame_sync.pb",
    registry_module = "gateway.protocol.protocol_registry_lesson_03_frame_sync",
    protocol_version = 4,
    read_timeout_ms = 30000,
    idle_timeout_ms = 300000,
    handshake_timeout_ms = 10000,
    max_clients = 1024,
}
