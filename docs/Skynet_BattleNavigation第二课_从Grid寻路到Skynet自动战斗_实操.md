# Skynet Battle Navigation 第二课实操：从世界位置 A→B 到 Server 权威自动战斗

第一课已经完成一条真实可运行的地图生产与查询链：

```text
Tuanjie Scene
-> NavMesh Authoring
-> Grid Sampling
-> BMAP V1
-> C++ BMapReader
-> immutable GridMap
-> MapRegistry
-> Lua C Binding
-> Skynet Query
```

第二课不重做这条链。现在第一次出现新的业务需求：

> 一个地面单位位于世界位置 A，需要绕过静态障碍和战斗中的其他单位，移动到世界位置 B；随后把这套导航能力放进一个 Server 权威、可确定性重放的自动战斗中。

这一个需求会自然长出本课全部核心对象：

```text
谁在走？
-> AgentProfile

A 到 B 的结果用什么表示？
-> Path

一场 Battle 自己的查询临时数据和动态占位放哪里？
-> NavigationContext

怎样从 A 找到 B？
-> Grid A*

其他单位怎样阻挡当前单位？
-> DynamicOccupancy

目标中心已经被占用，近战单位应该走到哪里？
-> Attack Position

怎样避免每 Tick 都重新 A*？
-> Path 生命周期 + Repath Policy

谁拥有战斗状态、谁允许 yield？
-> BattleMgr / BattleWorker / pure battle_core

Server 算完以后怎样验证客户端只负责表现？
-> Unity Replay
```

第二课结束时的完整执行链是：

```text
BattleMgr
  -> prepare immutable input/snapshot
  -> skynet.call(BattleWorker, "simulate", snapshot)   [这里会 yield]

BattleWorker
  -> acquire map/version
  -> create battle-local NavigationContext
  -> place dynamic units
  -> battle_core.simulate(...)                         [核心阶段 no-yield]
       -> target select
       -> find attack position
       -> context:find_path(...)
          -> WorldPosition -> GridPos
          -> Grid A*
          -> Path(WorldPosition)
       -> follow cached Path
       -> only repath on explicit trigger
       -> attack / hp / death
       -> ordered BattleEvent
  -> return deterministic event log

Unity
  -> load event log
  -> replay MOVE_PATH / MOVE_STOPPED / ATTACK / UNIT_DEAD
  -> never overwrite Server result
```

本课仍然只使用第一课的单层 2.5D Grid。不会引入：

```text
DetourNavigationBackend
Recast / Detour
Polygon NavMesh
SkillDefinition / SkillRuntime
Projectile
Flying Navigation
PlayerCommand
完整 Battle Snapshot/Event 在线同步
```

可选第四课第一次出现第二种地面导航实现时，才正式抽取 `INavigationBackend / GridNavigationBackend / DetourNavigationBackend`。第二课末尾只整理当前已经被 `BattleWorker` 使用过的稳定 Grid 导航调用面。

---

## 0. 开始前先确认第一课的真实边界

本课依赖的第一课真实 C++ 类型位于：

```text
server/native/grid_map/include/bmap_format.h
server/native/grid_map/include/grid_map.h
server/native/grid_map/include/map_registry.h
server/native/grid_map/include/nav_result.h
server/native/lua_battle_nav/src/lua_battle_nav.cpp
```

第一课已经固定：

```cpp
struct WorldPosition {
    std::int32_t x_mm;
    std::int32_t y_mm;
    std::int32_t z_mm;
};

struct GridPos {
    std::int32_t x;
    std::int32_t z;
};

struct NavCell {
    std::int32_t height_mm;
    std::uint16_t flags;
    std::uint8_t area_type;
    std::uint8_t clearance_cells;
};
```

### 0.1 第二课的文件操作原则

本课不会为了“最终目录漂亮”先移动第一课文件。当前能力继续增加在已经工作的 `server/native/grid_map/`；目录调整不属于本课功能链。

所有操作都使用以下四种标签：

```text
[新建文件]
[完整替换]
[局部修改]
[只阅读]
```

---

# 第一部分：先让“谁在走”和“返回什么”变成明确合同

## 1. AgentProfile：同一张地图，不同单位不是同一种可走规则

第一课的 `NavCell.clearance_cells` 只是静态地图属性：

> 这个 Cell 离静态障碍/地图边界还有多少格保守空间。

现在第一次出现“谁要经过这个 Cell”。Small Soldier 和 Large Boss 可以共享同一张 BMAP，但它们对窄路、坡度和 Area 的可接受范围不同。

### 1.1 空间关系先看图

仍然使用 500mm Cell：

```text
世界 X ->

        500mm     500mm     500mm
     +---------+---------+---------+
 Z ^ |    #    |    #    |    #    |
   | +---------+---------+---------+
   | |    #    |  C(1)   |    #    |
   | +---------+---------+---------+
   | |    #    |    #    |    #    |
     +---------+---------+---------+

#      = 静态不可走
C(1)   = 可走 Cell，但 clearance_cells = 1
```

如果单位半径只有 200mm，课程的保守规则允许 `required_clearance_cells=1`。如果半径需要 600mm，规则要求至少 2 格静态空间，这个 Cell 就会被拒绝。

这个换算是 2.5D Grid 的保守近似：

```text
required_clearance_cells
= max(1, ceil(radius_mm / cell_size_mm))
```

它不是连续几何的精确 Minkowski Sum。课程把这种保守性作为明确语义，而不是假装 Grid 能提供无限精度。

坡度也来自已有数据。相邻两格的中心高度分别为 `h0` 和 `h1`，水平距离为：

```text
直走：cell_size_mm
斜走：约 1.414 * cell_size_mm
```

为了避免浮点比较，使用千分比坡度：

```text
abs(height_delta_mm) * 1000
<= max_slope_permille * horizontal_distance_mm
```

例如：

```text
max_slope_permille = 500
约等于 50% 坡度
```

`max_step_mm` 另外限制单次高度跳变；即使平均坡度允许，也不能跨越一个不应该被当作坡面的高度断层。

### 1.2 AgentProfile 学习导航

本文件解决的问题：把单位对静态地图的导航约束集中成一份只读 record，让 A* 不从 Lua 的零散字段猜规则。

本节必须掌握：

```text
radius_mm                  单位静态体型约束
max_step_mm                相邻 Cell 最大高度跳变
max_slope_permille         最大坡度千分比
area_allowed[256]          哪些静态 Area 可以进入
area_cost_permille[256]    进入不同 Area 的相对成本
```

必须精读：字段单位、`ValidateAgentProfile()`、`RequiredClearanceCells()`。

可以略读：`std::array` 初始化语法。

输入、输出和失败条件：

```text
输入：一份 AgentProfile + 当前 Grid cell_size_mm
输出：合法 profile 或明确 INVALID_AGENT
失败：id=0、radius<0、step/slope 非法、允许 Area 的 cost<1000
```

这里规定允许 Area 的 cost 最低为 `1000`。这样 A* 的 Octile Heuristic 仍然保持可采纳；泥地可以 2000、3000，但本课不实现“公路速度 0.8 倍成本”这种低于基础成本的情况。

运行验证：第 10 节统一 `navigation_test` 会同时验证 Small/Large、Slope 和 Area Cost。

理解自测：

```text
1. 为什么 clearance 是地图属性，而 radius 是单位属性？
2. 为什么 area cost 放 AgentProfile，而不是直接写死在 GridMap？
3. 如果允许 cost=500，现有 heuristic 为什么需要同步调整？
```

### 1.3 创建 AgentProfile

[新建文件]

```text
server/native/grid_map/include/agent_profile.h
```

```cpp
// 职责：定义地面单位在 Grid 导航中的静态通行规则。
// 边界：Server Runtime Navigation Input；由 Battle 配置创建，A* 只读使用。
// 输入/输出：单位体型、坡度和 Area 策略 -> Cell 可通行判定参数。
// 生命周期：随 NavigationContext/Battle 输入存活；查询期间不可修改。
// 不负责：不保存单位当前位置，不保存动态占位，不执行寻路。
#pragma once

#include "bmap_format.h"
#include "nav_result.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>

namespace battle_nav {

struct AgentProfile {
    std::uint32_t id = 0;          // Battle 内稳定 Profile ID；0 保留为非法值。
    std::int32_t radius_mm = 0;    // 地面圆形 footprint 半径，毫米；合法范围 [0, INT32_MAX]。
    std::int32_t max_step_mm = 0;  // 相邻 Cell 允许的最大高度跳变，毫米；必须 >=0。
    std::uint32_t max_slope_permille = 0; // 高差/水平距离 *1000 的上限。

    // area_type 是 uint8，因此固定 256 项避免 map 查找和查询期动态分配。
    std::array<std::uint8_t, 256> area_allowed{};       // 1=允许进入，0=禁止。
    std::array<std::uint16_t, 256> area_cost_permille{}; // 1000=基础成本，>=1000。
};

// 构造一份最常用的“全部 Area 允许、基础成本 1000”默认表。
// 仅分配/返回一个小值对象；不访问地图、不加锁、不 yield。
inline AgentProfile MakeDefaultAgentProfile(std::uint32_t id) {
    AgentProfile profile;
    profile.id = id;
    profile.area_allowed.fill(1);
    profile.area_cost_permille.fill(1000);
    return profile;
}

// 验证 Profile 是否满足本课 A* 的整数成本与 Heuristic 前提。
// 成功返回 true；失败返回 kInvalidAgent + detail。
inline NavResult<bool> ValidateAgentProfile(const AgentProfile& profile) {
    if (profile.id == 0 || profile.radius_mm < 0 || profile.max_step_mm < 0) {
        return NavResult<bool>::Failure(
            NavError::kInvalidAgent,
            "agent id/radius/max_step is invalid");
    }

    for (std::size_t area = 0; area < profile.area_allowed.size(); ++area) {
        if (profile.area_allowed[area] == 0) {
            continue;
        }
        if (profile.area_cost_permille[area] < 1000) {
            return NavResult<bool>::Failure(
                NavError::kInvalidAgent,
                "allowed area cost must be >= 1000 permille");
        }
    }
    return NavResult<bool>::Success(true);
}

// 把毫米制半径转换为第一课 clearance_cells 的保守需求。
// cell_size_mm 必须 >0；返回值至少为 1，并在 uint8 范围饱和。
inline std::uint8_t RequiredClearanceCells(
    const AgentProfile& profile,
    std::uint32_t cell_size_mm) {
    if (cell_size_mm == 0) {
        return std::numeric_limits<std::uint8_t>::max();
    }
    const std::uint64_t radius = static_cast<std::uint64_t>(profile.radius_mm);
    const std::uint64_t cells = (radius + cell_size_mm - 1) / cell_size_mm;
    const std::uint64_t at_least_one = cells == 0 ? 1 : cells;
    return static_cast<std::uint8_t>(
        at_least_one > 255 ? 255 : at_least_one);
}

} // namespace battle_nav
```

谁马上会使用它：第 6 节 A* 的 `CanOccupyStatic()`。完成后暂时看不到路径变化，这是正常的；当前只是把“谁能走”从隐含规则变成明确输入。

---

## 2. Path：A* 的结果必须回到世界坐标

A* 内部会使用 `GridPos` 和 node index，但 Battle、Lua、Replay 不应该长期依赖 Grid 的 origin/cell size。

正式结果必须是：

```text
Path
└─ WorldPosition[0..N-1]  单位：整数毫米
```

路径点通常位于 Cell Center，所以 Y 来自第一课 `NavCell.height_mm`。

### 2.1 Path 学习导航

本文件解决的问题：把一次成功寻路的结果保存成不可变世界坐标路径，供 Lua/Battle/Replay 读取。

本节必须掌握：

```text
Path point 属于世界坐标边界
GridPos 只在构建 Path 之前存在
Path 构建后 immutable
最终 Path 分配允许发生；A* node 不能 per-node new/delete
```

必须精读：`WorldPoint()`、`length_mm()`、构造时 ownership。

可以略读：`std::vector` getter。

输入、输出和失败：

```text
输入：已经验证的 WorldPosition 点序列
输出：immutable Path
失败：空路径由 FindPath 返回 NO_PATH/其他显式错误，不用空 Path 偷偷表达失败
```

运行验证：直线路径、绕障碍路径和 smoothing 测试会读取 Path 世界点。

理解自测：为什么 Lua 不应该拿到 `{grid_x, grid_z}` 数组作为正式路径？

### 2.2 创建 Path

[新建文件]

```text
server/native/grid_map/include/navigation_path.h
```

```cpp
// 职责：保存一次成功地面导航产生的不可变世界坐标路径。
// 边界：Server Runtime Navigation Result；Lua/Battle/Replay 只看 WorldPosition。
// 输入/输出：有序 WorldPosition 点 -> 只读 Path 和总长度。
// 生命周期：由调用者或 Lua userdata 持有；构建完成后不再修改。
// 不负责：不保存 A* node、GridPos、dynamic occupancy 或未来 Off-Mesh 语义。
#pragma once

#include "bmap_format.h"

#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <utility>
#include <vector>

namespace battle_nav {

class Path final {
public:
    Path() = default;

    // 接管已经按行进顺序排列的世界坐标点。
    // points 可以只含一个点（start==end）；本构造不执行地图合法性检查。
    explicit Path(std::vector<WorldPosition> points, std::uint64_t length_mm)
        : points_(std::move(points)), length_mm_(length_mm) {}

    // 返回路径点数量；不分配、不加锁、不 yield。
    std::size_t count() const noexcept { return points_.size(); }

    // 读取 index 对应的世界坐标点；越界抛 out_of_range，仅供已验证调用者使用。
    const WorldPosition& WorldPoint(std::size_t index) const {
        if (index >= points_.size()) {
            throw std::out_of_range("path point index out of range");
        }
        return points_[index];
    }

    // 返回整条路径在 XZ 平面的整数毫米长度；不包含动画或墙钟时间。
    std::uint64_t length_mm() const noexcept { return length_mm_; }

    // Native 内部只读访问连续点数组；返回引用不拥有数据。
    const std::vector<WorldPosition>& points() const noexcept { return points_; }

private:
    std::vector<WorldPosition> points_; // 按移动顺序保存；Path 独占内存。
    std::uint64_t length_mm_ = 0;       // XZ 折线总长度，单位毫米。
};

} // namespace battle_nav
```

这里出现的 `std::vector` 分配属于“最终结果分配”。本课禁止的是：A* 每访问一个 Node 都 `new Node`，或者 open list 每次 push 都构造一堆堆上对象。最终返回一条 Path，本身需要保存结果，这是合理分配。

---

# 第二部分：先建立每场 Battle 私有的查询上下文，再写 A*

## 3. NavigationContext：把 A* scratch 的 owner 先确定下来

如果直接在 `GridPathfinder::FindPath()` 里写：

```cpp
static std::vector<Node> nodes;
static std::vector<int> open_heap;
```

单线程测试很可能全部通过；多个 Skynet Service 在不同 OS Thread 同时调用时，会互相覆盖：

```text
Thread A: node[123].parent = 50
Thread B: node[123].parent = 890
Thread A: 回溯 parent -> 路径突然跳到 B 的查询
```

因此先建立 owner，再写算法。

现在才需要把 ownership 画完整：

```text
进程级，只读，可多线程共享
┌──────────────────────────────────────────────┐
│ MapRegistry                                  │
│   └─ shared_ptr<const GridMap>               │
│        ├─ BMapMetadata                       │
│        └─ const vector<NavCell>              │
└──────────────────────────────────────────────┘
                       ▲
                       │ shared immutable asset
                       │
每场 Battle 私有       │
┌──────────────────────┴───────────────────────┐
│ NavigationContext                            │
│   ├─ shared_ptr<const GridMap>               │
│   ├─ A* Node Scratch                         │
│   ├─ Binary Heap Scratch                     │
│   ├─ query generation                        │
│   └─ 第 7 节加入的 DynamicOccupancy          │
└──────────────────────────────────────────────┘
```

读图要点：

1. `GridMap` 保存 map/version 对应的静态事实，加载后 immutable，可以跨 Battle 共享。
2. `NavigationContext` 保存一次 Battle 的查询临时状态，不能跨 Battle 共享。
3. `g_cost / parent / open/closed / heap_index / generation` 都属于一次查询，不能写进 `GridMap`。
4. 第 7 节出现的动态单位也只属于当前 Battle，不能写进 `NavCell`。
5. 图中的 `GridPos` 仍只是 Native 算法坐标；正式业务位置继续使用 `WorldPosition(mm)`。

### 3.1 Skynet Service、Lua State 和 OS Thread 的关系

这张图的线程安全结论来自三个不同层次：

```text
Skynet Service
  -> 通常拥有自己的 Lua State
  -> 消息处理协程可以在 yield 点交错

Skynet Worker Thread
  -> 调度不同 Service
  -> 一个 Service 在生命周期中可能被不同 Worker Thread 调度

C/C++ Native Module
  -> 进程级代码和静态数据
  -> 不同 Service 可以在不同 OS Thread 同时进入同一份 Native 代码
```

因此 immutable `GridMap` 可以共享；process-global mutable A* scratch、current Path buffer 和 DynamicOccupancy 都不可以共享。即使一个 Lua Service 内没有两个 Lua 指令流同时执行，另一个 Service 仍可能从另一个 OS Thread 进入同一份 Native 模块。

### 3.2 generation stamp 解决什么问题

假设地图 512×512：

```text
cell_count = 262144
```

每次 FindPath 前把 26 万个 Node 全部 `memset` 清零，会把“搜索访问了 2000 个节点”的算法变成“每次至少触碰 26 万个节点”。

本课给每个 Node 保存：

```text
generation
```

每次查询只做：

```text
context.query_generation++
```

访问一个 Node 时：

```text
if node.generation != current_generation:
    把这个 Node 当成本次第一次访问
    初始化 g/parent/heap/state
    node.generation = current_generation
```

这样只初始化真正访问到的节点。

Generation 从 `UINT32_MAX` 回卷时，才一次性把 generation 数组清零。这个极低频分支必须存在，不能让旧查询的 generation 与新查询碰撞。

### 3.3 Binary Heap 中的三个 index 不要混

A* 里会同时出现：

```text
node_index   = z * width + x        Grid Cell 对应的稳定 Node 编号
heap_slot    = 当前 Node 在 binary heap 数组中的位置
parent_index = 最优路径上一个 Node 的 node_index
```

它们都可能是 `int32_t`，所以注释必须持续写明是哪一种 index。

### 3.4 NavigationContext 学习导航

本文件解决的问题：让每场 Battle/每个独立 Query owner 自己持有 A* scratch，避免全局可变查询状态。

本节必须掌握：

```text
NodeScratch 生命周期 = NavigationContext 生命周期
open_heap 预分配一次
query_generation 每次查询递增
GridMap shared_ptr<const> 只读共享
```

必须精读：`NodeScratch` 字段、`BeginQuery()`、`TouchNode()`、`heap` ownership。

可以略读：getter。

输入、输出和失败：

```text
输入：shared_ptr<const GridMap>
输出：一个可重复执行 FindPath 的 battle-local context
失败：null map、cell_count 超过 int32 node_index 能力
```

运行验证：第 11 节并发测试会让多个 Context 同时查询同一 GridMap。

理解自测：如果把 `query_generation_` 设成全局 atomic，为什么仍然没有解决 `g_cost/parent/heap` 的共享污染？

### 3.5 创建 NavigationContext 的第一版

这一版只放静态 A* scratch。第 7 节出现动态单位以后，再对同一文件做局部修改加入 `DynamicOccupancy`。

[新建文件]

```text
server/native/grid_map/include/navigation_context.h
```

```cpp
// 职责：拥有一场 Battle/一次独立导航会话的 A* 可变查询状态。
// 边界：Server Runtime Battle-local Navigation；只读共享 GridMap，可写状态绝不跨 Context。
// 输入/输出：immutable GridMap -> 可重复使用的 Node/Heap scratch。
// 生命周期：通常与一场 Battle 相同；销毁时释放本 Context 的全部 scratch。
// 不负责：不拥有 MapRegistry，不把 GridPos 暴露给 Lua 业务，不执行 Skynet yield。
#pragma once

#include "grid_map.h"
#include "nav_result.h"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

namespace battle_nav {

class NavigationContext final {
public:
    enum class NodeState : std::uint8_t {
        kUnseen = 0,
        kOpen = 1,
        kClosed = 2,
    };

    struct NodeScratch {
        std::uint32_t generation = 0; // 只有等于 query_generation_ 时其余字段才属于当前查询。
        std::uint64_t g_cost = 0;     // 起点到当前 node 的累计整数成本；大图不会发生 uint32 回绕。
        std::int32_t parent_index = -1; // 最优前驱 node_index；-1 表示起点/未设置。
        std::int32_t heap_index = -1;   // 当前 node 在 binary heap 中的 slot；不在 heap 时为 -1。
        NodeState state = NodeState::kUnseen; // 本次 query 的 unseen/open/closed 状态。
    };

    // 为 map 分配一次 dense scratch；构造阶段会发生 O(cell_count) 内存分配。
    // map 必须非空，cell_count 必须可由 int32 node_index 表示。
    explicit NavigationContext(std::shared_ptr<const GridMap> map);

    // 开始一次新查询：递增 generation、清空 heap_size，不扫描清零全部 Node。
    // Generation 回卷时才 O(cell_count) 清零 generation 字段。
    void BeginQuery();

    // 取得 node_index 对应的当前查询 NodeScratch；首次触碰时按当前 generation 初始化。
    // node_index 必须位于 [0, cell_count)；返回引用归本 Context 所有。
    NodeScratch& TouchNode(std::int32_t node_index);

    // 只读访问共享静态地图；返回 shared_ptr 引用，不转移所有权。
    const std::shared_ptr<const GridMap>& map() const noexcept { return map_; }

    // Binary Heap backing array；元素是 node_index。容量在构造时一次性分配为 cell_count。
    std::vector<std::int32_t>& heap_storage() noexcept { return heap_; }
    const std::vector<std::int32_t>& heap_storage() const noexcept { return heap_; }

    // 当前 heap 的有效 slot 数；[0, heap_size_) 才是本次查询数据。
    std::size_t heap_size() const noexcept { return heap_size_; }
    void set_heap_size(std::size_t value) noexcept { heap_size_ = value; }

    // 当前查询 generation；只用于 GridPathfinder，不进入业务数据。
    std::uint32_t query_generation() const noexcept { return query_generation_; }

    // 调试/Benchmark：本次 A* 真正 Touch 的 Node 数。
    std::uint32_t visited_nodes() const noexcept { return visited_nodes_; }

private:
    std::shared_ptr<const GridMap> map_; // 与 MapRegistry 共享 immutable GridMap 所有权。
    std::vector<NodeScratch> nodes_;     // 每 Cell 一个 scratch record，本 Context 独占。
    std::vector<std::int32_t> heap_;     // Binary Heap 的 node_index 存储，本 Context 独占。
    std::size_t heap_size_ = 0;          // 本次 query 的有效 heap slot 数。
    std::uint32_t query_generation_ = 0; // 0 保留为“从未属于任何查询”。
    std::uint32_t visited_nodes_ = 0;    // 本次查询 Touch 的唯一 Node 计数。
};

} // namespace battle_nav
```

[新建文件]

```text
server/native/grid_map/src/navigation_context.cpp
```

```cpp
// 职责：实现 NavigationContext 的 scratch 分配、generation 生命周期和按需 Node 初始化。
// 边界：Server Runtime Battle-local Mutable State；不访问 Skynet/Lua，不执行 I/O。
// 输入/输出：immutable GridMap -> 可复用 A* scratch。
// 内存：构造时按 cell_count 分配 nodes + heap；每次查询不做 per-node allocation。
// 不负责：不计算邻居、不判断 Agent、不生成 Path。
#include "navigation_context.h"

#include <algorithm>
#include <limits>
#include <stdexcept>
#include <utility>

namespace battle_nav {

NavigationContext::NavigationContext(std::shared_ptr<const GridMap> map)
    : map_(std::move(map)) {
    if (!map_) {
        throw std::invalid_argument("NavigationContext requires map");
    }
    if (map_->cell_count() >
        static_cast<std::size_t>(std::numeric_limits<std::int32_t>::max())) {
        throw std::invalid_argument("map has too many cells for int32 node index");
    }

    // Dense scratch 在 Context 构造阶段一次分配；查询热路径只重用这些内存。
    nodes_.resize(map_->cell_count());
    heap_.resize(map_->cell_count());
}

void NavigationContext::BeginQuery() {
    ++query_generation_;
    if (query_generation_ == 0) {
        // uint32 generation 回卷后必须清掉旧标记，避免几十亿次前的 Node 被误认为当前查询。
        for (NodeScratch& node : nodes_) {
            node.generation = 0;
        }
        query_generation_ = 1;
    }
    heap_size_ = 0;
    visited_nodes_ = 0;
}

NavigationContext::NodeScratch& NavigationContext::TouchNode(
    std::int32_t node_index) {
    if (node_index < 0 ||
        static_cast<std::size_t>(node_index) >= nodes_.size()) {
        throw std::out_of_range("A* node_index outside scratch array");
    }

    NodeScratch& node = nodes_[static_cast<std::size_t>(node_index)];
    if (node.generation != query_generation_) {
        // 只初始化本次查询真正访问的 Node；不对整张地图 memset。
        node.generation = query_generation_;
        node.g_cost = std::numeric_limits<std::uint64_t>::max();
        node.parent_index = -1;
        node.heap_index = -1;
        node.state = NodeState::kUnseen;
        ++visited_nodes_;
    }
    return node;
}

} // namespace battle_nav
```

