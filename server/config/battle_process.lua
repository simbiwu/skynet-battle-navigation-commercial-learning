-- 职责：Battle Skynet 进程启动配置；由 run_server.sh 直接传给 Skynet。
-- 边界：进程启动层；只设置 Skynet 全局启动参数，不返回 Battle 业务运行配置。
-- 使用：启动 Battle 时传入此文件；业务 Service 仍 require config.battle。
-- 不负责：不保存地图、Cluster 地址或 Battle 运行参数。
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
