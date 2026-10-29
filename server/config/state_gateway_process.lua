--- 职责：State Gateway OS进程启动配置；只装载网络/协议/Logger模块。
--- 边界：相对路径以server/为根，不在Gateway加载Battle Native或地图。
thread = 4
harbor = 0
bootstrap = "snlua bootstrap"
start = "gateway/state_sync/main"
logger = "./logs/state_gateway"
logservice = "flywow_logger"
flywow_logger_level = "normal"

luaservice = "./service/?.lua;./third_party/skynet/service/?.lua;"
    .. "./third_party/skynet-flywow/gateway/service/?.lua;"
    .. "./third_party/skynet-flywow/gateway/service/gateway/?.lua"
lualoader = "./third_party/skynet/lualib/loader.lua"
lua_path = "./?.lua;./lualib/?.lua;./lualib/?/init.lua;"
    .. "./third_party/skynet/lualib/?.lua;"
    .. "./third_party/skynet/lualib/?/init.lua;"
    .. "./third_party/skynet-flywow/common/lualib/?.lua;"
    .. "./third_party/skynet-flywow/gateway/lualib/?.lua;"
    .. "./third_party/skynet-flywow/gateway/lualib/?/init.lua;"
    .. "./third_party/skynet-flywow/logger/lualib/?.lua"
lua_cpath = "./luaclib/?.so;./third_party/lua-protobuf-runtime/?.so;"
    .. "./third_party/skynet/luaclib/?.so;"
    .. "./third_party/skynet-flywow/build/native/?.so"
cpath = "./third_party/skynet/cservice/?.so;" .. "./third_party/skynet-flywow/build/native/?.so"
preload = "./third_party/skynet-flywow/logger/lualib/flywow_logger_preload.lua"