### 3.6 这里会占多少内存

`NodeScratch` 含 `uint64_t g_cost`，实际大小受 ABI 对齐影响，不能在文档里写死。用 `sizeof(NavigationContext::NodeScratch)` 记录当前编译产物；Heap 还需要每 Cell 一个 `int32_t`，Occupancy 需要一个 `uint32_t`。

粗略估算：

```text
80x60      = 4,800 cells      很小
256x256    = 65,536 cells     约 MB 级 scratch
512x512    = 262,144 cells    数 MB scratch/context
```

因此“每场 Battle 一个 Context”并不等于“可以无限创建大地图 Context”。商业项目需要结合：

```text
同时活跃 Battle 数
地图 cell_count
每场寻路频率
Worker 数
内存预算
```

再决定是否做 scratch pool、分区地图或更稀疏的数据结构。本课先把 correctness 和 ownership 做对，再用第 12 节 Benchmark 给下一步优化提供数据。

---

# 第三部分：第一次真正实现 Grid A*

## 4. 先给现有 GridMap 增加 A* 所需的只读热路径访问

第一课 `GridMap` 已经可以 `WorldToGrid()`、`GridToWorldCenter()` 和 `QueryWorld()`。A* 每访问一个邻居都调用返回 `NavResult<NavCell>` 的高层接口，会反复构造错误对象和字符串；它需要一个更低层但仍然只读的 Cell 访问入口。

这里不改变 GridMap ownership，也不把任何 A* 状态塞进去。

### 4.1 GridMap 局部修改学习导航

本次修改解决的问题：让 Native A* 在已知 GridPos 时零分配读取 Cell。

必须精读：`TryCell()` 的边界和返回指针生命周期。

可以略读：现有第一课函数。

输入、输出和失败：

```text
输入：GridPos
输出：const NavCell*；越界返回 nullptr
失败不构造字符串，因为这是 A* 内部热路径
```

运行验证：所有第一课 `grid_map_test` 必须继续通过。

理解自测：为什么这个指针可以跨当前函数短期读取，却不能在 GridMap 销毁后保存？

### 4.2 修改 `grid_map.h`

[局部修改]

```text
server/native/grid_map/include/grid_map.h
```

找到：

```cpp
NavResult<NavCell> QueryWorld(const WorldPosition& world) const;
```

在它后面增加：

```cpp
    // Native 导航热路径按 GridPos 读取 immutable Cell。
    // grid 越界返回 nullptr；成功指针指向 GridMap 内部 const vector，调用方不释放。
    // 本函数不分配、不加锁、不修改共享状态。
    const NavCell* TryCell(const GridPos& grid) const noexcept;
```

### 4.3 修改 `grid_map.cpp`

[局部修改]

在 `QueryWorld()` 后、`Contains()` 前增加：

```cpp
const NavCell* GridMap::TryCell(const GridPos& grid) const noexcept {
    if (!Contains(grid)) {
        return nullptr;
    }
    return &cells_[IndexOf(grid)];
}
```

这就是本次对第一课 `GridMap` 的全部修改。

---

## 5. 扩展显式错误，再写 A*

第一课错误主要服务资产加载和单 Cell 查询。现在第一次出现路径失败，需要区分：

```text
OUT_OF_BOUNDS
START_NOT_NAVIGABLE
END_NOT_NAVIGABLE
NO_PATH
INVALID_AGENT
CONTEXT_CLOSED
PATH_TOO_LONG
DYNAMIC_OCCUPIED
MOVE_BLOCKED
```

`NO_PATH` 不是异常，也不能用空 Path 表示；它是完全合法的业务结果。

### 5.1 修改 `nav_result.h`

[局部修改]

在第一课 `NavError` 的 `kInvalidArgument` 后增加：

```cpp
    kInvalidAgent,          // AgentProfile 本身不合法或 profile_id 不存在。
    kStartNotNavigable,    // 起点在地图内，但不满足静态/动态通行规则。
    kEndNotNavigable,      // 终点在地图内，但不满足静态/动态通行规则。
    kNoPath,               // 起终点均合法，但当前规则下不存在连通路径。
    kContextClosed,        // Lua/业务仍在调用已经关闭的 NavigationContext。
    kPathTooLong,          // 回溯点数或累计长度超过项目保护上限。
    kDynamicOccupied,      // 动态占位提交与其他 Unit 冲突。
    kMoveBlocked,          // 缓存路径的本次跨格已被静态或动态规则拒绝。
    kInternalError,        // Native 未预期异常在 C ABI 边界被收敛，不能继续传播。
```

### 5.2 修改 `nav_result.cpp`

[局部修改]

在 `NavErrorName()` 的 switch 中增加：

```cpp
    case NavError::kInvalidAgent: return "INVALID_AGENT";
    case NavError::kStartNotNavigable: return "START_NOT_NAVIGABLE";
    case NavError::kEndNotNavigable: return "END_NOT_NAVIGABLE";
    case NavError::kNoPath: return "NO_PATH";
    case NavError::kContextClosed: return "CONTEXT_CLOSED";
    case NavError::kPathTooLong: return "PATH_TOO_LONG";
    case NavError::kDynamicOccupied: return "DYNAMIC_OCCUPIED";
    case NavError::kMoveBlocked: return "MOVE_BLOCKED";
    case NavError::kInternalError: return "INTERNAL_ERROR";
```

新增错误以后，后面的 Binding 只按稳定名字做映射；Battle 不能解析 `detail` 文案做业务分支。

---

## 6. GridPathfinder：Binary Heap + generation stamp + 8-way A*

现在输入和 owner 都已经存在，才开始 A*。

### 6.1 本课 A* 的固定规则

```text
邻居：8-way
直走基础成本：1000
斜走基础成本：1414
Heuristic：Octile Distance
Open List：Binary Min Heap
Node Scratch：NavigationContext dense array
Node 初始化：generation stamp
per-node new/delete：禁止
corner cutting：禁止
clearance：检查目标 Cell
step/slope：检查 current -> neighbor
area allowed/cost：检查目标 Cell
错误：显式 NavError
```

### 6.2 为什么不用 `std::priority_queue`

普通 `priority_queue` 很适合基础 A*，但本课还需要：

```text
Decrease-Key
heap_index
不为同一个 Node 反复 push 多个 stale entry
可观测 visited/open 状态
```

所以自己维护一个 `node_index[]` Binary Heap。每个 NodeScratch 保存自己的 `heap_index`，松弛后直接 `SiftUp()`。

### 6.3 corner cutting 图示

```text
Z ^
  |
  |  [ B ] [ # ]
  |  [ # ] [ A ]  -> 想从 A 斜走到 B
  +--------------> X

A -> B 是对角移动。
两个正交侧格都是 #。
```

如果只检查 B 自己可走，单位会从两个障碍的角之间“切过去”。因此对角移动 `(dx,dz)` 时，必须同时验证：

```text
(x + dx, z)
(x, z + dz)
```

而且使用与真正目标格一致的 `AgentProfile` 静态约束。第 7 节加入动态占位后，这两个侧格也会同时检查动态阻挡。

### 6.4 slope / step / area 的判定顺序

对一个邻居，先做便宜拒绝，再做成本计算：

```text
1. Grid 边界
2. Walkable
3. clearance
4. area allowed
5. max_step
6. max_slope
7. diagonal side cells（若斜走）
8. 计算 area-adjusted move cost
9. A* relax
```

这里不做动态占位。先让静态规则独立通过 Golden Test；第 7 节再叠加 Battle-local overlay。

### 6.5 GridPathfinder 学习导航

本文件解决的问题：在第一课 immutable GridMap 上执行一条工程化 A* 查询，并返回世界坐标 Path。

本节必须掌握：

```text
node_index / parent_index / heap_index
Binary Heap push/pop/decrease-key
generation stamp
open / closed 状态
Octile heuristic
corner cutting
clearance / step / slope / area cost
Path 回溯后 Grid -> World
```

必须精读：`CanOccupyStatic()`、`CanTraverseStatic()`、Heap 操作和 `FindPathStatic()` 主循环。

可以略读：方向数组常量、普通 overflow guard。

输入、输出和失败：

```text
输入：NavigationContext、AgentProfile、start_world、end_world
输出：Path(WorldPosition)
失败：OUT_OF_BOUNDS / START_NOT_NAVIGABLE / END_NOT_NAVIGABLE / NO_PATH / INVALID_AGENT
```

内存与锁：

```text
查询开始：0 次全图清零
访问 Node：0 次 heap allocation
Open List：复用 Context heap_storage
最终 Path：会按结果点数分配 vector
锁：0
共享可变状态：0
yield：0
```

运行验证：第 10 节统一测试入口。

理解自测：

```text
1. 为什么 closed Node 仍要带 generation？
2. 为什么 heap 中保存 node_index，而不是 Node*？
3. 为什么 Area Cost 乘在进入 neighbor 的 move cost 上？
4. 为什么本课要求 cost >= 1000？
```

### 6.6 创建 `grid_pathfinder.h`

[新建文件]

```text
server/native/grid_map/include/grid_pathfinder.h
```

```cpp
// 职责：声明当前 GridMap 的 A* 路径查询入口。
// 边界：Server Runtime Native Navigation；内部使用 GridPos，外部只接受/返回 WorldPosition。
// 输入/输出：NavigationContext + AgentProfile + A/B 世界坐标 -> Path 或显式 NavError。
// 生命周期：不保存全局状态；所有 scratch 由调用者传入的 NavigationContext 拥有。
// 不负责：本阶段不处理动态占位、不调用 Skynet、不做 Unity 表现。
#pragma once

#include "agent_profile.h"
#include "navigation_context.h"
#include "navigation_path.h"

namespace battle_nav {

class GridPathfinder final {
public:
    // 在静态 GridMap 上寻找 A->B 路径。
    // start/end 使用整数毫米世界坐标；Y 只用于输入完整性，归格使用 XZ。
    // 成功 Path 的点全部为世界坐标；函数不加锁、不 yield。
    static NavResult<Path> FindPathStatic(
        NavigationContext& context,
        const AgentProfile& profile,
        const WorldPosition& start,
        const WorldPosition& end);
};

} // namespace battle_nav
```

### 6.7 创建 `grid_pathfinder.cpp`

[新建文件]

```text
server/native/grid_map/src/grid_pathfinder.cpp
```

```cpp
// 职责：实现 Grid 8-way A*、Binary Heap、Agent 静态通行规则和 Path 回溯。
// 边界：Server Runtime Native Navigation；只读 GridMap，scratch 全部来自 NavigationContext。
// 输入/输出：WorldPosition A/B -> WorldPosition Path；失败使用 NavError。
// 内存：A* Node/Open 不做 per-node allocation；最终 Path 会分配结果 vector。
// 不负责：本文件当前不处理 DynamicOccupancy；第 7 节在同一判定链上叠加。
#include "grid_pathfinder.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <cstdint>
#include <limits>
#include <vector>

namespace battle_nav {
namespace {

constexpr std::uint32_t kStraightCost = 1000;
constexpr std::uint32_t kDiagonalCost = 1414;
constexpr std::size_t kMaxPathPoints = 65535;

struct Direction {
    std::int8_t dx;             // Grid X 偏移。
    std::int8_t dz;             // Grid Z 偏移。
    std::uint32_t base_cost;    // 1000=直走，1414=对角。
};

constexpr std::array<Direction, 8> kDirections{{
    {-1,  0, kStraightCost},
    { 1,  0, kStraightCost},
    { 0, -1, kStraightCost},
    { 0,  1, kStraightCost},
    {-1, -1, kDiagonalCost},
    {-1,  1, kDiagonalCost},
    { 1, -1, kDiagonalCost},
    { 1,  1, kDiagonalCost},
}};

// 把合法 GridPos 映射成稳定 node_index；width 来自 immutable map metadata。
std::int32_t NodeIndex(const GridMap& map, const GridPos& p) {
    const std::uint64_t index =
        static_cast<std::uint64_t>(p.z) * map.metadata().width +
        static_cast<std::uint32_t>(p.x);
    return static_cast<std::int32_t>(index);
}

// 把 node_index 还原成 GridPos；node_index 必须来自当前 map。
GridPos GridFromIndex(const GridMap& map, std::int32_t node_index) {
    const std::uint32_t width = map.metadata().width;
    return GridPos{
        static_cast<std::int32_t>(static_cast<std::uint32_t>(node_index) % width),
        static_cast<std::int32_t>(static_cast<std::uint32_t>(node_index) / width),
    };
}

// Octile Distance：8-way、直走1000、斜走1414 的可采纳启发式。
// 因为本课允许 Area Cost 只会 >=1000，所以真实代价不会低于此估计。
std::uint64_t Heuristic(const GridPos& a, const GridPos& b) {
    // 先提升到 int64 再相减，避免极端 GridPos 的 int32 减法溢出。
    const std::uint32_t dx = static_cast<std::uint32_t>(std::llabs(
        static_cast<long long>(a.x) - b.x));
    const std::uint32_t dz = static_cast<std::uint32_t>(std::llabs(
        static_cast<long long>(a.z) - b.z));
    const std::uint32_t diagonal = std::min(dx, dz);
    const std::uint32_t straight = std::max(dx, dz) - diagonal;
    return static_cast<std::uint64_t>(diagonal) * kDiagonalCost +
        static_cast<std::uint64_t>(straight) * kStraightCost;
}

// 判断一个 Cell 是否满足 Agent 的“单格静态条件”。
// 不检查 current->next 高差，也不检查 diagonal side cell；这些属于边关系。
bool CanOccupyStatic(
    const GridMap& map,
    const AgentProfile& profile,
    const GridPos& grid) {
    const NavCell* cell = map.TryCell(grid);
    if (cell == nullptr || !cell->IsWalkable()) {
        return false;
    }

    const std::uint8_t required =
        RequiredClearanceCells(profile, map.metadata().cell_size_mm);
    if (cell->clearance_cells < required) {
        return false;
    }

    const std::uint8_t area = cell->area_type;
    return profile.area_allowed[area] != 0;
}

// 判断 current->next 这条 Grid 边是否满足高度、坡度和 corner-cutting 规则。
bool CanTraverseStatic(
    const GridMap& map,
    const AgentProfile& profile,
    const GridPos& current,
    const GridPos& next,
    std::int32_t dx,
    std::int32_t dz) {
    if (!CanOccupyStatic(map, profile, next)) {
        return false;
    }

    const NavCell* from = map.TryCell(current);
    const NavCell* to = map.TryCell(next);
    if (from == nullptr || to == nullptr) {
        return false;
    }

    const std::uint64_t height_delta = static_cast<std::uint64_t>(
        std::llabs(static_cast<long long>(to->height_mm) - from->height_mm));
    if (height_delta > static_cast<std::uint64_t>(profile.max_step_mm)) {
        return false;
    }

    // 对角水平距离用 1414/1000 的整数近似，避免查询热路径浮点比较。
    const std::uint64_t horizontal_mm =
        (dx != 0 && dz != 0)
            ? static_cast<std::uint64_t>(map.metadata().cell_size_mm) * 1414 / 1000
            : map.metadata().cell_size_mm;
    if (height_delta * 1000 >
        static_cast<std::uint64_t>(profile.max_slope_permille) * horizontal_mm) {
        return false;
    }

    if (dx != 0 && dz != 0) {
        // 禁止 corner cutting：斜走时两个正交侧格都必须对同一 Agent 可站立。
        const GridPos side_x{current.x + dx, current.z};
        const GridPos side_z{current.x, current.z + dz};
        if (!CanOccupyStatic(map, profile, side_x) ||
            !CanOccupyStatic(map, profile, side_z)) {
            return false;
        }
    }
    return true;
}

// 计算进入 next Cell 的整数移动成本；Area Cost 属于 AgentProfile。
std::uint32_t MoveCost(
    const GridMap& map,
    const AgentProfile& profile,
    const GridPos& next,
    std::uint32_t base_cost) {
    const NavCell* cell = map.TryCell(next);
    const std::uint32_t area_cost = profile.area_cost_permille[cell->area_type];
    const std::uint64_t scaled =
        static_cast<std::uint64_t>(base_cost) * area_cost / 1000;
    return scaled > std::numeric_limits<std::uint32_t>::max()
        ? std::numeric_limits<std::uint32_t>::max()
        : static_cast<std::uint32_t>(scaled);
}

// heap 中两个 node 谁优先：f=g+h 更小优先；f 相同则 h 小，再 node_index 小。
// 最后的 node_index tie-break 保证相同输入下顺序稳定。
bool HeapLess(
    NavigationContext& context,
    const GridMap& map,
    std::int32_t lhs,
    std::int32_t rhs,
    const GridPos& goal) {
    auto& left = context.TouchNode(lhs);
    auto& right = context.TouchNode(rhs);
    const std::uint64_t lh = Heuristic(GridFromIndex(map, lhs), goal);
    const std::uint64_t rh = Heuristic(GridFromIndex(map, rhs), goal);
    const std::uint64_t lf = left.g_cost + lh;
    const std::uint64_t rf = right.g_cost + rh;
    if (lf != rf) return lf < rf;
    if (lh != rh) return lh < rh;
    return lhs < rhs;
}

// 交换 heap 两个 slot，同时维护对应 NodeScratch.heap_index。
void HeapSwap(
    NavigationContext& context,
    std::size_t a,
    std::size_t b) {
    auto& heap = context.heap_storage();
    std::swap(heap[a], heap[b]);
    context.TouchNode(heap[a]).heap_index = static_cast<std::int32_t>(a);
    context.TouchNode(heap[b]).heap_index = static_cast<std::int32_t>(b);
}

void SiftUp(
    NavigationContext& context,
    const GridMap& map,
    std::size_t slot,
    const GridPos& goal) {
    auto& heap = context.heap_storage();
    while (slot > 0) {
        const std::size_t parent_slot = (slot - 1) / 2;
        if (!HeapLess(context, map, heap[slot], heap[parent_slot], goal)) {
            break;
        }
        HeapSwap(context, slot, parent_slot);
        slot = parent_slot;
    }
}

void SiftDown(
    NavigationContext& context,
    const GridMap& map,
    std::size_t slot,
    const GridPos& goal) {
    auto& heap = context.heap_storage();
    const std::size_t size = context.heap_size();
    for (;;) {
        const std::size_t left = slot * 2 + 1;
        if (left >= size) break;
        const std::size_t right = left + 1;
        std::size_t best = left;
        if (right < size && HeapLess(context, map, heap[right], heap[left], goal)) {
            best = right;
        }
        if (!HeapLess(context, map, heap[best], heap[slot], goal)) {
            break;
        }
        HeapSwap(context, slot, best);
        slot = best;
    }
}

void HeapPush(
    NavigationContext& context,
    const GridMap& map,
    std::int32_t node_index,
    const GridPos& goal) {
    auto& heap = context.heap_storage();
    const std::size_t slot = context.heap_size();
    heap[slot] = node_index;
    context.set_heap_size(slot + 1);
    context.TouchNode(node_index).heap_index = static_cast<std::int32_t>(slot);
    SiftUp(context, map, slot, goal);
}

std::int32_t HeapPop(
    NavigationContext& context,
    const GridMap& map,
    const GridPos& goal) {
    auto& heap = context.heap_storage();
    const std::int32_t result = heap[0];
    const std::size_t new_size = context.heap_size() - 1;
    context.set_heap_size(new_size);
    context.TouchNode(result).heap_index = -1;
    if (new_size > 0) {
        heap[0] = heap[new_size];
        context.TouchNode(heap[0]).heap_index = 0;
        SiftDown(context, map, 0, goal);
    }
    return result;
}

// 使用整数毫米计算 XZ 线段长度，最终 Path 长度用于日志/Benchmark/Replay。
std::uint64_t SegmentLengthMm(const WorldPosition& a, const WorldPosition& b) {
    const long double dx = static_cast<long double>(b.x_mm) - a.x_mm;
    const long double dz = static_cast<long double>(b.z_mm) - a.z_mm;
    return static_cast<std::uint64_t>(std::llround(std::sqrt(dx * dx + dz * dz)));
}

NavResult<Path> BuildPath(
    NavigationContext& context,
    const GridMap& map,
    std::int32_t goal_index) {
    std::vector<std::int32_t> reversed;
    reversed.reserve(64); // 只为最终回溯结果分配；不是 per-node heap allocation。

    std::int32_t current = goal_index;
    while (current >= 0) {
        if (reversed.size() >= kMaxPathPoints) {
            return NavResult<Path>::Failure(
                NavError::kPathTooLong,
                "path point count exceeds safety limit");
        }
        reversed.push_back(current);
        const auto& node = context.TouchNode(current);
        current = node.parent_index;
    }
    std::reverse(reversed.begin(), reversed.end());

    std::vector<WorldPosition> points;
    points.reserve(reversed.size());
    std::uint64_t length_mm = 0;
    for (std::int32_t node_index : reversed) {
        const auto world = map.GridToWorldCenter(GridFromIndex(map, node_index));
        if (!world.ok()) {
            return NavResult<Path>::Failure(world.error, world.detail);
        }
        if (!points.empty()) {
            length_mm += SegmentLengthMm(points.back(), world.value);
        }
        points.push_back(world.value);
    }
    return NavResult<Path>::Success(Path(std::move(points), length_mm));
}

} // namespace

NavResult<Path> GridPathfinder::FindPathStatic(
    NavigationContext& context,
    const AgentProfile& profile,
    const WorldPosition& start,
    const WorldPosition& end) {
    const auto valid_profile = ValidateAgentProfile(profile);
    if (!valid_profile.ok()) {
        return NavResult<Path>::Failure(valid_profile.error, valid_profile.detail);
    }

    const GridMap& map = *context.map();
    const auto start_grid = map.WorldToGrid(start);
    if (!start_grid.ok()) {
        return NavResult<Path>::Failure(NavError::kOutOfBounds, "start outside map");
    }
    const auto end_grid = map.WorldToGrid(end);
    if (!end_grid.ok()) {
        return NavResult<Path>::Failure(NavError::kOutOfBounds, "end outside map");
    }
    if (!CanOccupyStatic(map, profile, start_grid.value)) {
        return NavResult<Path>::Failure(
            NavError::kStartNotNavigable,
            "start cell rejected by walkable/clearance/area");
    }
    if (!CanOccupyStatic(map, profile, end_grid.value)) {
        return NavResult<Path>::Failure(
            NavError::kEndNotNavigable,
            "end cell rejected by walkable/clearance/area");
    }

    context.BeginQuery();
    const std::int32_t start_index = NodeIndex(map, start_grid.value);
    const std::int32_t goal_index = NodeIndex(map, end_grid.value);
    auto& start_node = context.TouchNode(start_index);
    start_node.g_cost = 0;
    start_node.parent_index = -1;
    start_node.state = NavigationContext::NodeState::kOpen;
    HeapPush(context, map, start_index, end_grid.value);

    while (context.heap_size() > 0) {
        const std::int32_t current_index = HeapPop(context, map, end_grid.value);
        auto& current_node = context.TouchNode(current_index);
        if (current_node.state == NavigationContext::NodeState::kClosed) {
            continue;
        }
        current_node.state = NavigationContext::NodeState::kClosed;
        if (current_index == goal_index) {
            return BuildPath(context, map, goal_index);
        }

        const GridPos current_grid = GridFromIndex(map, current_index);
        for (const Direction& direction : kDirections) {
            const GridPos next{
                current_grid.x + direction.dx,
                current_grid.z + direction.dz,
            };
            if (!CanTraverseStatic(
                    map, profile, current_grid, next,
                    direction.dx, direction.dz)) {
                continue;
            }

            const std::int32_t next_index = NodeIndex(map, next);
            auto& next_node = context.TouchNode(next_index);
            if (next_node.state == NavigationContext::NodeState::kClosed) {
                continue;
            }

            const std::uint32_t step = MoveCost(map, profile, next, direction.base_cost);
            const std::uint64_t candidate = current_node.g_cost + step;
            if (next_node.state != NavigationContext::NodeState::kUnseen &&
                candidate >= next_node.g_cost) {
                continue;
            }

            next_node.g_cost = candidate;
            next_node.parent_index = current_index;
            if (next_node.state == NavigationContext::NodeState::kUnseen) {
                next_node.state = NavigationContext::NodeState::kOpen;
                HeapPush(context, map, next_index, end_grid.value);
            } else {
                // 已经在 Open 中，本次找到更低 g-cost；heap_index 直接执行 decrease-key。
                SiftUp(
                    context,
                    map,
                    static_cast<std::size_t>(next_node.heap_index),
                    end_grid.value);
            }
        }
    }

    return NavResult<Path>::Failure(
        NavError::kNoPath,
        "open list exhausted before reaching goal");
}

} // namespace battle_nav
```

