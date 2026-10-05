-- 职责：声明当前工程的 Skynet 进程启动参数和 Lua/C 模块搜索路径。
-- 边界：Server Runtime Bootstrap；由 skynet 可执行文件在创建 Service 前读取。
-- 输入/输出：Server 根目录下的相对路径 -> main Service 及其运行时加载路径。
-- 生命周期：进程启动时读取一次；不会进入业务 Service 的 Lua State。
-- 不负责：不加载 BMAP、不监听业务端口、不包含业务配置。

thread = 4                              -- Skynet Worker OS Thread 数；课程开发基线。
harbor = 0                              -- 第一课只运行单节点，不启用全局名字服务。
logger = "./logs/server"                -- FlyWow Logger 的日志目录，以 Server 根目录为基准。
logservice = "flywow_logger"
flywow_logger_level = "normal"
start = "main"                          -- 首个业务 Service：service/main.lua。
bootstrap = "snlua bootstrap"           -- 使用 Skynet 标准 Lua Bootstrap。

-- Navigation 是本进程需要的 FlyWow 模块；Gateway Service 仅加入 Gateway 专属进程配置。
-- 单进程 Adapter 同时启动课程 Gateway 与 Navigation；生产双进程配置按角色缩小搜索路径。
luaservice = "./service/?.lua;./third_party/skynet/service/?.lua;" ..
             "./third_party/skynet-flywow/gateway/service/?.lua;" ..
             "./third_party/skynet-flywow/gateway/service/gateway/?.lua"
lualoader = "./third_party/skynet/lualib/loader.lua"
lua_path = "./?.lua;./lualib/?.lua;./lualib/?/init.lua;" ..
           "./third_party/skynet/lualib/?.lua;" ..
           "./third_party/skynet/lualib/?/init.lua;" ..
           "./third_party/skynet-flywow/gateway/lualib/?.lua;" ..
           "./third_party/skynet-flywow/gateway/lualib/?/init.lua;" ..
           "./third_party/skynet-flywow/navigation/lualib/?.lua;" ..
           "./third_party/skynet-flywow/logger/lualib/?.lua"
lua_cpath = "./luaclib/?.so;./third_party/lua-protobuf-runtime/?.so;" ..
            "./third_party/skynet/luaclib/?.so;" ..
            "./third_party/skynet-flywow/build/native/?.so"
cpath = "./third_party/skynet/cservice/?.so;" ..
        "./third_party/skynet-flywow/build/native/?.so"
preload = "./third_party/skynet-flywow/logger/lualib/flywow_logger_preload.lua"
