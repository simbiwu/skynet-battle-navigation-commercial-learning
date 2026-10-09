# FlyWow Navigation Build and Battle Runtime Chain

本文说明 Navigation 从构建到 Battle 运行时调用的完整链路，按实际执行顺序组织。

## 1. 相关目录

~~~text
server/third_party/skynet-flywow/navigation/
├── lualib/flywow_navigation.lua
├── native/
│   ├── CMakeLists.txt
│   ├── grid_map/
│   └── lua/
└── tests/
~~~

职责：

- native/grid_map：BMAP、Grid、动态占用、A* 和 Path；
- native/lua：Lua 与 C++ 的 Binding；
- lualib/flywow_navigation.lua：Lua 对外入口，只转交 Native API；
- tests：Native 和 Lua Binding 测试。

Lua Wrapper 不重复实现地图和寻路算法。

## 2. 构建命令

从 FlyWow 目录执行：

~~~bash
./scripts/build_flywow.sh <SKYNET_ROOT> navigation
~~~

示例：

~~~bash
cd /home/simbi/workspace/skynet-battle-navigation-commercial-learning/server/third_party/skynet-flywow

./scripts/build_flywow.sh \
  /home/simbi/workspace/skynet-battle-navigation-commercial-learning/server/third_party/skynet \
  navigation
~~~

第一个参数用于定位当前 Skynet 的头文件，Navigation Lua Binding 会检查：

~~~text
<SKYNET_ROOT>/3rd/lua/lua.h
~~~

它必须使用和运行时相同的 Lua ABI。

第二个参数支持：

~~~text
gateway     只构建 Gateway
navigation  只构建 Navigation
logger      只构建 Logger
all         构建全部模块
~~~

省略第二个参数时默认为 all。

构建脚本只负责编译、测试和检查产物，不读取 BMAP，也不启动 Battle。

## 3. CMake 做什么

Navigation 分支执行：

~~~bash
cmake -S navigation/native \
  -B build/cmake/navigation \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DFLYWOW_NAVIGATION_LUA=ON \
  -DFLYWOW_NATIVE_OUTPUT_DIR=build/native \
  -DSKYNET_ROOT=<SKYNET_ROOT>
~~~

主要构建目标：

~~~text
grid_map_core
grid_map_test
navigation_test
navigation_benchmark
flywow_navigation_lua
~~~

其中：

- grid_map_core：地图、Registry、动态占用、Context、PathFinder；
- grid_map_test：Grid Map 回归测试；
- navigation_test：导航回归测试；
- navigation_benchmark：性能程序，只构建不自动运行；
- flywow_navigation_lua：Lua Native Binding。

grid_map_test 和 navigation_test 都带有：

~~~cmake
-UNDEBUG
~~~

因此 RelWithDebInfo 下仍会执行 assert。

中间文件在：

~~~text
server/third_party/skynet-flywow/build/cmake/navigation/
~~~

最终 Native 文件是：

~~~text
server/third_party/skynet-flywow/build/native/flywow_navigation_native.so
~~~

## 4. Battle 如何找到文件

Battle 配置：

~~~text
server/config/battle_process.lua
~~~

Lua Wrapper 的搜索路径：

~~~lua
lua_path = "./?.lua;./lualib/?.lua;" ..
           "./third_party/skynet-flywow/navigation/lualib/?.lua"
~~~

所以：

~~~lua
require "flywow_navigation"
~~~

会找到：

~~~text
server/third_party/skynet-flywow/navigation/lualib/flywow_navigation.lua
~~~

Native 模块的搜索路径：

~~~lua
lua_cpath = "./luaclib/?.so;" ..
            "./third_party/skynet-flywow/build/native/?.so"
~~~

所以：

~~~lua
require "flywow_navigation_native"
~~~

会查找：

~~~text
server/third_party/skynet-flywow/build/native/flywow_navigation_native.so
~~~

这些相对路径以 Server 根目录为基准，启动 Server 时当前目录必须是：

~~~text
server/
~~~

## 5. Lua Wrapper 到 C++

