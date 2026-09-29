-- 职责：拥有一个 Skynet Battle Worker Lua State，并为每次模拟创建 battle-local NavigationContext。
-- 边界：Skynet Service Adapter；dispatch 外层可以与 Skynet 交互，battle_core.simulate 内 no-yield。
-- 输入/输出：可序列化 snapshot -> 可序列化 battle result/event log。
-- 生命周期：Service 长驻；NavigationContext 只覆盖一次 simulate，结束后 close。
-- 不负责：不监听网络、不访问 DB、不在核心模拟中 skynet.call。
local skynet = require "skynet"
local battle_nav = require "battle_nav"
local battle_core = require "battle.battle_core"

-- 为一次可序列化 snapshot 创建并独占 Context，然后连续模拟到结束。
-- 成功返回 result；创建或核心失败返回 nil,error；核心阶段不 I/O、不 yield。
local function simulate(snapshot)
    local context, err = battle_nav.new_context(
        snapshot.map_id,
        snapshot.map_version,
        snapshot.profiles)
    if not context then
        return nil, {
            code = err and err.code or "CONTEXT_CREATE_FAILED",
            message = err and err.message or "new_context failed",
        }
    end

    -- 从这里进入核心状态推进。battle_core 不 require skynet，也没有外部 yield 点。
    local ok, result = xpcall(
        battle_core.simulate,
        debug.traceback,
        snapshot,
        context)

    context:close()
    if not ok then
        return nil, { code = "SIMULATE_FAILED", message = result }
    end
    return result
end

skynet.start(function()
    skynet.dispatch("lua", function(_, _, command, payload)
        if command == "simulate" then
            skynet.retpack(simulate(assert(payload)))
            return
        end
        error("unknown battle worker command: " .. tostring(command))
    end)
end)