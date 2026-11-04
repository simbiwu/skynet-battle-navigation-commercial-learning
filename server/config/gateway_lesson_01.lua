-- 职责：Gateway 运行配置；供 Gateway Service 通过 require 由对应课程 composition root 显式传给 FlyWow Gateway。
-- 边界：Server Runtime；只保存监听、协议、资源上限和 Cluster 运行参数。
-- 使用：修改配置后重启 Gateway 进程；启动入口使用同目录的 gateway_process.lua。
-- 不负责：不设置 start、luaservice、lua_path 等 Skynet 进程启动参数。
return {
    host = "127.0.0.1",                                     -- Gateway 监听地址；127.0.0.1 只允许本机客户端连接。
    port = 19011,                                            -- Gateway 业务端口；客户端和集成测试连接此端口。
    transport = "tcp",                                       -- 接入协议；当前生产验收使用 tcp，也可由 FlyWow 支持 websocket。
    descriptor_path = "../shared/protocol/generated/server/lesson_01.pb", -- FileDescriptorSet 路径；相对 Server 工作目录。
    registry_module = "gateway.protocol.protocol_registry_lesson_01", -- Registry Lua 模块；由 FlyWow 脚本生成，不手工维护。
    protocol_version = 4,                                    -- Envelope 协议版本；必须与客户端握手合同一致。
    read_timeout_ms = 30000,                               -- TCP 定长读取或 WS 握手最长等待 30 秒。
    idle_timeout_ms = 300000,                              -- WebSocket 完整消息空闲最长等待 300 秒。
    handshake_timeout_ms = 10000,                          -- 从接纳到握手完成的最长时间，单位毫秒。
    max_clients = 1024,                                      -- Gateway 允许保持的最大在线连接数。
}
