# Skynet Battle Navigation 商业级三课实操

这是一个全新的独立课程，不属于 `Skynet-slg-learning` 主工程。

参考：

- https://github.com/simbiwu/Skynet-slg-learning

只参考它的教学组织、Codex 工程教练模式、Skynet ownership/yield 审查、测试和文档纪律；不复制旧项目业务。

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
-> Unity Replay

Lesson 3
Unity Navigation Source
-> Recast / Detour Polygon NavMesh
-> Detour Backend
-> Bridge / Multi-level / Off-Mesh Link
-> 与 Grid Backend 共用上层 Battle API
```

## 教学顺序原则

商业架构需要为第三课留下升级空间，但**不会把第三课概念提前塞进第一课**。

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
  课程后段再整理 Navigation Backend 抽象

Lesson 3:
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
- AI Navigation：`com.unity.ai.navigation@1.1`
- 具体补丁版由团结引擎 Package Manager 实际解析并记录，不再强行固定 Unity 6 的 `2.0.9`

说明：

- 文档中仍会出现 `Unity Scene`、`Unity API`、`Unity Replay` 等术语，它们表示 Unity 技术体系/兼容 API；
- 本课程实际 Editor 使用 **团结引擎 1.10.0**；
- 不要求安装 Unity 6000.x；
- Lesson 3 的 Server Polygon NavMesh 仍由独立 C++ Recast/Detour Toolchain 生成，因此不依赖 Unity 6。

### Polygon NavMesh

- Recast Navigation v1.6.0
- Recast：离线构建
- Detour：Server Runtime Query
- Lesson 3 使用 Tiled NavMesh
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

Lesson 3 再解决：

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
<workspace>/skynet-battle-navigation-unity
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
