# Skynet Battle Navigation 专题实操：Gateway/Battle 链路韧性与战斗持久化

本专题承接第二课的双进程 `cluster.send`/反向 `cluster.send`，以及第三课的在线 `BattleWorker`、`PlayerCommand`、有序 Event 和 Snapshot。它回答一个新问题：**已经确认给玩家的命令与战斗进度，在网络断开或 Battle 进程重启后怎样保持可解释、可恢复？**

这是一份独立的进阶专题，不改变前三课和可选第四课的完成条件，不要求在第三课开始前先接入数据库。实施前先完成第三课在线战斗与确定性回归；只有真实的 `BattleWorker`、命令序号和 Snapshot/Event 合同存在后，才按本专题逐阶段增加持久化。FlyWow 抽取仍按原有课程完成后的边界执行。

本专题采用 **Redis 中间缓存 + MySQL 8.4 LTS / InnoDB 最终持久化 + 独立 Skynet DB 进程**。这是学习商业 Skynet SLG 服务端数据链路的明确课程选型，不根据当前练习项目规模反推选型。Skynet、Lua、C++、Unity、导航依赖的固定版本保持仓库既有基线。实施时固定 Redis 补丁版本，记录两种存储的配置和数据格式版本；不把密码、开发机绝对路径或数据库连接藏进 Battle Core。SQL 表结构与 Redis key 格式都是本专题的初始版本，后续变更必须走显式迁移。

这里的「DB 进程」指第三个 **Skynet OS 进程**，负责数据访问与缓存一致性；Redis Server 和 MySQL Server 各自是外部服务。这个进程由 `server/config/skynet_db.lua` 的 `start` 入口组装，不因为把 Lua 文件放进 `service/db/` 就自动产生进程。进入实际编码阶段前，须同步更新 `AGENTS.md` 的进程角色目录约定和 `docs/ENGINEERING_DECISIONS.md` 的已确认选型；本文现在只规定实操步骤。

## 完成后可观察什么

1. Gateway 与 Battle 之间断开任一方向的连接，Gateway 能在有界时间内进入降级状态；请求得到明确的失败或“结果不确定”状态，等待表不会无限增长。
2. Battle 接受并确认的命令写入 MySQL 持久化日志。重复发送同一个 `command_seq` 不会重复执行；不同内容复用同一序号会拒绝。
3. Battle 进程在命令提交、Tick 提交、回包前后任一点退出，重启后从已提交输入重放到**最后持久化 Tick**，重新生成相同状态和 Event 顺序。
4. 只有在 MySQL 命令提交后发送接受 ACK，只有在 MySQL Tick/Event 提交后向 Client 发布这些 Event。Redis 不可用时安全回退 MySQL；MySQL 不可用时，该 Battle 停止推进并明确报错。
5. 同一 `battle_id` 同时被旧 Worker 和新 Worker 争用时，数据库中的 owner epoch 阻止旧 Worker 再提交结果。
6. DB 进程重启、Redis 丢 key 或重启后，可以从 MySQL 重建缓存；Battle/DB 间的请求丢失、迟到、重复都可按业务键对账。
7. 用故障注入和恢复日志证明上述行为；单元测试、三进程集成、Redis/MySQL 重启与负载测试分别报告。

## 学习导航

| 先学什么 | 当前问题 | 完成后能回答 |
|---|---|---|
| 链路探活 | 启动时 ready 不代表运行中可用 | 是进程存活、Cluster 可达，还是 Battle 可服务？ |
| 结果不确定 | `cluster.send` 成功返回后仍可能丢回包 | 超时后为什么不能直接换一个命令号重发？ |
| 事务与唯一键 | ACK 不能早于 durable commit | 崩溃恰好发生在 COMMIT 与 ACK 之间会怎样？ |
| 独立 DB 进程 | Battle 不应直接管理两种存储连接 | 哪个 Service 负责事务、缓存和故障恢复？ |
| Redis 缓存 | 热数据需要低延迟访问 | 缓存失效、落后或重启后以谁为准？ |
| 确定性重放 | 内存 Battle 丢失 | 哪些输入、版本和逻辑 Tick 必须保存？ |
| 检查点 | 每次从第 0 Tick 重放有上限 | 什么才算可独立恢复的检查点？ |
| 持有权隔离 | 两个 Worker 可能同时认为自己是 owner | 旧 Worker 怎样被持久化层拒绝？ |

推荐按每阶段的“实现→故障注入→验收”推进。不要先创建一棵 `Repository/Manager/Provider` 目录树。本专题只在首次出现真实调用者时增加对应文件。

## 0. 冻结现有边界与故障模型