> 说明：`BuildPath()` 为了输出精确毫米折线长度使用 `sqrt`。它不参与 A* 排序、通行判定和确定性 tie-break；真正的搜索成本全部是整数。若项目要求跨不同 CPU/标准库得到 bit-for-bit 相同的 `length_mm`，把这里替换成项目统一的整数平方根即可。逻辑 Event 的确定性不要依赖这个统计字段。

### 6.8 为什么现在还没有 DynamicOccupancy

因为当前先锁定静态算法错误：

```text
walkable
clearance
step
slope
area cost
corner cutting
```

如果一开始把动态单位也混进去，`NO_PATH` 时会很难判断是地图、Agent 还是 Battle 状态造成。下一节在静态 Golden Cases 全通过之后，再把动态层叠上去。


## 6.9 Path 起点仍然是业务 WorldPosition，不让单位先跳到 Cell Center

A* 的 node 必然对应 Cell Center，但 Battle 的真实起点可能位于 Cell 内任意毫米位置。
例如第一课真实出生点 `x=-11000mm` 落入 500mm Cell 后，对应 Cell Center 可能是 `-10750mm`。如果 Path 第一个点直接返回 Center，Replay 会先瞬移 250mm。

因此 `BuildPath()` 在把 Grid 序列转换为世界点以后，再收敛端点：

```text
第一个点：保留 start_world 的 X/Z，Y 使用 start Cell 的静态 height_mm
精确 FindPath 最后一点：保留 end_world 的 X/Z，Y 使用 end Cell 静态 height_mm
FindPathToRange 最后一点：仍使用实际 goal Cell Center，不能替换成 target 中心
```

这仍然是 WorldPosition 合同。起点/终点所在 Cell 已经经过 `walkable/clearance/area` 验证；Cell 内连续几何精度受当前 2.5D Grid 分辨率限制。

[局部修改]

让 `BuildPath()` 接收 `start_world` 和可选的 `exact_end_world`。世界点生成完成后：

```cpp
if (!points.empty()) {
    // 保留业务起点 XZ，Y 继续使用 Server Grid 的权威地表高度。
    points.front().x_mm = start_world.x_mm;
    points.front().z_mm = start_world.z_mm;
}
if (exact_end_world != nullptr) {
    if (points.size() == 1 &&
        (points.front().x_mm != exact_end_world->x_mm ||
         points.front().z_mm != exact_end_world->z_mm)) {
        // A/B 落在同一 Cell 但不是同一个毫米位置时，仍要返回真实 B。
        WorldPosition exact = points.front();
        exact.x_mm = exact_end_world->x_mm;
        exact.z_mm = exact_end_world->z_mm;
        points.push_back(exact);
    } else {
        points.back().x_mm = exact_end_world->x_mm;
        points.back().z_mm = exact_end_world->z_mm;
    }
}
```

修改端点后再重新累计 `length_mm`；不要先算长度再改点。`FindPathToRange()` 的 `exact_end_world` 传 `nullptr`，因为真正终点是搜索得到的攻击位置。第 10 节还要增加“同一 Cell 内 A/B 不同”的用例，锁定这条不会瞬移也不会丢失终点的合同。

---

# 第四部分：动态单位出现后，再给每场 Battle 增加 DynamicOccupancy

## 7. DynamicOccupancy：静态地图不再足够

静态 A* 跑通以后，出现第一个 Battle 问题：

```text
地图上这条路静态可走，
但现在另一个单位正站在这里。
```

第一课的 BMAP 不能修改：

```text
GridMap = 地图资产事实
DynamicOccupancy = 当前 Battle 的瞬时事实
```

如果把单位写进 `NavCell.flags`：

```text
Battle A Unit 10 occupy cell 500
-> 修改共享 GridMap
-> Battle B 同时看到 cell 500 被阻挡
```

这会直接破坏 Battle 隔离和 Native 线程安全。

### 7.1 DynamicOccupancy 的课程模型

每场 Battle 的 Occupancy 使用一个与 Grid 一样大的 `uint32_t owner_by_cell[]`：

```text
0       = 当前没有动态单位预留
unit_id = 该 Cell 被这个 Unit 的 footprint 预留
```

本课单位用圆形 `radius_mm`，映射到 Grid 时采用保守 footprint：

```text
检查以中心 Cell 为原点的有限邻域；
某邻居 Cell Center 到单位中心的距离
<= radius_mm + cell_size_mm/2
则由该单位预留。
```

这不是完整 steering/crowd system。它解决的是本课需要的离散动态阻挡、冲突提交和寻路避让。大量密集士兵的局部避碰属于后续可单独演进的系统，不能用“每 Tick A*”替代。

### 7.2 为什么 Move 必须先验证，再 commit

错误写法：

```text
clear old footprint
-> 发现 new footprint 被占用
-> 返回失败
```

失败以后，单位已经从 Occupancy 消失。

正确顺序：

```text
Validate new footprint
-> 全部 Cell 都是 empty 或 self
-> clear old footprint owned by self
-> write new footprint
-> success
```

单个 `NavigationContext` 在 BattleWorker no-yield 核心中由同一个 Battle owner 使用，所以这里不加 mutex。多个 Battle 各自有自己的 Occupancy；共享锁不是正确的隔离方式。

### 7.3 DynamicOccupancy 学习导航

本文件解决的问题：保存一场 Battle 自己的单位占位，并提供原子语义的 place/move/release。

本节必须掌握：

```text
owner_by_cell ownership
unit_id=0 保留为空
footprint 与 Agent radius 的关系
Move validate-before-commit
ignore self
```

必须精读：`ForEachFootprintCell()`、`CanPlace()`、`Move()`。

可以略读：lambda 调用语法。

输入、输出和失败：

```text
输入：GridMap 尺寸、AgentProfile、中心 GridPos、unit_id
输出：占位成功/失败，或单 Cell 是否被其他 Unit 阻挡
失败：越界 footprint、unit_id=0、与其他 Unit 冲突
```

内存：构造时 `cell_count * sizeof(uint32_t)`；查询/移动不分配。

运行验证：第 10 节统一测试覆盖 occupy/move/release/conflict/ignore self。

理解自测：为什么 Occupancy 不应该成为 `MapRegistry` 的字段？

### 7.4 创建 DynamicOccupancy

[新建文件]

```text
server/native/grid_map/include/dynamic_occupancy.h
```

```cpp
// 职责：保存一场 Battle 的地面单位动态 footprint 占位。
// 边界：Server Runtime Battle-local Mutable State；绝不写入共享 GridMap。
// 输入/输出：unit_id + AgentProfile + GridPos -> place/move/release/blocked 查询。
// 生命周期：随 NavigationContext/Battle 创建和销毁；不跨 Battle 共享。
// 内存：构造时一次分配 owner_by_cell；热路径不做动态分配。
// 不负责：不做 A*、不保存 HP/AI、不实现 steering 或速度积分。
#pragma once

#include "agent_profile.h"
#include "grid_map.h"
#include "nav_result.h"

#include <cstddef>
#include <cstdint>
#include <limits>
#include <vector>

namespace battle_nav {

class DynamicOccupancy final {
public:
    // 按 map cell_count 创建空 Occupancy；map 必须在本对象生命周期内保持存活。
    explicit DynamicOccupancy(const GridMap& map);

    // 返回 grid 是否被 ignore_unit_id 之外的单位占用。
    // 越界视为 blocked；0 表示不忽略任何单位。
    bool IsBlocked(const GridPos& grid, std::uint32_t ignore_unit_id) const noexcept;

    // 验证并预留 unit_id 的 footprint；成功后所有 footprint Cell owner=unit_id。
    NavResult<bool> Place(
        std::uint32_t unit_id,
        const AgentProfile& profile,
        const GridPos& center);

    // 原子语义移动：先完整验证 to footprint，再清 old，再写 new。
    // 失败时原占位保持不变。
    NavResult<bool> Move(
        std::uint32_t unit_id,
        const AgentProfile& profile,
        const GridPos& from,
        const GridPos& to);

    // 只清理由 unit_id 自己持有的 footprint Cell；重复 Release 安全但返回成功。
    NavResult<bool> Release(
        std::uint32_t unit_id,
        const AgentProfile& profile,
        const GridPos& center);

    // Debug/Test：返回当前单 Cell owner；越界返回 0。
    std::uint32_t OwnerAt(const GridPos& grid) const noexcept;

private:
    // 根据 Agent 半径遍历保守 footprint。
    // Callback 返回 false 时提前停止；不构造临时 Cell vector。
    template <typename Callback>
    bool ForEachFootprintCell(
        const AgentProfile& profile,
        const GridPos& center,
        Callback callback) const {
        const std::int64_t cell = map_.metadata().cell_size_mm;
        const std::int64_t threshold =
            static_cast<std::int64_t>(profile.radius_mm) + cell / 2;
        const std::int32_t max_offset = static_cast<std::int32_t>(
            (threshold + cell - 1) / cell);

        for (std::int32_t dz = -max_offset; dz <= max_offset; ++dz) {
            for (std::int32_t dx = -max_offset; dx <= max_offset; ++dx) {
                const std::int64_t world_dx = static_cast<std::int64_t>(dx) * cell;
                const std::int64_t world_dz = static_cast<std::int64_t>(dz) * cell;
                const std::uint64_t ax = static_cast<std::uint64_t>(
                    world_dx < 0 ? -world_dx : world_dx);
                const std::uint64_t az = static_cast<std::uint64_t>(
                    world_dz < 0 ? -world_dz : world_dz);
                const std::uint64_t r = static_cast<std::uint64_t>(threshold);
                if (ax > r || az > r) {
                    continue;
                }
                const std::uint64_t r2 = r * r;
                const std::uint64_t ax2 = ax * ax;
                const std::uint64_t az2 = az * az;
                // 使用减法比较，避免 ax2+az2 在极端参数下 uint64 溢出。
                if (ax2 > r2 || az2 > r2 - ax2) {
                    continue;
                }
                // 先提升再相加，恶意超大 radius 也不能触发 int32 signed overflow。
                const std::int64_t grid_x =
                    static_cast<std::int64_t>(center.x) + dx;
                const std::int64_t grid_z =
                    static_cast<std::int64_t>(center.z) + dz;
                if (grid_x < std::numeric_limits<std::int32_t>::min() ||
                    grid_x > std::numeric_limits<std::int32_t>::max() ||
                    grid_z < std::numeric_limits<std::int32_t>::min() ||
                    grid_z > std::numeric_limits<std::int32_t>::max()) {
                    return false;
                }
                const GridPos grid{
                    static_cast<std::int32_t>(grid_x),
                    static_cast<std::int32_t>(grid_z)};
                if (map_.TryCell(grid) == nullptr || !callback(grid)) {
                    return false;
                }
            }
        }
        return true;
    }

    // 合法 GridPos -> row-major owner 数组下标；调用前必须确保在地图内。
    std::size_t IndexOf(const GridPos& grid) const noexcept;

    const GridMap& map_;                  // 非 owning immutable map 引用；Context 保证生命周期。
    std::vector<std::uint32_t> owners_;   // 每 Cell 动态 owner；0=empty，本对象独占。
};

} // namespace battle_nav
```

[新建文件]

```text
server/native/grid_map/src/dynamic_occupancy.cpp
```

```cpp
// 职责：实现 Battle-local 动态 footprint 占位和 validate-before-commit 移动。
// 边界：Server Runtime Mutable Navigation State；只读 GridMap，不访问全局 Registry。
// 输入/输出：单位 footprint 变更 -> owner_by_cell 更新或明确冲突。
// 锁/yield：无锁、无 I/O、无 yield；要求调用者遵守单 Battle owner 规则。
// 不负责：不检查静态 walkable/clearance/slope；这些由 GridPathfinder 负责。
#include "dynamic_occupancy.h"

namespace battle_nav {

DynamicOccupancy::DynamicOccupancy(const GridMap& map)
    : map_(map), owners_(map.cell_count(), 0) {}

std::size_t DynamicOccupancy::IndexOf(const GridPos& grid) const noexcept {
    return static_cast<std::size_t>(grid.z) * map_.metadata().width +
        static_cast<std::size_t>(grid.x);
}

std::uint32_t DynamicOccupancy::OwnerAt(const GridPos& grid) const noexcept {
    if (map_.TryCell(grid) == nullptr) {
        return 0;
    }
    return owners_[IndexOf(grid)];
}

bool DynamicOccupancy::IsBlocked(
    const GridPos& grid,
    std::uint32_t ignore_unit_id) const noexcept {
    if (map_.TryCell(grid) == nullptr) {
        return true;
    }
    const std::uint32_t owner = owners_[IndexOf(grid)];
    return owner != 0 && owner != ignore_unit_id;
}

NavResult<bool> DynamicOccupancy::Place(
    std::uint32_t unit_id,
    const AgentProfile& profile,
    const GridPos& center) {
    if (unit_id == 0) {
        return NavResult<bool>::Failure(
            NavError::kInvalidArgument,
            "unit_id 0 is reserved for empty occupancy");
    }

    const bool available = ForEachFootprintCell(
        profile,
        center,
        [&](const GridPos& grid) {
            const std::uint32_t owner = owners_[IndexOf(grid)];
            return owner == 0 || owner == unit_id;
        });
    if (!available) {
        return NavResult<bool>::Failure(
            NavError::kDynamicOccupied,
            "dynamic footprint is outside map or occupied");
    }

    ForEachFootprintCell(profile, center, [&](const GridPos& grid) {
        owners_[IndexOf(grid)] = unit_id;
        return true;
    });
    return NavResult<bool>::Success(true);
}

NavResult<bool> DynamicOccupancy::Move(
    std::uint32_t unit_id,
    const AgentProfile& profile,
    const GridPos& from,
    const GridPos& to) {
    if (unit_id == 0) {
        return NavResult<bool>::Failure(
            NavError::kInvalidArgument,
            "unit_id 0 is reserved for empty occupancy");
    }

    // Phase 1：完整验证新 footprint。此时旧 footprint 仍然存在，self 可以被忽略。
    const bool available = ForEachFootprintCell(
        profile,
        to,
        [&](const GridPos& grid) {
            const std::uint32_t owner = owners_[IndexOf(grid)];
            return owner == 0 || owner == unit_id;
        });
    if (!available) {
        return NavResult<bool>::Failure(
            NavError::kDynamicOccupied,
            "destination footprint conflicts with another unit");
    }

    // Phase 2：只清理由 self 持有的旧 Cell，避免错误释放其他单位。
    ForEachFootprintCell(profile, from, [&](const GridPos& grid) {
        std::uint32_t& owner = owners_[IndexOf(grid)];
        if (owner == unit_id) {
            owner = 0;
        }
        return true;
    });

    // Phase 3：提交新 footprint。验证已经完成，此处不会留下半占位。
    ForEachFootprintCell(profile, to, [&](const GridPos& grid) {
        owners_[IndexOf(grid)] = unit_id;
        return true;
    });
    return NavResult<bool>::Success(true);
}

NavResult<bool> DynamicOccupancy::Release(
    std::uint32_t unit_id,
    const AgentProfile& profile,
    const GridPos& center) {
    if (unit_id == 0) {
        return NavResult<bool>::Failure(
            NavError::kInvalidArgument,
            "unit_id 0 is invalid");
    }
    ForEachFootprintCell(profile, center, [&](const GridPos& grid) {
        std::uint32_t& owner = owners_[IndexOf(grid)];
        if (owner == unit_id) {
            owner = 0;
        }
        return true;
    });
    return NavResult<bool>::Success(true);
}

} // namespace battle_nav
```

### 7.5 把 Occupancy 加到 NavigationContext

现在 `DynamicOccupancy` 已经有真实使用者，所以修改 Context。

[局部修改]

```text
server/native/grid_map/include/navigation_context.h
```

`navigation_context.h/.cpp` 的职责已经从“只拥有 A* scratch”扩展为“拥有一场 Battle 的全部可变导航状态”。两处文件头中的输入/输出和非职责同步改为：

```cpp
// 输入/输出：immutable GridMap -> 可复用 A* scratch + Battle-local DynamicOccupancy。
// 不负责：不拥有 MapRegistry，不保存 HP/AI，不把 GridPos 暴露给 Lua 业务。
```

在 include 区增加：

```cpp
#include "dynamic_occupancy.h"
```

在 public 区增加：

```cpp
    // 返回本 Battle 私有动态占位；调用者只能在本 Context owner 内修改。
    DynamicOccupancy& occupancy() noexcept { return occupancy_; }
    const DynamicOccupancy& occupancy() const noexcept { return occupancy_; }
```

在 private 字段中，紧跟 `map_` 增加：

```cpp
    DynamicOccupancy occupancy_; // 当前 Battle 的动态 footprint；与 map_ 尺寸一致。
```

[局部修改]

```text
server/native/grid_map/src/navigation_context.cpp
```

构造初始化列表从：

```cpp
NavigationContext::NavigationContext(std::shared_ptr<const GridMap> map)
    : map_(std::move(map)) {
```

改为：

```cpp
NavigationContext::NavigationContext(std::shared_ptr<const GridMap> map)
    : map_(std::move(map)),
      occupancy_(*map_) {
```

注意：真实代码中必须保证 `map_` 非空后才能解引用。更稳妥的完整实现应使用一个先检查参数的静态 helper，或者把 `occupancy_` 改成在构造函数体内通过 `std::unique_ptr` 创建。本课程采用下面这个安全版本替换构造函数：

```cpp
namespace {
std::shared_ptr<const GridMap> RequireMap(std::shared_ptr<const GridMap> map) {
    if (!map) {
        throw std::invalid_argument("NavigationContext requires map");
    }
    return map;
}
} // namespace

NavigationContext::NavigationContext(std::shared_ptr<const GridMap> map)
    : map_(RequireMap(std::move(map))),
      occupancy_(*map_) {
    if (map_->cell_count() >
        static_cast<std::size_t>(std::numeric_limits<std::int32_t>::max())) {
        throw std::invalid_argument("map has too many cells for int32 node index");
    }
    nodes_.resize(map_->cell_count());
    heap_.resize(map_->cell_count());
}
```

这样不会出现“为了初始化 occupancy 先解引用 null shared_ptr”的隐藏 UB。

### 7.6 把动态占位叠加到 A*，而不是复制第二套 A*

[局部修改]

```text
server/native/grid_map/include/grid_pathfinder.h
```

同时更新 `grid_pathfinder.h/.cpp` 文件头：它们现在处理静态规则与可选 Battle-local Occupancy，删除“当前不处理 DynamicOccupancy”的旧说明。更新后的非职责应是：

```cpp
// 不负责：不保存 Battle 单位状态，不调用 Skynet，不执行 Unity 表现或未来 Detour 查询。
```

在 `FindPathStatic()` 后增加正式 Battle 入口：

```cpp
    // 在静态地图规则上再叠加当前 Context 的 DynamicOccupancy。
    // ignore_unit_id 通常传移动者自己，使起点 footprint 不阻挡自己。
    static NavResult<Path> FindPath(
        NavigationContext& context,
        const AgentProfile& profile,
        const WorldPosition& start,
        const WorldPosition& end,
        std::uint32_t ignore_unit_id);

    // Test/Debug：重新验证 Path 每个 Segment 是否仍满足静态规则。
    static NavResult<bool> ValidatePathStatic(
        NavigationContext& context,
        const AgentProfile& profile,
        const Path& path);

    // Test/Debug：重新验证 Path，并叠加当前 Context 动态占位；不暴露给 Lua 业务。
    static NavResult<bool> ValidatePath(
        NavigationContext& context,
        const AgentProfile& profile,
        const Path& path,
        std::uint32_t ignore_unit_id);

    // 验证并提交单位的一次连续移动。from/to 是毫米制世界坐标；unit_id 是占位 owner。
    // 先用 A* 相同的静态、坡度、切角和动态规则验证跨格，再原子更新 Occupancy。
    // 成功返回 true；缓存路径失效返回 MOVE_BLOCKED，占位提交冲突返回 DYNAMIC_OCCUPIED。
    // 不分配大块内存、不加锁、不 yield；要求调用者独占当前 NavigationContext。
    static NavResult<bool> MoveUnit(
        NavigationContext& context,
        const AgentProfile& profile,
        std::uint32_t unit_id,
        const WorldPosition& from,
        const WorldPosition& to);
```

不要复制整个 A* 主循环。把 `grid_pathfinder.cpp` 中的：

```cpp
CanOccupyStatic(...)
CanTraverseStatic(...)
```

整理成一个内部 `QueryPolicy`：

```cpp
struct QueryPolicy {
    const DynamicOccupancy* occupancy = nullptr; // nullptr 表示静态 Golden Test。
    std::uint32_t ignore_unit_id = 0;            // 移动者自己的 unit_id。
};

bool CanOccupy(
    const GridMap& map,
    const AgentProfile& profile,
    const GridPos& grid,
    const QueryPolicy& policy) {
    if (!CanOccupyStatic(map, profile, grid)) {
        return false;
    }
    return policy.occupancy == nullptr ||
        !policy.occupancy->IsBlocked(grid, policy.ignore_unit_id);
}
```

`CanTraverseStatic()` 中的目标 Cell 和两个 diagonal side Cell 都改成调用 `CanOccupy(..., policy)`。这一步非常重要：如果只对最终对角目标检查 Occupancy，单位仍可能从两个动态单位形成的窄角中切过去。

随后把原 A* 主体抽成一个私有：

```cpp
NavResult<Path> FindPathImpl(
    NavigationContext& context,
    const AgentProfile& profile,
    const WorldPosition& start,
    const WorldPosition& end,
    const QueryPolicy& policy);
```

两个公开入口只提供不同 policy：

```cpp
NavResult<Path> GridPathfinder::FindPathStatic(...) {
    return FindPathImpl(context, profile, start, end, QueryPolicy{});
}

NavResult<Path> GridPathfinder::FindPath(
    NavigationContext& context,
    const AgentProfile& profile,
    const WorldPosition& start,
    const WorldPosition& end,
    std::uint32_t ignore_unit_id) {
    QueryPolicy policy;
    policy.occupancy = &context.occupancy();
    policy.ignore_unit_id = ignore_unit_id;
    return FindPathImpl(context, profile, start, end, policy);
}
```

这里没有新算法，只有一层 Battle-local policy。静态测试继续走 `FindPathStatic()`，Battle 走 `FindPath()`。

---

## 8. Path Smoothing：不能为了好看破坏已经正确的路径

Grid A* 的原始点可能是：

```text
A -> (1,0) -> (2,1) -> (3,1) -> (4,2) -> B
```

Unity 如果逐点播放，会有明显锯齿。可以删除中间冗余点，但不能只做几何直线判断。

每条候选简化 Segment 必须重新验证：

```text
walkable
clearance
step
slope
corner cutting
dynamic occupancy
area policy
```

还要注意 Area Cost：

```text
A* 绕开一大片 Mud
-> 纯 line-of-sight smoothing 直接穿过 Mud
-> 路径虽然“可走”，但改变了 A* 的成本选择
```

因此本课只有在：

```text
直接 Segment 合法
并且
direct_segment_cost <= original_subpath_cost
```

时才允许替换。

### 8.1 Smoothing 学习导航

本次修改解决的问题：减少 Grid 锯齿点，同时保持原静态/动态合法性和 Area Cost 语义。

必须精读：Supercover 遍历为什么覆盖线段穿过的所有 Cell、为何 smoothing 后重新走同一 `CanTraverse()`。

可以略读：Bresenham/Supercover 的整数误差变量。

输入、输出和失败：

```text
输入：已经由 A* 得到的 Grid node 序列
输出：点数 <= 原路径的合法序列
失败：某候选 shortcut 不合法时保留原中间点，不把整次 FindPath 判失败
```

内存：允许为最终 smoothing 结果 reserve O(path_points)；不做 per-map-size 分配。

运行验证：统一测试会逐 Segment 再验证合法性。

理解自测：为什么“Raycast 没撞墙”还不足以证明 smoothing 正确？

### 8.2 在 `grid_pathfinder.cpp` 中增加 Supercover 验证

[局部修改]

在匿名 namespace 中增加下面的辅助类型和函数。它们复用 A* 的 `CanTraverse()` 和 `MoveCost()`，不要另写一套“简化版可走判断”。

```cpp
struct SegmentCheck {
    bool valid = false;
    std::uint64_t cost = 0; // 使用与 A* 相同的整数 Area-adjusted cost。
};

// 使用整数 Supercover 思路逐 Cell 穿过一条 Grid 直线。
// 每一步都重新调用与 A* 相同的 CanTraverse，因此 corner/clearance/slope/dynamic 不会绕过。
SegmentCheck ValidateGridSegment(
    const GridMap& map,
    const AgentProfile& profile,
    const QueryPolicy& policy,
    GridPos from,
    const GridPos& to) {
    const int delta_x = to.x - from.x;
    const int delta_z = to.z - from.z;
    const int step_x = delta_x > 0 ? 1 : (delta_x < 0 ? -1 : 0);
    const int step_z = delta_z > 0 ? 1 : (delta_z < 0 ? -1 : 0);
    const int nx = std::abs(delta_x);
    const int nz = std::abs(delta_z);

    int ix = 0;
    int iz = 0;
    std::uint64_t cost = 0;
    while (ix < nx || iz < nz) {
        // 比较下一次跨越 X/Z 网格边界的归一化时刻。
        const long long lhs = static_cast<long long>(1 + 2 * ix) * nz;
        const long long rhs = static_cast<long long>(1 + 2 * iz) * nx;

        GridPos next = from;
        std::uint32_t base = kStraightCost;
        int dx = 0;
        int dz = 0;
        if (lhs == rhs) {
            dx = step_x;
            dz = step_z;
            ++ix;
            ++iz;
            base = kDiagonalCost;
        } else if (lhs < rhs) {
            dx = step_x;
            ++ix;
        } else {
            dz = step_z;
            ++iz;
        }
        next.x += dx;
        next.z += dz;

        if (!CanTraverse(map, profile, from, next, dx, dz, policy)) {
            return SegmentCheck{};
        }
        cost += MoveCost(map, profile, next, base);
        from = next;
    }
    return SegmentCheck{true, cost};
}
```

