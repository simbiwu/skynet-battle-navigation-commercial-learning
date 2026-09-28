# Lua C API 与 Native Binding 入门

本文单独解释课程中使用的 Lua C API Binding。目标是让读者能看懂 `battle_nav.so` 如何被 `require` 加载、Lua 栈如何变化，以及 Lua userdata 如何持有 C++ 对象。

本文面向熟悉 C++、Lua 和 Skynet Service 的读者，不覆盖 Lua C API 全部接口。示例以课程固定的 Skynet v1.8.0 内置 PUC Lua 5.4.7 为准；其他 Lua 版本的 ABI 和 API 可能不同。

## 1. 先建立一个模型：C 函数通过栈和 Lua 交换值

Lua 调用 C 函数时，Lua 把参数放在该次调用的栈帧里。C 函数用 `lua_State* L` 找到当前 Lua State，并通过 Lua C API 读取参数、压入返回值。C 函数最后返回“返回值数量”，Lua 从栈顶取出相应数量的值作为结果。

本文中的栈图统一按这个方向读：

```text
栈底  [较早放入的值] [后来放入的值]  栈顶
```

例如：

```text
栈底  [map_id] [map_version] [profiles]  栈顶
```

本次 C 函数调用的参数索引从 1 开始。`lua_tostring(L, 1)` 读取第一个参数；`lua_tostring(L, -1)` 读取调用时栈顶参数。负索引相对当前栈顶计算：`-1` 是栈顶，`-2` 是栈顶下方一个值。每次压栈或弹栈后，负索引指向的位置都可能变化；正索引通常适合引用调用参数，负索引适合操作栈顶附近的临时值。

## 2. 常用栈操作及其净变化

下面的“弹出”表示值从 Lua 栈移除；它不一定意味着 C++ 对象析构，具体生命周期取决于 Lua 值类型。

| API | 调用前栈顶 | 调用后栈顶 | 作用 |
| --- | --- | --- | --- |
| `lua_pushinteger(L, 42)` | `...` | `... · 42` | 压入一个整数，栈净增 1。 |
| `lua_pushvalue(L, -1)` | `... · value` | `... · value · value` | 复制指定栈值并压入副本，栈净增 1。 |
| `lua_pop(L, 1)` | `... · value` | `...` | 弹出一个栈值，栈净减 1。 |
| `lua_getfield(L, index, "name")` | `... · table` | `... · table · table.name` | 读取字段并把字段值压栈，栈净增 1。 |
| `lua_setfield(L, index, "name")` | `... · table · value` | `... · table` | 把栈顶 `value` 设为 `table.name`，并弹出 value，栈净减 1。 |
| `lua_newtable(L)` | `...` | `... · table` | 新建普通 Lua table 并压栈。 |
| `luaL_getmetatable(L, name)` | `...` | `... · metatable` | 从当前 Lua State 的 registry 取出已注册元表并压栈。 |
| `lua_setmetatable(L, index)` | `... · value · metatable` | `... · value` | 把栈顶元表挂到指定值上，再弹出元表。 |

`lua_setfield` 的关键点是：它既做赋值，也弹出被赋的值。下面用实际栈状态展开：

```text
调用前：       [module table] [C function]       栈顶
lua_setfield(L, -2, "load_map")
调用后：       [module table]                    栈顶
```

调用前 `-2` 指 module table，`-1` 指 C function。API 执行后，table 中多了 `load_map` 字段，函数值从栈上弹出，所以栈顶只剩 module table。

## 3. `require` 怎样找到 Native 模块入口

Lua 执行：

```lua
local battle_nav = require "battle_nav"
```

`require` 先检查当前 Lua State 的 `package.loaded` 缓存。若模块尚未加载，它会按 `package.cpath` 搜索动态库，并按模块名寻找 C 加载入口 `luaopen_battle_nav`。找到并调用入口后，入口返回一个 Lua 值，`require` 通常把它存入 `package.loaded["battle_nav"]`，并把它作为 `require` 的结果返回。

所以 `luaopen_battle_nav` 是由模块名约定出来的加载符号，不是因为 Lua 源码显式传入了 C 函数名。C++ 入口使用 `extern "C"` 是为了使用 C linkage，避免 C++ 名字改编让动态加载器找不到约定符号。

