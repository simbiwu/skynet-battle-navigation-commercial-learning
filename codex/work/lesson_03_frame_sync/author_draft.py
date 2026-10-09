# 职责：保存第三课帧同步实操编写中的未验证代码与教学草稿。
# 边界：文档作者工作稿，不是课程成品或Server运行源码。
# 状态：未完成、未编译、未运行；当前只有文件记录与部分C++核心草案。
# 注意：fs_map_version等占位API必须修正，禁止直接交付或宣称可运行。
from pathlib import Path
import argparse
import re
import subprocess

REPO = Path('/home/simbi/workspace/skynet-battle-navigation-commercial-learning')
STAGE = Path('/tmp/flywow_lesson3_full')
FILES = []
PROSE = {'frame': [], 'state': []}

def source(mode, path, language, why, code, focus, verify):
    FILES.append(dict(mode=mode, path=path, language=language, why=why,
                      code=code.strip()+'\n', focus=focus, verify=verify))

def prose(mode, title, body):
    PROSE[mode].append((title,body.strip()))

prose('frame', '从第二课开始的实施基线', '''
这份文档可以独立从第二课完成后的主仓库与固定 FlyWow 子模块继续。所有运行时新增代码都在本课列出；生成的 Protobuf 文件用固定生成器产生。先完成纯模拟，再接真实 Gateway/Cluster，再做 Unity 预测与恢复。每阶段通过后再进入下一阶段。

本版玩法为一名玩家对一名确定性 AI：WASD 移动，J 普通攻击，K 逻辑火球。双方死亡即停止，无奖励结算。战斗核心支持有界单位/弹丸数组，玩法场景只配置两个角色。单位在地面导航资产上运动，不增加空中资产或 Buff。

帧同步的模拟在 Server 与 Unity 内使用同一份 C++17 代码编译成不同平台产物，这保证两端技能、取整和碰撞规则一致。此处只在帧同步版内部共用模拟；状态同步版拥有自己的 Lua 战斗与 Unity 预测实现。Native 只消费已发布 BMAP，复用 FlyWow 的 Reader/GridMap，不复制地图解析器。

| 状态 | Owner | 生命周期 |
|---|---|---|
| immutable GridMap | 每个模拟实例的 shared_ptr | Native close 后释放最后引用 |
| 正式 Battle | Skynet Frame Worker | 建立至结束/过期 |
| speculative Battle | Unity 控制器 | 本地预测；校正时恢复重演 |
| 帧历史 | Worker/Unity 各自的固定窗口 | 超窗 RESYNC |
| UDP socket/peer/key | FlyWow 数据报 Service / 客户端传输 | 控制会话绑定至撤销 |

WSL Build 终端先执行第二课已提供的构建入口，不修改旧 Battle Core：

```bash
cd ~/workspace/skynet-battle-navigation-commercial-learning/server
./scripts/linux/run_server.sh build
test -x third_party/skynet/skynet
test -x third_party/skynet/3rd/lua/lua
test -s ../shared/navigation/battle_1001/battle_1001.bmap
git status --short
```

已有 `config/battle.lua` 包含的在线字段不是本版前置实现；本课使用新配置，旧 Worker/Manager 保留第二课批量模拟入口。未提交内容先识别归属，不执行全仓 reset。
''')

