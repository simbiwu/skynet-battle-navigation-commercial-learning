-- 职责：定义 Unit 类型 ID=1 的 Grid Navigation 专用静态参数。
-- 边界：仅由 Navigation Native Registry 使用；不属于通用 UnitProfile。
-- 输入/输出：无输入 -> 一份 NavigationProfile record。
-- 生命周期：Battle 进程启动时整表发布；热更时完整替换 Registry 当前表。
-- 不负责：不保存 Unit 实例状态、位置、速度或占位。
return {
    unit_id = 1,
    radius_mm = 200,
    max_step_mm = 600,
    max_slope_permille = 1000,
    area_cost_permille = {
        [0] = 1000, [1] = 3000, [2] = 1000, [3] = 1500,
    },
}
