# Lesson 2 实操：从 A* 到 Skynet 自动战斗

> 状态：旧草稿，当前不作为学习入口，也不继续扩写。学习者完成第一课并明确提出后，必须依据 `codex/LESSON_02_SPEC.md`、第一课真实产物和最新课程路线重新验收或重写，不能直接沿用本稿。

第一课已有：

```text
Unity -> BMAP -> GridMap -> Skynet Query
```

现在第一次出现真实需求：

> Hero A 怎么绕过障碍，走到 Hero B 的攻击范围？

新的概念全部围绕这个问题引入。

---

## Stage 1：先实现最简单 FindPath

输入：

```text
start world position
end world position
```

GridMap 内部：

```text
World -> Grid
```

然后 C++ A*。

先实现静态地图版本：

```text
walkable
```

跑通以后再加体型、坡度、Area 和动态占位。

---

## Stage 2：A* 工程实现

要求：

```text
Binary Heap
flat arrays
generation stamp
no per-node new/delete
integer cost
8-way
Octile heuristic
no corner cutting
```

先写 Golden Tests。

---

## Stage 3：为什么现在需要 AgentProfile

现在出现问题：

```text
Small 能走过窄路
Boss 不能
```

所以第一次定义：

```text
AgentProfile
```

包含：

```text
radius
max_step
max_slope
area mask/cost
```

这时第一课导出的：

```text
clearance
height
area
```

才真正开始被消费。

---

## Stage 4：为什么现在需要 Path

A* 返回的不应该是一堆业务 Lua 小 Table。

第一次定义：

```text
Path
```

Native 持有连续路径点。

正式 Path 使用：

```text
WorldPosition
```

而不是长期暴露 GridPos。

Lua：

```lua
path:count()
path:world_point(i)
path:length_mm()
```

---

## Stage 5：Slope / Area / Clearance

逐个加入：

```text
clearance
max step
max slope
area cost
```

每加入一种规则，就增加对应 Golden Case。

---

## Stage 6：为什么现在需要 NavigationContext

接下来两场 Battle：

```text
Battle A
Battle B
```

使用同一静态地图，但单位位置不同。

于是第一次引入：

```text
NavigationContext
```

含义非常具体：

> 一场 Battle 自己的动态导航状态。

它拥有：

```text
DynamicOccupancy
Reservation
```

不拥有 Static GridMap。

---

## Stage 7：Dynamic Occupancy

实现：

```text
occupy
move
release
ignore self
conflict
```

移动更新要先验证新位置，再 commit，不能留下半占位。

---

## Stage 8：Attack Position

不能让 Hero A 的终点直接是 Hero B 已占用的中心格。

先搜索：

```text
处于 attack range
可走
能容纳 Agent
未占用
```

的候选攻击位置。

再寻路。

---

## Stage 9：Path Smoothing

Grid A* 路径可能锯齿。

Native：

```text
supercover line check
```

做逻辑路径简化。

每条简化 Segment 再检查：

```text
walkable
clearance
corner
dynamic policy
```

---

## Stage 10：BattleWorker

固定 Worker Pool。

```text
BattleMgr
-> skynet.call(worker, "simulate", snapshot)
```

BattleMgr 会 yield。

Worker：

```text
simulate()
```

内部不做外部 `skynet.call`。

---

## Stage 11：Battle Snapshot

输入：

```text
battle_id
battle_version
map_id
map_version
seed
units
```

Unit：

```text
world position
move speed
attack range
agent profile
hp
camp
```

---

## Stage 12：Logic Tick

课程可：

```text
50ms
```

CPU 快速模拟 30 秒逻辑时间。

不 `skynet.sleep()` 等真实时间。

---

## Stage 13：Path 不每 Tick 重算

只有：

```text
target changed
destination changed
path blocked
replan policy
```

才重新 A*。

正常 Tick 只沿已有 Path 推进。

---

## Stage 14：Battle Event

至少：

```text
TARGET_CHANGED
MOVE_PATH
MOVE_STOPPED
ATTACK
UNIT_DEAD
```

不要每 50ms 推位置。

---

## Stage 15：Unity Replay

`MOVE_PATH`：

```text
world path
start_logic_ms
end_logic_ms
```

Unity：

```text
world mm -> meter
-> spline/interpolation
-> animator
```

必须在 Server 逻辑结束时刻到达。

---

## Stage 16：Determinism

固定：

```text
target tie
RNG order
iteration order
integer rules
```

同：

```text
input + seed + map version + battle version
```

Event 一致。

---

# Stage 17：现在才整理 Navigation API

到这里，你已经亲手用过：

```text
AgentProfile
Path
NavigationContext
FindPath
```

现在观察：

这些概念其实不是 Grid 专属。

Grid 专属的是：

```text
GridPos
AStarNode
GridCell
```

于是课程后段再做一次小范围整理：

```text
Grid navigation implementation
        ↓
common Navigation API
```

正式形成：

```cpp
INavigationBackend
```

或等价接口。

但不要为了抽象而重写业务。

目的只有：

> 可选 Lesson 4 可以新增 Detour 实现；第三课主线不依赖 Detour。

---

## Stage 18：抽象后的业务接口

Lua 仍然：

```lua
local context =
    nav.new_context(
        map_id,
        map_version
    )

local path, err =
    context:find_path(
        profile_id,
        start_world,
        end_world,
        options
    )
```

BattleWorker 不知道底层：

```text
Grid A*
```

---

## Stage 19：Benchmark

Standalone：

```text
80x60
256x256
512x512
```

记录：

```text
p50/p95/p99
qps
visited nodes
allocation
thread count
```

Skynet：

```text
worker queue
simulate latency
CPU
path count
repath count
```

---

## 第二课结束后

现在你已经真正理解：

```text
AgentProfile
Path
NavigationContext
INavigationBackend
```

因为它们都是从实际 Battle 需求中长出来的。

Lesson 3 才开始学：

```text
Polygon
Tile
PolyRef
Corridor
Recast
Detour
Off-Mesh Link
```
