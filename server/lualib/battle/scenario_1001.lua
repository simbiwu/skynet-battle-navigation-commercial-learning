-- 职责：为 batch 和 Gateway 请求构造相同的 Battle_1001 输入。
-- 边界：Server Battle Input；只生成纯 Lua 值。
-- 输入/输出：scenario_id=1001 -> 全新 Snapshot；其他 ID -> nil,BAD_SCENARIO。
-- 生命周期：每次调用都新建嵌套 table，由调用者独占。
-- 不负责：不运行寻路/AI、不读取 Unity 场景、不信任客户端战斗状态。
local M = {}

-- 只接受已发布的场景选择；每次创建独立数据，避免两次模拟共享可变状态。
-- scenario_id：客户端可提供的唯一选择值；无 I/O、无 yield。
function M.make_snapshot(scenario_id)
    if scenario_id ~= 1001 then return nil, "BAD_SCENARIO" end
    return {
        battle_id = 70001, battle_version = 1,
        map_id = 1001, map_version = 1,
        seed = 123456, tick_ms = 50, max_logic_ms = 30000,
        profiles = {
            {
                id = 1, radius_mm = 200,
                max_step_mm = 600, max_slope_permille = 1000,
                area_cost_permille = {
                    [0] = 1000, [1] = 3000, [2] = 1000, [3] = 1500,
                },
            },
        },
        units = {
            {
                id = 1001, camp = 1, agent_profile_id = 1,
                position = { x_mm = -11000, y_mm = 0, z_mm = 4000 },
                move_speed_mm_per_sec = 2500, attack_range_mm = 900,
                attack_damage = 20, attack_cooldown_ms = 1000, hp = 100,
            },
            {
                id = 2001, camp = 2, agent_profile_id = 1,
                position = { x_mm = 11000, y_mm = 0, z_mm = -4000 },
                move_speed_mm_per_sec = 2200, attack_range_mm = 900,
                attack_damage = 18, attack_cooldown_ms = 1100, hp = 100,
            },
        },
    }
end

return M
