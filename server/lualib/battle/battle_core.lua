-- 职责：执行一场地面自动战斗的确定性 fixed-tick 核心模拟。
-- 边界：Server Battle Core；不 require skynet，不访问网络/DB/墙钟时间。
-- 输入/输出：已验证 snapshot + battle-local NavigationContext -> ordered BattleEvent log。
-- 生命周期：state 只属于一次 simulate；Context 由 BattleWorker 创建并独占。
-- yield：核心函数禁止任何外部 yield；Native 导航调用为同步本地调用。
-- 不负责：不处理在线输入、额外战斗子系统或在线状态同步。
local M = {}

-- 本课自动 Battle 的资源预算；超限显式失败，不让完整 Event Log 无界增长。
-- 这些是教学场景上限，扩大规模前要结合 Benchmark 和部署内存预算重新设定。
local MAX_UNITS = 128
local MAX_TICKS = 2000
local MAX_EVENTS = 20000

-- 验证一个 Lua integer 的业务范围；失败立即终止本次 simulate，由 Worker 收敛错误。
local function integer_between(value, name, minimum, maximum)
    if math.type(value) ~= "integer" or value < minimum or value > maximum then
        error(string.format("%s must be integer in [%d,%d]", name, minimum, maximum))
    end
    return value
end

-- 验证 Battle 使用的 WorldPosition。坐标限制在正负 10^9mm，保证二维距离平方不溢出 int64。
local function checked_position(value, name)
    assert(type(value) == "table", name .. " must be table")
    return {
        x_mm = integer_between(value.x_mm, name .. ".x_mm", -1000000000, 1000000000),
        y_mm = integer_between(value.y_mm, name .. ".y_mm", -1000000000, 1000000000),
        z_mm = integer_between(value.z_mm, name .. ".z_mm", -1000000000, 1000000000),
    }
end

-- 整数平方距离；WorldPosition 全部使用毫米。
local function distance2(a, b)
    local dx = a.x_mm - b.x_mm
    local dz = a.z_mm - b.z_mm
    return dx * dx + dz * dz
end

-- 深度只复制一层 WorldPosition，避免事件与后续可变 unit.position 共用同一 table。
local function copy_position(p)
    return { x_mm = p.x_mm, y_mm = p.y_mm, z_mm = p.z_mm }
end

-- 按 unit.id 排序得到稳定迭代顺序；返回新数组，不修改输入 snapshot.units。
local function sorted_units(snapshot)
    local units = {}
    for i, source in ipairs(snapshot.units) do
        local prefix = string.format("units[%d]", i)
        units[i] = {
            id = integer_between(source.id, prefix .. ".id", 1, 0x7fffffff),
            camp = integer_between(source.camp, prefix .. ".camp", 1, 0x7fffffff),
            agent_profile_id = integer_between(
                source.agent_profile_id, prefix .. ".agent_profile_id", 1, 0x7fffffff),
            position = checked_position(source.position, prefix .. ".position"),
            move_speed_mm_per_sec = integer_between(
                source.move_speed_mm_per_sec,
                prefix .. ".move_speed_mm_per_sec", 1, 1000000),
            attack_range_mm = integer_between(
                source.attack_range_mm, prefix .. ".attack_range_mm", 0, 1000000000),
            attack_damage = integer_between(
                source.attack_damage, prefix .. ".attack_damage", 1, 0x7fffffff),
            attack_cooldown_ms = integer_between(
                source.attack_cooldown_ms,
                prefix .. ".attack_cooldown_ms", 1, 0x7fffffff),
            hp = integer_between(source.hp, prefix .. ".hp", 1, 0x7fffffff),
            max_hp = source.hp,
            target_id = nil,
            next_attack_ms = 0,
            path = nil,
            need_repath = true,
            repath_not_before_ms = 0,
            last_target_position = nil,
            move_numerator_remainder = 0,
        }
    end
    table.sort(units, function(a, b) return a.id < b.id end)
    return units
end

-- 构造 id->unit 查找表；只做直接查找，不依赖 pairs() 迭代顺序。
local function index_units(units)
    local by_id = {}
    for _, unit in ipairs(units) do
        assert(by_id[unit.id] == nil, "duplicate unit id")
        by_id[unit.id] = unit
    end
    return by_id
end