一个 `.so` 并不被限制为只能有一个导出函数，也可以包含多个 `luaopen_*` 入口。一次 `require "battle_nav"` 只寻找与当前模块名匹配的 `luaopen_battle_nav`，不会自动调用库内所有加载入口。只要搜索路径或加载器把另一个模块名也映射到同一动态库，该库也可以提供对应的另一个 `luaopen_*` 入口。

### 3.1 从空表到返回模块

课程入口的核心结构如下：

```cpp
extern "C" int luaopen_battle_nav(lua_State* L) {
    luaL_checkversion(L);
    lua_newtable(L);

    // 此处注册函数，最终返回模块 table。
    return 1;
}
```

`lua_newtable` 只创建一个普通空 table。它在作为入口返回值、被 `require` 缓存后，才成为 Lua 代码拿到的 `battle_nav` 模块对象。`return 1` 表示把栈顶的一个值作为 C 函数结果交还给 Lua；它不是 `lua_pop`，也不是“把整数 1 返回给 Lua”。

## 4. 按步骤看闭包和 upvalue

Lua C 函数可以通过 closure 捕获创建时提供的 upvalue。以课程的 `load_map` 注册代码为例：

```cpp
lua_newtable(L);

lua_pushlightuserdata(L, &MapRegistry::Instance());
lua_pushcclosure(L, l_load_map, 1);
lua_setfield(L, -2, "load_map");

return 1;
```

每个 API 调用之后的栈如下；省略 `require` 调用框架可能提供的其他值：

| 步骤 | 调用后栈：栈底 → 栈顶 | 发生的动作 |
| --- | --- | --- |
| `lua_newtable(L)` | `[module table]` | 新建空 table 并压栈。 |
| `lua_pushlightuserdata(L, &MapRegistry::Instance())` | `[module table] [Registry 指针]` | 把不归 Lua 所有的裸指针包装成 lightuserdata 并压栈。 |
| `lua_pushcclosure(L, l_load_map, 1)` | `[module table] [load_map 闭包]` | 从栈顶取走 1 个值作为闭包 upvalue，再压入闭包。指针不再单独留在栈上。 |
| `lua_setfield(L, -2, "load_map")` | `[module table]` | `-2` 找到 table，`-1` 是闭包；写入字段后弹出闭包。 |
| `return 1` | Lua 得到 `module table` | 把栈顶一个值作为模块结果返回给 `require`。 |

逐步说就是：`lua_pushlightuserdata` 把 Registry 地址压到模块表上方；`lua_pushcclosure(..., 1)` 把这个地址收进闭包作为第一个 upvalue，并用闭包替换栈顶的地址；`lua_setfield(L, -2, "load_map")` 将闭包放入模块表并弹出闭包；入口最终返回模块表。

闭包里的 upvalue 在 C 回调中通过 `lua_upvalueindex(1)` 读取：

```cpp
MapRegistry* registry(lua_State* L) {
    void* pointer = lua_touserdata(L, lua_upvalueindex(1));
    return static_cast<MapRegistry*>(pointer);
}
```

这里的 `lua_upvalueindex(1)` 指的是这个 C closure 捕获的第一个值，不是普通函数参数栈中的第 1 项。

### 4.1 为什么单例仍然作为 upvalue 传入

课程保留这个写法，是为了展示“创建一个 Lua C 函数时，可以显式把依赖绑定到该函数实例”的机制。它让 `l_load_map` 通过 closure 获得 Registry，而不必在函数体里查找全局对象。

不过，课程里的 `MapRegistry::Instance()` 是固定的进程级单例。因此在这个具体工程实现中，捕获 Registry 并非必要：C 入口可以直接调用 `MapRegistry::Instance()`，不需要 `lua_pushlightuserdata`、`lua_pushcclosure` 的 upvalue 参数，也不需要 `registry(L)` helper。若所有调用永远使用同一个单例，直接调用通常更简单。闭包捕获更适合需要把不同 Registry 或其他依赖绑定到不同函数实例的场景。

本课示例保留 upvalue 只为教学；不要仅因示例采用闭包，就在生产代码里机械复制这层传递。

