# Engineering Decisions

## D001 - 三课主线先完成可交互战斗，Polygon NavMesh 为可选第四课

Lesson 1 / 2 完成 2.5D Grid、A*、动态占位和确定性 BattleWorker。

Lesson 3 完成人工控制 Player、Server AI GroundEnemy/FlyingEnemy、固定离地空中导航、三类技能、状态/事件同步和 Unity 表现闭环。

Recast / Detour Polygon NavMesh 移到 Lesson 4 可选高级专题。典型单层 SLG 可以长期使用 Grid；技能和空中 Air Grid 不依赖 Detour。

本文后续早期决策中写作“Lesson 3”的 Recast/Detour 内容，课程排期统一解释为“可选 Lesson 4”；其技术决策仍保留，不属于前三课前置要求。

## D002 - Navigation Backend 不在第一课提前抽象

第一课只保持两个长期约束：

```text
业务位置使用 WorldPosition
GridPos 不成为长期 Battle Contract
```

第一课实现：

```text
BMapReader
GridMap
MapRegistry
```

不提前创建 `AgentProfile / Path / NavigationContext / INavigationBackend`。

Lesson 2 在 A*、Path、动态占位和 BattleWorker 已经有真实用途以后，只稳定当前 Grid 导航调用面，不要求提前完成双 Backend。

可选 Lesson 4 再形成：

```text
INavigationBackend
├── GridNavigationBackend
└── DetourNavigationBackend
```

这是教学顺序调整，不降低最终商业架构标准。

## D003 - Lua Battle 使用 World Position

业务位置采用整数毫米：

```text
x_mm / y_mm / z_mm
```

Grid 坐标只做内部和 Debug。

这样第三课无需改 Battle API。

## D004 - 中国客户端开发基线：团结引擎 1.10.0

课程实际 Editor 固定为：

```text
Tuanjie Editor 1.10.0
Windows x64
Unity 2022.3 LTS 技术基线
```

AI Navigation 使用：

```text
com.unity.ai.navigation@1.1.7
```

课程操作时由学习者通过 Package Manager 确认或安装，并把解析结果写入 `manifest.json` / lock file；不能自行换成其他补丁版或最新版。

原因：

- 与当前中国官方发行链一致；
- 不依赖 Unity 6000.x 海外下载链；
- 2022.3 / AI Navigation 1.1 已覆盖课程需要的 NavMeshSurface、Modifier、Link、Obstacle 与 NavMesh Query；
- 可选 Lesson 4 Recast/Detour Pipeline 与 Unity 6 无强依赖。

不静默切回 Unity 6000.x。

## D005 - Skynet v1.8.0

不静默升级。

## D006 - Recast Navigation 1.6.0

第三课固定：

```text
v1.6.0
```

不跟 `main`。

原因：

- 可复现；
- 课程不是追踪上游最新 Commit；
- 资产 Builder 版本需要纳入 NavMesh Build Fingerprint。

## D007 - Recast Offline, Detour Runtime

生产链：

```text
Unity -> NAVSRC
nav_builder + Recast -> DNAV
Server + Detour -> Query
```

BattleWorker 不运行 Recast Build。

## D008 - 2.5D Single-layer

Lesson 1 / 2：

```text
one XZ -> one Y
```

多层直接 Validator Error。

## D009 - BMAP 显式 Binary Protocol

No raw struct dump。

Little Endian + CRC + version。

## D010 - NAVSRC 独立中间格式

Unity 不直接输出 Detour 内存结构。

NAVSRC 表示：

```text
triangle source
area
links
bounds
build metadata
```

Server Toolchain 可以独立重建。

## D011 - DNAV 是 Runtime Asset

DNAV 保存：

```text
format header
recast build fingerprint
map id/version
agent class
tile directory
detour tile bytes
crc
```

Detour tile 内部有自己的 magic/version，但外层仍加项目资产协议。

## D012 - Tiled Detour

第三课即使测试地图很小也走 Tiled Build。

Solo Mesh 只作为 RecastDemo 学习参考，不作为课程最终 Server Asset。

## D013 - Static Asset Immutable

Grid：

```text
BattleGridMap
```

Detour：

```text
DetourMap
```

加载后只读。

## D014 - Query State 不共享

Grid：

```text
AStarQueryContext
```

Detour：

```text
DetourQueryContext
```

都不能是 global mutable。

## D015 - Dynamic Battle Context 私有

每场 Battle 自己：

```text
NavigationContext
```

不跨 BattleWorker 共享可变 Unit Occupancy。

## D016 - Grid A* 第一版 Native

不先 Lua A*。

## D017 - Path 公共接口世界坐标化

Path Lua API：

```text
count
world_point
length_mm
segment_type
encode
```

不要把 `GridPos` 当正式 Path Contract。

## D018 - Off-Mesh Segment 是业务可见语义

Detour 的 Off-Mesh Connection 不能在 Binding 中被“压平”为普通直线。

它需要：

```text
type
user_id
start/end
```

让 Battle / Replay 决定：

```text
jump
drop
ladder
teleport
```

## D019 - Multi Agent 不是运行时 radius 一个参数就全部解决

Lesson 3 必须比较：

```text
one conservative mesh
multiple agent-class navmeshes
query filter
```

课程可实现 Small / Large 两份 DNAV 或一份保守 DNAV，最终选择必须写 Benchmark / Asset Cost 理由。

## D020 - Client Unity NavMesh 不等于 Server Detour Mesh

两边不要求 Poly 一致。

Server path authoritative。

Unity Navigation 用于：

```text
authoring validation
visual projection
presentation
```

## D021 - Unity NavMesh Triangulation 只作为 Debug

可以使用：