然后在 A* 到达 goal、回溯得到 `reversed` 并反转以后，不要马上 `GridToWorldCenter()`。先把 node index 转成 GridPos 数组，再做 greedy smoothing：

```cpp
std::vector<GridPos> SmoothGridPath(
    const GridMap& map,
    const AgentProfile& profile,
    const QueryPolicy& policy,
    const std::vector<GridPos>& raw) {
    if (raw.size() <= 2) {
        return raw;
    }

    std::vector<GridPos> out;
    out.reserve(raw.size());
    std::size_t anchor = 0;
    out.push_back(raw[0]);

    while (anchor + 1 < raw.size()) {
        std::size_t best = anchor + 1;
        std::uint64_t original_cost = 0;

        for (std::size_t candidate = anchor + 1;
             candidate < raw.size(); ++candidate) {
            if (candidate > anchor + 1) {
                // original_cost 累加原始子路径的真实 Area-adjusted cost。
                const GridPos prev = raw[candidate - 1];
                const GridPos cur = raw[candidate];
                const int dx = cur.x - prev.x;
                const int dz = cur.z - prev.z;
                original_cost += MoveCost(
                    map,
                    profile,
                    cur,
                    (dx != 0 && dz != 0) ? kDiagonalCost : kStraightCost);
            } else {
                const GridPos prev = raw[anchor];
                const GridPos cur = raw[candidate];
                const int dx = cur.x - prev.x;
                const int dz = cur.z - prev.z;
                original_cost = MoveCost(
                    map,
                    profile,
                    cur,
                    (dx != 0 && dz != 0) ? kDiagonalCost : kStraightCost);
            }

            const SegmentCheck direct = ValidateGridSegment(
                map, profile, policy, raw[anchor], raw[candidate]);
            if (!direct.valid || direct.cost > original_cost) {
                break;
            }
            best = candidate;
        }

        out.push_back(raw[best]);
        anchor = best;
    }
    return out;
}
```

最后：

```text
parent 回溯 node_index
-> raw GridPos
-> SmoothGridPath
-> 每个 GridPos 调 GridToWorldCenter
-> Path(WorldPosition)
```

再给 Native Test/Debug 增加一个很薄的整 Path 复验入口。它不写第二套规则，只把每两个世界点重新 `WorldToGrid()` 后调用同一个 `ValidateGridSegment()`：

```cpp
NavResult<bool> ValidatePathImpl(
    NavigationContext& context,
    const AgentProfile& profile,
    const Path& path,
    const QueryPolicy& policy) {
    if (path.count() == 0) {
        return NavResult<bool>::Failure(NavError::kNoPath, "empty path");
    }
    const GridMap& map = *context.map();
    for (std::size_t i = 1; i < path.count(); ++i) {
        const auto from = map.WorldToGrid(path.WorldPoint(i - 1));
        const auto to = map.WorldToGrid(path.WorldPoint(i));
        if (!from.ok() || !to.ok()) {
            return NavResult<bool>::Failure(NavError::kOutOfBounds, "path point outside map");
        }
        if (!ValidateGridSegment(map, profile, policy, from.value, to.value).valid) {
            return NavResult<bool>::Failure(
                NavError::kNoPath,
                "smoothed path contains invalid segment");
        }
    }
    return NavResult<bool>::Success(true);
}
```

`ValidatePathStatic()` 传空 Dynamic policy；`ValidatePath()` 传 `context.occupancy()+ignore_unit_id`。这两个函数只给测试/诊断使用，不进入 Lua 长期业务 API。

缓存 Path 在生成后，其他单位仍可能移动到下一段的目标格或两个对角侧格。`move_unit` 因此不能只调用 `DynamicOccupancy::Move()` 检查终点 footprint；否则会重新出现动态 corner cutting。复用同一个 Segment Validator 实现正式提交入口：

```cpp
NavResult<bool> GridPathfinder::MoveUnit(
    NavigationContext& context,
    const AgentProfile& profile,
    std::uint32_t unit_id,
    const WorldPosition& from,
    const WorldPosition& to) {
    if (unit_id == 0) {
        return NavResult<bool>::Failure(
            NavError::kInvalidArgument, "unit_id 0 is reserved");
    }

    const GridMap& map = *context.map();
    const auto from_grid = map.WorldToGrid(from);
    if (!from_grid.ok()) {
        return NavResult<bool>::Failure(from_grid.error, from_grid.detail);
    }
    const auto to_grid = map.WorldToGrid(to);
    if (!to_grid.ok()) {
        return NavResult<bool>::Failure(to_grid.error, to_grid.detail);
    }
    if (from_grid.value.x == to_grid.value.x &&
        from_grid.value.z == to_grid.value.z) {
        return NavResult<bool>::Success(true);
    }

    QueryPolicy policy;
    policy.occupancy = &context.occupancy();
    policy.ignore_unit_id = unit_id;
    const SegmentCheck transition = ValidateGridSegment(
        map, profile, policy, from_grid.value, to_grid.value);
    if (!transition.valid) {
        return NavResult<bool>::Failure(
            NavError::kMoveBlocked,
            "cached path transition is no longer traversable");
    }
    return context.occupancy().Move(
        unit_id, profile, from_grid.value, to_grid.value);
}
```

这里的“验证后提交”在一次同步 Native 调用里完成；同一 Battle 的 Context 只有一个 owner，所以两步之间没有另一个线程修改同一 Occupancy。不同 Battle 使用不同 Context，不需要为共享静态地图加锁。

第 10 节测试不能只断言“点变少了”。它必须重新检查 smoothing 后每一段都合法。

---

## 9. 起点/终点已被单位占用时，先区分 self 和 target

Battle 中两个常见情况：

```text
start Cell 被自己占用
end Cell 是目标中心，被目标占用
```

第一种应该通过 `ignore_unit_id=self` 忽略自己。

第二种不能简单 `ignore target` 后让攻击者走到目标身体中心。近战真实需求是：

> 找到一个处于 attack range、自己能站立、当前未被其他单位占用的位置。

这就是 Attack Position。

### 9.1 为什么这里不需要“未来 Backend 抽象”

业务只要求：

```text
给定 start / target / attack_range
-> 找到一条最终进入攻击范围的合法地面路径
```

现在底层只有 Grid，所以直接在当前 Grid 导航能力里实现。可选第四课接 Detour 时，再从 Grid 与 Detour 的两个真实实现中抽取共同 Contract。

### 9.2 本课的 FindPathToRange

最简单且正确的实现，是从 start 做同一套 A*/Dijkstra 搜索，只把“终点条件”从：

```text
current == exact goal Cell
```

改成：

```text
current Cell Center 到 target_world 的 XZ 距离 <= attack_range_mm
并且当前 Cell 满足完整通行/Occupancy 规则
```

为了避免给“一个目标区域”设计错误的过高 heuristic，本课第一版对这个入口使用 `h=0`，也就是保留同一套 Binary Heap/Relax 的 Dijkstra 形式。它只在需要生成/重生成攻击路径时运行，不是每 Tick 运行。

后续 Benchmark 如果证明大地图攻击寻路成为瓶颈，可以增加对目标圆的可采纳 heuristic；不要先写一个看似聪明但可能破坏最优性的估计。

[局部修改]

在 `grid_pathfinder.h` 增加：

```cpp
    // 寻找到任一“进入 target 攻击范围”的合法 Cell；target 中心可以被目标自己占用。
    // self_unit_id 只忽略移动者自己，绝不忽略 target_unit_id 的动态 footprint。
    static NavResult<Path> FindPathToRange(
        NavigationContext& context,
        const AgentProfile& profile,
        const WorldPosition& start,
        const WorldPosition& target,
        std::uint32_t attack_range_mm,
        std::uint32_t self_unit_id);
```

目标判定使用整数平方距离：

```cpp
bool InAttackRange(
    const GridMap& map,
    const GridPos& grid,
    const WorldPosition& target,
    std::uint32_t range_mm) {
    const auto world = map.GridToWorldCenter(grid);
    if (!world.ok()) return false;
    const std::int64_t dx =
        static_cast<std::int64_t>(world.value.x_mm) - target.x_mm;
    const std::int64_t dz =
        static_cast<std::int64_t>(world.value.z_mm) - target.z_mm;
    const std::uint64_t ax = static_cast<std::uint64_t>(dx < 0 ? -dx : dx);
    const std::uint64_t az = static_cast<std::uint64_t>(dz < 0 ? -dz : dz);
    const std::uint64_t range2 =
        static_cast<std::uint64_t>(range_mm) * range_mm;
    if (ax > range_mm || az > range_mm) return false;
    // 分步减法比较，避免两个平方相加在 int32 极端坐标差下溢出 uint64。
    const std::uint64_t ax2 = ax * ax;
    return az * az <= range2 - ax2;
}
```

`FindPathToRange()` 复用原来的：

```text
CanTraverse
MoveCost
Binary Heap
NodeScratch
generation stamp
Build/Smooth Path
```

不要复制主循环。把精确终点和攻击范围终点收敛成一个内部 GoalPolicy：

```cpp
struct GoalPolicy {
    bool exact = true;              // true=必须到 exact_grid；false=进入 target_world 的攻击范围即可。
    GridPos exact_grid{};           // 仅 exact=true 时使用。
    WorldPosition target_world{};   // 仅 exact=false 时使用，单位毫米。
    std::uint32_t attack_range_mm = 0;
};

bool IsGoal(const GridMap& map, const GridPos& current, const GoalPolicy& goal) {
    if (goal.exact) {
        return current.x == goal.exact_grid.x && current.z == goal.exact_grid.z;
    }
    return InAttackRange(map, current, goal.target_world, goal.attack_range_mm);
}

std::uint64_t GoalHeuristic(const GridPos& current, const GoalPolicy& goal) {
    // 精确 A->B 使用 Octile；目标区域第一版使用 Dijkstra(h=0) 保证不高估。
    return goal.exact ? Heuristic(current, goal.exact_grid) : 0;
}
```

原 `FindPathImpl()` 的两个位置替换为：

```cpp
if (IsGoal(map, current_grid, goal)) {
    return BuildPathFromGoal(...);
}

// HeapLess / SiftUp / SiftDown 统一读取 GoalHeuristic，而不是写死 exact end。
```

`FindPath()` 构造 `exact=true` 的 GoalPolicy；`FindPathToRange()` 构造 `exact=false`。其余 Neighbor/Relax/Heap/Parent/Smoothing 代码完全共用。

不要创建 `AttackAStar.cpp`。复制两套搜索代码，后面修 corner cutting 时很容易只修其中一套。

---

# 第五部分：统一测试入口，先把导航风险锁死

## 10. 不给每个小节创建测试程序

第二课新增一个统一 Native 测试入口：

```text
server/native/grid_map/tests/navigation_test.cpp
```

第一课已有：

```text
grid_map_test.cpp
```

保留它作为第一课回归，不重命名。第二课所有 A*/Agent/Occupancy/Smoothing/Concurrency 都进入 `navigation_test`。

测试地图使用进程内构造的 `GridMap`，这样失败时不会把 BMAP Loader、Unity Exporter 和 A* 混成同一个问题。

### 10.1 测试必须覆盖的风险

```text
[ ] 起点越界
[ ] 终点越界
[ ] 起点不可走
[ ] 终点不可走
[ ] 无路径
[ ] 直线路径
[ ] 同一 Cell 内 A/B 不同仍保留两个精确业务端点
[ ] 绕障碍
[ ] 8-way corner cutting
[ ] clearance 不足
[ ] slope 超限
[ ] area cost 影响路线选择
[ ] dynamic occupancy
[ ] move conflict 不破坏旧 occupancy
[ ] 缓存路径提交移动时重新检查动态 diagonal side cells
[ ] ignore self
[ ] target center 被占用时 FindPathToRange 停在合法攻击位置
[ ] 负世界坐标转换
[ ] smoothing 后每段仍合法
[ ] 同输入/map/version/seed 重复结果一致
[ ] 多 NavigationContext 并发无共享 scratch 污染
```

这里的 deterministic Native test 不需要 RNG；它反复查询同一输入，要求 Path 世界点完全一致。Battle seed 与完整 Event 的重复模拟到第 20 节再验证。

### 10.2 navigation_test 学习导航

本文件解决的问题：用一个可执行程序锁定第二课 Native 导航全部高风险语义。

必须精读：每个 case 为什么存在、它锁定哪类线上 bug。

可以略读：`assert`、synthetic map builder 的机械初始化。

输入、输出和失败：

```text
输入：进程内 synthetic GridMap
输出：assert + 最终 ALL_TESTS_OK
失败：任何断言中止，定位到具体 case
```

运行验证：CTest。

理解自测：如果 `around wall` 通过但 `corner cutting` 没测，仍可能出现什么穿墙？

### 10.3 创建统一测试入口

[新建文件]

```text
server/native/grid_map/tests/navigation_test.cpp
```

下面代码给出完整测试骨架。为了避免测试自己复制生产 `clearance` 算法，synthetic case 直接明确填入每格期望的 `clearance_cells`；这里测试的是“运行时消费 clearance 是否正确”，不是重复测试 Unity 第一课的 Clearance Builder。

```cpp
// 职责：统一验证第二课 Agent/A*/Occupancy/Smoothing/Determinism/Concurrency 风险。
// 边界：Native Test；不启动 Skynet、不读 Unity Scene、不依赖真实 BMAP 文件。
// 输入/输出：内存 synthetic GridMap -> assert 或 ALL_TESTS_OK。
// 生命周期：每个 case 创建独立 map/context；并发 case 共享 const map 但 Context 独立。
// 不负责：不做性能结论，性能由 navigation_benchmark 单独记录条件。
#include "agent_profile.h"
#include "dynamic_occupancy.h"
#include "grid_pathfinder.h"
#include "navigation_context.h"

#include <cassert>
#include <cstdint>
#include <iostream>
#include <memory>
#include <thread>
#include <vector>

using namespace battle_nav;

namespace {

// 创建全可走 synthetic map；origin 是毫米制世界原点，返回 immutable shared owner。
std::shared_ptr<const GridMap> MakeMap(
    std::uint32_t width,
    std::uint32_t height,
    std::int32_t origin_x_mm = 0,
    std::int32_t origin_z_mm = 0) {
    BMapMetadata meta;
    meta.map_id = 9001;
    meta.map_version = 1;
    meta.width = width;
    meta.height = height;
    meta.cell_size_mm = 500;
    meta.origin_x_mm = origin_x_mm;
    meta.origin_z_mm = origin_z_mm;

    std::vector<NavCell> cells(width * height);
    for (NavCell& cell : cells) {
        cell.flags = kWalkableFlag;
        cell.height_mm = 0;
        cell.area_type = 0;
        cell.clearance_cells = 10;
    }
    return std::make_shared<const GridMap>(meta, std::move(cells));
}

// 构造带自定义 Cell 的地图，避免测试通过 const GridMap 后再修改共享资产。
std::shared_ptr<const GridMap> MakeMapFromCells(
    std::uint32_t width,
    std::uint32_t height,
    std::vector<NavCell> cells,
    std::int32_t origin_x_mm = 0,
    std::int32_t origin_z_mm = 0) {
    BMapMetadata meta;
    meta.map_id = 9002;
    meta.map_version = 1;
    meta.width = width;
    meta.height = height;
    meta.cell_size_mm = 500;
    meta.origin_x_mm = origin_x_mm;
    meta.origin_z_mm = origin_z_mm;
    return std::make_shared<const GridMap>(meta, std::move(cells));
}

// 把测试 GridPos 转为 z-major 数组下标；调用者保证 x/z 在范围内。
std::size_t Idx(std::uint32_t width, int x, int z) {
    return static_cast<std::size_t>(z) * width + x;
}

// 返回测试统一的小型地面 Agent；按值返回，不持有地图或共享状态。
AgentProfile Small() {
    AgentProfile p = MakeDefaultAgentProfile(1);
    p.radius_mm = 200;
    p.max_step_mm = 600;
    p.max_slope_permille = 1000;
    return p;
}

// 构造 Y=0 的毫米制测试世界位置；正式地表 Y 由 GridMap 输出。
WorldPosition P(int x_mm, int z_mm) {
    return WorldPosition{x_mm, 0, z_mm};
}

// 断言两个 Path 的所有逻辑字段完全一致；失败终止当前 Test 进程。
void AssertSamePath(const Path& a, const Path& b) {
    assert(a.count() == b.count());
    assert(a.length_mm() == b.length_mm());
    for (std::size_t i = 0; i < a.count(); ++i) {
        const auto& pa = a.WorldPoint(i);
        const auto& pb = b.WorldPoint(i);
        assert(pa.x_mm == pb.x_mm);
        assert(pa.y_mm == pb.y_mm);
        assert(pa.z_mm == pb.z_mm);
    }
}

// 锁定越界、不可走起点和不可走终点的稳定错误码。
void TestBoundsAndBlockedEndpoints() {
    auto map = MakeMap(5, 5);
    NavigationContext ctx(map);
    const AgentProfile p = Small();

    auto r = GridPathfinder::FindPathStatic(ctx, p, P(-1, 250), P(2250, 2250));
    assert(!r.ok() && r.error == NavError::kOutOfBounds);

    r = GridPathfinder::FindPathStatic(ctx, p, P(250, 250), P(2500, 250));
    assert(!r.ok() && r.error == NavError::kOutOfBounds);

    std::vector<NavCell> cells(25);
    for (auto& c : cells) {
        c.flags = kWalkableFlag;
        c.clearance_cells = 10;
    }
    cells[Idx(5, 0, 0)].flags = 0;
    cells[Idx(5, 4, 4)].flags = 0;
    auto blocked = MakeMapFromCells(5, 5, std::move(cells));
    NavigationContext blocked_ctx(blocked);

    r = GridPathfinder::FindPathStatic(blocked_ctx, p, P(250, 250), P(1750, 1750));
    assert(!r.ok() && r.error == NavError::kStartNotNavigable);
    r = GridPathfinder::FindPathStatic(blocked_ctx, p, P(750, 250), P(2250, 2250));
    assert(!r.ok() && r.error == NavError::kEndNotNavigable);
}

// 锁定直线成功、绕墙成功以及最终 Segment 复验。
void TestStraightAndAroundWall() {
    auto map = MakeMap(7, 5);
    NavigationContext ctx(map);
    const AgentProfile p = Small();
    auto straight = GridPathfinder::FindPathStatic(ctx, p, P(250, 1250), P(3250, 1250));
    assert(straight.ok());
    assert(straight.value.count() >= 2);

    std::vector<NavCell> cells(35);
    for (auto& c : cells) {
        c.flags = kWalkableFlag;
        c.clearance_cells = 10;
    }
    for (int z = 0; z < 4; ++z) {
        cells[Idx(7, 3, z)].flags = 0; // 墙在 z=4 留一个口。
    }
    auto wall = MakeMapFromCells(7, 5, std::move(cells));
    NavigationContext wall_ctx(wall);
    auto around = GridPathfinder::FindPathStatic(
        wall_ctx, p, P(250, 250), P(3250, 250));
    assert(around.ok());
    assert(around.value.count() >= 3);
    assert(GridPathfinder::ValidatePathStatic(
        wall_ctx, p, around.value).ok());
}

// A/B 位于同一 Cell 时不需要搜索多个 Node，但正式 Path 仍必须到达精确 B。
void TestSameCellExactEndpoints() {
    auto map = MakeMap(2, 2);
    NavigationContext ctx(map);
    const auto result = GridPathfinder::FindPathStatic(
        ctx, Small(), P(100, 100), P(400, 400));
    assert(result.ok() && result.value.count() == 2);
    assert(result.value.WorldPoint(0).x_mm == 100);
    assert(result.value.WorldPoint(0).z_mm == 100);
    assert(result.value.WorldPoint(1).x_mm == 400);
    assert(result.value.WorldPoint(1).z_mm == 400);
}

// 锁定无路可达与 8-way 禁止切角规则。
void TestNoPathAndCornerCutting() {
    std::vector<NavCell> cells(9);
    for (auto& c : cells) {
        c.flags = kWalkableFlag;
        c.clearance_cells = 10;
    }
    // Start=(0,0)，Goal=(1,1)，两个正交侧格都阻挡；若允许切角会错误成功。
    cells[Idx(3, 1, 0)].flags = 0;
    cells[Idx(3, 0, 1)].flags = 0;
    auto map = MakeMapFromCells(3, 3, std::move(cells));
    NavigationContext ctx(map);
    auto r = GridPathfinder::FindPathStatic(ctx, Small(), P(250, 250), P(750, 750));
    assert(!r.ok() && r.error == NavError::kNoPath);
}

// 锁定 Agent clearance 差异和整数坡度拒绝。
void TestClearanceAndSlope() {
    std::vector<NavCell> cells(15);
    for (auto& c : cells) {
        c.flags = kWalkableFlag;
        c.clearance_cells = 3;
    }
    // 中间列只给 clearance=1；Small 可走，Large 要 2 格，因此 Large 必须失败/绕开。
    for (int z = 0; z < 3; ++z) {
        cells[Idx(5, 2, z)].clearance_cells = 1;
    }
    auto map = MakeMapFromCells(5, 3, cells);
    NavigationContext ctx_small(map);
    auto small = Small();
    assert(GridPathfinder::FindPathStatic(
        ctx_small, small, P(250, 750), P(2250, 750)).ok());

    auto large = Small();
    large.id = 2;
    large.radius_mm = 700; // required_clearance_cells = 2。
    NavigationContext ctx_large(map);
    auto large_path = GridPathfinder::FindPathStatic(
        ctx_large, large, P(250, 750), P(2250, 750));
    assert(!large_path.ok() && large_path.error == NavError::kNoPath);

    // 单独锁定 slope：1 个 500mm Cell 跨 1000mm 高差，max_step 放行但 slope 拒绝。
    cells.assign(3, NavCell{});
    for (auto& c : cells) {
        c.flags = kWalkableFlag;
        c.clearance_cells = 10;
    }
    cells[1].height_mm = 1000;
    auto slope_map = MakeMapFromCells(3, 1, std::move(cells));
    auto slope_agent = Small();
    slope_agent.max_step_mm = 1500;
    slope_agent.max_slope_permille = 500;
    NavigationContext slope_ctx(slope_map);
    auto slope = GridPathfinder::FindPathStatic(
        slope_ctx, slope_agent, P(250, 250), P(1250, 250));
    assert(!slope.ok() && slope.error == NavError::kNoPath);
}

// 锁定 Area Cost 会改变最优路径，且 smoothing 不会切回高成本区域。
void TestAreaCostChangesRoute() {
    const int w = 7;
    const int h = 3;
    std::vector<NavCell> cells(w * h);
    for (auto& c : cells) {
        c.flags = kWalkableFlag;
        c.clearance_cells = 10;
        c.area_type = 0;
    }
    // 中间直线标为 Mud(area=1)，上下两行保持 Normal。
    for (int x = 1; x < 6; ++x) {
        cells[Idx(w, x, 1)].area_type = 1;
    }
    auto map = MakeMapFromCells(w, h, std::move(cells));
    auto p = Small();
    p.area_cost_permille[1] = 5000;
    NavigationContext ctx(map);
    auto r = GridPathfinder::FindPathStatic(ctx, p, P(250, 750), P(3250, 750));
    assert(r.ok());

    bool left_middle_row = false;
    for (std::size_t i = 0; i < r.value.count(); ++i) {
        if (r.value.WorldPoint(i).z_mm != 750) {
            left_middle_row = true;
        }
    }
    assert(left_middle_row);
    assert(GridPathfinder::ValidatePathStatic(ctx, p, r.value).ok());
}

// 锁定 place/move/release、ignore self 和冲突时保留旧占位。
void TestDynamicOccupancyAndAtomicMove() {
    auto map = MakeMap(7, 3);
    NavigationContext ctx(map);
    auto p = Small();

    const GridPos a{2, 1};
    const GridPos b{3, 1};
    const GridPos c{4, 1};
    assert(ctx.occupancy().Place(100, p, a).ok());
    assert(ctx.occupancy().Place(200, p, c).ok());
    assert(ctx.occupancy().IsBlocked(a, 0));
    assert(!ctx.occupancy().IsBlocked(a, 100)); // ignore self。

    // b 可移动；随后 c 被 200 占用，失败后 b 必须仍归 100。
    assert(ctx.occupancy().Move(100, p, a, b).ok());
    auto conflict = ctx.occupancy().Move(100, p, b, c);
    assert(!conflict.ok() && conflict.error == NavError::kDynamicOccupied);
    assert(ctx.occupancy().OwnerAt(b) == 100);
    assert(ctx.occupancy().OwnerAt(c) == 200);

    // 另一个单位从左向右寻路时必须绕开 b/c 的动态 footprint；平滑后再复验。
    auto dynamic_path = GridPathfinder::FindPath(
        ctx, p, P(250, 250), P(3250, 250), 300);
    assert(dynamic_path.ok());
    assert(GridPathfinder::ValidatePath(
        ctx, p, dynamic_path.value, 300).ok());

    assert(ctx.occupancy().Release(100, p, b).ok());
    assert(ctx.occupancy().OwnerAt(b) == 0);
}

// 缓存 Path 生成后，两个对角侧格可能被其他单位占据；提交移动时仍必须拒绝切角。
void TestMoveRevalidatesDynamicCorner() {
    auto map = MakeMap(3, 3);
    NavigationContext ctx(map);
    const auto p = Small();
    assert(ctx.occupancy().Place(10, p, GridPos{0, 0}).ok());
    assert(ctx.occupancy().Place(20, p, GridPos{1, 0}).ok());
    assert(ctx.occupancy().Place(30, p, GridPos{0, 1}).ok());

    const auto moved = GridPathfinder::MoveUnit(
        ctx, p, 10, P(250, 250), P(750, 750));
    assert(!moved.ok() && moved.error == NavError::kMoveBlocked);
    assert(ctx.occupancy().OwnerAt(GridPos{0, 0}) == 10);
    assert(ctx.occupancy().OwnerAt(GridPos{1, 1}) == 0);
}

// 攻击目标中心被目标占用时，搜索必须停在攻击范围内的其他合法 Cell。
void TestFindPathToOccupiedTargetRange() {
    auto map = MakeMap(7, 3);
    NavigationContext ctx(map);
    const auto p = Small();
    const WorldPosition start = P(250, 750);
    const WorldPosition target = P(3250, 750);
    assert(ctx.occupancy().Place(10, p, GridPos{0, 1}).ok());
    assert(ctx.occupancy().Place(20, p, GridPos{6, 1}).ok());

    const auto path = GridPathfinder::FindPathToRange(
        ctx, p, start, target, 1000, 10);
    assert(path.ok() && path.value.count() >= 1);
    const auto& end = path.value.WorldPoint(path.value.count() - 1);
    const std::int64_t dx = static_cast<std::int64_t>(end.x_mm) - target.x_mm;
    const std::int64_t dz = static_cast<std::int64_t>(end.z_mm) - target.z_mm;
    assert(dx * dx + dz * dz <= 1000LL * 1000LL);
    const auto end_grid = map->WorldToGrid(end);
    assert(end_grid.ok());
    assert(ctx.occupancy().OwnerAt(end_grid.value) != 20);
}

// 锁定负世界坐标使用 floor 归格，负数不等于越界。
void TestNegativeWorldCoordinates() {
    auto map = MakeMap(4, 4, -1000, -1000);
    NavigationContext ctx(map);
    auto r = GridPathfinder::FindPathStatic(
        ctx, Small(), P(-750, -750), P(750, 750));
    assert(r.ok());
    assert(r.value.WorldPoint(0).x_mm == -750);
    assert(r.value.WorldPoint(0).z_mm == -750);
}

// 在同一 Context 重复查询，锁定 generation 复用与稳定 tie-break。
void TestDeterministicRepeatedQuery() {
    auto map = MakeMap(20, 20);
    NavigationContext ctx(map);
    auto first = GridPathfinder::FindPathStatic(
        ctx, Small(), P(250, 250), P(9250, 9250));
    assert(first.ok());
    for (int i = 0; i < 100; ++i) {
        auto next = GridPathfinder::FindPathStatic(
            ctx, Small(), P(250, 250), P(9250, 9250));
        assert(next.ok());
        AssertSamePath(first.value, next.value);
    }
}

// 多线程只共享 immutable map，各线程 Context 独占；结果必须与 baseline 一致。
void TestIndependentContextsConcurrent() {
    auto map = MakeMap(64, 64);
    const AgentProfile p = Small();
    const WorldPosition start = P(250, 250);
    const WorldPosition end = P(31750, 31750);

    NavigationContext baseline_ctx(map);
    auto baseline = GridPathfinder::FindPathStatic(baseline_ctx, p, start, end);
    assert(baseline.ok());

    const int thread_count = 8;
    const int iterations = 500;
    std::vector<std::thread> threads;
    // 不使用 vector<bool>：它按 bit 打包，不同线程写“不同元素”仍可能落在同一机器字。
    std::vector<int> ok(thread_count, 1);
    for (int t = 0; t < thread_count; ++t) {
        threads.emplace_back([&, t]() {
            // 关键：每个线程/模拟 owner 都有独立 Context；只共享 const GridMap。
            NavigationContext local(map);
            for (int i = 0; i < iterations; ++i) {
                auto r = GridPathfinder::FindPathStatic(local, p, start, end);
                if (!r.ok()) {
                    ok[t] = 0;
                    return;
                }
                if (r.value.count() != baseline.value.count() ||
                    r.value.length_mm() != baseline.value.length_mm()) {
                    ok[t] = 0;
                    return;
                }
                for (std::size_t point = 0; point < r.value.count(); ++point) {
                    const auto& a = baseline.value.WorldPoint(point);
                    const auto& b = r.value.WorldPoint(point);
                    if (a.x_mm != b.x_mm || a.y_mm != b.y_mm || a.z_mm != b.z_mm) {
                        ok[t] = 0;
                        return;
                    }
                }
            }
        });
    }
    for (auto& thread : threads) thread.join();
    for (int value : ok) assert(value == 1);
}

} // namespace

// 运行全部第二课 Native correctness/stress case；任一 assert 失败返回非零。
int main() {
    TestBoundsAndBlockedEndpoints();
    TestStraightAndAroundWall();
    TestSameCellExactEndpoints();
    TestNoPathAndCornerCutting();
    TestClearanceAndSlope();
    TestAreaCostChangesRoute();
    TestDynamicOccupancyAndAtomicMove();
    TestMoveRevalidatesDynamicCorner();
    TestFindPathToOccupiedTargetRange();
    TestNegativeWorldCoordinates();
    TestDeterministicRepeatedQuery();
    TestIndependentContextsConcurrent();

    std::cout << "ALL_TESTS_OK\n";
    return 0;
}
```

