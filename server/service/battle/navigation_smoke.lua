-- 职责：在单个 Skynet Lua State 中验证地图、Context、Path 与动态占位接线。
-- 边界：Server Test/Debug Service；不参与正式 Battle 或 Gateway 接入。
-- 输入/输出：已发布 Battle_1001 BMAP -> NAVIGATION_SMOKE_OK 或明确错误。
-- 生命周期：运行一次；查询 Service 先加载地图，本 Service 验证后退出。
-- 不负责：不计算 AI/伤害，不编写 Replay，不做性能测试。
local skynet = require "skynet"
local battle_nav = require "flywow.navigation"

-- 把 Binding 的 nil,{code,message} 合同变成可读的 Smoke 失败日志。
-- value/error 属于本次同步调用；成功返回原值，失败抛错终止此检查；不 I/O、不 yield。
local function require_nav(value, err)
    assert(value, err and (err.code .. ": " .. err.message) or "navigation call failed")
    return value
end

-- 等待同进程地图加载完成，然后在当前 Lua State 执行同步 Native 查询。
-- 无参数；成功输出 marker；启动阶段可 yield，导航调用本身不 yield。
skynet.start(function()
    -- 数据准备：先启动并等待地图查询 Service。
    local query_service = skynet.newservice("battle/navigation_query")
    assert(skynet.call(query_service, "lua", "ready"))

    local profiles = {
        {
            id = 1,
            radius_mm = 200,
            max_step_mm = 600,
            max_slope_permille = 1000,
            area_cost_permille = {
                [0] = 1000,
                [1] = 3000,
                [2] = 1000,
                [3] = 1500,
            },
        },
    }

    -- 参数/状态检查：创建本次 smoke 独占的 Native Context。
    local context = require_nav(battle_nav.new_context(1001, 1, profiles))

    local start = { x_mm = -11000, y_mm = 0, z_mm = 4000 }
    local target = { x_mm = 11000, y_mm = 0, z_mm = -4000 }

    start = require_nav(context:place_unit(1, 1001, start))
    target = require_nav(context:place_unit(1, 2001, target))

    -- 核心计算：提交路径查询并打印可复核结果。
    local path = require_nav(context:find_path_to_range(
        1,
        start,
        target,
        900,
        1001))

    print("PATH_OK count=", path:count(), " length_mm=", path:length_mm())
    for i = 1, path:count() do
        local p = path:world_point(i)
        print(i, p.x_mm, p.y_mm, p.z_mm)
    end

    -- 状态修改：验证同一 handle 的占位更新和释放。
    -- 同 Cell Move 验证首次占位仍可由同一 handle 提交；跨格移动由 Native 测试覆盖。
    start = require_nav(context:move_unit(1, 1001, start, start))
    require_nav(context:release_unit(1001))
    require_nav(context:release_unit(2001))
    context:close()
    skynet.error("NAVIGATION_SMOKE_OK")
    skynet.exit()
end)
