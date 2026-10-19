-- 职责：创建固定 BattleWorker Pool，并把独立 Battle snapshot 分发到 Worker。
-- 边界：Skynet Orchestration；这里允许 skynet.call/yield，不直接修改 Battle 内部状态。
-- 输入/输出：simulate(snapshot) -> Worker 返回的 result 或 error。
-- 生命周期：Manager/Worker 长驻；snapshot 在消息发送时序列化复制。
-- 不负责：不执行 AI/A*/伤害，不保存 NavigationContext userdata。
local skynet = require "skynet"
local luapanda_debug = require "shared.debug.luapanda_debug"

local module_state =
{
    worker_handles = {}, -- 本 Manager 独占并负责关闭的 Battle Worker handles。
    next_worker_index = 1, -- round-robin 下一次分配的 Worker 下标。
    is_shutting_down = false, -- 关闭后拒绝新模拟请求。
    active_simulation_calls = 0, -- 正在等待 Worker 返回的 simulate 调用数。
}

-- 按稳定 round-robin 选择 Worker；Manager 单 Service owner 修改 module_state.next_worker_index。
local function choose_worker()
    local worker = module_state.worker_handles[module_state.next_worker_index]
    module_state.next_worker_index = module_state.next_worker_index % #module_state.worker_handles + 1
    return worker
end

-- 把纯数据 snapshot 发给一个 Worker；本函数会在 skynet.call 处 yield。
local function simulate(snapshot)
    if module_state.is_shutting_down then
        return nil, { code = "SERVER_SHUTTING_DOWN", message = "battle manager is shutting down" }
    end
    local worker = choose_worker()
    module_state.active_simulation_calls = module_state.active_simulation_calls + 1
    local ok, result, err = pcall(
        skynet.call,
        worker,
        "lua",
        "simulate",
        snapshot
    )
    module_state.active_simulation_calls = module_state.active_simulation_calls - 1
    if not ok then
        return nil, { code = "WORKER_CALL_FAILED", message = tostring(result) }
    end
    return result, err
end

local function shutdown()
    module_state.is_shutting_down = true
    while module_state.active_simulation_calls > 0 do
        skynet.sleep(1)
    end
    for _, worker in ipairs(module_state.worker_handles) do
        skynet.call(worker, "lua", "shutdown")
    end
    module_state.worker_handles = {}
    skynet.retpack(true)
    skynet.exit()
end

skynet.start(function()
    luapanda_debug.start(8822)
    local count = tonumber(skynet.getenv("battle_worker_count")) or 2
    assert(count >= 1)
    for _ = 1, count do
        module_state.worker_handles[#module_state.worker_handles + 1] = skynet.newservice("battle/battle_worker")
        skynet.call(module_state.worker_handles[#module_state.worker_handles], "lua", "debug_start", 8822 + #module_state.worker_handles)
    end

    skynet.dispatch("lua", function(_, _, command, payload)
        if command == "ready" then
            skynet.retpack(#module_state.worker_handles > 0)
            return
        end
        if command == "simulate" then
            skynet.retpack(simulate(assert(payload)))
            return
        end
        if command == "shutdown" then
            shutdown()
            return
        end
        error("unknown battle manager command: " .. tostring(command))
    end)
end)