-- 把事件追加到唯一 Event Log；达到预算时失败，由 Worker 关闭 Context 并返回错误。
-- state/event 只归本场 Battle 所有；seq 由 append 顺序严格递增；不 I/O、不 yield。
local function emit(state, event)
    assert(#state.events < MAX_EVENTS, "battle event limit exceeded")
    state.next_event_seq = state.next_event_seq + 1
    event.seq = state.next_event_seq
    event.logic_ms = state.logic_ms
    state.events[#state.events + 1] = event
end

-- 从全部存活敌人中选最近目标；距离相同用更小 unit.id 稳定打破平局。
local function choose_target(state, self)
    local best = nil
    local best_dist2 = nil
    for _, candidate in ipairs(state.units) do
        if candidate.hp > 0 and candidate.camp ~= self.camp then
            local d2 = distance2(self.position, candidate.position)
            if best == nil or d2 < best_dist2 or
               (d2 == best_dist2 and candidate.id < best.id) then
                best = candidate
                best_dist2 = d2
            end
        end
    end
    return best
end

-- 判断攻击者当前位置是否已经进入目标攻击范围；使用整数平方距离。
local function in_attack_range(self, target)
    local range2 = self.attack_range_mm * self.attack_range_mm
    return distance2(self.position, target.position) <= range2
end

-- Path userdata 只在 replan 点读取一次，复制成 Lua 连续世界点供后续 Tick 使用。
local function copy_path_points(path)
    local points = {}
    for i = 1, path:count() do
        points[i] = path:world_point(i)
    end
    return points
end

-- 当前目标是否相对上次规划位置移动超过一个 Grid Cell 量级。
-- 阈值由 Context 的真实 cell_size_mm 提供，不复制一份地图配置。
local function target_moved_enough(self, target, threshold_mm)
    if self.last_target_position == nil then return true end
    return distance2(self.last_target_position, target.position) >=
        threshold_mm * threshold_mm
end

-- 停止现有移动并发送权威最终位置。只有确实持有 Path 时才发事件，避免空闲 Tick 刷屏。
local function stop_movement(state, self, reason)
    if self.path == nil then return end
    self.path = nil
    emit(state, {
        type = "MOVE_STOPPED",
        unit_id = self.id,
        reason = reason,
        position = copy_position(self.position),
    })
end

-- 只在明确 trigger + cooldown 允许时重新寻路；NO_PATH 会退避而不是每 Tick 重试。
local function ensure_attack_path(state, context, self, target)
    if in_attack_range(self, target) then
        stop_movement(state, self, "IN_ATTACK_RANGE")
        self.need_repath = false
        return true, false
    end

    if target_moved_enough(self, target, state.repath_distance_mm) then
        self.need_repath = true
    end
    if not self.need_repath or state.logic_ms < self.repath_not_before_ms then
        return self.path ~= nil, false
    end

    local path, err = context:find_path_to_range(
        self.agent_profile_id,
        self.position,
        target.position,
        self.attack_range_mm,
        self.id)
    if not path then
        -- 动态拥堵或暂时 NO_PATH 不应该在 50ms 后再次全图 A*。
        self.path = nil
        self.repath_not_before_ms = state.logic_ms + 300
        emit(state, {
            type = "MOVE_STOPPED",
            unit_id = self.id,
            reason = err and err.code or "NO_PATH",
            position = copy_position(self.position),
        })
        return false, false
    end

    self.path = path
    self.need_repath = false
    self.repath_not_before_ms = state.logic_ms + 300
    self.last_target_position = copy_position(target.position)

    emit(state, {
        type = "MOVE_PATH",
        unit_id = self.id,
        speed_mm_per_sec = self.move_speed_mm_per_sec,
        points = copy_path_points(path),
    })
    -- 新 Path 在当前 tick 边界发布；从下一个 tick 才消费移动预算，Replay 时间与 Server 对齐。
    return true, true
end

-- 当前 Tick 可移动的整数毫米预算；remainder 保留除以1000的余数，避免长期速度漂移。
local function movement_budget(self, tick_ms)
    local numerator = self.move_speed_mm_per_sec * tick_ms +
        self.move_numerator_remainder
    local whole = numerator // 1000
    self.move_numerator_remainder = numerator % 1000
    return whole
end

-- 沿缓存 Path 推进一个 fixed tick。
-- Battle 只提供已经结算完成的整数毫米预算；路点游标、插值、Grid 拆步和 Occupancy
-- 提交由 Native 完成。返回 true 表示位置实际变化；函数同步执行且不 yield。
local function advance_move(state, context, self)
    if self.path == nil then return false end

    local budget = movement_budget(self, state.tick_ms)
    local advanced, err = context:advance_path({
        profile_id = self.agent_profile_id,
        unit_id = self.id,
        path = self.path,
        from_world = self.position,
        distance_mm = budget,
    })
    if advanced == nil then
        error(string.format(
            "advance_path failed unit=%d code=%s message=%s",
            self.id,
            err and err.code or "UNKNOWN",
            err and err.message or ""))
    end

    -- position 是最后一个成功提交的权威位置；blocked 也可能已经移动了一段。
    self.position = advanced.position
    if advanced.status == "blocked" then
        self.need_repath = true
        stop_movement(state, self, "MOVE_BLOCKED")
    elseif advanced.status == "reached" then
        -- Path 可能因目标在规划后移动而先结束。若仍未进入攻击范围，
        -- 下一次 cooldown 允许时重新规划，不能永久站在旧终点。
        self.need_repath = true
        stop_movement(state, self, "PATH_END")
    elseif advanced.status ~= "moving" then
        error("advance_path returned unknown status")
    end
    return advanced.moved
end

-- 执行最小普通攻击；这是固定数值的 Battle rule，不是 Skill System。
local function try_attack(state, context, self, target)
    if not in_attack_range(self, target) then return false end
    -- 无论 CD 是否已经结束，进入攻击范围后都先停止客户端正在播放的旧 Path。
    stop_movement(state, self, "IN_ATTACK_RANGE")
    self.need_repath = false
    if state.logic_ms < self.next_attack_ms then return false end

    self.next_attack_ms = state.logic_ms + self.attack_cooldown_ms
    target.hp = math.max(0, target.hp - self.attack_damage)
    emit(state, {
        type = "ATTACK",
        attacker_id = self.id,
        target_id = target.id,
        damage = self.attack_damage,
        target_hp = target.hp,
    })

    if target.hp == 0 then
        local released, release_error = context:release_unit(target.id)
        if not released then
            error(string.format(
                "release_unit failed unit=%d code=%s message=%s",
                target.id,
                release_error and release_error.code or "UNKNOWN",
                release_error and release_error.message or ""))
        end
        emit(state, {
            type = "UNIT_DEAD",
            unit_id = target.id,
            killer_id = self.id,
            position = copy_position(target.position),
        })
    end
    return true
end

local function alive_camp_count(state)
    local camps = {}
    local count = 0
    for _, unit in ipairs(state.units) do
        if unit.hp > 0 and not camps[unit.camp] then
            camps[unit.camp] = true
            count = count + 1
        end
    end
    return count
end

-- 推进一个 fixed tick；函数内禁止调用任何可能 yield 的 Skynet/网络/DB API。
function M.step(state, context)
    -- 参数/状态检查：已结束的 Battle 不允许继续推进。
    assert(state.final_result == nil, "cannot step a finished battle")
    assert(state.logic_ms < state.max_logic_ms, "cannot step past max_logic_ms")

    -- 状态修改：先提交本次 fixed tick 的逻辑时间边界。
    -- state.logic_ms 表示本次结算完成的 tick 边界；本 step 内事件时间不会倒退。
    state.logic_ms = state.logic_ms + state.tick_ms

    -- 核心计算：按稳定 unit 顺序选择目标、规划路径、移动和攻击。
    for _, self in ipairs(state.units) do
        if self.hp > 0 then
            local target = self.target_id and state.by_id[self.target_id] or nil
            if target == nil or target.hp <= 0 then
                target = choose_target(state, self)
                local old_target = self.target_id
                self.target_id = target and target.id or nil
                self.need_repath = true
                if self.target_id ~= old_target then
                    -- 旧 Path 的业务前提已经消失；即使没有新目标，也要让 Replay 停止旧移动。
                    stop_movement(state, self, "TARGET_CHANGED")
                    emit(state, {
                        type = "TARGET_CHANGED",
                        unit_id = self.id,
                        target_id = self.target_id or 0,
                    })
                end
            end

            if target ~= nil and target.hp > 0 then
                if not try_attack(state, context, self, target) then
                    local _, new_path = ensure_attack_path(
                        state, context, self, target)
                    if not new_path then
                        advance_move(state, context, self)
                    end
                    -- 移动后再次检查，进入攻击范围的同 Tick 可以立即攻击。
                    if target.hp > 0 then
                        try_attack(state, context, self, target)
                    end
                end
            end
        end
    end
end

-- 从冻结 snapshot 创建模拟状态并完成初始占位；返回值由同一 Battle owner 持有。
-- 本函数不 yield。在线驱动创建一次后可分段调用 M.step；自动驱动交给 M.simulate。
function M.create(snapshot, context)
    -- 参数/状态检查：校验 Battle 标识、时间预算和单位数量。
    assert(type(snapshot) == "table", "snapshot must be table")
    integer_between(snapshot.battle_id, "battle_id", 1, 0x7fffffff)
    integer_between(snapshot.battle_version, "battle_version", 1, 0x7fffffff)
    integer_between(snapshot.map_id, "map_id", 1, 0x7fffffff)
    integer_between(snapshot.map_version, "map_version", 1, 0x7fffffff)
    integer_between(snapshot.seed, "seed", -0x7fffffffffffffff, 0x7fffffffffffffff)
    integer_between(snapshot.tick_ms, "tick_ms", 1, 1000)
    integer_between(snapshot.max_logic_ms, "max_logic_ms", 1, 0x7fffffff)
    assert(snapshot.max_logic_ms % snapshot.tick_ms == 0,
        "max_logic_ms must be divisible by tick_ms")
    assert(snapshot.max_logic_ms // snapshot.tick_ms <= MAX_TICKS,
        "battle tick limit exceeded")
    assert(type(snapshot.units) == "table" and
        #snapshot.units > 0 and #snapshot.units <= MAX_UNITS,
        "units must be a non-empty array within limit")

    -- 数据准备：复制并排序单位，读取真实地图 Cell 尺寸。
    local units = sorted_units(snapshot)
    local cell_size_mm = integer_between(
        context:cell_size_mm(), "cell_size_mm", 1, 1000000000)
    -- 状态修改：创建本场 Battle 独占的可变状态。
    local state = {
        battle_id = assert(snapshot.battle_id),
        battle_version = snapshot.battle_version,
        map_id = snapshot.map_id,
        map_version = snapshot.map_version,
        seed = snapshot.seed,
        tick_ms = snapshot.tick_ms,
        max_logic_ms = snapshot.max_logic_ms,
        -- 从真实 GridMap 读取，不把第一课 500mm Cell 硬编码进 Battle 逻辑。
        repath_distance_mm = cell_size_mm,
        logic_ms = 0,
        next_event_seq = 0,
        units = units,
        by_id = index_units(units),
        events = {},
    }

    -- 核心计算：把每个单位放入动态占位索引并归一化位置。
    for _, unit in ipairs(units) do
        local normalized_position, err = context:place_unit(
            unit.agent_profile_id,
            unit.id,
            unit.position)
        assert(normalized_position, string.format(
            "place_unit failed unit=%d code=%s message=%s",
            unit.id,
            err and err.code or "UNKNOWN",
            err and err.message or ""))
        -- XZ 保留 snapshot 的业务位置，Y 由 Server Grid 归一；后续 Spawn/Path 使用同一高度事实。
        unit.position = normalized_position
    end
    -- 持久化/消息发送：按固定顺序写入 Battle 开始和单位出生事件。
    emit(state, {
        type = "BATTLE_BEGIN",
        battle_id = state.battle_id,
        battle_version = state.battle_version,
        map_id = state.map_id,
        map_version = state.map_version,
        seed = state.seed,
    })
    for _, unit in ipairs(state.units) do
        emit(state, {
            type = "UNIT_SPAWN",
            unit_id = unit.id,
            position = copy_position(unit.position),
        })
    end

    -- 收尾：返回由当前 Battle owner 持有的初始化状态。
    return state
end

-- 判断当前状态是否到达胜负或逻辑时限；只读、不分配、不 yield。
function M.is_finished(state)
    return state.logic_ms >= state.max_logic_ms or
        alive_camp_count(state) <= 1
end

-- 封存已经结束的 state 并生成一次 BATTLE_END；重复调用属于编程错误。
function M.finish(state)
    assert(M.is_finished(state), "cannot finish a running battle")
    assert(state.final_result == nil, "battle state already finished")
    local result = alive_camp_count(state) <= 1 and "FINISHED" or "TIMEOUT"
    state.final_result = result
    emit(state, { type = "BATTLE_END", result = result })
    return {
        battle_id = state.battle_id,
        battle_version = state.battle_version,
        map_id = state.map_id,
        map_version = state.map_version,
        seed = state.seed,
        result = result,
        end_logic_ms = state.logic_ms,
        events = state.events,
    }
end

-- 自动战斗入口：不等待墙钟时间，CPU 连续 fixed-tick 推进直到结束或达到逻辑时限。
function M.simulate(snapshot, context)
    local state = M.create(snapshot, context)

    while not M.is_finished(state) do
        M.step(state, context)
    end
    return M.finish(state)
end

return M