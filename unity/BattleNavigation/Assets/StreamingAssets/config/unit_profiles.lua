--- 职责：聚合本进程要使用的 UnitProfile；数组顺序不作为 Profile ID。
---@type UnitProfile[]
local unit_profiles =
{
    (require "config.unit_profiles.profile1"),
    (require "config.unit_profiles.profile2"),
}
return unit_profiles
