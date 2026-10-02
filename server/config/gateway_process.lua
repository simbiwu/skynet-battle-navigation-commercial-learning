-- 职责：Gateway Skynet 进程启动配置；由 run_server.sh 直接传给 Skynet。
-- 边界：进程启动层；只设置 Skynet 全局启动参数，不返回 Gateway 业务运行配置。
-- 使用：启动 Gateway 时传入此文件；业务 Service 仍 require config.gateway。
-- 不负责：不保存监听端口、协议资源上限或动态路由配置。
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
