// 职责：在 Lua table 与 Native 导航类型之间做参数和结果转换。
// 边界：Server Runtime Binding；只调用 MapRegistry/GridMap，不包含 Skynet 业务。
// 输入/输出：Lua map/version/WorldPosition -> 查询结果 table 或 nil + error table。
// 生命周期：临时值只存在于当前 Lua 调用栈；不保存全局 mutable scratch。
// 不负责：不 yield、不执行 skynet.call、不管理动态单位。
#include "lua_battle_nav.h"

#include "map_registry.h"

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

#include <cstdint>
#include <limits>
#include <string>

namespace {

using battle_nav::MapRegistry;

// 读取模块闭包的第一个 upvalue，并返回非 owning Registry 指针。
// Registry 生命周期覆盖 Lua State；注册阶段必须保证指针非空。
MapRegistry* registry(lua_State* L) {
    void* p = lua_touserdata(L, lua_upvalueindex(1));
    return static_cast<MapRegistry*>(p);
}

// 从 index 指向的 Lua table 读取 int32 字段；缺失、类型错误或越界触发 luaL_error。
// WorldPosition 的协议字段是 sint64，进入 Native int32 前必须显式检查范围。
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
    position.x_mm = int32_field(L, 3, "x_mm");
    position.y_mm = int32_field(L, 3, "y_mm");
    position.z_mm = int32_field(L, 3, "z_mm");

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
    lua_newtable(L);

    // 每个 Lua State 得到独立模块 table；closure 指向同一个进程级 immutable 地图目录。
    lua_pushlightuserdata(L, &MapRegistry::Instance());
    lua_pushcclosure(L, l_load_map, 1);
    lua_setfield(L, -2, "load_map");

    lua_pushlightuserdata(L, &MapRegistry::Instance());
    lua_pushcclosure(L, l_query_cell, 1);
    lua_setfield(L, -2, "query_cell");
    return 1;
}
