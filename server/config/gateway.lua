-- 职责：Gateway 进程唯一配置；同时提供 Skynet 启动参数和 Gateway Service 运行参数。
-- 边界：Server Runtime；由 run_server.sh 直接传给 Skynet，也由 Gateway Service require "config.gateway" 读取。
-- 输入/输出：仓库内固定 Skynet/FlyWow 路径 -> Gateway 进程、cluster 和 FlyWow 监听配置。
-- 生命周期：进程启动时读取；Service 启动后只读，不保存连接或业务状态。
-- 使用：run_server.sh start/debug 默认启动本文件；不要再为同一 Gateway 进程创建第二份配置。
-- 不负责：不生成协议、不创建 Service、不解析客户端请求、不保存动态路由。
local skynet_root = "./third_party/skynet/"
local flywow_root = [[./third_party/skynet-flywow/]]

thread = 4
harbor = 0
logger = nil
start = "gateway/gateway_main"
bootstrap = "snlua bootstrap"
luaservice = "./service/?.lua;" .. flywow_root .. "service/gateway/?.lua;" .. skynet_root .. "service/?.lua"
lualoader = skynet_root .. "lualib/loader.lua"
lua_path = "./?.lua;./lualib/?.lua;./lualib/?/init.lua;" ..
           flywow_root .. "lualib/?.lua;" .. flywow_root .. "lualib/?/init.lua;" ..
           skynet_root .. "lualib/?.lua;" .. skynet_root .. "lualib/?/init.lua"
lua_cpath = "./luaclib/?.so;" .. flywow_root .. "luaclib/?.so;" ..
            "./third_party/lua-protobuf-runtime/?.so;" .. skynet_root .. "luaclib/?.so"
cpath = skynet_root .. "cservice/?.so"

return {
    host = "127.0.0.1",
    port = 19001,
    backlog = 128,
    transport = "tcp",
    websocket_protocol = "ws",
    descriptor_path = "../shared/protocol/generated/server/navigation_query.pb",
    registry_module = "gateway.protocol.navigation_registry",
    protocol_version = 3,
    max_frame_bytes = 0xffff,
    read_timeout_ticks = 3000,
    idle_timeout_ticks = 30000,
    max_requests_per_second = 200,
    max_total_requests_per_second = 10000,
    max_pending_handshakes = 128,
    handshake_timeout_ticks = 1000,
    max_clients = 1024,
    write_warning_close_kb = 1024,

    gateway = {
        host = "127.0.0.1",
        port = 19011,
        transport = "tcp",
    },
    cluster = {
        local_node = "gateway",
        proxy_service = "gateway_proxy",
        local_listen = 2527,
        remote_node = "battle",
        remote_service = "battle_dispatch",
        remote_address = "127.0.0.1:2528",
        max_clients = 64,
    },
}
