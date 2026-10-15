-- 职责：第三课 frame sync Gateway 独立运行配置。
-- 边界：由该课程 Gateway composition root 显式传给通用 FlyWow Gateway。
-- 路径：descriptor 相对 Server 根目录；Registry 由专属 build_protocol 脚本生成。
return {
    host = "127.0.0.1",
    port = 19021,
    backlog = 128,
    transport = "tcp",
    websocket_protocol = "ws",
    descriptor_path = "../shared/protocol/generated/server/lesson_03_frame_sync.pb",
    registry_module = "gateway.protocol.protocol_registry_lesson_03_frame_sync",
    protocol_version = 4,
    max_frame_bytes = 0xffff,
    read_timeout_ticks = 3000,
    idle_timeout_ticks = 30000,
    max_requests_per_second = 200,
    max_total_requests_per_second = 10000,
    max_pending_handshakes = 128,
    handshake_timeout_ticks = 1000,
    max_clients = 1024,
    write_warning_close_kb = 1024,
}
