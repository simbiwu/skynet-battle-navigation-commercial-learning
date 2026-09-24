# Skynet Battle Navigation 三课主线实操

这是一个全新的独立课程，不属于 `Skynet-slg-learning` 主工程。

参考：

- https://github.com/simbiwu/Skynet-slg-learning

只参考它的教学组织、Codex 工程教练模式、Skynet ownership/yield 审查、测试和文档纪律；不复制旧项目业务。

## 课程定位

本项目面向有多年 C++ / Lua / MySQL 和 MMO Server 经验、准备应聘 **Skynet SLG Server 主程或高级工程师** 的学习者。它不是 Unity 客户端转岗课程，也不是完整 SLG 产品开发教程。

三课用一个可以运行、调试和测试的专题工程，训练面试中真正需要讲清楚的能力：

```text
客户端地图如何成为可信 Server Asset
Skynet Service ownership / yield 边界
C++ Native Module 的线程安全与内存边界
静态地图与每场战斗动态状态的分离
确定性战斗、事件与 Replay
Protobuf 协议、版本和错误处理
性能测试、回归、损坏资产与并发测试
地面/空中导航、权威技能和客户端表现边界
```

Unity 在本项目中只有两个角色：离线资产生产工具和联调/回放客户端。评价重点始终是 Server 设计、证据和取舍，而不是场景美术或客户端表现技巧。

三课不是 SLG Server 面试知识的全部。AOI、世界地图分片、行军定时器、联盟/跨服、MySQL 持久化与幂等、网关与断线恢复、部署监控等属于后续专题；本项目先把导航与战斗这一条纵向链做深。

## 从这里开始

- 第一课：[从 Unity 地图到 Skynet 查询](docs/Skynet_BattleNavigation第一课_从Unity地图到Skynet查询_实操.md)
- Git 入门：[VS Code Git 实操（面向 SVN 使用者）](docs/VS_CODE_GIT_FOR_SVN.md)

仓库当前只初始化本地 `main` 分支。远程仓库地址由项目所有者之后提供。

## 三课路线

```text
Lesson 1
Unity 3D Scene
-> 2.5D Logic Grid
-> BMAP
-> C++ GridMap
-> Skynet 查询
-> Unity / Server Protobuf 验证

Lesson 2
2.5D Grid
-> C++ A*
-> AgentProfile
-> NavigationContext
-> Path
-> Dynamic Occupancy
-> BattleWorker
-> Server AI
-> Unity Replay

Lesson 3
Player Command + GroundEnemy AI + FlyingEnemy AI
-> Ground Grid / Air Grid / NoFly
-> 瞬发、表现型弹丸、逻辑型弹丸
-> Server 权威伤害与死亡
-> Battle Snapshot / Event
-> Unity 完整显示移动和技能

Lesson 4（可选）
Unity Navigation Source
-> Recast / Detour Polygon NavMesh
-> Bridge / Multi-level / Off-Mesh Link
```

第三课使用同一个确定性 BattleWorker 支持两种运行方式：人工操作时按命令和 fixed tick 分段推进，发送 Event 并周期发送 Snapshot；纯自动 SLG 战斗时快速模拟到结束，返回完整 Event Log 供 Unity 回放。网络和回放层不能各自复制一套战斗结算。

## 教学顺序原则

商业架构需要保留升级空间，但**不会把后续课程概念提前塞进第一课**。

概念首次正式出现：

```text
Lesson 1:
  WorldPosition
  GridPos
  Cell
  BMapReader
  GridMap
  MapRegistry

Lesson 2:
  AgentProfile
  Path
  NavigationContext
  DynamicOccupancy
  A*
  BattleWorker
  Server AI
  Unity Replay

Lesson 3:
  PlayerCommand
  SkillDefinition / SkillRuntime
  Projectile
  AirNavigationMap / NoFly
  Battle Snapshot / Event Sync

Lesson 4 optional:
  INavigationBackend 正式形成双实现
  GridNavigationBackend
  DetourNavigationBackend
  Recast / Detour
  Polygon / Tile / PolyRef / Corridor / Off-Mesh Link
```

第一课只解决一个问题：

> Unity 3D 地图如何变成 Server 真正能查询的 2.5D 逻辑地图。

不会为了未来扩展而提前学习无当前用途的抽象。

## 固定技术基线

### Server

- Linux / WSL2
- Skynet v1.8.0
- Skynet bundled modified Lua 5.4.7
- C++14
- CMake

### Client Editor（中国开发基线）

- 团结引擎 1.10.0
- 技术基线：Unity 2022.3 LTS
- AI Navigation：`com.unity.ai.navigation@1.1.7`
- 不静默升级 Unity、AI Navigation、Skynet 或 Recast

说明：

- 文档中仍会出现 `Unity Scene`、`Unity API`、`Unity Replay` 等术语，它们表示 Unity 技术体系/兼容 API；
- 本课程实际 Editor 使用 **团结引擎 1.10.0**；
- 不要求安装 Unity 6000.x；
- 可选 Lesson 4 的 Server Polygon NavMesh 由独立 C++ Recast/Detour Toolchain 生成，因此不依赖 Unity 6。

### Polygon NavMesh

- Recast Navigation v1.6.0
- Recast：离线构建
- Detour：Server Runtime Query
- 可选 Lesson 4 使用 Tiled NavMesh
- 不在 BattleWorker 运行期执行 Recast Bake

## 为什么先学 2.5D

2.5D 本身就是可用商业方案，适合：

```text
自动战斗
RTS / SLG 地面导航
坡地
丘陵
单层竞技场
单位占位
动态阻挡
```

可选 Lesson 4 再解决：

```text
桥上 / 桥下
多层平台
复杂立体拓扑
Off-Mesh Traversal
```

## 第一版商业要求

功能可以少：

```text
1 张地图
少量单位
2 个 Agent Profile
简单攻击
```

但边界不能做成 Demo：

- 版本化地图资产；
- CRC；
- 显式字节序；
- static / dynamic 分离；
- Native Core / Lua Binding 分离；
- deterministic battle；
- benchmark；
- regression；
- corruption test；
- concurrent query；
- Unity Debug Overlay；
- map version pin。

## 推荐工作区

Unity：

```text
Windows:
G:\simbi\dev\skynet-battle-navigation-commercial-learning\unity\BattleNavigation
```

Server：

```text
WSL:
~/workspace/skynet-battle-navigation-server
```

## Codex 第一条指令

```text
先完整阅读根目录 AGENTS.md、docs/ 和 codex/。
这是全新的独立 Battle Navigation 三课项目，不合并旧 Skynet-slg-learning。

特别注意教学顺序：
Lesson 1 只学习 Unity -> 2.5D Grid -> BMAP -> C++ GridMap -> Skynet Query。
不要提前向我讲 AgentProfile、Path、NavigationContext、INavigationBackend 的完整设计。
这些概念在真正需要时再引入。

按照 codex/CODEX_START_HERE.md 检查现场，然后逐阶段辅导我亲手完成。
不要一次性生成最终项目。
```
