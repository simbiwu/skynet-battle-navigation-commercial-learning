# AGENTS.md - Skynet Battle Navigation 三课主线与可选高级课

## P0

课程训练：

```text
Unity 3D Authoring
-> Server Navigation Asset
-> C++ Navigation
-> Skynet Battle Simulation
-> Unity Replay
```

功能可简化，工程边界不能用 Demo 捷径替代。

## 独立项目

参考：

```text
https://github.com/simbiwu/Skynet-slg-learning
```

只参考教学方法、工程纪律、Skynet ownership/yield、测试和文档风格。

禁止合并旧工程或复制旧业务。

## 可抽取的 Skynet Server 模块

课程首先完成当前真实链路，同时把已经成熟、与具体 SLG 业务无关的能力设计成以后可抽取到独立 Skynet Server 框架 `skynet-flywow` 的模块。抽取时不应重写核心实现，也不应要求网络、地图、热更等模块互相依赖。

`skynet-flywow` 使用独立 Git 仓库，当前本机编辑源为：

```text
~/workspace/skynet-flywow
```

学习项目与框架仓库按阶段协作：

```text
课程中的真实问题
-> 在课程链路中实现、运行、调试和测试
-> 判断是否与具体业务无关
-> 在 skynet-flywow 中整理公开合同、独立测试和接入示例
-> 再由课程或其他商业项目通过公开边界接入
```

禁止直接用一个仓库的目录覆盖另一个仓库。抽取时分别修改、验证和提交两个仓库，保留各自的历史、版本和适配层；框架远端固定为 `https://github.com/simbiwu/Skynet-FlyWow.git`，只有用户明确要求提交或同步时才 Push。

预期可以独立复用的方向包括：

```text
网络接入与连接生命周期
协议 framing / codec / dispatch
配置、日志、指标和错误合同
Service 启停与依赖注入
代码或配置热更、状态迁移与回滚
静态地图资产加载与查询
导航查询运行时
测试、诊断和部署工具
```

模块依赖必须形成单向、可解释的 DAG：

```text
composition root
  -> 独立基础模块
  -> 少量稳定公共合同
  -> Skynet / Lua / Native 等固定运行时依赖

业务模块 -> 基础模块
基础模块 -X-> Battle / SLG 具体业务
网络模块 -X-> 地图或导航模块
地图或导航模块 -X-> 网络模块
```

`common` 只能放真正稳定、被多个模块共同需要的最小合同，例如错误结构、版本标识和少量值类型。禁止把它变成无归属代码、业务 DTO、全局状态或循环依赖的收容目录。

每个准备复用的模块在课程中达到稳定边界时，都要能回答：

```text
公开 API 和版本合同是什么
允许依赖什么，禁止依赖什么
状态、Service、Lua State、native 对象和 buffer 由谁拥有
配置怎样注入，是否依赖全局名字或固定路径
怎样启动、停止、重载、回滚和报告失败
怎样单独 build / test / benchmark / diagnose
怎样从课程仓库打包或迁移到另一项目
```

可抽取不等于提前建立空框架。继续遵守“架构预留 ≠ 提前教学”：只有当前课程出现真实调用者、实现已经工作、边界能由测试证明时，才整理稳定接口和模块目录。第一次真实实现直接遵守正确的 ownership、依赖方向和错误合同，避免以后靠大改拆除业务耦合。

课程工程仍然是独立、可运行的完整仓库，不在教学过程中强制依赖另一个尚未发布的个人框架。后续抽取优先采用保留历史和测试的迁移方式；共享源码的具体发布形态（独立仓库、包、submodule 或其他方式）等出现第二个真实消费者后再决定。

## 本机双工作区职责

本项目在当前开发机使用两个完整 Git worktree，但每类文件只有一个编辑源，禁止同时维护两份实现：