Wrapper 文件：

~~~text
navigation/lualib/flywow_navigation.lua
~~~

它的职责只有转交：

~~~lua
local navigation = require "flywow_navigation_native"
return navigation
~~~

调用链：

~~~text
业务代码 require "flywow_navigation"
  ↓
lua_path 找到 Lua Wrapper
  ↓
Wrapper require "flywow_navigation_native"
  ↓
lua_cpath 找到 .so
  ↓
Lua 调用 luaopen_flywow_navigation_native
  ↓
返回 Navigation API table
~~~

Wrapper 使用 flywow_navigation，Native 使用 flywow_navigation_native，避免 Wrapper 递归加载自己。

## 6. Native 模块初始化

Native 入口：

~~~text
navigation/native/navigation_binding.cpp
~~~

入口函数：

~~~cpp
extern "C" int luaopen_flywow_navigation_native(lua_State *L)
~~~

第一次 require Native 模块时执行。

它完成：

1. 调用 luaL_checkversion，确认 Lua ABI；
2. 注册 Path userdata 及其 __gc、count、world_point、length_mm；
3. 注册 NavigationContext userdata 及其查询、移动、close 方法；
4. 创建模块 table；
5. 放入 load_map、query_cell、new_context；
6. 将 MapRegistry::Instance() 绑定到这些 API 的 closure。

这个阶段只注册 API，不读取 BMAP。require 的模块结果会被当前 Lua State 缓存。

## 7. Battle 什么时候读取 BMAP

Battle 入口：

~~~text
server/service/battle/battle_main.lua
~~~

它先启动：

~~~lua
local query_service = skynet.newservice("battle/navigation_query")
assert(skynet.call(query_service, "lua", "ready"))
~~~

Query Service：

~~~text
server/service/battle/navigation_query.lua
~~~

启动时加载：

~~~lua
local battle_nav = require "flywow_navigation"
local query_logic = require "battle.navigation.query_logic"
~~~

随后执行：

~~~lua
query_logic.start(config)
~~~

query_logic.start 调用：

~~~lua
local loaded, err = battle_nav.load_map(path)
~~~

这一步才真正：

~~~text
打开 BMAP
校验 map_id 和 map_version
读取静态 Grid
创建 Native GridMap
放入 MapRegistry
~~~

加载成功后，Query Service 才返回 ready。

顺序是：

~~~text
加载 .so
  ↓
注册 Lua API
  ↓
启动 navigation_query
  ↓
load_map(BMAP)
  ↓
BMAP 进入 MapRegistry
  ↓
返回 ready
  ↓
Battle 继续启动
~~~

## 8. 静态 Cell 查询链路

静态查询链路：

~~~text
Battle Dispatch 收到 QueryCell
  ↓
skynet.call(query_service, "lua", "query_cell", payload)
  ↓
navigation_query.lua
  ↓
query_logic.query(request)
  ↓
battle_nav.query_cell(...)
  ↓
Native MapRegistry 和 GridMap
  ↓
返回 Cell 结果
~~~

结果包括：

~~~text
grid_x
grid_z
cell_height_mm
area
clearance
~~~

这条链路只读静态地图，不创建 Battle Context，也不修改动态单位状态。

## 9. Battle Worker 创建 Context

正式模拟由：

~~~text
server/service/battle/battle_worker.lua
~~~

执行。

Battle 进程启动时，navigation_query 先从 config.battle.profiles 调用 load_profiles 一次，再加载静态地图。每次模拟开始只创建本场 Context：

~~~lua
local context, err = battle_nav.new_context(
    snapshot.map_id,
    snapshot.map_version)
~~~

Context 持有本次 Battle 的可变状态：

~~~text
occupancy
单位占位状态
Path 跟随状态
本次 Context 的查询 scratch
~~~

静态地图仍由 MapRegistry 共享，Context 不复制整张地图。

然后进入：

~~~lua
battle_core.simulate(snapshot, context)
~~~

模拟结束：

~~~lua
context:close()
~~~

## 10. Battle 如何重新寻路

