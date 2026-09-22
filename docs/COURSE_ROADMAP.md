# 三课路线

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