```text
G:\simbi\dev\skynet-battle-navigation-commercial-learning
  docs/、unity/、shared/navigation/、shared/protocol/generated/unity/、codex/、根目录课程文档和文档生成工具的编辑源

~/workspace/skynet-battle-navigation-commercial-learning
  server/、shared/protocol/ 源文件与 Server 生成物的编辑源
```

两边通过 Git 提交同步，不把 `/mnt/g/...`、Windows 盘符、WSL home 或另一工作区路径写进 Runtime 配置。跨端共享资产遵守后文“跨端共享合同与发布资产”规则；双工作区只是一种本机开发安排，不是部署拓扑。

WSL 中必须保持完整主仓库结构，Server 位于：

```text
~/workspace/skynet-battle-navigation-commercial-learning/server/
```

禁止把 `service/`、`lualib/`、`native/`、`protocol/` 等目录另建为独立 Git 仓库。旧的 `~/workspace/skynet-battle-navigation-serve` 不再作为开发源。

执行规则：

- 文档、课程规范和 Unity 修改只在 G 盘主仓库进行；
- `server/` 下的 Lua、C++、协议、配置、构建脚本和测试只在 WSL 主仓库进行；
- G 盘的 `server/` 只通过远端 Git 更新，不直接编辑；
- 跨文档与 Server 的任务分别在各自编辑源修改并验证，不用目录复制覆盖另一侧的未提交工作；
- Commit/Push 前检查两个 worktree 的分支、HEAD、未提交修改和远端分叉；同一远端分支的提交必须串行同步，禁止两边基于旧 HEAD 分别 Push；
- 没有用户明确的“开始、修改、执行、更新、同步”等指令时，只讨论，不修改任何文件。

## Learner

可以默认学习者：

- 熟悉 C++ / Lua；
- 有 MMO Server 经验；
- 已理解 Skynet Service / Lua State / call/send/dispatch；
- 关注性能、并发、内存、部署和维护；
- 不需要基础语法教学。

# 最重要的教学规则：架构预留 ≠ 提前教学

三课主线先完成可交互的 Server 权威战斗闭环。Polygon NavMesh 是 Lesson 4 可选高级专题，不能因此提前让学习者理解当前行为尚未需要的抽象。

概念首次正式出现时间固定：

```text
Lesson 1:
  WorldPosition
  GridPos
  NavCell
  BMapReader
  GridMap
  MapRegistry

Lesson 2:
  AgentProfile
  Path
  NavigationContext
  DynamicOccupancy
  Grid A*
  BattleWorker
  Server AI
  Unity Replay

Lesson 3:
  PlayerCommand
  SkillDefinition / SkillRuntime
  Projectile
  AirNavigationMap
  NoFly
  固定离地高度
  Battle Snapshot / Event Sync

Lesson 4 optional:
  INavigationBackend 双实现
  GridNavigationBackend
  DetourNavigationBackend
  Recast / Detour
```

Lesson 1 文档里可以用一句话说明：

```text
“后续可能增加另一种导航实现，因此 Lua 业务不把 GridPos 当长期持久业务坐标。”
```

但不能因此提前创建：

```text
AgentProfile
Path
NavigationContext
Detour placeholder
几十个 interface 空文件
```

也不能大段讲它们。

## Lesson 1

只做：

```text
Unity Scene
NavMesh Authoring
Grid Sampling
Height
Area
Clearance
BMAP
Validator
Overlay
C++ BMapReader
GridMap
MapRegistry
Lua C Binding
Skynet Query
```

正式业务位置：

```text
WorldPosition mm
```

允许提供 Grid Debug API。

不做：

```text
A*
AgentProfile
Path
NavigationContext
Dynamic Occupancy
Battle
INavigationBackend abstraction
```

## Lesson 2

当第一次出现：

```text
A -> B 要寻路
```

才自然引入：

```text
AgentProfile
Path
NavigationContext
A*
DynamicOccupancy
```

课程后段，在这些概念已经有真实用途以后，只收敛当前 BattleWorker 需要的稳定 Grid 导航调用面。双 Backend 抽象留到可选 Lesson 4 首次接入 Detour 时再引入。

