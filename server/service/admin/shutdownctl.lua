-- 职责：一次性向 Gateway/Battle 的 shutdown Coordinator 发送进程级关闭命令。
-- 边界：独立 Admin OS Process；不拥有目标进程的业务状态。
-- 输入：Skynet 配置 shutdown_target=gateway|battle|all。
-- 输出：日志 SHUTDOWNCTL_OK 或 SHUTDOWNCTL_FAILED，随后退出自身 Service。
local cluster = require "skynet.cluster"
local skynet = require "skynet.manager"

local function abort_later()
    -- 延迟几个 tick，让 Cluster 响应和日志先完成，再终止一次性 Admin Runtime。
    skynet.fork(function()
        skynet.sleep(10)
        skynet.abort()
    end)
end

local targets = {
    gateway = { node = "gateway", address = "@gateway_shutdown" },
    battle = { node = "battle", address = "@battle_shutdown" },
}

local function shutdown_one(name)
    local target = assert(targets[name])
    local ok, result = pcall(
        cluster.call,
        target.node,
        target.address,
        "shutdown"
    )
    if not ok or result ~= true then
        return false, tostring(result)
    end
    return true
end

skynet.start(function()
    cluster.reload({
        gateway = "127.0.0.1:2527",
        battle = "127.0.0.1:2528",
    })

    local target = skynet.getenv("shutdown_target") or "all"
    local names
    if target == "all" then
        -- 先停 Gateway，避免 Battle 停止后仍有新请求进入。
        names = { "gateway", "battle" }
    elseif targets[target] then
        names = { target }
    else
        skynet.error("SHUTDOWNCTL_FAILED unknown target=" .. target)
        abort_later()
        return
    end

    for _, name in ipairs(names) do
        local ok, detail = shutdown_one(name)
        if not ok then
            skynet.error("SHUTDOWNCTL_FAILED target=" .. name ..
                " detail=" .. detail)
            abort_later()
            return
        end
    end

    skynet.error("SHUTDOWNCTL_OK target=" .. target)
    -- Admin 进程是一次性控制进程；业务结果已记录后终止自身 Runtime。
    abort_later()
end)
