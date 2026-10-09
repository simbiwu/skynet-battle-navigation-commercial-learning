# 一次性战斗模拟与 Unity 回放完整导读

本文带读者从 Unity 发起一次自动战斗请求开始，沿 TCP、Gateway、Protobuf、Skynet Cluster、Battle、FlyWow Navigation/A* 一直跟到 Unity 播放完成。目标是能够解释每一步由哪个进程和 Service 执行、输入输出是什么、失败会在哪里暴露，以及如何亲自观察整条链路。

本文描述的是当前课程中的**一次性自动模拟**：客户端选择 Server 已登记的场景；Server 自己构造战斗输入、模拟到终局，把一整份有序事件返回；Unity 收到完整结果后再播放。它不是实时战斗推流，也不把客户端的单位位置、HP、路径或战斗胜负当作权威输入。

地图如何从 Unity Authoring 导出、如何成为 Server 可加载的 BMAP，见[《FlyWow导航构建与Battle运行链路》](FlyWow导航构建与Battle运行链路.md)。本文从地图已发布、Server 已能加载 BMAP 这个前置条件开始，专注于“一场战斗如何产生并回放”。

## 先建立完整画面

```text
Unity Battle_1001 Scene
  BattleReplayRequester
    └─ ServerBattleClient
        └─ GatewayEnvelopeClient
            ├─ Gateway 握手
            ├─ TCP 长度帧 + Protobuf Envelope
            └─ RunAutoBattleRequest(scenario_id=1001)
                    │
                    ▼
Gateway Process                         Battle Process
FlyWow Gateway                           battle_main
  解帧、解 Envelope、解 Request             ├─ navigation_query：启动时加载共享 Profile 与静态 BMAP
        │                                   ├─ battle_mgr：选 Worker
        ▼                                   └─ battle_dispatch：业务分发
gateway_proxy ── cluster.send ────────────────┘
                                                │ skynet.call("simulate", Snapshot)
                                                ▼
                                          battle_worker
                                            ├─ new_context(map)
                                            └─ battle_core.simulate()
                                                 ├─ fixed tick、目标选择、攻击结算
                                                 ├─ context:find_path_to_range() ──► Native A*
                                                 ├─ context:advance_path()       ◄── Native 移动推进
                                                 └─ 按 seq/logic_ms 追加 Battle Events
        ▲                                   │
        └────────── cluster.send ◄─────────┘  完整 BattleResult + Event Log
        │
Gateway Proxy → Gateway 编码并写回同一连接
        │
Unity 解析 RunAutoBattleResponse
  → 转为 ReplayDocument
  → BattleReplayPlayer 按 logic_ms 消费 Event
  → 沿 Server Path 做表现插值；不再寻路、不结算伤害
```

最重要的边界：Gateway 搬运消息，不懂 Battle；Battle Core 算权威结果，不懂 TCP/Protobuf/Unity；Unity 消费权威结果做表现，不重算 Server 规则。

## 一、地图资产是战斗的前置输入

**解决的问题：** A* 要在有边界、可行走区域、高度、坡度、Area 和 clearance 数据的地图上搜索，不能拿 Unity 场景对象直接当 Server 的寻路图。

1. Unity Authoring 工具采样并导出 BMAP；资产校验、发布及文件格式见[《FlyWow导航构建与Battle运行链路》](FlyWow导航构建与Battle运行链路.md)及 [BMAP 格式说明](BMAP_FORMAT.md)。
2. 当前 Battle 配置在 `server/config/battle.lua` 指定 `map_id=1001`、`map_version=1` 和发布资产 `../shared/navigation/battle_1001/battle_1001.bmap`。路径相对 `server/` 工作目录。
3. Battle Process 启动时由 `battle_main.lua` 创建 `battle/navigation_query`。该 Service 的 `query_logic.start()` 调用 `flywow_navigation.load_map()`，校验地图身份并将静态 Grid 放进 Native MapRegistry；成功后才向上报告 ready。
4. `battle_mgr`/Worker 使用同一 Battle Process 内的只读静态地图。每场模拟另有独占的 `NavigationContext`，动态占位、单位移动游标和查询 scratch 不放进共享地图。