source('frame', 'server/native/frame_sync/frame_core.h', 'cpp',
       '先定义单步模拟、可保存的状态和跨平台 ABI；下一节 Server Binding 与 Unity 都只调用这个合同。', r'''
// 职责：定义帧同步整数模拟及稳定 C ABI；属于宿主 Battle，不属于 FlyWow。
// 输入/输出：已发布地图、帧输入 -> 新状态；逻辑不读取网络或墙钟。
// ownership：每个 Engine 独占 State，GridMap 只读；C handle 必须成对 open/close。
#pragma once
#include "grid_map.h"
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace lesson_frame
{
constexpr std::size_t kMaxUnits = 64;       // 每场实际持有的单位上限。
constexpr std::size_t kMaxBolts = 128;      // 在途逻辑弹丸上限；施法超限拒绝。
constexpr std::uint32_t kMaxFrames = 3600;  // 180秒；到期判平局。
constexpr std::uint32_t kTickMs = 50;       // 一逻辑帧50ms，渲染不使用此周期。

/// 单个玩家当前帧的按键意图；x/z 为 -1/0/1，skill 为0/1/2。
struct Input
{
    std::int32_t x = 0; // 方向，无单位；不会提交正式位置。
    std::int32_t z = 0;
    std::int32_t skill = 0; // 0不施法，1近战，2逻辑火球。
};
/// 单位运行状态；三轴坐标均为有符号64位毫米。
struct Unit
{
    std::uint32_t id = 0; // 稳定实例ID，按ID排序推进。
    std::uint32_t camp = 0;
    std::int64_t x = 0;
    std::int64_t y = 0;
    std::int64_t z = 0;
    std::int32_t hp = 100;
    std::uint32_t ready[2] = {}; // 各技能允许再次施放的帧号。
};
/// 在途逻辑弹丸；ID生成器和到期帧均属于可恢复状态。
struct Bolt
{
    std::uint32_t id = 0;
    std::uint32_t caster = 0;
    std::uint32_t target = 0;
    std::uint32_t expires = 0;
    std::int64_t x = 0;
    std::int64_t y = 0;
    std::int64_t z = 0;
};
/// 完整逻辑状态；不含指针、表现对象、墙钟或Socket。
struct State
{
    std::uint32_t frame = 0;
    std::uint32_t winner = 0; // 0进行中，1/2胜方阵营，3平局。
    std::uint32_t next_bolt = 1;
    std::vector<Unit> units;
    std::vector<Bolt> bolts;
};
/// 无锁、无yield的单实例模拟；调用方保证同一实例顺序调用。
class Engine
{
public:
    explicit Engine(std::shared_ptr<const flywow_navigation::GridMap> map);
    /// 初始化指定玩法；地图拒绝出生点时抛异常，由ABI入口转换。
    void reset();
    /// 推进一帧；非法输入/已结束状态失败，不产生半步提交。
    void step(Input input);
    /// 显式小端规范化序列化；可用于Checkpoint与确定性校验。
    std::string save() const;
    /// 校验候选状态后原子替换；失败不改变旧状态。
    void restore(const std::string& bytes);
    const State& state() const noexcept { return state_; }
private:
    std::shared_ptr<const flywow_navigation::GridMap> map_;
    State state_;
    bool sample(std::int64_t x, std::int64_t z, std::int64_t from_y, std::int64_t& y) const;
    void move(Unit& unit, Input input);
    Input ai(const Unit& unit) const;
    void cast(Unit& unit, std::int32_t skill, std::vector<std::int32_t>& damage);
    void projectiles(std::vector<std::int32_t>& damage);
    std::size_t target(const Unit& unit) const;
    void finish(const std::vector<std::int32_t>& damage);
};
}

#if defined(_WIN32)
#define LESSON_FRAME_API __declspec(dllexport)
#else
#define LESSON_FRAME_API __attribute__((visibility("default")))
#endif
extern "C"
{
/// open执行资产I/O；成功返回独占handle，失败返回nullptr。path为UTF-8。
LESSON_FRAME_API void* fs_open(const char* path);
/// close释放handle；nullptr允许，重复释放同一非空handle属于调用方错误。
LESSON_FRAME_API void fs_close(void* handle);
/// 返回1成功、0失败；调用方只在成功后使用输出。
LESSON_FRAME_API int fs_step(void* handle, int x, int z, int skill);
/// 缓冲不够返回0；最大状态长度16384 bytes，返回实际长度。
LESSON_FRAME_API int fs_save(void* handle, unsigned char* out, int capacity);
/// restore失败返回0并保留旧状态。
LESSON_FRAME_API int fs_restore(void* handle, const unsigned char* bytes, int count);
/// map版本用于跨端一致性；空handle返回0。
LESSON_FRAME_API std::uint32_t fs_map_version(void* handle);
}
''', '精读 State 的全部字段、save/restore 的候选提交，以及 C ABI 的失败返回。vector 语法可略读。',
       '下一节编译并执行 Golden；先检查 State 没有地址/墙钟字段。')

