// 职责：在 Lua table 与 Native 导航类型之间做参数和结果转换。
// 边界：Server Runtime Binding；只调用 MapRegistry/GridMap，不包含 Skynet 业务。
// 输入/输出：Lua map/version/WorldPosition -> 查询结果 table 或 nil + error table。
// 生命周期：临时值只存在于当前 Lua 调用栈；不保存全局 mutable scratch。
// 不负责：不 yield、不执行 skynet.call、不管理动态单位。
#include "lua_battle_nav.h"
#include "agent_profile.h"
#include "grid_pathfinder.h"
#include "navigation_context.h"
#include "navigation_path.h"
#include "map_registry.h"

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

#include <cstdint>
#include <limits>
#include <string>
#include <exception>
#include <memory>
#include <new>
#include <utility>
#include <vector>
namespace {

using battle_nav::MapRegistry;
using battle_nav::DynamicNavigationPolicy;
using battle_nav::NavigationAgent;
using battle_nav::NavigationAgentHandle;

// 这些 helper 的实现保留在文件后部；先声明，供前面的 Binding 入口调用。
// 从 Lua table 读取 int32 字段；缺失、类型错误或越界会通过 luaL_error 失败。
std::int32_t int32_field(lua_State* L, int index, const char* name);
// 从 Lua table 读取 int64 世界毫米坐标；Skynet Lua 5.4 的 lua_Integer 为 64 位。
std::int64_t int64_field(lua_State* L, int index, const char* name);

// 压入 nil 和 {code,message}；message 由 Lua 复制持有，返回两个 Lua 结果。
void push_error(lua_State* L, const char* code, const std::string& message);

// 读取模块闭包 upvalue 中的非 owning Registry 指针；Registry 生命周期覆盖 Lua State。
MapRegistry* registry(lua_State* L);

// 检查目标 footprint 是否只被当前实体占用；定义位于后续的 DynamicOccupancy helper 区域。
bool ExclusiveDynamicRule(
    void*,
    const battle_nav::DynamicNavigationQuery& query);

constexpr const char* kContextMeta = "battle_nav.NavigationContext";
constexpr const char* kPathMeta = "battle_nav.Path";

struct LuaNavigationContext {
    std::unique_ptr<battle_nav::NavigationContext> context; // 当前 Lua State 独占。
    std::vector<battle_nav::AgentProfile> profiles;         // 创建后冻结，只读查找。
    bool closed = false;                                    // close/__gc 后拒绝调用。
};

struct LuaPath {
    battle_nav::Path path; // userdata 独占 immutable Path 结果。
    battle_nav::PathFollowCursor cursor;     // 这条路线自己的跟随进度。
};

// 校验 Context userdata 类型和生命周期；关闭后返回 nullptr，不转移所有权。
LuaNavigationContext* check_context(lua_State* L, int index) {
    auto* value = static_cast<LuaNavigationContext*>(
        luaL_checkudata(L, index, kContextMeta));
    if (value->closed || !value->context) {
        return nullptr;
    }
    return value;
}

// 校验 Path userdata 类型并返回 non-owning 指针；类型错误 luaL_error。
LuaPath* check_path(lua_State* L, int index) {
    return static_cast<LuaPath*>(luaL_checkudata(L, index, kPathMeta));
}

// 按稳定 profile_id 线性查找只读配置；不存在返回 nullptr。
const battle_nav::AgentProfile* find_profile(
    const LuaNavigationContext& owner,
    std::uint32_t profile_id) {
    for (const auto& profile : owner.profiles) {
        if (profile.id == profile_id) return &profile;
    }
    return nullptr;
}

// 从 Lua table 读取 int64 毫米 WorldPosition；字段缺失或类型错误 luaL_error。
battle_nav::WorldPosition world_position(lua_State* L, int index) {
    luaL_checktype(L, index, LUA_TTABLE);
    battle_nav::WorldPosition p;
    p.x_mm = int64_field(L, index, "x_mm");
    p.y_mm = int64_field(L, index, "y_mm");
    p.z_mm = int64_field(L, index, "z_mm");
    return p;
}

// 读取正 uint32 业务 ID；当前查询必须明确传入已有实体的 self 句柄。
// 越界通过 luaL_error 终止当前 Lua 调用，不允许 0 或负数变成有效 ID。
std::uint32_t uint32_arg(
    lua_State* L,
    int index,
    const char* name) {
    const lua_Integer raw = luaL_checkinteger(L, index);
    if (raw < 1 ||
        static_cast<std::uint64_t>(raw) >
            std::numeric_limits<std::uint32_t>::max()) {
        luaL_error(L, "%s outside uint32 business range", name);
    }
    return static_cast<std::uint32_t>(raw);
}

// 把一个毫米 WorldPosition 复制为新 Lua table；栈净增加 1。
void push_world_position(lua_State* L, const battle_nav::WorldPosition& p) {
    lua_newtable(L);

    lua_pushinteger(L, p.x_mm);
    lua_setfield(L, -2, "x_mm");

    lua_pushinteger(L, p.y_mm);
    lua_setfield(L, -2, "y_mm");

    lua_pushinteger(L, p.z_mm);
    lua_setfield(L, -2, "z_mm");
}

// 压入 nil,{code,message} 并返回 Lua 结果数量 2。
int push_nav_failure(
    lua_State* L,
    battle_nav::NavError error,
    const std::string& detail) {
    push_error(L, battle_nav::NavErrorName(error), detail);
    return 2;
}

// 把 immutable Path 和该实体私有 cursor move 进新 userdata；栈净增加 1。
void push_path(lua_State* L, battle_nav::Path path) {
    void* storage = lua_newuserdatauv(L, sizeof(LuaPath), 0);
    new (storage) LuaPath{
        std::move(path),
        battle_nav::PathFollowCursor{}};
    luaL_getmetatable(L, kPathMeta);
    lua_setmetatable(L, -2);
}

// 解析并验证一项 Lua Profile；返回按值快照，字段错误 luaL_error。
battle_nav::AgentProfile parse_profile(lua_State* L, int index) {
    const int abs = lua_absindex(L, index);
    luaL_checktype(L, abs, LUA_TTABLE);

    battle_nav::AgentProfile profile = battle_nav::MakeDefaultAgentProfile(1);

    lua_getfield(L, abs, "id");
    const lua_Integer raw_id = luaL_checkinteger(L, -1);
    lua_pop(L, 1);
    if (raw_id <= 0 ||
        static_cast<std::uint64_t>(raw_id) >
            std::numeric_limits<std::uint32_t>::max()) {
        luaL_error(L, "profile id must be positive uint32");
    }
    profile.id = static_cast<std::uint32_t>(raw_id);

    profile.radius_mm = int32_field(L, abs, "radius_mm");
    profile.max_step_mm = int32_field(L, abs, "max_step_mm");

    lua_getfield(L, abs, "max_slope_permille");
    const lua_Integer slope = luaL_checkinteger(L, -1);
    lua_pop(L, 1);
    if (slope < 0 || slope > std::numeric_limits<std::uint32_t>::max()) {
        luaL_error(L, "max_slope_permille outside uint32 range");
    }
    profile.max_slope_permille = static_cast<std::uint32_t>(slope);

    // area_cost_permille 使用 Lua key=0..255；未配置保持默认 1000。
    lua_getfield(L, abs, "area_cost_permille");
    if (lua_istable(L, -1)) {
        for (int area = 0; area < 256; ++area) {
            lua_geti(L, -1, area);
            if (!lua_isnil(L, -1)) {
                const lua_Integer cost = luaL_checkinteger(L, -1);
                if (cost < 0 || cost > 65535) {
                    luaL_error(L, "area cost outside uint16 range");
                }
                profile.area_cost_permille[area] =
                    static_cast<std::uint16_t>(cost);
            }
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1);

    lua_getfield(L, abs, "area_allowed");
    if (lua_istable(L, -1)) {
        for (int area = 0; area < 256; ++area) {
            lua_geti(L, -1, area);
            if (!lua_isnil(L, -1)) {
                profile.area_allowed[area] = lua_toboolean(L, -1) ? 1 : 0;
            }
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1);

    // NavResult 内含 std::string；先让它离开作用域再 luaL_error，
    // 避免 Lua longjmp 跳过 C++ 对象析构。
    const char* validation_error = nullptr;
    {
        const auto valid = battle_nav::ValidateAgentProfile(profile);
        if (!valid.ok()) {
            validation_error = battle_nav::NavErrorName(valid.error);
        }
    }
    if (validation_error != nullptr) {
        luaL_error(L, "invalid agent profile: %s", validation_error);
    }
    return profile;
}

// Lua battle_nav.new_context(map_id, map_version, profiles_array)
// 成功返回 context userdata；地图查找只持有第一课 Registry 短锁，不 yield。
int l_new_context(lua_State* L) {
    // 数据准备：读取并校验地图标识和 Profile 数组参数。
    auto* maps = registry(L);
    const lua_Integer raw_map_id = luaL_checkinteger(L, 1);
    const lua_Integer raw_map_version = luaL_checkinteger(L, 2);
    if (raw_map_id <= 0 || raw_map_version <= 0 ||
        static_cast<std::uint64_t>(raw_map_id) > std::numeric_limits<std::uint32_t>::max() ||
        static_cast<std::uint64_t>(raw_map_version) > std::numeric_limits<std::uint32_t>::max()) {
        return luaL_error(L, "map_id/map_version must be positive uint32");
    }
    const auto map_id = static_cast<std::uint32_t>(raw_map_id);
    const auto map_version = static_cast<std::uint32_t>(raw_map_version);
    luaL_checktype(L, 3, LUA_TTABLE);

    // 先构造并挂 metatable。后续 luaL_check* 可能通过 Lua longjmp 报错；
    // userdata 已受 GC 管理，profiles/context 不会因跳过 C++ 栈析构而泄漏。
    void* storage = lua_newuserdatauv(L, sizeof(LuaNavigationContext), 0);
    auto* owner = new (storage) LuaNavigationContext;
    luaL_getmetatable(L, kContextMeta);
    lua_setmetatable(L, -2);

    try {
        // found 的 NavResult 含 std::string；把它限制在本作用域中，确保在调用任何
        // 可能 luaL_error 的 profile parser 之前完成正常 C++ 析构。
        {
            const auto found = maps->Find(map_id, map_version);
            if (!found.ok()) {
                return push_nav_failure(L, found.error, found.detail);
            }
            owner->context.reset(
                new battle_nav::NavigationContext(found.value));
        }

        // 核心计算：查找地图、解析 Profile，并检查 Profile ID 唯一性。
        const lua_Integer count = luaL_len(L, 3);
        if (count <= 0) {
            return luaL_error(L, "profiles must not be empty");
        }
        owner->profiles.reserve(static_cast<std::size_t>(count));
        for (lua_Integer i = 1; i <= count; ++i) {
            lua_geti(L, 3, i);
            const battle_nav::AgentProfile profile = parse_profile(L, -1);
            lua_pop(L, 1);
            for (const auto& existing : owner->profiles) {
                if (existing.id == profile.id) {
                    return luaL_error(
                        L, "duplicate profile id: %u", profile.id);
                }
            }
            owner->profiles.push_back(profile);
        }
        // 状态修改：完成初始化后才允许 Context 被调用。
        owner->closed = false;
    } catch (const std::exception& exception) {
        // C++ exception 不能穿越 Lua C ABI；userdata 保持有效并由 __gc 析构。
        return push_nav_failure(
            L, battle_nav::NavError::kInternalError, exception.what());
    }
    // 收尾：把已初始化的 Context userdata 返回 Lua。
    return 1;
}

// 从 request table 读取 uint32；allow_zero=false 时 0 也属于合同错误。
// 字段缺失、类型错误或越界通过 luaL_error 终止当前 Lua 调用；栈净变化为 0。
std::uint32_t uint32_request_field(
    lua_State* L,
    int request_index,
    const char* name,
    bool allow_zero) {
    const int request = lua_absindex(L, request_index);
    lua_getfield(L, request, name);
    const lua_Integer raw = luaL_checkinteger(L, -1);
    lua_pop(L, 1);
    if (raw < (allow_zero ? 0 : 1) ||
        static_cast<std::uint64_t>(raw) >
            std::numeric_limits<std::uint32_t>::max()) {
        luaL_error(L, "field '%s' outside uint32 range", name);
    }
    return static_cast<std::uint32_t>(raw);
}

// 把 Native 状态映射为稳定 Lua 字符串；未知枚举视为 Native 编程错误。
const char* path_advance_status_name(
    battle_nav::PathAdvanceStatus status) {
    switch (status) {
    case battle_nav::PathAdvanceStatus::kMoving: return "moving";
    case battle_nav::PathAdvanceStatus::kReached: return "reached";
    case battle_nav::PathAdvanceStatus::kBlocked: return "blocked";
    }
    return nullptr;
}

// Lua context:advance_path(request)：消费一个 fixed-tick 距离预算并返回最后成功位置。
// request 的 path/from_world 只在本次同步调用借用；函数不 I/O、不加锁、不 yield。
// blocked 是成功 result 状态；参数、生命周期或 Native 内部错误返回 nil,error。
int l_context_advance_path(lua_State* L) {
    // 参数/状态检查：确认 Context、Profile、Unit 和 Path 都有效。
    LuaNavigationContext* owner = check_context(L, 1);
    if (owner == nullptr) {
        return push_nav_failure(
            L, battle_nav::NavError::kContextClosed, "context is closed");
    }
    luaL_checktype(L, 2, LUA_TTABLE);

    const std::uint32_t profile_id =
        uint32_request_field(L, 2, "profile_id", false);
    const std::uint32_t unit_id =
        uint32_request_field(L, 2, "unit_id", false);
    const std::uint32_t distance_mm =
        uint32_request_field(L, 2, "distance_mm", true);
    const auto* profile = find_profile(*owner, profile_id);
    if (profile == nullptr) {
        return push_nav_failure(
            L, battle_nav::NavError::kInvalidAgent,
            "profile_id not found");
    }

    lua_getfield(L, 2, "path");
    LuaPath* path_owner = check_path(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, 2, "from_world");
    const battle_nav::WorldPosition from_world = world_position(L, -1);
    lua_pop(L, 1);

    // 核心计算：调用 Native 同步推进路径。
    try {
        const NavigationAgent agent{
            NavigationAgentHandle{unit_id},
            profile};
        const DynamicNavigationPolicy dynamic_policy{
            nullptr,
            &ExclusiveDynamicRule};
        auto advanced = battle_nav::GridPathfinder::AdvancePath(
            *owner->context,
            agent,
            path_owner->path,
            path_owner->cursor,
            from_world,
            distance_mm,
            dynamic_policy);
        if (!advanced.ok()) {
            return push_nav_failure(
                L, advanced.error, advanced.detail);
        }

        const char* status = path_advance_status_name(advanced.value.status);
        if (status == nullptr) {
            return push_nav_failure(
                L, battle_nav::NavError::kInternalError,
                "unknown PathAdvanceStatus");
        }
        // 收尾：把 Native 结果转换为 Lua record。
        lua_newtable(L);
        lua_pushstring(L, status);
        lua_setfield(L, -2, "status");
        push_world_position(L, advanced.value.position);
        lua_setfield(L, -2, "position");
        lua_pushinteger(L, advanced.value.consumed_mm);
        lua_setfield(L, -2, "consumed_mm");
        lua_pushboolean(L, advanced.value.moved ? 1 : 0);
        lua_setfield(L, -2, "moved");
        return 1;
    } catch (const std::exception& exception) {
        return push_nav_failure(
            L, battle_nav::NavError::kInternalError, exception.what());
    }
}

// 判断 agent 的整个目标 footprint 是否只包含自己。
// query 中所有指针只在本次同步调用期间有效；本函数不保存引用、不分配、不 yield。
bool ExclusiveDynamicRule(
    void*,
    const battle_nav::DynamicNavigationQuery& query) {
    if (query.agent == nullptr || query.agent->profile == nullptr ||
        query.occupancy == nullptr) {
        return false;
    }

    const battle_nav::NavigationAgentHandle self = query.agent->handle;
    return query.occupancy->ForEachFootprintCell(
        *query.agent->profile,
        query.target,
        [&](const battle_nav::GridPos& grid) {
            bool allowed = true;
            query.occupancy->ForEachOccupant(
                grid,
                [&](battle_nav::NavigationAgentHandle other) {
                    if (other != self) {
                        allowed = false;
                        return false;
                    }
                    return true;
                });
            return allowed;
        });
}

// Lua context:find_path：读取毫米世界坐标并同步查询；成功返回 Path userdata，失败 nil,error。
int l_context_find_path(lua_State* L) {
    LuaNavigationContext* owner = check_context(L, 1);
    if (owner == nullptr) {
        return push_nav_failure(L, battle_nav::NavError::kContextClosed, "context is closed");
    }
    const auto profile_id = uint32_arg(L, 2, "profile_id");
    const auto* profile = find_profile(*owner, profile_id);
    if (profile == nullptr) {
        return push_nav_failure(L, battle_nav::NavError::kInvalidAgent, "profile_id not found");
    }
    const auto start = world_position(L, 3);
    const auto end = world_position(L, 4);
    const auto self_id = uint32_arg(L, 5, "self_unit_id");

    try {
        const NavigationAgent agent{
            NavigationAgentHandle{self_id},
            profile};
        const DynamicNavigationPolicy dynamic_policy{
            nullptr,
            &ExclusiveDynamicRule};
        auto result = battle_nav::GridPathfinder::FindPath(
            *owner->context,
            agent,
            start,
            end,
            dynamic_policy);
        if (!result.ok()) {
            return push_nav_failure(L, result.error, result.detail);
        }
        push_path(L, std::move(result.value));
        return 1;
    } catch (const std::exception& exception) {
        return push_nav_failure(
            L, battle_nav::NavError::kInternalError, exception.what());
    }
}

// Lua context:find_path_to_range：搜索合法攻击位置；不忽略 target 占位，不 yield。
int l_context_find_path_to_range(lua_State* L) {
    LuaNavigationContext* owner = check_context(L, 1);
    if (owner == nullptr) {
        return push_nav_failure(L, battle_nav::NavError::kContextClosed, "context is closed");
    }
    const auto profile_id = uint32_arg(L, 2, "profile_id");
    const auto* profile = find_profile(*owner, profile_id);
    if (profile == nullptr) {
        return push_nav_failure(L, battle_nav::NavError::kInvalidAgent, "profile_id not found");
    }
    const auto start = world_position(L, 3);
    const auto target = world_position(L, 4);
    const lua_Integer raw_range = luaL_checkinteger(L, 5);
    const auto self_id = uint32_arg(L, 6, "self_unit_id");
    if (raw_range < 0 || raw_range > std::numeric_limits<std::uint32_t>::max()) {
        return luaL_error(L, "attack_range_mm outside uint32 range");
    }

    try {
        const NavigationAgent agent{
            NavigationAgentHandle{self_id},
            profile};
        const DynamicNavigationPolicy dynamic_policy{
            nullptr,
            &ExclusiveDynamicRule};
        auto result = battle_nav::GridPathfinder::FindPathToRange(
            *owner->context,
            agent,
            start,
            target,
            static_cast<std::uint32_t>(raw_range),
            dynamic_policy);
        if (!result.ok()) {
            return push_nav_failure(L, result.error, result.detail);
        }
        push_path(L, std::move(result.value));
        return 1;
    } catch (const std::exception& exception) {
        return push_nav_failure(
            L, battle_nav::NavError::kInternalError, exception.what());
    }
}

// Lua context:place_unit：出生场景的薄包装；用同一个 MoveUnit 规则提交首个 footprint。
// 成功返回 Server 地表 Y 归一化的 WorldPosition；失败不改变原有动态事实。
int l_context_place_unit(lua_State* L) {
    LuaNavigationContext* owner = check_context(L, 1);
    if (owner == nullptr) {
        return push_nav_failure(L, battle_nav::NavError::kContextClosed, "context is closed");
    }
    const auto profile_id = uint32_arg(L, 2, "profile_id");
    const auto unit_id = uint32_arg(L, 3, "unit_id");
    const auto* profile = find_profile(*owner, profile_id);
    if (profile == nullptr) {
        return push_nav_failure(L, battle_nav::NavError::kInvalidAgent, "profile_id not found");
    }
    const auto world = world_position(L, 4);
    const auto grid = owner->context->map()->WorldToGrid(world);
    if (!grid.ok()) return push_nav_failure(L, grid.error, grid.detail);

    try {
        // 先准备返回位置；失败时尚未写入 Occupancy，不需要回滚已有 footprint。
        auto normalized = owner->context->map()->GridToWorldCenter(grid.value);
        if (!normalized.ok()) {
            return push_nav_failure(L, normalized.error, normalized.detail);
        }

        // 出生也是一次 from==to 的 MoveUnit：使用与真实移动相同的静态、
        // Grid/Cell 动态配置和业务回调，不能直接写 DynamicOccupancy 绕过冲突规则。
        const NavigationAgent agent{NavigationAgentHandle{unit_id}, profile};
        const DynamicNavigationPolicy dynamic_policy{
            nullptr, &ExclusiveDynamicRule};
        const auto placed = battle_nav::GridPathfinder::MoveUnit(
            *owner->context, agent, world, world, dynamic_policy);
        if (!placed.ok()) {
            return push_nav_failure(L, placed.error, placed.detail);
        }

        // Battle 正式位置保留输入 XZ；Y 来自 Server Grid 的权威地表高度。
        normalized.value.x_mm = world.x_mm;
        normalized.value.z_mm = world.z_mm;
        push_world_position(L, normalized.value);
        return 1;
    } catch (const std::exception& exception) {
        return push_nav_failure(
            L, battle_nav::NavError::kInternalError, exception.what());
    }
}

// Lua context:move_unit：复验当前子步并提交占位；成功返回 Server 地表 Y 归一的世界位置。
// from/to 为毫米世界坐标，to 的 X/Z 保留，Y 由目标 Cell 的 BMAP 高度决定。
// 失败返回 nil,error 且不写入新的动态事实；同步调用，不 I/O、不 yield。
int l_context_move_unit(lua_State* L) {
    LuaNavigationContext* owner = check_context(L, 1);
    if (owner == nullptr) {
        return push_nav_failure(L, battle_nav::NavError::kContextClosed, "context is closed");
    }
    const auto profile_id = uint32_arg(L, 2, "profile_id");
    const auto unit_id = uint32_arg(L, 3, "unit_id");
    const auto* profile = find_profile(*owner, profile_id);
    if (profile == nullptr) {
        return push_nav_failure(L, battle_nav::NavError::kInvalidAgent, "profile_id not found");
    }
    const auto from_world = world_position(L, 4);
    const auto to_world = world_position(L, 5);
    // 缓存路径生成后动态占位仍会变化。正式提交必须重新验证本次跨格，
    // 包括对角侧格；只检查终点 footprint 会允许动态 corner cutting。
    try {
        // 先准备权威返回位置；若归格失败，尚未提交 Occupancy。
        const auto to_grid = owner->context->map()->WorldToGrid(to_world);
        if (!to_grid.ok()) {
            return push_nav_failure(L, to_grid.error, to_grid.detail);
        }
        auto normalized = owner->context->map()->GridToWorldCenter(to_grid.value);
        if (!normalized.ok()) {
            return push_nav_failure(L, normalized.error, normalized.detail);
        }

        const NavigationAgent agent{
            NavigationAgentHandle{unit_id},
            profile};
        const DynamicNavigationPolicy dynamic_policy{
            nullptr,
            &ExclusiveDynamicRule};
        const auto moved = battle_nav::GridPathfinder::MoveUnit(
            *owner->context,
            agent,
            from_world,
            to_world,
            dynamic_policy);
        if (!moved.ok()) return push_nav_failure(L, moved.error, moved.detail);
        // 成功提交后，Battle 保存与静态地图一致的 Y，不使用折线端点的 Y 插值。
        normalized.value.x_mm = to_world.x_mm;
        normalized.value.z_mm = to_world.z_mm;
        push_world_position(L, normalized.value);
        return 1;
    } catch (const std::exception& exception) {
        return push_nav_failure(
            L, battle_nav::NavError::kInternalError, exception.what());
    }
}

// 返回当前 Context 静态地图 Cell 边长，单位毫米；只读、零分配、不 yield。
int l_context_cell_size_mm(lua_State* L) {
    LuaNavigationContext* owner = check_context(L, 1);
    if (owner == nullptr) {
        return push_nav_failure(L, battle_nav::NavError::kContextClosed, "context is closed");
    }
    lua_pushinteger(L, owner->context->map()->metadata().cell_size_mm);
    return 1;
}

// Lua context:release_unit：释放该 handle 当前记录的 footprint；成功返回 true。
int l_context_release_unit(lua_State* L) {
    LuaNavigationContext* owner = check_context(L, 1);
    if (owner == nullptr) {
        return push_nav_failure(L, battle_nav::NavError::kContextClosed, "context is closed");
    }
    const auto unit_id = uint32_arg(L, 2, "unit_id");
    try {
        const NavigationAgentHandle handle{unit_id};
        const auto released = owner->context->occupancy().Release(
            handle);
        if (!released.ok()) {
            return push_nav_failure(L, released.error, released.detail);
        }
        lua_pushboolean(L, 1);
        return 1;
    } catch (const std::exception& exception) {
        return push_nav_failure(
            L, battle_nav::NavError::kInternalError, exception.what());
    }
}

// 返回 Path 世界点数量；不分配、不修改 Path。
int l_path_count(lua_State* L) {
    auto* value = check_path(L, 1);
    lua_pushinteger(L, static_cast<lua_Integer>(value->path.count()));
    return 1;
}

// 返回 Lua 1-based index 对应的毫米 WorldPosition table；越界 luaL_error。
int l_path_world_point(lua_State* L) {
    auto* value = check_path(L, 1);
    const lua_Integer lua_index = luaL_checkinteger(L, 2);
    if (lua_index <= 0 ||
        static_cast<std::size_t>(lua_index) > value->path.count()) {
        return luaL_error(L, "path index out of range");
    }
    push_world_position(L, value->path.WorldPoint(
        static_cast<std::size_t>(lua_index - 1)));
    return 1;
}

// 返回 XZ 折线总长度，单位毫米。
int l_path_length_mm(lua_State* L) {
    auto* value = check_path(L, 1);
    lua_pushinteger(L, static_cast<lua_Integer>(value->path.length_mm()));
    return 1;
}

// 析构 placement-new LuaPath；仅由 Lua __gc 调用一次。
int l_path_gc(lua_State* L) {
    auto* value = check_path(L, 1);
    value->~LuaPath();
    return 0;
}

// 幂等关闭 Context 的大块 Native 内存；userdata 本体保留到 __gc。
int l_context_close(lua_State* L) {
    auto* owner = static_cast<LuaNavigationContext*>(
        luaL_checkudata(L, 1, kContextMeta));
    if (!owner->closed) {
        owner->context.reset();
        owner->closed = true;
    }
    return 0;
}

// __gc 必须真正调用 placement-new 对象析构函数；vector capacity 才会释放。
// 析构 placement-new owner，释放 profiles capacity 和尚未 close 的 Context。
int l_context_gc(lua_State* L) {
    auto* owner = static_cast<LuaNavigationContext*>(
        luaL_checkudata(L, 1, kContextMeta));
    owner->~LuaNavigationContext();
    return 0;
}

// 在当前 Lua State 注册一次 Path metatable；栈净变化为 0。
void register_path_meta(lua_State* L) {
    if (luaL_newmetatable(L, kPathMeta)) {
        lua_pushcfunction(L, l_path_gc);
        lua_setfield(L, -2, "__gc");
        lua_newtable(L);
        lua_pushcfunction(L, l_path_count); lua_setfield(L, -2, "count");
        lua_pushcfunction(L, l_path_world_point); lua_setfield(L, -2, "world_point");
        lua_pushcfunction(L, l_path_length_mm); lua_setfield(L, -2, "length_mm");
        lua_setfield(L, -2, "__index");
    }
    lua_pop(L, 1);
}

// 在当前 Lua State 注册一次 Context metatable；栈净变化为 0。
void register_context_meta(lua_State* L) {
    if (luaL_newmetatable(L, kContextMeta)) {
        lua_pushcfunction(L, l_context_gc);
        lua_setfield(L, -2, "__gc");
        lua_newtable(L);
        lua_pushcfunction(L, l_context_find_path);
        lua_setfield(L, -2, "find_path");
        lua_pushcfunction(L, l_context_find_path_to_range);
        lua_setfield(L, -2, "find_path_to_range");
        lua_pushcfunction(L, l_context_place_unit);
        lua_setfield(L, -2, "place_unit");
        lua_pushcfunction(L, l_context_move_unit);
        lua_setfield(L, -2, "move_unit");
        lua_pushcfunction(L, l_context_release_unit);
        lua_setfield(L, -2, "release_unit");
        lua_pushcfunction(L, l_context_advance_path);
        lua_setfield(L, -2, "advance_path");
        lua_pushcfunction(L, l_context_cell_size_mm);
        lua_setfield(L, -2, "cell_size_mm");
        lua_pushcfunction(L, l_context_close);
        lua_setfield(L, -2, "close");
        lua_setfield(L, -2, "__index");
    }
    lua_pop(L, 1);
}

// 读取模块闭包的第一个 upvalue，并返回非 owning Registry 指针。
// Registry 生命周期覆盖 Lua State；注册阶段必须保证指针非空。
// 本课保留闭包捕获，用于展示 Native 依赖可以在注册函数时显式绑定。
// Registry 固定为进程级单例；实际工程也可由 C 入口直接调用 Instance()，省去 upvalue。
MapRegistry* registry(lua_State* L) {
    void* p = lua_touserdata(L, lua_upvalueindex(1));
    return static_cast<MapRegistry*>(p);
}

// 从 index 指向的 Lua table 读取 AgentProfile 用的 int32 字段；缺失、类型错误或越界触发 luaL_error。
std::int32_t int32_field(lua_State* L, int index, const char* name) {
    lua_getfield(L, index, name);
    if (!lua_isinteger(L, -1)) {
        luaL_error(L, "field '%s' must be integer", name);
    }
    const lua_Integer value = lua_tointeger(L, -1);
    lua_pop(L, 1);
    if (value < std::numeric_limits<std::int32_t>::min() ||
        value > std::numeric_limits<std::int32_t>::max()) {
        luaL_error(L, "field '%s' is outside int32 range", name);
    }
    return static_cast<std::int32_t>(value);
}

// 读取 WorldPosition 的 int64 毫米字段；Lua 5.4 的 lua_Integer 与此合同同为有符号 64 位。
std::int64_t int64_field(lua_State* L, int index, const char* name) {
    static_assert(
        std::numeric_limits<lua_Integer>::digits == 63,
        "WorldPosition requires a 64-bit Lua integer");
    lua_getfield(L, index, name);
    if (!lua_isinteger(L, -1)) {
        luaL_error(L, "field '%s' must be integer", name);
    }
    const lua_Integer value = lua_tointeger(L, -1);
    lua_pop(L, 1);
    return static_cast<std::int64_t>(value);
}

// 向 Lua 栈压入 nil 和 {code,message} 两个返回值；message bytes 由 Lua 复制持有。
void push_error(lua_State* L, const char* code, const std::string& message) {
    lua_pushnil(L);
    lua_newtable(L);
    lua_pushstring(L, code);
    lua_setfield(L, -2, "code");
    lua_pushlstring(L, message.data(), message.size());
    lua_setfield(L, -2, "message");
}

// Lua load_map(path) 入口；在启动阶段读取、校验并注册一份 BMAP。
// 成功返回 {map_id,map_version}；失败返回 nil,error；本函数执行文件 I/O。
int l_load_map(lua_State* L) {
    auto* maps = registry(L);
    const char* path = luaL_checkstring(L, 1);
    const auto loaded = maps->Load(path);
    if (!loaded.ok()) {
        push_error(L, battle_nav::NavErrorName(loaded.error), loaded.detail);
        return 2;
    }

    const auto& metadata = loaded.value->metadata();
    lua_newtable(L);
    lua_pushinteger(L, metadata.map_id);
    lua_setfield(L, -2, "map_id");
    lua_pushinteger(L, metadata.map_version);
    lua_setfield(L, -2, "map_version");
    return 1;
}

// Lua query_cell(map_id, version, position) 入口。
// 成功返回一个结果 table；失败返回 nil,error；不 yield、不保存请求状态。
int l_query_cell(lua_State* L) {
    auto* maps = registry(L);
    const lua_Integer raw_map_id = luaL_checkinteger(L, 1);
    const lua_Integer raw_version = luaL_checkinteger(L, 2);
    if (raw_map_id <= 0 ||
        static_cast<std::uint64_t>(raw_map_id) > std::numeric_limits<std::uint32_t>::max() ||
        raw_version <= 0 ||
        static_cast<std::uint64_t>(raw_version) > std::numeric_limits<std::uint32_t>::max()) {
        return luaL_error(L, "map_id/version must be positive uint32");
    }
    const auto map_id = static_cast<std::uint32_t>(raw_map_id);
    const auto version = static_cast<std::uint32_t>(raw_version);
    luaL_checktype(L, 3, LUA_TTABLE);

    battle_nav::WorldPosition position;
    position.x_mm = int64_field(L, 3, "x_mm");
    position.y_mm = int64_field(L, 3, "y_mm");
    position.z_mm = int64_field(L, 3, "z_mm");

    const auto found = maps->Find(map_id, version);
    if (!found.ok()) {
        push_error(L, battle_nav::NavErrorName(found.error), found.detail);
        return 2;
    }
    const auto& map = *found.value;

    const auto grid = map.WorldToGrid(position);
    if (!grid.ok()) {
        push_error(L, battle_nav::NavErrorName(grid.error), grid.detail);
        return 2;
    }

    const auto result = map.QueryWorld(position);
    if (!result.ok()) {
        push_error(L, battle_nav::NavErrorName(result.error), result.detail);
        return 2;
    }

    const auto& cell = result.value;
    lua_newtable(L);
    lua_pushinteger(L, grid.value.x);
    lua_setfield(L, -2, "grid_x");
    lua_pushinteger(L, grid.value.z);
    lua_setfield(L, -2, "grid_z");
    lua_pushinteger(L, cell.height_mm);
    lua_setfield(L, -2, "cell_height_mm");
    lua_pushinteger(L, cell.area_type);
    lua_setfield(L, -2, "area");
    lua_pushinteger(L, cell.clearance_cells);
    lua_setfield(L, -2, "clearance");
    lua_pushboolean(L, cell.IsWalkable() ? 1 : 0);
    lua_setfield(L, -2, "walkable");
    return 1;
}

} // namespace

// 标准 Lua require 入口：为当前 Lua State 创建模块 table，并把进程级 Registry
// 指针绑定到两个函数的 closure。Registry 由 C++ 单例持有，Lua 只保存 non-owning
// lightuserdata；本函数不执行文件 I/O、不分配跨调用 scratch、不 yield。
// 返回 1 表示把栈顶模块 table 交给 require 缓存并返回。
extern "C" int luaopen_battle_nav(lua_State* L) {
    luaL_checkversion(L);

    register_context_meta(L);
    register_path_meta(L);
    lua_newtable(L);

    lua_pushlightuserdata(L, &MapRegistry::Instance());
    lua_pushcclosure(L, l_load_map, 1);
    lua_setfield(L, -2, "load_map");

    lua_pushlightuserdata(L, &MapRegistry::Instance());
    lua_pushcclosure(L, l_query_cell, 1);
    lua_setfield(L, -2, "query_cell");

    lua_pushlightuserdata(L, &MapRegistry::Instance());
    lua_pushcclosure(L, l_new_context, 1);
    lua_setfield(L, -2, "new_context");
    return 1;
}
