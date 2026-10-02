-- 职责：Battle 进程唯一配置；同时提供 Skynet 启动参数、地图和 Cluster 参数。
-- 边界：Server Runtime；由 run_server.sh 直接传给 Skynet，也由 Battle Service require "config.battle" 读取。
-- 使用：所有字段都在本文件维护；修改地图或 Cluster 参数后必须重启 Battle/Gateway 进程。
-- 不负责：不监听客户端 Gateway 端口、不保存客户端连接、不生成地图资产。
local flywow_root = [[./third_party/skynet-flywow/]]        -- 固定 FlyWow 根目录；用于加载共享 Lua 模块。
local skynet_root = "./third_party/skynet/"                 -- 固定 Skynet 根目录；路径相对 Server 工作目录。

thread = 4                                                  -- Skynet Worker OS 线程数。
harbor = 0                                                   -- 单机模式；不启用 Harbor 集群。
logger = nil                                                 -- nil 表示日志输出到标准输出。
start = "battle/battle_main"                                -- Battle 进程入口 Service。
bootstrap = "snlua bootstrap"                               -- Skynet 标准 Lua Bootstrap。
luaservice = "./service/?.lua;" .. skynet_root .. "service/?.lua" -- Battle Service 搜索路径。
lualoader = skynet_root .. "lualib/loader.lua"              -- 固定 Skynet Lua loader。
lua_path = "./?.lua;./lualib/?.lua;./lualib/?/init.lua;" ..
           flywow_root .. "lualib/?.lua;" ..
           skynet_root .. "lualib/?.lua;" .. skynet_root .. "lualib/?/init.lua" -- Lua 模块搜索路径。
lua_cpath = "./luaclib/?.so;" .. "./build/lua_battle_nav/?.so;" ..
            "./third_party/lua-protobuf-runtime/?.so;" .. skynet_root .. "luaclib/?.so" -- C 模块搜索路径。
cpath = skynet_root .. "cservice/?.so"                       -- Skynet C Service 动态库搜索路径。

return {
    map = {
        id = 1001,                                           -- BMAP Header 中的业务地图 ID。
        version = 1,                                         -- 地图版本；必须与 BMAP Header 和发布合同一致。
        bmap = "../shared/navigation/battle_1001/battle_1001.bmap", -- 已发布 BMAP 路径；相对 Server 工作目录。
    },
    cluster = {
        local_listen = 2528,                                 -- Battle Cluster 监听端口；Gateway 连接此端口。
        service_name = "battle_dispatch",                    -- Gateway 发起请求的 Cluster Service 名。
        gateway_node = "gateway",                            -- Gateway Cluster 节点名；Battle 回推使用。
        gateway_address = "127.0.0.1:2527",                 -- Gateway Cluster 地址；格式为 host:port。
        gateway_proxy_service = "gateway_proxy",             -- Gateway 接收 Battle 结果的 Service 名。
        max_clients = 64,                                    -- Battle Cluster 连接上限。
    },
}
