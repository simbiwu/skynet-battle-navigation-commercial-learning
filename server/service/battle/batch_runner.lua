-- 职责：使用共享 Battle_1001 场景两次调用 BattleMgr，验证确定性并写出 Replay。
-- 边界：Skynet Test/Batch Entry；只服务课程验收，不包含战斗规则。
-- 输入/输出：共享场景模块 -> 两次模拟结果、确定性比较和 Replay 文件。
-- 生命周期：运行一次后可退出；不作为长期在线 Gateway。
-- 不负责：不实现 AI/A*，不定义其他战斗子系统类型。
local skynet = require "skynet"
local replay_writer = require "battle.replay_writer"
local scenario = require "battle.scenario_1001"

-- 只比较逻辑字段，不用 tostring(table)；pairs/hash 地址顺序不能当 determinism 证据。
local function assert_same_result(a, b)
    assert(a.battle_id == b.battle_id)
    assert(a.battle_version == b.battle_version)
    assert(a.map_id == b.map_id and a.map_version == b.map_version)
    assert(a.seed == b.seed)
    assert(a.result == b.result)
    assert(a.end_logic_ms == b.end_logic_ms)
    assert(#a.events == #b.events)
    for i = 1, #a.events do
        local x = a.events[i]
        local y = b.events[i]
        assert(x.seq == i and y.seq == i)
        if i > 1 then
            assert(x.logic_ms >= a.events[i - 1].logic_ms)
            assert(y.logic_ms >= b.events[i - 1].logic_ms)
        end
        assert(x.seq == y.seq)
        assert(x.logic_ms == y.logic_ms)
        assert(x.type == y.type)
        assert(x.unit_id == y.unit_id)
        assert(x.attacker_id == y.attacker_id)
        assert(x.target_id == y.target_id)
        assert(x.killer_id == y.killer_id)
        assert(x.damage == y.damage)
        assert(x.target_hp == y.target_hp)
        assert(x.speed_mm_per_sec == y.speed_mm_per_sec)
        assert(x.reason == y.reason)
        assert(x.result == y.result)
        local xp, yp = x.position, y.position
        assert((xp == nil) == (yp == nil))
        if xp ~= nil then
            assert(xp.x_mm == yp.x_mm and xp.y_mm == yp.y_mm and xp.z_mm == yp.z_mm)
        end
        local xa, ya = x.points or {}, y.points or {}
        assert(#xa == #ya)
        for point = 1, #xa do
            assert(xa[point].x_mm == ya[point].x_mm)
            assert(xa[point].y_mm == ya[point].y_mm)
            assert(xa[point].z_mm == ya[point].z_mm)
        end
    end
end

skynet.start(function()
    -- Query Service 在同一进程完成地图加载；ready 返回后才创建 Worker，
    -- 避免 new_context 在空 MapRegistry 上查询。批量入口不启动 Gateway。
    local query_service = skynet.newservice("battle/navigation_query")
    assert(skynet.call(query_service, "lua", "ready"))
    local mgr = skynet.newservice("battle/battle_mgr")
    local first, err1 = skynet.call(mgr, "lua", "simulate", assert(scenario.make_snapshot(1001)))
    assert(first, err1 and err1.message)
    local second, err2 = skynet.call(mgr, "lua", "simulate", assert(scenario.make_snapshot(1001)))
    assert(second, err2 and err2.message)
    assert_same_result(first, second)
    skynet.error("BATTLE_DETERMINISM_OK events=", #first.events,
                 " end_logic_ms=", first.end_logic_ms,
                 " result=", first.result)
    local replay_ok, replay_error = replay_writer.write(
        "tmp/battle_replay.json",
        first)
    assert(replay_ok, replay_error)
    skynet.error("BATTLE_REPLAY_OK path=tmp/battle_replay.json")
end)