source('frame', 'server/native/frame_sync/frame_core.cpp', 'cpp',
       '现在让一份明确输入推进一帧，并把静态碰撞、AI、冷却、弹丸与同帧伤害落到固定顺序。', r'''
// 职责：实现帧同步纯整数规则、规范化状态和C ABI异常边界。
// 输入：Input与固定地图；输出：State；无网络、锁、Timer或随机全局状态。
#include "frame_core.h"
#include "bmap_reader.h"
#include <algorithm>
#include <cstring>
#include <limits>
#include <stdexcept>

namespace lesson_frame
{
namespace
{
// 技能定义是静态值；运行态只保存ready与Bolts。所有距离单位为毫米。
struct Skill { std::int64_t range; std::uint32_t cooldown; std::int32_t damage; bool bolt; };
constexpr Skill kSkills[] = {{900, 12, 14, false}, {9000, 24, 20, true}};
constexpr std::int64_t kPositionLimit = 1000000000;
std::int32_t sign(std::int64_t value) { return (value > 0) - (value < 0); }
// 先限制单轴，平方和在int64范围内；positions经过输入/restore边界验证。
std::int64_t distance2(const Unit& a, const Unit& b)
{
    const auto dx = a.x - b.x;
    const auto dz = a.z - b.z;
    return dx * dx + dz * dz;
}
void put(std::string& out, std::uint64_t value, unsigned count)
{
    for (unsigned i = 0; i < count; ++i) out.push_back(static_cast<char>((value >> (8*i)) & 255));
}
std::uint64_t get(const std::string& in, std::size_t& offset, unsigned count)
{
    if (offset + count > in.size()) throw std::runtime_error("STATE_TRUNCATED");
    std::uint64_t value = 0;
    for (unsigned i = 0; i < count; ++i)
        value |= static_cast<std::uint64_t>(static_cast<unsigned char>(in[offset++])) << (8*i);
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
}

Engine::Engine(std::shared_ptr<const flywow_navigation::GridMap> map) : map_(std::move(map))
{
    if (!map_ || map_->metadata().cell_size_mm < 100) throw std::runtime_error("MAP_CELL_SIZE");
    reset();
}
bool Engine::sample(std::int64_t x, std::int64_t z, std::int64_t from_y, std::int64_t& y) const
{
    const auto result = map_->QueryWorld({x, from_y, z});
    if (!result.ok() || !result.value.IsWalkable()) return false;
    const auto radius_cells = (200u + map_->metadata().cell_size_mm - 1) / map_->metadata().cell_size_mm;
    if (result.value.clearance_cells < radius_cells) return false;
    y = result.value.height_mm;
    return std::abs(y - from_y) <= 600;
}
void Engine::reset()
{
    State candidate;
    candidate.units = {{1001,1,-11000,0,4000,100,{}}, {2001,2,11000,0,-4000,100,{}}};
    for (auto& unit : candidate.units)
        if (!sample(unit.x, unit.z, unit.y, unit.y)) throw std::runtime_error("SPAWN_BLOCKED");
    state_ = std::move(candidate);
}
std::size_t Engine::target(const Unit& unit) const
{
    std::size_t best = state_.units.size();
    std::int64_t best_distance = INT64_MAX;
    for (std::size_t i = 0; i < state_.units.size(); ++i)
    {
        const auto& other = state_.units[i];
        if (other.hp <= 0 || other.camp == unit.camp) continue;
        const auto d = distance2(unit, other);
        if (d < best_distance) { best = i; best_distance = d; }
    }
    return best; // ID排序保证等距时优先较小ID。
}
Input Engine::ai(const Unit& unit) const
{
    const auto i = target(unit);
    if (i == state_.units.size()) return {};
    const auto& other = state_.units[i];
    Input input;
    if (distance2(unit, other) > 800*800)
    {
        input.x = sign(other.x-unit.x);
        input.z = sign(other.z-unit.z);
    }
    input.skill = distance2(unit, other) <= 900*900 ? 1 : 2;
    return input;
}
void Engine::move(Unit& unit, Input input)
{
    // 3000mm/s × 50ms / 1000 = 150mm；对角分量乘707/1000约为1/sqrt(2)。
    // 这里的106mm量化是玩法合同，两端使用同一代码；不使用平台sqrt。
    const std::int64_t length = input.x != 0 && input.z != 0 ? 106 : 150;
    const auto dx = input.x * length;
    const auto dz = input.z * length;
    // 最大子步不超过cell/4，防止跨越一个阻挡格；最多8步。
    const auto stride = std::max<std::int64_t>(1,map_->metadata().cell_size_mm/4);
    const auto steps = std::max<std::int64_t>(1,(length+stride-1)/stride);
    for (std::int64_t n = 1; n <= steps; ++n)
    {
        const auto sx = dx*n/steps - dx*(n-1)/steps;
        const auto sz = dz*n/steps - dz*(n-1)/steps;
        std::int64_t y = unit.y;
        // X后Z是固定的贴墙滑动顺序；不是由物理回调执行顺序决定。
        if (sample(unit.x+sx,unit.z,unit.y,y)) { unit.x+=sx; unit.y=y; }
        if (sample(unit.x,unit.z+sz,unit.y,y)) { unit.z+=sz; unit.y=y; }
    }
}
void Engine::cast(Unit& unit, std::int32_t skill_id, std::vector<std::int32_t>& damage)
{
    if (skill_id == 0) return;
    const auto& def = kSkills[skill_id-1];
    const auto index = target(unit);
    if (index == state_.units.size() || state_.frame < unit.ready[skill_id-1] ||
        distance2(unit,state_.units[index]) > def.range*def.range) return;
    if (def.bolt && state_.bolts.size() >= kMaxBolts) return;

    unit.ready[skill_id-1] = state_.frame + def.cooldown;
    if (!def.bolt) { damage[index] += def.damage; return; }
    state_.bolts.push_back({state_.next_bolt++,unit.id,state_.units[index].id,
                            state_.frame+60,unit.x,unit.y,unit.z});
}
void Engine::projectiles(std::vector<std::int32_t>& damage)
{
    std::vector<Bolt> surviving;
    surviving.reserve(kMaxBolts);
    for (auto bolt : state_.bolts)
    {
        const auto it = std::find_if(state_.units.begin(),state_.units.end(),
            [&](const Unit& unit){ return unit.id == bolt.target && unit.hp>0; });
        if (it == state_.units.end() || bolt.expires <= state_.frame) continue;
        const auto dx = it->x-bolt.x;
        const auto dz = it->z-bolt.z;
        const auto span = std::max(std::abs(dx),std::abs(dz));
        // 400mm/frame；以Chebyshev长度归一保证整数确定性，技能规则不是欧氏匀速。
        if (span <= 400)
        {
            damage[static_cast<std::size_t>(it-state_.units.begin())] += 20;
            continue;
        }
        bolt.x += dx*400/span;
        bolt.z += dz*400/span;
        surviving.push_back(bolt);
    }
    state_.bolts.swap(surviving); // 保持原ID顺序；回滚后迭代顺序不改变。
}
void Engine::finish(const std::vector<std::int32_t>& damage)
{
    bool alive1 = false;
    bool alive2 = false;
    for (std::size_t i = 0; i < state_.units.size(); ++i)
    {
        auto& unit = state_.units[i];
        unit.hp = std::max(0,unit.hp-damage[i]);
        alive1 |= unit.hp>0 && unit.camp==1;
        alive2 |= unit.hp>0 && unit.camp==2;
    }
    if (!alive1 || !alive2) state_.winner = alive1 ? 1 : alive2 ? 2 : 3;
    else if (state_.frame>=kMaxFrames) state_.winner = 3;
}
void Engine::step(Input input)
{
    if (state_.winner != 0) throw std::runtime_error("BATTLE_FINISHED");
    if (input.x < -1 || input.x > 1 || input.z < -1 || input.z > 1 ||
        input.skill < 0 || input.skill > 2) throw std::runtime_error("BAD_INPUT");
    ++state_.frame;
    std::vector<Input> inputs;
    for (const auto& unit : state_.units) inputs.push_back(unit.id==1001 ? input : ai(unit));
    for (std::size_t i = 0; i < state_.units.size(); ++i)
        if (state_.units[i].hp>0) move(state_.units[i],inputs[i]);

    std::vector<std::int32_t> damage(state_.units.size(),0);
    for (std::size_t i = 0; i < state_.units.size(); ++i)
        if (state_.units[i].hp>0) cast(state_.units[i],inputs[i].skill,damage);
    projectiles(damage);
    finish(damage); // 同帧统一提交伤害；不会因先处理ID小者而取消对方同帧攻击。
}
std::string Engine::save() const
{
    std::string out;
    out.reserve(128 + state_.units.size()*44 + state_.bolts.size()*40);
    put(out,1,4); put(out,state_.frame,4); put(out,state_.winner,4); put(out,state_.next_bolt,4);
    put(out,state_.units.size(),4);
    for (const auto& unit : state_.units)
    {
        put(out,unit.id,4); put(out,unit.camp,4);
        put(out,static_cast<std::uint64_t>(unit.x),8);
        put(out,static_cast<std::uint64_t>(unit.y),8);
        put(out,static_cast<std::uint64_t>(unit.z),8);
        put(out,static_cast<std::uint32_t>(unit.hp),4);
        put(out,unit.ready[0],4); put(out,unit.ready[1],4);
    }
    put(out,state_.bolts.size(),4);
    for (const auto& bolt : state_.bolts)
    {
        put(out,bolt.id,4); put(out,bolt.caster,4); put(out,bolt.target,4); put(out,bolt.expires,4);
        put(out,static_cast<std::uint64_t>(bolt.x),8);
        put(out,static_cast<std::uint64_t>(bolt.y),8);
        put(out,static_cast<std::uint64_t>(bolt.z),8);
    }
    return out;
}
void Engine::restore(const std::string& bytes)
{
    std::size_t offset = 0;
    if (get(bytes,offset,4)!=1) throw std::runtime_error("STATE_VERSION");
    State candidate;
    candidate.frame = static_cast<std::uint32_t>(get(bytes,offset,4));
    candidate.winner = static_cast<std::uint32_t>(get(bytes,offset,4));
    candidate.next_bolt = static_cast<std::uint32_t>(get(bytes,offset,4));
    const auto count = get(bytes,offset,4);
    if (count<1 || count>kMaxUnits || candidate.frame>kMaxFrames || candidate.winner>3 ||
        candidate.next_bolt==0) throw std::runtime_error("STATE_RANGE");
    for (std::size_t i = 0; i < count; ++i)
    {
        Unit unit;
        unit.id = static_cast<std::uint32_t>(get(bytes,offset,4));
        unit.camp = static_cast<std::uint32_t>(get(bytes,offset,4));
        unit.x = signedValue(get(bytes,offset,8));
        unit.y = signedValue(get(bytes,offset,8));
        unit.z = signedValue(get(bytes,offset,8));
        unit.hp = static_cast<std::int32_t>(get(bytes,offset,4));
        unit.ready[0] = static_cast<std::uint32_t>(get(bytes,offset,4));
        unit.ready[1] = static_cast<std::uint32_t>(get(bytes,offset,4));
        checkPosition(unit.x); checkPosition(unit.y); checkPosition(unit.z);
        if (unit.id==0 || (unit.camp!=1 && unit.camp!=2) || unit.hp<0 || unit.hp>100 ||
            (!candidate.units.empty() && candidate.units.back().id>=unit.id))
            throw std::runtime_error("STATE_UNIT");
        candidate.units.push_back(unit);
    }
    const auto bolts = get(bytes,offset,4);
    if (bolts>kMaxBolts) throw std::runtime_error("STATE_BOLTS");
    for (std::size_t i = 0; i < bolts; ++i)
    {
        Bolt bolt;
        bolt.id=static_cast<std::uint32_t>(get(bytes,offset,4));
        bolt.caster=static_cast<std::uint32_t>(get(bytes,offset,4));
        bolt.target=static_cast<std::uint32_t>(get(bytes,offset,4));
        bolt.expires=static_cast<std::uint32_t>(get(bytes,offset,4));
        bolt.x=signedValue(get(bytes,offset,8));
        bolt.y=signedValue(get(bytes,offset,8));
        bolt.z=signedValue(get(bytes,offset,8));
        checkPosition(bolt.x); checkPosition(bolt.y); checkPosition(bolt.z);
        if (bolt.id==0 || bolt.id>=candidate.next_bolt ||
            (!candidate.bolts.empty() && candidate.bolts.back().id>=bolt.id))
            throw std::runtime_error("STATE_BOLT");
        candidate.bolts.push_back(bolt);
    }
    if (offset!=bytes.size()) throw std::runtime_error("STATE_TRAILING");
    state_=std::move(candidate);
}
}

extern "C" void* fs_open(const char* path)
{
    try
    {
        if (!path) return nullptr;
        const auto map=flywow_navigation::BMapReader::Read(path);
        return map.ok() ? new lesson_frame::Engine(map.value) : nullptr;
    }
    catch (...) { return nullptr; }
}
extern "C" void fs_close(void* handle) { delete static_cast<lesson_frame::Engine*>(handle); }
extern "C" int fs_step(void* handle,int x,int z,int skill)
{
    try
    {
        if (!handle) return 0;
        static_cast<lesson_frame::Engine*>(handle)->step({x,z,skill});
        return 1;
    }
    catch (...) { return 0; }
}
extern "C" int fs_save(void* handle,unsigned char* out,int capacity)
{
    try
    {
        if (!handle || !out || capacity<0) return 0;
        const auto bytes=static_cast<lesson_frame::Engine*>(handle)->save();
        if (bytes.size()>static_cast<std::size_t>(capacity)) return 0;
        std::memcpy(out,bytes.data(),bytes.size());
        return static_cast<int>(bytes.size());
    }
    catch (...) { return 0; }
}
extern "C" int fs_restore(void* handle,const unsigned char* bytes,int count)
{
    try
    {
        if (!handle || !bytes || count<0 || count>16384) return 0;
        static_cast<lesson_frame::Engine*>(handle)->restore(std::string(reinterpret_cast<const char*>(bytes),count));
        return 1;
    }
    catch (...) { return 0; }
}
extern "C" std::uint32_t fs_map_version(void* handle)
{
    // map_version由open时固定；状态版本不等于地图版本。
    (void)handle;
    return 0; // 下一节将ABI地图身份改成显式初始化结果，不使用此占位API。
}
''', '精读 move 的拆步/取整、cast 的定义与运行态分离、damage 的统一提交、restore 的候选状态。',
       '运行后面的 Native Golden；断点选 step、move、projectiles、restore。')