### 10.4 smoothing 测试不能只看 Path 点数

使用上一步已经加入的 `GridPathfinder::ValidatePathStatic/ValidatePath` 重新验证最终结果。至少断言：

```text
1. 原始路径可达；
2. smoothing 后 count <= raw count；
3. 每一段 supercover 仍通过：
   walkable / clearance / slope / area / corner / occupancy；
4. Mud detour case 不会被 smoothing 直接切回高成本区域；
5. 动态阻挡存在时 shortcut 不穿过被占 Cell。
```

不要写成：

```cpp
assert(smoothed.count() < raw.count());
```

因为“点变少”本身不是正确性。

### 10.5 修改 CMake

[局部修改]

```text
server/native/grid_map/CMakeLists.txt
```

这个 Build 文件现在同时构建第二课导航核心、正确性测试和 Benchmark，先把文件头更新为：

```cmake
# 职责：构建 immutable GridMap、Battle-local Grid 导航核心、Native 测试和 Benchmark。
# 边界：Server Native Build；不下载依赖，不构建 Skynet 本体。
# 输入/输出：本目录 C++ 源码 -> 静态库、测试可执行文件和独立性能程序。
# 运行时机：第一/二课 Native 代码变化后，由 make_test.sh 或显式 CMake 命令驱动。
# 不负责：不加载 Unity Scene，不启动 BattleWorker，不生成 BMAP。
```

`grid_map_core` 增加：

```cmake
    src/navigation_context.cpp
    src/dynamic_occupancy.cpp
    src/grid_pathfinder.cpp
```

在第一课 `grid_map_test` 后增加：

```cmake
add_executable(navigation_test tests/navigation_test.cpp)
target_link_libraries(navigation_test PRIVATE grid_map_core pthread)
target_compile_options(navigation_test PRIVATE -Wall -Wextra -Wpedantic)
add_test(NAME navigation_test COMMAND navigation_test)
```

`make_test.sh` 会开始运行第二课测试，因此也要同步它的文件头；脚本命令本身不需要复制一套：

[局部修改]

```text
server/native/grid_map/make_test.sh
```

```bash
# 职责：配置、编译并运行 GridMap 与 Grid Navigation 的 Native 回归测试。
# 边界：Server Native Build/Test；不下载依赖，不构建 Skynet 或 Lua Binding。
# 输入/输出：native/grid_map 源码 -> build/grid_map 构建产物和 CTest 结果。
# 运行时机：修改 BMAP、坐标、A*、占位或 NavigationContext 后执行。
# 不负责：不生成 BMAP，不启动 Skynet，不修改源码或测试数据。
```

运行：

```bash
cd "$(git rev-parse --show-toplevel)/server"
./native/grid_map/make_test.sh
```

`make_test.sh` 使用 CTest，所以新增 target 后无需再创建第二套测试脚本。

预期：

```text
grid_map_test     Passed
navigation_test   Passed
100% tests passed
```

CTest 默认隐藏成功用例的 stdout。需要亲眼看到 `ALL_TESTS_OK` 时，执行 `ctest --test-dir build/grid_map -V -R navigation_test`，或直接运行构建目录中的 `navigation_test`；不要把“默认输出没显示 marker”误判为测试没执行。

---

## 11. Concurrency Stress 的正确测试模型

错误测试：

```text
8 个 thread
-> 共用同一个 NavigationContext
```

这只能证明“你故意违反 ownership 后会不会撞得明显”。

本课要验证的正确模型是：

```text
                  shared_ptr<const GridMap>
                    /      |       \
                   /       |        \
          Context A   Context B   Context C
          scratch A   scratch B   scratch C
          occupancy A occupancy B occupancy C
```

多个 OS Thread 可以同时进入 `grid_map_core`，但它们的 mutable query state 完全不同。

如果环境支持，再额外跑：

```bash
cmake -S native/grid_map -B build/grid_map-tsan \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_CXX_FLAGS="-fsanitize=thread -fno-omit-frame-pointer" \
  -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=thread"
cmake --build build/grid_map-tsan -j"$(nproc)"
ctest --test-dir build/grid_map-tsan --output-on-failure
```

TSAN 是额外证据，不替代 ownership 设计。某些 WSL/工具链组合不支持 TSAN 时，记录环境限制，不把“没有跑 TSAN”包装成“已经证明无竞争”。

---

## 12. Benchmark：性能数字必须带条件

现在功能正确，才测性能。

统一 Benchmark。这个文件马上用于本节三组地图测试，并由 CMake 的 `navigation_benchmark` target 直接运行。

[新建文件]

```text
server/native/grid_map/benchmark/navigation_benchmark.cpp
```

```cpp
// 职责：在固定 synthetic Grid/query set 下记录 Grid A* 延迟、QPS、访问节点和 Context 内存条件。
// 边界：Standalone Benchmark；不启动 Skynet/Unity，不作为 correctness test。
// 输入/输出：固定地图尺寸/blocked ratio/query count -> 条件化性能统计。
// 生命周期：每组 case 创建一个 immutable map 和一个独立 NavigationContext。
// 不负责：不宣称跨机器性能，不把 Benchmark 数字写成产品 SLA。
#include "grid_pathfinder.h"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <iostream>
#include <memory>
#include <numeric>
#include <vector>

using namespace battle_nav;

namespace {

// 推进固定 LCG；state 由当前 Benchmark case 独占，返回下一 uint32 样本。
std::uint32_t Next(std::uint32_t& state) {
    state = state * 1664525u + 1013904223u;
    return state;
}

// 创建给定尺寸和阻挡率的可复现 synthetic map；不模拟真实 Clearance 分布。
std::shared_ptr<const GridMap> MakeSynthetic(
    std::uint32_t width,
    std::uint32_t height,
    std::uint32_t blocked_percent,
    std::uint32_t seed) {
    BMapMetadata meta;
    meta.map_id = width * 10000 + height;
    meta.map_version = 1;
    meta.width = width;
    meta.height = height;
    meta.cell_size_mm = 500;

    std::vector<NavCell> cells(static_cast<std::size_t>(width) * height);
    for (std::uint32_t z = 0; z < height; ++z) {
        for (std::uint32_t x = 0; x < width; ++x) {
            NavCell& cell = cells[static_cast<std::size_t>(z) * width + x];
            const bool border = x == 0 || z == 0 || x + 1 == width || z + 1 == height;
            const bool blocked = !border && (Next(seed) % 100u) < blocked_percent;
            cell.flags = blocked ? 0 : kWalkableFlag;
            cell.clearance_cells = blocked ? 0 : 10;
            cell.area_type = 0;
            cell.height_mm = 0;
        }
    }
    return std::make_shared<const GridMap>(meta, std::move(cells));
}

// 从 map 中确定性抽取一个可走 Cell Center；map 至少有一格可走是前置条件。
WorldPosition RandomWalkable(
    const GridMap& map,
    std::uint32_t& seed) {
    for (;;) {
        const GridPos grid{
            static_cast<std::int32_t>(Next(seed) % map.metadata().width),
            static_cast<std::int32_t>(Next(seed) % map.metadata().height),
        };
        const NavCell* cell = map.TryCell(grid);
        if (cell != nullptr && cell->IsWalkable()) {
            const auto world = map.GridToWorldCenter(grid);
            if (world.ok()) return world.value;
        }
    }
}

// 对耗时副本排序并返回 [0,1] 分位点；values 必须非空。
double Percentile(std::vector<double> values, double p) {
    std::sort(values.begin(), values.end());
    const std::size_t index = static_cast<std::size_t>(
        (values.size() - 1) * p);
    return values[index];
}

// 单线程执行一组固定 query set，并输出带完整条件的延迟/访问量统计。
void RunCase(std::uint32_t width, std::uint32_t height) {
    constexpr std::uint32_t kBlockedPercent = 15;
    constexpr int kQueries = 2000;
    auto map = MakeSynthetic(width, height, kBlockedPercent, 0x12345678u);
    NavigationContext context(map);
    AgentProfile profile = MakeDefaultAgentProfile(1);
    profile.radius_mm = 200;
    profile.max_step_mm = 500;
    profile.max_slope_permille = 1000;

    std::uint32_t seed = 0xabcdef01u;
    std::vector<double> microseconds;
    microseconds.reserve(kQueries);
    std::uint64_t visited_sum = 0;
    int success = 0;
    int no_path = 0;

    const auto all_begin = std::chrono::steady_clock::now();
    for (int i = 0; i < kQueries; ++i) {
        const WorldPosition start = RandomWalkable(*map, seed);
        const WorldPosition end = RandomWalkable(*map, seed);
        const auto begin = std::chrono::steady_clock::now();
        const auto result = GridPathfinder::FindPathStatic(
            context, profile, start, end);
        const auto finish = std::chrono::steady_clock::now();
        microseconds.push_back(std::chrono::duration<double, std::micro>(
            finish - begin).count());
        visited_sum += context.visited_nodes();
        if (result.ok()) ++success;
        else if (result.error == NavError::kNoPath) ++no_path;
    }
    const auto all_end = std::chrono::steady_clock::now();
    const double seconds = std::chrono::duration<double>(all_end - all_begin).count();

    const std::size_t cells = map->cell_count();
    const std::size_t context_bytes_est =
        cells * (sizeof(NavigationContext::NodeScratch) +
                 sizeof(std::int32_t) +
                 sizeof(std::uint32_t));

    std::cout
        << "BENCH width=" << width
        << " height=" << height
        << " blocked_percent=" << kBlockedPercent
        << " queries=" << kQueries
        << " threads=1"
        << " success=" << success
        << " no_path=" << no_path
        << " p50_us=" << Percentile(microseconds, 0.50)
        << " p95_us=" << Percentile(microseconds, 0.95)
        << " p99_us=" << Percentile(microseconds, 0.99)
        << " qps=" << (kQueries / seconds)
        << " avg_visited=" << (visited_sum / static_cast<double>(kQueries))
        << " context_bytes_est=" << context_bytes_est
        << "\n";
}

} // namespace

// 依次运行三种地图尺寸；成功返回 0，不把结果解释成产品 SLA。
int main() {
    RunCase(80, 60);
    RunCase(256, 256);
    RunCase(512, 512);
    return 0;
}
```

在 `server/native/grid_map/CMakeLists.txt` 增加：

```cmake
add_executable(navigation_benchmark benchmark/navigation_benchmark.cpp)
target_link_libraries(navigation_benchmark PRIVATE grid_map_core pthread)
target_compile_options(navigation_benchmark PRIVATE -Wall -Wextra -Wpedantic)
```

运行前记录环境：

```bash
lscpu | sed -n '1,20p'
g++ --version
cmake -S native/grid_map -B build/grid-map-release -DCMAKE_BUILD_TYPE=Release
cmake --build build/grid-map-release -j"$(nproc)"
./build/grid-map-release/navigation_benchmark
```

只需要一个程序，覆盖：

```text
80x60
256x256
512x512 synthetic
```

每组记录：

```text
CPU
compiler + version
build type / -O
map width/height
blocked ratio
query count
thread count
p50/p95/p99
qps
visited nodes
context bytes
final Path allocation bytes/points（可近似）
```

### 12.1 Benchmark 不能证明什么

如果测试得到：

```text
80x60 p99 = 0.08ms
```

只能说明：

> 在这台 CPU、这个编译器、这个 Build、这组地图和 query set 下，观测到该结果。

不能写：

```text
“A* p99 就是 0.08ms”
“商业服一定扛得住”
```

真实 Battle 还包含 AI、动态占位、Lua/C 边界、事件生成和大量同时 Battle。

### 12.2 Benchmark 特别关注 Context 内存

程序至少打印：

```cpp
sizeof(NavigationContext::NodeScratch)
map->cell_count()
node_scratch_bytes
heap_bytes
occupancy_bytes
```

如果 512x512 的每 Battle Context 内存不可接受，这就是需要下一轮设计的证据。可选方向包括：

```text
Worker-local scratch pool
Context 按地图尺寸复用
Battle 分区/局部导航窗
稀疏 scratch
降低 cell density
```

本课不在没有数据的情况下提前实现这些优化。


# 第六部分：只有真实调用者出现以后，才扩展 Lua C Binding

## 13. Lua 业务仍然只看 WorldPosition

Native 导航已经有了：

```text
AgentProfile
Path
NavigationContext
Grid A*
DynamicOccupancy
FindPathToRange
```

现在 BattleWorker 才真正需要跨 Lua/C 边界。

正式 Lua 调用面保持：

```lua
local context, err = battle_nav.new_context(
    map_id,
    map_version,
    profiles)

local path, err = context:find_path(
    profile_id,
    start_world,
    end_world,
    self_unit_id)

local path, err = context:find_path_to_range(
    profile_id,
    start_world,
    target_world,
    attack_range_mm,
    self_unit_id)
```

`GridPos` 只允许出现在 Native Debug 日志和测试，不进入 `battle_core.lua`。

### 13.1 为什么 Context 和 Path 使用 userdata

如果每次 FindPath 都把结果拆成几十个 Lua table：

```text
C++ Path
-> N 个 Lua table
-> N*3 个 integer field
-> GC 压力
```

本课先让 `Path` 作为 Native userdata 持有连续 `std::vector<WorldPosition>`：

```lua
path:count()
path:world_point(i)
path:length_mm()
```

Battle 在“生成/重生成路径”时一次性把必要点复制到自己的 Lua movement state；不会每 Tick 反复创建 Path userdata。

`NavigationContext` 也使用 userdata，因为它真实拥有：

```text
A* scratch
binary heap
DynamicOccupancy
shared_ptr<const GridMap>
```

它不能被序列化跨 Skynet Service 发送。

### 13.2 一个很重要的 Skynet 所有权限制

```text
BattleMgr Lua State
   context userdata   X 不应该存在这里再发给 Worker

skynet.call
   只能发送可序列化 snapshot/value

BattleWorker Lua State
   在本 Service 内创建 NavigationContext userdata
   在本 Service 内使用和销毁
```

每个 Skynet Service 有自己的 Lua State。不要把某个 State 创建的 userdata 指针塞到另一个 Service。

### 13.3 Context 中怎样保存 AgentProfile

本课不增加进程级可变 `AgentProfileRegistry`。一场 Battle 在创建 Context 时传入自己冻结的 profile definitions：

```lua
profiles = {
    {
        id = 1,
        radius_mm = 200,
        max_step_mm = 600,
        max_slope_permille = 1000,
        area_cost_permille = {
            [0] = 1000,
            [1] = 3000,
            [2] = 1000,
            [3] = 1500,
        },
    },
}
```

Binding 把它复制成 `std::vector<AgentProfile>` 存在 Context userdata 旁边。Profile 数量通常远小于单位数；按 `profile_id` 做线性查找简单、稳定，也不依赖 unordered_map iteration。

如果正式项目 Profile 来自全局版本化配置系统，可以在接入时把“配置快照 -> Context profiles”替换为已有配置读取；不要为了本课另造一整套配置中心。

### 13.4 Binding 修改学习导航

本次修改解决的问题：让每个 BattleWorker Lua State 能创建自己的 Context、调用 Pathfinding 和维护动态占位。

必须精读：

```text
LuaNavigationContext userdata ownership
LuaPath userdata ownership
__gc / close
profile 解析与校验
WorldPosition int32 range check
nil,error 返回合同
```

可以略读：Lua metatable 样板、`luaL_Reg` 数组语法。

输入、输出和失败：

```text
输入：map/version/profiles/WorldPosition/unit_id
输出：context/path userdata；place_unit 成功返回归一地表 Y 后的 WorldPosition；失败统一返回 nil,{code,message}
失败：map 不存在、profile 不存在、坐标越界、NO_PATH、CONTEXT_CLOSED、occupancy conflict
```

内存：

```text
new_context   O(cell_count) Context + Occupancy 分配
find_path     A* scratch 复用；最终 Path vector + userdata 分配
world_point   创建一个很小 Lua table
```

锁/yield：Binding 内不调用 `skynet.call`、不 yield。`MapRegistry::Find` 仍是第一课的短锁查找；拿到 `shared_ptr<const GridMap>` 后 A* 不持有 Registry lock。

C++ exception 边界：`NavigationContext` 构造、Path 分配等 Native 代码如果抛出 `std::exception`，Binding 必须在 C++ 内捕获并转换为 `INTERNAL_ERROR`；异常不能穿过 `lua_CFunction` ABI。

运行验证：第 14 节先用单 Worker smoke，再进入 Battle。

理解自测：为什么 `Path userdata` 可以在同一 Worker 的多个 Lua 函数间传递，但不应该通过 `skynet.call` 发给另一个 Service？

### 13.5 扩展现有 `lua_battle_nav.cpp`

这是第一课已有文件，所以只做局部修改，不整份重建。

[局部修改]

```text
server/native/lua_battle_nav/src/lua_battle_nav.cpp
```

它现在不只做静态 Cell 查询。先把文件头完整替换为当前真实职责：

```cpp
// 职责：在 Lua 与 Native Grid 导航之间转换参数、错误、Context 和 Path ownership。
// 边界：Server Runtime Binding；调用 MapRegistry/GridMap/GridPathfinder，不包含 Battle AI。
// 输入/输出：Lua map/profile/WorldPosition/unit -> userdata、WorldPosition 或 nil + error table。
// 生命周期：模块 table 属于当前 Lua State；Context/Path userdata 由该 State 的 GC 管理。
// 锁/yield：Registry 查找只持短锁；Native 查询同步执行，不 yield。
// 不负责：不执行 skynet.call，不保存 HP/技能，不允许 userdata 跨 Lua State 传递。
```

在现有 include 区增加：

```cpp
#include "agent_profile.h"
#include "grid_pathfinder.h"
#include "navigation_context.h"
#include "navigation_path.h"

#include <exception>
#include <memory>
#include <new>
#include <utility>
#include <vector>
```

在匿名 namespace 内增加两个 userdata owner：

```cpp
constexpr const char* kContextMeta = "battle_nav.NavigationContext";
constexpr const char* kPathMeta = "battle_nav.Path";

struct LuaNavigationContext {
    std::unique_ptr<battle_nav::NavigationContext> context; // 当前 Lua State 独占。
    std::vector<battle_nav::AgentProfile> profiles;         // 创建后冻结，只读查找。
    bool closed = false;                                    // close/__gc 后拒绝调用。
};

struct LuaPath {
    battle_nav::Path path; // userdata 独占 immutable Path 结果。
};
```

增加通用 helper：

