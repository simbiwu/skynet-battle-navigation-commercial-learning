-- 职责：按环境变量为指定 Skynet Service Lua State 启用 LuaPanda。
-- 边界：Debug-only Runtime Library；默认完全不启动调试器。
-- 输入/输出：service role + LUA_PANDA_* 环境变量 -> 当前 Lua State 的 LuaPanda 连接。
-- 生命周期：每个 Service Lua State 最多启动一次；Gateway/Query 使用不同端口。
-- 不负责：不下载依赖、不修改业务请求、不跨 Lua State 共享 debugger 状态。
local skynet = require "skynet"

local M = {}
local started = false

local function enabled()
    local value = os.getenv("LUA_PANDA_ENABLE")
    return value == "1" or value == "true" or value == "TRUE"
end

local function prepend_debug_paths()
    local socket_runtime = "./third_party/luasocket-runtime"
    package.path = table.concat({
        "./third_party/luapanda/?.lua",
        socket_runtime .. "/share/lua/5.4/?.lua",
        socket_runtime .. "/share/lua/5.4/?/init.lua",
        package.path,
    }, ";")
    package.cpath = table.concat({
        socket_runtime .. "/lib/lua/5.4/?.so",
        socket_runtime .. "/lib/lua/5.4/?/core.so",
        package.cpath,
    }, ";")
end

-- port 由 Service 启动入口显式传入；本模块不维护 Service 名称到端口的映射。
-- LuaPanda.start 内部使用 LuaSocket；这是 debug-only 阻塞 socket，不属于业务 Gateway 网络模型。
-- port 必须只属于当前 Lua State，不能与另一个同时运行的调试端点重复。
function M.start(port)
    if not enabled() then
        return false
    end
    assert(not started, "LuaPanda already started in this Lua State")
    port = tonumber(port)
    assert(port and port > 0 and port <= 65535, "invalid LuaPanda port")
    local host = os.getenv("LUA_PANDA_HOST") or "127.0.0.1"

    prepend_debug_paths()
    local ok_socket, socket_or_error = pcall(require, "socket.core")
    assert(ok_socket, "LuaPanda requires debug LuaSocket runtime: " .. tostring(socket_or_error))

    local panda = require "LuaPanda"
    started = true
    skynet.error("LUA_PANDA_CONNECT host=", host, " port=", port)
    panda.start(host, port)
    skynet.error("LUA_PANDA_READY port=", port)
    return true
end

return M