关键文件：

| 文件 | 阅读目的 |
| --- | --- |
| `server/config/battle.lua` | 追地图 ID、版本、BMAP 路径和 Cluster 端口。 |
| `server/service/battle/battle_main.lua` | 看 Query、Manager、Dispatch 的创建顺序和 handle 注入。 |
| `server/service/battle/navigation_query.lua` | 看启动时如何加载地图，以及 QueryCell 内部查询入口。 |
| `server/lualib/battle/navigation/query_logic.lua` | 看 map_id/version 校验和 Native 查询调用。 |
| `server/third_party/skynet-flywow/navigation/lualib/flywow_navigation.lua` | Lua 对外入口；地图和 A* 实现在 Native，不在 Lua Wrapper 重写。 |
| `server/third_party/skynet-flywow/navigation/native/navigation_binding.cpp` | 看 Lua 参数、Context/Path userdata 与 C++ API 如何连接。 |
| `server/third_party/skynet-flywow/navigation/native/grid_map/grid_pathfinder.cpp` | 看实际 A*、邻居扩展、启发式、路径重建与平滑。 |

## 二、Unity 发起一次请求：场景组件到 Protobuf

**解决的问题：** 用户从 Unity 点击 Play 后，如何实际触发一场 Server 模拟，而不是从磁盘加载预先复制的 JSON。

当前示例场景是 `unity/BattleNavigation/Assets/BattleNavigation/Scenes/Battle_1001.unity`。场景上的 `BattleReplayRequester` 在 `Start()` 后台执行一次网络请求，避免同步 Socket I/O 阻塞 Unity 主线程。成功收到整份响应后才在 Unity 主线程调用 `replayPlayer.Play(...)`。

从入口向下读：

| 顺序 | 文件 | 必须看懂的内容 |
| --- | --- | --- |
| 1 | `unity/BattleNavigation/Assets/BattleNavigation/Scripts/Editor/BattleReplaySceneSetup.cs` | `AttachReplay()` 如何给已有 Scene 接入两个回放组件并连 Inspector 引用；它不启动 Server、不生成地图。 |
| 2 | `unity/BattleNavigation/Assets/BattleNavigation/client/BattleReplayRequester.cs` | `Start()`、`Task.Run`、返回后处理错误、`ConvertResult()`。它不产生 Snapshot，只把响应转换成播放器 DTO。 |
| 3 | `unity/BattleNavigation/Assets/BattleNavigation/Scripts/Protocol/ServerBattleClient.cs` | 构造 `RunAutoBattleRequest`，使用命令号 `RUN_AUTO_BATTLE=1002`，解析强类型 Response。 |
| 4 | `unity/BattleNavigation/Assets/BattleNavigation/Scripts/Protocol/GatewayEnvelopeClient.cs` | TCP 连接、握手、Envelope、request_id 校验、收发一次往返。 |
| 5 | `shared/protocol/navigation_query.proto` | 命令编号、WorldPosition、BattleEvent 和 RunAutoBattleResponse 的业务字段合同。 |

客户端传入的业务数据很少：`scenario_id=1001`。它没有上传单位坐标、属性、随机种子、地图路径或路线。场景身份只是选择 Server 上哪个已登记方案，不代表客户端获准决定战斗状态。

## 三、TCP、握手、长度帧与 Protobuf 各自做什么

这四层要分开理解：

```text
TCP Socket
  只提供有序字节流；一次 Read 不保证刚好是一条消息
  ↓
2-byte Big Endian Length Frame
  找出一条完整消息边界；长度不包括头本身
  ↓
Protobuf Envelope
  protocol_version + command + request_id + body
  ↓
业务 Protobuf Body
  RunAutoBattleRequest 或 RunAutoBattleResponse
```