## 5. Full userdata、lightuserdata 和 C++ 所有权

### 5.1 Light userdata：只携带地址

`lua_pushlightuserdata` 将 `void*` 地址作为 Lua 值放入栈中。它不分配被指向对象的存储，不拥有对象，也不会调用对象析构函数。

因此：

```text
Lua closure 中的 lightuserdata -> 只保存地址
C++ MapRegistry 单例          -> 真正拥有 Registry 和其中的地图
```

必须保证指针指向的对象在所有使用它的 closure 存活期间有效。本例由进程级单例保证。进程退出、Native 模块卸载或单例提前销毁都不能留下仍会被 Lua 调用的悬空指针。

### 5.2 Full userdata：Lua 管理的原生存储

`lua_newuserdatauv(L, size, nuvalue)` 在当前 Lua State 中分配一块由 Lua 管理的 userdata 存储，并把 userdata 压到栈顶。Lua 管理这块存储的可达性与回收时机，但不会自动理解其中 C++ 对象的构造和析构。

课程创建 `NavigationContext` userdata 的简化示例：

```cpp
void* storage = lua_newuserdatauv(L, sizeof(LuaNavigationContext), 0);
auto* owner = new (storage) LuaNavigationContext;
luaL_getmetatable(L, kContextMeta);
lua_setmetatable(L, -2);
```

逐步看栈和对象：

| 步骤 | 调用后栈：栈底 → 栈顶 | 发生的动作 |
| --- | --- | --- |
| 进入函数 | `[map_id] [map_version] [profiles]` | 参数由 Lua 放在 C 函数栈帧中。 |
| `lua_newuserdatauv(...)` | `[map_id] [map_version] [profiles] [userdata]` | 分配足够存放 wrapper 的 Lua 内存并压栈；此时尚未自动构造 C++ 对象。 |
| placement new | 栈不变 | 在 userdata 的内存中显式构造 `LuaNavigationContext`。 |
| `luaL_getmetatable(...)` | `[...] [userdata] [metatable]` | 从当前 Lua State 的 registry 取出已注册元表并压栈。 |
| `lua_setmetatable(L, -2)` | `[...] [userdata]` | 将元表附到 userdata 上并弹出元表。 |
| `return 1` | Lua 得到 `userdata` | 返回栈顶 userdata。 |

placement new 只负责构造；userdata 被 GC 回收时，也必须由 `__gc` 回调显式调用对应 C++ 析构函数。若 userdata 包含 `std::shared_ptr`、`std::vector` 等非平凡成员，漏掉析构会泄漏其拥有的资源。

## 6. Metatable、`__index` 和 `__gc`

metatable 是 Lua 用来定义某个值行为的 table。对于课程的 userdata，它主要负责两件事：

- `__index`：当 Lua 访问 userdata 上不存在的字段或方法时，决定去哪里查找；课程将它指向方法 table。
- `__gc`：userdata 被 Lua 回收时调用的清理回调；课程用它显式析构 placement new 构造的 C++ wrapper。

### 6.1 注册一个 Path metatable

下面是简化后的注册顺序：

```cpp
if (luaL_newmetatable(L, kPathMeta)) {
    lua_pushcfunction(L, l_path_gc);
    lua_setfield(L, -2, "__gc");

    lua_newtable(L);
    lua_pushcfunction(L, l_path_count);
    lua_setfield(L, -2, "count");
    lua_pushcfunction(L, l_path_world_point);
    lua_setfield(L, -2, "world_point");

    lua_setfield(L, -2, "__index");
}
lua_pop(L, 1);
```

关键栈变化如下：

```text
luaL_newmetatable          [PathMeta]
push l_path_gc             [PathMeta] [gc 函数]
setfield(-2, "__gc")       [PathMeta]
lua_newtable               [PathMeta] [methods]
push/setfield("count")     [PathMeta] [methods]
push/setfield("world_point")[PathMeta] [methods]
setfield(-2, "__index")    [PathMeta]
lua_pop(L, 1)              空栈（本函数新增的值已清理）
```