第二、三课形成的在线链路及本专题计划新增的数据支路：

```text
Unity --TCP/Proto--> FlyWow Gateway
                         |
                         v
                 gateway_proxy.lua
                         | cluster.send(request, route_token)
                         v
                 battle_dispatch.lua
                         | skynet.call
                         v
                 BattleMgr -> BattleWorker -> no-yield Battle Core
                         |                |
                         |       本专题新增：有界请求/应答
                         |                v
                         |       DB Process: battle_store Service
                         |          |                 |
                         |     Redis 热缓存       MySQL 持久事实
                         |
            cluster.send(result, route_token)
                         v
                 gateway_proxy.lua -> 原 TCP 请求
```

Gateway 只拥有连接、传输会话、route token 与有界等待表。Battle 拥有玩家归属、战斗路由、命令序号、状态和恢复策略。DB 进程拥有 MySQL/Redis 连接、事务、缓存编码与读写策略；MySQL 记录 Battle 的持久事实，Redis 保存可丢弃、可重建的已提交热数据。`route_token` 只关联一次跨进程请求；`connection_id` 只标识当前 Gateway 连接；`battle_id`、命令序号和 owner epoch 是 Battle 侧的业务/持久化身份，不能混用。Gateway 不直接访问 DB 进程或存储。

先只读以下文件并记录当前行为：

```text
server/service/gateway/gateway_proxy.lua
server/service/battle/battle_dispatch.lua
server/service/battle/battle_mgr.lua
server/service/battle/battle_worker.lua
server/lualib/battle/battle_core.lua
docs/SKYNET_CLUSTER_AND_HARBOR.md
docs/TEST_STRATEGY.md 的 Lesson 3 段落
```

写一张故障表，至少覆盖：请求尚未送达、Battle 已接受但回包丢失、Battle↔DB 请求/应答断开、MySQL COMMIT 结果不确定、Redis 写入失败、Tick/Event 已提交但发布失败、Gateway/Battle/DB 分别重启、Worker 失联、MySQL 失联。对每项分别记下“Client 看见什么”“MySQL 持久事实是什么”“Redis 可以是什么状态”“允许重试什么”“怎样验收”。