连接建立后，Unity Gateway SDK 先完成 FlyWow 握手；握手帧复用长度帧，但不属于业务 Envelope。握手成功后，`GatewayEnvelopeClient.RoundTrip()` 为请求分配 request_id，将 Protobuf Request 编成 body，再构造 Envelope 和 TCP 长度帧。响应必须匹配协议版本、command 和 request_id。TCP 可能短读，因此客户端循环读取直到收满长度头和 payload；连接失败、帧非法或响应身份不匹配会抛异常。

主要文件：

- `unity/BattleNavigation/Assets/BattleNavigation/Scripts/Protocol/LengthFrame.cs`：uint16 大端长度头的打包/校验。
- `server/third_party/skynet-flywow/gateway/clients/unity/FlyWowHandshake.cs`：Unity 端 SDK 握手。
- `server/third_party/skynet-flywow/gateway/service/gateway/flywow_gateway.lua`：服务端接入、TCP/WS 帧读取、握手和业务派发。
- `server/third_party/skynet-flywow/gateway/lualib/flywow/gateway/codec.lua`：使用加载后的 descriptor 解码 Envelope/Request，并编码 Response。
- `server/third_party/skynet-flywow/gateway/lualib/flywow/gateway/registry.lua` 与 `server/lualib/gateway/protocol/navigation_registry.lua`：命令号到请求/响应 Protobuf 类型的映射与校验。

注意：ProtoBuf 负责把有类型的字段编码成 bytes；它不负责 TCP 分帧、连接、重试、Battle 路由或播放。长度帧负责字节边界；Envelope 负责通用协议头；body 才是具体业务消息。

### 当前协议源与生成代码有一处必须留意的差异

曾发现 `.proto` 与 Unity 生成代码不一致：Unity 已使用 `request_id=3`、`body=4`，但 `.proto` 曾写成 `body=3` 且缺少 request_id。现已将 `.proto` 修正为与 Unity 既有合同一致，并同步生成/校验产物；协议版本仍为 3，因为这次是恢复双方原本预期的字段合同，不是新增线上字段。Gateway、Proxy、Battle Dispatch 和测试都透传并回显 request_id；客户端据此关联同一连接上的请求与响应。

## 四、Gateway Process：网络入口和透明转发

**解决的问题：** Gateway 管好客户端连接、协议与回包地址；Battle 不接触 fd、Socket 或帧缓冲。

本项目拆成两个独立 Skynet Process：Gateway Process 与 Battle Process，各自有独立 Service、Lua State 和 Cluster 节点。`gateway_main.lua` 是组合入口：先启动 `gateway_proxy` 并确认远端 Battle ready，再创建 FlyWow Gateway、把 Gateway handle 绑定到 Proxy，最后开放监听端口。启动次序避免端口已经可连、Battle 路由却尚不可用。

收到一个已完成握手的 TCP 消息后，FlyWow Gateway 读取完整长度帧，解 Envelope，按 `command` 查生成 registry，解码 Request，然后本地 `skynet.send` 给 Proxy。Gateway 不执行 `cluster.call` 等 Battle，也不保存等待业务完成的协程；它可以继续读后续请求。Gateway 只保有本地连接身份和 transport 资源。

入口配置与源码：

- `server/config/gateway_process.lua`：Gateway Process 的 Skynet `start`、`luaservice`、`lua_path`、`lua_cpath`、`cpath`。
- `server/config/gateway.lua`：客户端监听地址/端口、协议版本、descriptor 与 registry 路径及网络边界。
- `server/service/gateway/gateway_main.lua`：组装 Proxy 与 FlyWow Gateway。
- `server/service/gateway/gateway_proxy.lua`：接收本地解码消息，将 gateway_epoch、connection_id、command_id、request_id 与业务数据用 `cluster.send` 发到 Battle；响应沿消息字段原路传回，不维护每请求 route-token 表。
- FlyWow `gateway/service/gateway/flywow_gateway.lua`：`dispatch_payload`、TCP `read_exact`/读取任务、响应投递和连接验证。

网络身份不要混淆：`fd` 是 OS Socket；`connection_id` 是 Gateway 当前实例中的逻辑连接身份；`request_id` 关联客户端一次请求与响应。它们不能代替 `battle_id`、`unit_id` 或持久业务身份。