注册方法时，`lua_setfield(L, -2, "count")` 中的 `-2` 指方法 table，栈顶 C 函数成为 `methods.count` 并被弹出。最后一次 `lua_setfield(L, -2, "__index")` 中，`-2` 指 Path metatable；方法 table 被设置成元表的 `__index` 值，并从栈弹出。末尾 `lua_pop` 再把 Path metatable 从栈顶弹出。

`luaL_newmetatable` 使用当前 Lua State 的 registry 保存命名元表。若该名字第一次注册，它创建元表并返回真；再次注册则取回已有元表并返回假。通常只在真分支填充元表，然后让本函数以 `lua_pop` 恢复调用前的栈高度。

### 6.2 Lua 的冒号调用怎样变成 C 函数参数

Lua 写：

```lua
path:world_point(1)
```

语义上等价于：

```lua
path.world_point(path, 1)
```

所以 C 函数收到的参数栈是：

```text
栈底  [self = path userdata] [index = 1]  栈顶
正索引     1                   2
负索引    -2                  -1
```

这就是 binding 函数通常先在索引 `1` 检查 userdata，再从索引 `2` 读取显式参数的原因。普通点调用 `path.world_point(1)` 不会自动传入 `path`，不符合这个方法合同。

### 6.3 `__gc` 释放 C++ wrapper

典型 `__gc` 回调会先验证 userdata 类型，再对 placement new 构造的 wrapper 显式调用析构函数。回调本身应避免抛出 C++ 异常；析构过程也不能假设该 Lua State 之外的对象还有效。

```text
Lua 变量不再引用 Path userdata
  -> Lua GC 决定回收时机
  -> 调用 metatable.__gc
  -> C 回调显式析构 LuaPath
  -> Lua 释放 userdata 存储
```

GC 时机由 Lua 管理，不能把 `__gc` 当作确定的业务时序。因此有明确结束边界的重型对象（例如每场战斗的 NavigationContext）应提供并调用显式 `close()`；`__gc` 负责兜底，避免 userdata 遗忘后永远不析构。

## 7. Lua State、模块 table 和 userdata 的边界

Skynet 的不同 Service 有各自独立的 Lua State。每个 State 分别拥有自己的：

- `package.loaded` 模块缓存和 `battle_nav` 模块 table；
- Lua registry 中的 metatable；
- closure、upvalue 和 userdata；
- Lua 栈与 GC 生命周期。

同一进程内 Native 模块的 C++ 静态对象（例如 `MapRegistry::Instance()`）则可能由多个 Service 的 Native 调用共同访问。只读 GridMap 可以按明确合同共享；每场战斗的 Context 和 Path userdata 仍属于创建它们的那个 Lua State，不能当作跨 Service 消息发送。

```text
Service A / Lua State A                  Service B / Lua State B
  module table A                           module table B
  metatable A                              metatable B
  Context userdata A                       Context userdata B
          \                                  /
           \---- 同进程 Native Registry ---/
                    immutable GridMap
```

`MapRegistry` 是项目的 C++ 地图目录；Lua `registry` 是每个 Lua State 内部供 Lua C API 保存元表等值的注册表。两者名字相似，但不是同一个对象，也不共享生命周期。

跨 Service 应传递可序列化的地图 ID、地图版本、整数世界坐标、请求记录或结果记录；不要传 Lua userdata、closure、Lua State 指针或 Native 裸指针。若请求到另一进程，目标进程还需要根据地图 ID/版本在自己的 Native Registry 中查找已加载地图。

## 8. 阅读和调试 Binding 时的检查顺序

遇到一个 Lua C API 函数时，可以按以下问题追踪，不必先背完整 API：

1. 进入 C 函数时，参数按什么顺序位于栈上？哪些是 `self`？
2. 当前使用的正索引或负索引指向哪个具体值？
3. 这个 API 会压栈、弹栈，还是只读取/修改已有值？
4. C 函数最终返回几个值？它们是否正好位于栈顶？
5. 若值是 userdata，哪个 C++ 对象真正拥有资源，placement new 在哪构造，`__gc`/`close` 在哪析构？
6. 这个 Lua 值属于哪个 Service 的 Lua State？是否错误地跨过了 Service 边界？

尤其注意：每次改变栈之后，重新判断 `-1`、`-2` 所指对象。把表格写出调用前与调用后栈状态，通常比盯着一串 API 名字猜含义更可靠。
