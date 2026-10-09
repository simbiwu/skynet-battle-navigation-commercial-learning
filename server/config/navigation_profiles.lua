-- 职责：聚合 Navigation 独占的静态通行参数。
-- 边界：仅 Battle Navigation 使用；完整 UnitProfile 由 config.unit_profiles 独立提供。
-- 输入/输出：各 NavigationProfile 文件 -> 按 unit_id 排列的配置数组。
-- 生命周期：进程启动时一次完整发布；更新时以完整新表替换 Registry 当前值。
-- 不负责：不保存 Battle/Unit 实例运行时属性。
---@class NavigationProfile
---@field unit_id integer 对应通用 UnitProfile.unit_id；正整数且不能重复。
---@field radius_mm integer 地面体型半径，毫米。
---@field max_step_mm integer 相邻 Cell 最大高差，毫米。
---@field max_slope_permille integer 坡度上限；1000 表示高差等于水平距离。
---@field area_cost_permille? table<integer,integer> Area 成本；未配置默认 1000。
---@field area_allowed? table<integer,boolean> Area 通行开关；未配置采用 Native 默认。
---@type NavigationProfile[]
local navigation_profiles = {
    (require "config.navigation_profiles.profile1"),
}
return navigation_profiles
