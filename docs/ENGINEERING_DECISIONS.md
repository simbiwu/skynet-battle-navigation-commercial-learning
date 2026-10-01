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
-> FlyWow TCP/WebSocket transport
-> Protobuf Envelope / QueryCellRequest
-> FlyWow Gateway Service
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
frame: TCP uint16 big-endian length + Protobuf Envelope；WebSocket binary message 直接承载 Envelope
max application payload: 65535 bytes
```

`.proto` 是唯一权威 Schema。Descriptor、C# 类型和 FlyWow `*_registry.lua` 在构建阶段生成，registry 生成器归独立 `Skynet-FlyWow` 框架所有。学习工程通过 `server/third_party/skynet-flywow` Git submodule 固定框架提交，业务仓库只提供源文件和构建输出位置；开发调试时才用 `FLYWOW_ROOT` 覆盖到 sibling 工作区。普通 Skynet Service 启动时不编译 Schema。Codec 在接入层结束，Query Service 的业务逻辑和 Native GridMap 不依赖 Protobuf 对象。

这条链只用于第一课查询验收和后续 Unity/Server 通信基础，不把一个 MapService 设计成所有高频导航请求的永久代理。

## D030 - Lesson 2 的 Gateway 与 Map/Battle Process 分离

第二课保留单进程入口作为本地调试默认，同时增加可运行的双进程验收入口：Gateway Process 由 `gateway_main` 组装 FlyWow Gateway 和本地 `gateway_proxy`；Map/Battle Process 由 `battle_main` 组装 `navigation_query`，并通过 Skynet cluster 注册 `battle_dispatch`。Gateway 只拥有客户端 fd、连接、framing 和协议编解码，Map/Battle Process 只拥有地图查询以及后续 BattleMgr/BattleWorker 的状态。

跨进程边界只传输已解码的 request/result record。cluster 节点地址、监听端口和入口名放在 `config/process_gateway.lua`、`config/process_battle.lua`，由 composition root 注入；不通过全局名字隐藏单节点依赖。`battle_dispatch` 例外属于明确的跨启动树发现合同，并要求 Battle Process 先完成 `ready` 再发布 READY 日志。Gateway Proxy 使用 `cluster.send` 转发请求，Battle 完成后向已注册的 Gateway Proxy 入口发送关联结果；route token 只用于传输关联，不是 Battle 身份。`RunAutoBattle` 客户端等待最终响应，但跨进程请求和回推均为异步 send，超时和在途数量有界。

本地脚本 `server/scripts/linux/run_lesson2_processes.sh` 负责有序启动、停止、状态检查和 doctor；默认 Gateway 端口为 19011，两个 cluster 端口为 2527/2528。该进程拆分验证部署边界，不提前创建尚未被当前行为使用的 BattleWorker 抽象；后续 BattleMgr/BattleWorker 接入 `battle_dispatch` 后，Gateway 合同保持不变。

## D031 - 在线交互与整场回放共用同一个 BattleWorker

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

## D032 - Skynet Service 入口与 Lua 模块按运行身份分目录

`service/` 只存放由 `skynet.newservice()` 或 `skynet.uniqueservice()` 启动的入口。这里的文件拥有独立 Service Context、消息队列、Lua State、生命周期和 dispatch。课程按进程角色分为 `service/gateway/` 与 `service/battle/`；其中子目录用于代码归类，OS 进程仍由 `config/skynet_*.lua` 的 `start` 入口决定。

`lualib/` 存放某个 Service 内部通过 `require` 加载的普通模块，并按消费进程归类到 `lualib/gateway/` 或 `lualib/battle/`。真正跨两类进程复用的无状态模块才放在 `lualib/shared/`。`require` 只在当前 Lua State 执行并缓存模块，不创建 Service，也不产生消息边界；即便模块源文件位于 shared 目录，进程之间也不会共享 Lua 对象。

当前目录示例：

```text
service/gateway/gateway_main.lua          Gateway 进程 composition root
service/gateway/gateway_proxy.lua         Gateway 的 Battle 转发 adapter
service/battle/battle_main.lua             Battle 进程 composition root
service/battle/navigation_query.lua        Battle 进程中的地图 Query Service
service/battle/battle_dispatch.lua         Battle 对外 Cluster 分发入口
service/flywow_gateway.lua                 FlyWow Gateway Service（来自框架仓库）
lualib/gateway/protocol/navigation_registry.lua  Gateway 构建阶段生成的 command registry
lualib/battle/navigation/query_logic.lua   Query 内部业务模块
```

启动者保存 `newservice()` 返回的 handle，并显式注入依赖。单节点内不通过全局名字隐藏地址关系，也不让一个 Service 用 `skynet.call` 调用自己。后续 BattleWorker、AI、技能和 Replay 文件继续按同一规则判断目录，不能按“看起来像业务组件”决定是否放入 `service/`。

## D033 - Skynet 是课程主线，功能裁剪不能破坏商业级边界

课程基于 Skynet 实现可演进的 SLG Server。第一次使用 `newservice`、`dispatch`、`call/send`、`register_protocol`、`PTYPE_SOCKET`、`socketdriver/netpack` 或固定版本的 `http.websocket` 等机制时，教程必须解释参数来源、Lua State、消息边界、ownership、yield、失败传播和固定版本源码依据，不能只提供可复制代码。

课程阶段允许暂不实现 TLS、账号鉴权、跨区路由、完整指标平台或最终 drain 编排，但不允许用以下 Demo 捷径换取代码量更少：

```text
无界连接、队列或并发请求
跨 yield 保存可能失效的 fd/C buffer/userdata
用全局名字隐藏本可显式注入的 Service handle
让 Gateway 同时承担地图、导航或战斗状态 Owner
同时维护两套 framing 或两套战斗规则
吞掉协议、版本、资产和业务错误
把阶段性实现描述成可以直接生产部署
```

商业级首先意味着 ownership、资源上限、错误、可观察性和演进边界正确。生产环境所需但尚未进入当前课程链路的能力必须明确列为阶段外能力，在首次产生真实用途时再引入。

## D034 - 跨端合同以版本化发布资产交付

Unity Authoring、协议生成和 Server 运行可能位于不同机器。仓库根目录 `shared/` 是课程阶段的发布边界：`shared/protocol/` 保存唯一 `.proto`、固定工具版本与可验证生成物，`shared/navigation/` 保存通过验证的 BMAP 与 manifest。

“共享”表示各端消费同一个 Git 提交、业务版本和内容哈希，不表示运行期读取另一台机器的工作目录。Unity Bake 只产生本地候选资产；完成验证、提交和推送后，Server 机器通过 Git 更新或部署包获得该版本。Server 启动不重新生成 descriptor，也不读取 Unity `BuildArtifacts`、`Assets` 或 Windows 绝对路径。

生产阶段可以把 `server/` 与所需 `shared/` 打成不可变发布包，或把相同目录迁移到制品仓库。迁移不得改变原子发布、版本固定和哈希校验语义。

## D035 - 地图、寻路与战斗模块为 2.5D 和 2D 保留同一接入方向

当前三课先实现 2.5D Ground Grid，但框架边界从现在起按多空间消费者设计。未来 H5 俯视角 2D 地图可以使用同一 Gateway、Battle Process、动态占位、确定性战斗和 Replay；业务只需选择地图资产、空间类型、寻路 profile 和客户端 Adapter。FlyWow Gateway 不知道地图维度，地图/寻路运行时不依赖网络，战斗核心不依赖 Unity、H5 或 Protobuf DTO。

第一类共同合同是整数世界/逻辑坐标、`map_id`、`map_version` 和内容 hash。地图 manifest 还必须声明 `space_type`、坐标轴、原点、Cell 尺寸和资产格式版本。长期 Path、BattleEvent 和业务位置不能暴露 `GridPos`、`grid_z` 或某个客户端的坐标轴；2.5D 的高度、2D 的固定平面和客户端坐标转换由地图空间 Adapter 负责。

Unity BMAP 和 H5/Tiled/JSON 等输入属于离线资产生产链，不能让 Server 运行时读取客户端工程目录。俯视角 2D 可以复用 Grid A* 的共同语义；横版平台的重力、跳跃和多层平台属于不同运动模型，不能把 `y=0` 当作完整支持。第二个真实地图消费者出现并通过独立测试后，才从两种实现的共同调用面提取稳定接口，不提前创建空的多维导航框架。

## D036 - WorldPosition 三轴业务坐标统一使用有符号 64 位

`WorldPosition.x_mm/y_mm/z_mm` 的业务合同统一为有符号 64 位整数毫米：Unity C# 使用 `long`，Protobuf 使用 `sint64`，Native 使用 `std::int64_t`，Lua 5.4 使用 64 位 `lua_Integer`，Replay 使用 `long`。各层传递位置时不得窄化或静默截断。Lua Binding 验证输入是整数，并依赖本项目固定的 Lua 5.4 64 位整数配置。

`GridPos` 是算法内部的 Cell 下标，仍使用独立的 32 位整数，不属于世界坐标。BMAP V1 磁盘格式的原点与 Cell 高度字段仍按既有 i32 格式读取；当前 GridMap 会把业务 WorldPosition 显式检查在 BMAP V1 可表达范围内，再做 Cell 转换。扩大资产格式范围必须另行升级 BMAP 版本，不能暗中改变文件布局。

协议兼容版本 2 曾把 WorldPosition 收窄为 `sint32`；为恢复已经确认的跨端 `int64` 合同，当前协议版本升至 3，不复用旧版本号。Gateway 与 Unity 必须同时使用版本 3；混跑版本会按 Envelope 版本校验拒绝请求。Server descriptor、Unity C# 与校验 hash 必须从同一个 `.proto` 生成并共同发布。第三课完成后可以把已验证的 Grid 地图与导航能力抽入 FlyWow；跨多种地图实现的统一导航接口仍要等真实调用者和第二种实现验证后再定。游戏专属 Battle DTO 不进入 FlyWow `common`。

## D037 - 第三课完成后将已验证能力抽入 FlyWow，不增设课程

FlyWow 的目标是面向 MMO/SLG 的 Skynet Server 框架，并提供配套的客户端接入能力。第三课完成 Server 权威在线战斗与自动战斗闭环后，再集中评估和抽取课程中已运行、已验证的通用能力；抽取不设第 3.5 课，也不作为第三课验收条件。可选第四课仍讲 Recast/Detour，不以完成 FlyWow 抽取或 H5 2D 接入为前置条件。

抽取目标是一套可分别接入、可配套使用的模块：Unity Package 同时包含地图 Bake、BMAP 导出/校验/发布等 Editor 能力，以及服务端地图、路径和战斗事件的客户端 Runtime 适配；Server 提供地图加载与版本校验、Native Grid 导航、Lua/Skynet 接入、Battle 运行机制和已验证的通用技能能力。未来 H5 俯视角 2D 客户端按同一版本化业务合同接入，其具体实现需要真实 H5 消费者验证。游戏项目保留实际地图资产、AgentProfile 数值、单位/技能规则、表现资源与项目协议配置；客户端不能覆盖 Server 权威结果。

Map、Navigation、Battle、Skill 同在 FlyWow，不意味着互相强制依赖。Navigation 使用地图查询；技能核心处理施放、冷却、目标与效果结算。单体回血或 Buff 无须地图和寻路；范围目标查询需要 Battle 单位位置及空间查询，遮挡类技能按需查询地图，冲刺/瞬移类技能按需调用导航。由 Battle 的组装入口接入这些能力，FlyWow 可以提供整套接入示例，但技能核心不依赖具体 GridMap 或 A* 实现。

常见技能可由配置组合已验证的目标选择和效果，特殊规则由业务扩展；业务仍负责伤害公式、阵营关系、特殊目标条件等项目语义。第三课不包含完整 Buff 系统，因此抽取时不能把 Buff 叠加、刷新、驱散等未验证规则宣称为现成功能。各端以 `map_id`、`map_version`、内容 hash、协议与技能配置版本对齐；公开合同、ownership、资源上限、错误路径和独立/集成测试按 `docs/FLYWOW_EXTRACTION_POLICY.md` 收口。

## D038 - Gateway 只做接入转发，在线玩家路由与指令可靠性归 Battle

Gateway 的职责是持有客户端连接、处理通用 framing/协议接入、维护把响应写回当前连接所需的会话路由，并把客户端命令转交给 Battle。Gateway 不负责权威查询玩家属于哪个 Battle/BattleWorker，也不决定命令的业务接受顺序、去重、重试、确认或恢复策略；这些状态和规则由 Battle 侧负责。

Battle 是玩家归属、战斗路由、命令可靠性和战斗状态的权威 owner。Gateway 可以保留连接生命周期和转发所需的非权威传输信息，但不能把客户端 fd、Gateway Service handle 或可复用的临时连接编号当作 Battle 身份。Battle 发回事件/响应时使用明确的逻辑会话标识和关联信息；Gateway 仅将结果投递给仍然匹配的连接，旧会话结果不得误投给重连后的新会话。

第二课已经建立双向跨进程异步转发合同：Gateway Proxy 用 `cluster.send` 将已解码请求交给 Battle Dispatch；Battle Dispatch 处理后再向注册的 Gateway Proxy 入口 `cluster.send` 结果。D039 将本地 Gateway/Proxy 合同也改为双向 send；route token 只关联返回上下文，不关联等待协程。路由表/保留时限/业务并发有界，重复或迟到回包不复用旧请求。Gateway 不持有 Battle 路由或状态，也不解释 Event。第三课复用既有 Gateway/Battle 进程边界扩展在线命令语义，不重新设计 Gateway 业务路由。

第三课在线命令不能让 Gateway 为每条实时指令同步等待整段 Battle 逻辑。Battle 侧定义命令序号、重复请求、确认、丢失检测与重连恢复合同；具体采用 `cluster.send`、`cluster.call` 或组合协议时，必须区分传输机制和业务可靠性。特别是 `cluster.send` 本身不提供送达确认，不能仅凭使用它就宣称指令可靠。

第二课 `RunAutoBattle` 的客户端仍等待完整模拟和 Replay 结果；Gateway/Battle 间使用异步 `cluster.send` + 反向 `cluster.send`，不使用 `cluster.call` 承载业务请求。

## D039 - Gateway 读取投递与响应发送独立运行

同一连接按收到的帧顺序读取、校验、解码并通过本地 `skynet.send` 投递到显式注入的 `handler_service`。投递完成后立即读取下一帧；不使用 `skynet.call` 等待业务结果。结果通过独立的 `gateway_response` 消息进入 Gateway。Gateway 只保存连接与网络资源状态，不建立业务 request/token 等待表，不处理业务超时、Cluster 节点或玩家路由。

内部响应携带 `gateway_epoch`、`connection_id`、`command_id`、`request_id` 和 `response`。Gateway 只允许配置的 handler 发送响应，拒绝旧实例或已关闭连接的结果；根据生成 registry 中的响应类型编码，按原请求编号发给客户端。实例内连接编号不复用、耗尽后拒绝接入；实例身份隔离重启前的结果。fd 不进入业务合同。

现有 `.proto` 与协议版本3保持不变。请求编号保留既有 uint64 位模式，编号0保留给已登记响应类型的主动消息；高位在 pinned Lua 中表现为负整数，也必须原样回传，不能按正负过滤，不据此宣称已支持任意独立推送类型。A/B 业务结果可以乱序，业务顺序由 Battle 负责，客户端按请求编号匹配。当前 Unity 使用单调用线程的短连接，继续兼容，不把它包装成已支持单连接并发的客户端。

课程 Proxy 保留最多64项的项目返回路由，10秒过期；记录返回上下文，不保存协程/result，不调用 wait/wakeup。容量、远程发送、结果结构或超时失败由项目映射为已有 QueryCell/RunAutoBattle 业务错误响应。失败不关闭健康连接；断线删除对应路由，重复和迟到回包丢弃。Battle 已接纳的操作不因断线自动取消。

FlyWow 的 `flywow.gateway.endpoint` 是可选薄接入模块：构造响应上下文、携带内部返回信息并单向回复；不接管 dispatch、不 fork 业务任务、不依赖 Cluster。跨进程部署由项目适配器负责。网络侧保留连接/帧/读超时/写缓冲/单连接及实例入站速率限制；速率限制不是对任意下游 Skynet mailbox 的硬容量承诺，handler 必须快速消费并在项目层限制业务在途数量。

业务主动断开使用 `context:close()` / `gateway_close`，仅携带实例与连接身份。Gateway 核对 handler 来源后先摘除连接、发出一次 disconnect，再关闭 transport；重复或失效命令忽略。跨进程通过项目 Proxy 转发，composition root 明确绑定 Gateway handle，关闭不依赖尚有效的请求 token。断线通知当前只到 handler/Proxy，不自动继续传给 Battle。响应后关闭不承诺客户端收到最后响应，业务可靠性仍归项目。

发布时先形成已验证的 FlyWow 提交，再更新课程 submodule gitlink。未获 commit 授权时使用显式 `FLYWOW_ROOT` 联调，不能把未修改的 gitlink 宣称为已经发布；旧同步 Gateway API 必须连同调用方一起迁移。回滚也需要一起回滚框架、Server handler 和配置。

## D040 - Gateway 内置无登录依赖的连接握手

FlyWow Gateway 与客户端 SDK 在连接进入 ready 前完成 P-256 ECDH、32 字节随机挑战、HKDF-SHA256 和完整 HMAC-SHA256 双向证明。每连接重新生成临时密钥和挑战，成功后释放秘密；不要求账号、宿主会话表或 Watchdog。合法协议客户端指完成握手的客户端，不附带账号授权语义。

状态机独立放在 `flywow.gateway.handshake`，Native 绑定仅链接 OpenSSL 3 的 libcrypto EVP，不链接 libssl、不启用 SSL/TLS；Gateway Service 只执行接入、发送及关闭。Unity SDK 使用固定 Bouncy Castle 2.6.2，H5 使用 Web Crypto。业务 `.proto`、Envelope 版本3及 D039 异步合同保持现状；不增加包头加密、CRC 或逐包 HMAC。

握手消息与 ready 后业务消息由连接状态区分，TCP 复用两字节长度帧，WS 使用 binary message。未 ready 不缓存或投递业务。并发握手数和总期限有界，复用既有扫描协程。连接协议不兼容旧客户端，必须双端升级，不自动降级。完整字节合同、构建、验收与未验证项见 `docs/FLYWOW_GATEWAY_HANDSHAKE.md`。