## 五、Cluster 返回路径：为什么用了两个单向 send

Gateway 与 Battle 是不同 Skynet Process。Proxy 将入站 payload（包含 request_id）通过 `cluster.send` 送到注册的 `battle_dispatch`。Battle 完成工作后，反向 `cluster.send` 将结果和相同 request_id 送回 Proxy；Proxy 再本地发送给 Gateway。Gateway 校验来源、实例和连接仍有效后编码响应并写回原连接。响应可以乱序到达，客户端用 request_id 区分对应请求。

```text
Unity ─TCP→ Gateway ─send→ Proxy ─cluster.send→ Battle Dispatch
Unity ←TCP─ Gateway ←send─ Proxy ←cluster.send─ Battle Dispatch
```

这里的单向 send 不是说客户端收不到响应；一次请求/响应由两次独立投递和 Proxy 的有限路由上下文组合而成。`cluster.send` 本身没有可靠送达确认。断线、超时或迟到回包会按路由状态被丢弃；不自动重做战斗。

阅读：`server/service/gateway/gateway_proxy.lua` 的 `forward_to_battle()` / Battle 回包处理；`server/service/battle/battle_dispatch.lua` 的 `forward_data()` / 回包发送；再看 FlyWow Gateway 的 `deliver_response()`。补充机制见 [Gateway 异步收发说明](FLYWOW_GATEWAY_ASYNC.md) 与 [Skynet Cluster/Harbor 说明](SKYNET_CLUSTER_AND_HARBOR.md)。

## 六、Battle Dispatch：从命令号到自动战斗

**解决的问题：** 网络层只提交统一业务 payload；Battle Process 在业务边界决定这是什么命令、需要哪个 Server-side 模拟。

`server/service/battle/battle_main.lua` 先创建并等待 Query Service 和 Battle Manager ready，再创建 `battle_dispatch`，显式注入两个本地 Service handle。Battle Dispatch 注册 Cluster 服务名，成为 Gateway 跨进程请求的目标。

在 `battle_dispatch.lua` 中：

1. `dispatch_gateway()` 用生成的 command id 区分 `QUERY_CELL` 与 `RUN_AUTO_BATTLE`。
2. 对 `RUN_AUTO_BATTLE` 调用 `run_auto_battle()`；非 `1001` 场景返回 `BAD_SCENARIO`；超过 Dispatch 的在途限制返回 `BUSY`。
3. 调用 `scenario_1001.make_snapshot()`，Server 创建纯 Lua 值 Snapshot。客户端不能提交 Snapshot。
4. 通过 `skynet.call(battle_mgr, "lua", "simulate", snapshot)` 取回计算结果。这个本地调用会 yield Dispatch 消息协程，但 Battle Core 自己不 yield。
5. 检查 Event、文本和 Path 路点上限；超过单次网络结果预算则返回 `RESULT_TOO_LARGE`，不会发一份截断后假装完整的 Replay。
6. 将结果 record 通过反向 Cluster 消息交给 Gateway Proxy。

关键文件：`server/service/battle/battle_dispatch.lua`、`server/lualib/battle/scenario_1001.lua`、`server/config/battle_process.lua`。

## 七、Battle Manager / Worker：进程内服务分工

`battle_mgr.lua` 保存 Worker handle 列表，以稳定轮询选择一个 Worker。它只负责调度和调用，不运行 A*、不维护单位状态。当前 Manager 的 `simulate()` 使用 `skynet.call`，等待 Worker 返回完整结果。

`battle_worker.lua` 收到 Snapshot 后：

1. 用 `flywow_navigation.new_context(map_id)` 创建本场独占 Native Context。
2. 调 `battle_core.simulate(snapshot, context)`，内部 `xpcall` 收敛异常。
3. 无论模拟成功失败都关闭本次 Context。
4. 成功时把纯数据 result/Event Log 通过 `skynet.retpack` 返回给 Manager。

