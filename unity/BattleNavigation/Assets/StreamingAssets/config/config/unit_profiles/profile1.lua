---@type UnitProfile
return
{
    unit_id = 1, -- 静态UnitProfile配置查询键；不是战斗中的单位实例ID。
    movement =
    {
        mode              = "ground", -- 地面单位按地图高度移动，并使用对应NavigationProfile。
        speed_mm_per_sec = 3000,      -- 单轴速度，毫米/秒；每个60Hz Tick约50mm。
    },
    max_hp = 100, -- 初始HP和最大HP。
    combat =
    {
        hitbox_height_mm = 1000, -- 当前地面角色碰撞盒高度，毫米；半宽复用NavigationProfile半径。
        attack_range_mm = 900, -- 双方中心点XZ距离上限，毫米；不加导航半径。
    },
}
