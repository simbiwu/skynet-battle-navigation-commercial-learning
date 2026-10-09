# 三课主线路线与可选高级课

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

学习者以 Server 工程经验为前提，不默认熟悉 Unity。Unity 坐标轴、World/Local Space、Transform、Inspector 序列化、NavMesh Query 和 SceneView 等概念必须在第一次操作或代码使用前完成桥接；核心文件先给学习目标和精读范围，再给完整代码。

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

这样已经足够为后续技能、空中导航和可选导航后端保留演进空间。

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

为后续业务继续使用稳定导航入口做准备。此时不要求为了 Detour 提前完成双 Backend。

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
如何在没有第二种实现时只稳定 Grid 调用面，不提前制造双 Backend。
```

---

# Lesson 3：分别掌握帧同步与状态同步

第三课从第二课完成基线出发，按顺序完成两份独立实操：

1. [帧同步版实操](Skynet_BattleNavigation第三课_帧同步版_实操.md)：以确定性逻辑帧输入为主，学习输入确认、预测、回滚重演、分歧恢复和帧输入回放。
2. [状态同步版实操](Skynet_BattleNavigation第三课_状态同步版_实操.md)：以 Server 权威状态复制为主，学习命令确认、BattleEvent、周期 Snapshot/Delta、本地预测校正、远端插值和断线恢复。

两版允许采用不同玩法和战斗模拟实现，不为共用而建立统一 Battle Core。它们都保留商业实时战斗的核心边界：客户端快速响应，Server 决定正式位置、寻路、技能、命中、伤害、HP、死亡和结果；版本、资源上限、错误路径、恢复行为与真实 Unity/Server 验证都属于课程内容。具体玩法和施工阶段以 `codex/LESSON_03_SPEC.md` 及对应实操为准。

Lesson 2 的离线批量模拟与 Replay 保持独立，不要求帧同步版、状态同步版和批量模拟共用战斗核心。旧版第三课实操仅作为知识点参考，不再作为实施基线。

---

# Lesson 4（可选）：Polygon NavMesh

只有项目出现桥上/桥下、多层平台、复杂不规则地面或 Off-Mesh Traversal 时，才进入 Recast/Detour：

```text
Unity NAVSRC
-> standalone nav_builder + Recast
-> DNAV
-> Detour Runtime
-> 与 Grid 共用上层 Battle API
```

本课不是前三课交互战斗闭环的前置条件。典型单层 SLG 可以长期使用 Grid。

---

# 三课主线完成后

学习者应该能回答：

- Unity 3D 地图如何成为 Server Data；
- 2.5D Grid 为什么能做商业自动战斗；
- Height / Clearance / Occupancy 如何工作；
- A* 如何工程化；
- Skynet + Native 并发边界；
- 玩家输入与 Server AI 如何进入同一个权威 BattleWorker；
- 地面与固定离地空中导航怎样并存；
- 瞬发、表现型弹丸和逻辑型弹丸怎样划分 Server 职责；
- Snapshot、Event 与 Unity 表现怎样组成可调试闭环；
- 什么项目继续用 Grid，什么条件下才需要可选的 Polygon NavMesh。