关键文件：`server/service/battle/battle_mgr.lua` 与 `server/service/battle/battle_worker.lua`。跨 Service 的 Skynet 序列化只传纯 Lua 数据；NavigationContext/Path userdata、Native 指针和网络 fd 都不跨 Service 传递。

## 八、Server 如何生成战斗，而不是只生成一条路线

`scenario_1001.lua` 提供固定测试输入：Battle 身份、地图版本、seed、Tick 周期、单位出生位置和属性、移动速度、攻击距离/伤害/冷却与 HP。它返回全新的 Snapshot，不做寻路或模拟。

`battle_core.simulate()` 创建本场 Core state，然后反复执行固定 Tick 的 `step()`，直到 `is_finished()`，最后 `finish()` 并返回。逻辑时间由固定 Tick 推进，不依赖墙钟 sleep、Unity 帧率或网络延迟；核心模拟不调用 Skynet、不做 Socket/文件 I/O、不 yield。

每个 Tick 的概念顺序可按 `battle_core.step()` 跟踪：

1. 按稳定规则选择存活敌方目标（距离相同用 unit id 稳定打破平局）。
2. 如果目标变化/移动达到重寻路条件，调用 Native `find_path_to_range()`，求可进入攻击范围的路线。
3. 有路时保存 Path，并发出 `MOVE_PATH`，其中含单位、逻辑时间、移动速度与路径世界点。
4. 每 Tick 根据速度和 tick_ms 得到整数毫米移动预算，Native `advance_path()` 沿已有 Path 推进，并提交本场动态占位。
5. 若受阻或路线终点失效，发 `MOVE_STOPPED`，必要时等待后重寻路。
6. 进入攻击范围后停止旧 Path；冷却到期时权威扣 HP 并发 `ATTACK`。目标 HP 到 0 则释放动态占位并发死亡事件。
7. 满足终止条件或到达最大逻辑时间后发 `BATTLE_END`。

Event 是顺序追加的 append-only 列表：`seq` 递增，`logic_ms` 记录事件发生的 Battle 逻辑时间。Replay 是这些事件组成的结果，不是录屏，也不是把每个画面帧都传给客户端。

## 九、A* 在哪一步执行，路线如何变成移动事件

当 Battle Core 判断需要重规划，它调用 `context:find_path_to_range(profile_id, from, target, attack_range, unit_id)`。这个调用经过 `flywow_navigation` Lua Wrapper 和 Lua C API Binding，进入 Native `NavigationContext` / `GridPathFinder`。

当前 Grid A* 的关键点：

- 8 邻接搜索；直走整数成本 1000，对角成本 1414；Binary Heap 维护待扩展节点。
- Octile Distance 是对应 8 邻接成本的启发式；它估算没有障碍时至少还需多少成本。
- AgentProfile 的 walkable、半径/clearance、Area 成本、最大台阶、最大坡度参与通行判断。
- 静态地图只读；本场的动态 Occupancy 与回调阻止不同单位占位冲突。A* 的目标是到达目标攻击距离内的合法位置。
- 搜索完成后回溯路线并做路径平滑；Path 以世界坐标点交还 Lua。A* 成本分数不等于移动毫米数或耗时。
- `find_path_to_range()` 只规划路线；后续每个 Tick 的 `advance_path()` 才按毫米预算推进并重新检查动态占位。

建议精读 `navigation/native/grid_map/grid_pathfinder.cpp` 中 `Heuristic`、`CanOccupyStaticCell`、`CanTraverse`、`SmoothGridPath`、`BuildPath` 以及实际搜索函数；再对照 `navigation/native/navigation_binding.cpp` 中 `new_context`、`find_path_to_range`、`advance_path` 对 Lua 表与 Native 类型的转换。

最容易混淆的区别：

```text
find_path_to_range  = 算“应该沿哪些点走” (A*)
advance_path        = 算“这个 Tick 实际走到哪里” (毫米预算 + 动态占位)
MOVE_PATH Event     = 把 Server 已算好的路线交给客户端表现
Unity 插值          = 沿收到的点表现移动，不调用 NavMesh/A*
```