```text
NavMesh.CalculateTriangulation()
```

对比 Unity 可走区域。

不把它定义成长期 Server Runtime Asset。

## D022 - Nav Builder 独立命令行程序

```text
tools/nav_builder
```

输入 NAVSRC，输出 DNAV。

支持：

```text
--validate
--dump-stats
--debug-obj
```

方便 CI 和离线定位。

## D023 - Build Fingerprint

DNAV Manifest 记录：

```text
Recast version
builder git revision
build config
source crc
agent profile
tile size
cell size
cell height
slope
climb
radius
```

战报只需 map/version；构建系统可通过 Manifest 追查资产来源。

## D024 - Dynamic units 不 TileCache

普通移动单位：

```text
Battle dynamic occupancy / steering
```

不造成 Tile 重建。

TileCache 用于拓扑级临时障碍，课程第三课只做概念或一个小案例。

## D025 - Same Battle API Backend Comparison

Lesson 3 结束必须可以：

```text
battle_simulator
-> Grid Backend
```

或：

```text
battle_simulator
-> Detour Backend
```

切换而不改 Unit AI 主流程。

## D026 - Grid 仍保留

第三课完成后不删除 Grid。

它仍适合：

- 简单地图；
- 大量规则占位；
- 低成本自动战斗；
- 测试 / fallback development。

不是“Detour 比 Grid 高级，所以 Grid 废弃”。

## D027 - Benchmark 分类

Grid 与 Detour 对比只在同一：

```text
CPU
compiler
build mode
map
query set
concurrency
```

下有效。

不要跨条件做结论。


## D028 - 抽象按教学时机引入

虽然最终有 Grid / Detour 两个 Backend，但 Lesson 1 不预先实现 `INavigationBackend`。

理由：

- 当前只有一个 GridMap；
- 抽象没有第二个实现和 Path 行为支撑；
- 会增加认知成本；
- 容易形成空接口和未来式代码。

Lesson 2 当 `AgentProfile / Path / NavigationContext / FindPath` 已经工作后，只收敛当前 BattleWorker 使用的稳定 Grid 调用面。可选 Lesson 4 第一次出现第二种实现时，再从真实调用者和两个实现中提取 Backend Contract。

这是教学顺序决定，不代表最终商业架构降低标准。

## D029 - Unity 与 Server 的运行时消息使用 Protobuf

第一课增加一条低频、可观察的端到端查询链：

```text
Unity WorldPosition
-> TCP netpack frame
-> Protobuf Envelope / QueryCellRequest
-> Navigation Gateway Service
-> Navigation Query Service
-> query_logic
-> battle_nav.so
-> Protobuf QueryCellResponse
-> Unity Debug Window
```

Protobuf 只负责运行时消息，不替代 BMAP。BMAP 仍是 Unity 到 Server 的离线、版本化导航资产。

协议基线固定：

```text
Server Runtime: starwing/lua-protobuf 0.5.3
commit: ee4beb3865e2b82ea94b8a4314d78875c550ce20
C# Runtime: Google.Protobuf 3.36.2
Unity dependency: System.Memory 4.5.3
Unity dependency: System.Runtime.CompilerServices.Unsafe 4.5.3
Unity dependency: System.Buffers 4.5.1
Unity dependency: System.Numerics.Vectors 4.4.0
protoc: 36.2
frame: uint16 big-endian length (Skynet netpack) + Protobuf Envelope
max application payload: 65535 bytes
```

`.proto` 是唯一权威 Schema。Descriptor 和 C# 类型在构建阶段生成，普通 Skynet Service 启动时不编译 Schema。Codec 在接入层结束，Query Service 的业务逻辑和 Native GridMap 不依赖 Protobuf 对象。

这条链只用于第一课查询验收和后续 Unity/Server 通信基础，不把一个 MapService 设计成所有高频导航请求的永久代理。

## D030 - 在线交互与整场回放共用同一个 BattleWorker

第三课同时验证两种 SLG 战斗运行方式：

```text
在线人工操作：分段接收 PlayerCommand，按 fixed tick 推进
纯自动战斗：输入准备完成后，不等待墙钟时间，快速模拟到结束
```

两者共用：

```text
Battle state
AI
Ground/Air navigation
skill/projectile resolution
deterministic clock
ordered BattleEvent
```

在线模式持续发送 Event，并周期发送 Snapshot 用于加入、重连和状态校正。自动模式返回完整 Event Log，Unity 按逻辑时间回放。

网络收包、等待玩家输入、插值和特效不进入核心 `simulate`。禁止为在线模式和自动回放各写一套战斗规则。

## D031 - Skynet Service 入口与 Lua 模块按运行身份分目录

`service/` 只存放由 `skynet.newservice()` 或 `skynet.uniqueservice()` 启动的入口。这里的文件拥有独立 Service Context、消息队列、Lua State、生命周期和 dispatch。

`lualib/` 存放某个 Service 内部通过 `require` 加载的普通模块。`require` 只在当前 Lua State 执行并缓存模块，不创建 Service，也不产生消息边界。

因此第一课固定为：

```text
service/navigation_query.lua       Query Service 入口
service/navigation_gateway.lua     Gateway Service 入口；直接持有 socketdriver/netpack event loop
lualib/navigation/query_logic.lua  Query 内部业务模块
lualib/protocol/navigation_codec.lua  Gateway 内部 codec
```

启动者保存 `newservice()` 返回的 handle，并显式注入依赖。单节点内不通过全局名字隐藏地址关系，也不让一个 Service 用 `skynet.call` 调用自己。后续 BattleWorker、AI、技能和 Replay 文件继续按同一规则判断目录，不能按“看起来像业务组件”决定是否放入 `service/`。
