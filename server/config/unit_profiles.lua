-- 职责：聚合进程级共享的 UnitProfile 基础配置。
-- 边界：业务配置层；由 Battle 进程入口发布到 sharedata，Navigation 不读取此表。
-- 输入/输出：各 UnitProfile 文件 -> 按 unit_id 排列的只读配置数组。
-- 生命周期：由启动入口发布到固定 sharedata key battle.unit_profiles。
-- 不负责：不定义导航专用字段，不生成或重排已发布 ID。
---@class UnitCombatProfile
---@field attack_range_mm integer 普通攻击的中心点 XZ 最大距离，整数毫米；0 表示中心重合，不读取导航半径或地图格子尺寸。

---@class UnitProfile
---@field unit_id integer 稳定 Unit 类型 ID；正整数，已使用 ID 不重排或删除。
---@field combat UnitCombatProfile 战斗基础属性；不包含导航半径。
---@type UnitProfile[]
local unit_profiles = {
    (require "config.unit_profiles.profile1"),
}
return unit_profiles
