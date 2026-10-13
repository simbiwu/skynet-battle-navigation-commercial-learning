// 职责：实现第三课帧同步确定性模拟、FlyWow导航复用、Checkpoint V3与C ABI。
// 边界：Battle
// Native；地图/导航来自FlyWow，玩法来自宿主，本文件不访问网络/Skynet/Lua。
// 输入/输出：每帧单席位输入 ->
// State/诊断Checkpoint；持有每场私有NavigationContext。
// 不负责：账户身份授权、BMAP SHA256部署校验、Unity渲染、Native热替换。
#include "frame_core.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <utility>

namespace
{
std::shared_ptr<const lesson_frame::ProfileSnapshot> g_profiles;
}

namespace lesson_frame
{
namespace
{
constexpr std::int64_t  kPositionLimit = 500000000;
constexpr std::uint32_t kRepathDelay   = 30; // 500ms重规划间隔；60 Tick/s下为30帧。
constexpr std::uint32_t kBlockedRetry  = 12; // 200ms阻挡重试间隔；60 Tick/s下为12帧。

std::int64_t strideForAxes(std::uint32_t speed_mm_per_sec, std::int32_t axis_count,
                           std::uint32_t zero_based_frame)
{
    if (axis_count == 0)
        return 0;
    // 对角方向用整数千分比近似单位向量，避免多轴合成速度变快。
    const std::uint32_t scale_permille =
        axis_count == 1 ? 1000 : axis_count == 2 ? 707 : 577;
    const std::uint64_t denominator = kTickRateHz * 1000ULL;
    const std::uint64_t scaled_speed =
        static_cast<std::uint64_t>(speed_mm_per_sec) * scale_permille;
    // 用累计距离之差分配每帧整数毫米，避免每帧独立取整造成长期速度漂移。
    const std::uint64_t before =
        static_cast<std::uint64_t>(zero_based_frame) * scaled_speed / denominator;
    const std::uint64_t after =
        (static_cast<std::uint64_t>(zero_based_frame) + 1) * scaled_speed / denominator;
    return static_cast<std::int64_t>(after - before);
}

std::int32_t sign(std::int64_t n)
{
    return (n > 0) - (n < 0);
}
std::int64_t absolute(std::int64_t n)
{
    return n < 0 ? -n : n;
}
std::int64_t distance2(const Unit &a, const Unit &b)
{
    const auto dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
    return dx * dx + dy * dy + dz * dz; // 输入边界保证绝对坐标有界。
}
flywow_navigation::WorldPosition position(const Unit &unit)
{
    return {unit.x, unit.y, unit.z};
}
const UnitProfile &profileFor(const UnitProfileTable &profiles, std::uint32_t unit_id)
{
    // 配置发布前按 unit_id 排序；所有单位只查这一张不可变表。
    const auto found = std::lower_bound(profiles.begin(), profiles.end(), unit_id,
                                        [](const UnitProfile &profile, std::uint32_t id)
                                        { return profile.unit_id < id; });
    if (found == profiles.end() || found->unit_id != unit_id)
    {
        throw std::runtime_error("UNIT_PROFILE_NOT_FOUND");
    }
    return *found;
}

// 在Pathfinder规划和提交阶段使用同一业务阻挡规则；FlyWow只记录动态footprint。
bool blockOccupancy(void *, const flywow_navigation::DynamicNavigationQuery &query)
{
    return query.agent && query.agent->profile && query.occupancy &&
           !query.occupancy->IsFootprintBlocked(*query.agent->profile, query.target,
                                                query.agent->handle);
}
flywow_navigation::DynamicNavigationPolicy policy()
{
    return {nullptr, &blockOccupancy};
}

// 显式逐字节小端格式；不允许序列化struct padding或指针。
void put(std::string &out, std::uint64_t n, unsigned count)
{
    for (unsigned i = 0; i < count; ++i)
        out.push_back(static_cast<char>((n >> (8 * i)) & 255u));
}
std::uint64_t get(const std::string &in, std::size_t &offset, unsigned count)
{
    if (count > in.size() - std::min(offset, in.size()))
        throw std::runtime_error("STATE_TRUNCATED");
    std::uint64_t value = 0;
    for (unsigned i = 0; i < count; ++i)
        value |= static_cast<std::uint64_t>(static_cast<unsigned char>(in[offset++])) << (8 * i);
    return value;
}
std::int64_t signed64(std::uint64_t n)
{
    // 无符号大整数转有符号是实现定义；这里手动还原二补数。
    return n <= static_cast<std::uint64_t>(INT64_MAX)
               ? static_cast<std::int64_t>(n)
               : -1 - static_cast<std::int64_t>(UINT64_MAX - n);
}
std::int32_t signed32(std::uint64_t n)
{
    return n <= static_cast<std::uint64_t>(INT32_MAX)
               ? static_cast<std::int32_t>(n)
               : -1 - static_cast<std::int32_t>(UINT32_MAX - n);
}
void requirePosition(std::int64_t n)
{
    if (n < -kPositionLimit || n > kPositionLimit)
        throw std::runtime_error("POSITION_RANGE");
}
void validatePoint(const flywow_navigation::WorldPosition &point)
{
    requirePosition(point.x_mm);
    requirePosition(point.y_mm);
    requirePosition(point.z_mm);
}
} // namespace

Engine::Engine(std::shared_ptr<const flywow_navigation::GridMap> map)
    : map_(std::move(map)),
      profiles_(std::atomic_load_explicit(&g_profiles, std::memory_order_acquire))
{
    if (!map_ || map_->metadata().cell_size_mm < 100)
        throw std::runtime_error("MAP_INVALID");
    if (!profiles_ || profiles_->units.empty())
        throw std::runtime_error("PROFILES_NOT_LOADED");
    reset();
}

bool Engine::sampleGround(const Unit &unit, std::int64_t x, std::int64_t z, std::int64_t from_y,
                          std::int64_t &new_y) const
{
    const auto query = map_->QueryWorld({x, from_y, z});
    if (!query.ok() || !query.value.IsWalkable())
        return false;
    const auto &profile = profileFor(profiles_->units, unit.unit_profile_id).navigation;
    const auto  required =
        flywow_navigation::RequiredClearanceCells(profile, map_->metadata().cell_size_mm);
    if (query.value.clearance_cells < required)
        return false;
    new_y = query.value.height_mm;
    return absolute(new_y - from_y) <= profile.max_step_mm;
}

bool Engine::sampleAir(const Unit &unit, std::int64_t x, std::int64_t z, std::int64_t target_y,
                       std::int64_t &new_y) const
{
    const auto &profile = profileFor(profiles_->units, unit.unit_profile_id);
    const auto  query   = map_->QueryWorld({x, 0, z});
    if (!query.ok() ||
        target_y <
            static_cast<std::int64_t>(query.value.height_mm) + profile.min_air_clearance_mm ||
        target_y > static_cast<std::int64_t>(query.value.height_mm) + profile.max_air_altitude_mm)
        return false;
    new_y = target_y;
    return true;
}

std::unique_ptr<flywow_navigation::NavigationContext>
Engine::buildContext(const State &candidate) const
{
    auto next_context = std::make_unique<flywow_navigation::NavigationContext>(map_);
    for (const auto &unit : candidate.units)
    {
        if (unit.hp <= 0)
            continue;

        const auto &profile = profileFor(profiles_->units, unit.unit_profile_id);
        if (unit.movement_mode == 2)
        {
            const auto center = position(unit);
            const auto radius = static_cast<std::int64_t>(profile.air_body.radius_mm);
            const auto half_height = static_cast<std::int64_t>(profile.air_body.half_height_mm);
            const flywow_navigation::AirBox box{
                {center.x_mm - radius, center.y_mm - half_height, center.z_mm - radius},
                {center.x_mm + radius, center.y_mm + half_height, center.z_mm + radius},
            };
            const flywow_navigation::NavigationAgentHandle handle{unit.instance_id};
            const auto placed = flywow_navigation::setAirObstacle(*next_context, handle, box);
            if (!placed.ok())
                throw std::runtime_error(flywow_navigation::NavErrorName(placed.error));
            const auto spawn = flywow_navigation::sweepAir(
                *next_context, center, center, profile.air_body, handle, {true, 0});
            if (!spawn.ok() || spawn.value.kind != flywow_navigation::AirHitKind::kClear)
                throw std::runtime_error("SPAWN_BLOCKED");
            continue;
        }
        if (unit.movement_mode != 1)
            throw std::runtime_error("STATE_MOVE_MODE");

        const auto &navigation = profile.navigation;
        const auto grid = map_->WorldToGrid(position(unit));
        if (!grid.ok() || next_context->occupancy().IsFootprintBlocked(
                navigation, grid.value, {unit.instance_id}))
            throw std::runtime_error("STATE_OCCUPANCY_CONFLICT");
        const auto placed = next_context->occupancy().Move(
            {unit.instance_id}, navigation, grid.value);
        if (!placed.ok() || !placed.value)
            throw std::runtime_error("STATE_OCCUPANCY_COMMIT");
    }
    return next_context;
}

void Engine::reset()
{
    State candidate;
    Unit  player;
    player.instance_id         = 1001;
    player.unit_profile_id = 1;
    player.camp       = 1;
    player.x          = -11000;
    player.z          = 4000;
    candidate.units.push_back(player);

    Unit flying_enemy;
    flying_enemy.instance_id         = 2001;
    flying_enemy.unit_profile_id = 2;
    flying_enemy.camp       = 2;
    flying_enemy.x          = 11000;
    flying_enemy.y          = 2000;
    flying_enemy.z          = -4000;
    candidate.units.push_back(flying_enemy);

    Unit ground_enemy;
    ground_enemy.instance_id         = 2002;
    ground_enemy.unit_profile_id = 1;
    ground_enemy.camp       = 2;
    ground_enemy.x          = 11000;
    ground_enemy.z          = -4000;
    candidate.units.push_back(ground_enemy);

    for (auto &unit : candidate.units)
    {
        const auto &profile   = profileFor(profiles_->units, unit.unit_profile_id);
        unit.movement_mode    = profile.movement_mode;
        unit.hp               = profile.max_hp;
        std::int64_t ground_y = unit.y;
        const bool   sampled  = unit.movement_mode == 1
                                    ? sampleGround(unit, unit.x, unit.z, unit.y, ground_y)
                                    : sampleAir(unit, unit.x, unit.z, unit.y, ground_y);
        if (!sampled)
            throw std::runtime_error("SPAWN_BLOCKED");
        unit.y = ground_y;
    }
    auto next_context = buildContext(candidate);
    state_            = std::move(candidate);
    context_          = std::move(next_context);
}

std::size_t Engine::targetOf(const Unit &unit, std::uint32_t move_mask) const
{
    auto         best    = state_.units.size();
    std::int64_t nearest = INT64_MAX;
    for (std::size_t index = 0; index < state_.units.size(); ++index)
    {
        const auto &other = state_.units[index];
        if (other.hp <= 0 || other.camp == unit.camp || !(other.movement_mode & move_mask))
            continue;
        const auto score = distance2(unit, other);
        if (score < nearest)
        {
            nearest = score;
            best    = index;
        }
    }
    return best; // 严格升序遍历，距离相同时instance_id较小者获胜。
}

Route &Engine::routeFor(std::uint32_t unit_instance_id)
{
    auto it = std::lower_bound(state_.routes.begin(), state_.routes.end(), unit_instance_id,
                               [](const Route &route, std::uint32_t value)
                               { return route.unit_instance_id < value; });
    if (it == state_.routes.end() || it->unit_instance_id != unit_instance_id)
        it = state_.routes.insert(it, Route{});
    it->unit_instance_id = unit_instance_id;
    return *it;
}

bool Engine::moveGround(Unit &unit, std::int32_t x, std::int32_t z)
{
    if (x == 0 && z == 0)
        return false;
    const auto  &unit_profile = profileFor(profiles_->units, unit.unit_profile_id);
    const auto   stride = strideForAxes(unit_profile.move_speed_mm_per_sec, (x != 0) + (z != 0), state_.frame - 1);
    const auto   target_x = unit.x + x * stride;
    const auto   target_z = unit.z + z * stride;
    std::int64_t target_y = unit.y;
    if (!sampleGround(unit, target_x, target_z, target_y, target_y))
        return false;
    const auto                              &navigation = unit_profile.navigation;
    const flywow_navigation::NavigationAgent agent{{unit.instance_id}, &navigation};
    const auto                               result = flywow_navigation::GridPathfinder::MoveUnit(
        *context_, agent, position(unit), {target_x, target_y, target_z}, policy());
    if (!result.ok() || !result.value)
        return false;
    unit.x = target_x;
    unit.z = target_z;
    unit.y = target_y;
    return true;
}

void Engine::moveAir(Unit &unit, std::int32_t x, std::int32_t z, std::int32_t y)
{
    const auto  &profile  = profileFor(profiles_->units, unit.unit_profile_id);
    const auto   axes     = (x != 0) + (z != 0) + (y != 0);
    const auto   stride   = strideForAxes(profile.move_speed_mm_per_sec, axes, state_.frame - 1);
    std::int64_t result_y = unit.y;
    const auto   new_y    = unit.y + y * stride;
    if (sampleAir(unit, unit.x + x * stride, unit.z + z * stride, new_y, result_y))
    {
        unit.x += x * stride;
        unit.z += z * stride;
        unit.y = result_y;
    }
}

void Engine::chaseGround(Unit &unit, const Unit &target)
{
    // 900 mm 是追击/停止移动距离；进入该距离后保留已有 Route，但本帧不再推进它。
    if (distance2(unit, target) <= 900 * 900)
        return;
    auto &route = routeFor(unit.instance_id);
    // Route 按单位实例缓存；追击目标一旦改变，旧路径立即失去业务前提。
    if (route.target_instance_id != target.instance_id)
    {
        route.valid     = false;
        route.target_instance_id = target.instance_id;
        route.repath_at = state_.frame;
    }

    const bool target_moved = target.x != route.planned_target_x ||
                              target.y != route.planned_target_y ||
                              target.z != route.planned_target_z;
    // 只有路径失效或目标坐标变化且重规划冷却已到期时才重新 A*；其余 Tick 复用旧路径。
    if (state_.frame >= route.repath_at && (!route.valid || target_moved))
    {
        const auto &navigation_profile = profileFor(profiles_->units, unit.unit_profile_id).navigation;
        const flywow_navigation::NavigationAgent agent{{unit.instance_id}, &navigation_profile};
        // 目标单位占位本身不能作为终点；找其附近允许站立的位置。
        // FindPathToRange沿用FlyWow的真实动态A*查询实现。
        auto candidate = flywow_navigation::GridPathfinder::FindPathToRange(
            *context_, agent, position(unit), position(target), 800, policy(), true);
        route.repath_at        = state_.frame + kRepathDelay;
        route.planned_target_x = target.x;
        route.planned_target_y = target.y;
        route.planned_target_z = target.z;
        route.blocked_frames   = 0;
        route.valid            = candidate.ok() && candidate.value.count() > 1;
        route.path             = flywow_navigation::Path{};
        route.next_point       = 1;
        route.progress_mm      = 0;
        if (route.valid)
            route.path = std::move(candidate.value);
    }

    if (!route.valid)
        return;
    const auto                         &path = route.path;
    flywow_navigation::PathFollowCursor cursor;
    cursor.next_point_index                             = route.next_point;
    cursor.segment_progress_mm                          = route.progress_mm;
    const auto                              &profile    = profileFor(profiles_->units, unit.unit_profile_id);
    const auto                              &navigation = profile.navigation;
    const flywow_navigation::NavigationAgent agent{{unit.instance_id}, &navigation};
    const auto result = flywow_navigation::GridPathfinder::AdvancePath(
        *context_, agent, path, cursor, position(unit), strideForAxes(profile.move_speed_mm_per_sec, 1, state_.frame - 1), policy());
    if (!result.ok())
        throw std::runtime_error("NAV_ADVANCE_FAILED");
    unit.x            = result.value.position.x_mm;
    unit.y            = result.value.position.y_mm;
    unit.z            = result.value.position.z_mm;
    route.next_point  = static_cast<std::uint32_t>(cursor.next_point_index);
    route.progress_mm = cursor.segment_progress_mm;
    if (result.value.status == flywow_navigation::PathAdvanceStatus::kBlocked)
    {
        route.valid = false;
        ++route.blocked_frames;
        route.repath_at = state_.frame + kBlockedRetry;
    }
    else if (result.value.status == flywow_navigation::PathAdvanceStatus::kReached)
    {
        route.valid     = false;
        route.repath_at = state_.frame + kRepathDelay;
    }
}

void Engine::chaseAir(Unit &unit, const Unit &target)
{
    const auto &profile = profileFor(profiles_->units, unit.unit_profile_id);
    if (distance2(unit, target) <= 800 * 800)
        return;

    const auto horizontal = std::max(absolute(target.x - unit.x),
                                     absolute(target.z - unit.z));
    const auto desired_y = target.y + 400 + std::min<std::int64_t>(2400, horizontal / 2);
    const auto vertical_intent =
        absolute(desired_y - unit.y) >=
            strideForAxes(profile.move_speed_mm_per_sec, 1, state_.frame - 1)
            ? sign(desired_y - unit.y)
            : 0;
    const flywow_navigation::NavigationAgentHandle handle{unit.instance_id};
    const auto route = flywow_navigation::findAirPath(
        *context_, position(unit), position(target), unit.y, profile.air_body,
        handle, {true, 0});
    if (!route.ok())
    {
        if (route.error == flywow_navigation::NavError::kNoPath)
            return;
        throw std::runtime_error(flywow_navigation::NavErrorName(route.error));
    }
    if (route.value.count() <= 1)
        return;

    const auto &next = route.value.WorldPoint(1);
    const auto x = sign(next.x_mm - unit.x);
    const auto z = sign(next.z_mm - unit.z);
    const auto axes = static_cast<std::uint32_t>((x != 0) + (z != 0) +
                                                  (vertical_intent != 0));
    const auto stride = strideForAxes(profile.move_speed_mm_per_sec, axes, state_.frame - 1);
    flywow_navigation::WorldPosition destination{
        unit.x + x * stride,
        unit.y + vertical_intent * stride,
        unit.z + z * stride,
    };
    std::int64_t checked_y = destination.y_mm;
    if (!sampleAir(unit, destination.x_mm, destination.z_mm, destination.y_mm, checked_y))
        return;
    destination.y_mm = checked_y;

    const auto moved = flywow_navigation::moveAir(*context_, handle, destination, {true, 0});
    if (!moved.ok())
    {
        if (moved.error == flywow_navigation::NavError::kBlocked)
            return;
        throw std::runtime_error(flywow_navigation::NavErrorName(moved.error));
    }
    unit.x = moved.value.x_mm;
    unit.y = moved.value.y_mm;
    unit.z = moved.value.z_mm;
}

void Engine::cast(Unit &unit, std::int32_t skill_id, std::vector<std::int32_t> &damage)
{
    if (skill_id == 0)
        return;
    const Skill &skill = profiles_->skills[static_cast<std::size_t>(skill_id - 1)];
    const auto   index = targetOf(unit, skill.target_mask);
    if (index == state_.units.size() || state_.frame < unit.ready[skill_id - 1] ||
        distance2(unit, state_.units[index]) > skill.range_mm * skill.range_mm)
        return;
    // 逻辑弹丸必须有活动槽位才允许施放；表现弹丸满槽时仍可保留已确认的技能伤害。
    if (skill.effect == 3 && state_.bolts.size() >= kMaxBolts)
        return;

    // 冷却只在技能通过目标、射程和逻辑弹丸容量检查后开始。
    unit.ready[skill_id - 1] = state_.frame + skill.cooldown;
    // effect=1 直接记伤害；effect=2 先记伤害再生成零伤害表现弹丸；effect=3 在弹丸抵达时记伤害。
    if (skill.effect == 1)
    {
        damage[index] += skill.damage;
        return;
    }
    if (skill.effect == 2)
        damage[index] += skill.damage;
    if (state_.bolts.size() == kMaxBolts)
        return; // 纯表现弹丸满槽不撤销已结算伤害。
    // 弹丸逻辑寿命固定为3秒，即180个60Hz逻辑帧；超时不再命中。
    state_.bolts.push_back({state_.next_bolt++, unit.instance_id, state_.units[index].instance_id, state_.frame + 180,
                            skill.effect == 2 ? 0 : skill.damage, unit.x, unit.y, unit.z});
}

void Engine::moveBolts(std::vector<std::int32_t> &damage)
{
    // 用新数组一次性收集仍活动的弹丸，避免遍历时删除导致漏处理后续弹丸。
    std::vector<Bolt> next;
    next.reserve(kMaxBolts);
    for (auto bolt : state_.bolts)
    {
        const auto it = std::find_if(state_.units.begin(), state_.units.end(), [&](const Unit &unit)
                                     { return unit.instance_id == bolt.target_instance_id && unit.hp > 0; });
        if (it == state_.units.end() || bolt.expires <= state_.frame)
            continue;
        const auto dx = it->x - bolt.x, dy = it->y - bolt.y, dz = it->z - bolt.z;
        // 弹丸速度为8000 mm/s；本帧位移使用与单位相同的整数帧号差分算法，到达判定按本帧位移检查。
        const auto span = std::max({absolute(dx), absolute(dy), absolute(dz)});
        const auto bolt_stride = strideForAxes(8000, 1, state_.frame - 1);
        if (span <= bolt_stride)
        {
            damage[static_cast<std::size_t>(it - state_.units.begin())] += bolt.damage;
            continue;
        }
        bolt.x += dx * bolt_stride / span;
        bolt.y += dy * bolt_stride / span;
        bolt.z += dz * bolt_stride / span;
        next.push_back(bolt);
    }
    state_.bolts.swap(next);
}

void Engine::finish(const std::vector<std::int32_t> &damage)
{
    bool alive1 = false, alive2 = false;
    for (std::size_t i = 0; i < state_.units.size(); ++i)
    {
        auto &unit = state_.units[i];
        unit.hp    = std::max(0, unit.hp - damage[i]);
        if (unit.hp == 0 && unit.movement_mode == 1)
        {
            const auto released = context_->occupancy().Release({unit.instance_id});
            if (!released.ok())
                throw std::runtime_error("NAV_RELEASE_FAILED");
        }
        alive1 = alive1 || (unit.camp == 1 && unit.hp > 0);
        alive2 = alive2 || (unit.camp == 2 && unit.hp > 0);
    }
    if (!alive1 || !alive2)
        state_.winner = alive1 ? 1 : alive2 ? 2 : 3;
    else if (state_.frame >= kMaxFrames)
        state_.winner = 3;
}

void Engine::runFrame(const PlayerInput *inputs)
{
    ++state_.frame;
    std::vector<std::int32_t>  damage(state_.units.size(), 0);
    // 先冻结 AI 移动阶段的目标实例 ID：单位移动的遍历先后不得改变本帧追击目标。
    std::vector<std::uint32_t> target_instance_ids(state_.units.size(), 0);
    for (std::size_t index = 0; index < state_.units.size(); ++index)
    {
        if (state_.units[index].instance_id == 1001 || state_.units[index].hp <= 0)
            continue;
        const auto target_index = targetOf(state_.units[index], 3);
        if (target_index != state_.units.size())
            target_instance_ids[index] = state_.units[target_index].instance_id;
    }
    // 全部单位按instance_id升序执行；玩家1001由正式帧输入驱动，其余单位由Core规则驱动。
    for (auto &unit : state_.units)
    {
        if (unit.hp <= 0)
            continue;
        if (unit.instance_id == 1001)
        {
            const auto &input = inputs[0];
            moveGround(unit, input.x, input.z);
        }
        else
        {
            const auto target_instance_id =
                target_instance_ids[static_cast<std::size_t>(&unit - state_.units.data())];
            const auto it = std::find_if(state_.units.begin(), state_.units.end(),
                                         [&](const Unit &other) { return other.instance_id == target_instance_id; });
            if (it == state_.units.end())
                continue;
            if (unit.movement_mode == 1)
                chaseGround(unit, *it);
            else
                chaseAir(unit, *it);
        }
    }
    // 移动完成后按稳定单位顺序选择施法；伤害先累加，最后统一提交以保留同帧互相命中的结果。
    for (auto &unit : state_.units)
    {
        if (unit.hp <= 0)
            continue;
        std::int32_t skill_id = 0;
        if (unit.instance_id == 1001)
            skill_id = inputs[0].skill;
        else
        {
            const auto enemy = targetOf(unit, 3);
            if (enemy != state_.units.size())
                skill_id =
                    (unit.movement_mode == 1 && distance2(unit, state_.units[enemy]) <= 900 * 900)
                        ? 1
                        : 3;
        }
        cast(unit, skill_id, damage);
    }
    moveBolts(damage);
    finish(damage);
}

void Engine::stepFrame(std::uint32_t frame, const PlayerInput *inputs, std::size_t count)
{
    if (poisoned_ || state_.winner != 0 || frame != state_.frame + 1 || frame > kMaxFrames ||
        !inputs || count != 1 || inputs[0].seat_id != 1 || inputs[0].unit_instance_id != 1001)
        throw std::runtime_error("FRAME_INPUT");
    for (std::size_t i = 0; i < count; ++i)
    {
        if (inputs[i].x < -1 || inputs[i].x > 1 || inputs[i].z < -1 || inputs[i].z > 1 ||
            inputs[i].skill < 0 || inputs[i].skill > 3)
            throw std::runtime_error("FRAME_INPUT_RANGE");
    }
    const State before = state_; // 失败路径补偿；商业规模需Benchmark评估快照复制成本。
    try
    {
        runFrame(inputs);
    }
    catch (...)
    {
        try
        {
            auto restored = buildContext(before);
            state_        = before;
            context_      = std::move(restored);
        }
        catch (...)
        {
            poisoned_ = true;
        }
        throw;
    }
}

std::string Engine::save() const
{
    if (poisoned_)
        throw std::runtime_error("STATE_POISONED");
    // Checkpoint V3 按固定字段顺序逐项小端编码；不能序列化 C++ struct 布局、指针或导航 scratch。
    std::string out;
    out.reserve(4096);
    put(out, 3, 4);
    put(out, state_.frame, 4);
    put(out, state_.winner, 4);
    put(out, state_.next_bolt, 4);
    put(out, state_.units.size(), 4);
    for (const auto &unit : state_.units)
    {
        put(out, unit.instance_id, 4);
        put(out, unit.unit_profile_id, 4);
        put(out, unit.camp, 4);
        put(out, unit.movement_mode, 4);
        put(out, static_cast<std::uint64_t>(unit.x), 8);
        put(out, static_cast<std::uint64_t>(unit.y), 8);
        put(out, static_cast<std::uint64_t>(unit.z), 8);
        put(out, static_cast<std::uint32_t>(unit.hp), 4);
        for (const auto ready : unit.ready)
            put(out, ready, 4);
    }
    put(out, state_.bolts.size(), 4);
    for (const auto &bolt : state_.bolts)
    {
        put(out, bolt.id, 4);
        put(out, bolt.caster_instance_id, 4);
        put(out, bolt.target_instance_id, 4);
        put(out, bolt.expires, 4);
        put(out, static_cast<std::uint32_t>(bolt.damage), 4);
        put(out, static_cast<std::uint64_t>(bolt.x), 8);
        put(out, static_cast<std::uint64_t>(bolt.y), 8);
        put(out, static_cast<std::uint64_t>(bolt.z), 8);
    }
    put(out, state_.routes.size(), 4);
    for (const auto &route : state_.routes)
    {
        put(out, route.unit_instance_id, 4);
        put(out, route.target_instance_id, 4);
        put(out, static_cast<std::uint64_t>(route.planned_target_x), 8);
        put(out, static_cast<std::uint64_t>(route.planned_target_y), 8);
        put(out, static_cast<std::uint64_t>(route.planned_target_z), 8);
        put(out, route.repath_at, 4);
        put(out, route.blocked_frames, 4);
        put(out, route.valid ? 1 : 0, 4);
        put(out, route.path.count(), 4);
        put(out, route.next_point, 4);
        put(out, route.progress_mm, 8);
        put(out, route.path.length_mm(), 8);
        put(out, std::string(route.path.status()) == "partial" ? 1 : 0, 4);
        for (const auto &point : route.path.points())
        {
            put(out, static_cast<std::uint64_t>(point.x_mm), 8);
            put(out, static_cast<std::uint64_t>(point.y_mm), 8);
            put(out, static_cast<std::uint64_t>(point.z_mm), 8);
        }
    }
    if (out.size() > kMaxState)
        throw std::runtime_error("STATE_SIZE_LIMIT");
    return out;
}

void Engine::restore(const std::string &bytes)
{
    if (poisoned_ || bytes.size() > kMaxState)
        throw std::runtime_error("STATE_INVALID");
    // 先解析并验证到局部 candidate；只有路径和动态占位都重建成功后才替换当前 Battle 状态。
    std::size_t offset = 0;
    if (get(bytes, offset, 4) != 3)
        throw std::runtime_error("STATE_VERSION");
    State candidate;
    candidate.frame     = static_cast<std::uint32_t>(get(bytes, offset, 4));
    candidate.winner    = static_cast<std::uint32_t>(get(bytes, offset, 4));
    candidate.next_bolt = static_cast<std::uint32_t>(get(bytes, offset, 4));
    const auto units    = get(bytes, offset, 4);
    if (units != 3 || candidate.frame > kMaxFrames || candidate.winner > 3 ||
        candidate.next_bolt == 0 || candidate.next_bolt > kMaxFrames * kMaxUnits + 1)
        throw std::runtime_error("STATE_HEADER");
    const auto maximum_cooldown = std::max_element(
        profiles_->skills.begin(), profiles_->skills.end(),
        [](const Skill &left, const Skill &right) { return left.cooldown < right.cooldown; })->cooldown;
    for (std::uint64_t i = 0; i < units; ++i)
    {
        Unit unit;
        unit.instance_id            = static_cast<std::uint32_t>(get(bytes, offset, 4));
        unit.unit_profile_id    = static_cast<std::uint32_t>(get(bytes, offset, 4));
        unit.camp          = static_cast<std::uint32_t>(get(bytes, offset, 4));
        unit.movement_mode = static_cast<std::uint32_t>(get(bytes, offset, 4));
        unit.x             = signed64(get(bytes, offset, 8));
        unit.y             = signed64(get(bytes, offset, 8));
        unit.z             = signed64(get(bytes, offset, 8));
        unit.hp            = signed32(get(bytes, offset, 4));
        for (auto &ready : unit.ready)
            ready = static_cast<std::uint32_t>(get(bytes, offset, 4));
        requirePosition(unit.x);
        requirePosition(unit.y);
        requirePosition(unit.z);
        if (unit.hp < 0 || unit.camp < 1 || unit.camp > 2 || unit.movement_mode < 1 ||
            unit.movement_mode > 2 ||
            (!candidate.units.empty() && candidate.units.back().instance_id >= unit.instance_id))
            throw std::runtime_error("STATE_UNIT");
        for (const auto ready : unit.ready)
            if (static_cast<std::uint64_t>(ready) >
                static_cast<std::uint64_t>(candidate.frame) + maximum_cooldown)
                throw std::runtime_error("STATE_READY");
        candidate.units.push_back(unit);
    }
    if (candidate.units[0].instance_id != 1001 || candidate.units[1].instance_id != 2001 ||
        candidate.units[2].instance_id != 2002)
        throw std::runtime_error("STATE_UNIT_IDS");
    if (candidate.units[0].unit_profile_id != 1 || candidate.units[1].unit_profile_id != 2 ||
        candidate.units[2].unit_profile_id != 1)
        throw std::runtime_error("STATE_PROFILE_IDS");
    for (const auto &unit : candidate.units)
    {
        const auto &profile = profileFor(profiles_->units, unit.unit_profile_id);
        if (unit.movement_mode != profile.movement_mode || unit.hp > profile.max_hp)
            throw std::runtime_error("STATE_PROFILE_MISMATCH");
    }
    const auto bolts = get(bytes, offset, 4);
    if (bolts > kMaxBolts)
        throw std::runtime_error("STATE_BOLT_LIMIT");
    for (std::uint64_t i = 0; i < bolts; ++i)
    {
        Bolt bolt;
        bolt.id      = static_cast<std::uint32_t>(get(bytes, offset, 4));
        bolt.caster_instance_id  = static_cast<std::uint32_t>(get(bytes, offset, 4));
        bolt.target_instance_id  = static_cast<std::uint32_t>(get(bytes, offset, 4));
        bolt.expires = static_cast<std::uint32_t>(get(bytes, offset, 4));
        bolt.damage  = signed32(get(bytes, offset, 4));
        bolt.x       = signed64(get(bytes, offset, 8));
        bolt.y       = signed64(get(bytes, offset, 8));
        bolt.z       = signed64(get(bytes, offset, 8));
        requirePosition(bolt.x);
        requirePosition(bolt.y);
        requirePosition(bolt.z);
        const auto unitExists = [&](std::uint32_t unit_instance_id)
        {
            return std::any_of(candidate.units.begin(), candidate.units.end(),
                               [&](const Unit &unit) { return unit.instance_id == unit_instance_id; });
        };
        if (!bolt.id || bolt.id >= candidate.next_bolt || !unitExists(bolt.caster_instance_id) ||
            !unitExists(bolt.target_instance_id) || (bolt.damage != 0 && bolt.damage != 20) ||
            bolt.expires <= candidate.frame || bolt.expires > candidate.frame + 180 ||
            (!candidate.bolts.empty() && candidate.bolts.back().id >= bolt.id))
            throw std::runtime_error("STATE_BOLT");
        candidate.bolts.push_back(bolt);
    }
    const auto routes = get(bytes, offset, 4);
    if (routes > kMaxRoutes)
        throw std::runtime_error("STATE_ROUTE_LIMIT");
    for (std::uint64_t i = 0; i < routes; ++i)
    {
        Route route;
        route.unit_instance_id          = static_cast<std::uint32_t>(get(bytes, offset, 4));
        route.target_instance_id        = static_cast<std::uint32_t>(get(bytes, offset, 4));
        route.planned_target_x = signed64(get(bytes, offset, 8));
        route.planned_target_y = signed64(get(bytes, offset, 8));
        route.planned_target_z = signed64(get(bytes, offset, 8));
        requirePosition(route.planned_target_x);
        requirePosition(route.planned_target_y);
        requirePosition(route.planned_target_z);
        route.repath_at           = static_cast<std::uint32_t>(get(bytes, offset, 4));
        route.blocked_frames      = static_cast<std::uint32_t>(get(bytes, offset, 4));
        const auto valid          = get(bytes, offset, 4);
        const auto points         = get(bytes, offset, 4);
        route.next_point          = static_cast<std::uint32_t>(get(bytes, offset, 4));
        route.progress_mm         = get(bytes, offset, 8);
        const auto path_length_mm = get(bytes, offset, 8);
        const auto partial        = get(bytes, offset, 4);
        if (valid > 1 || partial > 1 || points > 1024 || route.next_point > points ||
            route.repath_at > candidate.frame + kRepathDelay || route.unit_instance_id == 0 ||
            route.target_instance_id == 0 ||
            (!candidate.routes.empty() && candidate.routes.back().unit_instance_id >= route.unit_instance_id))
            throw std::runtime_error("STATE_ROUTE");
        route.valid = valid != 0;
        std::vector<flywow_navigation::WorldPosition> path_points;
        path_points.reserve(static_cast<std::size_t>(points));
        for (std::uint64_t j = 0; j < points; ++j)
        {
            flywow_navigation::WorldPosition point;
            point.x_mm = signed64(get(bytes, offset, 8));
            point.y_mm = signed64(get(bytes, offset, 8));
            point.z_mm = signed64(get(bytes, offset, 8));
            validatePoint(point);
            if (!map_->WorldToGrid(point).ok())
                throw std::runtime_error("STATE_ROUTE_POINT");
            path_points.push_back(point);
        }
        route.path = flywow_navigation::Path(std::move(path_points), path_length_mm, partial != 0);
        if (route.valid && (route.path.count() < 2 || route.next_point < 1))
            throw std::runtime_error("STATE_ROUTE_CURSOR");
        candidate.routes.push_back(std::move(route));
    }
    if (offset != bytes.size())
        throw std::runtime_error("STATE_TRAILING");
    auto next_context = buildContext(candidate);
    state_            = std::move(candidate);    // 候选已完成逻辑校验与占位重建。
    context_          = std::move(next_context); // 发布点后从未混用新旧动态事实。
}
} // namespace lesson_frame

