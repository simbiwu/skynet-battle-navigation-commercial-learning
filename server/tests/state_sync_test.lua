--- 真正的FlyWow Navigation及状态同步Runtime回归；不以替身替代领域行为。
local root = assert(arg[1])
package.path = root
    .. "/?.lua;"
    .. root
    .. "/lualib/?.lua;"
    .. root
    .. "/third_party/skynet-flywow/navigation/lualib/?.lua;"
    .. package.path
package.cpath = root .. "/third_party/skynet-flywow/build/native/?.so;" .. package.cpath
local nav = require("flywow_navigation")
assert(nav.load_navigation_profiles(require("config.navigation_profiles")))
local loaded = assert(nav.load_map(root .. "/../shared/navigation/battle_1001/battle_1001.bmap"))
assert(loaded.content_sha256 == require("config.state_sync_asset").map_hash)
local core = require("battle.state_sync.runtime")
local a = assert(core.create(1))
local b = assert(core.create(2))
local start = b.units[1].position.x_mm
assert(core.accept_inputs(a, { { input_seq = 2, x = 1, z = 0 } }) == "INPUT_GAP")
assert(a.received == 0)
assert(core.accept_inputs(a, { { input_seq = 1, x = 2, z = 0 } }) == "BAD_INPUT")
assert(core.accept_inputs(a, { { input_seq = 1, x = 1, z = 0 } }) == "OK")
assert(core.accept_inputs(a, { { input_seq = 1, x = -1, z = 0 } }) == "CONFLICT")
assert(core.accept_inputs(a, { { input_seq = 1, x = 1, z = 0 } }) == "OK")
core.step(a)
assert(a.consumed == 1 and a.units[1].position.x_mm == start + 50)
assert(b.units[1].position.x_mm == start, "Battle Context/state cannot leak")
local moved = a.units[1].position.x_mm
core.step(a)
assert(a.units[1].position.x_mm == moved, "missing input must be neutral")
local request = { cast_seq = 1, skill_id = 1, target_id = 2001 }
assert(core.accept_cast(a, request).code == "QUEUED")
assert(core.accept_cast(a, request).code == "QUEUED")
assert(core.accept_cast(a, { cast_seq = 1, skill_id = 2, target_id = 2001 }).code == "CONFLICT")
core.step(a)
assert(core.accept_cast(a, request).code == "RANGE")
assert(#a.casts == 0)
local old = core.snapshot(a, 1)
assert(core.accept_inputs(a, { { input_seq = 2, x = 1, z = 0 } }) == "OK")
core.step(a)
assert(old.units[1].position.x_mm == moved, "Snapshot must not alias mutable unit")
local replication = require("battle.state_sync.replication")
local full = core.snapshot(a, 2)
local delta = replication.delta(full, old)
assert(delta.base_seq == 1 and #delta.units > 0)
assert(replication.delta(full, nil).base_seq == 0)
core.disconnect(a)
assert(a.consumed == a.received and next(a.inputs) == nil)
core.close(a)
core.close(a)
local value, error_value = a.context:cell_size_mm()
assert(value == nil and error_value.code == "CONTEXT_CLOSED")
-- 三种正式技能从Cast入口进入，伤害由Server产生，重复请求不重复结算。
local c = assert(core.create(3))
local player, enemy = c.units[1], c.units[2]
assert(c.context:release_unit(enemy.instance_id))
enemy.position = assert(
    c.context:place_unit(
        enemy.unit_profile_id,
        enemy.instance_id,
        {
            x_mm = player.position.x_mm + 600,
            y_mm = player.position.y_mm,
            z_mm = player.position.z_mm,
        }
    )
)
assert(c.context:set_air_obstacle({
    handle = enemy.instance_id,
    min = {
        x_mm = enemy.position.x_mm - 200,
        y_mm = enemy.position.y_mm,
        z_mm = enemy.position.z_mm - 200,
    },
    max = {
        x_mm = enemy.position.x_mm + 200,
        y_mm = enemy.position.y_mm + 1000,
        z_mm = enemy.position.z_mm + 200,
    },
}))
assert(
    core.accept_cast(c, { cast_seq = 1, skill_id = 1, target_id = enemy.instance_id }).code
        == "QUEUED"
)
core.step(c)
assert(enemy.hp == 86)
assert(
    core.accept_cast(c, { cast_seq = 1, skill_id = 1, target_id = enemy.instance_id }).code == "OK"
)
core.step(c)
assert(enemy.hp == 86, "duplicate cast cannot apply damage twice")
assert(
    core.accept_cast(c, { cast_seq = 2, skill_id = 2, target_id = enemy.instance_id }).code
        == "QUEUED"
)
core.step(c)
assert(enemy.hp == 74, "visual projectile settles at accepted cast Tick")
assert(
    core.accept_cast(c, { cast_seq = 3, skill_id = 3, target_id = enemy.instance_id }).code
        == "QUEUED"
)
core.step(c)
assert(enemy.hp == 74 and #c.bolts == 1, "logical projectile cannot settle at launch")
for _ = 1, 10 do
    core.step(c)
end
assert(enemy.hp == 54 and #c.bolts == 0, "continuous sweep decides projectile hit")
core.close(c)
core.close(b)
print("STATE_CORE_TEST_OK")
