-- 职责：一次性 shutdownctl Skynet 进程配置。
-- 边界：只配置 Admin Service 的加载路径和目标参数，不保存业务状态。
local skynet_root = "./third_party/skynet/"

thread = 2
harbor = 0
logger = nil
start = "admin/shutdownctl"
bootstrap = "snlua bootstrap"
shutdown_profile = "lesson2" -- lesson2、state_sync 或 frame_sync；由运行脚本按课程覆盖。
shutdown_target = "all" -- gateway、battle 或 all；all 时先关闭 Gateway。
luaservice = "./service/?.lua;" .. skynet_root .. "service/?.lua"
lualoader = skynet_root .. "lualib/loader.lua"
lua_path = "./?.lua;./lualib/?.lua;./lualib/?/init.lua;" ..
    skynet_root .. "lualib/?.lua;" ..
    skynet_root .. "lualib/?/init.lua"
lua_cpath = "./luaclib/?.so;" .. skynet_root .. "luaclib/?.so"
cpath = skynet_root .. "cservice/?.so"

