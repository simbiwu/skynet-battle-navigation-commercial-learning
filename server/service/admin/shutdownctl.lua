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

local profiles = {
    lesson2 = {
        gateway = { node = "gateway", address = "@gateway_shutdown", endpoint = "127.0.0.1:2527" },
        battle = { node = "battle", address = "@battle_shutdown", endpoint = "127.0.0.1:2528" },
    },
    state_sync = {
        gateway = { node = "state_gateway", address = "@state_gateway_shutdown", endpoint = "127.0.0.1:2547" },
        battle = { node = "state_battle", address = "@state_battle_shutdown", endpoint = "127.0.0.1:2548" },
    },
    frame_sync = {
        gateway = { node = "frame_gateway", address = "@frame_gateway_shutdown", endpoint = "127.0.0.1:2537" },
        battle = { node = "frame_battle", address = "@frame_battle_shutdown", endpoint = "127.0.0.1:2538" },
    },
}

local function shutdown_one(profile_targets, name)
    local target = assert(profile_targets[name])
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
    local profile = skynet.getenv("shutdown_profile") or "lesson2"
    local profile_targets = assert(profiles[profile], "unknown shutdown profile: " .. profile)
    if profile == "frame_sync" then
        -- 帧同步 Battle/Gateway 的 Cluster 地址唯一配置在 frame_sync.lua。
        -- 发布验收会改临时副本的端口；从同一配置读取可保证运行与关闭使用相同地址。
        local frame_config = require "config.frame_sync"
        profile_targets.gateway.node = frame_config.gateway_node
        profile_targets.gateway.endpoint = frame_config.gateway_address
        profile_targets.battle.node = frame_config.battle_node
        profile_targets.battle.endpoint = frame_config.battle_address
    end
    local nodes = {}
    for _, target in pairs(profile_targets) do
        nodes[target.node] = target.endpoint
    end
    cluster.reload(nodes)

    local target = skynet.getenv("shutdown_target") or "all"
    local names
    if target == "all" then
        -- 先停 Gateway，避免 Battle 停止后仍有新请求进入。
        names = { "gateway", "battle" }
    elseif profile_targets[target] then
        names = { target }
    else
        skynet.error("SHUTDOWNCTL_FAILED unknown target=" .. target)
        abort_later()
        return
    end

    for _, name in ipairs(names) do
        local ok, detail = shutdown_one(profile_targets, name)
        if not ok then
            skynet.error("SHUTDOWNCTL_FAILED target=" .. name .. " profile=" .. profile ..
                " detail=" .. detail)
            abort_later()
            return
        end
    end

    skynet.error("SHUTDOWNCTL_OK target=" .. target .. " profile=" .. profile)
    -- Admin 进程是一次性控制进程；业务结果已记录后终止自身 Runtime。
    abort_later()
end)
