-- 职责：接收 Battle 进程级 shutdown 命令，按依赖反方向关闭业务 Service。
-- 边界：Battle OS Process 内的控制 Service；只持有本进程 Service handle。
-- 输入/输出：configure(handles) 注入 Query/Manager/Dispatch -> shutdown 返回 true 或错误。
-- 不负责：不处理客户端请求、不直接解析 SIGTERM；超时兜底由外部脚本负责。
local cluster = require "skynet.cluster"
local skynet = require "skynet.manager"

local state = {
    configured = false,
    shutting_down = false,
    handles = nil,
}

local function configure(handles)
    assert(not state.configured, "battle shutdown already configured")
    assert(type(handles) == "table", "shutdown handles are required")
    assert(math.type(handles.query_service) == "integer" and
        math.type(handles.battle_mgr) == "integer" and
        math.type(handles.dispatcher) == "integer",
        "invalid battle shutdown handles")
    state.handles = handles
    state.configured = true
    cluster.register("battle_shutdown", skynet.self())
    return true
end

local function shutdown()
    assert(state.configured, "battle shutdown is not configured")
    if state.shutting_down then
        return true
    end
    state.shutting_down = true

    -- 先关闭入口，拒绝新请求；再关闭 Manager/Worker；最后释放 Query。
    skynet.call(state.handles.dispatcher, "lua", "shutdown")
    skynet.call(state.handles.battle_mgr, "lua", "shutdown")
    skynet.call(state.handles.query_service, "lua", "shutdown")
    skynet.error("BATTLE_SHUTDOWN_COMPLETE")
    --- 业务已完成收尾；等待 Native Logger 刷新后再向 shutdownctl 确认。
    --- flush 会 yield；写盘失败抛错误，关闭流程不能谎报成功。
    require("flywow_logger").flush()
    return true
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
            -- 让调用方先收到返回值，再结束整个 Battle Runtime。
            skynet.fork(function()
                skynet.sleep(10)
                skynet.abort()
            end)
            return
        end
        error("unknown battle shutdown command: " .. tostring(command))
    end)
end)
