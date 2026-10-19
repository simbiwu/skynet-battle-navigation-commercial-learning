--- 状态同步权威模拟；每场Runtime独占Context、输入、单位和弹丸。
--- Step同步no-yield；不require Skynet，不读取socket、DB或墙钟。
--- Navigation来自FlyWow公开API，配置在进程启动时固定，战斗中不热替换。
local navigation_api = require("flywow_navigation")
local state_sync_config = require("config.state_sync")
local M = {}
-- Unit/Skill配置只维护一份源；本Lua State建立按业务ID查询的只读索引，不把数组位置当ID。
local module_state =
{
    units_by_profile_id = {}, -- 只读单位配置索引，按公开 unit_id 查找。
    skills_by_id = {}, -- 只读技能配置索引，按公开 skill_id 查找。
    skill_ids_in_order = {}, -- 按 skill_id 排序的稳定遍历顺序。
}
assert(#state_sync_config.skills >= 3 and #state_sync_config.skills <= 16, "SKILL_LIMIT") -- 每单位冷却状态和复制记录的真实容量。
for _, profile in ipairs(state_sync_config.unit_profiles) do
    assert(
        math.type(profile.unit_id) == "integer"
            and profile.unit_id > 0
            and not module_state.units_by_profile_id[profile.unit_id],
        "UNIT_PROFILE_ID"
    )
    module_state.units_by_profile_id[profile.unit_id] = profile
end
for _, skill in ipairs(state_sync_config.skills) do
    assert(
        math.type(skill.skill_id) == "integer"
            and skill.skill_id > 0
            and not module_state.skills_by_id[skill.skill_id],
        "SKILL_ID"
    )
    module_state.skills_by_id[skill.skill_id] = skill
    module_state.skill_ids_in_order[#module_state.skill_ids_in_order + 1] = skill.skill_id
end
table.sort(module_state.skill_ids_in_order)

---@class StateRuntime
---@field tick integer 已提交的60Hz逻辑Tick。
---@field context FlyWowNavigationContext 本场单owner导航Context。
---@field units table 顺序固定的实体数组。
---@field by_id table<integer,table> 本场不复用实例ID的身份索引。
---@field events table 有界事件窗口；旧事件淘汰后由全量状态覆盖。
---@field consumed integer 最后实际消费的移动输入序号。

local function copy(p)
    return { x_mm = p.x_mm, y_mm = p.y_mm, z_mm = p.z_mm }
end

local function distance2(a, b)
    local x = a.x_mm - b.x_mm
    local y = a.y_mm - b.y_mm
    local z = a.z_mm - b.z_mm
    return x * x + y * y + z * z
end

local function emit(s, value)
    s.event_seq = s.event_seq + 1
    value.event_seq = s.event_seq
    value.server_tick = s.tick
    s.events[#s.events + 1] = value
    if #s.events > state_sync_config.event_window then
        table.remove(s.events, 1)
    end
end

local function air_box(s, u)
    if u.hp == 0 then
        assert(s.context:remove_air_obstacle({ handle = u.instance_id }))
        return
    end
    local p = u.position
    local radius = assert(s.context:unit_radius_mm(u.unit_profile_id))
    assert(s.context:set_air_obstacle({
        handle = u.instance_id,
        min = { x_mm = p.x_mm - radius, y_mm = p.y_mm, z_mm = p.z_mm - radius },
        max = { x_mm = p.x_mm + radius, y_mm = p.y_mm + u.hitbox_height_mm, z_mm = p.z_mm + radius },
    }))
end

--- create失败时关闭已创建Context；返回nil,error，不泄漏半场Battle。
---@param id integer 进程分配的BattleID。
---@return StateRuntime|nil
---@return table|nil
function M.create(id)
    local ctx, err = navigation_api.new_context(1001)
    if not ctx then
        return nil, err
    end
    local s = {
        id = id,
        tick = 0,
        context = ctx,
        units = {},
        by_id = {},
        bolts = {},
        inputs = {},
        received = 0,
        consumed = 0,
        casts = {},
        cast_next = 1,
        cast_results = {},
        event_seq = 0,
        events = {},
        winner = 0,
        next_bolt = 1,
    }
    local ok, failure = pcall(function()
        local positions = {
            { x_mm = -11000, y_mm = 0, z_mm = 4000 },
            { x_mm = 11000, y_mm = 0, z_mm = -4000 },
            { x_mm = 9000, y_mm = 0, z_mm = -4000 },
        }
        local profile = assert(module_state.units_by_profile_id[1])
        assert(profile.unit_id == 1 and profile.movement.mode == "ground")
        assert(
            math.type(profile.max_hp) == "integer"
                and profile.max_hp > 0
                and profile.max_hp <= 0x7fffffff,
            "INVALID_HP"
        )
        assert(
            math.type(profile.combat.hitbox_height_mm) == "integer"
                and profile.combat.hitbox_height_mm > 0
                and profile.combat.hitbox_height_mm <= 10000,
            "INVALID_HITBOX"
        )
        assert(
            math.type(profile.movement.speed_mm_per_sec) == "integer"
                and profile.movement.speed_mm_per_sec > 0
                and profile.movement.speed_mm_per_sec <= 60 * assert(ctx:cell_size_mm()),
            "INVALID_MOVE_SPEED"
        )
        for id, skill in ipairs(state_sync_config.skills) do
            assert(
                math.type(skill.damage) == "integer"
                    and math.type(skill.range_mm) == "integer"
                    and math.type(skill.cooldown_ticks) == "integer"
                    and skill.damage > 0
                    and skill.range_mm >= 0
                    and skill.range_mm <= 30000
                    and skill.cooldown_ticks >= 1
                    and skill.cooldown_ticks <= state_sync_config.max_ticks,
                "INVALID_SKILL"
            )
            assert(
                skill.effect == "instant"
                    or skill.effect == "visual"
                    or skill.effect == "projectile",
                "INVALID_EFFECT"
            )
            if skill.effect == "projectile" then
                assert(
                    skill.projectile_speed_mm_per_sec > 0
                        and skill.projectile_speed_mm_per_sec <= 30000
                        and skill.projectile_lifetime_ticks > 0
                        and skill.projectile_lifetime_ticks <= 600
                        and skill.projectile_radius_mm >= 0
                        and skill.projectile_radius_mm <= 1000,
                    "INVALID_PROJECTILE"
                )
            end
        end
        for i, pos in ipairs(positions) do
            local uid = i == 1 and 1001 or 2000 + i - 1
            local placed, place_error = ctx:place_unit(profile.unit_id, uid, pos)
            assert(placed, place_error and place_error.code)
            local u = {
                instance_id = uid,
                unit_profile_id = profile.unit_id,
                position = placed,
                hp = profile.max_hp,
                max_hp = profile.max_hp,
                camp = i == 1 and 1 or 2,
                cooldown = {},
                speed = profile.movement.speed_mm_per_sec,
                hitbox_height_mm = profile.combat.hitbox_height_mm,
                path = nil,
                repath = 0,
            }
            for _, skill_id in ipairs(module_state.skill_ids_in_order) do
                u.cooldown[skill_id] = 0
            end
            s.units[#s.units + 1] = u
            s.by_id[uid] = u
            air_box(s, u)
        end
    end)
    if not ok then
        ctx:close()
        return nil, { code = "CREATE_FAILED", message = tostring(failure) }
    end
    return s
end

--- inputs每条表示一个1/60秒采样；按连续序号排队，重复不重复消费。
--- 全批先校验后提交；队列超窗不部分接纳。无输入Tick使用中立方向。
---@param s StateRuntime 当前Battle单owner；不I/O、不yield。
---@param batch table 最多8条连续输入record；仅成功时提交接收队列。
---@return string 稳定结果码；OK仅表示入队，消费由Snapshot水位确认。
function M.accept_inputs(s, batch)
    if s.winner ~= 0 then
        return "ENDED"
    end
    if type(batch) ~= "table" or #batch > 8 then
        return "INPUT_BATCH"
    end
    local last = s.received
    local fresh = {}
    for _, v in ipairs(batch) do
        if
            math.type(v.input_seq) ~= "integer"
            or v.input_seq < 1
            or v.input_seq > 0x7fffffff
            or math.type(v.x) ~= "integer"
            or math.type(v.z) ~= "integer"
            or math.abs(v.x) > 1
            or math.abs(v.z) > 1
        then
            return "BAD_INPUT"
        end
        if v.input_seq > last then
            if v.input_seq ~= last + 1 then
                return "INPUT_GAP"
            end
            last = v.input_seq
            fresh[#fresh + 1] = { input_seq = v.input_seq, x = v.x, z = v.z }
        elseif v.input_seq > s.consumed then
            local old = s.inputs[v.input_seq]
            if not old or old.x ~= v.x or old.z ~= v.z then
                return "CONFLICT"
            end
        end
    end
    if last - s.consumed > state_sync_config.input_window then
        return "INPUT_WINDOW"
    end
    for _, v in ipairs(fresh) do
        s.inputs[v.input_seq] = v
    end
    s.received = last
    return "OK"
end

--- 离散施法先接纳再于下一Tick执行；缓存明确的最终拒绝/执行结果。
---@param s StateRuntime 当前Battle；命令记录最多保留64项。
---@param req table cast_seq/skill_id/target_id，不接受damage或hp。
---@return table QUEUED或原结果；actual apply_tick由Step决定；不yield。
function M.accept_cast(s, req)
    if s.winner ~= 0 then
        return { code = "ENDED", cast_seq = req.cast_seq }
    end
    if math.type(req.cast_seq) ~= "integer" or req.cast_seq < 1 or req.cast_seq > 0x7fffffff then
        return { code = "BAD_CAST" }
    end
    local old = s.cast_results[req.cast_seq]
    if old then
        if old.skill_id ~= req.skill_id or old.target_id ~= req.target_id then
            return { code = "CONFLICT", cast_seq = req.cast_seq }
        end
        return { code = old.code, cast_seq = req.cast_seq, apply_tick = old.apply_tick }
    end
    if req.cast_seq < s.cast_next then
        return { code = "EXPIRED", cast_seq = req.cast_seq }
    end
    if req.cast_seq ~= s.cast_next then
        return { code = "CAST_GAP", cast_seq = req.cast_seq }
    end
    if #s.casts >= 8 then
        return { code = "CAST_QUEUE", cast_seq = req.cast_seq }
    end
    local value = {
        cast_seq = req.cast_seq,
        skill_id = req.skill_id,
        target_id = req.target_id,
        code = "QUEUED",
        apply_tick = s.tick + 1,
    }
    s.cast_results[req.cast_seq] = value
    s.casts[#s.casts + 1] = value
    s.cast_next = s.cast_next + 1
    s.cast_results[req.cast_seq - 64] = nil
    return { code = value.code, cast_seq = req.cast_seq, apply_tick = value.apply_tick }
end

local function damage(s, caster, target, skill, cast_seq)
    if target.hp == 0 then
        return
    end
    target.hp = math.max(0, target.hp - skill.damage)
    emit(s, {
        kind = "HIT",
        actor_id = caster.instance_id,
        target_id = target.instance_id,
        skill_id = skill.skill_id,
        cast_seq = cast_seq or 0,
        damage = skill.damage,
        hp = target.hp,
    })
    if target.hp == 0 then
        assert(s.context:release_unit(target.instance_id))
        air_box(s, target)
        target.path = nil
        emit(s, { kind = "DEATH", actor_id = target.instance_id })
    end
end

local function cast(s, caster, skill_id, target_id, cast_seq)
    local skill = module_state.skills_by_id[skill_id]
    local target = s.by_id[target_id]
    local code = "OK"
    if not skill then
        code = "BAD_SKILL"
    elseif caster.hp == 0 then
        code = "DEAD"
    elseif not target or target.hp == 0 or target.camp == caster.camp then
        code = "BAD_TARGET"
    elseif caster.cooldown[skill_id] > s.tick then
        code = "COOLDOWN"
    elseif distance2(caster.position, target.position) > skill.range_mm * skill.range_mm then
        code = "RANGE"
    elseif skill.effect == "projectile" and #s.bolts >= 64 then
        code = "BOLT_LIMIT"
    end
    emit(s, {
        kind = "CAST",
        actor_id = caster.instance_id,
        target_id = target_id,
        skill_id = skill_id,
        cast_seq = cast_seq or 0,
        code = code,
    })
    if code ~= "OK" then
        return code
    end
    caster.cooldown[skill_id] = s.tick + skill.cooldown_ticks
    if skill.effect ~= "projectile" then
        -- 表现弹丸的伤害在施法Tick结算；Client弹体到达不触发逻辑。
        damage(s, caster, target, skill, cast_seq)
    else
        local a, b = caster.position, target.position
        local dx, dz = b.x_mm - a.x_mm, b.z_mm - a.z_mm
        local dy = b.y_mm + target.hitbox_height_mm // 2 - a.y_mm - caster.hitbox_height_mm // 2
        -- 直线指向目标出生时的盒中心；目标移动后不会自动追踪或寻路。
        local length = math.max(1, math.floor(math.sqrt(dx * dx + dy * dy + dz * dz)))
        s.bolts[#s.bolts + 1] = {
            instance_id = s.next_bolt,
            caster_id = caster.instance_id,
            target_id = target_id,
            position = {
                x_mm = a.x_mm,
                y_mm = a.y_mm + caster.hitbox_height_mm // 2,
                z_mm = a.z_mm,
            },
            velocity_per_sec = {
                x_mm = dx * skill.projectile_speed_mm_per_sec // length,
                y_mm = dy * skill.projectile_speed_mm_per_sec // length,
                z_mm = dz * skill.projectile_speed_mm_per_sec // length,
            },
            expires_tick = s.tick + skill.projectile_lifetime_ticks - 1, -- 含施法Tick的首次推进，共计配置次数。
            born = s.tick,
            skill = skill,
            cast_seq = cast_seq,
        }
        emit(s, {
            kind = "BOLT_SPAWN",
            actor_id = caster.instance_id,
            target_id = target_id,
            skill_id = skill.skill_id,
            projectile_id = s.next_bolt,
            position = copy(s.bolts[#s.bolts].position),
        })
        s.next_bolt = s.next_bolt + 1
    end
    return code
end

local function move_player(s, u, input)
    if u.hp == 0 or not input or (input.x == 0 and input.z == 0) then
        return
    end
    local scale = input.x ~= 0 and input.z ~= 0 and 707 or 1000
    -- 单个输入代表一Tick；累计差分确保3000mm/s连续60条轴向输入移动3000mm。
    local n = input.input_seq
    local step = n * u.speed * scale // 60000 - (n - 1) * u.speed * scale // 60000
    local target = copy(u.position)
    target.x_mm = target.x_mm + input.x * step
    target.z_mm = target.z_mm + input.z * step
    local moved = s.context:move_unit(u.unit_profile_id, u.instance_id, u.position, target)
    if moved then
        u.position = moved
        air_box(s, u)
    end
end

local function ai(s, u, budget)
    if u.hp == 0 then
        return
    end
    local target = s.units[1]
    if target.hp == 0 then
        return
    end
    local skill = assert(module_state.skills_by_id[1])
    if distance2(u.position, target.position) <= skill.range_mm * skill.range_mm then
        if u.cooldown[1] <= s.tick then
            cast(s, u, 1, target.instance_id, 0)
        end
        return
    end
    if s.tick >= u.repath and budget.remaining > 0 then
        budget.remaining = budget.remaining - 1
        u.path = s.context:find_path_to_unit_range(
            u.unit_profile_id,
            u.position,
            target.unit_profile_id,
            target.position,
            u.instance_id
        )
        u.repath = s.tick + 30 -- 500ms重规划；失败也等待，避免每Tick全图查询。
    end
    if u.path then
        local stride = s.tick * u.speed // 60 - (s.tick - 1) * u.speed // 60
        local v, err = s.context:advance_path({
            unit_id = u.unit_profile_id,
            unit_instance_id = u.instance_id,
            path = u.path,
            from_world = u.position,
            distance_mm = stride,
        })
        if not v then
            error(err.code)
        end
        u.position = v.position
        air_box(s, u)
        if v.status ~= "moving" then
            u.path = nil
        end
    end
end

local function bolts(s)
    for i = #s.bolts, 1, -1 do
        local b = s.bolts[i]
        local next_pos = copy(b.position)
        for _, axis in ipairs({ "x_mm", "y_mm", "z_mm" }) do
            local speed = b.velocity_per_sec[axis]
            local age = s.tick - b.born
            next_pos[axis] = next_pos[axis] + (age + 1) * speed // 60 - age * speed // 60
        end
        local hit, err = s.context:sweep_air({
            from = b.position,
            to = next_pos,
            body = {
                radius_mm = b.skill.projectile_radius_mm,
                half_height_mm = b.skill.projectile_radius_mm,
            },
            exclude_handle = b.caster_id,
            check_terrain = true,
        })
        if not hit then
            if err.code ~= "OUT_OF_BOUNDS" then
                error(err.code)
            end
        elseif hit.kind == "dynamic" then
            local target = s.by_id[hit.handle]
            if target and target.camp ~= s.by_id[b.caster_id].camp then
                damage(s, s.by_id[b.caster_id], target, b.skill, b.cast_seq)
            end
        end
        if not hit or hit.kind ~= "clear" or s.tick >= b.expires_tick then
            emit(s, {
                kind = "BOLT_END",
                projectile_id = b.instance_id,
                actor_id = b.caster_id,
                target_id = hit and hit.handle or 0,
                skill_id = b.skill.skill_id,
            })
            table.remove(s.bolts, i)
        else
            b.position = next_pos
        end
    end
end

--- 固定顺序：输入消费、玩家移动、施法、AI、连续弹丸、胜负；失败由Worker终止整场。
---@param s StateRuntime 唯一owner推进；失败后必须整场终止，不发送半步状态。
---@param budget table|nil Worker本轮剩余A*次数；预算不足仅延后AI重规划。
---@return nil 同步/no-yield；只修改本场与显式传入的查询预算。
function M.step(s, budget)
    assert(not s.closed and s.winner == 0, "STATE_NOT_RUNNING")
    budget = budget or { remaining = 2 }
    s.tick = s.tick + 1
    local input = s.inputs[s.consumed + 1]
    if input then
        s.inputs[input.input_seq] = nil
        s.consumed = input.input_seq
    end
    move_player(s, s.units[1], input)
    for _, req in ipairs(s.casts) do
        req.apply_tick = s.tick
        req.code = cast(s, s.units[1], req.skill_id, req.target_id, req.cast_seq)
    end
    s.casts = {}
    for i = 2, #s.units do
        ai(s, s.units[i], budget)
    end
    bolts(s)
    local enemies_alive = false
    for i = 2, #s.units do
        enemies_alive = enemies_alive or s.units[i].hp > 0
    end
    if s.units[1].hp == 0 then
        s.winner = enemies_alive and 2 or 3
    elseif not enemies_alive then
        s.winner = 1
    elseif s.tick >= state_sync_config.max_ticks then
        s.winner = 3
    end
    if s.winner ~= 0 then
        emit(s, { kind = "END", code = tostring(s.winner) })
    end
end

--- 生成与Runtime无可变table别名的完整权威状态；供复制/回放使用。
---@param s StateRuntime 已提交的权威状态。
---@param seq integer 本场复制序号，由Worker单调分配。
---@return table 完整状态，与单位/弹丸可变table无别名。
function M.snapshot(s, seq)
    local value = {
        snapshot_seq = seq,
        base_seq = 0,
        server_tick = s.tick,
        consumed_input_seq = s.consumed,
        event_watermark = s.event_seq,
        winner = s.winner,
        units = {},
        bolts = {},
    }
    for _, u in ipairs(s.units) do
        value.units[#value.units + 1] = {
            instance_id = u.instance_id,
            unit_profile_id = u.unit_profile_id,
            position = copy(u.position),
            hp = u.hp,
            max_hp = u.max_hp,
            camp = u.camp,
            cooldowns = {},
        }
    end
    for index, u in ipairs(s.units) do
        for _, skill_id in ipairs(module_state.skill_ids_in_order) do
            local cooldowns = value.units[index].cooldowns
            cooldowns[#cooldowns + 1] = { skill_id = skill_id, ready_tick = u.cooldown[skill_id] }
        end
    end
    for _, b in ipairs(s.bolts) do
        value.bolts[#value.bolts + 1] = {
            instance_id = b.instance_id,
            caster_id = b.caster_id,
            target_id = b.target_id,
            position = copy(b.position),
            velocity_per_sec = copy(b.velocity_per_sec),
            expires_tick = b.expires_tick,
        }
    end
    return value
end

--- 断线清空未消费输入与施法；消费水位跳到已接收末端，重连从该水位重建。
function M.disconnect(s)
    s.inputs = {}
    s.consumed = s.received
    for _, req in ipairs(s.casts) do
        req.code = "DISCONNECTED"
    end
    s.casts = {}
end

--- 幂等关闭；显式释放Native Context，不依赖Lua GC等待。
---@param s StateRuntime 已结束/失败/超时的本场资源owner。
function M.close(s)
    if s.closed then
        return
    end
    s.closed = true
    s.context:close()
end
return M