不要在 Lesson 2 开头先讲抽象类，再讲 A*。

## Lesson 3

目标是形成一个可运行的 Server 权威战斗验证场景：

```text
Player（人工输入，Server 权威执行）
GroundEnemy（Server AI）
FlyingEnemy（Server AI）
```

必须能够在 Unity 中完整观察：

```text
三者移动
地面与空中目标选择
技能施放
弹丸飞行
伤害、HP 与死亡
Server 状态和事件同步
```

空中导航采用二维 XZ Air Grid：

```text
NoFly 决定 XZ 是否可进入
worldY = groundHeight + flightHeight
```

支持三类技能执行模型：

```text
瞬发技能
只需客户端表现的定时弹丸
轨迹影响命中结果的 Server 权威弹丸
```

玩家客户端只能发送移动和施法意图，不能提交权威位置、命中、伤害或死亡结果。技能表现可以简化，但完整执行链和 Client/Server 边界不能省略。

Lesson 3 不要求 Recast/Detour，不要求完整 3D Voxel Navigation，不实现桥上/桥下空中体积查询。

## Lesson 4（可选高级课）

在学习者已经熟悉：

```text
context:find_path(...)
Path
AgentProfile
```

以后，再正式引入：

```text
INavigationBackend
GridNavigationBackend
DetourNavigationBackend
```

并证明 BattleWorker 上层不需要重写。该课不属于前三课交互战斗闭环的前置条件。

## Unity

Server 不加载：

```text
.unity
GameObject
Rigidbody
NavMeshAgent
Animator
```

Lesson 1：

```text
Unity -> BMAP
```

Lesson 4：

```text
Unity -> NAVSRC
nav_builder -> DNAV
```

## 2.5D

```text
one XZ -> one walkable height
```

支持：

```text
坡地
丘陵
台地
普通建筑障碍
```

不支持：

```text
桥上+桥下
多层楼
地下+地面重叠
```

无法表达时 Exporter Fail。

## Static / Dynamic

Lesson 1 static GridMap 加载后 immutable。

Lesson 2 每场 Battle 才出现 dynamic occupancy。

禁止把动态单位写入共享静态地图。

## 跨端共享合同与发布资产

Unity、Server 和离线工具共同依赖的内容必须以仓库根目录 `shared/` 为唯一版本化来源：

```text
shared/protocol/    .proto、固定版本和各端可验证生成物
shared/navigation/  Unity 验证通过并准备发布的 BMAP 与 manifest
```

共享指的是同一个 Git 提交、发布版本和内容哈希，不是共享某台机器的实时目录。Unity Bake 只更新当前工作区的候选资产；验证、提交和推送后，Server 所在机器通过 Git 或发布包取得同一版本，新的资产才可生效。真实部署必须允许 Unity、构建机和 Server 位于不同机器。

要求：

- `.proto` 只有一份源文件；Unity C#、Server descriptor 和校验文件必须从它生成并在同一次提交中更新；
- Server 启动和部署只消费已发布生成物，不在启动时临时生成另一份协议合同；
- BMAP 与 manifest 成对发布，目录按地图 ID 隔离；Server 不读取 Unity `Assets/`、Library、临时 Bake 目录或 Windows 绝对路径；
- 本地双工作区只能用来开发和验证，不能成为运行时架构前提；
- 后续若改用制品仓库，仍必须保留版本、哈希和原子发布语义，不能退回人工复制“当前最新文件”。

## Native Thread Safety

多个 Skynet Service 可在不同 OS Thread 调用同一 Native Module。

所以：

- static GridMap 可 immutable 共享；
- A* scratch 不能 global mutable；
- Lesson 2 QueryContext 独立；
- Lesson 4 Detour QueryContext 独立。

## Skynet 工程目录与运行身份

目录必须表达 Lua 文件的真实运行身份：

