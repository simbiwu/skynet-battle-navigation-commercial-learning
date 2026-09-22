# 三课路线

## 面试主线

三课围绕一个适合主程/高级工程师面试深入追问的纵向案例展开：

```text
Authoring Source
-> Versioned Server Asset
-> Native Runtime
-> Skynet Ownership / Yield
-> Deterministic Battle
-> Client Replay
```

每课都要形成四类可展示证据：

```text
代码：边界真实落地，不是只有架构图
运行：能够 build/run/debug
测试：正常、边界、损坏和并发路径
讲解：能说明 WHY、取舍、限制和演进条件
```

## Lesson 1：先学清楚地图

目标只有：

```text
Unity 3D
-> 2.5D Logic Grid
-> BMAP
-> C++ GridMap
-> Skynet 查询
```

### 本课正式概念

```text
WorldPosition
GridPos
NavCell
GridMap
MapRegistry
```

### 最终行为

Unity 中：

```text
Ground
Slope
House
Rock
Spawn
```

导出：

```text
battle_1001.bmap
manifest.json
```

Overlay 可以看到：

```text
walkable
blocked
height
area
clearance
```

Server 加载并查询同一位置，结果一致。

Unity 通过真实 TCP/Protobuf 请求发送 WorldPosition，Skynet 查询同一份 BMAP 后返回 Cell 结果。Protobuf 是运行时消息格式，BMAP 仍是离线导航资产。

### 第一课面试输出

```text
为什么 Server 不加载 .unity / GameObject / NavMeshAgent；
为什么 BMAP 不使用 Protobuf 替代；
WorldPosition 与 GridPos 为什么不能混成长期业务坐标；
为什么 BMapReader 必须检查 magic/version/size/CRC/endianness；
为什么 GridMap 加载后 immutable；
多个 Skynet Service 在不同 OS Thread 查询同一 Native Map 时怎样安全；
为什么不让一个 MapService 成为所有高频查询的永久代理；
如何证明 Unity、Native 和 Skynet 查询结果一致。
```

### 为什么这一课不讲 AgentProfile / Path

因为当前还没有：

```text
A -> B
```

的路径需求。

Clearance 只是作为地图属性导出，先知道：

> “这个位置离障碍有多少空间。”

第二课出现不同体型时再解释 AgentProfile 如何消费它。

### 为什么这一课不正式讲 INavigationBackend

因为当前只有一种实现。

只保持两个约束：

1. Lua 正式业务坐标使用 WorldPosition；
2. Grid 类型不泄露成长期 Battle Contract。

这样已经足够为第三课保留升级空间。

---

# Lesson 2：第一次真正做导航和战斗

当需求变成：

```text
Hero A 要走到 Hero B 的攻击范围
```

才引入：

```text
AgentProfile
Path
NavigationContext
A*
DynamicOccupancy
```

顺序：

```text
Agent 有体型
-> Cell clearance 有意义

A 到 B
-> 需要 A*

A* 得到路线
-> 需要 Path

每场 Battle 有自己的 Unit Occupancy
-> 需要 NavigationContext

Target / Move / Attack
-> BattleWorker

Server Path
-> Unity Replay
```

课程后段，当 Grid 导航 API 已经稳定后，再整理：

```text
Grid Navigation API
```

为 Lesson 3 可替换 Backend 做准备。

不是 Lesson 2 开头先造抽象。

### 第二课面试输出

```text
A* 为什么使用 binary heap、generation stamp 和无 per-node allocation；
8-way 为什么禁止 corner cutting；
clearance、slope、area cost 和 dynamic occupancy 怎样组合；
为什么每场 Battle 拥有独立 NavigationContext；
为什么 simulate(snapshot) 核心阶段不能 skynet.call；
如何保证相同版本、输入和 seed 得到相同事件；
为什么不每 Tick 重跑寻路；
何时才有资格抽取 Navigation Backend Contract。
```

---

# Lesson 3：再学习 Polygon NavMesh

地图增加：

```text
Bridge
Road under bridge
Ramp
Upper Platform
Jump Link
```

2.5D Grid 明确不能表示。

此时自然引入：

```text
INavigationBackend
    ├── GridNavigationBackend
    └── DetourNavigationBackend
```

并学习：

```text
NAVSRC
Recast
DNAV
Detour
Tile
PolyRef
Corridor
StraightPath
Off-Mesh Link
```

### 生产链

```text
Unity
-> NAVSRC
-> standalone nav_builder
-> Recast
-> DNAV
-> Detour Runtime
-> same BattleWorker
```

### 第三课验收核心

Battle AI 主流程不因 Grid / Detour 改写。

如果需要大面积重写：

```text
TargetSelector
BattleWorker
EventWriter
UnitState
```

说明第二课抽象有问题。

### 第三课面试输出

```text
Recast 为什么属于 Offline Build，Detour 为什么属于 Runtime Query；
NAVSRC 与 DNAV 为什么分别版本化；
Tile、PolyRef、Corridor、StraightPath 各自解决什么问题；
dtNavMeshQuery 为什么不能作为跨线程 global mutable context；
桥上/桥下和 Off-Mesh Link 为什么超出单层 Grid 表达能力；
如何证明 BattleWorker 不因 Backend 切换而重写；
怎样用相同条件比较 Grid 与 Detour 的耗时和内存。
```

---

# 三课完成后

学习者应该能回答：

- Unity 3D 地图如何成为 Server Data；
- 2.5D Grid 为什么能做商业自动战斗；
- Height / Clearance / Occupancy 如何工作；
- A* 如何工程化；
- Skynet + Native 并发边界；
- Polygon NavMesh 为什么解决多层拓扑；
- Recast 和 Detour 分别做什么；
- 什么项目继续用 Grid；
- 什么项目应直接用 Polygon NavMesh。
