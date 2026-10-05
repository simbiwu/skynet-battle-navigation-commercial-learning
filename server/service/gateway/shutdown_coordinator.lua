-- 职责：接收 Gateway 进程级 shutdown 命令，先停止接入再关闭 Proxy。
-- 边界：Gateway OS Process 内的控制 Service；只持有本进程 Service handle。
-- 输入/输出：configure(handles) 注入 FlyWow Gateway/Proxy -> shutdown 返回 true。
-- 不负责：不处理客户端业务、不直接解析 SIGTERM。
local cluster = require "skynet.cluster"
local skynet = require "skynet.manager"

local state = {
    configured = false,
    shutting_down = false,
    handles = nil,
}

local function configure(handles)
    assert(not state.configured, "gateway shutdown already configured")
    assert(type(handles) == "table" and
        math.type(handles.gateway_service) == "integer" and
        math.type(handles.proxy_service) == "integer",
        "invalid gateway shutdown handles")
    state.handles = handles
    state.configured = true
    cluster.register("gateway_shutdown", skynet.self())
    return true
end

local function shutdown()
    assert(state.configured, "gateway shutdown is not configured")
    if state.shutting_down then
        return true
    end
    state.shutting_down = true

    -- FlyWow stop 会停止监听并关闭已有连接；随后 Proxy 不再转发。
    skynet.call(state.handles.gateway_service, "lua", "stop")
    skynet.call(state.handles.proxy_service, "lua", "shutdown")
    skynet.error("GATEWAY_SHUTDOWN_COMPLETE")
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
            -- 让 shutdownctl 先收到确认，再结束 Gateway Runtime。
            skynet.fork(function()
                skynet.sleep(10)
                skynet.abort()
            end)
            return
        end
        error("unknown gateway shutdown command: " .. tostring(command))
    end)
end)
