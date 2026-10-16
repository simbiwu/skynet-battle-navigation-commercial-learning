--- 职责：Frame Battle OS进程启动配置；Server工作目录为所有相对路径的基准。
--- 边界：仅入口、Skynet搜索路径、进程线程数和日志；不持有Battle动态状态。
--- 不负责：Gateway监听、Unity资源读取、自动Git同步。
thread = 4
harbor = 0
bootstrap = "snlua bootstrap"
start = "battle/frame_sync/main"
debug_console_port = 8003 -- Gateway 的调试控制台端口；0 表示关闭，控制台默认只监听本机 127.0.0.1。
logger = "./logs/frame_battle"
logservice = "flywow_logger"
flywow_logger_level = "normal"
flywow_logger_console = true -- 同一日志同时写入按天文件与 stdout，终端逐条刷新。

luaservice = "./service/?.lua;./third_party/skynet/service/?.lua"
lualoader = "./third_party/skynet/lualib/loader.lua"
lua_path = "./?.lua;./lualib/?.lua;./lualib/?/init.lua;" ..
           "./third_party/skynet/lualib/?.lua;" ..
           "./third_party/skynet/lualib/?/init.lua;" ..
           "./third_party/skynet-flywow/navigation/lualib/?.lua;" ..
           "./third_party/skynet-flywow/logger/lualib/?.lua"
lua_cpath = "./build/frame_sync/?.so;" ..
            "./luaclib/?.so;./third_party/lua-protobuf-runtime/?.so;" ..
            "./third_party/skynet/luaclib/?.so;" ..
            "./third_party/skynet-flywow/build/native/?.so"
cpath = "./third_party/skynet/cservice/?.so;" ..
        "./third_party/skynet-flywow/build/native/?.so"
preload = "./third_party/skynet-flywow/logger/lualib/flywow_logger_preload.lua"