```cpp
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

// 从 Lua table 读取 int32 毫米 WorldPosition；字段缺失或越界 luaL_error。
battle_nav::WorldPosition world_position(lua_State* L, int index) {
    luaL_checktype(L, index, LUA_TTABLE);
    battle_nav::WorldPosition p;
    p.x_mm = int32_field(L, index, "x_mm");
    p.y_mm = int32_field(L, index, "y_mm");
    p.z_mm = int32_field(L, index, "z_mm");
    return p;
}

// 读取 uint32 业务 ID；allow_zero 只用于 find_path 的“没有 self owner”调试调用。
// 越界通过 luaL_error 终止当前 Lua 调用，不允许负数静默转换成巨大 ID。
std::uint32_t uint32_arg(
    lua_State* L,
    int index,
    const char* name,
    bool allow_zero = false) {
    const lua_Integer raw = luaL_checkinteger(L, index);
    const lua_Integer minimum = allow_zero ? 0 : 1;
    if (raw < minimum ||
        static_cast<std::uint64_t>(raw) >
            std::numeric_limits<std::uint32_t>::max()) {
        luaL_error(L, "%s outside uint32 business range", name);
    }
    return static_cast<std::uint32_t>(raw);
}

// 把一个毫米 WorldPosition 复制为新 Lua table；栈净增加 1。
void push_world_position(lua_State* L, const battle_nav::WorldPosition& p) {
    lua_newtable(L);
    lua_pushinteger(L, p.x_mm); lua_setfield(L, -2, "x_mm");
    lua_pushinteger(L, p.y_mm); lua_setfield(L, -2, "y_mm");
    lua_pushinteger(L, p.z_mm); lua_setfield(L, -2, "z_mm");
}

// 压入 nil,{code,message} 并返回 Lua 结果数量 2。
int push_nav_failure(
    lua_State* L,
    battle_nav::NavError error,
    const std::string& detail) {
    push_error(L, battle_nav::NavErrorName(error), detail);
    return 2;
}

// 把 Path move 进新 userdata 并挂 metatable；栈净增加 1。
void push_path(lua_State* L, battle_nav::Path path) {
    void* storage = lua_newuserdatauv(L, sizeof(LuaPath), 0);
    new (storage) LuaPath{std::move(path)};
    luaL_getmetatable(L, kPathMeta);
    lua_setmetatable(L, -2);
}
```

> 当前 Skynet v1.8.0 内置 PUC Lua 5.4.7，所以这里使用 `lua_newuserdatauv`。不要换成 Lua 5.1/5.2 的 userdata API 再假装 ABI 一致。

增加 Profile 解析函数。它在 `new_context` 时执行，不在每次 A* 热路径解析 Lua table：

```cpp
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

    const auto valid = battle_nav::ValidateAgentProfile(profile);
    if (!valid.ok()) {
        luaL_error(L, "%s: %s",
            battle_nav::NavErrorName(valid.error), valid.detail.c_str());
    }
    return profile;
}
```

创建 Context：

```cpp
// Lua battle_nav.new_context(map_id, map_version, profiles_array)
// 成功返回 context userdata；地图查找只持有第一课 Registry 短锁，不 yield。
int l_new_context(lua_State* L) {
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
        owner->closed = false;
    } catch (const std::exception& exception) {
        // C++ exception 不能穿越 Lua C ABI；userdata 保持有效并由 __gc 析构。
        return push_nav_failure(
            L, battle_nav::NavError::kInternalError, exception.what());
    }
    return 1;
}
```

Context Path API：

```cpp
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
    const auto self_id = lua_isnoneornil(L, 5)
        ? 0
        : uint32_arg(L, 5, "self_unit_id", true);

    try {
        auto result = battle_nav::GridPathfinder::FindPath(
            *owner->context, *profile, start, end, self_id);
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
        auto result = battle_nav::GridPathfinder::FindPathToRange(
            *owner->context,
            *profile,
            start,
            target,
            static_cast<std::uint32_t>(raw_range),
            self_id);
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
```

Occupancy API：

```cpp
// Lua context:place_unit：验证静态规则并预留 footprint；成功返回归一地表 Y 的 WorldPosition。
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
        // Battle 初始放置不能只检查“动态格为空”；start==end 的静态 FindPath
        // 会复用 walkable/clearance/area 等正式通行规则。该分配只发生在 prepare 阶段。
        const auto static_check = battle_nav::GridPathfinder::FindPathStatic(
            *owner->context, *profile, world, world);
        if (!static_check.ok()) {
            return push_nav_failure(L, static_check.error, static_check.detail);
        }

        const auto placed = owner->context->occupancy().Place(
            unit_id, *profile, grid.value);
        if (!placed.ok()) {
            return push_nav_failure(L, placed.error, placed.detail);
        }

        // Battle 正式位置保留输入 XZ，但 Y 必须归一到 Server Grid 的权威地表高度。
        auto normalized = owner->context->map()->GridToWorldCenter(grid.value);
        if (!normalized.ok()) {
            owner->context->occupancy().Release(unit_id, *profile, grid.value);
            return push_nav_failure(L, normalized.error, normalized.detail);
        }
        normalized.value.x_mm = world.x_mm;
        normalized.value.z_mm = world.z_mm;
        push_world_position(L, normalized.value);
        return 1;
    } catch (const std::exception& exception) {
        return push_nav_failure(
            L, battle_nav::NavError::kInternalError, exception.what());
    }
}

// Lua context:move_unit：复验缓存路径当前跨格并原子提交占位；成功返回 true。
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
        const auto moved = battle_nav::GridPathfinder::MoveUnit(
            *owner->context, *profile, unit_id, from_world, to_world);
        if (!moved.ok()) return push_nav_failure(L, moved.error, moved.detail);
        lua_pushboolean(L, 1);
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

// Lua context:release_unit：释放该 owner 在给定中心的 footprint；成功返回 true。
int l_context_release_unit(lua_State* L) {
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
        const auto released = owner->context->occupancy().Release(
            unit_id, *profile, grid.value);
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
```

Path API：

```cpp
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
```

注册 metatable：

```cpp
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
        lua_pushcfunction(L, l_context_cell_size_mm);
        lua_setfield(L, -2, "cell_size_mm");
        lua_pushcfunction(L, l_context_close);
        lua_setfield(L, -2, "close");
        lua_setfield(L, -2, "__index");
    }
    lua_pop(L, 1);
}
```

最后修改现有 `luaopen_battle_nav()`：先注册两个 metatable，再把 `new_context` 放进模块 table。

修改前核心结构：

```cpp
extern "C" int luaopen_battle_nav(lua_State* L) {
    luaL_checkversion(L);
    lua_newtable(L);
    ...
}
```

修改后：

```cpp
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
```

### 13.6 每个需要导航的 Service 显式加载 Native 模块

第一课已经把 Binding 收敛为标准 Lua C Module：`battle_nav.so` 导出 `luaopen_battle_nav`。因此 BattleWorker 的 Service 入口或其私有业务模块直接写：

```lua
local battle_nav = require "battle_nav"
assert(type(battle_nav.new_context) == "function")
```

`require` 只在当前 Service 的 Lua State 中创建并缓存模块 table；C++ `MapRegistry::Instance()` 仍由同一进程的 Native Module 共享。每场战斗的 `NavigationContext` 由当前 BattleWorker 创建并独占，不能放进第一课 Query Service 再通过高频 `skynet.call` 代理。

第二课继续遵守目录身份：真正通过 `newservice()` 启动的 BattleWorker 入口放在 `service/`；被它 `require` 的战斗、AI 和导航协调模块放在 `lualib/`。

---

## 14. 先做 Lua/Native smoke，不急着上 Battle

在进入 AI 前，先证明一个 Worker State 能：

```text
new_context
-> place unit
-> find_path
-> path:world_point
-> move/release occupancy
```

示例调用：

```lua
local profiles = {
    {
        id = 1,
        radius_mm = 200,
        max_step_mm = 600,
        max_slope_permille = 1000,
        area_cost_permille = {
            [0] = 1000,
            [1] = 3000,
            [2] = 1000,
            [3] = 1500,
        },
    },
}

local context, err = battle_nav.new_context(1001, 1, profiles)
assert(context, err and (err.code .. ": " .. err.message))

local start = { x_mm = -11000, y_mm = 0, z_mm = 4000 }
local target = { x_mm = 11000, y_mm = 0, z_mm = -4000 }

start = assert(context:place_unit(1, 1001, start))
target = assert(context:place_unit(1, 2001, target))

local path, path_err = context:find_path_to_range(
    1,
    start,
    target,
    900,
    1001)
assert(path, path_err and (path_err.code .. ": " .. path_err.message))

print("PATH_OK count=", path:count(), " length_mm=", path:length_mm())
for i = 1, path:count() do
    local p = path:world_point(i)
    print(i, p.x_mm, p.y_mm, p.z_mm)
end

context:close()
```

这里使用的两个世界位置直接来自仓库 `Battle1001SceneBuilder.cs`：

```text
Team1_Spawn_01 = (-11m, 0.05m,  4m)
Team2_Spawn_01 = ( 11m, 0.05m, -4m)
```

正式毫米位置的 Y 最终应使用 Server Grid 对应高度，不依赖 Unity Marker 的 `0.05m` 显示偏移。

如果这里失败，先停在 Binding/Native 层。不要用 Battle AI 的更多状态掩盖基础接线问题。

---

# 第七部分：BattleWorker 出现后，才讨论 no-yield 核心

## 15. BattleWorker 的真实边界

本课最重要的 Skynet 结构不是“用了多少 Service”，而是 yield 边界：

```text
BattleMgr
  prepare snapshot
  -> skynet.call(worker, "simulate", snapshot)
     ^ 允许 yield

BattleWorker dispatch
  -> 创建/准备本地 NavigationContext
  -> battle_core.simulate(snapshot, context)
     ^ 从这里开始 no-yield
  -> return events
```

核心 `simulate()` 期间禁止：

```text
skynet.call
skynet.sleep
socket read/write
DB query
HTTP/RPC
等待墙钟时间
```

可以做：

```text
Lua table/array 访问
确定性整数计算
同步 Native C 调用
A*
DynamicOccupancy
事件 append
```

### 15.1 为什么 no-yield 不是“Skynet 不能 yield”

`BattleMgr` 调 Worker 本来就会 yield。第一课的 Navigation Gateway 现在由 `socketdriver + netpack` 直接接收 `PTYPE_SOCKET` 事件，在完整请求进入 `skynet.call(Query Service)` 时同样允许 yield；这类接入层并发不会改变 Battle 核心的 no-yield 规则。

约束只针对**已经开始推进某段 Battle 状态的核心临界区**：

```text
read battle state
-> AI
-> move
-> damage
-> emit ordered events
-> complete segment
```

如果中间 `skynet.call(DB)`：

```text
Unit A 已移动
-> yield
-> 其他消息进入同一 Service
-> 读到半更新 Battle
```

就必须引入复杂的状态锁/事务/版本检查。本课选择更简单的 owner model：核心推进期间不 yield。

### 15.2 在线模式与自动战斗怎样共用同一核心

第二课先真正运行自动模式：

```text
simulate(snapshot)
-> CPU 快速推进到结束
-> 完整 Event Log
```

核心从现在开始就把状态生命周期和驱动方式分开：

```lua
battle_core.create(snapshot, context)
battle_core.step(state, context)
battle_core.is_finished(state)
battle_core.finish(state)
```

因此第三课在线模式只增加外层驱动：

```text
收到 PlayerCommand
-> validate
-> 连续 step 若干 fixed tick
-> 输出 Event + 周期 Snapshot
-> 返回等待下一批命令
```

自动模式的 `simulate()` 只是连续调用同一组 `create/step/is_finished/finish`。第三课的在线驱动持有同一种 state，分段调用 `step()`，不会复制第二套 AI、导航、移动或攻击结算。

---

## 16. Battle 输入：Snapshot 只保存确定性需要的事实

本课自动战斗最小输入：

```lua
{
    battle_id = 70001,
    battle_version = 1,
    map_id = 1001,
    map_version = 1,
    seed = 123456,
    tick_ms = 50,
    max_logic_ms = 30000,

    profiles = {...},
    units = {...},
}
```

单位：

```lua
{
    id = 1001,
    camp = 1,
    agent_profile_id = 1,
    position = {x_mm=..., y_mm=..., z_mm=...},
    move_speed_mm_per_sec = 2500,
    attack_range_mm = 900,
    attack_damage = 10,
    attack_cooldown_ms = 1000,
    hp = 100,
}
```

`attack_damage/cooldown` 是最小普攻参数，不是第三课 Skill System。没有 SkillDefinition、Projectile、Cast Command。

### 16.1 确定性规则现在就固定

```text
Unit iteration：按 unit.id 升序
Target tie：距离平方更小优先；相同则 target.id 更小
A* tie：f -> h -> node_index
Tick：固定 tick_ms
位置/HP/时间：整数
随机：本课 AI 不依赖随机；seed 仍写入输入和输出身份
Event：append 顺序就是权威逻辑顺序
```

相同：

```text
battle_version
map_id
map_version
snapshot/input
seed
```

必须得到相同逻辑 Event。

---

## 17. `battle_core.lua`：纯模拟核心不 require skynet

### 17.1 本文件解决的问题

它拥有一场自动战斗的**可变业务状态**：Unit HP、目标、当前 Path、攻击 CD、logic time。

它不拥有：

```text
Skynet Service address
Socket
DB connection
MapRegistry
Unity object
```

谁马上使用：`battle_worker.lua`。

完成后能观察：给定 snapshot + context，直接得到有序 Event Log。

### 17.2 学习导航

必须掌握：

```text
state ownership
fixed tick
目标选择稳定顺序
Path cache
repath trigger
整数移动预算
Occupancy commit
attack/death event order
```

必须精读：`choose_target()`、`ensure_attack_path()`、`advance_move()`、`step()`、`simulate()`。

可以略读：复制 table 的样板。

输入、输出和失败：

```text
输入：已经完成版本校验的 snapshot + battle-local context
输出：{result, end_logic_ms, events}
失败：非法 snapshot 直接 error，由 Worker 在边界收敛；NO_PATH 作为 AI 状态处理，不崩进程
```

内存/yield：Event Log 和单位状态会按 Battle 大小分配 Lua 内存；核心不 yield。

理解自测：为什么 Path 失效只设置 `need_repath=true`，而不是每 Tick 都直接 A*？

### 17.3 创建 `battle_core.lua`

[新建文件]

```text
server/lualib/battle/battle_core.lua
```

```lua
-- 职责：执行一场地面自动战斗的确定性 fixed-tick 核心模拟。
-- 边界：Server Battle Core；不 require skynet，不访问网络/DB/墙钟时间。
-- 输入/输出：已验证 snapshot + battle-local NavigationContext -> ordered BattleEvent log。
-- 生命周期：state 只属于一次 simulate；Context 由 BattleWorker 创建并独占。
-- yield：核心函数禁止任何外部 yield；Native 导航调用为同步本地调用。
-- 不负责：不处理在线输入、额外战斗子系统或在线状态同步。
local M = {}

-- 验证一个 Lua integer 的业务范围；失败立即终止本次 simulate，由 Worker 收敛错误。
local function integer_between(value, name, minimum, maximum)
    if math.type(value) ~= "integer" or value < minimum or value > maximum then
        error(string.format("%s must be integer in [%d,%d]", name, minimum, maximum))
    end
    return value
end

-- 验证 Battle 使用的 WorldPosition。坐标限制在正负 10^9mm，保证二维距离平方不溢出 int64。
local function checked_position(value, name)
    assert(type(value) == "table", name .. " must be table")
    return {
        x_mm = integer_between(value.x_mm, name .. ".x_mm", -1000000000, 1000000000),
        y_mm = integer_between(value.y_mm, name .. ".y_mm", -1000000000, 1000000000),
        z_mm = integer_between(value.z_mm, name .. ".z_mm", -1000000000, 1000000000),
    }
end

-- 整数平方距离；WorldPosition 全部使用毫米。
local function distance2(a, b)
    local dx = a.x_mm - b.x_mm
    local dz = a.z_mm - b.z_mm
    return dx * dx + dz * dz
end

-- 深度只复制一层 WorldPosition，避免事件与后续可变 unit.position 共用同一 table。
local function copy_position(p)
    return { x_mm = p.x_mm, y_mm = p.y_mm, z_mm = p.z_mm }
end

-- 按 unit.id 排序得到稳定迭代顺序；返回新数组，不修改输入 snapshot.units。
local function sorted_units(snapshot)
    local units = {}
    for i, source in ipairs(snapshot.units) do
        local prefix = string.format("units[%d]", i)
        units[i] = {
            id = integer_between(source.id, prefix .. ".id", 1, 0x7fffffff),
            camp = integer_between(source.camp, prefix .. ".camp", 1, 0x7fffffff),
            agent_profile_id = integer_between(
                source.agent_profile_id, prefix .. ".agent_profile_id", 1, 0x7fffffff),
            position = checked_position(source.position, prefix .. ".position"),
            move_speed_mm_per_sec = integer_between(
                source.move_speed_mm_per_sec,
                prefix .. ".move_speed_mm_per_sec", 1, 1000000),
            attack_range_mm = integer_between(
                source.attack_range_mm, prefix .. ".attack_range_mm", 0, 1000000000),
            attack_damage = integer_between(
                source.attack_damage, prefix .. ".attack_damage", 1, 0x7fffffff),
            attack_cooldown_ms = integer_between(
                source.attack_cooldown_ms,
                prefix .. ".attack_cooldown_ms", 1, 0x7fffffff),
            hp = integer_between(source.hp, prefix .. ".hp", 1, 0x7fffffff),
            max_hp = source.hp,
            target_id = nil,
            next_attack_ms = 0,
            path = nil,
            path_index = 0,
            need_repath = true,
            repath_not_before_ms = 0,
            last_target_position = nil,
            move_numerator_remainder = 0,
        }
    end
    table.sort(units, function(a, b) return a.id < b.id end)
    return units
end

-- 构造 id->unit 查找表；只做直接查找，不依赖 pairs() 迭代顺序。
local function index_units(units)
    local by_id = {}
    for _, unit in ipairs(units) do
        assert(by_id[unit.id] == nil, "duplicate unit id")
        by_id[unit.id] = unit
    end
    return by_id
end

-- 把事件追加到唯一 Event Log；seq 由 append 顺序严格递增。
local function emit(state, event)
    state.next_event_seq = state.next_event_seq + 1
    event.seq = state.next_event_seq
    event.logic_ms = state.logic_ms
    state.events[#state.events + 1] = event
end

-- 从全部存活敌人中选最近目标；距离相同用更小 unit.id 稳定打破平局。
local function choose_target(state, self)
    local best = nil
    local best_dist2 = nil
    for _, candidate in ipairs(state.units) do
        if candidate.hp > 0 and candidate.camp ~= self.camp then
            local d2 = distance2(self.position, candidate.position)
            if best == nil or d2 < best_dist2 or
               (d2 == best_dist2 and candidate.id < best.id) then
                best = candidate
                best_dist2 = d2
            end
        end
    end
    return best
end

-- 判断攻击者当前位置是否已经进入目标攻击范围；使用整数平方距离。
local function in_attack_range(self, target)
    local range2 = self.attack_range_mm * self.attack_range_mm
    return distance2(self.position, target.position) <= range2
end

-- Path userdata 只在 replan 点读取一次，复制成 Lua 连续世界点供后续 Tick 使用。
local function copy_path_points(path)
    local points = {}
    for i = 1, path:count() do
        points[i] = path:world_point(i)
    end
    return points
end

-- 当前目标是否相对上次规划位置移动超过一个 Grid Cell 量级。
-- 阈值由 Context 的真实 cell_size_mm 提供，不复制一份地图配置。
local function target_moved_enough(self, target, threshold_mm)
    if self.last_target_position == nil then return true end
    return distance2(self.last_target_position, target.position) >=
        threshold_mm * threshold_mm
end

-- 停止现有移动并发送权威最终位置。只有确实持有 Path 时才发事件，避免空闲 Tick 刷屏。
local function stop_movement(state, self, reason)
    if self.path == nil then return end
    self.path = nil
    self.path_index = 0
    emit(state, {
        type = "MOVE_STOPPED",
        unit_id = self.id,
        reason = reason,
        position = copy_position(self.position),
    })
end

-- 只在明确 trigger + cooldown 允许时重新寻路；NO_PATH 会退避而不是每 Tick 重试。
local function ensure_attack_path(state, context, self, target)
    if in_attack_range(self, target) then
        stop_movement(state, self, "IN_ATTACK_RANGE")
        self.need_repath = false
        return true, false
    end

    if target_moved_enough(self, target, state.repath_distance_mm) then
        self.need_repath = true
    end
    if not self.need_repath or state.logic_ms < self.repath_not_before_ms then
        return self.path ~= nil, false
    end

    local path, err = context:find_path_to_range(
        self.agent_profile_id,
        self.position,
        target.position,
        self.attack_range_mm,
        self.id)
    if not path then
        -- 动态拥堵或暂时 NO_PATH 不应该在 50ms 后再次全图 A*。
        self.path = nil
        self.path_index = 0
        self.repath_not_before_ms = state.logic_ms + 300
        emit(state, {
            type = "MOVE_STOPPED",
            unit_id = self.id,
            reason = err and err.code or "NO_PATH",
            position = copy_position(self.position),
        })
        return false, false
    end

    self.path = copy_path_points(path)
    self.path_index = (#self.path >= 2) and 2 or 1
    self.need_repath = false
    self.repath_not_before_ms = state.logic_ms + 300
    self.last_target_position = copy_position(target.position)

    emit(state, {
        type = "MOVE_PATH",
        unit_id = self.id,
        speed_mm_per_sec = self.move_speed_mm_per_sec,
        points = self.path,
    })
    -- 新 Path 在当前 tick 边界发布；从下一个 tick 才消费移动预算，Replay 时间与 Server 对齐。
    return true, true
end

-- 当前 Tick 可移动的整数毫米预算；remainder 保留除以1000的余数，避免长期速度漂移。
local function movement_budget(self, tick_ms)
    local numerator = self.move_speed_mm_per_sec * tick_ms +
        self.move_numerator_remainder
    local whole = numerator // 1000
    self.move_numerator_remainder = numerator % 1000
    return whole
end

-- 二维整数平方根；返回 floor(sqrt(n))，避免核心位置推进依赖浮点 sqrt。
local function isqrt(n)
    if n <= 0 then return 0 end
    local x = n
    local y = (x + 1) // 2
    while y < x do
        x = y
        y = (x + n // x) // 2
    end
    return x
end

-- 沿缓存 Path 推进一个 Tick；只有跨入新 Grid Cell 时 Occupancy move 才改变动态状态。
-- 返回 true 表示有移动，false 表示未移动/被阻挡/路径结束。
local function advance_move(state, context, self)
    if self.path == nil or self.path_index <= 0 or
       self.path_index > #self.path then
        return false
    end

    local budget = movement_budget(self, state.tick_ms)
    local moved = false
    while budget > 0 and self.path_index <= #self.path do
        local goal = self.path[self.path_index]
        local dx = goal.x_mm - self.position.x_mm
        local dz = goal.z_mm - self.position.z_mm
        local length = isqrt(dx * dx + dz * dz)
        if length == 0 then
            self.position = copy_position(goal)
            self.path_index = self.path_index + 1
        else
            -- 每次 Occupancy 提交最多半个 Cell，避免高移速单 Tick 跳过中间动态阻挡。
            local step = math.min(budget, length, state.max_move_substep_mm)
            local next_position
            if step == length then
                next_position = copy_position(goal)
            else
                -- 用当前线段比例做整数插值；逻辑位置始终是整数毫米。
                next_position = {
                    x_mm = self.position.x_mm + dx * step // length,
                    y_mm = self.position.y_mm +
                        (goal.y_mm - self.position.y_mm) * step // length,
                    z_mm = self.position.z_mm + dz * step // length,
                }
            end

            local ok, err = context:move_unit(
                self.agent_profile_id,
                self.id,
                self.position,
                next_position)
            if not ok then
                self.need_repath = true
                self.path = nil
                self.path_index = 0
                emit(state, {
                    type = "MOVE_STOPPED",
                    unit_id = self.id,
                    reason = err and err.code or "DYNAMIC_OCCUPIED",
                    position = copy_position(self.position),
                })
                return moved
            end

            self.position = next_position
            moved = true
            budget = budget - step
            if step == length then
                self.path_index = self.path_index + 1
            else
                break
            end
        end
    end

    if self.path ~= nil and self.path_index > #self.path then
        -- Path 可能因目标在规划后移动而先结束。若仍未进入攻击范围，
        -- 下一次 cooldown 允许时必须重新规划，不能永久站在旧终点。
        self.need_repath = true
        stop_movement(state, self, "PATH_END")
    end
    return moved
end

-- 执行最小普通攻击；这是固定数值的 Battle rule，不是 Skill System。
local function try_attack(state, context, self, target)
    if not in_attack_range(self, target) then return false end
    -- 无论 CD 是否已经结束，进入攻击范围后都先停止客户端正在播放的旧 Path。
    stop_movement(state, self, "IN_ATTACK_RANGE")
    self.need_repath = false
    if state.logic_ms < self.next_attack_ms then return false end

    self.next_attack_ms = state.logic_ms + self.attack_cooldown_ms
    target.hp = math.max(0, target.hp - self.attack_damage)
    emit(state, {
        type = "ATTACK",
        attacker_id = self.id,
        target_id = target.id,
        damage = self.attack_damage,
        target_hp = target.hp,
    })

    if target.hp == 0 then
        local released, release_error = context:release_unit(
            target.agent_profile_id,
            target.id,
            target.position)
        if not released then
            error(string.format(
                "release_unit failed unit=%d code=%s message=%s",
                target.id,
                release_error and release_error.code or "UNKNOWN",
                release_error and release_error.message or ""))
        end
        emit(state, {
            type = "UNIT_DEAD",
            unit_id = target.id,
            killer_id = self.id,
            position = copy_position(target.position),
        })
    end
    return true
end

local function alive_camp_count(state)
    local camps = {}
    local count = 0
    for _, unit in ipairs(state.units) do
        if unit.hp > 0 and not camps[unit.camp] then
            camps[unit.camp] = true
            count = count + 1
        end
    end
    return count
end

-- 推进一个 fixed tick；函数内禁止调用任何可能 yield 的 Skynet/网络/DB API。
function M.step(state, context)
    assert(state.final_result == nil, "cannot step a finished battle")
    assert(state.logic_ms < state.max_logic_ms, "cannot step past max_logic_ms")
    -- state.logic_ms 表示本次结算完成的 tick 边界；本 step 内事件时间不会倒退。
    state.logic_ms = state.logic_ms + state.tick_ms
    for _, self in ipairs(state.units) do
        if self.hp > 0 then
            local target = self.target_id and state.by_id[self.target_id] or nil
            if target == nil or target.hp <= 0 then
                target = choose_target(state, self)
                local old_target = self.target_id
                self.target_id = target and target.id or nil
                self.need_repath = true
                if self.target_id ~= old_target then
                    -- 旧 Path 的业务前提已经消失；即使没有新目标，也要让 Replay 停止旧移动。
                    stop_movement(state, self, "TARGET_CHANGED")
                    emit(state, {
                        type = "TARGET_CHANGED",
                        unit_id = self.id,
                        target_id = self.target_id or 0,
                    })
                end
            end

            if target ~= nil and target.hp > 0 then
                if not try_attack(state, context, self, target) then
                    local _, new_path = ensure_attack_path(
                        state, context, self, target)
                    if not new_path then
                        advance_move(state, context, self)
                    end
                    -- 移动后再次检查，进入攻击范围的同 Tick 可以立即攻击。
                    if target.hp > 0 then
                        try_attack(state, context, self, target)
                    end
                end
            end
        end
    end
end

-- 从冻结 snapshot 创建模拟状态并完成初始占位；返回值由同一 Battle owner 持有。
-- 本函数不 yield。在线驱动创建一次后可分段调用 M.step；自动驱动交给 M.simulate。
function M.create(snapshot, context)
    assert(type(snapshot) == "table", "snapshot must be table")
    integer_between(snapshot.battle_id, "battle_id", 1, 0x7fffffff)
    integer_between(snapshot.battle_version, "battle_version", 1, 0x7fffffff)
    integer_between(snapshot.map_id, "map_id", 1, 0x7fffffff)
    integer_between(snapshot.map_version, "map_version", 1, 0x7fffffff)
    integer_between(snapshot.seed, "seed", -0x7fffffffffffffff, 0x7fffffffffffffff)
    integer_between(snapshot.tick_ms, "tick_ms", 1, 1000)
    integer_between(snapshot.max_logic_ms, "max_logic_ms", 1, 0x7fffffff)
    assert(snapshot.max_logic_ms % snapshot.tick_ms == 0,
        "max_logic_ms must be divisible by tick_ms")
    assert(type(snapshot.units) == "table" and #snapshot.units > 0,
        "units must be a non-empty array")

    local units = sorted_units(snapshot)
    local cell_size_mm = integer_between(
        context:cell_size_mm(), "cell_size_mm", 1, 1000000000)
    local state = {
        battle_id = assert(snapshot.battle_id),
        battle_version = snapshot.battle_version,
        map_id = snapshot.map_id,
        map_version = snapshot.map_version,
        seed = snapshot.seed,
        tick_ms = snapshot.tick_ms,
        max_logic_ms = snapshot.max_logic_ms,
        -- 从真实 GridMap 读取，不把第一课 500mm Cell 硬编码进 Battle 逻辑。
        repath_distance_mm = cell_size_mm,
        max_move_substep_mm = math.max(1, cell_size_mm // 2),
        logic_ms = 0,
        next_event_seq = 0,
        units = units,
        by_id = index_units(units),
        events = {},
    }

    for _, unit in ipairs(units) do
        local normalized_position, err = context:place_unit(
            unit.agent_profile_id,
            unit.id,
            unit.position)
        assert(normalized_position, string.format(
            "place_unit failed unit=%d code=%s message=%s",
            unit.id,
            err and err.code or "UNKNOWN",
            err and err.message or ""))
        -- XZ 保留 snapshot 的业务位置，Y 由 Server Grid 归一；后续 Spawn/Path 使用同一高度事实。
        unit.position = normalized_position
    end
    emit(state, {
        type = "BATTLE_BEGIN",
        battle_id = state.battle_id,
        battle_version = state.battle_version,
        map_id = state.map_id,
        map_version = state.map_version,
        seed = state.seed,
    })
    for _, unit in ipairs(state.units) do
        emit(state, {
            type = "UNIT_SPAWN",
            unit_id = unit.id,
            position = copy_position(unit.position),
        })
    end
    return state
end

-- 判断当前状态是否到达胜负或逻辑时限；只读、不分配、不 yield。
function M.is_finished(state)
    return state.logic_ms >= state.max_logic_ms or
        alive_camp_count(state) <= 1
end

-- 封存已经结束的 state 并生成一次 BATTLE_END；重复调用属于编程错误。
function M.finish(state)
    assert(M.is_finished(state), "cannot finish a running battle")
    assert(state.final_result == nil, "battle state already finished")
    local result = alive_camp_count(state) <= 1 and "FINISHED" or "TIMEOUT"
    state.final_result = result
    emit(state, { type = "BATTLE_END", result = result })
    return {
        battle_id = state.battle_id,
        battle_version = state.battle_version,
        map_id = state.map_id,
        map_version = state.map_version,
        seed = state.seed,
        result = result,
        end_logic_ms = state.logic_ms,
        events = state.events,
    }
end

-- 自动战斗入口：不等待墙钟时间，CPU 连续 fixed-tick 推进直到结束或达到逻辑时限。
function M.simulate(snapshot, context)
    local state = M.create(snapshot, context)

    while not M.is_finished(state) do
        M.step(state, context)
    end
    return M.finish(state)
end

return M
```

