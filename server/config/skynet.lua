-- 职责：声明当前工程的 Skynet 进程启动参数和 Lua/C 模块搜索路径。
-- 边界：Server Runtime Bootstrap；由 skynet 可执行文件在创建 Service 前读取。
-- 输入/输出：仓库内固定目录与 FlyWow 框架根目录 -> main Service 及其运行时加载路径。
-- 生命周期：进程启动时读取一次；不会进入业务 Service 的 Lua State。
-- 不负责：不加载 BMAP、不监听业务端口、不包含业务配置。
local skynet_root = "./third_party/skynet/"
-- `$FLYWOW_ROOT` 由 run_server.sh 在依赖检查后导出；Skynet 配置加载器会在执行 Lua 前替换环境变量。
local flywow_root = [[./third_party/skynet-flywow/]]

thread = 4                              -- Skynet Worker OS Thread 数；课程开发基线。
harbor = 0                              -- 第一课只运行单节点，不启用全局名字服务。
logger = nil                            -- nil 表示日志输出到标准输出。
start = "main"                          -- 首个业务 Service：service/main.lua。
bootstrap = "snlua bootstrap"           -- 使用 Skynet 标准 Lua Bootstrap。

-- flywow_gateway 和 gateway.* 均由独立框架仓库提供；业务仓库不复制这些源码。
luaservice = "./service/?.lua;" .. flywow_root .. "service/gateway/?.lua;" .. skynet_root .. "service/?.lua"
lualoader = skynet_root .. "lualib/loader.lua"
lua_path = "./?.lua;./lualib/?.lua;./lualib/?/init.lua;" ..
           flywow_root .. "lualib/?.lua;" ..
           flywow_root .. "lualib/?/init.lua;" ..
           skynet_root .. "lualib/?.lua;" ..
           skynet_root .. "lualib/?/init.lua"
lua_cpath = "./luaclib/?.so;" .. "./build/lua_battle_nav/?.so;" ..
            "./third_party/lua-protobuf-runtime/?.so;" ..
            flywow_root .. "luaclib/?.so;" .. skynet_root .. "luaclib/?.so"
cpath = skynet_root .. "cservice/?.so"
