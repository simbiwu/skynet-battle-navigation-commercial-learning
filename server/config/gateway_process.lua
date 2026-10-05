-- 职责：Gateway Skynet 进程启动配置；由 run_server.sh 直接传给 Skynet。
-- 边界：只设置进程级路径、日志和入口；业务参数仍由 config.gateway 提供。
-- 相对路径：以下路径均以 Server 根目录为基准，因此启动前工作目录必须是 server/。
thread = 4
harbor = 0
logger = "./logs/gateway" -- Skynet 把日志文件参数交给 FlyWow Logger；按天写入此目录。
logservice = "flywow_logger"
flywow_logger_level = "normal" -- normal 及以上级别入盘，debug 被忽略。
start = "gateway/gateway_main"
bootstrap = "snlua bootstrap"

-- Service 文件分散在 Server、Skynet 和 FlyWow Gateway；Skynet 按顺序查找。
luaservice = "./service/?.lua;./third_party/skynet/service/?.lua;" ..
             "./third_party/skynet-flywow/gateway/service/?.lua;" ..
             "./third_party/skynet-flywow/gateway/service/gateway/?.lua"
lualoader = "./third_party/skynet/lualib/loader.lua"
lua_path = "./?.lua;./lualib/?.lua;./lualib/?/init.lua;" ..
           "./third_party/skynet/lualib/?.lua;" ..
           "./third_party/skynet/lualib/?/init.lua;" ..
           "./third_party/skynet-flywow/gateway/lualib/?.lua;" ..
           "./third_party/skynet-flywow/gateway/lualib/?/init.lua;" ..
           "./third_party/skynet-flywow/logger/lualib/?.lua"
lua_cpath = "./luaclib/?.so;./third_party/lua-protobuf-runtime/?.so;" ..
            "./third_party/skynet/luaclib/?.so;" ..
            "./third_party/skynet-flywow/build/native/?.so"
cpath = "./third_party/skynet/cservice/?.so;" ..
        "./third_party/skynet-flywow/build/native/?.so"

-- Logger 的 Lua 适配在每个 Lua State 启动时加载，skynet.error API 保持不变。
preload = "./third_party/skynet-flywow/logger/lualib/flywow_logger_preload.lua"