这里把 `state.logic_ms` 定义为“本次结算完成后的 tick 边界”。`M.step()` 先推进到下一个边界，再给本次事件统一打时间戳，所以同一 Event 数组中的 `logic_ms` 不会因单位顺序而倒退。新生成的 `MOVE_PATH` 在当前边界发布，从下一个 tick 才消费移动预算；这样 Unity 从 Path 事件到 `MOVE_STOPPED` 的播放时长与 Server 实际移动 tick 数一致。

### 17.4 为什么不能每 Tick 重算路径

假设：

```text
200 个单位
20 Tick/s
每 Tick 1 次 A*
```

就是：

```text
4000 次 A*/秒/战场
```

而目标多数 Tick 只移动几十到几百毫米，原 Path 仍然可用。

本课只在这些 trigger 设置 `need_repath`：

```text
target changed
target 相对规划位置移动 >= 1 Cell
当前 Path 被 DynamicOccupancy 阻挡
Path 走完但仍未进入 attack range
NO_PATH 的退避时间到期
```

并有：

```text
repath_not_before_ms
```

限制动态拥堵时的重试频率。

实际项目还可以增加：

```text
路径走廊局部失效
目标速度预测
群体 flow field
局部 steering
reservation table
```

这些都应该由负载数据推动，不要用“每 Tick A*”作为默认答案。

---

## 18. `battle_worker.lua`：Context 的真正 owner

### 18.1 文件职责

Worker 接收纯数据 Snapshot，在自己的 Lua State 创建 Context，然后进入 no-yield 核心。

谁马上使用：`battle_mgr.lua`。

完成后能观察：一次 `skynet.call(worker,"simulate",snapshot)` 返回完整 Event Log。

### 18.2 学习导航

必须精读：Context 创建位置、`xpcall` 边界、simulate 前后哪里可以/不可以 yield。

可以略读：Skynet dispatch 样板。

输入、输出和失败：

```text
输入：可序列化 snapshot
输出：可序列化 result/event tables
失败：Native Context 创建失败或核心 assert -> Worker 返回明确错误 table
```

### 18.3 创建 Worker

[新建文件]

```text
server/service/battle/battle_worker.lua
```

```lua
-- 职责：拥有一个 Skynet Battle Worker Lua State，并为每次模拟创建 battle-local NavigationContext。
-- 边界：Skynet Service Adapter；dispatch 外层可以与 Skynet 交互，battle_core.simulate 内 no-yield。
-- 输入/输出：可序列化 snapshot -> 可序列化 battle result/event log。
-- 生命周期：Service 长驻；NavigationContext 只覆盖一次 simulate，结束后 close。
-- 不负责：不监听网络、不访问 DB、不在核心模拟中 skynet.call。
local skynet = require "skynet"
local battle_nav = require "battle_nav"
local battle_core = require "battle.battle_core"

-- 为一次可序列化 snapshot 创建并独占 Context，然后连续模拟到结束。
-- 成功返回 result；创建或核心失败返回 nil,error；核心阶段不 I/O、不 yield。
local function simulate(snapshot)
    local context, err = battle_nav.new_context(
        snapshot.map_id,
        snapshot.map_version,
        snapshot.profiles)
    if not context then
        return nil, {
            code = err and err.code or "CONTEXT_CREATE_FAILED",
            message = err and err.message or "new_context failed",
        }
    end

    -- 从这里进入核心状态推进。battle_core 不 require skynet，也没有外部 yield 点。
    local ok, result = xpcall(
        battle_core.simulate,
        debug.traceback,
        snapshot,
        context)

    context:close()
    if not ok then
        return nil, { code = "SIMULATE_FAILED", message = result }
    end
    return result
end

skynet.start(function()
    skynet.dispatch("lua", function(_, _, command, payload)
        if command == "simulate" then
            skynet.retpack(simulate(assert(payload)))
            return
        end
        error("unknown battle worker command: " .. tostring(command))
    end)
end)
```

`xpcall` 不是事务机制。它只是确保异常越过 core 边界时能够关闭 Context 并把错误变成可观察结果。核心已经修改过的局部 state 不会继续复用，因为整次 simulate 失败并结束。

---

## 19. `battle_mgr.lua`：允许 yield 的调度层

这里第一次真正出现：

```lua
skynet.call(worker, "lua", "simulate", snapshot)
```

它会 yield，这是允许的，因为 BattleMgr 自己不在持有“推进到一半”的 Battle Core 状态。

### 19.1 文件职责

管理固定 Worker Pool，并把一次自动 Battle 分配给某个 Worker。

本课不做复杂负载均衡。稳定 round-robin 足够验证 service/yield 边界；真实项目可以根据 queue depth/CPU/战场成本演进。

### 19.2 创建 Manager

[新建文件]

```text
server/service/battle/battle_mgr.lua
```

```lua
-- 职责：创建固定 BattleWorker Pool，并把独立 Battle snapshot 分发到 Worker。
-- 边界：Skynet Orchestration；这里允许 skynet.call/yield，不直接修改 Battle 内部状态。
-- 输入/输出：simulate(snapshot) -> Worker 返回的 result 或 error。
-- 生命周期：Manager/Worker 长驻；snapshot 在消息发送时序列化复制。
-- 不负责：不执行 AI/A*/伤害，不保存 NavigationContext userdata。
local skynet = require "skynet"

local workers = {}
local next_worker = 1

-- 按稳定 round-robin 选择 Worker；Manager 单 Service owner 修改 next_worker。
local function choose_worker()
    local worker = workers[next_worker]
    next_worker = next_worker % #workers + 1
    return worker
end

-- 把纯数据 snapshot 发给一个 Worker；本函数会在 skynet.call 处 yield。
local function simulate(snapshot)
    local worker = choose_worker()
    -- 这是明确允许的 yield 点。Manager 没有推进到一半的 Battle mutable state。
    return skynet.call(worker, "lua", "simulate", snapshot)
end

skynet.start(function()
    local count = tonumber(skynet.getenv("battle_worker_count")) or 2
    assert(count >= 1)
    for _ = 1, count do
        workers[#workers + 1] = skynet.newservice("battle/battle_worker")
    end

    skynet.dispatch("lua", function(_, _, command, payload)
        if command == "simulate" then
            skynet.retpack(simulate(assert(payload)))
            return
        end
        error("unknown battle manager command: " .. tostring(command))
    end)
end)
```

注意 Worker 的服务名取决于当前 Skynet `luaservice` 搜索路径。仓库已经提交第一课的 `server/config/skynet.lua`，其 `./service/?.lua` 与 `./lualib/?.lua` 可以继续解析第二课的 `battle/...` 子路径；第二课直接沿用这份进程配置，不为匹配课程阶段另造 `lesson2_server` 入口。

---

## 20. 一个真实的 Battle_1001 自动战斗输入

仓库真实场景出生点：

```text
Team1_Spawn_01 = (-11000, groundY,  4000) mm
Team2_Spawn_01 = ( 11000, groundY, -4000) mm
```

[新建文件]

```text
server/service/battle/batch_runner.lua
```

```lua
-- 职责：构造一个固定 Battle_1001 自动战斗输入，调用 BattleMgr 并做 determinism smoke。
-- 边界：Skynet Test/Batch Entry；只服务课程验收，不包含战斗规则。
-- 输入/输出：固定 snapshot -> 两次模拟结果、确定性比较和可选 Replay 文件。
-- 生命周期：运行一次后可退出；不作为长期在线 Gateway。
-- 不负责：不实现 AI/A*，不定义其他战斗子系统类型。
local skynet = require "skynet"

-- 构造 Battle_1001 的冻结输入；每次调用返回全新的 table，避免两次 smoke 共享可变状态。
local function snapshot()
    return {
        battle_id = 70001,
        battle_version = 1,
        map_id = 1001,
        map_version = 1,
        seed = 123456,
        tick_ms = 50,
        max_logic_ms = 30000,
        profiles = {
            {
                id = 1,
                radius_mm = 200,
                max_step_mm = 600,
                max_slope_permille = 1000,
                area_cost_permille = {
                    [0] = 1000,
                    [1] = 3000,
                    [2] = 1000,
                    [3] = 1500,
                },
            },
        },
        units = {
            {
                id = 1001,
                camp = 1,
                agent_profile_id = 1,
                position = { x_mm = -11000, y_mm = 0, z_mm = 4000 },
                move_speed_mm_per_sec = 2500,
                attack_range_mm = 900,
                attack_damage = 20,
                attack_cooldown_ms = 1000,
                hp = 100,
            },
            {
                id = 2001,
                camp = 2,
                agent_profile_id = 1,
                position = { x_mm = 11000, y_mm = 0, z_mm = -4000 },
                move_speed_mm_per_sec = 2200,
                attack_range_mm = 900,
                attack_damage = 18,
                attack_cooldown_ms = 1100,
                hp = 100,
            },
        },
    }
end

-- 只比较逻辑字段，不用 tostring(table)；pairs/hash 地址顺序不能当 determinism 证据。
local function assert_same_result(a, b)
    assert(a.battle_id == b.battle_id)
    assert(a.battle_version == b.battle_version)
    assert(a.map_id == b.map_id and a.map_version == b.map_version)
    assert(a.seed == b.seed)
    assert(a.result == b.result)
    assert(a.end_logic_ms == b.end_logic_ms)
    assert(#a.events == #b.events)
    for i = 1, #a.events do
        local x = a.events[i]
        local y = b.events[i]
        assert(x.seq == i and y.seq == i)
        if i > 1 then
            assert(x.logic_ms >= a.events[i - 1].logic_ms)
            assert(y.logic_ms >= b.events[i - 1].logic_ms)
        end
        assert(x.seq == y.seq)
        assert(x.logic_ms == y.logic_ms)
        assert(x.type == y.type)
        assert(x.unit_id == y.unit_id)
        assert(x.attacker_id == y.attacker_id)
        assert(x.target_id == y.target_id)
        assert(x.killer_id == y.killer_id)
        assert(x.damage == y.damage)
        assert(x.target_hp == y.target_hp)
        assert(x.speed_mm_per_sec == y.speed_mm_per_sec)
        assert(x.reason == y.reason)
        assert(x.result == y.result)
        local xp, yp = x.position, y.position
        assert((xp == nil) == (yp == nil))
        if xp ~= nil then
            assert(xp.x_mm == yp.x_mm and xp.y_mm == yp.y_mm and xp.z_mm == yp.z_mm)
        end
        local xa, ya = x.points or {}, y.points or {}
        assert(#xa == #ya)
        for point = 1, #xa do
            assert(xa[point].x_mm == ya[point].x_mm)
            assert(xa[point].y_mm == ya[point].y_mm)
            assert(xa[point].z_mm == ya[point].z_mm)
        end
    end
end

skynet.start(function()
    local mgr = skynet.newservice("battle/battle_mgr")
    local first, err1 = skynet.call(mgr, "lua", "simulate", snapshot())
    assert(first, err1 and err1.message)
    local second, err2 = skynet.call(mgr, "lua", "simulate", snapshot())
    assert(second, err2 and err2.message)
    assert_same_result(first, second)
    skynet.error("BATTLE_DETERMINISM_OK events=", #first.events,
                 " end_logic_ms=", first.end_logic_ms,
                 " result=", first.result)
end)
```

### 20.1 这里故意没有“等待 30 秒”

`max_logic_ms=30000` 表示最多模拟 30 秒**逻辑时间**。CPU 可能几十毫秒就完成整场。

不能写：

```lua
for ... do
    skynet.sleep(5) -- 等 50ms 墙钟
end
```

自动 Battle 的价值就是可以快速算完，再让 Unity 按逻辑时间慢慢播放。

---

# 第八部分：Battle Event 与 Unity Replay

## 21. Event 是逻辑事实，不是每 Tick 位置流

第二课至少输出：

```text
BATTLE_BEGIN
UNIT_SPAWN
TARGET_CHANGED
MOVE_PATH
MOVE_STOPPED
ATTACK
UNIT_DEAD
BATTLE_END
```

不会每 50ms 发一个 POSITION Event。移动表现由：

```text
MOVE_PATH
+ speed_mm_per_sec
+ 后续 MOVE_STOPPED / 新 MOVE_PATH
```

重建。

第三课在线模式会增加周期 Snapshot 用于加入/重连/校正；第二课 Replay 只是离线验证，不提前实现完整同步。

### 21.1 Replay 文件为什么先用 JSON

当前用途是：

```text
Server 自动模拟完
-> 把一次结果作为调试/演示 artifact
-> Unity 手工加载回放
```

它不是第三课线上协议，因此本课不扩展 Protobuf Battle Snapshot/Event Schema。JSON 可直接查看，便于核对 `logic_ms/seq/position/path`。

如果正式项目已有统一战报二进制/Protobuf 格式，接入时替换 Writer 即可；Battle Event 的 ownership 和逻辑时间不变。

---

## 22. `replay_writer.lua`：只序列化已经完成的逻辑结果

### 22.1 文件职责

把已完成的 Battle result 写成固定字段顺序 JSON。Writer 在核心 `simulate()` 返回之后执行，所以文件 I/O 不在 no-yield 核心。

### 22.2 学习导航

必须精读：为什么 Writer 位于 simulate 之后、为什么 Event 顺序按数组而不是按 map/pairs。

可以略读：JSON escape 的机械实现。

输入、输出和失败：

```text
输入：immutable-by-convention result table
输出：battle_replay.json
失败：I/O error 只影响 Replay artifact，不回滚已经完成的 Battle result
```

### 22.3 创建 Writer

[新建文件]

```text
server/lualib/battle/replay_writer.lua
```

```lua
-- 职责：把已经完成的 Battle result 以固定字段顺序写成可人工审查的 JSON Replay。
-- 边界：Server Debug/Replay Artifact；只在 battle_core.simulate 返回后执行 I/O。
-- 输入/输出：result table -> UTF-8 JSON 文件。
-- 生命周期：一次调用打开/关闭文件；不保存战斗状态。
-- 不负责：不参与权威结算，不在核心 simulate 内调用，不实现在线同步协议。
local M = {}

-- 把受控事件字符串编码为 JSON string；返回新字符串，不执行 I/O。
local function quote(s)
    s = tostring(s)
    s = s:gsub("\\", "\\\\")
         :gsub('"', '\\"')
         :gsub("\n", "\\n")
         :gsub("\r", "\\r")
         :gsub("\t", "\\t")
    return '"' .. s .. '"'
end

-- 编码一个毫米制 WorldPosition；nil 编码为 JSON null。
local function position(p)
    if p == nil then return "null" end
    return string.format(
        '{"x_mm":%d,"y_mm":%d,"z_mm":%d}',
        p.x_mm, p.y_mm, p.z_mm)
end

-- 按数组顺序编码 Path 世界点；不使用 pairs，保证 artifact 字段顺序稳定。
local function points(value)
    local out = { "[" }
    for i, p in ipairs(value or {}) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = position(p)
    end
    out[#out + 1] = "]"
    return table.concat(out)
end

-- 以固定字段顺序编码一个权威事件；缺失的可选字段使用稳定默认值。
local function event(e)
    -- 字段顺序固定，缺失的可选字段写成 null/0，避免不同 Lua hash 顺序影响 artifact。
    return table.concat({
        "{",
        '"seq":', tostring(e.seq), ",",
        '"logic_ms":', tostring(e.logic_ms), ",",
        '"type":', quote(e.type), ",",
        '"unit_id":', tostring(e.unit_id or 0), ",",
        '"target_id":', tostring(e.target_id or 0), ",",
        '"attacker_id":', tostring(e.attacker_id or 0), ",",
        '"killer_id":', tostring(e.killer_id or 0), ",",
        '"damage":', tostring(e.damage or 0), ",",
        '"target_hp":', tostring(e.target_hp or 0), ",",
        '"speed_mm_per_sec":', tostring(e.speed_mm_per_sec or 0), ",",
        '"reason":', quote(e.reason or ""), ",",
        '"result":', quote(e.result or ""), ",",
        '"position":', position(e.position), ",",
        '"points":', points(e.points),
        "}"
    })
end

-- 编码完整 Battle result；返回 UTF-8 JSON 字符串，不读写文件。
function M.encode(result)
    local out = {
        "{",
        '"battle_id":', tostring(result.battle_id), ",",
        '"battle_version":', tostring(result.battle_version), ",",
        '"map_id":', tostring(result.map_id), ",",
        '"map_version":', tostring(result.map_version), ",",
        '"seed":', tostring(result.seed), ",",
        '"result":', quote(result.result), ",",
        '"end_logic_ms":', tostring(result.end_logic_ms), ",",
        '"events":[',
    }
    for i, e in ipairs(result.events) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = event(e)
    end
    out[#out + 1] = "]}"
    return table.concat(out)
end

-- 把 result 写到 path。成功返回 true；打开、写入或关闭失败返回 nil,error。
-- 本函数执行同步文件 I/O，只能在 battle_core.simulate 已经返回以后调用。
function M.write(path, result)
    local file, open_error = io.open(path, "wb")
    if file == nil then return nil, open_error end
    local ok, write_error = file:write(M.encode(result), "\n")
    if ok == nil then
        file:close()
        return nil, write_error
    end
    local closed, close_error = file:close()
    if closed == nil then return nil, close_error end
    return true
end

return M
```

Writer 创建完成后，对已有 `batch_runner.lua` 做一次局部修改。文件顶部增加：

```lua
local replay_writer = require "battle.replay_writer"
```

两次 determinism 验证通过后增加：

```lua
local replay_ok, replay_error = replay_writer.write(
    "tmp/battle_replay.json", first)
assert(replay_ok, replay_error)
skynet.error("BATTLE_REPLAY_OK path=tmp/battle_replay.json")
```

本课约定从仓库的 `server/` 目录启动 Skynet，因此启动 batch 前先在该目录执行 `mkdir -p tmp`。Writer 的相对路径会落到 `server/tmp/battle_replay.json`；若本机启动脚本改变了工作目录，就把输出根目录作为启动配置显式传入，不能依赖碰巧的 cwd。

这个 I/O 在 `battle_core.simulate()` 已经结束之后，所以不违反核心 no-yield/无外部 I/O 边界。

---

## 23. Unity Replay：Client 只按 Server logic_ms 表现

第二课不需要漂亮角色。两个 Capsule/Cube 足够验证：

```text
Server Path 是否绕墙
移动时间是否符合 logic_ms
重新规划是否覆盖旧 Path
攻击/死亡是否按 Event 顺序发生
```

### 23.1 Unity 边界先解释清楚

本节的 Unity 代码属于：

```text
Client Runtime / Debug Presentation
```

`BattleReplayPlayer` 是 Play Mode 中的回放组件。它读取 Server 已经完成的逻辑结果，作用类似 Server 侧“按时间戳消费 append-only Event Log 的只读投影”：只更新显示对象，不重新执行业务规则。当前步骤需要它来验证 Server Path、攻击与死亡事件能被独立客户端完整观察。

进入 Play Mode 后，在 Unity 的 Hierarchy 观察 `ReplayUnit_*`，在 Scene/Game 视图观察移动，在 Console 观察攻击和结束日志。它属于 Client Runtime / Debug Presentation；BMAP 导出仍属于 Authoring/Asset，A* 与伤害仍属于 Server Runtime。