## 十、Event Log 与 Proto Response：Server 一次性打包什么

Server 返回的核心不是内部 Lua state，也不是 Native Path userdata，而是可序列化的数据：

```text
Battle 身份/版本、地图身份/版本、seed、终局与结束逻辑时间
events[]:
  seq, logic_ms, type
  相关 unit/target/attacker/killer id
  权威伤害与 target_hp
  MOVE_PATH 的 speed_mm_per_sec 和 points[] 世界毫米坐标
  MOVE_STOPPED/UNIT_SPAWN 的 position、reason 等字段
  BATTLE_END 的 result
```

字段定义在 `shared/protocol/navigation_query.proto` 的 `BattleEvent` 与 `RunAutoBattleResponse`。`battle_dispatch.lua` 将 Lua Core result 映射成响应 record；Gateway 按生成 registry 指定的响应类型 Protobuf 编码。当前结果受业务预算限制（Dispatch 最多 100 个 Event、总 Path 点最多 200 个、事件文本最多 64 bytes），超过预算返回错误，不承诺任意规模战斗可放进单帧。

## 十一、返回原客户端连接

Worker 的结果沿调用链原路回到业务入口：

```text
Worker retpack
→ Manager 的 skynet.call 返回
→ Battle Dispatch 构造 Response record
→ cluster.send 回 Gateway Proxy
→ Proxy 使用暂存响应上下文关联原请求
→ 本地投递 Gateway response
→ Gateway 校验实例/连接/command 后 Protobuf 编码
→ 重新包 TCP 长度帧并写回 Socket
```

Gateway 写回前会验证连接身份。若客户端已断开或回包上下文过期，结果不能安全投给一条新连接，会被丢弃。客户端短连接每次只发一个请求；此课程示例不验证单连接并发请求的乱序分发。

## 十二、Unity 收到后怎样“播放”

`BattleReplayRequester` 收到 `RunAutoBattleResponse` 后：

1. 检查业务 ResultCode。失败时记录错误并不启动回放。
2. `ConvertResult()` 把 Protobuf Event 复制为 `ReplayDocument` / `ReplayEvent`，毫米坐标仍保留整数值。
3. `BattleReplayPlayer.Play()` 校验 Event 非空、seq 连续、logic_ms 非递减且没有越过 end time；有效后才替换当前表现状态。
4. Unity `Update()` 推进本地表现时钟；到某个 `logic_ms` 时应用对应事件。
5. `UNIT_SPAWN` 创建当前演示用几何体；`MOVE_PATH` 设置路线并按速度插值；`MOVE_STOPPED` 停止路线并对齐到 Server 位置；`ATTACK` 记录伤害/HP；`UNIT_DEAD` 删除显示对象；`BATTLE_END` 清除仍在进行的移动。

当前客户端只展示课程级几何体移动、攻击/结束日志和死亡删除。模型动画、特效、音频、镜头、玩家输入和生产级 Battle HUD 不属于这条回放链路的已实现能力。Unity 也不会在收到 Path 后再次运行自己的 NavMesh 寻路。

关键文件：

- `unity/BattleNavigation/Assets/BattleNavigation/client/BattleReplayRequester.cs`
- `unity/BattleNavigation/Assets/BattleNavigation/client/BattleReplayPlayer.cs`
- `unity/BattleNavigation/Assets/BattleNavigation/Scripts/Protocol/ServerBattleClient.cs`
- `unity/BattleNavigation/Assets/BattleNavigation/Scripts/Protocol/GatewayEnvelopeClient.cs`

## 十三、磁盘 JSON 与在线网络回放不是同一条传输路径

同一份 Battle result 可以由 `server/lualib/battle/replay_writer.lua` 编成 JSON 文件，`batch_runner.lua` 会调用 Manager 对固定 Snapshot 做重复模拟，并写出结果供确定性测试/人工检查。JSON 文件是离线调试/验证工件。

