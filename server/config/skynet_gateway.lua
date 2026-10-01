-- 职责：启动独立的 Lesson 2 Gateway Process，并提供 FlyWow 搜索路径。
-- 边界：Skynet Process Bootstrap Config；不加载地图或 Battle Service。
-- 输入/输出：FLYWOW_ROOT + Skynet -> gateway/gateway_main 进程。
-- 生命周期：进程启动时读取一次；由双进程控制脚本管理。
-- 不负责：不生成协议、不修改 shared 资产。
local skynet_root = "./third_party/skynet/"
local flywow_root = "$FLYWOW_ROOT"
thread = 4
harbor = 0
logger = nil
start = "gateway/gateway_main"
bootstrap = "snlua bootstrap"
luaservice = "./service/?.lua;" .. flywow_root .. "/service/?.lua;" .. skynet_root .. "service/?.lua"
lualoader = skynet_root .. "lualib/loader.lua"
lua_path = "./?.lua;./lualib/?.lua;./lualib/?/init.lua;" ..
           flywow_root .. "/lualib/?.lua;" .. flywow_root .. "/lualib/?/init.lua;" ..
           skynet_root .. "lualib/?.lua;" .. skynet_root .. "lualib/?/init.lua"
lua_cpath = "./luaclib/?.so;" .. "./third_party/lua-protobuf-runtime/?.so;" .. skynet_root .. "luaclib/?.so"
cpath = skynet_root .. "cservice/?.so"