它不能：

```text
NavMeshAgent 重新寻路后覆盖 Server Path
客户端自己重新判定是否进入攻击范围
客户端重新计算伤害
客户端把本地碰撞结果写回 Server
```

`Transform.position` 使用米：

```text
server 2500mm -> Unity 2.5f
```

Y 也来自 Server Path point；不要重新从 Unity NavMesh Sample 一个不同高度替换它。

### 23.2 BattleReplayPlayer 学习导航

本文件解决的问题：按 Server `logic_ms` 顺序消费 Replay Event，并显示两支地面单位的移动、攻击和死亡。

必须精读：毫米转米、Server logic time 与 Unity elapsed time 的映射、MOVE_PATH 覆盖旧移动。

可以略读：`GameObject.CreatePrimitive`、Material/颜色等纯显示样板。

输入、输出和失败：

```text
输入：TextAsset JSON Replay
输出：Play Mode 中的单位移动/日志/死亡显示
失败：JSON 无效、seq 倒序、未知 unit 时明确 Debug.LogError
```

### 23.3 创建 Replay Player

[新建文件]

```text
unity/BattleNavigation/Assets/BattleNavigation/Client/BattleReplayPlayer.cs
```

```csharp
// 职责：按 Server 生成的 logic_ms/seq 回放第二课自动战斗事件。
// 边界：Unity Client Runtime Debug Presentation；Server Event 是权威输入。
// 输入/输出：Replay JSON TextAsset -> 基础几何体移动、攻击日志和死亡显示。
// 生命周期：Play Mode 开始时解析一次；Update 只推进表现时间。
// 不负责：不重新寻路、不计算命中/伤害、不把客户端位置回写 Server。
using System;
using System.Collections.Generic;
using UnityEngine;

namespace BattleNavigation.Client
{
    /// <summary>Replay 中一个 Server 世界坐标点；三个分量单位都是毫米。</summary>
    [Serializable]
    public sealed class ReplayPosition
    {
        public int x_mm; // Server 世界 X，毫米。
        public int y_mm; // Server 权威地表 Y，毫米。
        public int z_mm; // Server 世界 Z，毫米。
    }

    /// <summary>一个按 seq/logic_ms 排序的 Server 逻辑事件；字段名与 JSON 合同一致。</summary>
    [Serializable]
    public sealed class ReplayEvent
    {
        public int seq;                         // Battle 内从 1 开始严格递增。
        public int logic_ms;                    // fixed-tick 逻辑时间，毫秒。
        public string type;                     // 稳定事件类型名。
        public int unit_id;                     // 事件主体；0 表示该类型不使用。
        public int target_id;                   // 目标单位；0 表示无。
        public int attacker_id;                 // 攻击者；0 表示无。
        public int killer_id;                   // 击杀者；0 表示无。
        public int damage;                      // 本次权威伤害；非攻击事件为 0。
        public int target_hp;                   // 伤害结算后的权威 HP。
        public int speed_mm_per_sec;             // MOVE_PATH 表现速度，毫米/秒。
        public string reason;                   // 停止/失败原因；无则空串。
        public string result;                   // BATTLE_END 结果；无则空串。
        public ReplayPosition position;         // 权威事件位置；可为 null。
        public ReplayPosition[] points;         // MOVE_PATH 世界点；其他事件为空数组。
    }

    /// <summary>一次完整离线 Replay 的身份、结束状态和有序事件数组。</summary>
    [Serializable]
    public sealed class ReplayDocument
    {
        public int battle_id;          // 本次 Battle 身份。
        public int battle_version;     // Battle 规则版本。
        public int map_id;             // BMAP 地图 ID。
        public int map_version;        // BMAP 地图版本。
        public long seed;              // 本次确定性输入 seed。
        public string result;          // FINISHED 或 TIMEOUT。
        public int end_logic_ms;        // 模拟结束逻辑时间，毫秒。
        public ReplayEvent[] events;    // 按 seq 保存的 Server 事件。
    }

    /// <summary>
    /// 第二课离线 Replay 播放器。只消费 Server Event，不拥有任何权威战斗规则。
    /// </summary>
    public sealed class BattleReplayPlayer : MonoBehaviour
    {
        // Server 输出并复制到 Unity Assets 的 JSON Replay；只读。
        [SerializeField] private TextAsset replayJson;
        // 播放倍速；1=按 logic_ms 实时播放，2=两倍速。
        [SerializeField, Min(0.1f)] private float playbackSpeed = 1f;

        private sealed class ActiveMove
        {
            public ReplayPosition[] points = Array.Empty<ReplayPosition>(); // Server Path 世界点，毫米。
            public int nextPoint = 1;       // 下一个目标点数组下标。
            public float speedMeters = 0f;  // 由 Server mm/s 转换，纯表现参数。
        }

        // unit_id -> Client Runtime 显示对象；由本组件创建和销毁。
        private readonly Dictionary<int, GameObject> units =
            new Dictionary<int, GameObject>();
        // unit_id -> 当前表现 Path；新 MOVE_PATH 会覆盖旧值。
        private readonly Dictionary<int, ActiveMove> moves =
            new Dictionary<int, ActiveMove>();
        private ReplayDocument replay; // 当前只读 Replay 文档。
        private int nextEvent;          // 下一个尚未消费的 events 数组下标。
        private float logicMs;          // 客户端表现时间，毫秒；不回写 Server。

        /// <summary>解析 Replay 并重置播放状态；失败时抛出明确异常。</summary>
        private void Start()
        {
            if (replayJson == null)
                throw new InvalidOperationException("Replay JSON is not assigned");
            replay = JsonUtility.FromJson<ReplayDocument>(replayJson.text);
            if (replay == null || replay.events == null)
                throw new InvalidOperationException("Replay JSON is invalid");
            if (replay.events.Length > 0 && replay.events[0].seq != 1)
                throw new InvalidOperationException("Replay event seq must start at 1");

            for (var i = 1; i < replay.events.Length; ++i)
            {
                if (replay.events[i].seq != replay.events[i - 1].seq + 1 ||
                    replay.events[i].logic_ms < replay.events[i - 1].logic_ms)
                    throw new InvalidOperationException("Replay event order is invalid");
            }
        }

        /// <summary>按墙钟 deltaTime 推进表现时间，再消费已经到达的 Server logic event。</summary>
        private void Update()
        {
            logicMs += Time.deltaTime * 1000f * playbackSpeed;
            while (nextEvent < replay.events.Length &&
                   replay.events[nextEvent].logic_ms <= logicMs)
            {
                Apply(replay.events[nextEvent]);
                ++nextEvent;
            }
            AdvanceMoves(Time.deltaTime * playbackSpeed);
        }

        /// <summary>应用一个权威事件；只改变显示对象和本地表现状态。</summary>
        private void Apply(ReplayEvent value)
        {
            switch (value.type)
            {
                case "BATTLE_BEGIN":
                    Debug.Log($"Battle {replay.battle_id} begin seed={replay.seed}");
                    break;
                case "UNIT_SPAWN":
                    if (value.position != null)
                        GetOrCreate(value.unit_id, value.position);
                    break;
                case "MOVE_PATH":
                    BeginMove(value);
                    break;
                case "MOVE_STOPPED":
                    StopMove(value);
                    break;
                case "ATTACK":
                    Debug.Log($"ATTACK {value.attacker_id}->{value.target_id} " +
                              $"damage={value.damage} hp={value.target_hp}");
                    break;
                case "UNIT_DEAD":
                    Kill(value.unit_id);
                    break;
                case "TARGET_CHANGED":
                    break; // 第二课只保留调试语义，不要求视觉效果。
                case "BATTLE_END":
                    moves.Clear(); // 结束事件终止所有纯表现插值，不能越过权威结束时间继续移动。
                    Debug.Log($"Battle end result={value.result}");
                    break;
                default:
                    Debug.LogError("Unknown replay event: " + value.type);
                    break;
            }
        }

        /// <summary>开始/覆盖某单位当前移动表现；新 MOVE_PATH 权威替换旧表现路径。</summary>
        private void BeginMove(ReplayEvent value)
        {
            if (value.points == null || value.points.Length == 0) return;
            var unit = GetOrCreate(value.unit_id, value.points[0]);
            unit.transform.position = ToUnity(value.points[0]);
            moves[value.unit_id] = new ActiveMove
            {
                points = value.points,
                nextPoint = value.points.Length > 1 ? 1 : value.points.Length,
                speedMeters = value.speed_mm_per_sec / 1000f,
            };
        }

        /// <summary>按 MOVE_STOPPED 的 Server 最终位置停止本地插值。</summary>
        private void StopMove(ReplayEvent value)
        {
            moves.Remove(value.unit_id);
            if (value.position != null)
            {
                var unit = GetOrCreate(value.unit_id, value.position);
                unit.transform.position = ToUnity(value.position);
            }
        }

        /// <summary>仅做路径折线插值；不会使用 NavMeshAgent 重新求路。</summary>
        private void AdvanceMoves(float deltaSeconds)
        {
            foreach (var pair in moves)
            {
                if (!units.TryGetValue(pair.Key, out var unit)) continue;
                var move = pair.Value;
                var remaining = move.speedMeters * deltaSeconds;
                while (remaining > 0f && move.nextPoint < move.points.Length)
                {
                    var target = ToUnity(move.points[move.nextPoint]);
                    var distance = Vector3.Distance(unit.transform.position, target);
                    if (distance <= remaining || distance <= 0.0001f)
                    {
                        unit.transform.position = target;
                        remaining -= distance;
                        ++move.nextPoint;
                    }
                    else
                    {
                        unit.transform.position = Vector3.MoveTowards(
                            unit.transform.position, target, remaining);
                        remaining = 0f;
                    }
                }
            }
        }

        /// <summary>返回现有显示对象；不存在时创建一个 Capsule 作为课程观察对象。</summary>
        private GameObject GetOrCreate(int unitId, ReplayPosition position)
        {
            if (units.TryGetValue(unitId, out var value)) return value;
            value = GameObject.CreatePrimitive(PrimitiveType.Capsule);
            value.name = "ReplayUnit_" + unitId;
            value.transform.position = ToUnity(position);
            units.Add(unitId, value);
            return value;
        }

        /// <summary>把 Server 整数毫米世界坐标转换为 Unity 世界米；轴保持 X/Y/Z 不变。</summary>
        private static Vector3 ToUnity(ReplayPosition p)
        {
            return new Vector3(p.x_mm / 1000f, p.y_mm / 1000f, p.z_mm / 1000f);
        }

        /// <summary>按 Server UNIT_DEAD 事件销毁显示对象；不在客户端重新判定 HP。</summary>
        private void Kill(int unitId)
        {
            moves.Remove(unitId);
            if (units.TryGetValue(unitId, out var value))
            {
                Destroy(value);
                units.Remove(unitId);
            }
        }
    }
}
```

### 23.4 实际操作

Server 自动战斗生成：

```text
server/tmp/battle_replay.json
```

把它复制到：

```text
unity/BattleNavigation/Assets/BattleNavigation/Generated/Replay/battle_replay.json
```

`Generated/Replay` 是运行生成物目录，不要手工维护里面的逻辑内容。

在 `Battle_1001` Scene：

```text
Create Empty -> ReplayPlayer
Add Component -> BattleReplayPlayer
把 battle_replay.json 拖到 Replay Json
Play
```

观察：

```text
两单位使用 Server Path 绕开 CenterBlock/其他静态障碍
动态碰撞导致的重规划不会互相穿格
攻击发生在进入 attack range 后
UNIT_DEAD 后对象消失
整个播放耗时按 logic_ms，而不是 Server 模拟实际 CPU 耗时
```

常见误解：

```text
Unity Capsule 穿插视觉模型
```

先检查 Server Path world points 与 BMAP Overlay。如果 Server 点合法而显示模型体积比 AgentProfile 大，这是 Client presentation 参数不一致；不要让 NavMeshAgent 在客户端重新规划去“修正”权威路径。

---

# 第九部分：课程后段才整理稳定 Grid Navigation API

## 24. 现在已经有真实调用者，可以看见哪些概念是稳定的

到这里 `battle_core` 已经真正使用：

```text
WorldPosition
AgentProfile
NavigationContext
Path
find_path
find_path_to_range
DynamicOccupancy
```

而这些仍然是 Grid 实现细节：

```text
GridPos
NavCell
node_index
heap_index
parent_index
generation stamp
Binary Heap
Octile heuristic
Supercover
```

因此第二课末尾可以把调用面冻结成：

```lua
battle_nav.new_context(map_id, map_version, profiles)

context:find_path(profile_id, start_world, end_world, self_unit_id)
context:find_path_to_range(
    profile_id, start_world, target_world, attack_range_mm, self_unit_id)
context:place_unit(profile_id, unit_id, world_position) -- -> normalized WorldPosition
context:move_unit(profile_id, unit_id, from_world, to_world)
context:release_unit(profile_id, unit_id, world_position)
context:cell_size_mm()
context:close()

path:count()
path:world_point(i)
path:length_mm()
```

这就是当前 BattleWorker 的稳定 **Grid Navigation API**。

### 24.1 本课明确不创建这些文件

```text
navigation_api.h 中的 INavigationBackend
GridNavigationBackend
DetourNavigationBackend
DetourQueryContext
NAVSRC
DNAV
nav_builder
```

原因不是“不考虑演进”，而是现在只有一个实现。可选 Lesson 4 第一次加入 Detour 时，再从：

```text
已工作的 Grid 调用者
+
真实 Detour 实现
```

中提取 Backend Contract，才能验证抽象到底是否正确。

### 24.2 本课保持现有目录

第二课继续使用 `server/native/grid_map/`，不安排目录迁移。当前验收对象是 A*、动态占位、BattleWorker 和 Replay 的行为链；路径重组不会增加可观察能力，还会把 include/CMake 机械改动混入功能调试。以后真的出现第二种导航实现时，再在可选第四课依据两个真实实现决定目录和 Backend 边界。

---

# 第十部分：完整构建、测试、调试和验收

## 25. 本课 Native CMake 最终应该包含什么

`grid_map_core` 最终源码：

```text
第一课已有：
src/bmap_reader.cpp
src/grid_map.cpp
src/map_registry.cpp
src/nav_result.cpp

第二课新增：
src/navigation_context.cpp
src/dynamic_occupancy.cpp
src/grid_pathfinder.cpp
```

Headers：

```text
第一课已有：
bmap_format.h
bmap_reader.h
grid_map.h
map_registry.h
nav_result.h

第二课新增：
agent_profile.h
navigation_path.h
navigation_context.h
dynamic_occupancy.h
grid_pathfinder.h
```

测试：

```text
grid_map_test        第一课 regression
navigation_test      第二课 unified correctness/concurrency
navigation_benchmark 第二课 standalone benchmark
```

不要出现：

```text
lesson2_astar.cpp
lesson02_server.lua
lesson2_context.h
```

课程阶段不应该泄漏到产品源码命名。

---

## 26. GDB：真正值得下断点的位置

Native：

```bash
gdb --args build/grid_map/navigation_test
```

建议断点：

```gdb
break battle_nav::NavigationContext::BeginQuery
break battle_nav::GridPathfinder::FindPath
break battle_nav::DynamicOccupancy::Move
run
```

观察一个 Node 时重点看：

```text
node_index
node.generation
node.g_cost
node.parent_index
node.heap_index
node.state
context.query_generation
context.heap_size
```

如果路径随机变化，优先检查：

```text
heap tie-break
未初始化 generation
parent 被其他 Context 污染
unordered iteration 进入逻辑顺序
```

Lua：在 `battle_core.lua` 下断点观察：

```text
state.logic_ms
unit.target_id
unit.need_repath
unit.repath_not_before_ms
unit.path_index
unit.position
```

但不要在调试时加入 `skynet.sleep()` 改变核心结构；调试工具不能偷偷改变被验证对象。

---

## 27. 第二课完整验收顺序

按执行链验收，不要只跑最后的 Battle：

```text
1. 第一课 grid_map_test 仍然通过
2. navigation_test -> ALL_TESTS_OK
3. static A* straight / wall / no path / corner cases
4. Agent clearance / slope / area cost
5. DynamicOccupancy place/move/release/conflict
6. 缓存 Path 跨格提交会拒绝新出现的动态切角阻挡
7. FindPathToRange 在 target center 被占用时返回合法攻击位置
8. smoothing 合法性复验
9. concurrency stress：shared immutable map + independent contexts
10. benchmark：80x60 / 256x256 / 512x512，记录条件
11. Lua Worker State 能 new_context + find_path
12. BattleMgr -> Worker simulate
13. core simulate 期间没有 skynet.call/sleep/I/O
14. Path 结束会按 cooldown 重寻路，进入攻击范围会停止旧移动
15. 相同 snapshot/map/version/seed 两次 Event 一致
16. 输出 battle_replay.json
17. Unity 按 Server Path/Event 完成 Replay
```

最终应该看到：

```text
ALL_TESTS_OK
BATTLE_DETERMINISM_OK
BATTLE_REPLAY_OK
```

---

## 28. 第二课面试复盘

完成这一课以后，应该能脱离代码回答下面的问题。

### 为什么 A* scratch 不能全局共享？

因为 Native Module 可以被多个 Skynet Service 从不同 OS Thread 同时进入。`g_cost/parent/open/closed/heap_index` 是查询级可变状态，全局共享会产生真实数据竞争和路径污染。静态 `GridMap` 能共享的前提是加载后 immutable。

### generation stamp 解决什么？

避免每次 Query 对全地图 Node Scratch 做 O(map_cells) 清零。每次查询递增 generation，只有实际访问的 Node 才懒初始化；回卷时才全量清 generation。

### 为什么 Binary Heap 保存 node_index？

Node 数据已经在 Context 的 dense array 中。Heap 只需要保存稳定 index；这样没有 per-node allocation，并且 `heap_index` 可以直接支持 decrease-key。

### 8-way 为什么必须防 corner cutting？

对角目标 Cell 自己可走并不代表单位可以穿过两个正交障碍的夹角。对角移动必须同时验证两个侧格，并使用同一 Agent/Occupancy 规则。

### clearance、slope、area cost 分别属于什么？

```text
clearance  GridMap 静态空间属性，AgentProfile 决定要求多少
slope      相邻 Cell height + AgentProfile 阈值共同决定
area       GridMap 提供 area_type，AgentProfile 决定 allowed/cost
```

### 为什么 DynamicOccupancy 不放进 GridMap？

GridMap 是 map/version 对应的进程级共享资产；Occupancy 是某一场 Battle 当前 Tick 的可变事实。生命周期和共享范围完全不同。

### 为什么 Path 返回 WorldPosition？

Battle/Replay 需要稳定业务坐标。GridPos 绑定 origin/cell size/当前 Grid 实现，不能成为长期业务合同。

### 为什么不每 Tick A*？

绝大多数 Tick 路径仍然有效。每 Tick A* 会把单位数×Tick 频率直接放大成大量完整搜索，并在拥堵时形成正反馈。缓存 Path，只在目标变化、路径失效等明确 trigger 下重算。

### BattleWorker 为什么核心 no-yield？

让一次状态推进成为清晰的单 owner 临界区。中途外部 `skynet.call` 会允许协程交错，引入半更新状态、版本变化和复杂补偿。准备好 Snapshot 后，本地连续 simulate，再一次性返回。

### 同一个 Skynet Service 和 OS Thread 是一回事吗？

不是。Service 是 Actor/消息处理实体，Lua State 属于 Service 运行环境；OS Worker Thread 是调度执行资源。Native 进程级模块可能同时从多个 Service/Thread 进入，所以 Native 线程安全不能只看一个 Lua State。

### 哪些地方会分配内存？

```text
Context 创建：NodeScratch + Heap + Occupancy，O(cell_count)
FindPath：最终 raw/smoothed Path points 分配，A* Node 本身不 per-node allocation
Lua Path userdata：每条新 Path 一次
Battle repath：Path 世界点复制到 Lua movement state
Event Log：按事件数量增长
Unity Replay：解析 JSON 和创建显示对象
```

### 哪些地方可能 yield？

```text
BattleMgr -> skynet.call(worker)      会
网络/DB/Socket                         会/可能
BattleWorker 调 battle_core 之前       dispatch 边界可
battle_core.simulate/step              禁止
Native find_path/occupancy             不会
Unity Replay                           与 Server yield 无关
```

---

## 29. 已知限制与何时演进

第二课完成的是商业项目可以真实使用的**单层 Grid 地面导航与自动战斗骨架**，但范围明确：

```text
支持：
单层 2.5D
坡地/台地
不同 Agent clearance/slope/area
动态单位离散 footprint
Server AI target/move/basic attack
确定性 Event Replay

不支持：
桥上+桥下同 XZ
多层楼
完整 crowd steering
局部避障速度障碍
飞行
技能/弹丸
Player 在线输入
完整在线 Snapshot/Event Sync
Polygon NavMesh / Off-Mesh
```

出现这些需求时：

```text
大量密集单位互相卡位
-> 先 Benchmark，再考虑 reservation/steering/flow field

桥上下层、多层平台、复杂不规则表面
-> 可选 Lesson 4 Recast/Detour

玩家实时操作、技能/弹丸、空中单位
-> Lesson 3
```

---

## 30. 文档结束前的自审计

本课实现时逐项检查：

```text
[ ] 所有现有路径都来自当前仓库或明确写为“第二课新建”。
[ ] 第一课 bmap_format/GridMap/MapRegistry 没有被重新创建。
[ ] WorldPosition 仍然是 Lua/Battle/Replay 正式业务位置。
[ ] GridPos 只存在 Native Grid 算法和 Debug/Test。
[ ] AgentProfile 在 A* 首次需要体型前出现。
[ ] Path 在第一次真正返回路线前出现。
[ ] NavigationContext 在 A* scratch 首次出现前确定 owner。
[ ] DynamicOccupancy 在静态 A* 跑通以后才加入。
[ ] A* 使用 Binary Heap、generation stamp、无 per-node allocation。
[ ] 8-way 对角同时检查两个 side Cell，禁止 corner cutting。
[ ] clearance/slope/area/dynamic 都进入统一 CanTraverse 判定链。
[ ] smoothing 复用同一合法性规则，并保留 Area Cost 语义。
[ ] 缓存 Path 的每次跨格提交重新验证目标格和 diagonal side cells。
[ ] 每个 Battle/Query 拥有独立 NavigationContext。
[ ] 没有 global mutable A* scratch。
[ ] Battle core 内没有 skynet.call/skynet.sleep/Socket/DB/I/O。
[ ] Path 有明确 repath trigger 和 cooldown，不每 Tick A*。
[ ] Path 结束但尚未进入攻击范围时会重新置位 need_repath。
[ ] 进入攻击范围会发送 MOVE_STOPPED，Unity 不继续播放旧 Path。
[ ] Event 顺序有稳定 seq/logic_ms。
[ ] 相同 input/map/version/battle_version/seed 得到同逻辑 Event。
[ ] Unity Replay 只表现 Server 结果，不重新寻路覆盖 Path。
[ ] 没有 INavigationBackend / GridNavigationBackend / DetourNavigationBackend。
[ ] 没有 Recast/Detour/Polygon NavMesh 教学内容。
[ ] 没有 SkillRuntime/Projectile/FlyingNavigation/PlayerCommand。
[ ] 没有 lesson2.lua、lesson02_server 等课程阶段命名进入工程。
[ ] 所有新增源码示例有职责/边界/输入输出/生命周期/非职责文件头。
[ ] 关键函数说明参数、返回、失败、分配/锁/yield 边界。
[ ] node_index/heap_index/parent_index/generation/open/closed 有明确注释。
[ ] 测试使用统一 navigation_test，不为每个小知识点创建独立程序。
```

如果把本教程落实到仓库后，再执行：

```bash
git diff --check
```

它应该无输出并以 0 退出。若出现 trailing whitespace 或 conflict marker，先修文档/源码格式，再提交。

---

## 31. 本课最终执行链

```text
第一课结果
WorldPosition + immutable GridMap
        |
        v
AgentProfile
        |
        v
NavigationContext
  ├─ A* scratch + generation
  ├─ Binary Heap
  └─ DynamicOccupancy
        |
        v
GridPathfinder
  ├─ World -> Grid
  ├─ clearance / step / slope / area
  ├─ 8-way no corner cutting
  ├─ dynamic occupancy
  ├─ A* / attack-range goal
  ├─ smoothing + revalidation
  └─ Grid -> World Path
        |
        v
Lua Context/Path userdata
        |
        v
BattleWorker
  prepare context
  -> battle_core no-yield
       target
       cached path
       conditional repath
       move
       basic attack
       deterministic event
  -> return
        |
        v
Replay JSON
        |
        v
Unity Client Runtime
  replay Server world path/events
```

这条链完成以后，第二课才算结束。它把第一课的“Server 能查询地图”推进成“Server 能在一场独立 Battle 中使用自己的动态导航状态，确定性地完成地面 AI 移动和基础战斗，并让 Unity 只按权威结果回放”。

下一课才继续加入人工 Player 输入、Ground/Flying Enemy、技能、弹丸、Air Grid/NoFly，以及在线 Snapshot/Event 同步。