Unity 联网播放则是另一条入口：Requester 发送一次请求，Server 在内存完成模拟，把事件列表直接放进 Protobuf Response；Unity 不需要把 JSON 文件复制进工程。两者复用 Server Battle 模拟与 Event 格式，但 I/O/交付方式不同。

第三课在线战斗的“持续收指令、按 Tick 推进、分段输出 Event/Snapshot”属于另一种驱动方式，不应与这里的自动模拟到终局的一次性请求混为一谈。入口与当前完成范围见 [Lesson 2 Spec](../codex/LESSON_02_SPEC.md)；在线链路另见 [Lesson 3 Spec](../codex/LESSON_03_SPEC.md)。

## 十四、亲自跑通与观察

### Server 侧

在 WSL 主工作区执行：

```bash
cd /home/simbi/workspace/skynet-battle-navigation-commercial-learning/server
./scripts/lessons/run_lesson_02_processes.sh doctor
./scripts/lessons/run_lesson_02_processes.sh start
./scripts/lessons/run_lesson_02_processes.sh status
```

启动顺序应先看到 `LESSON2_BATTLE_PROCESS_READY`，再看到 `LESSON2_GATEWAY_PROCESS_READY`。`doctor` 检查已有构建/配置，不替代 build。Native 或服务二进制缺失时按 Server README 的构建入口先构建。日志可分别查看 `server/logs/lesson2/battle.log`、`server/logs/lesson2/gateway.log`。

### Unity 侧

1. 打开 `Battle_1001.unity`，确认场景里 `BattleReplayRuntime` 同时挂有 `BattleReplayPlayer` 和 `BattleReplayRequester`，Requester 的 Replay Player 引用已连接，host/port 指向本机 Gateway（当前默认 TCP `127.0.0.1:19011`）。
2. 若场景还没接入组件，在 Unity 菜单运行 `Tools/战斗导航/示例/91 接入 Battle_1001 回放`；该菜单调用 `BattleReplaySceneSetup.AttachReplay()`，不要重新执行会重建静态场景的 `CreateOrRebuild()`。
3. 进入 Play Mode。观察 Console 的 `BATTLE_GATEWAY_RESULT_LOADED events=...`，然后观察 Game/Scene 中单位移动直到 `BATTLE_END`。该日志只证明完整响应已收到；还需看完整播放到结束。
4. 将 `Scenario Id` 改成 `9999` 重试：预期是 `BAD_SCENARIO`，不应开始回放；改回 `1001` 后再测成功路径。
5. 结束后在 Server 执行 `./scripts/lessons/run_lesson_02_processes.sh stop`。

## 十五、按什么顺序阅读源码

建议每次只跟一段，不要同时跳读整仓库：

| 步 | 打开文件 | 读完应能回答 |
| --- | --- | --- |
| 1 | `BattleReplaySceneSetup.cs`、`BattleReplayRequester.cs` | 谁在何时发请求？请求前端提交了哪些字段？ |
| 2 | `ServerBattleClient.cs`、`GatewayEnvelopeClient.cs`、`LengthFrame.cs` | 握手、TCP 分帧、Envelope、Body 各负责什么？如何识别回应的是这次请求？ |
| 3 | `navigation_query.proto`、生成的 Gateway registry、FlyWow codec | 如何从 command id 找到 Request 类型？Protobuf descriptor 从哪里来？ |
| 4 | `flywow_gateway.lua`、`gateway_main.lua`、`gateway_proxy.lua` | 哪个 Service 拥有 fd？Gateway 为什么不等待 Battle？返回上下文在哪里？ |
| 5 | `battle_main.lua`、`battle_dispatch.lua` | 请求如何跨 Cluster 到达 Battle？什么字段触发自动战斗？错误如何变成业务 ResultCode？ |
| 6 | `scenario_1001.lua`、`battle_mgr.lua`、`battle_worker.lua` | Snapshot 谁创建？Manager 如何选 Worker？Native Context 谁拥有、何时释放？ |
| 7 | `battle_core.lua` | 一个 fixed tick 做什么？何时 A*？何时推进 Path？Event 的 seq/logic_ms 如何产生？ |
| 8 | `grid_pathfinder.cpp`、`navigation_binding.cpp` | A* 如何遵守地图/Profile/动态占位？Native 结果怎样变成 Lua Path？ |
| 9 | `navigation_query.proto`、`battle_dispatch.lua` | 路径与伤害如何表示成有界、可序列化的 BattleEvent？ |
| 10 | `gateway_proxy.lua`、FlyWow Gateway 回包函数 | Response 如何回到原连接？断线/迟到响应为何不能送给任意连接？ |
| 11 | `BattleReplayRequester.cs`、`BattleReplayPlayer.cs` | Unity 如何校验事件次序、按逻辑时间播放，并避免重新寻路/结算？ |

