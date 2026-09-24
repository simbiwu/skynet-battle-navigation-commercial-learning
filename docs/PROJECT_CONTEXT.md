# Project Context

## 学习者与求职目标

学习者已有多年 C++ / Lua / MySQL MMO Server 经验，做过技术经理或主程；目标岗位是 Skynet SLG Server 主程或高级工程师。

因此课程不降低到语言语法和基础网络教学，也不要求学习者转型为 Unity 客户端工程师。Unity 只学到能够理解资产来源、亲自完成关键生产步骤、定位 Client/Server 边界问题和完成联调验收。

课程不能假设 Server 开发者天然理解 Unity 坐标、Transform、World/Local Space、Inspector 序列化、NavMesh Query 或 SceneView。相关概念在首次使用前完成 Server 视角桥接；每个核心文件先标出学习目标和精读范围，再进入完整代码。

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
- 地面 AI、固定离地空中 AI 与 NoFly；
- 权威技能、弹丸、Battle Snapshot / Event；
- 何时继续使用 Grid，何时进入可选 Polygon NavMesh 专题。

## 目标游戏形态

前三课的最小可运行验证场景：

```text
人工控制 Player 提交移动/施法意图
+ GroundEnemy 由 Server AI 控制
+ FlyingEnemy 由 Server AI 控制
-> Server 权威移动、技能、伤害和死亡
-> Unity 显示三者移动、弹丸与技能事件
```

该场景是 SLG 战斗内核的最小验证沙盒。正式 SLG 可以把单个 Object 扩展为英雄、士兵或编队，并把人工操作降为低频指令；Server 权威、AI、导航、技能和事件边界保持不变。

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

这些知识会直接被第三课的地面 AI、空中 AI 和技能系统使用。

Recast 自己构建 NavMesh 也包含 Rasterization / Heightfield 阶段。

## 为什么 Polygon NavMesh 放到可选第四课

用于：

```text
桥上下层
多层平台
复杂不规则可走面
Off-Mesh Traversal
```

并理解商业导航系统为何不能只看“A* 算法”。典型单层 SLG 可以只完成前三课，长期使用 Grid。

## 三课主线完成后的面试输出

三课后，学习者不仅能 Review：

```text
Grid-based Ground/Air Navigation
Server-authoritative Skill and Projectile
Skynet BattleWorker / AI / Sync
Unity Navigation Asset and Battle Presentation
```

并能解释客户端意图与 Server 权威结果、表现型和逻辑型弹丸、地面 Grid 和 Air Grid 的成本与适用边界。

还应能完成一次 20～30 分钟的项目陈述：

```text
1. 业务问题与约束
2. Unity -> Server 的资产生产链
3. BMAP、Ground/Air Navigation 数据的版本与校验
4. Native Core / Lua Binding / Skynet Service 的 ownership
5. Battle simulate no-yield 与确定性事件
6. Player、GroundEnemy、FlyingEnemy 和技能事件的完整执行链
7. 测试、性能条件、已知限制与下一步
```

回答时必须区分“已经通过工程证明的行为”和“未来可以做的设计”，不能用架构名词替代证据。
