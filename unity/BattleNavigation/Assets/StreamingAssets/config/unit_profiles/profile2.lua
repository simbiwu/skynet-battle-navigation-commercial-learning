---@type UnitProfile
return
{
    unit_id = 2, -- 静态UnitProfile配置查询键；不是战斗中的单位实例ID。
    movement =
    {
        mode              = "air", -- 空中移动，不申请地面NavigationProfile。
        speed_mm_per_sec = 20000,  -- 单轴速度，毫米/秒；每个60Hz Tick约333/334mm。
    },
    max_hp = 100, -- 初始HP和最大HP。
    flight =
    {
        min_air_clearance_mm = 200,   -- 与当前位置地表至少相隔200毫米。
        max_air_altitude_mm  = 10000, -- 最高在当前位置地表上方10000毫米，不是固定高度。
        air_body =
        {
            radius_mm      = 350, -- X/Z各方向盒体半宽；动态占位与扫掠共用。
            half_height_mm = 500, -- Y方向盒体半高；中心高度仍由确定性AI改变。
        },
    },
    combat =
    {
        attack_range_mm = 9000, -- 双方中心点XZ距离上限，毫米；不加导航半径。
    },
}
