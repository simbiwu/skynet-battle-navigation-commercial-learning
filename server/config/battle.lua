-- 职责：Battle 进程唯一配置；同时提供 Skynet 启动参数、地图和 cluster 参数。
-- 边界：Server Runtime；由 run_server.sh 直接传给 Skynet，也由 Battle Service require "config.battle" 读取。
-- 输入/输出：Skynet/FlyWow/Native 路径和已发布地图 -> Battle 进程、Query、Manager、cluster 配置。
-- 生命周期：进程启动时读取；静态地图和配置在运行期只读。
-- 使用：run_server.sh start/debug 默认启动本文件；不要再为同一 Battle 进程创建第二份配置。
-- 不负责：不监听客户端 Gateway 端口、不保存客户端连接、不生成地图资产。
local flywow_root = [[./third_party/skynet-flywow/]]
local skynet_root = "./third_party/skynet/"

thread = 4
harbor = 0
logger = nil
start = "battle/battle_main"
bootstrap = "snlua bootstrap"
luaservice = "./service/?.lua;" .. skynet_root .. "service/?.lua"
lualoader = skynet_root .. "lualib/loader.lua"
lua_path = "./?.lua;./lualib/?.lua;./lualib/?/init.lua;" ..
           flywow_root .. "lualib/?.lua;" ..
           skynet_root .. "lualib/?.lua;" .. skynet_root .. "lualib/?/init.lua"
lua_cpath = "./luaclib/?.so;" .. "./build/lua_battle_nav/?.so;" ..
            "./third_party/lua-protobuf-runtime/?.so;" .. skynet_root .. "luaclib/?.so"
cpath = skynet_root .. "cservice/?.so"

return {
    map = {
        id = 1001,
        version = 1,
        bmap = "../shared/navigation/battle_1001/battle_1001.bmap",
    },
    cluster = {
        local_listen = 2528,
        service_name = "battle_dispatch",
        gateway_node = "gateway",
        gateway_address = "127.0.0.1:2527",
        gateway_proxy_service = "gateway_proxy",
        max_clients = 64,
    },
}
