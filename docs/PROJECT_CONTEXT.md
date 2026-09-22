# Project Context

## 学习目标

学习者已有 C++ + Lua MMO Server 经验。

本项目补齐：

```text
3D Client Map
-> Server Navigation Asset
-> Native Navigation
-> Skynet Battle
-> Client Replay
```

重点不是重新讲：

```text
TCP
C++
Lua
basic A*
```

而是：

- Unity 地图如何成为 Server Data；
- 地图格式如何版本化；
- 2.5D Grid 商业实现；
- Native Query 并发；
- Skynet BattleWorker；
- Client / Server 权威边界；
- Polygon NavMesh；
- Recast / Detour；
- 何时选 Grid，何时选 NavMesh。

## 目标游戏形态

典型：

```text
布阵
-> Battle Start
-> 自动选目标
-> 自动移动
-> 换目标
-> 进入攻击距离
-> 攻击
-> 3D Replay
```

课程不实现完整：

```text
英雄成长
Roguelike Run
复杂 Skill Editor
完整 Buff
完整 PvP
奖励
```

## 为什么 2.5D 先学

它让学习者完整掌握：

```text
Authoring
Sampling
Height
Clearance
A*
Occupancy
Path
Battle integration
```

而这些知识不会因为第三课 Detour 消失。

Recast 自己构建 NavMesh 也包含 Rasterization / Heightfield 阶段。

## 为什么第三课学 Polygon NavMesh

用于：

```text
桥上下层
多层平台
复杂不规则可走面
Off-Mesh Traversal
```

并理解商业导航系统为何不能只看“A* 算法”。

## 最终目标

三课后，学习者能 Review：

```text
Grid-based Battle Navigation
Recast/Detour Server Navigation
Skynet Integration
Navigation Asset Pipeline
```

并能解释不同方案的成本和适用边界。
