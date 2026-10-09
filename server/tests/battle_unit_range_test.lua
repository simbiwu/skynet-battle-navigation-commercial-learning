-- 职责：真实 Native Context 下验证攻击中心距与导航体型互不混用。
-- 输入：Server 根、已发布 BMAP；独立解释器执行，不启动服务或写 Replay。
local root = assert(arg[1])
local flywow = root .. "/third_party/skynet-flywow"
package.path = root .. "/lualib/?.lua;" .. flywow .. "/navigation/lualib/?.lua;" .. package.path
package.cpath = flywow .. "/build/native/?.so;" .. package.cpath
local navigation = require "flywow_navigation"
local battle = require "battle.battle_core"
assert(navigation.load_map(assert(arg[2])))
local navigation_profiles = {
    {unit_id=1,radius_mm=100,max_step_mm=1000,max_slope_permille=1000},
    {unit_id=2,radius_mm=600,max_step_mm=1000,max_slope_permille=1000},
}
assert(navigation.load_navigation_profiles(navigation_profiles))
local function unit_profiles(range)
    return {
        {unit_id=1,combat={attack_range_mm=range}},
        {unit_id=2,combat={attack_range_mm=range}},
    }
end
local function unit(id, profile, x)
    return {id=id,camp=id,unit_id=profile,position={x_mm=x,y_mm=0,z_mm=1250},
        move_speed_mm_per_sec=1000,attack_damage=10,attack_cooldown_ms=100,hp=100}
end
local function snapshot(distance)
    return {battle_id=1,battle_version=1,map_id=17,seed=1,tick_ms=50,
        max_logic_ms=1000,units={unit(1,1,250),unit(2,2,250+distance)}}
end
local function has_event(state, kind)
    for _, e in ipairs(state.events) do
        if e.type == kind then return true end
    end
    return false
end
-- 中心距刚好等于攻击范围时可攻击；导航半径不加进战斗距离。
local context = assert(navigation.new_context(17))
local state = battle.create(snapshot(1000), context, unit_profiles(1000))
battle.step(state, context, unit_profiles(1000))
assert(state.units[1].hp < 100 and state.units[2].hp < 100)
assert(not has_event(state, "MOVE_PATH"))
context:close()
-- 中心距 1000、攻击范围 999：即使双方导航半径之和只有 700，也不能提前攻击。
context = assert(navigation.new_context(17))
state = battle.create(snapshot(1000), context, unit_profiles(999))
battle.step(state, context, unit_profiles(999))
assert(state.units[1].hp == 100 and state.units[2].hp == 100)
context:close()
-- 导航接近查询只用半径 100+600，不接收攻击范围；中心距 1500 不会因此被判为可攻击。
context = assert(navigation.new_context(17))
state = battle.create(snapshot(1500), context, unit_profiles(300))
battle.step(state, context, unit_profiles(300))
assert(state.units[1].hp == 100 and state.units[2].hp == 100)
assert(state.units[1].path and state.units[1].path:status() == "reached")
context:close()
-- 零攻击距离按字面表示中心重合，不借用 Grid 对角线容差。
context = assert(navigation.new_context(17))
state = battle.create(snapshot(1400), context, unit_profiles(0))
battle.step(state, context, unit_profiles(0))
assert(state.units[1].hp == 100 and state.units[2].hp == 100)
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
    local ctx = assert(navigation.new_context(17))
    local result = battle.simulate(snapshot(1500), ctx, unit_profiles(300))
    ctx:close()
    return encode(result)
end
assert(simulate() == simulate())
print("BATTLE_UNIT_RANGE_OK")