```text
service/
  只放由 skynet.newservice / skynet.uniqueservice 启动的 Service 入口。
  入口拥有独立 Service Context、消息队列、Lua State、生命周期和 dispatch。

lualib/
  只放在某个 Service Lua State 内由 require 加载的普通模块。
  require 不创建 Service，不创建消息队列，也不形成跨 Service 边界。

protocol/
  放 .proto 等协议源、版本清单和生成物；运行期 require 的 codec 放 lualib/protocol/。

config/
  放进程配置和只读业务配置；配置文件不能伪装成 Service 或运行时状态 Owner。
```

禁止：

- 把只会被 `require` 的模块放进 `service/`；
- 用 `worker`、`agent`、`gateway` 等名字把普通模块伪装成独立 Service；
- 通过 `skynet.register` 给当前 Service 起名，再从同一个 Service `skynet.call` 自己；
- 用全局服务名隐藏本可由启动者显式传递的 Service handle；
- 在 `protocol/` 下放通过 `require` 加载的运行期业务模块。

启动者默认保存 `newservice()` 返回的 handle，并把 handle 显式注入调用方。只有存在明确的跨启动树发现需求时才注册名字；单节点本地名字使用 `.` 前缀，并说明唯一性、重启和冲突处理。

## Skynet 教学与商业级实现

本课程的核心是基于 Skynet 实现可演进的 SLG Server。Skynet 不能只作为“能把 Lua 跑起来的容器”，也不能只给最终代码让学习者照抄。每个 Skynet 核心机制第一次在真实链路中出现时，必须就地讲清：

```text
它解决的当前问题
它属于哪个 Service / Lua State
调用者、接收者和状态 Owner
回调参数与返回值从哪里产生
消息经过 pack / unpack / dispatch 的顺序
哪里可能 yield，yield 前后哪些引用仍然有效
内存、fd、buffer、queue 或 userdata 的 ownership
失败怎样传播，是否回包、断连或终止启动
固定 Skynet 版本中可以核对的源码与官方示例位置
如何通过日志、断点和负向测试验证
```

至少覆盖课程中实际使用的：

```text
newservice / uniqueservice
Service handle 显式注入
require 与独立 Lua State 的区别
skynet.start
skynet.dispatch
skynet.call / skynet.send / skynet.retpack
skynet.register_protocol
session / source / command / ... 的来源
PTYPE_SOCKET
socketdriver / netpack
Service 消息协程与 yield
```

动态 Lua/C 边界不能依赖 IDE 猜测。教程应给出稳定公式和源码依据。例如自定义接收协议必须说明：

```text
dispatch 参数 = session + source + unpack(msg, sz) 的全部返回值
```

并解释 `unpack`、`dispatch`、可选 `pack` 的职责。IDE 注解、命名函数和类型 stub 用于提高开发效率，不能替代协议合同。

### Lua 可变参数限制

项目自有 Lua 源码默认禁止把 `...` 用作函数参数、返回转发或稳定模块接口。该限制覆盖 `service/`、`lualib/`、协议/构建脚本和教程中要求学习者复制的 Lua 代码，不只限于 Gateway。

Skynet 或 C 模块返回可变参数时，适配层必须用固定数量的命名槽位接收，并按 command/event 显式映射到语义函数：

```lua
dispatch = function(_session, _source, queue, event, arg1, arg2, arg3)
    if event == "open" then
        SOCKET.open(arg1, arg2)
    elseif event == "data" then
        SOCKET.data(arg1, arg2, arg3)
    end
end
```

跨 Service 和跨模块接口优先使用：

```text
固定位置参数；或
command + 一个带 Lua Language Server 注解的 request record；或
一个明确 result record
```

禁止：

- 从 Service dispatch 把 `...` 原样继续传给业务函数；
- 用 `table.pack(...)` / `{...}` 隐藏未定义的长期接口；
- 把可变参数保存到闭包、table、异步任务或跨 yield 使用；
- 仅以“Skynet 示例这样写”为理由保留项目内的动态签名；
- 在教程完整代码中使用 `...` 代替本来已知的业务参数。

