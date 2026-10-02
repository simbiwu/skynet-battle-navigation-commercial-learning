-- 职责：Gateway 进程唯一配置；同时提供 Skynet 启动参数和 FlyWow Gateway 运行参数。
-- 边界：Server Runtime；由 run_server.sh 直接传给 Skynet，也由 Gateway Service require "config.gateway" 读取。
-- 使用：所有字段都在本文件维护；修改监听或 cluster 参数后必须重启 Gateway/Battle 进程。
-- 不负责：不生成协议、不创建 Service、不解析客户端请求、不保存动态路由。
local skynet_root = "./third_party/skynet/"                 -- 固定 Skynet 根目录；路径相对 Server 工作目录。
local flywow_root = [[./third_party/skynet-flywow/]]        -- 固定 FlyWow 根目录；不读取外部环境变量。

thread = 4                                                  -- Skynet Worker OS 线程数；影响同一进程的消息调度并行度。
harbor = 0                                                   -- 单机模式；不启用 Skynet Harbor 集群。
logger = nil                                                 -- nil 表示日志输出到标准输出，由 run_server 日志接管。
start = "gateway/gateway_main"                              -- 进程入口 Service；负责组装 Proxy 和 FlyWow Gateway。
bootstrap = "snlua bootstrap"                               -- Skynet 标准 Lua Bootstrap。
luaservice = "./service/?.lua;" .. flywow_root .. "service/gateway/?.lua;" .. skynet_root .. "service/?.lua" -- Service 搜索路径。
lualoader = skynet_root .. "lualib/loader.lua"              -- 使用固定 Skynet Lua loader。
lua_path = "./?.lua;./lualib/?.lua;./lualib/?/init.lua;" ..
           flywow_root .. "lualib/?.lua;" .. flywow_root .. "lualib/?/init.lua;" ..
           skynet_root .. "lualib/?.lua;" .. skynet_root .. "lualib/?/init.lua" -- Lua 模块搜索路径。
lua_cpath = "./luaclib/?.so;" .. flywow_root .. "luaclib/?.so;" ..
            "./third_party/lua-protobuf-runtime/?.so;" .. skynet_root .. "luaclib/?.so" -- C 模块搜索路径。
cpath = skynet_root .. "cservice/?.so"                       -- Skynet C Service 动态库搜索路径。

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
