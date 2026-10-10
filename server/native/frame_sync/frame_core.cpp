// 职责：实现帧同步纯整数规则、规范化状态和C ABI异常边界。
// 输入：Input与固定地图；输出：State；无网络、锁、Timer或随机全局状态。
#include "frame_core.h"
#include "bmap_reader.h"
#include "grid_pathfinder.h"
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <stdexcept>

namespace lesson_frame
{
namespace
{
// 静态技能定义不进入可变运行状态；Unit 只保存各技能下次可施放的帧号。
enum class SkillEffect
{
    kInstant,     // 当前帧直接提交伤害。
    kVisualBolt,  // 当前帧提交伤害；弹丸只负责表现，不再次结算。
    kLogicalBolt, // 弹丸到达目标时提交伤害。
};
struct Skill
{
    std::int64_t  range;        // 施法最大距离，单位 mm，按三轴距离判定。
    std::uint32_t cooldown;     // 冷却时长，单位逻辑帧。
    std::int32_t  damage;       // 正式伤害点数；只由 Engine 提交。
    SkillEffect   effect;       // 命中/弹丸的逻辑生效时机。
    std::uint32_t target_modes; // 可选目标移动类型位标记：1 地面、2 空中、3 两者。
};
// 数组下标对应 skill 编号减一；射程用 mm，冷却用固定逻辑帧。
constexpr Skill        kSkills[]      = {{900, 12, 14, SkillEffect::kInstant, 1},
                                         {9000, 24, 12, SkillEffect::kVisualBolt, 3},
                                         {9000, 24, 20, SkillEffect::kLogicalBolt, 3}};
// 每轴绝对坐标不超过 500,000,000mm，最大轴差为 1,000,000,000mm；
// 三轴平方和最多为 3e18，小于 int64 上限，保证 distance2 的乘加不溢出。
constexpr std::int64_t kPositionLimit = 500000000;
std::int32_t           sign(std::int64_t value)
{
    return (value > 0) - (value < 0);
}
// 先限制单轴，平方和在int64范围内；positions经过输入/restore边界验证。
std::int64_t distance2(const Unit &a, const Unit &b)
{
    const auto dx = a.x - b.x;
    const auto dz = a.z - b.z;
    const auto dy = a.y - b.y;
    return dx * dx + dy * dy + dz * dz;
}
void put(std::string &out, std::uint64_t value, unsigned count)
{
    for (unsigned i = 0; i < count; ++i)
        out.push_back(static_cast<char>((value >> (8 * i)) & 255));
}
std::uint64_t get(const std::string &in, std::size_t &offset, unsigned count)
{
    if (offset + count > in.size())
        throw std::runtime_error("STATE_TRUNCATED");
    std::uint64_t value = 0;
    for (unsigned i = 0; i < count; ++i)
        value |= static_cast<std::uint64_t>(static_cast<unsigned char>(in[offset++])) << (8 * i);
    return value;
}
std::int64_t signedValue(std::uint64_t bits)
{
    // 不依赖无符号大值转有符号的实现定义行为；显式还原二补数。
    return bits <= static_cast<std::uint64_t>(INT64_MAX)
               ? static_cast<std::int64_t>(bits)
               : -1 - static_cast<std::int64_t>(UINT64_MAX - bits);
}
void checkPosition(std::int64_t value)
{
    if (value < -kPositionLimit || value > kPositionLimit)
        throw std::runtime_error("POSITION_RANGE");
}

std::size_t readStateHeader(const std::string &bytes, std::size_t &offset, State &candidate)
{
    if (get(bytes, offset, 4) != 1)
        throw std::runtime_error("STATE_VERSION");
    candidate.frame     = static_cast<std::uint32_t>(get(bytes, offset, 4));
    candidate.winner    = static_cast<std::uint32_t>(get(bytes, offset, 4));
    candidate.next_bolt = static_cast<std::uint32_t>(get(bytes, offset, 4));
    const auto count    = get(bytes, offset, 4);
    if (count < 1 || count > kMaxUnits || candidate.frame > kMaxFrames || candidate.winner > 3 ||
        candidate.next_bolt == 0 || candidate.next_bolt > kMaxFrames * kMaxUnits + 1)
        throw std::runtime_error("STATE_RANGE");
    return static_cast<std::size_t>(count);
}
Unit readUnit(const std::string &bytes, std::size_t &offset, const State &candidate)
{
    Unit unit;
    unit.id        = static_cast<std::uint32_t>(get(bytes, offset, 4));
    unit.camp      = static_cast<std::uint32_t>(get(bytes, offset, 4));
    unit.move_mode = static_cast<std::uint32_t>(get(bytes, offset, 4));
    unit.x         = signedValue(get(bytes, offset, 8));
    unit.y         = signedValue(get(bytes, offset, 8));
    unit.z         = signedValue(get(bytes, offset, 8));
    const auto hp  = get(bytes, offset, 4);
    if (hp > 100)
        throw std::runtime_error("STATE_HP");
    unit.hp       = static_cast<std::int32_t>(hp);
    unit.ready[0] = static_cast<std::uint32_t>(get(bytes, offset, 4));
    unit.ready[1] = static_cast<std::uint32_t>(get(bytes, offset, 4));
    unit.ready[2] = static_cast<std::uint32_t>(get(bytes, offset, 4));
    checkPosition(unit.x);
    checkPosition(unit.y);
    checkPosition(unit.z);
    if (unit.ready[0] > candidate.frame + 24 || unit.ready[1] > candidate.frame + 24 ||
        unit.ready[2] > candidate.frame + 24 || (unit.move_mode != 1 && unit.move_mode != 2) ||
        unit.id == 0 || (unit.camp != 1 && unit.camp != 2) || unit.hp < 0 || unit.hp > 100 ||
        (!candidate.units.empty() && candidate.units.back().id >= unit.id))
        throw std::runtime_error("STATE_UNIT");
    return unit;
}
Bolt readBolt(const std::string &bytes, std::size_t &offset, const State &candidate)
{
    Bolt bolt;
    bolt.id      = static_cast<std::uint32_t>(get(bytes, offset, 4));
    bolt.caster  = static_cast<std::uint32_t>(get(bytes, offset, 4));
    bolt.target  = static_cast<std::uint32_t>(get(bytes, offset, 4));
    bolt.expires = static_cast<std::uint32_t>(get(bytes, offset, 4));
    bolt.damage  = static_cast<std::int32_t>(get(bytes, offset, 4));
    bolt.x       = signedValue(get(bytes, offset, 8));
    bolt.y       = signedValue(get(bytes, offset, 8));
    bolt.z       = signedValue(get(bytes, offset, 8));
    checkPosition(bolt.x);
    checkPosition(bolt.y);
    checkPosition(bolt.z);
    const auto exists = [&](std::uint32_t id)
    {
        return std::any_of(candidate.units.begin(), candidate.units.end(),
                           [&](const Unit &unit) { return unit.id == id; });
    };
    if ((bolt.damage != 0 && bolt.damage != 20) || !exists(bolt.caster) || !exists(bolt.target) ||
        bolt.expires <= candidate.frame || bolt.expires > candidate.frame + 60 || bolt.id == 0 ||
        bolt.id >= candidate.next_bolt ||
        (!candidate.bolts.empty() && candidate.bolts.back().id >= bolt.id))
        throw std::runtime_error("STATE_BOLT");
    return bolt;
}
} // namespace

Engine::Engine(std::shared_ptr<const flywow_navigation::GridMap> map)
    : map_(std::move(map)), context_(map_)
{
    if (!map_ || map_->metadata().cell_size_mm < 100)
        throw std::runtime_error("MAP_CELL_SIZE");
    reset();
}
bool Engine::sample(std::int64_t x, std::int64_t z, std::int64_t from_y, std::int64_t &y) const
{
    const auto result = map_->QueryWorld({x, from_y, z});
    if (!result.ok() || !result.value.IsWalkable())
        return false;
    const auto radius_cells =
        (200u + map_->metadata().cell_size_mm - 1) / map_->metadata().cell_size_mm;
    if (result.value.clearance_cells < radius_cells)
        return false;
    y = result.value.height_mm;
    return std::abs(y - from_y) <= 600;
}
bool Engine::sampleAir(std::int64_t x, std::int64_t z, std::int64_t desired_y,
                       std::int64_t &y) const
{
    const auto result = map_->QueryWorld({x, 0, z});
    if (!result.ok())
        return false;
    if (desired_y < static_cast<std::int64_t>(result.value.height_mm) + 200 || desired_y > 10000)
        return false;
    y = desired_y;
    return true; // 不读取IsWalkable/clearance；该地图尚无空域禁飞与天花板资产。
}
void Engine::reset()
{
    State candidate;
    candidate.units = {{1001, 1, 1, -11000, 0, 4000, 100, {}},
                       {2001, 2, 2, 11000, 2000, -4000, 100, {}},
                       {2002, 2, 1, 11000, 0, -4000, 100, {}}};
    for (auto &unit : candidate.units)
        if (!(unit.move_mode == 2 ? sampleAir(unit.x, unit.z, unit.y, unit.y)
                                  : sample(unit.x, unit.z, unit.y, unit.y)))
            throw std::runtime_error("SPAWN_BLOCKED");
    state_ = std::move(candidate);
}
std::size_t Engine::target(const Unit &unit, std::uint32_t target_modes) const
{
    std::size_t  best          = state_.units.size();
    std::int64_t best_distance = INT64_MAX;
    for (std::size_t i = 0; i < state_.units.size(); ++i)
    {
        const auto &other = state_.units[i];
        if (other.hp <= 0 || other.camp == unit.camp || (other.move_mode & target_modes) == 0)
            continue;
        const auto d = distance2(unit, other);
        if (d < best_distance)
        {
            best          = i;
            best_distance = d;
        }
    }
    return best; // ID排序保证等距时优先较小ID。
}
void Engine::chaseAir(const Unit &unit, const Unit &other, Input &input) const
{
    input.x               = sign(other.x - unit.x);
    input.z               = sign(other.z - unit.z);
    // 水平距离越大，追击高度越高；接近目标时下俯，目标移动后重新计算。
    const auto horizontal = std::max(std::abs(other.x - unit.x), std::abs(other.z - unit.z));
    const auto desired_y  = other.y + 400 + std::min<std::int64_t>(2400, horizontal / 2);
    input.y               = std::abs(desired_y - unit.y) >= 150 ? sign(desired_y - unit.y) : 0;
    std::int64_t probe_y  = unit.y;
    if (!sampleAir(unit.x + input.x * 150, unit.z + input.z * 150, unit.y, probe_y))
        input.y = 1;
    if (distance2(unit, other) <= 800 * 800)
        input.x = input.z = 0;
}
void Engine::chaseGround(const Unit &unit, const Unit &other, Input &input)
{
    auto profile               = flywow_navigation::MakeDefaultNavigationProfile(unit.id);
    profile.radius_mm          = 200;
    profile.max_step_mm        = 600;
    profile.max_slope_permille = 1500;
    const auto path            = flywow_navigation::GridPathfinder::FindPathStatic(
        context_, profile, {unit.x, unit.y, unit.z}, {other.x, other.y, other.z});
    // 路线不存入逻辑事实：相同当前State重新查询得到相同结果；不可达停住。
    if (path.ok() && path.value.count() > 1)
    {
        const auto &next = path.value.WorldPoint(1);
        input.x          = sign(next.x_mm - unit.x);
        input.z          = sign(next.z_mm - unit.z);
    }
}
Input Engine::ai(const Unit &unit)
{
    const auto index = target(unit);
    if (index == state_.units.size())
        return {};
    const auto &other = state_.units[index];
    Input       input;
    if (unit.move_mode == 2)
        chaseAir(unit, other, input);
    else if (distance2(unit, other) > 800 * 800)
        chaseGround(unit, other, input);
    input.skill = distance2(unit, other) <= 900 * 900 && other.move_mode == 1 ? 1 : 3;
    return input;
}
void Engine::move(Unit &unit, Input input)
{
    // 3000mm/s × 50ms / 1000 = 150mm；对角分量乘707/1000约为1/sqrt(2)。
    // 这里的106mm量化是玩法合同，两端使用同一代码；不使用平台sqrt。
    if (unit.move_mode == 1)
        input.y = 0;
    const int          axes   = (input.x != 0) + (input.z != 0) + (input.y != 0);
    const std::int64_t length = axes == 3 ? 86 : axes == 2 ? 106 : 150;
    const auto         dx     = input.x * length;
    const auto         dz     = input.z * length;
    const auto         dy     = input.y * length;
    // 最大子步不超过cell/4，防止跨越一个阻挡格；最多8步。
    const auto         stride = std::max<std::int64_t>(1, map_->metadata().cell_size_mm / 4);
    const auto         steps  = std::max<std::int64_t>(1, (length + stride - 1) / stride);
    for (std::int64_t n = 1; n <= steps; ++n)
    {
        const auto   sx = dx * n / steps - dx * (n - 1) / steps;
        const auto   sz = dz * n / steps - dz * (n - 1) / steps;
        const auto   sy = dy * n / steps - dy * (n - 1) / steps;
        std::int64_t y  = unit.y;
        // X后Z是固定的贴墙滑动顺序；不是由物理回调执行顺序决定。
        if (unit.move_mode == 2 ? sampleAir(unit.x + sx, unit.z, unit.y, y)
                                : sample(unit.x + sx, unit.z, unit.y, y))
        {
            unit.x += sx;
            unit.y = y;
        }
        if (unit.move_mode == 2 ? sampleAir(unit.x, unit.z + sz, unit.y, y)
                                : sample(unit.x, unit.z + sz, unit.y, y))
        {
            unit.z += sz;
            unit.y = y;
        }
        if (unit.move_mode == 2 && sampleAir(unit.x, unit.z, unit.y + sy, y))
            unit.y = y;
    }
}
void Engine::cast(Unit &unit, std::int32_t skill_id, std::vector<std::int32_t> &damage)
{
    if (skill_id == 0)
        return;
    const auto &def   = kSkills[skill_id - 1];
    const auto  index = target(unit, def.target_modes);
    if (index == state_.units.size() || state_.frame < unit.ready[skill_id - 1] ||
        distance2(unit, state_.units[index]) > def.range * def.range ||
        (def.target_modes & state_.units[index].move_mode) == 0)
        return;
    if (def.effect == SkillEffect::kLogicalBolt && state_.bolts.size() >= kMaxBolts)
        return;

    unit.ready[skill_id - 1] = state_.frame + def.cooldown;
    if (def.effect == SkillEffect::kInstant)
    {
        damage[index] += def.damage;
        return;
    }
    if (def.effect == SkillEffect::kVisualBolt)
        damage[index] += def.damage; // 表现飞行不会改变已经结算的伤害。
    if (state_.bolts.size() >= kMaxBolts)
        return; // 表现球满槽仅降级视觉，不撤回已提交的伤害与冷却。
    state_.bolts.push_back({state_.next_bolt++, unit.id, state_.units[index].id, state_.frame + 60,
                            def.effect == SkillEffect::kVisualBolt ? 0 : def.damage, unit.x, unit.y,
                            unit.z});
}
void Engine::projectiles(std::vector<std::int32_t> &damage)
{
    std::vector<Bolt> surviving;
    surviving.reserve(kMaxBolts);
    for (auto bolt : state_.bolts)
    {
        const auto it = std::find_if(state_.units.begin(), state_.units.end(), [&](const Unit &unit)
                                     { return unit.id == bolt.target && unit.hp > 0; });
        if (it == state_.units.end() || bolt.expires <= state_.frame)
            continue;
        const auto dx   = it->x - bolt.x;
        const auto dz   = it->z - bolt.z;
        const auto dy   = it->y - bolt.y;
        const auto span = std::max({std::abs(dx), std::abs(dy), std::abs(dz)});
        // 400mm/frame；以Chebyshev长度归一保证整数确定性，技能规则不是欧氏匀速。
        if (span <= 400)
        {
            damage[static_cast<std::size_t>(it - state_.units.begin())] += bolt.damage;
            continue;
        }
        bolt.x += dx * 400 / span;
        bolt.z += dz * 400 / span;
        bolt.y += dy * 400 / span;
        surviving.push_back(bolt);
    }
    state_.bolts.swap(surviving); // 保持原ID顺序；回滚后迭代顺序不改变。
}
void Engine::finish(const std::vector<std::int32_t> &damage)
{
    bool alive1 = false;
    bool alive2 = false;
    for (std::size_t i = 0; i < state_.units.size(); ++i)
    {
        auto &unit = state_.units[i];
        unit.hp    = std::max(0, unit.hp - damage[i]);
        alive1 |= unit.hp > 0 && unit.camp == 1;
        alive2 |= unit.hp > 0 && unit.camp == 2;
    }
    if (!alive1 || !alive2)
        state_.winner = alive1 ? 1 : alive2 ? 2 : 3;
    else if (state_.frame >= kMaxFrames)
        state_.winner = 3;
}
void Engine::step(Input input)
{
    // API原子提交：任何异常恢复旧逻辑状态；临时内存失败不留下半帧。
    State before = state_;
    try
    {
        stepUnchecked(input);
    }
    catch (...)
    {
        state_ = std::move(before);
        throw;
    }
}
void Engine::stepUnchecked(Input input)
{
    if (state_.winner != 0)
        throw std::runtime_error("BATTLE_FINISHED");
    if (input.x < -1 || input.x > 1 || input.z < -1 || input.z > 1 || input.y != 0 ||
        input.skill < 0 || input.skill > 3)
        throw std::runtime_error("BAD_INPUT");
    ++state_.frame;
    std::vector<Input> inputs;
    for (const auto &unit : state_.units)
        inputs.push_back(unit.id == 1001 ? input : ai(unit));
    for (std::size_t i = 0; i < state_.units.size(); ++i)
        if (state_.units[i].hp > 0)
            move(state_.units[i], inputs[i]);

    std::vector<std::int32_t> damage(state_.units.size(), 0);
    for (std::size_t i = 0; i < state_.units.size(); ++i)
        if (state_.units[i].hp > 0)
            cast(state_.units[i], inputs[i].skill, damage);
    projectiles(damage);
    finish(damage); // 同帧统一提交伤害；不会因先处理ID小者而取消对方同帧攻击。
}
std::string Engine::save() const
{
    std::string out;
    out.reserve(128 + state_.units.size() * 52 + state_.bolts.size() * 44);
    put(out, 1, 4);
    put(out, state_.frame, 4);
    put(out, state_.winner, 4);
    put(out, state_.next_bolt, 4);
    put(out, state_.units.size(), 4);
    for (const auto &unit : state_.units)
    {
        put(out, unit.id, 4);
        put(out, unit.camp, 4);
        put(out, unit.move_mode, 4);
        put(out, static_cast<std::uint64_t>(unit.x), 8);
        put(out, static_cast<std::uint64_t>(unit.y), 8);
        put(out, static_cast<std::uint64_t>(unit.z), 8);
        put(out, static_cast<std::uint32_t>(unit.hp), 4);
        put(out, unit.ready[0], 4);
        put(out, unit.ready[1], 4);
        put(out, unit.ready[2], 4);
    }
    put(out, state_.bolts.size(), 4);
    for (const auto &bolt : state_.bolts)
    {
        put(out, bolt.id, 4);
        put(out, bolt.caster, 4);
        put(out, bolt.target, 4);
        put(out, bolt.expires, 4);
        put(out, static_cast<std::uint32_t>(bolt.damage), 4);
        put(out, static_cast<std::uint64_t>(bolt.x), 8);
        put(out, static_cast<std::uint64_t>(bolt.y), 8);
        put(out, static_cast<std::uint64_t>(bolt.z), 8);
    }
    return out;
}
void Engine::restore(const std::string &bytes)
{
    std::size_t offset = 0;
    State       candidate;
    const auto  count = readStateHeader(bytes, offset, candidate);
    for (std::size_t i = 0; i < count; ++i)
        candidate.units.push_back(readUnit(bytes, offset, candidate));

    const auto bolts = get(bytes, offset, 4);
    if (bolts > kMaxBolts)
        throw std::runtime_error("STATE_BOLTS");
    for (std::size_t i = 0; i < bolts; ++i)
        candidate.bolts.push_back(readBolt(bytes, offset, candidate));
    if (offset != bytes.size())
        throw std::runtime_error("STATE_TRAILING");
    state_ = std::move(candidate); // 所有校验通过后唯一发布点。
}
} // namespace lesson_frame