只有职责本身就是“转发未知签名”的通用基础设施才可申请例外。例外必须局部、写明 WHY 和参数/ownership 约束、不得进入业务模块，并有针对参数数量、nil 洞、返回值和 yield 的测试。当前课程代码没有默认例外白名单。

性能结论必须区分 Lua VM 的 vararg 访问与 `table.pack/unpack` 产生的额外分配，并给出固定 Lua/Skynet 版本、调用次数、参数数量和 GC 条件。即使性能差异不显著，可读性、IDE 支持和重构安全仍足以作为默认禁用理由。

功能可以按课程范围简化，架构和运行边界不能为了少写代码而简化。所谓商业级，至少要求：

- 状态 Owner、生命周期和跨 Service 边界明确；
- 输入、协议版本、资源上限和错误结果显式；
- 队列、连接、并发请求和内存增长有界；
- yield 前后重新验证可能失效或复用的身份；
- C buffer、userdata、fd、queue 和动态状态有明确释放路径；
- 接入层、业务模拟、静态资产和动态状态分离；
- 启动、停止、日志、调试、测试和故障路径可观察；
- 后续扩展通过稳定边界演进，不靠复制第二套业务逻辑。

第一课 Gateway 即使只承载低频 `QueryCell`，也必须采用正确接入层边界：

```text
socketdriver + PTYPE_SOCKET + netpack
Gateway Service 独占 listen/client fd 与 connections
netpack C message 在任何 yield 前转成 Lua string 或释放
fd close/reuse 后用 connection object identity 防止旧协程误写
max frame / max clients / per-connection in-flight / write warning 有界
malformed/version/command/body 显式拒绝
Query Service handle 由 main 显式注入
```

课程可以明确暂不实现 TLS、账号鉴权、跨区路由、全量限流策略、指标平台或最终 drain 编排，但必须标注这些是阶段外能力，不能把缺失能力包装成“已可直接生产部署”。也不能为了看起来完整而提前创建尚未被当前行为使用的模块。

## Lesson 2 A*

要求：

- C++；
- Binary Heap；
- no per-node heap allocation；
- generation stamp；
- 8-way 时禁止 corner cutting；
- clearance；
- slope；
- area cost；
- dynamic occupancy；
- explicit error；
- smoothing 再验证；
- 不每 Tick 重跑。

## Lesson 4（可选高级课）

固定：

```text
Recast Navigation v1.6.0
```

职责：

```text
Recast = Offline Build
Detour = Runtime Query
```

Unity：

```text
NAVSRC
```

Standalone：

```text
nav_builder
```

Runtime：

```text
DNAV -> dtNavMesh / dtNavMeshQuery
```

不在 BattleWorker 中执行 Recast Build。

## Battle Simulation

Lesson 2 起：

```text
BattleWorker.simulate(snapshot)
```

核心模拟不执行外部 `skynet.call`。

准备 Snapshot 后：

```text
simulate no-yield
-> event
-> return
```

同一个核心模拟必须支持两种驱动：

```text
在线交互：分段接收 PlayerCommand，按 fixed tick 推进，输出 Event + 周期 Snapshot
自动战斗：输入准备完成后快速模拟到结束，输出完整 Event Log 给 Unity Replay
```

网络收包、等待玩家输入和 Unity 播放不进入核心 `simulate`。两种模式不能各写一套 AI、导航或技能结算。

## Determinism

相同：

```text
battle_version
map_id
map_version
input
seed
```

得到相同逻辑 Event。

Lesson 3 再增加：

```text
skill definitions/version
player commands
battle snapshots/events
air navigation asset version
```

Lesson 4 使用 Detour 时再增加：

```text
navigation backend
navigation asset/build version
```

## Docs

