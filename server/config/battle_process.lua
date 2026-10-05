-- 职责：Battle Skynet 进程启动配置；由 run_server.sh 直接传给 Skynet。
-- 边界：只设置进程级路径、日志和入口；业务参数仍由 config.battle 提供。
-- 相对路径：以下路径均以 Server 根目录为基准，因此启动前工作目录必须是 server/。
thread = 4
harbor = 0
logger = "./logs/battle" -- Skynet 把日志文件参数交给 FlyWow Logger；按天写入此目录。
logservice = "flywow_logger"
flywow_logger_level = "normal" -- normal 及以上级别入盘，debug 被忽略。
start = "battle/battle_main"
bootstrap = "snlua bootstrap"

luaservice = "./service/?.lua;./third_party/skynet/service/?.lua"
lualoader = "./third_party/skynet/lualib/loader.lua"
lua_path = "./?.lua;./lualib/?.lua;./lualib/?/init.lua;" ..
           "./third_party/skynet/lualib/?.lua;" ..
           "./third_party/skynet/lualib/?/init.lua;" ..
           "./third_party/skynet-flywow/navigation/lualib/?.lua;" ..
           "./third_party/skynet-flywow/logger/lualib/?.lua"
lua_cpath = "./luaclib/?.so;./third_party/lua-protobuf-runtime/?.so;" ..
            "./third_party/skynet/luaclib/?.so;" ..
            "./third_party/skynet-flywow/build/native/?.so"
cpath = "./third_party/skynet/cservice/?.so;" ..
        "./third_party/skynet-flywow/build/native/?.so"
preload = "./third_party/skynet-flywow/logger/lualib/flywow_logger_preload.lua"
