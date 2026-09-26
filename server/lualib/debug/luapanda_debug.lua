-- 职责：按环境变量为指定 Skynet Service Lua State 启用 LuaPanda。
-- 边界：Debug-only Runtime Library；默认完全不启动调试器。
-- 输入/输出：service role + LUA_PANDA_* 环境变量 -> 当前 Lua State 的 LuaPanda 连接。
-- 生命周期：每个 Service Lua State 最多启动一次；Gateway/Query 使用不同端口。
-- 不负责：不下载依赖、不修改业务请求、不跨 Lua State 共享 debugger 状态。
local skynet = require "skynet"

local M = {}
local started = false

local DEFAULT_PORT = {
    gateway = 8818,
    query = 8819,
}

local PORT_ENV = {
    gateway = "LUA_PANDA_GATEWAY_PORT",
    query = "LUA_PANDA_QUERY_PORT",
}

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

-- role 目前只允许 gateway/query，因为第一课核心运行链只需要跟踪这两个 Lua State。
-- LuaPanda.start 内部使用 LuaSocket；这是 debug-only 阻塞 socket，不属于业务 Gateway 网络模型。
function M.start(role)
    if not enabled() then
        return false
    end
    assert(not started, "LuaPanda already started in this Lua State")
    local default_port = assert(DEFAULT_PORT[role], "unsupported LuaPanda role: " .. tostring(role))
    local port = tonumber(os.getenv(PORT_ENV[role]) or tostring(default_port))
    assert(port and port > 0 and port <= 65535, "invalid LuaPanda port")
    local host = os.getenv("LUA_PANDA_HOST") or "127.0.0.1"

    prepend_debug_paths()
    local ok_socket, socket_or_error = pcall(require, "socket.core")
    assert(ok_socket, "LuaPanda requires debug LuaSocket runtime: " .. tostring(socket_or_error))

    local panda = require "LuaPanda"
    started = true
    skynet.error("LUA_PANDA_CONNECT role=", role, " host=", host, " port=", port)
    panda.start(host, port)
    skynet.error("LUA_PANDA_READY role=", role, " port=", port)
    return true
end

return M
