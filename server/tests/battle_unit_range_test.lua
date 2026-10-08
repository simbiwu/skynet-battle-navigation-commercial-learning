-- 职责：使用真实导航 Context 验证 Battle 的边缘射程与确定性。
-- 输入：Server 根、BMAP 路径；独立解释器执行，不启动服务或写 Replay。
local root = assert(arg[1])
local flywow = root .. "/third_party/skynet-flywow"
package.path = root .. "/lualib/?.lua;" .. flywow .. "/navigation/lualib/?.lua;" .. package.path
package.cpath = flywow .. "/build/native/?.so;" .. package.cpath
local navigation = require "flywow_navigation"
local battle = require "battle.battle_core"
assert(navigation.load_map(assert(arg[2])))
local profiles = {
    {id=1,radius_mm=100,max_step_mm=1000,max_slope_permille=1000},
    {id=2,radius_mm=600,max_step_mm=1000,max_slope_permille=1000},
}
local function unit(id, profile, x, range)
    return {id=id,camp=id,agent_profile_id=profile,position={x_mm=x,y_mm=0,z_mm=1250},
        move_speed_mm_per_sec=1000,attack_range_mm=range,attack_damage=10,
        attack_cooldown_ms=100,hp=100}
end
local function snapshot(distance, range)
    return {battle_id=1,battle_version=1,map_id=17,map_version=2,seed=1,tick_ms=50,
        max_logic_ms=1000,profiles=profiles,units={unit(1,1,250,range),unit(2,2,250+distance,range)}}
end
local function has_event(state, kind)
    for _, e in ipairs(state.events) do
        if e.type == kind then return true end
    end
    return false
end
-- 中心距离 1000、双方半径 700、边缘间距 300：两种正射程都能原地攻击。
for _, range in ipairs({300, 1000}) do
    local context = assert(navigation.new_context(17,2,profiles))
    local state = battle.create(snapshot(1000, range), context)
    battle.step(state, context)
    assert(state.units[1].hp < 100 and state.units[2].hp < 100)
    assert(not has_event(state, "MOVE_START"))
    context:close()
end
-- 刚好超出正射程时，先取得单位边缘路线，不能原地造成伤害。
local context = assert(navigation.new_context(17,2,profiles))
local state = battle.create(snapshot(1500,300),context)
battle.step(state,context)
assert(state.units[1].hp == 100 and state.units[2].hp == 100)
assert(state.units[1].path and state.units[1].path:status() == "reached")
context:close()
-- 零射程采用同一 Grid 对角线容差，距离 1400 <= 700+708。
context = assert(navigation.new_context(17,2,profiles))
state = battle.create(snapshot(1400,0),context)
battle.step(state,context)
assert(state.units[1].hp < 100 and state.units[2].hp < 100)
context:close()
-- 重放事件关键字段及位置在两个独立 Context 中一致。
local function encode(value)
    if type(value) ~= "table" then return tostring(value) end
    local keys = {}
    for k in pairs(value) do keys[#keys+1] = k end
    table.sort(keys, function(a,b) return tostring(a) < tostring(b) end)
    local out = {}
    for _, k in ipairs(keys) do out[#out+1] = tostring(k) .. "=" .. encode(value[k]) end
    return "{" .. table.concat(out, ",") .. "}"
end
local function simulate()
    local ctx = assert(navigation.new_context(17,2,profiles))
    local result = battle.simulate(snapshot(1500,300),ctx)
    ctx:close()
    return encode(result)
end
assert(simulate() == simulate())
print("BATTLE_UNIT_RANGE_OK")