- 中文；
- 顺真实执行链；
- 标完整路径；
- Skynet 核心机制第一次出现时必须解释运行合同、参数来源、ownership、yield 和固定版本源码依据，不能只给可复制代码；
- 每个文件步骤必须明确标注“新建文件、完整替换、局部修改或只读”，不能只给路径和代码让学习者猜操作；
- 每节围绕一个当前实际问题组织，按“为什么现在需要 -> 最小必要概念 -> 实际操作 -> 谁会使用 -> 验证”推进；
- 每节只要求学习者新增或修改当前链路马上会使用的文件。未来步骤才需要的类型、常量和工具，延后到首次真实使用处再引入；
- 每次要求新建、替换或修改文件前，先用简短白话说明“为什么需要这个文件、哪个步骤会直接使用它、完成后能看到什么结果”；没有这些信息，不得给出文件操作指令；
- 不以最终目录结构或代码清单驱动教学，不连续要求学习者机械新建文件；若工具代码不是学习者当前目标，提供可运行工具并说明输入、输出和操作，不要求逐文件手写实现；
- 对以后新增场景的目标，优先讲清场景约束、资产生成入口、产物和验证方式；不要让后端学习者为理解资产生产链而先实现整套 Unity Editor 工具。
- 正文用自然、直接的陈述句；避免反复使用“不是……而是……”等模板化对照句。确有必要区分两个概念时，先分别说清它们各自是什么。
- 学习者有资深 C++/Lua Server 背景；优先用 struct/record、二维逻辑网格、一维数组、索引和序列化等熟悉的工程概念解释。简单的数据组织先用几句话和一个小例子讲清，不把它扩写成术语导览。
- 解释 WHY；
- 不提前铺未来模块；
- 不用 AI 培训腔；
- 不重复 C++ / Lua 基础；
- 性能结论给测试条件。

面向已有 Server 经验但不熟悉 Unity 的学习者时，Unity/客户端概念必须在第一次成为当前步骤前置条件时解释，不能要求学习者从代码反推。首次解释至少包含：

```text
是什么
在 Unity 哪里观察
与熟悉的 Server 概念如何类比
为什么当前步骤需要
属于 Authoring / Asset / Client Runtime / Server Runtime 哪个边界
一个具体数值例子
常见误解
```

每个核心代码文件在完整代码前必须给出：

```text
本文件解决的问题
本节必须掌握的概念
必须精读的类型/字段/函数
可以略读的语法或样板
输入、输出和失败条件
运行验证
理解自测
```

代码注释不能替代这层学习导航。

坐标、偏移量或边界在课程中首次举例时，先用非负数建立计算模型。必须使用负数前，先解释坐标零点、负轴方向以及“负坐标不等于非法坐标”，再代回当前工程的真实数值。

坐标轴、世界/局部空间、Bounds、Grid Cell、2.5D 限制、NavMesh 采样等空间关系首次出现时，必须在相邻正文提供图示。图示必须标注方向、起点、单位和关键边界，并紧跟一段“读图要点”；不能用纯装饰截图代替概念图。

空间概念优先复用同一张底图逐步增加标记，不能连续更换坐标、数值、视角和比喻。先让学习者能在图上指出对象和关系，再给精确公式；公式用于把已经理解的空间关系写成代码，不用于建立第一印象。

任何类名、文件名或工具链列表出现前，必须先用一句直白的业务职责回答“它解决什么问题”。不能在过渡段先列出 `BattleMapRoot / Sampler / Validator / Writer` 等名字，再要求学习者到后文猜职责。

教程是面向所有学习者的独立可发布文档，不得写入“你之前的理解”、“我们刚才讨论”、“根据本次反馈”等依赖历史对话的措辞。修改原因只体现为更清晰的正文结构，不将编辑过程写进课程。

## Code Comments

课程代码使用中文注释解释领域语义，不要求学习者靠通读整个函数反推变量作用。

每个源码、脚本、协议和构建文件必须在文件头提供总体说明，适用于 C#、C++、Lua、Shell、PowerShell、Proto 和 CMake。文件头至少说明：

```text
本文件解决的问题
所属边界（Authoring / Asset / Client Runtime / Server Runtime / Build / Test / Debug）
主要输入和输出
生命周期、所有权或运行时机
明确不负责的事情
```