每一站都问四个问题：输入是谁创建的？当前状态归哪个 Process/Service/Lua State？调用是否 yield？失败时是业务错误、断开连接、丢弃迟到响应还是终止 Service？

## 十六、常见误解与故障定位

| 现象/问题 | 正确定位 |
| --- | --- |
| Unity 画面慢，所以 Battle Core 模拟也必须按墙钟慢速运行？ | 不必。Core 快速推进固定逻辑 Tick 并记录逻辑时间；Unity 收齐后按 `logic_ms` 播放。 |
| Unity 收到单位坐标与 Path 后可以再 NavMesh 求一条更顺的路？ | 不行。Server Path 是权威移动结果；客户端只能表现，不可改路线。 |
| `skynet.call` 出现在 Battle 完整模拟链，所以 Core 会 yield？ | 不会。Dispatch/Manager/Worker 边界可等待；Core `simulate/step` 保持 no-yield。 |
| 一个 A* Path 本身就是 Replay？ | 不是。它只表达某段移动；战斗 Replay 还包括 Spawn、停止、攻击、HP、死亡、结束等事件及逻辑时间。 |
| `BATTLE_GATEWAY_RESULT_LOADED` 就代表已经播放结束？ | 不是。它表示 Unity 收到并转换完整响应；继续确认单位播放到 `BATTLE_END`。 |
| 找不到连接/端口失败 | 查 Gateway ready 日志、host/port、Gateway Process 状态与握手。 |
| `BAD_SCENARIO` | Unity 与 Server 通了；业务场景 id 不在 Server 已登记范围。 |
| `BATTLE_FAILED` | Dispatch/Manager/Worker 模拟路径失败；查 Battle 日志及 Worker 返回的稳定错误。 |
| `RESULT_TOO_LARGE` | Event、文本或路径点超出当前单次响应预算；结果不会被静默截断。 |
| 有 `MOVE_PATH` 但单位不动/停在旧位置 | 同时核对 `MOVE_STOPPED`、事件顺序、logic_ms、坐标单位和 Unity Path 插值；先确认 Server Event 本身正确。 |
| descriptor/type decode 错误 | 核对协议源、Server descriptor、Gateway registry、Unity 生成 C# 是否同一版本；先处理本文“协议差异”提示。 |

## 掌握后应能不看文档讲清楚

1. Unity 请求里只有 `scenario_id`；Snapshot 与所有权威单位属性由 Server 生成。
2. TCP 是字节流，长度帧找边界，Protobuf 编/解字段，Envelope 路由类型和关联请求；这几层不可混为一谈。
3. Gateway 拥有 Socket，Battle Dispatch 按命令执行业务；跨进程用双向异步 Cluster 消息，Proxy 保存有限响应上下文。
4. Worker 为每场模拟拥有一个 Native NavigationContext；静态 BMAP 可只读复用。
5. A* 规划 Path，Native `advance_path` 才逐 Tick 推进并提交动态占位；Battle Core 将权威变化追加为带 `seq` 与 `logic_ms` 的事件。
6. Server 一次返回完整有界 Event Log；Unity 按事件时间表现 Server 结果，不反向决定寻路或战斗胜负。
7. 当前实现是固定场景的自动模拟与课程级 Unity 回放；生产级连续在线战斗流、数据库持久化与完整演出系统是不同能力。
