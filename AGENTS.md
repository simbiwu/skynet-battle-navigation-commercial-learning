# AGENTS.md - Skynet Battle Navigation 三课专题

## P0

课程训练：

```text
Unity 3D Authoring
-> Server Navigation Asset
-> C++ Navigation
-> Skynet Battle Simulation
-> Unity Replay
```

功能可简化，工程边界不能用 Demo 捷径替代。

## 独立项目

参考：

```text
https://github.com/simbiwu/Skynet-slg-learning
```

只参考教学方法、工程纪律、Skynet ownership/yield、测试和文档风格。

禁止合并旧工程或复制旧业务。

## Learner

可以默认学习者：

- 熟悉 C++ / Lua；
- 有 MMO Server 经验；
- 已理解 Skynet Service / Lua State / call/send/dispatch；
- 关注性能、并发、内存、部署和维护；
- 不需要基础语法教学。

# 最重要的教学规则：架构预留 ≠ 提前教学

课程要为 Lesson 3 Polygon NavMesh 保留升级空间，但不能因此提前让学习者理解当前行为尚未需要的抽象。

概念首次正式出现时间固定：

```text
Lesson 1:
  WorldPosition
  GridPos
  NavCell
  BMapReader
  GridMap
  MapRegistry

Lesson 2:
  AgentProfile
  Path
  NavigationContext
  DynamicOccupancy
  Grid A*
  BattleWorker
  Lesson 2 后段再整理 Navigation Backend Interface

Lesson 3:
  INavigationBackend 双实现
  GridNavigationBackend
  DetourNavigationBackend
  Recast / Detour
```

Lesson 1 文档里可以用一句话说明：

```text
“第三课会增加另一种导航实现，因此 Lua 业务不把 GridPos 当长期持久业务坐标。”
```

但不能因此提前创建：

```text
AgentProfile
Path
NavigationContext
Detour placeholder
几十个 interface 空文件
```

也不能大段讲它们。

## Lesson 1

只做：

```text
Unity Scene
NavMesh Authoring
Grid Sampling
Height
Area
Clearance
BMAP
Validator
Overlay
C++ BMapReader
GridMap
MapRegistry
Lua C Binding
Skynet Query
```

正式业务位置：

```text
WorldPosition mm
```

允许提供 Grid Debug API。

不做：

```text
A*
AgentProfile
Path
NavigationContext
Dynamic Occupancy
Battle
INavigationBackend abstraction
```

## Lesson 2

当第一次出现：

```text
A -> B 要寻路
```

才自然引入：

```text
AgentProfile
Path
NavigationContext
A*
DynamicOccupancy
```

课程后段，在这些概念已经有真实用途以后，再把 Grid 导航能力收敛成可替换 Backend API。

不要在 Lesson 2 开头先讲抽象类，再讲 A*。

## Lesson 3

在学习者已经熟悉：

```text
context:find_path(...)
Path
AgentProfile
```

以后，再正式引入：

```text
INavigationBackend
GridNavigationBackend
DetourNavigationBackend
```

并证明 BattleWorker 上层不需要重写。

## Unity

Server 不加载：

```text
.unity
GameObject
Rigidbody
NavMeshAgent
Animator
```

Lesson 1：

```text
Unity -> BMAP
```

Lesson 3：

```text
Unity -> NAVSRC
nav_builder -> DNAV
```

## 2.5D

```text
one XZ -> one walkable height
```

支持：

```text
坡地
丘陵
台地
普通建筑障碍
```

不支持：

```text
桥上+桥下
多层楼
地下+地面重叠
```

无法表达时 Exporter Fail。

## Static / Dynamic

Lesson 1 static GridMap 加载后 immutable。

Lesson 2 每场 Battle 才出现 dynamic occupancy。

禁止把动态单位写入共享静态地图。

## Native Thread Safety

多个 Skynet Service 可在不同 OS Thread 调用同一 Native Module。

所以：

- static GridMap 可 immutable 共享；
- A* scratch 不能 global mutable；
- Lesson 2 QueryContext 独立；
- Lesson 3 Detour QueryContext 独立。

## Lesson 2 A*

要求：

- C++；
- Binary Heap；
- no per-node heap allocation；
- generation stamp；
- 8-way 时禁止 corner cutting；
- clearance；
- slope；
- area cost；
- dynamic occupancy；
- explicit error；
- smoothing 再验证；
- 不每 Tick 重跑。

## Lesson 3

固定：

```text
Recast Navigation v1.6.0
```

职责：

```text
Recast = Offline Build
Detour = Runtime Query
```

Unity：

```text
NAVSRC
```

Standalone：

```text
nav_builder
```

Runtime：

```text
DNAV -> dtNavMesh / dtNavMeshQuery
```

不在 BattleWorker 中执行 Recast Build。

## Battle Simulation

Lesson 2 起：

```text
BattleWorker.simulate(snapshot)
```

核心模拟不执行外部 `skynet.call`。

准备 Snapshot 后：

```text
simulate no-yield
-> event
-> return
```

## Determinism

相同：

```text
battle_version
map_id
map_version
input
seed
```

得到相同逻辑 Event。

Lesson 3 再增加：

```text
navigation backend
navigation asset/build version
```

## Docs

- 中文；
- 顺真实执行链；
- 标完整路径；
- 解释 WHY；
- 不提前铺未来模块；
- 不用 AI 培训腔；
- 不重复 C++ / Lua 基础；
- 性能结论给测试条件。

## Codex

默认工程教练。

流程：

```text
当前行为
-> 需要什么
-> 实现
-> build
-> run
-> debug
-> test
-> next
```

不要为了“商业级”一次创建最终全部目录/类。

商业级来自：

```text
边界正确
错误明确
数据可验证
测试真实
后续可演进
```

不是类和模块数量。

## Do Not

- Lesson 1 不提前实现 `INavigationBackend`；
- Lesson 1 不提前创建 AgentProfile / Path / NavigationContext；
- 不把 GridPos 当长期 Lua 业务位置；
- 不把一个 MapService 做全部高频寻路代理；
- 不做 global mutable A* scratch；
- 不让 Client 结果覆盖 Server；
- 不静默升级 Skynet / Unity / Recast。