这里必须先接受一条边界：**网络超时不是业务回滚证明**。Skynet 官方 Cluster 文档明确提醒跨节点 `send` 可能丢失，也不提供完整的分布式故障恢复。[Skynet Cluster 官方说明](https://github.com/cloudwu/skynet/wiki/Cluster)

### 阶段 0 验收

- 第二课双进程 Query/RunAutoBattle 仍能运行。
- 第三课相同输入、版本、seed 的 Battle Core 两次运行得到相同有序 Event。
- 能说明当前 `gateway_proxy.lua` 的等待上限与超时能释放什么资源，以及它无法判断什么业务结果。

## 1. 运行态探活与降级

启动时的 `ready` 只验证启动那一刻。本阶段在已有 Proxy/Dispatch 边界增加**内部**健康探测，不引入客户端可调用的 `HealthProbe` Proto RPC。

具体操作范围：

1. [局部修改] `server/service/gateway/gateway_proxy.lua`：只保留一个在途 probe。它使用现有 route token/反向结果通道，记录开始时间、deadline、连续失败数、最近成功时间。探测失败时清理等待项；不得因健康检查挤占所有 64 个业务待回包名额。
2. [局部修改] `server/service/battle/battle_dispatch.lua`：处理内部 `health_probe`，返回进程启动世代、Manager ready、Worker 数量与已发布地图/协议版本。不得读取任意客户端上传的 battle_id 来决定健康状态。
3. [局部修改] `server/service/battle/battle_mgr.lua`：提供有界 `health` 结果；Worker 不可用时返回降级，不把端口连通当作 Battle 就绪。
4. Proxy 状态固定为 `READY / DEGRADED / UNAVAILABLE`。示例门槛：每秒一个 probe、500 ms deadline、连续 3 次失败降为 `UNAVAILABLE`、连续 2 次成功恢复；部署前按真实网络延迟测试调整。探测超时、结果格式错误、进程世代变化都计入诊断。
5. `UNAVAILABLE` 时新 Start/Command 快速返回稳定错误；Proxy 不无限缓存请求，不替 Battle 决定命令重试。恢复 `READY` 后，结果不确定的请求仍需 Battle 对账。

Skynet Timer 用来调度 probe；它不是 Battle logical tick。一次往返探测覆盖请求和反向结果两条通信路径，但并不能证明每个 Worker 的每一场 Battle 都正常。进程存活、传输可达、业务 ready 与某场 Battle 可恢复是四个不同结论。

### 阶段 1 验收

- 断开 Gateway→Battle 或 Battle→Gateway 任一方向，观察状态迁移与恢复耗时。
- `pending_count`、probe 数、请求队列始终受限；长期断链时内存不持续上涨。
- Battle 端口可连接但 Manager 未 ready 时，probe 不报告 `READY`。
- 迟到的旧 probe 与旧结果不能改变新进程世代的状态。

## 2. MySQL 事务与 Redis 缓存练习：分清数据层级

本阶段先在独立练习库操作，不接 Battle Core。MySQL 8.4 使用 InnoDB；记录 `SELECT VERSION()`、`@@innodb_flush_log_at_trx_commit`、`@@sync_binlog`、`@@transaction_isolation`。持久性取决于数据库提交与刷盘/复制配置；不能因应用收到了 COMMIT 返回就忽略部署配置。MySQL 官方说明了 InnoDB 日志刷盘与 binlog 同步设置的作用。[MySQL 8.4 持久性设置](https://dev.mysql.com/doc/refman/8.4/en/innodb-parameters.html#sysvar_innodb_flush_log_at_trx_commit)、[MySQL 8.4 binlog 设置](https://dev.mysql.com/doc/refman/8.4/en/replication-options-binary-log.html#sysvar_sync_binlog)

练习三个最小事务：

1. `BEGIN → INSERT → ROLLBACK`：查询证明没有接受事实。
2. `BEGIN → INSERT → COMMIT`：断开应用连接后重新连接，查询证明事实存在。
3. `COMMIT` 发出后主动断开应用连接：客户端必须把结果标为**不确定**，用唯一业务键查询，不能直接生成新键再插一次。

本专题选择以下最小持久化表。操作类型：[新建文件] `server/sql/battle_persistence_v1.sql`；它只在进入本阶段并确定 MySQL 练习环境后创建，运行前先审查目标库名。`payload` 是**明确版本化的纯数据编码**，不保存 Lua `table` 指针、Native userdata、Service handle、客户端 fd 或开发机路径。

```sql
-- 职责：保存 Battle 的初始输入、已接受命令、已提交 Tick/Event 与持有者世代。
-- 边界：MySQL InnoDB 持久化层；由独立 Skynet DB Process 的存储 Service 访问。
-- 输入/输出：版本化纯数据 payload 与事务提交结果；不存 Native Context。
-- 生命周期：DDL v1 经迁移执行；表中 Battle 数据按保留策略清理。
-- 不负责：不决定技能合法性、AI、路径、伤害或客户端投递。
CREATE TABLE battle_instance (
    battle_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    start_nonce_hash BINARY(32) NOT NULL,
    scenario_id INT UNSIGNED NOT NULL,
    battle_version INT UNSIGNED NOT NULL,
    map_id INT UNSIGNED NOT NULL,
    map_version INT UNSIGNED NOT NULL,
    map_hash BINARY(32) NOT NULL,
    air_map_version INT UNSIGNED NOT NULL,
    air_map_hash BINARY(32) NOT NULL,
    skill_version INT UNSIGNED NOT NULL,
    skill_hash BINARY(32) NOT NULL,
    seed BIGINT NOT NULL,
    input_codec_version INT UNSIGNED NOT NULL,
    initial_payload LONGBLOB NOT NULL,
    initial_payload_hash BINARY(32) NOT NULL,
    durable_tick INT UNSIGNED NOT NULL DEFAULT 0,
    durable_event_seq BIGINT UNSIGNED NOT NULL DEFAULT 0,
    status TINYINT UNSIGNED NOT NULL,
    owner_node VARCHAR(64) NULL,
    owner_epoch BIGINT UNSIGNED NOT NULL DEFAULT 0,
    lease_until DATETIME(6) NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (battle_id),
    UNIQUE KEY uq_start_nonce (start_nonce_hash)
) ENGINE=InnoDB;

CREATE TABLE battle_command (
    battle_id BIGINT UNSIGNED NOT NULL,
    unit_id INT UNSIGNED NOT NULL,
    command_seq INT UNSIGNED NOT NULL,
    apply_tick INT UNSIGNED NOT NULL,
    command_codec_version INT UNSIGNED NOT NULL,
    command_payload BLOB NOT NULL,
    command_hash BINARY(32) NOT NULL,
    PRIMARY KEY (battle_id, unit_id, command_seq),
    KEY ix_command_apply (battle_id, apply_tick, unit_id, command_seq)
) ENGINE=InnoDB;

CREATE TABLE battle_tick_commit (
    battle_id BIGINT UNSIGNED NOT NULL,
    logic_tick INT UNSIGNED NOT NULL,
    last_event_seq BIGINT UNSIGNED NOT NULL,
    state_hash BINARY(32) NOT NULL,
    owner_epoch BIGINT UNSIGNED NOT NULL,
    PRIMARY KEY (battle_id, logic_tick)
) ENGINE=InnoDB;

CREATE TABLE battle_event (
    battle_id BIGINT UNSIGNED NOT NULL,
    event_seq BIGINT UNSIGNED NOT NULL,
    logic_tick INT UNSIGNED NOT NULL,
    event_codec_version INT UNSIGNED NOT NULL,
    event_payload BLOB NOT NULL,
    event_hash BINARY(32) NOT NULL,
    PRIMARY KEY (battle_id, event_seq),
    KEY ix_event_tick (battle_id, logic_tick, event_seq)
) ENGINE=InnoDB;
```

`start_nonce_hash` 解决 Start 回包丢失：Client 在 Start 前用安全随机源生成一次短期 nonce，并在重试时使用同一个值；Battle 按唯一键返回同一场创建结果。仅有 nonce 不等于账号认证，它必须作为短期 bearer 凭据保密；成熟系统应将其与账号/会话授权绑定。`battle_command` 的主键解决重复命令；同主键而 `command_hash` 不同必须拒绝，不能当作成功重试。`battle_tick_commit` 是逐 Tick 的完整性记录；`durable_tick` 是恢复与对外发布水位。

接着在独立练习 Redis 实例上练习 `SET`、`GET`、过期与删除。先固定 Redis 版本，记录 RDB/AOF 配置，然后主动删除 key 和重启 Redis，观察缓存命中、失效与恢复。Redis 官方文档说明，即使打开常见的 AOF `everysec` 策略，也可能丢失最近约一秒数据；因此本专题不把 Redis 成功写入当作业务 durable ACK。[Redis 持久化说明](https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/)

初始缓存合同只覆盖两类有真实读者的数据：`battle:{battle_id}:head` 保存 `owner_epoch`、`durable_tick`、`durable_event_seq`、状态、数据/codec 版本和 payload hash；`battle:{battle_id}:events:{page}` 保存已提交 Event 的有界分页。Key 带格式版本前缀与 TTL，值只含版本化纯数据，不保存连接、Lua State、Native Context 或未提交 Core 状态。缓存读取必须先检查格式、hash、epoch 和水位；不命中、过期、损坏、落后或 Redis 不可达时，从 MySQL 查询并按当前持久水位回填。不能仅凭 Redis 中「更新」的水位越过 MySQL 已提交水位。缓存数据保留期短于 MySQL 的 Battle/Replay 保留期。

首次写路径采用 **MySQL 事务提交 → Redis 写入/失效 → DB 进程返回 durable 结果**。Redis 写失败不抹掉已提交的 MySQL 事实，DB 进程标记缓存降级、按业务键返回已提交结果，并在后续读取时回填；Redis 写成功也不提前触发业务 ACK。这样 Redis 是中间访问层，MySQL 是最终持久层。想练习 Redis 先写、异步落 MySQL 的 write-behind 时，必须另立阶段设计可恢复的队列/日志、顺序水位、重放和丢数据窗口；不能把「Redis 已收」伪装成「MySQL 已持久」。

### 阶段 2 验收

- 四张表均为 InnoDB；重复 Start nonce 命中唯一键。
- 相同命令号、相同 payload 重试可查到原接受事实；相同命令号、不同 payload 被拒绝。
- 记录数据库配置、表结构版本和一次断线后查询事务结果的证据。
- 手工删除/过期/重启 Redis 后，能独立从 MySQL 查到原持久事实；MySQL 中没有的事实不能由 Redis 生成。自动回填留到阶段 3 验证。
- MySQL COMMIT 后故意让 Redis 写失败，手工查询确认 MySQL 事实仍存在；缓存降级指标留到阶段 3 验证。

## 3. 独立 DB 进程：先保证命令 ACK 的含义

只有走到本阶段才 [新建文件] `server/config/skynet_db.lua`、`server/service/db/db_main.lua` 与 `server/service/db/battle_store.lua`；普通连接/编码/缓存模块按真实调用放到 `server/lualib/db/`。`db_main.lua` 是第三个 Skynet Process 的 composition root，启动 Store 并保存 handle；`battle_store.lua` 是该进程中的 Service，拥有 MySQL 与 Redis 连接。Battle Process 仅保存显式注入的 DB Cluster 地址/路由，不拥有数据库连接；Gateway 仍只与 Battle 通信。密码从 DB 进程运行环境注入，不入 Git、日志或 Replay。Skynet 自带的 `skynet.db.mysql` 可作为课程适配器，但必须先在固定 Skynet v1.8.0 源码核对连接、错误、重连与事务行为；Redis 客户端同样按固定源码版本核对连接和错误行为。一个 MySQL 事务的全部语句必须在**同一数据库连接**上执行。[Skynet MySQL 模块源码](https://github.com/cloudwu/skynet/blob/v1.8.0/lualib/skynet/db/mysql.lua)

不要让不同消息协程的 SQL 插进另一事务的 `BEGIN` 与 `COMMIT` 中。最小实现由一个 Store Service/连接负责串行 MySQL 事务，跨 yield 临界段用 `skynet.queue` 或等价的显式排队；Redis 更新放在事务临界段外，并有独立的短 deadline。后续性能测试证明需要时，才按 `battle_id` 分片多个连接/Store。Store 的队列长度、连接超时、单笔 payload、重试次数和停机排空时间必须有限；满时返回 `STORE_BUSY`，不能无限堆积。Redis 与 MySQL 连接、超时和重试预算分别记录，不能用 Redis 重连循环阻塞 MySQL 提交队列。MySQL 连接在事务中断开时，该事务结果先标为不确定；重连后先按唯一业务键查询，禁止自动重放非幂等 SQL。

Battle↔DB 是第二条跨进程边界。先在 `docs/SKYNET_CLUSTER_AND_HARBOR.md` 的固定版本结论下选择有界请求/应答通道，保存 `request_id`、deadline、DB 进程世代、`battle_id` 和 `owner_epoch`；请求/应答丢失后按 Start nonce、命令主键或 Tick 主键查询，不把传输超时解释成 MySQL 回滚。DB Store 接口从真实调用开始，只提供 `create_or_get_battle`、`append_or_get_command`、`commit_or_get_tick`、`load_recovery`、`acquire/renew_owner`、`health/stats`。每个返回值区分 `COMMITTED`、`NOT_COMMITTED`、`RESULT_UNCERTAIN`、`STORE_BUSY`、`OWNER_FENCED`；Redis 降级单列状态，不覆盖 MySQL 结果。DB 进程重启后必须能重新建连，并用 MySQL 重建缓存与对账状态。

DB 进程提供内部 `READY / CACHE_DEGRADED / UNAVAILABLE` 健康状态，分别表示 MySQL 可提交且 Redis 可用、MySQL 可提交但 Redis 不可用、MySQL 无法完成持久提交。Battle 定期做有界往返 probe，并记录 DB 进程世代；断线后按退避与抖动重连，任何迟到旧世代结果只用于诊断，不推进当前 Battle。Gateway 的传输探活与 DB 的存储探活分别记录；Gateway 的 `READY` 不能证明某场 Battle 的 MySQL 持久能力。断线期间不积压无限请求，恢复连接后先按业务键对账，再重新开放该场命令与 Tick。

对外确认语义固定如下；日志和测试也使用同一名称：

| 状态 | 可依据什么返回 | Client 后续动作 |
|---|---|---|
| `RECEIVED` | Gateway/Battle 收到传输消息，但没有 MySQL 接受事实 | 只作传输诊断，不当作命令已接受 |
| `ACCEPTED_DURABLE` | MySQL 命令事务已提交，或对账查到同主键同 hash 的原提交 | 保留原命令号等待执行/同步 |
| `RESULT_UNCERTAIN` | 请求或 COMMIT 应答丢失，尚未完成 MySQL 对账 | 使用相同业务键与相同 payload 查询/重试 |
| `APPLIED_DURABLE` | 对应 Tick/Event 的 MySQL 事务已提交 | 可展示 Event；断线后按 `event_seq` 补取 |

命令接受顺序：

```text
Worker no-yield 预校验权限、命令号、队列预算
-> 标记这场 Battle 正在提交命令；本场 heartbeat 暂停，其他 Battle 继续
-> 向 DB 进程发有界请求；Store 事务插入 battle_command，固定 apply_tick = 当前 Tick + 1
-> MySQL COMMIT 成功；Store 更新/失效 Redis 缓存
-> Worker 核对仍为同一场与同一 epoch，no-yield 入队并回 ACCEPTED(command_seq, apply_tick)
-> MySQL COMMIT 失败/不确定：不发接受 ACK；按唯一键查询，不能直接换序号重试
```

在跨进程等待的 yield 期间，同一 Worker 的别的消息协程仍可运行。因此本场需要一个有界的 `admission_busy` 状态：后续该场命令明确返回忙或进入有界队列；heartbeat 跳过该场。不要拿着 `unit` table、fd 或借用 buffer 跨 yield 后直接使用，恢复执行时重新按 `battle_id` 找 Runtime、核对 owner epoch、生命周期和预留的命令号。DB 回包过迟且 Battle 已关闭时，不可把结果放进新 Runtime。

如果崩溃发生在 COMMIT 后、Worker 入队或 ACK 前，日志中已有命令；恢复重放会在已记录的 `apply_tick` 执行一次。Client 使用相同命令号与内容对账，看到原接受结果后继续。**提交前 ACK 是本专题的 P0 错误。**

### 阶段 3 验收

- 在事务提交前杀 Worker：没有接受 ACK，也没有可恢复命令。
- 在 COMMIT 后、ACK 前杀 Worker：重启后命令存在且只执行一次。
- Battle↔DB 断开、MySQL 连接断开或 Store 队列满：Battle 不再推进该场，客户端收到稳定失败/不确定状态。
- Redis 连接断开但 MySQL 可用：命令仍按 MySQL COMMIT 结果确认；缓存降级与回填可观察。
- DB 进程重启：Battle 的在途请求可对账，DB 不从 Redis 猜测未返回的 MySQL 提交结果。
- 断开 Battle→DB 或 DB→Battle 任一方向：probe 在有界时间内降级，重连有退避，迟到旧世代应答不推进 Battle；对账完成后才恢复该场服务。
- 别的 Battle 仍可按各自资源预算运行；Core 中没有 SQL、`skynet.call` 或其他 yield。

## 4. Tick/Event 持久化：只发布已提交的事实

第一版使用最容易验证的逐 Tick 提交，不提前宣称它能支持大量 Battle。一个 Tick 的 `battle_core.step()` 仍是 no-yield；Worker 从 Core 取出待发布 Event 后，先经有界 Battle↔DB 请求提交，再对 Gateway/Client 可见。DB Store 在**同一 MySQL 事务**中检查 `owner_epoch` 和前一个 `durable_tick`，插入这一 Tick 的 Event/hash 与 `battle_tick_commit`，更新 `battle_instance.durable_tick/durable_event_seq/status`，最后 COMMIT。事务成功后更新/失效 Redis `head` 与相关 Event 页；失败时清理该进程内尚未发布的缓存候选数据。

Worker 等待该事务时把该场标成 `PERSISTING_TICK`：本场 heartbeat 不重复推进；Sync 只能返回上一个 durable 水位的 Snapshot/Event，不能读取尚未提交的 Core 内存状态。MySQL COMMIT 成功后才推进对外水位、填入在线 Event ring 并发布。COMMIT 明确失败或结果不确定时，不能简单继续使用已经突变的内存 Core：隔离该 Runtime，由 DB 进程对账 MySQL，再从最后确认的 durable Tick 重建。Redis 中的旧水位不能使这场 Battle 继续推进。其他 Battle 的状态不受这次失败污染。

DB 进程维护本进程已确认的每场 MySQL 水位，缓存值低于该水位时直接视为 miss。DB 进程重启后，这个内存水位消失，首次恢复/对账必须从 MySQL 读取权威 `durable_tick`，再考虑 Redis 值；普通缓存读若要求「最新」，同样先持有可信的 MySQL 水位或执行 MySQL 校验。仅靠 TTL、时间戳或 Redis key 存在无法证明最新。缓存回填用带 epoch/水位的条件更新，防止较慢的旧读取盖过新提交；不能完成条件更新时直接删除旧 key，下一次从 MySQL 读取。

这个正确性基线每场每秒最多触发 `1000/tick_ms` 次 Tick 事务；50 ms Tick 即每场约 20 次。Worker 配置里的 `max_battles_per_worker` 是内存保护值，不代表数据库已经能承受该规模。测出事务吞吐、p50/p95/p99 提交延迟、队列深度、Battle 逻辑落后和恢复耗时后，再考虑有限批量提交。批量提交仍必须满足“ACK/Event 不早于对应事务 COMMIT”，并明确批内失败语义。

### 阶段 4 验收

- 在 Core step 后、DB COMMIT 前杀进程：Client 从未见到该 Tick Event，恢复从前一个 durable Tick 开始。
- 在 COMMIT 后、回推前杀进程：数据库有 Tick/Event，恢复后 Sync 能重新得到相同 seq/内容。
- `durable_tick`、`last_event_seq` 单调且连续；Event 不跨 Tick 重排。
- 数据库慢或断开时本场暂停、队列有界；不能把未持久化内存状态称为 Snapshot。
- Redis 旧页、较慢回填、重启后的残留 key 都不能使读取结果回退或越过 MySQL 持久水位。

## 5. Battle 进程重启：先从初始输入确定性重放

第一条可运行恢复路径**不保存 Native Path、NavigationContext 或 Lua 闭包**。数据库保存版本化初始输入、已接受命令及其 `apply_tick`、每 Tick state hash 与 Event。重启后先校验 `map_id/map_version/hash`、AirMap、技能配置、协议/codec 版本和 seed；缺少任一匹配发布资产时返回 `RECOVERY_ASSET_MISMATCH`，绝不在新版地图上“尽量恢复”。

恢复算法（DB 进程从 MySQL 提供完整权威日志；Redis 只可在核对后辅助读取）：

```text
读取 battle_instance、命令日志、durable_tick 与 Tick/Event hash
-> 创建新的 battle-local NavigationContext
-> 从原始初始输入调用同一 battle_core.create()
-> 按记录的 apply_tick/unit_id/command_seq 送入同一 Core
-> 连续 step() 到 durable_tick；这一过程不等待墙钟
-> 每 Tick 对比 state_hash、event_seq/Event hash
-> 全部一致后发布即时 Snapshot，重新开启在线 heartbeat
```

重放不重新调用客户端、不读 Unity 工程、不让 Gateway 提供权威位置。若 hash 不一致，标记 `RECOVERY_DIVERGED` 并停止该场；不能跳过损坏日志或用数据库中的 Event 直接拼出一个看似正常的 Core State。Redis 缓存损坏时删除并从 MySQL 回填；MySQL 权威日志损坏时拒绝恢复，不能反向用 Redis「修复」。课程场景 `max_ticks` 有固定上限，所以先重放到头可以教学和验收；恢复耗时必须实测。

`BattleSnapshot` 是给客户端表现/校正的视图，缺少 Path、冷却、AI 决策等完整 Runtime 事实，**不能直接充当进程恢复检查点**。第一次做真正的加速检查点时，再给 Core 增加 `export_checkpoint/import_checkpoint`，显式列出 PRNG、Unit/技能/Buff/弹丸/AreaEffect、命令游标和动态占位；Native Path 要么可验证重建，要么在恢复边界强制重新规划并用确定性测试证明 Event 不变。检查点包含 codec 版本、资产 hash、state hash 和对应 durable Tick，必须与日志水位原子发布；不完整或过期检查点回退到从初始输入重放。

### 阶段 5 验收

- 同一初始输入/命令/版本/seed，未中断运行与重启恢复的 Event、最终状态 hash 一致。
- 损坏初始 payload、命令、Event、检查点任一 hash 时明确失败，绝不部分恢复。
- 不兼容 map/air/skill/codec 版本拒绝恢复。
- 记录恢复 100、1000、2400 Tick 的耗时与峰值内存；检查点只有在实际缩短恢复且通过等价测试后才启用。

## 6. 多 Worker 持有权与故障切换

单进程重启与多节点故障切换不是同一个问题。若两台 Battle Process 都能加载同一 `battle_id`，需要 MySQL 持有权世代：DB Store 获取 owner 时在事务中锁定 `battle_instance`，确认租约过期或明确移交，再增加 `owner_epoch` 并写入 `owner_node/lease_until`。所有命令与 Tick 写事务都检查当前 epoch；旧 Worker 即使晚到也只能得到 `OWNER_FENCED`，不能覆盖新 owner 的状态。租约时间按数据库时间判断，不依赖两台机器墙钟完全一致。Redis 可缓存路由或租约提示，但不能单独发放权威 epoch；失去 Redis key 不能导致双主。[MySQL 锁定读说明](https://dev.mysql.com/doc/refman/8.4/en/innodb-locking-reads.html)

租约续期、获取和放弃都有有限超时与重试。网络分区时旧 Worker 可能仍在内存模拟，但没有有效 epoch 的结果不得被确认或发布。Gateway 不挑选新的 Worker；Battle 侧的 Manager/部署控制面决定归属变化，Gateway 只转发并交付当前连接可用的结果。

这里不提前制造通用服务发现系统。先在一个 Battle Process 重启场景验证恢复；确有第二个 Battle 节点时，再做双节点抢占与 fencing 测试。

### 阶段 6 验收

- 两个 Worker 同时争同一 Battle，只有一个取得新 epoch。
- 旧 Worker 在新 epoch 生效后提交命令/Tick，数据库拒绝。
- 旧 Gateway/Proxy 进程世代的迟到结果不能投递到新连接。
- DB 不可用时不猜测租约归属，不自动双主。

## 7. 资源上限、保留与故障注入清单

所有数值在实施时写入只读配置并做压测校准，至少包括：Gateway route 等待数与 deadline、probe 并发与频率、Battle↔DB 在途请求数与 deadline、DB Store 队列与单笔 BLOB 上限、Redis key/页大小与 TTL、Redis/MySQL 各自连接与重试预算、单场未确认命令数、每 Tick 最大 Event 数、最大恢复 Tick、恢复并发数、MySQL 事务 deadline、短期 Battle/Replay 保留期。超限统一返回稳定错误；日志/指标区分 `REMOTE_TIMEOUT`、`RESULT_UNCERTAIN`、`STORE_BUSY`、`MYSQL_UNAVAILABLE`、`CACHE_DEGRADED`、`OWNER_FENCED`、`RECOVERY_DIVERGED` 和资产版本错误。日志不记录 resume token、原始命令 payload、Redis/MySQL 密码或个人信息。

保留策略必须写清：活动 Battle 的初始输入、命令、Tick 与 Event 不能在恢复窗口内删除；Battle 完结且 Replay/审计保留期结束后，先确认归档，再按 `battle_id` 有界清理。清理任务不得与活动 owner 竞争。Redis key 到期或清空只造成性能回退，不得损坏 MySQL 中的 Battle。MySQL 备份与恢复演练是持久化验收的一部分；只做应用重启测试不足以证明数据库灾难恢复。

| 故障注入点 | 必须观察的结果 |
|---|---|
| Gateway→Battle 断开 | 探活降级、等待表释放、新请求有界拒绝 |
| Battle→Gateway 回推断开 | 命令结果标为不确定，恢复后按序号对账 |
| Start COMMIT 后回包前断开 | 同一 start nonce 返回同一 Battle，不重复创建 |
| Command COMMIT 前/后杀 Worker | 前者未接受；后者恢复后执行一次 |
| Tick COMMIT 前/后杀 Battle Process | 前者不可见；后者恢复同 seq/Event |
| Battle↔DB 单向断开、DB 进程重启 | 在途请求有界；按业务键对账；不重复接受或提交 |
| Redis 断连/重启/清空/旧值回填 | MySQL 提交和对账继续；缓存降级、miss、回填可见 |
| MySQL 连接超时/重启 | 单场暂停或失败，不发布未持久化状态 |
| 数据库行/日志损坏 | hash/版本校验拒绝恢复 |
| 双 Worker 竞争 | owner epoch 拒绝旧 owner 写入 |
| 过载 | Gateway/Store/恢复队列均有界，拒绝路径可见 |

## 8. 每阶段的验证与完成报告

按影响范围依次做静态检查、Lua/SQL 语法检查、Native/Proto/Unity 编译、MySQL/Redis 独立练习、Skynet Gateway/Battle/DB 三进程集成、故障注入、确定性对照和负载测试。未接入某一阶段时，不把该阶段的设计表述成已运行通过。

完成报告分别列出：

```text
静态检查
编译/协议生成
单元与 MySQL/Redis 独立测试
Gateway/Battle/DB 三进程 + Redis/MySQL 集成运行
断链、重启、COMMIT 边界故障注入
确定性、并发与 Benchmark 条件及结果
尚未验证的故障或部署边界
```

推荐学习顺序为第 0、1、2、3、4、5 阶段。第 6 阶段需要第二个真实 Battle 节点；未出现时先保留持有权字段及其单节点校验测试，不宣称完成多节点故障切换。每次只落地当前阶段被调用的最小文件与接口，验收后再进入下一阶段。阶段 1 只验证 Gateway/Battle；阶段 3 起才引入第三个 Skynet 进程与 Redis/MySQL。

## 参考与课程边界

- [第三课实操](Skynet_BattleNavigation第三课_从在线指令到多BattleWorker权威战斗_实操.md)：在线命令、BattleWorker、Snapshot/Event 与 Unity 表现。
- [Lesson 3 Spec](../codex/LESSON_03_SPEC.md)：第三课原定完成条件；本专题不重写它。
- [Skynet Cluster 与 Harbor](SKYNET_CLUSTER_AND_HARBOR.md)：固定 Skynet 版本下的传输与故障语义。
- [测试策略](TEST_STRATEGY.md)：确定性、并发与集成验证的原有门槛。
- [MySQL 8.4 InnoDB 事务模型](https://dev.mysql.com/doc/refman/8.4/en/innodb-transaction-model.html)：事务、锁和一致性读的官方说明。
- [Redis 持久化说明](https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/)：RDB/AOF 的数据丢失窗口；本专题仅把 Redis 用作可重建缓存。
