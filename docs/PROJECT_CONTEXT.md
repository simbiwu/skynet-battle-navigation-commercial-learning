# Project Context

## 学习者与求职目标

学习者已有多年 C++ / Lua / MySQL MMO Server 经验，做过技术经理或主程；目标岗位是 Skynet SLG Server 主程或高级工程师。

因此课程不降低到语言语法和基础网络教学，也不要求学习者转型为 Unity 客户端工程师。Unity 只学到能够理解资产来源、亲自完成关键生产步骤、定位 Client/Server 边界问题和完成联调验收。

面试训练不以“写了多少类”为标准，而以能否用真实代码和测试回答以下问题为标准：

```text
为什么这样分服务和数据 ownership？
哪些路径会 yield，yield 前后哪些状态必须稳定？
Native 数据如何被多个 OS Thread 安全访问？
资产、协议和战斗版本如何绑定并拒绝不兼容输入？
哪些结论有单元测试、集成测试、并发测试或 benchmark 证据？
线上出错时怎样从日志、错误码和版本信息定位？
当前方案何时适用，何时必须演进？
```

## 专题学习目标

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

## 三课完成后的面试输出

三课后，学习者不仅能 Review：

```text
Grid-based Battle Navigation
Recast/Detour Server Navigation
Skynet Integration
Navigation Asset Pipeline
```

并能解释不同方案的成本和适用边界。

还应能完成一次 20～30 分钟的项目陈述：

```text
1. 业务问题与约束
2. Unity -> Server 的资产生产链
3. BMAP / NAVSRC / DNAV 的版本与校验
4. Native Core / Lua Binding / Skynet Service 的 ownership
5. Battle simulate no-yield 与确定性事件
6. Grid 到 Detour 的演进理由
7. 测试、性能条件、已知限制与下一步
```

回答时必须区分“已经通过工程证明的行为”和“未来可以做的设计”，不能用架构名词替代证据。