Battle Core 在需要重新规划路线时调用单位接近查询：

~~~lua
local path, err = context:find_path_to_unit_range(
    self.unit_id,
    self.position,
    target.unit_id,
    target.position,
    self.id)
~~~

参数：

- self.unit_id / target.unit_id：双方静态 Unit 类型 ID，用于读取 NavigationProfile；
- self.position / target.position：双方当前权威位置，整数毫米；
- self.id：当前移动实体的 unit_instance_id，占位查询时忽略自身。

这个导航查询只用双方 NavigationProfile.radius_mm 计算不重叠的接近位置，不接收战斗射程。
Battle Core 另从共享 UnitProfile.combat.attack_range_mm 读取中心距攻击范围；移动中的每个 Tick
都独立检查是否进入攻击范围，进入后停止路径并执行攻击。

Native 处理：

~~~text
读取双方 NavigationProfile
  ↓
以半径之和限制目标接近点，格子对角线误差只用于离散终点
  ↓
检查静态可行走信息与动态 occupancy
  ↓
返回 Path；Battle 后续推进并独立判定攻击距离
~~~

## 11. Battle 如何推进单位

每个固定 Tick，Battle 先计算移动预算：

~~~lua
local budget = movement_budget(self, state.tick_ms)
~~~

再调用：

~~~lua
local advanced, err = context:advance_path({
    profile_id = self.agent_profile_id,
    unit_id = self.id,
    path = self.path,
    from_world = self.position,
    distance_mm = budget,
})
~~~

Native 处理：

~~~text
读取 Path cursor
  ↓
按 distance_mm 推进
  ↓
处理路径点和插值
  ↓
检查动态占位提交
  ↓
更新位置
  ↓
返回推进结果
~~~

返回结果包含：

~~~text
status
position
consumed_mm
moved
~~~

Battle 保存返回的位置，并根据结果生成移动、停止等权威事件。Replay 使用 Battle 产生的事件和最终结果。

## 12. 总链路

~~~text
build_flywow.sh <SKYNET_ROOT> navigation
  ↓
CMake 编译 grid_map_core 和 Lua Binding
  ↓
运行 grid_map_test、navigation_test
  ↓
生成 build/native/flywow_navigation_native.so
  ↓
battle_process.lua 配置 lua_path、lua_cpath
  ↓
Battle 启动 navigation_query
  ↓
require "flywow_navigation"
  ↓
Wrapper require "flywow_navigation_native"
  ↓
luaopen_flywow_navigation_native
  ↓
query_logic.start()
  ↓
battle_nav.load_map(path)
  ↓
BMAP 进入 MapRegistry
  ↓
Battle Worker new_context()
  ↓
context:find_path_to_range()
  ↓
context:advance_path()
  ↓
Battle 保存权威位置和事件
  ↓
Replay 消费 Battle 结果
~~~

## 13. 常见问题定位

### 找不到 Lua Wrapper

检查：

~~~text
server/config/battle_process.lua
lua_path
navigation/lualib/flywow_navigation.lua
~~~

### 找不到 Native .so

检查：

~~~text
server/config/battle_process.lua
lua_cpath
build/native/flywow_navigation_native.so
~~~

并确认运行 Server 时当前目录是 server。

### Native 加载失败

检查：

- SKYNET_ROOT 是否指向当前运行的 Skynet；
- lua.h 是否来自该 Skynet；
- Lua ABI 是否一致；
- .so 是否由当前源码重新生成。

### BMAP 加载失败

这说明 .so 已经加载成功，问题在运行阶段。继续检查：

- BMAP 路径；
- 文件是否存在；
- map_id 是否一致；
- map_version 是否一致；
- BMAP 是否已由 Unity 导出并通过校验。

### 寻路失败

按阶段区分：

~~~text
load_map 失败       地图没有进入 MapRegistry
new_context 失败    Context 或 Profile 初始化失败
find_path 失败      当前静态地图和动态占用下没有路径
advance_path 失败  路径推进或动态占位提交失败
~~~
