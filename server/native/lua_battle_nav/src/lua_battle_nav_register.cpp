// 职责：把进程级 MapRegistry 指针绑定为当前 Lua 模块的只读 upvalue。
// 边界：Server 启动接线；每个 Lua State 初始化一次。
// 输入/输出：lua_State + Registry -> 全局 battle_nav 模块 table。
// 不负责：不加载地图，不执行查询，不跨 Lua State 共享 table。
#include "lua_battle_nav.h"
#include "map_registry.h"

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

// 在启动阶段把非 owning registry 指针绑定进模块闭包，并设置全局 battle_nav。
// L 独占当前 Service 的 Lua State；本函数不加载地图、不 yield，成功返回 0。
extern "C" int battle_nav_register(lua_State* L,
                                    battle_nav::MapRegistry* registry) {
    lua_pushlightuserdata(L, registry);
    lua_pushcclosure(L, luaopen_battle_nav, 1);
    lua_call(L, 0, 1);
    lua_setglobal(L, "battle_nav");
    return 0;
}