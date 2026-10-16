-- 职责：为第三课的独立状态同步/帧同步进程提供一次性优雅关闭入口。
-- 边界：仅协调同一 OS Process 内已注入的 Service handle；不保存业务状态。
-- 输入：configure 注入 profile、role、Cluster endpoint 和目标 Service handles。
-- 输出：shutdownctl 调用 @<endpoint> 的 shutdown 后得到 true，再延迟终止本进程。
-- 生命周期：由课程 Battle/Gateway 组合根启动；关闭流程超时由运行脚本信号兜底。
local cluster = require "skynet.cluster"
local skynet = require "skynet.manager"

local state = {
    configured = false,
    shutting_down = false,
    profile = nil,
    role = nil,
    endpoint = nil,
    dispatcher = nil,
    gateway = nil,
    proxy = nil,
}

local function configure(options)
    assert(not state.configured, "lesson3 shutdown already configured")
    assert(type(options) == "table", "shutdown options are required")
    assert(options.profile == "state_sync" or options.profile == "frame_sync",
        "invalid lesson3 shutdown profile")
    assert(options.role == "battle" or options.role == "gateway",
        "invalid lesson3 shutdown role")
    assert(type(options.endpoint) == "string" and #options.endpoint > 0,
        "shutdown endpoint is required")

    if options.role == "battle" then
        assert(math.type(options.dispatcher) == "integer",
            "battle dispatcher handle is required")
        state.dispatcher = options.dispatcher
        assert(skynet.call(state.dispatcher, "lua", "configure_shutdown", skynet.self()))
    else
        assert(math.type(options.gateway) == "integer" and
            math.type(options.proxy) == "integer",
            "gateway and proxy handles are required")
        state.gateway = options.gateway
        state.proxy = options.proxy
        assert(skynet.call(state.proxy, "lua", "set_shutdown_coordinator", skynet.self()))
    end

    state.profile = options.profile
    state.role = options.role
    state.endpoint = options.endpoint
    cluster.register(state.endpoint, skynet.self())
    state.configured = true
    return true
end

local function shutdown()
    assert(state.configured, "lesson3 shutdown is not configured")
    if state.shutting_down then
        return true
    end
    state.shutting_down = true

    if state.role == "gateway" then
        -- Gateway 只关闭本进程内的监听、连接和 Proxy，不通知或改变 Battle 进程。
        assert(skynet.call(state.gateway, "lua", "stop"))
        assert(skynet.call(state.proxy, "lua", "shutdown"))
    else
        -- Battle Dispatch 通知 Worker 释放其拥有的 Native Battle Runtime。
        assert(skynet.call(state.dispatcher, "lua", "shutdown"))
    end

    skynet.error("LESSON3_SHUTDOWN_COMPLETE profile=", state.profile,
        " role=", state.role)
    require("flywow_logger").flush()
    return true
end

local function abort_later()
    -- 先把 RPC true 返回给 shutdownctl，并让 Logger 完成写入，再结束进程。
    skynet.fork(function()
        skynet.sleep(10)
        skynet.abort()
    end)
end

skynet.start(function()
    skynet.dispatch("lua", function(_, _, command, payload)
        if command == "configure" then
            skynet.retpack(configure(payload))
            return
        end
        if command == "ready" then
            skynet.retpack(state.configured)
            return
        end
        if command == "shutdown" then
            skynet.retpack(shutdown())
            abort_later()
            return
        end
        error("unknown lesson3 shutdown command: " .. tostring(command))
    end)
end)
