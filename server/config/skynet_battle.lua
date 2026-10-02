-- 职责：启动独立的 Lesson 2 Map/Battle Process，并提供地图查询和 cluster 路径。
-- 边界：Skynet Process Bootstrap Config；拥有地图和后续 Battle Service。
-- 输入/输出：Skynet + Native build -> battle/battle_main 进程。
-- 生命周期：进程启动时读取一次；由双进程控制脚本管理。
-- 不负责：不监听 Unity TCP/WebSocket，不拥有 FlyWow 连接。
local flywow_root = [[./third_party/skynet-flywow/]]
local skynet_root = "./third_party/skynet/"
thread = 4
harbor = 0
logger = nil
start = "battle/battle_main"
bootstrap = "snlua bootstrap"
luaservice = "./service/?.lua;" .. skynet_root .. "service/?.lua"
lualoader = skynet_root .. "lualib/loader.lua"
lua_path = "./?.lua;./lualib/?.lua;./lualib/?/init.lua;" ..
           flywow_root .. "lualib/?.lua;" ..
           skynet_root .. "lualib/?.lua;" .. skynet_root .. "lualib/?/init.lua"
lua_cpath = "./luaclib/?.so;" .. "./build/lua_battle_nav/?.so;" ..
            "./third_party/lua-protobuf-runtime/?.so;" .. skynet_root .. "luaclib/?.so"
cpath = skynet_root .. "cservice/?.so"
