# Skynet Cluster 与 Harbor：进程间通信专题

本文是独立的 Skynet 通信参考文档，不属于第二课正文。第二课使用双向 `cluster.send` 加有界 route token 的关联结果；本文解释 Skynet 的两种集群机制、传输边界和生产系统需要自行承担的可靠性合同。

本文以项目固定的 Skynet v1.8.0 为技术基线。Skynet 官方文档明确提醒：Cluster 不会抹平分布式系统的本质，框架提供的是组网基础设施，不是完整的服务发现、故障转移和业务可靠性方案。[Skynet 官方 Cluster 文档](https://github.com/cloudwu/skynet/wiki/Cluster) · [Skynet v1.8.0 启动代码](https://github.com/cloudwu/skynet/blob/v1.8.0/service/bootstrap.lua)

## 1. 先分清三个层次

```text
Skynet Service
  一个 actor：自己的消息队列、Lua State、生命周期

Skynet Process / Node
  一个操作系统进程：容纳多个 Service，共享进程内运行时

Skynet Cluster
  多个可独立运行的 Skynet Process / Node 通过网络通信
```

`service/`、`lualib/` 目录名不会创建 OS 进程；启动配置的 `start` 入口和 composition root 决定一个进程启动哪些 Service。`skynet.call` 是 Service 间消息调用，`cluster.call` 是跨 Cluster 节点的请求-响应调用。两者 API 看上去相似，但远程调用额外经过网络、节点发现和序列化边界，不能因此把两者当成相同成本或相同故障语义。

## 2. Harbor 与 Cluster 是两套不同机制

| 机制 | 核心作用 | 常见形态 | 本项目当前双进程示例 |
|---|---|---|---|
| Harbor master/slave | 把多个 Skynet 节点组织成一个带全局 Service 地址/名字的网络；底层消息可按全局地址转发 | 一组节点由 master 协调，各节点有 harbor ID | 未启用；配置 `harbor = 0` |
| `skynet.cluster` | 让独立节点按节点名和显式 Service 地址/名字进行 RPC 或单向发送 | 每个节点独立配置对端地址，按需建立 Cluster 连接 | 正在使用；Gateway 与 Battle 各自 `cluster.open()`，再调用对方 |

两者可以组合，但不是一回事，也不是先开 Harbor 才能用 Cluster。官方 Cluster 文档将单节点 `harbor = 0` 的独立节点列为一种直接的 Cluster 部署方式。`harbor = 0` 只表示不加入 master/slave Harbor 网络；它不会关闭 `skynet.cluster`。[Skynet 官方 Cluster 文档](https://github.com/cloudwu/skynet/wiki/Cluster)

### 2.1 Harbor 做什么

Harbor 的 master/slave 机制把多个 Skynet 进程编成一个较统一的 Service 地址空间。每个节点有 harbor ID，Service 地址中携带所属节点信息；跨节点消息由 Skynet 核心路由到 Harbor 服务。全局名字也依赖这个网络。

它适合节点集合相对稳定、位于受控网络、希望使用 Skynet 全局地址/名字和透明跨节点消息的部署。它不是自动容错集群：节点之间的联系是整体运行前提之一；官方说明中，断开的 harbor ID 不应随意复用，否则其他节点可能仍持有旧地址。它也不会替业务做玩家归属迁移、战斗恢复、请求去重或数据复制。

Harbor 暴露的 `harbor.link(id)`、`harbor.linkmaster()`、`harbor.connect(id)` 等接口可用于监视节点/主节点连接状态，但它们不是业务命令的确认协议。应由少数基础监控组件观察网络状态，再把状态通知业务层，避免每个业务 Service 各自建立一套网络监控。

### 2.2 Cluster 做什么

Cluster 将节点配置成具名对端，例如 `gateway`、`battle`，再由调用方指定节点名和目标 Service。常用操作：

```lua
cluster.open(listen_port, max_clients) -- 本节点监听 Cluster 连接
cluster.reload(node_config)            -- 装载/更新节点名到地址的映射
cluster.register(name, handle)          -- 注册 Cluster 可见的 Service 名
cluster.call(node, service, ...)        -- 远程请求并等待返回值
cluster.send(node, service, ...)        -- 远程单向发送
cluster.proxy(node, service)            -- 创建远程 Service 代理
```

`cluster.register("battle_dispatch", handle)` 注册的是 Cluster 模块自己的远程名字；调用 `"@battle_dispatch"` 明确查询这个注册表。点号开头的 `".local_name"` 表示目标节点的本地名字。应优先使用清晰、稳定的远端注册名或节点内显式名字，而不是把运行时 Service 数字地址写进部署配置。

Cluster 是去中心化配置：每个调用方需要知道目标节点名及地址，Skynet 不替项目自动同步所有节点的配置。地址变化后要有配置发布/重载流程，并考虑在途请求仍可能属于旧连接/旧地址。[官方 Cluster 配置与命名说明](https://github.com/cloudwu/skynet/wiki/Cluster#cluster-config-update)

## 3. `cluster.call`、`cluster.send` 与 TCP 连接

### 3.1 `cluster.call` 是请求-响应

```text
Gateway Service                         Battle Service
      |                                       |
      | cluster.call("battle", "@dispatch", request)
      |---------------- request ------------->|
      |                                       | 处理请求
      |<--------------- response -------------|
      | 得到返回值，继续当前 Lua 协程          |
```

调用方等待的是目标 Service 的回复。Skynet Lua 协程在等待期间会 yield，让出当前 Service 的执行权；这不是把整个 OS Thread 睡死。不过当前调用流程仍然被挂起，调用方仍须面对远程延迟、远端失败、超时策略和资源占用。

远程断连或找不到服务时，调用可能抛错；需要在明确边界捕获并转换成稳定的错误合同。**不能把 `cluster.call` 的等待理解成自动有界的业务超时**：业务必须明确请求的 deadline、取消/过期行为和失败返回。调用返回失败也不总意味着远端一定没执行——例如远端已处理、但响应途中连接断开时，调用方无法仅凭异常判断业务是否提交。

### 3.2 `cluster.send` 是单向消息

```text
Gateway/某 Service  -- cluster.send(command) -->  Battle Service
          立即返回；没有该调用对应的业务 response
```

`cluster.send` 适合不要求本次 API 直接取得响应的单向投递，但它本身不提供送达确认、业务重试、持久化、去重或 exactly-once。发送端可能在连接断开时无法知道消息是否到达。Skynet 官方文档也明确指出跨节点 `send` 有丢消息风险。[官方 Cluster send 说明](https://github.com/cloudwu/skynet/wiki/Cluster#cluster-mode)

如果一条命令不能丢，应用协议必须补齐确认与恢复机制，例如：稳定 `command_id`、玩家/会话世代号、递增序号、服务端去重窗口、ACK、超时重发、过期拒绝以及重连后状态对账。重发必然可能造成重复，所以接收端要幂等或去重。不要声称 TCP 或 `cluster.send` 单独提供业务 exactly-once。

### 3.3 双向通信为什么可能出现两条 TCP 连接

TCP 连接本身是全双工的：建立一条连接后，双方都能在这条连接上发送字节。Skynet Cluster 的使用方式还涉及“哪个节点主动建立到哪个对端的 Cluster 通道”。当 A 调用 B 时，通常由 A 建立/使用 A→B 的出站通道，B 的响应沿该请求连接返回；这一次 `cluster.call` 并不需要再为 response 额外建一条反向连接。

如果 B 之后也要主动向 A 发起独立请求/推送，B 需要建立/使用 B→A 的出站通道。此时两节点之间可能各有一条方向相反的 TCP 连接。它们不是一条 TCP 不能双向传输，而是 Cluster 的节点通道按发起方向建立和管理；每个节点都可以既监听对端连接，也主动连接对端。Skynet 官方文档也指出双向请求/推送可能形成两条 TCP 连接，并且两个方向的消息不保证相互排序。[官方 Cluster 消息次序说明](https://github.com/cloudwu/skynet/wiki/Cluster#message-order-between-clusters)

因此要区分：

```text
A -> B 的一次 call + B 的 response：通常复用这次请求的连接往返
A -> B 的独立流量 + B -> A 的独立主动流量：可能分别使用 A->B、B->A 两条连接
```

两条连接不会自动代表“双份可靠性”或“消息更有序”。相反，跨方向的事件和响应可能竞争到达，业务协议应携带序号、关联 ID 或版本，让接收方判断先后和有效性。

### 3.4 顺序与大消息

不要把 TCP 的字节有序误当成所有 Cluster 业务消息全局有序。单方向、同一连接上的普通消息通常按发送序到达，但官方文档指出，大包分块传输可能导致后发的小包先完成；两方向使用不同连接时，两方向消息更不具备相对次序保证。因此业务需要自己定义命令序号、状态版本或事件顺序，不要依赖“谁先 send 就一定先处理完”。

避免把大量/超大数据结构放进 Cluster 消息。使用有界 request/result record；大型静态地图和 Native userdata 不跨节点传输。共享资产应由各进程按 `map_id`、`map_version`、内容 hash 分别加载/校验，或使用明确的资产分发流程。

## 4. 超时、断连、重试与健康状态

Skynet Cluster 提供连接与远程消息基础，不提供完整的应用级韧性策略。设计时逐项回答：

| 问题 | 应用需要定义的语义 |
|---|---|
| Deadline | 请求最晚何时仍有意义；过期请求如何拒绝；调用方如何停止等待/释放关联状态 |
| 结果不确定 | 连接断开但远端可能已提交时，如何用 `command_id` 查询/重放而不重复结算 |
| 重试 | 哪些错误可重试、退避与上限、重试期间是否允许后续命令越过 |
| 顺序 | 玩家命令序号、并发请求排序、跨连接事件排序和旧会话隔离 |
| 去重 | 接收端持有多长的去重记录，进程重启后状态如何恢复 |
| 重连 | 重连后如何重绑定玩家会话、获取权威 Snapshot、补发/丢弃未确认命令 |
| 健康检查 | 进程存活、Service ready、链路可用、业务可服务分别如何判定 |
| 过载 | 队列/并发上限、拒绝策略、客户端背压与降级 |

TCP keepalive、连接错误、Cluster 调用错误可帮助发现部分故障，但不能替代业务 ACK、deadline 和恢复合同。`ready` RPC 只能证明启动阶段某个 Service 已达到约定状态；它不是持续健康检查，也不证明后续每个玩家请求都可成功。

实践上，自动模拟、管理查询等明确需要完整结果的有限操作可以用 `cluster.call`；高频实时命令通常让 Gateway 快速转发，Battle 异步接收、排队/校验并主动回推事件或 ACK。具体采用 `call`、`send` 或组合方式是实现选型，责任边界和可靠性语义必须先定义。

## 5. Gateway 与 Battle：把概念放回本项目

第二课的两进程验收结构如下：

```text
Unity / test client
   | 客户端 TCP（协议帧）
   v
Gateway Process                         Battle Process
 gateway_main                              battle_main
   | gateway_proxy                          | navigation_query
   | cluster.send -------------------------> | battle_dispatch
   |            <------ cluster.send -------| (route_token + result)
```

这里 Gateway 与 Battle 都配置 `harbor = 0`，但各自打开 Cluster 监听端口，通过 `cluster.reload()` 配置对端并注册服务。因此它们是两个独立 Skynet 进程，通过 Cluster 通信；它们没有加入 Harbor master/slave 网络。第二课的 `RunAutoBattle` 要等待整场自动模拟和 Replay 结果，但 Gateway 只负责透明转发：请求通过 `cluster.send` 到 Battle，Battle 完成后通过反向 `cluster.send` 回推结果，Proxy 以有界 route token 等待表关联本地原请求。启动时的 `ready` 检查仍是单独的控制面请求-响应。

第三课在线战斗的职责边界不同于第二课验收链路：

```text
Client -> Gateway: 连接、帧解析、通用协议接入
Gateway -> Battle: 透明转发命令和必要的非权威连接会话标识
Battle: 玩家归属、Battle/Worker 路由、命令顺序/去重/可靠性、权威战斗状态
Battle -> Gateway -> Client: ACK、BattleEvent、Snapshot 或错误
```

Gateway 不查玩家属于哪个 Battle，不持有 Battle 权威状态，也不决定命令业务顺序。Gateway 必须保留足够的连接会话信息来把 Battle 的回推送到正确的当前连接，但不能把 fd 或可复用连接号当作玩家/Battle 身份。Battle 通过逻辑会话 ID 加会话世代/关联 ID 回推，Gateway 校验目标仍是同一会话，避免断线重连后把旧结果发给新连接。

若 Battle 主动向 Gateway 推送，Battle 会使用反向 Cluster 通道；从 TCP 角度看可能出现 Gateway→Battle 与 Battle→Gateway 两条连接。一次 `cluster.call` 的响应则属于该调用，不等价于 Battle 后续独立推送。实时命令不必为每个 Tick 建立一轮“Gateway 同步等 Battle 完整处理”的 RPC；可将接收 ACK 与最终事件拆开，并明确其 ID、序号、超时和恢复规则。

## 6. 本项目当前配置与调用链

```text
server/config/skynet_gateway.lua
  harbor = 0
  start = "gateway/gateway_main"

server/config/skynet_battle.lua
  harbor = 0
  start = "battle/battle_main"

server/config/process_gateway.lua
  Gateway 的 Cluster listen、Battle 节点名/地址、远端 Service 名

server/config/process_battle.lua
  Battle 的 Cluster listen、对外注册名
```

启动入口负责组装本进程 Service。`battle_main` 在 Query/Manager/Dispatcher ready 后 `cluster.reload()`、`cluster.open()` 并 `cluster.register()`；Gateway Proxy 用 `cluster.reload()` 装载远端节点，通过 ready 调用确认 Battle 启动完成。业务请求路径使用 `cluster.send()`，结果由 Battle 反向 `cluster.send()` 回推；Proxy 的本地等待受并发上限和 deadline 限制。这不等于生产级健康检查或实时命令可靠性协议。

当前端口、调用链和责任约束见 [Lesson 2 实操文档](Skynet_BattleNavigation第二课_从Grid寻路到Skynet自动战斗_实操.md)、[Lesson 3 Spec](../codex/LESSON_03_SPEC.md) 和 [Engineering Decisions D038](ENGINEERING_DECISIONS.md)。

## 7. 常见误解

1. **“两个进程用了 Skynet，就天然在同一个 Harbor 集群。”** 不对。看 `harbor` 配置和启动拓扑；本项目 `harbor = 0`，使用的是 Cluster API。
2. **“TCP 是可靠的，所以 `cluster.send` 可靠。”** 不对。TCP 只在连接仍成立时提供字节流传输语义；断连时应用可能不知道消息是否已被远端处理，`cluster.send` 没有业务 ACK。
3. **“`cluster.call` 抛错，远端肯定没执行。”** 不对。请求可能已经执行但响应丢失；有副作用的操作必须使用请求 ID、幂等/去重和结果查询。
4. **“A 调 B 的 response 必须再开一条 B→A TCP。”** 不对。response 可沿本次请求连接返回；独立反向请求/推送才可能需要反向连接。
5. **“用了 Harbor/Cluster 就有服务发现、故障转移和玩家迁移。”** 不对。它们提供不同层次的节点通信/寻址基础；业务路由、可靠性、状态复制和故障恢复仍需应用定义。
6. **“Gateway 应负责找玩家在哪个 Battle。”** 不符合本项目已确认的边界。Gateway 只接入与转发；玩家归属、Battle/Worker 路由与命令可靠性由 Battle 侧权威负责。

## 8. 官方参考

- [Skynet Cluster Wiki](https://github.com/cloudwu/skynet/wiki/Cluster)：Harbor master/slave、Cluster 调用、配置、命名、消息次序和 `send` 丢失风险。
- [Skynet v1.8.0 `service/bootstrap.lua`](https://github.com/cloudwu/skynet/blob/v1.8.0/service/bootstrap.lua)：固定版本下 `harbor`、`cmaster`/`cslave`、单节点启动路径。
- [Skynet v1.8.0 `lualib/skynet/cluster.lua`](https://github.com/cloudwu/skynet/blob/v1.8.0/lualib/skynet/cluster.lua)：Cluster Lua API 实现入口。
- [Skynet v1.8.0 `service/clusterd.lua`](https://github.com/cloudwu/skynet/blob/v1.8.0/service/clusterd.lua)：Cluster 连接与请求处理 Service。