extern "C" LESSON_FRAME_API int fs_preload_map(const char *bmap_path, const char *airnav_path)
{
    try
    {
        if (!bmap_path || !*bmap_path)
            return 0;
        const std::string air_path = airnav_path ? airnav_path : "";
        const auto result = flywow_navigation::MapRegistry::Instance().Load(bmap_path, air_path);
        return result.ok() && static_cast<bool>(result.value) ? 1 : 0;
    }
    catch (...)
    {
        return 0;
    }
}

extern "C" LESSON_FRAME_API int fs_load_profiles(
    const FsUnitProfile *units, std::uint32_t unit_count,
    const FsNavigationProfile *navigation, std::uint32_t navigation_count,
    const FsSkillProfile *skills, std::uint32_t skill_count)
{
    using lesson_frame::ProfileSnapshot;
    using lesson_frame::UnitProfile;
    try
    {
        if (!units || unit_count == 0 || unit_count > 128 ||
            (navigation_count != 0 && !navigation) || navigation_count > unit_count ||
            !skills || skill_count != 3)
            return 0;

        auto snapshot = std::make_shared<ProfileSnapshot>();
        snapshot->units.reserve(unit_count);
        for (std::uint32_t i = 0; i < unit_count; ++i)
        {
            const auto &source = units[i];
            if (source.unit_id == 0 ||
                (source.movement_mode != 1 && source.movement_mode != 2) ||
                source.move_speed_mm_per_sec == 0 ||
                source.move_speed_mm_per_sec > INT32_MAX || source.max_hp <= 0 ||
                (source.movement_mode == 2 &&
                 (source.air_radius_mm == 0 || source.air_half_height_mm == 0)) ||
                (source.movement_mode == 1 &&
                 (source.air_radius_mm != 0 || source.air_half_height_mm != 0)) ||
                (i > 0 && units[i - 1].unit_id >= source.unit_id))
                return 0;

            UnitProfile profile{};
            profile.unit_id = source.unit_id;
            profile.movement_mode = source.movement_mode;
            profile.move_speed_mm_per_sec = source.move_speed_mm_per_sec;
            profile.max_hp = source.max_hp;
            profile.min_air_clearance_mm = source.min_air_clearance_mm;
            profile.max_air_altitude_mm = source.max_air_altitude_mm;
            profile.air_body = {source.air_radius_mm, source.air_half_height_mm};
            if (source.movement_mode == 2 &&
                (source.min_air_clearance_mm == 0 ||
                 source.max_air_altitude_mm < source.min_air_clearance_mm))
                return 0;
            if (source.movement_mode == 1 &&
                (source.min_air_clearance_mm != 0 || source.max_air_altitude_mm != 0))
                return 0;
            snapshot->units.push_back(std::move(profile));
        }

        std::uint32_t nav_index = 0;
        for (auto &profile : snapshot->units)
        {
            if (profile.movement_mode == 2)
                continue;
            if (nav_index >= navigation_count ||
                navigation[nav_index].unit_id != profile.unit_id)
                return 0;
            const auto &source = navigation[nav_index++];
            if (source.radius_mm <= 0 || source.max_step_mm <= 0)
                return 0;
            auto &target = profile.navigation;
            target.unit_id = source.unit_id;
            target.radius_mm = source.radius_mm;
            target.max_step_mm = source.max_step_mm;
            target.max_slope_permille = source.max_slope_permille;
            for (std::size_t area = 0; area < 256; ++area)
            {
                if (source.area_allowed[area] > 1 ||
                    (source.area_allowed[area] && source.area_cost_permille[area] < 1000))
                    return 0;
                target.area_allowed[area] = source.area_allowed[area];
                target.area_cost_permille[area] = source.area_cost_permille[area];
            }
        }
        if (nav_index != navigation_count)
            return 0;

        for (std::uint32_t i = 0; i < skill_count; ++i)
        {
            const auto &source = skills[i];
            if (source.skill_id != i + 1 || source.range_mm > INT64_MAX ||
                source.cooldown_ticks == 0 || source.cooldown_ticks > lesson_frame::kMaxFrames ||
                source.damage <= 0 ||
                source.target_mask < 1 || source.target_mask > 3 ||
                source.effect < 1 || source.effect > 3)
                return 0;
            snapshot->skills[i] = {
                static_cast<std::int64_t>(source.range_mm), source.cooldown_ticks,
                source.damage, source.target_mask, source.effect};
        }

        std::shared_ptr<const ProfileSnapshot> published = std::move(snapshot);
        std::atomic_store_explicit(&g_profiles, std::move(published),
                                   std::memory_order_release);
        return 1;
    }
    catch (...)
    {
        return 0;
    }
}

