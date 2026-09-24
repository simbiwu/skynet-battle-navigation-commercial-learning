// 职责：声明 battle_nav Lua C 模块入口。
// 边界：Server Native/Lua ABI；头文件不暴露 GridMap 实现细节。
// 输入/输出：当前 lua_State -> 压入一个模块 table 并返回结果数量。
// 不负责：不启动 Skynet Service，不持有 Lua State。
#pragma once

struct lua_State;

extern "C" int luaopen_battle_nav(lua_State* L);