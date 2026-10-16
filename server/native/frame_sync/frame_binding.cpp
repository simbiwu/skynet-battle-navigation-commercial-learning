// 职责：Skynet Lua 5.4.7 到宿主 Frame Core 的唯一 Native Adapter。
// 边界：Lua Binding；参数/返回值使用固定FlyWow lua-binding封装，不实现玩法。
// 输入/输出：map_id、完整FrameInputs、Checkpoint -> userdata/true或nil,error。
// ownership：userdata独占Engine，close幂等；每次Native调用同步、no-yield。
// 不负责：Socket、权限认证、Skynet Service、进程级地图资产发布策略。
// 栈合同：这里仅调用 FlyWow LuaBinding/LuaTable；read 不改变回调参数栈，
// table 句柄用 registry 引用短暂保活，returnValues 只把声明的结果交给 Lua。
// 原始 Lua C API 与临时栈恢复集中在 FlyWow 封装内，业务入口不重复维护栈索引。
#include "frame_core.h"
#include "lua_binding.h"
#include "lua_table.h"
#include <algorithm>
#include <array>
#include <cstdint>
#include <string>
#include <vector>

using flywow_lua_binding::LuaBinding;
using flywow_lua_binding::LuaTable;

namespace
{
constexpr const char *kUserdataType = "lesson.frame.engine";

struct Owner
{
    void *handle = nullptr; // 只能由本Lua State的回调访问。
    ~Owner() noexcept
    {
        fs_close(handle);
    }
};

bool readUnitProfiles(const LuaTable &rows, std::vector<FsUnitProfile> &output)
{
    // 先验证密集数组边界；核心配置容量上限为 128，拒绝稀疏表和空配置。
    std::size_t count = 0;
    if (!rows.denseArrayLength(count) || count == 0 || count > 128)
        return false;
    output.clear();
    output.reserve(count);

    // 将具名 Lua record 转为连续 C ABI record；LuaTable 负责临时栈恢复和类型检查。
    for (std::size_t index = 1; index <= count; ++index)
    {
        LuaTable      row, movement, flight, air_body;
        FsUnitProfile profile{};
        std::string   mode;
        if (!rows.readTable(index, row) || !row.readValue("unit_id", profile.unit_id) ||
            !row.readValue("max_hp", profile.max_hp) || !row.readTable("movement", movement) ||
            !movement.readValue("mode", mode) ||
            !movement.readValue("speed_mm_per_sec", profile.move_speed_mm_per_sec))
            return false;
        // Native 合同用 1 表示地面单位、2 表示空中单位；Lua 配置使用可读字符串。
        if (mode == "ground")
            profile.movement_mode = 1;
        else if (mode == "air")
        {
            profile.movement_mode = 2;
            if (!row.readTable("flight", flight) ||
                !flight.readValue("min_air_clearance_mm", profile.min_air_clearance_mm) ||
                !flight.readValue("max_air_altitude_mm", profile.max_air_altitude_mm) ||
                !flight.readTable("air_body", air_body) ||
                !air_body.readValue("radius_mm", profile.air_radius_mm) ||
                !air_body.readValue("half_height_mm", profile.air_half_height_mm))
                return false;
        }
        else
            return false;
        output.push_back(profile);
    }
    // Native profile 查找依赖稳定排序；相同 unit_id 会让配置含义不唯一，需在边界拒绝。
    std::sort(output.begin(), output.end(),
              [](const auto &a, const auto &b) { return a.unit_id < b.unit_id; });
    for (std::size_t i = 1; i < output.size(); ++i)
    {
        if (output[i - 1].unit_id == output[i].unit_id)
        {
            return false;
        }
    }

    return true;
}

bool readNavigationProfiles(const LuaTable &rows, std::vector<FsNavigationProfile> &output)
{
    // 导航 profile 可为空（使用核心默认行为），但总数仍受 Native 配置容量约束。
    std::size_t count = 0;
    if (!rows.denseArrayLength(count) || count > 128)
        return false;
    output.clear();
    output.reserve(count);

    // 将具名 Lua record 转为连续 C ABI record；LuaTable 负责临时栈恢复和类型检查。
    for (std::size_t index = 1; index <= count; ++index)
    {
        LuaTable            row, costs, allowed;
        FsNavigationProfile profile{};
        if (!rows.readTable(index, row) || !row.readValue("unit_id", profile.unit_id) ||
            !row.readValue("radius_mm", profile.radius_mm) ||
            !row.readValue("max_step_mm", profile.max_step_mm) ||
            !row.readValue("max_slope_permille", profile.max_slope_permille))
            return false;
        // area id 使用 uint8 范围；缺省为全可通行、1000‰（1.0 倍）移动代价。
        for (std::size_t area = 0; area < 256; ++area)
        {
            profile.area_allowed[area]       = 1;
            profile.area_cost_permille[area] = 1000;
        }
        if (!row.isNil("area_cost_permille"))
        {
            if (!row.readTable("area_cost_permille", costs))
                return false;
            for (std::uint32_t area = 0; area < 256; ++area)
                if (!costs.isNil(area) && !costs.readValue(area, profile.area_cost_permille[area]))
                    return false;
        }
        if (!row.isNil("area_allowed"))
        {
            if (!row.readTable("area_allowed", allowed))
                return false;
            for (std::uint32_t area = 0; area < 256; ++area)
                if (!allowed.isNil(area))
                {
                    bool is_allowed = false;
                    if (!allowed.readTruth(area, is_allowed))
                        return false;
                    profile.area_allowed[area] = is_allowed ? 1 : 0;
                }
        }
        output.push_back(profile);
    }
    // Native profile 查找依赖稳定排序；相同 unit_id 会让配置含义不唯一，需在边界拒绝。
    std::sort(output.begin(), output.end(),
              [](const auto &a, const auto &b) { return a.unit_id < b.unit_id; });
    for (std::size_t i = 1; i < output.size(); ++i)
    {
        if (output[i - 1].unit_id == output[i].unit_id)
        {
            return false;
        }
    }

    return true;
}

bool readSkillProfiles(const LuaTable &rows, std::vector<FsSkillProfile> &output)
{
    // 本课 Native skill profile 合同固定为三种配置；长度与 frame_sync.skills 对齐。
    std::size_t count = 0;
    if (!rows.denseArrayLength(count) || count != 3)
        return false;
    output.clear();
    output.reserve(count);

    // 将具名 Lua record 转为连续 C ABI record；LuaTable 负责临时栈恢复和类型检查。
    for (std::size_t index = 1; index <= count; ++index)
    {
        LuaTable       row;
        FsSkillProfile profile{};
        if (!rows.readTable(index, row) || !row.readValue("skill_id", profile.skill_id) ||
            !row.readValue("range_mm", profile.range_mm) ||
            !row.readValue("cooldown_ticks", profile.cooldown_ticks) ||
            !row.readValue("damage", profile.damage) ||
            !row.readValue("target_mask", profile.target_mask) ||
            !row.readValue("effect", profile.effect))
            return false;
        output.push_back(profile);
    }
    std::sort(output.begin(), output.end(),
              [](const auto &a, const auto &b) { return a.skill_id < b.skill_id; });
    return true;
}

int preloadAssets(lua_State *state)
{
    LuaBinding                       lua(state);
    std::string                      path, airnav_path;
    LuaTable                         unit_profiles, navigation_profiles, skill_rows;
    std::vector<FsUnitProfile>       units;
    std::vector<FsNavigationProfile> navigation;
    std::vector<FsSkillProfile>      skills;
    // 阶段一：读取路径和三组 Lua record；参数错误统一返回 nil,error，不修改 Native 资源。
    if (!lua.readValue(1, path) || !lua.readOptionalValue(2, airnav_path) ||
        !lua.readTable(3, unit_profiles) || !lua.readTable(4, navigation_profiles) ||
        !lua.readTable(5, skill_rows) || !readUnitProfiles(unit_profiles, units) ||
        !readNavigationProfiles(navigation_profiles, navigation) ||
        !readSkillProfiles(skill_rows, skills))
        return lua.pushError("PROFILE_CONFIG", "existing Lua config tables are invalid");
    // 阶段二：安装通过校验的 profile 后再加载地图资产；Native 失败映射为稳定错误码。
    if (fs_load_profiles(units.data(), static_cast<std::uint32_t>(units.size()), navigation.data(),
                         static_cast<std::uint32_t>(navigation.size()), skills.data(),
                         static_cast<std::uint32_t>(skills.size())) != 1)
        return lua.pushError("PROFILE_LOAD", "Native rejected the Lua profile records");
    if (!fs_preload_map(path.c_str(), airnav_path.c_str()))
        return lua.pushError("MAP_PRELOAD", "published BMAP/AIRN assets could not be loaded");
    return lua.returnValues(true);
}

int openEngine(lua_State *state)
{
    LuaBinding    lua(state);
    std::uint32_t map_id = 0;
    if (!lua.readValue(1, map_id) || map_id == 0)
        return lua.pushError("MAP_ID", "map_id must be a positive integer");
    // 参数通过后才创建 Engine；userdata 创建失败时当前入口仍负责关闭该 handle。
    void *handle = fs_open(map_id);
    if (!handle)
        return lua.pushError("MAP_OPEN", "map not preloaded or spawn blocked");
    Owner *owner = nullptr;
    if (!lua.newUserdata(kUserdataType, owner))
    {
        fs_close(handle);
        return lua.pushError();
    }
    // userdata 成功创建后独占 handle；Owner 的显式 close 和 __gc 共用这一释放路径。
    owner->handle = handle;
    return lua.returnValues(owner);
}

int stepFrame(lua_State *state)
{
    LuaBinding    lua(state);
    Owner        *owner = nullptr;
    std::uint32_t frame = 0;
    LuaTable      inputs;
    if (!lua.readUserdata(1, kUserdataType, owner) || !lua.readValue(2, frame) ||
        !lua.readTable(3, inputs))
        return lua.pushError();
    if (!owner->handle)
        return lua.pushError("CLOSED", "engine already closed");
    std::size_t count = 0;
    if (!inputs.denseArrayLength(count))
        return lua.pushError();
    if (count != 1)
        return lua.pushError("INPUT_COUNT", "exactly one player input required");

    // 当前课程合同只收一个玩家输入；转成固定容量 C ABI 数组后才推进核心帧。
    std::array<FsPlayerInput, 1> players{};
    for (std::size_t index = 0; index < count; ++index)
    {
        LuaTable entry;
        if (!inputs.readTable(static_cast<std::int64_t>(index + 1), entry) ||
            !entry.readValue("seat_id", players[index].seat_id) ||
            !entry.readValue("unit_instance_id", players[index].unit_instance_id) ||
            !entry.readValue("x", players[index].x) || !entry.readValue("z", players[index].z) ||
            !entry.readValue("skill", players[index].skill))
            return lua.pushError("INPUT_FIELDS", "missing or invalid seat fields");
    }
    // 参数和数组形状均验证后，执行同步、no-yield 的 Native 帧推进。
    if (fs_step_frame(owner->handle, frame, players.data(),
                      static_cast<std::uint32_t>(players.size())) != 1)
        return lua.pushError("STEP_FAILED", "invalid frame or simulation error");
    return lua.returnValues(true);
}

int saveEngine(lua_State *state)
{
    LuaBinding lua(state);
    Owner     *owner = nullptr;
    if (!lua.readUserdata(1, kUserdataType, owner))
        return lua.pushError();
    if (!owner->handle)
        return lua.pushError("CLOSED", "engine already closed");
    // Core 按最大 Checkpoint 容量写入；成功后缩到实际长度，再复制为 Lua 字符串。
    std::string buffer(lesson_frame::kMaxState, '\0');
    const int   written = fs_save(owner->handle, reinterpret_cast<unsigned char *>(&buffer[0]),
                                  static_cast<int>(buffer.size()));
    if (written <= 0)
        return lua.pushError("STATE_SAVE", "serialization failed");
    buffer.resize(static_cast<std::size_t>(written));
    return lua.returnValues(buffer);
}

int restoreEngine(lua_State *state)
{
    LuaBinding  lua(state);
    Owner      *owner = nullptr;
    std::string bytes;
    if (!lua.readUserdata(1, kUserdataType, owner) || !lua.readValue(2, bytes))
        return lua.pushError();
    if (!owner->handle)
        return lua.pushError("CLOSED", "engine already closed");
    // bytes 是 readValue 复制出的本地缓冲；Native 只在本次同步调用中消费，不保留指针。
    if (!fs_restore(owner->handle, reinterpret_cast<const unsigned char *>(bytes.data()),
                    static_cast<int>(bytes.size())))
        return lua.pushError("STATE_RESTORE", "checkpoint invalid or incompatible");
    return lua.returnValues(true);
}

int identity(lua_State *state)
{
    LuaBinding lua(state);
    Owner     *owner = nullptr;
    if (!lua.readUserdata(1, kUserdataType, owner))
        return lua.pushError();
    if (!owner->handle)
        return lua.pushError("CLOSED", "engine already closed");
    return lua.returnValues(fs_map_id(owner->handle), fs_map_version(owner->handle));
}

int closeEngine(lua_State *state)
{
    LuaBinding lua(state);
    Owner     *owner = nullptr;
    if (!lua.readUserdata(1, kUserdataType, owner))
        return lua.pushError();
    // 先释放 Native 资源并清空句柄；Owner 后续 __gc 再调用 fs_close(nullptr) 仍保持幂等。
    fs_close(owner->handle);
    owner->handle = nullptr;
    return lua.returnValues(true);
}
} // namespace

extern "C" int luaopen_lesson_frame_native(lua_State *state)
{
    LuaBinding lua(state);
    LuaTable   meta;

    // setFunction 由通用 Binding 管理 closure/upvalue 和临时栈；此处只组合公开 Lua 方法。
    auto methods = lua.newTable();
    methods.setFunction("step_frame", stepFrame);
    methods.setFunction("save", saveEngine);
    methods.setFunction("restore", restoreEngine);
    methods.setFunction("identity", identity);
    methods.setFunction("close", closeEngine);

    if (!lua.registerUserdata<Owner>(kUserdataType, meta))
        return lua.pushError();
    // 注册成功后才把方法表绑定到 userdata 类型，提供 Lua 冒号调用入口。
    meta.writeValue("__index", methods);

    // 模块 table 只导出资产预加载与 Engine 创建两个构造阶段 API。
    auto module = lua.newTable();
    module.setFunction("preload", preloadAssets);
    module.setFunction("open", openEngine);

    return lua.returnValues(module);
}