文件头使用该语言的普通注释，不写容易失真的作者、日期、手工版本号，也不重复文件名或逐句翻译代码。文件职责或边界变化时，必须同步更新文件头。

变量注释的位置遵守以下规则：

- struct/record 字段、Lua 配置项、Proto 字段等简短数据定义，优先使用同行尾注释，让类型、名字、单位和范围一次可见；
- 局部变量的语义能用短句说清时使用同行尾注释；涉及 WHY、所有权、算法不变量或多步计算时，放在相邻上方；
- C# Inspector 字段带 `[SerializeField]`、`[Min]`、`[Header]` 等 Attribute 时，详细领域注释放在 Attribute 上方，避免 Attribute 割裂字段与说明；
- 不为了强行同行而写超长行；超过一个短句的说明改为紧邻上方注释。

函数注释是强制要求，不能只靠函数名或函数体让学习者反推。每个函数、方法、构造函数、协议/脚本入口都必须在定义前说明职责；公开函数、跨模块入口和包含领域判断的私有函数还必须完整说明：

```text
函数解决的具体问题
每个参数的业务意义、单位、坐标系、合法范围和所有权（适用时）
返回值各状态的意义和所有权（适用时）
显式失败条件、错误码或异常
是否执行 I/O、分配内存、加锁、yield 或修改共享状态
复杂度、前置条件或调用时机（适用时）
```

C# 公共 API 和课程核心私有函数优先使用 XML Documentation 的 `summary`、`param`、`returns`、`exception`；C++ 使用紧邻声明或定义的统一函数注释；Lua、Shell、PowerShell 也必须在函数或入口前写清参数与返回/退出约定。无参数、无失败分支的简单属性访问器或薄包装函数可以只用一行说明，不能完全省略，也不能用大段样板掩盖关键函数。

函数内部的关键代码必须解释领域 WHY，包括坐标换算、取整方向、边界判定、字节 offset/stride、CRC 覆盖范围、资源所有权、锁/yield 边界、半包/粘包状态和算法不变量。注释应放在对应逻辑之前；不能只在函数头笼统写“处理数据”。

必须注释：

- 类型职责、生命周期和所属边界（Authoring / Asset / Runtime / Debug）；
- 每个成员字段的用途、单位、坐标系、合法范围，以及是否进入资产或网络；
- 方法参数、返回值和显式失败条件；
- 非显然局部变量承载的中间语义；
- `x/z/index/offset/size/count` 对应 Grid、数组还是 byte；
- 集合、缓冲区的元素语义、所有者和生命周期；
- 算法不变量、WHY、复杂度和适用限制。

禁止只翻译语法的无效注释，例如：

```cpp
// 遍历数组
for (...) { }

// 返回结果
return result;
```

代码行为、单位或数据布局变化时必须同步更新注释、文档和测试。

## Codex

默认工程教练。

流程：

```text
当前行为
-> 需要什么
-> 实现
-> build
-> run
-> debug
-> test
-> next
```

不要为了“商业级”一次创建最终全部目录/类。

商业级来自：

```text
边界正确
错误明确
数据可验证
测试真实
后续可演进
```

不是类和模块数量。

## Do Not

- Lesson 1 不提前实现 `INavigationBackend`；
- Lesson 1 不提前创建 AgentProfile / Path / NavigationContext；
- Lesson 2 不提前创建 SkillRuntime、Projectile 或 AirNavigationMap；
- Lesson 3 不把客户端位置、命中或伤害当作权威结果；
- Lesson 3 不用地面 Walkable 直接代替 Air NoFly 规则；
- 不把 GridPos 当长期 Lua 业务位置；
- 不把一个 MapService 做全部高频寻路代理；
- 不做 global mutable A* scratch；
- 不让 Client 结果覆盖 Server；
- 项目自有 Lua 稳定接口和业务调用不使用 `...`；
- 不静默升级 Skynet / Unity / Recast。