extern "C" void *fs_open(const char *path)
{
    try
    {
        if (!path)
            return nullptr;
        const auto map = flywow_navigation::BMapReader::Read(path);
        return map.ok() ? new lesson_frame::Engine(map.value) : nullptr;
    }
    catch (...)
    {
        return nullptr;
    }
}
extern "C" void fs_close(void *handle)
{
    delete static_cast<lesson_frame::Engine *>(handle);
}
extern "C" int fs_step(void *handle, int x, int z, int skill)
{
    try
    {
        if (!handle)
            return 0;
        static_cast<lesson_frame::Engine *>(handle)->step({x, z, 0, skill});
        return 1;
    }
    catch (...)
    {
        return 0;
    }
}
extern "C" int fs_save(void *handle, unsigned char *out, int capacity)
{
    try
    {
        if (!handle || !out || capacity < 0)
            return 0;
        const auto bytes = static_cast<lesson_frame::Engine *>(handle)->save();
        if (bytes.size() > static_cast<std::size_t>(capacity))
            return 0;
        std::memcpy(out, bytes.data(), bytes.size());
        return static_cast<int>(bytes.size());
    }
    catch (...)
    {
        return 0;
    }
}
extern "C" int fs_restore(void *handle, const unsigned char *bytes, int count)
{
    try
    {
        if (!handle || !bytes || count < 0 || count > 16384)
            return 0;
        static_cast<lesson_frame::Engine *>(handle)->restore(
            std::string(reinterpret_cast<const char *>(bytes), count));
        return 1;
    }
    catch (...)
    {
        return 0;
    }
}

extern "C" std::uint32_t fs_map_version(void *handle)
{
    return handle ? static_cast<lesson_frame::Engine *>(handle)->mapVersion() : 0;
}
extern "C" std::uint32_t fs_map_id(void *handle)
{
    return handle ? static_cast<lesson_frame::Engine *>(handle)->mapId() : 0;
}