extern "C" LESSON_FRAME_API void *fs_open(std::uint32_t map_id)
{
    try
    {
        const auto result = flywow_navigation::MapRegistry::Instance().Find(map_id);
        if (!result.ok() || !result.value)
            return nullptr;
        return new lesson_frame::Engine(result.value);
    }
    catch (...)
    {
        return nullptr;
    }
}

extern "C" LESSON_FRAME_API void fs_close(void *handle)
{
    delete static_cast<lesson_frame::Engine *>(handle);
}

extern "C" LESSON_FRAME_API int fs_step_frame(void *handle, std::uint32_t frame,
                                              const FsPlayerInput *players, std::uint32_t count)
{
    try
    {
        if (!handle || !players || count != 1)
            return 0;
        lesson_frame::PlayerInput inputs[1];
        for (std::uint32_t i = 0; i < count; ++i)
            inputs[i] = {players[i].seat_id, players[i].unit_instance_id, players[i].x, players[i].z,
                         players[i].skill};
        static_cast<lesson_frame::Engine *>(handle)->stepFrame(frame, inputs, count);
        return 1;
    }
    catch (...)
    {
        return 0;
    }
}

extern "C" LESSON_FRAME_API int fs_save(void *handle, unsigned char *output, int capacity)
{
    try
    {
        if (!handle || !output || capacity < 0)
            return 0;
        const auto bytes = static_cast<lesson_frame::Engine *>(handle)->save();
        if (bytes.size() > static_cast<std::size_t>(capacity))
            return 0;
        std::memcpy(output, bytes.data(), bytes.size());
        return static_cast<int>(bytes.size());
    }
    catch (...)
    {
        return 0;
    }
}

extern "C" LESSON_FRAME_API int fs_restore(void *handle, const unsigned char *bytes, int count)
{
    try
    {
        if (!handle || !bytes || count <= 0 || count > static_cast<int>(lesson_frame::kMaxState))
            return 0;
        static_cast<lesson_frame::Engine *>(handle)->restore(
            std::string(reinterpret_cast<const char *>(bytes), static_cast<std::size_t>(count)));
        return 1;
    }
    catch (...)
    {
        return 0;
    }
}

extern "C" LESSON_FRAME_API std::uint32_t fs_map_id(void *handle)
{
    return handle ? static_cast<lesson_frame::Engine *>(handle)->mapId() : 0;
}
extern "C" LESSON_FRAME_API std::uint32_t fs_map_version(void *handle)
{
    return handle ? static_cast<lesson_frame::Engine *>(handle)->mapVersion() : 0;
}
