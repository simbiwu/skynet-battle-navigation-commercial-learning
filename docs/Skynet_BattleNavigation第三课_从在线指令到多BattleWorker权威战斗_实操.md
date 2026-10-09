# Skynet Battle Navigation 第三课实操：从在线 PlayerCommand 到多 BattleWorker 权威战斗

> 本课直接承接 `docs/Skynet_BattleNavigation第二课_从Grid寻路到Skynet自动战斗_实操.md` **全部完成后的工程状态**。
>
> 本课前置条件固定为：第二课实操已经全部完成并通过第二课验收。第三课只继承第二课文档定义的最终状态，不把任何中间实现状态当作课程基线。开始第 7 节前，先按第二课第 27 节重新运行 Native 测试、Batch Regression 和 Gateway/Battle 双进程验收；任一项未通过，先完成第二课，不把第三课代码用于修补第二课基线。

> **使用方式：**本文是分阶段实操手册，不是一次性复制全部代码的脚本。每次只推进一个阶段；先核对该阶段的真实基线，再读文件职责、实现、失败路径和验收。第三课正式验收以 `codex/LESSON_03_SPEC.md` 为准；本文中明确标为扩展的 FireWall、Buff 和 BRPL 文件封装不作为主课通过条件。
>
> **当前基线提醒：**第二课结束时 BattleMgr 仍是一次性自动战斗的 round-robin 分发；固定 Shard、在线 Battle Runtime、PlayerCommand 和 Air Grid 都是第三课要逐步新增的内容，不能当作仓库已经存在的实现。开始第三课前，先实际跑完第二课验收，不以文档描述替代运行结果。

本课不是“做一个大而全的商业 SLG”。目标是用一个足够小、但边界真实的战斗 Runtime，把以下知识真正串起来：

```text
Skynet Service / Lua State / coroutine / yield
-> 固定 BattleWorker Shard
-> 多场 Battle 的 ownership
-> PlayerCommand
-> Ground / Air Navigation
-> 三类 Skill：瞬发 / 表现型弹丸 / Server 权威逻辑弹丸
-> BattleEvent / BattleSnapshot
-> 在线 fixed-tick + 自动快速 simulate 共用同一个 Core
-> Unity 只负责输入和表现
```

学习者已经有多年 C++ / Lua / MySQL MMO Server 主程经验，因此本课不重新讲线程池、RPC、状态机、网络基础或普通 Lua/C++ 语法。需要重点补齐的是：

```text
这些熟悉的 Server 概念，在 Skynet 里怎样表达；
Service、Lua State、协程、消息和 OS Worker Thread 到底是什么关系；
哪里可以 yield，哪里必须 no-yield；
多个 Battle 怎样稳定分片到固定 BattleWorker；
Native Navigation 怎样被多个 Service 并发安全调用；
地图、技能和战斗事件怎样进入同一个确定性 Battle Core。
```

---

## 本课最终可见结果

Unity 场景中至少存在：

```text
Player       地面单位；人工输入 Move / CastSkill
GroundEnemy  地面单位；Server AI
FlyingEnemy  空中单位；Server AI
```

最终能够观察：

```text
Player 人工移动
GroundEnemy 自动寻路、追击、近战
FlyingEnemy 使用 Air Grid / NoFly 寻路
Player / AI 使用 Skill Runtime
瞬发技能
表现型弹丸
Server 权威逻辑弹丸
HP / Cooldown / TargetMask / Death
Server Event / Snapshot
Unity 在线表现
同一 Core 的自动快速模拟与 Replay
多个 Battle 同时稳定分配到固定 BattleWorker Shard
```

本课完成后，不要求拥有完整 RPG 技能框架，也不要求拥有完整 SLG 世界系统。

FireWall、Haste/Slow/Burning 和 BRPL 文件封装在本文中作为可选扩展材料保留。先完成 Spec 列出的主课闭环和验收；若它们没有服务当前验收目标，可以跳过，不要让扩展内容阻塞主线。

---

# 第一部分：先冻结边界，再开始写第三课代码

## 0. 第二课完成后，我们已经有什么

> 当前基线补充（以 WSL 主工作区为准）：Ground Navigation 与 Unity Authoring 已迁入 FlyWow navigation 模块。Lua 入口是 require flywow_navigation，Native 产物是 flywow_navigation_native.so。Profile 在 navigation_query.start() 中通过 load_profiles(config.profiles) 一次加载到进程级只读 Registry；BattleWorker 只用 new_context(map_id, map_version) 创建 Battle-local scratch/occupancy。课程 Unity 工程通过离线 UPM .tgz 消费 FlyWow 包；修改包源码后需重新打包并在 Windows Unity 更新包，再执行对应 Editor 测试。

> server/config/battle.lua、Battle 源码和 FlyWow 子模块可能已有你的未提交修改。每个完整替换步骤前先核对 diff，把仍有效的改动并入目标版本；教程步骤不得覆盖用户已有内容。

第三课禁止重新创建第二课已经建立的概念。第二课最终稳定调用面至少包括：

```lua
navigation.new_context(map_id, map_version)

context:find_path(profile_id, start_world, end_world, self_unit_id)
context:find_path_to_range(
    profile_id,
    start_world,
    target_world,
    attack_range_mm,
    self_unit_id)

context:place_unit(profile_id, unit_id, world_position)
context:advance_path({
    profile_id = profile_id,
    unit_id = unit_id,
    path = path,
    from_world = current_world,
    distance_mm = tick_distance_mm,
})
context:release_unit(unit_id)
context:cell_size_mm()
context:close()

path:count()
path:world_point(i)
path:length_mm()
```

第二课 Battle Core 已经形成：

```text
battle_core.create(snapshot, context)
battle_core.step(state, context)
battle_core.is_finished(state)
battle_core.finish(state)
battle_core.simulate(snapshot, context)
```

第二课还有这些已经成立的规则：

```text
WorldPosition 使用整数毫米
GridPos 不进入长期 Battle Contract
GridMap 加载后 immutable
NavigationContext 是 Battle-local mutable state
A* scratch 不允许 global mutable
Battle Core 不 require skynet
simulate / step 内禁止 skynet.call / sleep / Socket / DB / I/O
Path 不每 Tick 重算
Event seq / logic_ms 是权威逻辑顺序
Gateway Process 与 Map/Battle Process 已经分离
跨进程使用 skynet.cluster
```

第三课是在这些合同上演进，不是重写。

### 0.1 第二课中 BattleMgr 的 round-robin 为什么第三课必须改

第二课处理的是一次性请求：

```text
snapshot
-> 任选一个空闲逻辑 Worker
-> 从头快速 simulate 到结束
-> 返回完整结果
```

因此第二课使用稳定 round-robin 足够验证：

```text
BattleMgr -> skynet.call(worker) -> yield
BattleWorker -> no-yield simulate
```

第三课增加长期在线 Battle 后，情况不同：

```text
StartBattle
-> Battle 还活着
-> 后续有很多 PlayerCommand
-> Worker heartbeat 持续推进
-> SyncBattle 多次读取结果
-> Stop / BattleEnd 最后释放
```

同一场 Battle 的后续消息必须始终回到同一个状态 Owner。

所以第三课固定改成：

```text
worker_index = battle_id % battle_worker_count + 1
```

课程中的 `battle_id` 使用非负整数，因此直接采用上式。若真实项目使用从 1 开始的连续 ID，也可以选择：

```text
((battle_id - 1) % battle_worker_count) + 1
```

两者只影响分布偏移，不影响“同 battle_id 永远命中同一个 Worker”的核心合同。

### 0.2 BattleWorker Service 不等于 OS Worker Thread

这点必须从第三课开始彻底分清：

```text
BattleWorker #1   一个 Skynet Service
BattleWorker #2   一个 Skynet Service
BattleWorker #3   一个 Skynet Service

        ↓
Skynet Scheduler
        ↓
thread=4 等 OS Worker Threads
```

`battle_id % battle_worker_count` 分的是 **Service shard**，不是把 battle_id 直接绑定到某个 OS Thread。

同一个 BattleWorker Service：

```text
拥有自己的 Service Context
拥有自己的消息队列
拥有自己的 Lua State
可以管理多场 Battle
```

Skynet 的 OS Worker Thread 是底层调度资源。一个 Service 的消息协程在不同时间可能由不同底层 Worker Thread 执行，因此 Native Module 不能因为“Lua State 是独占的”就假设整个进程只有一个线程会进入 C++。

### 0.3 本课明确不做什么

第三课不实现：

```text
MySQL 持久化
玩家登录体系
断线重连恢复流程
AOI
世界地图分片
大地图行军
联盟
跨服
Match
完整热更
完整监控平台
复杂 Skill Editor
完整 Buff / Aura / Trigger Graph / DSL
完整 Crowd Steering
完整 3D Flying Navigation
Recast / Detour
桥上桥下同 XZ
```

这些不是“不重要”，而是不会为了看起来像完整商业 SLG 而破坏本课主线。

本课新增的 Buff 只覆盖：

```text
Haste    加速
Slow     减速
Burning  周期伤害
```

本课新增的 AreaEffect 只实现：

```text
FireWall
```

足够学习运行时模型后立即停下。

# 第二部分：第三课最终 Runtime 拓扑

## 1. 先看完整运行链

第三课完成后的双进程结构：

```text
Unity
  |
  | TCP / Protobuf Envelope
  v
FlyWow Gateway Service
  |
  | 已解码 request record
  v
Gateway Proxy
  |
  | cluster.send(request record)
  v
Battle Process
  |
  v
battle_dispatch
  | cluster.send(response record)
  |
  v
BattleMgr Service
  |
  | worker_index = battle_id % worker_count + 1
  |
  +----------------+----------------+----------------+
  |                |                |                |
  v                v                v                v
BattleWorker#1   BattleWorker#2   BattleWorker#3   BattleWorker#4
  |                |                |                |
  | battles{}      | battles{}      | battles{}      | battles{}
  |                |                |                |
  +----------------+----------------+----------------+
                   |
                   v
             battle_core.lua
              /    |     \
             /     |      \
        Ground    Air    Skill Runtime
          Nav     Nav      |
           |       |       +-- Projectile
           |       |       +-- AreaEffect / FireWall
           |       |       +-- Buff
           v       v
              navigation.so
                   |
                   v
      immutable GridMap / AirMap
```

这里最重要的 owner 不是文件名，而是生命周期。

## 2. Ownership 表

| 对象 | Owner | 生命周期 | 能否跨 Service 直接传 |
| --- | --- | --- | --- |
| `GridMap` | Map Registry / Native process | 进程级 immutable | 不能传 C++ 指针；跨进程只传 map id/version |
| `AirMap` | Map Registry / Native process | 进程级 immutable | 同上 |
| `BattleMgr` worker handles | BattleMgr Service | Battle Process 生命周期 | handle 是值，可以传；本课只由 composition root 注入 |
| `BattleRuntime` | 某个 BattleWorker | 一场在线 Battle | 不能直接传 table 引用，只通过消息访问 |
| `NavigationContext` userdata | 某个 BattleRuntime | 一场 Battle | 不能跨 Lua State / Service |
| `Path` userdata | 某个单位 | 路线有效期 | 不能跨 Service |
| Projectile / AreaEffect / Buff | BattleRuntime | 当前 Battle；后两者属于可选扩展 | 不能跨 Service |
| `PlayerCommand` | 纯值 | 一次消息 | 可以跨 Service / cluster |
| `BattleEvent` | 纯值 | Event Buffer / Replay | 可以跨 Service / cluster |
| `BattleSnapshot` | 纯值 | 同步点 | 可以跨 Service / cluster |

### 2.1 多场 Battle 不是多个全局变量

一个 Worker 的 Lua State 中会同时存在：

```lua
local battles = {
    [70001] = battle_runtime_a,
    [70005] = battle_runtime_b,
    [70009] = battle_runtime_c,
}
```

每个 `BattleRuntime` 必须独占：

```text
core_state
NavigationContext
command_queue
event ring buffer
latest_snapshot
controller_connection_id
生命周期状态
```

禁止写成：

```text
current_battle = <某场状态>
current_context = <某场导航 Context>
global_rng = <某场随机状态>
global_projectiles = <某场弹丸数组>
```

这些变量一旦在一个 Worker 中承载多场 Battle，就会发生状态串场。

---

# 第三部分：Skynet 的 Service、消息、协程和 yield，要在真实 Battle 中学

## 3. `skynet.call` 为什么不是普通函数调用

Skynet v1.8.0 的固定源码位置：

```text
third_party/skynet/lualib/skynet.lua
```

课程要求实际打开源码看 `skynet.call()`。核心行为是：

```text
pack request
-> 分配 session
-> send 到目标 Service
-> 当前协程 yield
-> response 到来
-> 根据 session 找回原协程
-> resume
-> unpack response
```

所以：

```lua
local result = skynet.call(worker, "lua", "command", request)
```

不能理解成 C++：

```cpp
result = worker.command(request);
```

它更接近：

```text
RPC + coroutine suspend/resume
```

### 3.1 同一个 Service 为什么仍然会出现“重入”

假设 BattleMgr 中：

```text
消息 A
-> 修改 local state
-> skynet.call(worker)
-> yield
```

yield 以后，同一个 Service 可以继续处理消息 B。

因此：

```text
单 Service
!=
整个 Lua 函数从头到尾天然原子
```

真正安全的规则是：

> 对一段必须原子观察的 mutable state，要么在 yield 前完成修改并建立清晰不变量，要么不要跨 yield 保存“半完成状态”。

第三课的 BattleMgr 会故意采用这个规则：

```text
先分配 battle_id
先算 worker_index
先把本地必要状态提交完成
再 skynet.call(worker)
```

如果 Worker 创建失败，允许 battle_id 留下空洞，不为了回收一个数字而跨 yield 做复杂回滚。

## 4. `send`、`call` 和 `retpack`

在本课统一使用：

```text
skynet.call
  需要请求方知道成功/失败或返回数据
  会 yield

skynet.send
  单向投递，不等 response
  当前调用不因为远端业务返回而 yield

skynet.retpack
  对 call 请求返回 Lua 协议结果
```

本课：

```text
Gateway -> Proxy -> cluster.send -> battle_dispatch
Gateway <- Proxy <- cluster.send <- battle_dispatch (关联结果)
BattleMgr -> Worker create/command/sync 使用 call
Observer / 非关键日志可以 send
Battle Core 完全不调用 call/send
```

## 5. `skynet.timeout` 与 Battle Logical Tick 不是一回事

Skynet v1.8.0：

```text
skynet.now()       单位为 1/100 秒
skynet.timeout(ti) ti 同样以 1/100 秒为单位
```

本课默认：

```text
tick_ms = 50
heartbeat_cs = 5
```

Skynet Timer 只解决：

> “什么时候再次让 BattleWorker 有机会执行 heartbeat。”

Battle 规则只能读取：

```text
state.logic_tick
state.logic_ms
```

禁止技能 CD、Buff duration、Projectile impact 直接依赖：

```text
os.time()
skynet.time()
skynet.now()
```

正确关系：

```text
Skynet wall clock timer
       |
       v
BattleWorker heartbeat
       |
       v
battle_core.step()
       |
       v
logic_tick / logic_ms
```

自动模式则完全不等待墙钟：

```text
while not finished:
    step()
```

因此在线与自动模式才能共用同一套业务规则。

## 6. 一个小实验：为什么 Battle Core 选择 no-yield，而不是到处 `skynet.queue`

Skynet v1.8.0 提供：

```text
third_party/skynet/lualib/skynet/queue.lua
```

`skynet.queue()` 可以把跨 yield 临界区串行化。但第三课不把它当 Battle Core 的默认方案。

先理解问题：

```text
A: 读 battle.hp=100
A: skynet.sleep(...)
                 -> yield
B: 修改 battle.hp=50
A: resume
A: 按旧前提继续
```

`skynet.queue()` 可以强制 A 的整个临界区完成后 B 再进。但如果把整个 Battle Tick 包进一个可能执行 DB/RPC 的 queue，等于把外部延迟直接塞进 Battle Owner 的串行临界区。

本课选择：

```text
Service Adapter 可以 yield
BattleMgr 可以 yield
battle_dispatch 可以 yield

BattleRuntime mutable core：
command enqueue  不 yield
step             不 yield
snapshot build   不 yield
sync read        不 yield
```

所以正式 BattleWorker 不需要用 queue 给核心“补锁”。

`skynet.queue` 作为 Skynet 核心知识需要理解，但不是所有状态 owner 都应该靠它解决设计问题。

# 第四部分：把 BattleMgr 改成稳定 Worker Shard

## 7. 新增 Battle Runtime 配置

[局部修改]

```text
server/config/battle.lua
```

该文件已包含 map、profiles、cluster。保留现有字段，只在返回 table 顶层追加本节的 Battle Runtime 字段；不要用示例替换整个文件。当前启动链先执行 navigation.load_profiles(config.profiles)，再加载 BMAP；Worker 用 navigation.new_context(map_id, map_version) 创建私有查询状态。配置属于进程启动期只读数据，不属于某一场 Battle。

```lua
-- 将以下字段追加到现有返回 table 顶层；保留 map/profiles/cluster。
-- 边界：Server Runtime Config；由 BattleMgr/BattleWorker 启动时只读加载。
-- 输入/输出：无运行时输入 -> 固定配置 table。
-- 生命周期：Battle Process 启动时读取；存在在线 Battle 时不得热改 worker_count。
-- 不负责：不创建 Service、不持有 Battle 状态、不决定技能数值。
-- 追加到现有 table：
    worker_count = 4,             -- 固定 BattleWorker Service 数；不是 OS Thread 数。
    tick_ms = 50,                 -- Battle 逻辑 Tick，必须是 10ms 的整数倍。
    heartbeat_cs = 5,             -- Skynet timeout 单位 1/100 秒；5 = 50ms。
    max_battles_per_worker = 128, -- 教学验收上限；超限明确 BUSY。
    max_commands_per_battle = 64, -- 单场尚未执行命令队列上限。
    max_events_buffered = 1024,   -- 在线增量同步 ring buffer 上限。
    max_events_per_sync = 128,    -- 一次 SyncBattle 最多返回事件数。
    snapshot_interval_ticks = 20, -- 20 * 50ms = 1 秒生成一次周期 Snapshot。
    max_catchup_ticks = 4,        -- heartbeat 落后时单次最多补 4 Tick，避免无限追赶。
    finished_retention_cs = 3000, -- 已结束在线 Battle 保留 30 秒供最终 Sync；只影响生命周期。
    max_finished_retained = 128,  -- 每 Worker 最多保留多少个已结束结果，防止缓存无界增长。
    debug_console_port = 8001,    -- 仅开发环境；0 表示不启动。
```

### 7.1 为什么 worker_count 不能在线随便改

当前路由：

```text
battle_id % worker_count
```

如果 70001 已经活在 Worker #2，运行中把：

```text
worker_count 4 -> 8
```

后续同一个 battle_id 可能算到另一个 Worker。

所以本课固定规则：

```text
worker_count 是 Battle Process 生命周期配置
存在在线 Battle 时不变
扩缩容属于后续部署/分片专题
```

## 8. 完整替换 `battle_mgr.lua`

[完整替换]

```text
server/service/battle/battle_mgr.lua
```

第三课 Manager 只做：

```text
创建固定 Worker Pool
Server 分配 battle_id
按 battle_id 稳定找 Worker
把 create/command/sync/stop/simulate 转发给 Worker
把 Worker call 失败收敛成结构化错误
```

它不保存一场 Battle 的 Unit/Skill/Context。

```lua
-- 职责：创建固定 BattleWorker Shard，并按 battle_id 稳定路由所有 Battle 请求。
-- 边界：Skynet Battle Orchestration；允许 skynet.call/yield，不推进 Battle mutable core。
-- 输入/输出：纯 Lua request -> 指定 Worker 的纯 Lua result/error。
-- 生命周期：Manager/Worker 随 Battle Process 长驻；worker_count 启动后固定。
-- I/O：create_online 在进入 Worker 前读取 Linux OS 随机源签发短期恢复凭据；不进入 Battle Core。
-- 不负责：不执行 AI/导航/技能、不保存 NavigationContext、不处理客户端 fd。
local skynet = require "skynet"
local battle_config = require "config.battle"
local scenario = require "battle.scenario_1001"

local workers = {}                 -- 1-based Worker Service handle 数组；启动后只读。
local next_battle_id = 70000       -- 课程单进程 ID 分配器；只由本 Manager 修改。

-- 从 Linux OS 随机源取得一次性恢复凭据；只在创建在线 Battle 时调用，不进入 Battle Core。
-- 32 字节编码为 64 位十六进制字符；读取失败拒绝创建，不能退化成时间戳或 math.random。
-- 文件句柄在本函数内关闭；凭据只随 Start 响应交给当前客户端和目标 Worker，不写日志。
local function new_resume_token()
    local file = assert(io.open("/dev/urandom", "rb"), "OS random source unavailable")
    local bytes = file:read(32)
    file:close()
    assert(bytes ~= nil and #bytes == 32, "OS random source short read")
    return (bytes:gsub(".", function(char)
        return string.format("%02x", string.byte(char))
    end))
end

-- 根据 battle_id 选择稳定 Worker Shard。
-- battle_id 必须为非负 Lua integer；返回 handle,index；不 I/O、不 yield。
local function worker_for(battle_id)
    assert(math.type(battle_id) == "integer" and battle_id >= 0,
           "battle_id must be a non-negative integer")
    local index = battle_id % #workers + 1
    return workers[index], index
end

-- 把 Worker call 的运行时异常收敛成稳定错误；调用期间会 yield。
-- worker/command/payload 均为当前调用值；成功返回 result，失败返回 nil,error。
local function call_worker(worker, command, payload)
    local ok, result, worker_error = pcall(
        skynet.call, worker, "lua", command, payload)
    if not ok then
        skynet.error("battle worker call failed command=", command,
                     " worker=", skynet.address(worker),
                     " error=", tostring(result))
        return nil, {
            code = "WORKER_UNAVAILABLE",
            message = "battle worker unavailable",
        }
    end
    if result == nil then
        return nil, worker_error or {
            code = "WORKER_REJECTED",
            message = "battle worker rejected request",
        }
    end
    return result
end

-- 为一个客户端连接创建课程交互战斗。
-- connection_id 是 Proxy 封装的当前 Gateway 进程/连接作用域身份，不是账号 ID；ID 在 yield 前完成保留。
-- 函数会调用 Worker，因此会 yield；失败允许 battle_id 出现空洞，不回滚计数器。
local function create_online(request)
    assert(type(request) == "table", "create_online request must be table")
    assert(type(request.connection_id) == "string" and #request.connection_id > 0 and
           #request.connection_id <= 128,
           "connection_id is required")
    assert(request.scenario_id == 1001, "only scenario 1001 is available")

    next_battle_id = next_battle_id + 1
    local battle_id = next_battle_id
    local snapshot, scenario_error = scenario.make_interactive_snapshot(battle_id)
    if snapshot == nil then
        return nil, { code = scenario_error or "BAD_SCENARIO", message = "scenario unavailable" }
    end

    local worker, worker_index = worker_for(battle_id)
    local resume_token = new_resume_token()
    local result, err = call_worker(worker, "create_online", {
        battle_id = battle_id,
        worker_index = worker_index,
        controller_connection_id = request.connection_id,
        resume_token = resume_token,
        snapshot = snapshot,
    })
    if result == nil then return nil, err end
    result.worker_index = worker_index
    result.resume_token = resume_token
    return result
end

-- 恢复到新的 Gateway 连接；Worker 校验凭据后原子替换临时控制连接，并返回即时 Snapshot。
-- battle_id 决定 Shard；token 只是当前 Battle 的短期 bearer 凭据，不参与确定性模拟。
-- 跨 Worker skynet.call 会 yield；认证失败由 Worker 返回稳定错误。
local function resume_online(request)
    assert(type(request) == "table", "resume_online request must be table")
    local worker = worker_for(assert(request.battle_id))
    return call_worker(worker, "resume_online", request)
end

-- 把 PlayerCommand 稳定路由回创建该 Battle 的同一个 Worker；会 yield。
local function submit_command(request)
    assert(type(request) == "table", "submit_command request must be table")
    local worker = worker_for(assert(request.battle_id))
    return call_worker(worker, "submit_command", request)
end

-- 获取增量 Event / Snapshot；会 yield，但 Manager 不持有 Battle 内部 mutable state。
local function sync_battle(request)
    assert(type(request) == "table", "sync_battle request must be table")
    local worker = worker_for(assert(request.battle_id))
    return call_worker(worker, "sync", request)
end

-- 主动结束交互 Battle；会 yield；正常 Battle 结束也会由 Worker 自己回收。
local function stop_battle(request)
    assert(type(request) == "table", "stop_battle request must be table")
    local worker = worker_for(assert(request.battle_id))
    return call_worker(worker, "stop", request)
end

-- 保留第二课 batch 验收，但也改成按 battle_id 稳定分片。
-- snapshot 是纯值；Worker 会创建独立 Context 并快速 simulate 到结束。
local function simulate(snapshot)
    assert(type(snapshot) == "table", "simulate snapshot must be table")
    local worker = worker_for(assert(snapshot.battle_id))
    return call_worker(worker, "simulate", snapshot)
end

-- 把客户端可见的固定场景 ID 转成 Server 自己构造的权威 Snapshot。
-- request 只允许 scenario_id；返回 simulate 的 result/error；构造本身不 I/O、不 yield，simulate 会 yield。
local function simulate_scenario(request)
    assert(type(request) == "table", "simulate_scenario request must be table")
    local snapshot, err = scenario.make_snapshot(request.scenario_id)
    if snapshot == nil then
        return nil, {
            code = err or "BAD_SCENARIO",
            message = "scenario unavailable",
        }
    end
    return simulate(snapshot)
end

-- 汇总 Worker 诊断数据；按顺序 call，每次会 yield，只用于调试/验收。
local function stats()
    local result = { worker_count = #workers, workers = {} }
    for index, worker in ipairs(workers) do
        local value, err = call_worker(worker, "stats", {})
        result.workers[index] = value or {
            worker_index = index,
            error = err and err.code or "UNKNOWN",
        }
    end
    return result
end

-- 启动固定 Worker Pool；每个 newservice 都创建独立 Service/Lua State。
-- Worker 数量是 Shard 数，不与 config/battle_process.lua 的 thread 数建立 1:1 假设。
skynet.start(function()
    assert(battle_config.worker_count >= 1, "worker_count must be positive")
    assert(battle_config.tick_ms >= 10 and battle_config.tick_ms % 10 == 0,
           "tick_ms must be a positive multiple of 10ms")
    assert(battle_config.heartbeat_cs == battle_config.tick_ms // 10,
           "heartbeat_cs must match tick_ms")

    for index = 1, battle_config.worker_count do
        workers[index] = skynet.newservice("battle/battle_worker")
        assert(skynet.call(workers[index], "lua", "configure", {
            worker_index = index,
        }))
        assert(skynet.call(workers[index], "lua", "ready"))
    end

    skynet.dispatch("lua", function(_session, _source, command, payload)
        if command == "ready" then
            skynet.retpack(#workers == battle_config.worker_count)
        elseif command == "create_online" then
            skynet.retpack(create_online(assert(payload)))
        elseif command == "resume_online" then
            skynet.retpack(resume_online(assert(payload)))
        elseif command == "submit_command" then
            skynet.retpack(submit_command(assert(payload)))
        elseif command == "sync" then
            skynet.retpack(sync_battle(assert(payload)))
        elseif command == "stop" then
            skynet.retpack(stop_battle(assert(payload)))
        elseif command == "simulate_scenario" then
            skynet.retpack(simulate_scenario(assert(payload)))
        elseif command == "simulate" then
            skynet.retpack(simulate(assert(payload)))
        elseif command == "stats" then
            skynet.retpack(stats())
        else
            error("unknown battle manager command: " .. tostring(command))
        end
    end)
end)
```

### 8.1 这里为什么不用 `battle_id -> worker` map

当前 Worker 数固定，而且路由函数纯计算：

```text
battle_id % worker_count
```

所以无需额外维护：

```lua
battle_routes[battle_id] = worker
```

少一个可变表，就少一个恢复/清理/一致性问题。

以后如果改成：

```text
按负载迁移 Battle
动态扩缩容
跨进程 Shard
```

才需要更复杂的 routing table / consistent hash / directory service。

本课不提前做。

### 8.2 `RunAutoBattle` 继续只接受场景 ID，而不是把 Snapshot 暴露给客户端

第二课已经固定了一个很重要的权威边界：Unity 的 `RunAutoBattle` 只能选择 Server 已发布场景，不能上传单位 HP、位置、技能、地图版本等权威输入。第三课虽然把 Manager 改成稳定 Shard，但这个边界不变。

上面 `battle_mgr.lua` 的完整累计代码已经同时保留两个入口：

```text
simulate_scenario({scenario_id=1001})
  给 Gateway/Unity 使用，只允许选择 Server 场景

simulate(snapshot)
  给 batch regression / Server 内部测试使用，可以直接喂冻结 Snapshot
```

`simulate_scenario()` 只负责：

```text
scenario_id
-> scenario.make_snapshot()
-> simulate(snapshot)
-> stable worker shard
-> battle_core.simulate()
```

它不是第二套战斗逻辑。这样第三课扩展在线战斗以后，第二课已经建立的“客户端不能上传权威 Snapshot”仍然成立。

---

# 第五部分：BattleWorker 从“一次 simulate”升级成“长期承载多场 Battle”

## 9. Worker 内部真正拥有的对象

第二课：

```text
收到 simulate
-> new NavigationContext
-> simulate 到结束
-> close
```

第三课在线模式：

```text
收到 create_online
-> new NavigationContext
-> battle_core.create
-> 保存 BattleRuntime
-> heartbeat 多次 step
-> command 多次进入
-> sync 多次读取
-> Battle End / stop
-> context:close
-> 删除 BattleRuntime
```

一个 Worker 同时有多场：

```text
BattleWorker#2 Lua State

battles[70001]
  core_state
  context A
  command queue A
  event buffer A

battles[70005]
  core_state
  context B
  command queue B
  event buffer B

battles[70009]
  core_state
  context C
  command queue C
  event buffer C
```

Context 绝不能在 Battle 之间复用。

## 10. Worker heartbeat 为什么一 Worker 一个，而不是一 Battle 一个 Timer

不要：

```text
Battle A -> 一个 skynet.timeout 循环
Battle B -> 一个 skynet.timeout 循环
Battle C -> 一个 skynet.timeout 循环
...
```

课程采用：

```text
BattleWorker
-> 一个 heartbeat
-> 依次推进自己拥有的所有 online Battle
```

原因：

```text
Timer 数量固定
调度位置明确
资源预算容易观察
所有 Battle 都仍由同一个 Service owner 串行进入 core
```

这不是宣称所有商业游戏必须这样实现。它是当前“固定 Shard + 每 Shard 多场 Battle”的最小真实方案。

## 11. 新的 `battle_worker.lua`

[完整替换]

```text
server/service/battle/battle_worker.lua
```

这一版 Worker 有三个很重要的变化：

```text
第二课：
一次 simulate -> 一次 Context -> 模拟到结束 -> close

第三课：
一个 BattleWorker Service -> 长期拥有多场 BattleRuntime
每场 BattleRuntime -> 独立 Context + core_state + command queue + Event ring
一个 Worker heartbeat -> 推进该 Shard 上所有在线 Battle
```

`BattleWorker` 是 **Battle Shard Service**，不是“一场 Battle”。它也不是固定 OS Thread。Skynet 仍然可以把这个 Service 的不同消息协程调度到自己的 Worker Thread 上执行；课程依赖的是 Service/Lua State 的 owner 关系，而不是线程亲和性。

完整实现如下。这里先使用后文即将补齐的 `battle_core.create/step/drain_events/build_snapshot/enqueue_player_command`，这样你可以先看清 Skynet 层的 ownership，再进入技能和同步细节。

```lua
-- 职责：作为长期 Battle Shard，拥有多场在线 Battle 的 Context、Core State 和同步缓存。
-- 边界：Skynet Service Adapter；Skynet Timer/消息只存在于本层，battle_core 始终 no-yield。
-- 输入/输出：configure/create/command/sync/stop/simulate/stats 的纯 Lua record。
-- 生命周期：Service 随 Battle Process 长驻；每场 Context 从 create 到 finish/stop 独占。
-- 不负责：不监听网络、不解析 Protobuf、不访问 DB、不让 Battle Core 调 Skynet。
local skynet = require "skynet"
local navigation = require "flywow_navigation"
local battle_core = require "battle.battle_core"
local battle_config = require "config.battle"

local state = {
    worker_index = nil,        -- BattleMgr configure 一次；之后只读。
    battles = {},              -- battle_id -> BattleRuntime；当前 Service 独占。
    active_ids = {},           -- 未结束在线 Battle 的稳定数组；heartbeat 顺序推进。
    active_index = {},         -- battle_id -> active_ids index；用于 O(1) swap-remove。
    heartbeat_started = false, -- 每个 Worker 只允许一个 heartbeat 链。
    next_heartbeat_cs = nil,   -- 下一理论墙钟 deadline；只负责调度，不进入 Battle 规则。
}

-- 验证一个 battle_id 是否应该落在当前 Shard。
-- 参数 battle_id：正整数 Battle ID；返回无；路由错误直接 assert，避免静默双写状态。
-- 不执行 I/O、不分配外部资源、不 yield。
local function assert_shard(battle_id)
    assert(math.type(battle_id) == "integer" and battle_id > 0,
           "battle_id must be a positive integer")
    local expected = battle_id % battle_config.worker_count + 1
    assert(expected == state.worker_index,
           string.format("battle %d routed to worker %d but expected %d",
                         battle_id, state.worker_index, expected))
end

-- 把未结束 Battle 加入 heartbeat 数组；重复加入表示生命周期 bug。
-- 返回无；只修改当前 Service Lua State，不 I/O、不 yield。
local function add_active(battle_id)
    assert(state.active_index[battle_id] == nil, "battle already active")
    local index = #state.active_ids + 1
    state.active_ids[index] = battle_id
    state.active_index[battle_id] = index
end

-- 从 heartbeat 数组 O(1) 移除 Battle。
-- swap-remove 会改变“不同 Battle 之间”的遍历顺序，但不同 Battle 相互独立，因此不属于单场确定性输入。
-- 返回无；不 I/O、不 yield。
local function remove_active(battle_id)
    local index = state.active_index[battle_id]
    if index == nil then return end

    local last_index = #state.active_ids
    local last_id = state.active_ids[last_index]
    state.active_ids[index] = last_id
    state.active_index[last_id] = index
    state.active_ids[last_index] = nil
    state.active_index[battle_id] = nil
end

-- 创建真正的有界环形 Event Buffer。
-- slots 固定最多 max_events_buffered 个元素；head 指向当前最旧事件。
-- first_seq 只表示当前仍可被增量拉取的第一条 seq，不参与 Battle 规则。
local function new_event_buffer()
    return {
        slots = {},
        head = 1,
        count = 0,
        first_seq = 1,
    }
end

-- 追加 Core 新事件；Buffer 满时覆盖最旧槽位，而不是 table.remove(1) 做 O(n) 搬移。
-- events 按 seq 递增传入；函数只保存纯值引用，Core drain 后不再修改这些 Event。
-- 不 I/O、不 yield；时间复杂度 O(new_events)。
local function append_events(buffer, events)
    local capacity = battle_config.max_events_buffered
    assert(capacity >= 1, "max_events_buffered must be positive")

    for _, event in ipairs(events) do
        assert(type(event) == "table" and math.type(event.seq) == "integer",
               "online event must have integer seq")

        if buffer.count < capacity then
            local index = ((buffer.head + buffer.count - 1) % capacity) + 1
            buffer.slots[index] = event
            buffer.count = buffer.count + 1
            if buffer.count == 1 then
                buffer.first_seq = event.seq
            end
        else
            -- head 当前就是最旧槽位；覆盖后 head 前移到新的最旧事件。
            buffer.slots[buffer.head] = event
            buffer.head = buffer.head % capacity + 1
            buffer.first_seq = buffer.slots[buffer.head].seq
        end
    end
end

-- 按逻辑顺序读取 after_seq 之后的有限 Event。
-- 返回新数组，不暴露 ring 内部 slots；不修改 Buffer、不 I/O、不 yield。
local function collect_events_after(buffer, after_seq)
    local result = {}
    if buffer.count == 0 then return result end

    local capacity = battle_config.max_events_buffered
    for offset = 0, buffer.count - 1 do
        local index = ((buffer.head + offset - 1) % capacity) + 1
        local event = buffer.slots[index]
        if event.seq > after_seq then
            result[#result + 1] = event
            if #result >= battle_config.max_events_per_sync then break end
        end
    end
    return result
end

-- 生成当前权威 Snapshot。
-- Snapshot 必须是可跨 Service/cluster 的纯 Lua 值，不得带 Path userdata、Context 或 Service handle。
-- 不 I/O、不 yield；分配量与当前 Battle 可见状态规模成正比。
local function refresh_snapshot(runtime)
    runtime.latest_snapshot = battle_core.build_snapshot(runtime.core_state)
end

-- 显式关闭一场 Battle 的 Native Context 并移除 Runtime。
-- 可以从 stop、保留超时、异常清理重复进入；closed 保证释放幂等。
-- skynet.error 只写日志，不做 RPC；函数不 yield。
local function close_runtime(runtime, reason)
    if runtime.closed then return end
    runtime.closed = true
    remove_active(runtime.battle_id)

    if runtime.context ~= nil then
        runtime.context:close()
        runtime.context = nil
    end

    state.battles[runtime.battle_id] = nil
    skynet.error("BATTLE_RUNTIME_CLOSED battle=", runtime.battle_id,
                 " worker=", state.worker_index,
                 " reason=", reason)
end

-- 统计当前仍保留的 finished Runtime，并找出最老一个。
-- pairs() 顺序不参与 Battle 逻辑；这里只做生命周期回收。相同 finished_at_cs 用更小 battle_id 稳定打破平局。
-- 返回 count,oldest；不 I/O、不 yield。
local function finished_stats()
    local count = 0
    local oldest = nil
    for _, runtime in pairs(state.battles) do
        if runtime.finished_result ~= nil then
            count = count + 1
            if oldest == nil or
               runtime.finished_at_cs < oldest.finished_at_cs or
               (runtime.finished_at_cs == oldest.finished_at_cs and
                runtime.battle_id < oldest.battle_id) then
                oldest = runtime
            end
        end
    end
    return count, oldest
end

-- 回收已结束 Battle。wall clock 只决定“结果缓存保留多久”，绝不参与伤害、CD、Buff 或 Event 顺序。
-- 超过 finished_retention_cs 或 finished cache 数量上限都会 close；不执行外部 RPC、不 yield。
local function cleanup_finished(now_cs)
    local expired = {}
    for _, runtime in pairs(state.battles) do
        if runtime.finished_result ~= nil and
           now_cs - runtime.finished_at_cs >= battle_config.finished_retention_cs then
            expired[#expired + 1] = runtime
        end
    end
    table.sort(expired, function(a, b) return a.battle_id < b.battle_id end)
    for _, runtime in ipairs(expired) do
        close_runtime(runtime, "FINISHED_RETENTION_EXPIRED")
    end

    while true do
        local count, oldest = finished_stats()
        if count <= battle_config.max_finished_retained or oldest == nil then break end
        close_runtime(oldest, "FINISHED_CACHE_LIMIT")
    end
end

-- 推进一场在线 Battle 一个逻辑 Tick；从进入 core 到返回全程 no-yield。
-- Battle 完成后立即退出 active heartbeat，但保留最终 Event/Snapshot 一小段墙钟时间供客户端拉取。
local function step_runtime(runtime)
    battle_core.step(runtime.core_state, runtime.context)
    append_events(runtime.event_buffer,
                  battle_core.drain_events(runtime.core_state))

    if runtime.core_state.logic_tick % battle_config.snapshot_interval_ticks == 0 then
        refresh_snapshot(runtime)
    end

    if battle_core.is_finished(runtime.core_state) then
        runtime.finished_result = battle_core.finish(runtime.core_state)
        append_events(runtime.event_buffer,
                      battle_core.drain_events(runtime.core_state))
        refresh_snapshot(runtime)
        runtime.finished_at_cs = skynet.now()
        remove_active(runtime.battle_id)
    end
end

-- 推进当前 Shard 所有未结束在线 Battle 一次。
-- heartbeat 回调内没有 skynet.call/sleep/socket/DB，因此一场 step 不会被同 Service 的另一个消息协程插进中间。
-- active_ids 可能因某场结束被 swap-remove，所以使用 while 并只在当前 ID 仍 active 时递增下标。
local function step_all_once()
    local index = 1
    while index <= #state.active_ids do
        local battle_id = state.active_ids[index]
        local runtime = state.battles[battle_id]
        if runtime ~= nil and runtime.finished_result == nil then
            step_runtime(runtime)
        end
        if state.active_ids[index] == battle_id then
            index = index + 1
        end
    end
end

-- Worker 唯一 heartbeat。
-- Skynet timeout 使用 1/100 秒墙钟，只决定应该推进多少个 logical tick；Battle 内仍只看 logic_tick/logic_ms。
-- 单轮最多追 max_catchup_ticks，持续落后会反映为 heartbeat lag，而不是一次回调无限追赶拖死 Service。
local function heartbeat()
    if not state.heartbeat_started then return end

    local now_cs = skynet.now()
    local due = 1
    if state.next_heartbeat_cs ~= nil and now_cs > state.next_heartbeat_cs then
        due = due + (now_cs - state.next_heartbeat_cs) // battle_config.heartbeat_cs
    end
    due = math.min(due, battle_config.max_catchup_ticks)

    for _ = 1, due do
        step_all_once()
    end
    cleanup_finished(skynet.now())

    local base_cs = state.next_heartbeat_cs or now_cs
    state.next_heartbeat_cs = base_cs + due * battle_config.heartbeat_cs
    local delay_cs = math.max(1, state.next_heartbeat_cs - skynet.now())
    skynet.timeout(delay_cs, heartbeat)
end

-- 配置当前 Shard 身份。Manager 创建 Service 后显式注入 worker_index，避免业务代码依赖 Lua chunk vararg。
-- 只允许调用一次；成功后启动唯一 heartbeat。timeout 注册不等待回包，当前函数本身不 yield。
local function configure(request)
    assert(state.worker_index == nil, "worker already configured")
    assert(type(request) == "table", "configure request must be table")

    local index = assert(request.worker_index)
    assert(math.type(index) == "integer" and index >= 1 and
           index <= battle_config.worker_count, "invalid worker_index")

    state.worker_index = index
    state.heartbeat_started = true
    state.next_heartbeat_cs = skynet.now() + battle_config.heartbeat_cs
    skynet.timeout(battle_config.heartbeat_cs, heartbeat)
    return true
end

-- 创建一场长期在线 Battle。
-- controller_connection_id 来自 Gateway metadata，不来自客户端 Proto；Context/CoreState 从这里开始由当前 Worker 独占。
-- 全过程同步，不执行外部 call/yield；任何失败都会显式关闭已经创建的 Context。
local function create_online(request)
    assert(type(request) == "table", "create_online request must be table")
    local battle_id = assert(request.battle_id)
    assert_shard(battle_id)

    if state.battles[battle_id] ~= nil then
        return nil, { code = "BATTLE_EXISTS", message = "battle already exists" }
    end
    if #state.active_ids >= battle_config.max_battles_per_worker then
        return nil, { code = "WORKER_BUSY", message = "worker battle limit reached" }
    end

    local snapshot = assert(request.snapshot)
    local context, nav_error = navigation.new_context(
        snapshot.map_id,
        snapshot.map_version)
    if context == nil then
        return nil, {
            code = nav_error and nav_error.code or "CONTEXT_CREATE_FAILED",
            message = nav_error and nav_error.message or "new_context failed",
        }
    end

    local ok, core_or_error = xpcall(
        battle_core.create,
        debug.traceback,
        snapshot,
        context,
        "online")
    if not ok then
        context:close()
        return nil, { code = "BATTLE_CREATE_FAILED", message = core_or_error }
    end

    local runtime = {
        battle_id = battle_id,
        controller_connection_id = assert(request.controller_connection_id),
        resume_token = assert(request.resume_token), -- 只由 BattleMgr 从 OS 随机源注入；不进入 Snapshot/Event。
        context = context,
        core_state = core_or_error,
        event_buffer = new_event_buffer(),
        latest_snapshot = nil,
        finished_result = nil,
        finished_at_cs = nil,
        closed = false,
    }
    state.battles[battle_id] = runtime
    add_active(battle_id)
    append_events(runtime.event_buffer,
                  battle_core.drain_events(runtime.core_state))
    refresh_snapshot(runtime)

    return {
        battle_id = battle_id,
        logic_tick = runtime.core_state.logic_tick,
        snapshot = runtime.latest_snapshot,
    }
end

-- 新连接持有 Start 时收到的短期凭据时，重新绑定当前 Battle 的控制权。
-- token 不来自日志/URL；失败统一返回 NOT_CONTROLLER，避免泄露 Battle 是否存在。
-- 当前 Service 内比较和替换之间无 yield；返回即时 Snapshot 作为恢复锚点。
local function resume_online(request)
    assert(type(request) == "table", "resume_online request must be table")
    local battle_id = assert(request.battle_id)
    assert_shard(battle_id)
    local runtime = state.battles[battle_id]
    local token = request.resume_token
    if runtime == nil or type(token) ~= "string" or #token ~= 64 or
       token ~= runtime.resume_token then
        return nil, { code = "NOT_CONTROLLER", message = "resume denied" }
    end
    assert(type(request.connection_id) == "string" and #request.connection_id > 0,
           "invalid transport session")
    runtime.controller_connection_id = request.connection_id
    refresh_snapshot(runtime)
    return {
        battle_id = battle_id,
        snapshot = runtime.latest_snapshot,
        finished = runtime.finished_result ~= nil,
    }
end

-- 接收 PlayerCommand。
-- 只校验控制连接、Battle 生命周期、command_seq/队列预算并入队；路径、技能和伤害在下一 logical tick 才执行。
-- 不 I/O、不 yield；返回值是可序列化纯 table。
local function submit_command(request)
    assert(type(request) == "table", "submit_command request must be table")
    local battle_id = assert(request.battle_id)
    assert_shard(battle_id)

    local runtime = state.battles[battle_id]
    if runtime == nil then
        return nil, { code = "BATTLE_NOT_FOUND", message = "battle not found" }
    end
    if runtime.controller_connection_id ~= request.connection_id then
        return nil, { code = "NOT_CONTROLLER", message = "connection does not control battle" }
    end
    if runtime.finished_result ~= nil then
        return nil, { code = "BATTLE_FINISHED", message = "battle already finished" }
    end

    local accepted, info = battle_core.enqueue_player_command(
        runtime.core_state,
        request.command,
        battle_config.max_commands_per_battle)
    if not accepted then return nil, info end
    return info
end

-- 拉取 after_event_seq 后的增量 Event。
-- 若客户端已经落到 ring buffer 之前，event_gap=true，并在本次调用即时构造新 Snapshot，不能返回一秒前的周期快照。
-- want_snapshot 同样强制即时刷新；不 I/O、不 yield。
local function sync_runtime(request)
    assert(type(request) == "table", "sync request must be table")
    local battle_id = assert(request.battle_id)
    assert_shard(battle_id)

    local runtime = state.battles[battle_id]
    if runtime == nil then
        return nil, { code = "BATTLE_NOT_FOUND", message = "battle not found" }
    end
    if runtime.controller_connection_id ~= request.connection_id then
        return nil, { code = "NOT_CONTROLLER", message = "connection does not control battle" }
    end

    local after_seq = request.after_event_seq or 0
    assert(math.type(after_seq) == "integer" and after_seq >= 0,
           "after_event_seq must be a non-negative integer")

    local buffer = runtime.event_buffer
    local gap = buffer.count > 0 and after_seq < buffer.first_seq - 1
    if gap or request.want_snapshot then
        refresh_snapshot(runtime)
    end

    return {
        battle_id = battle_id,
        logic_tick = runtime.core_state.logic_tick,
        first_available_seq = buffer.count > 0 and
            buffer.first_seq or (runtime.core_state.next_event_seq + 1),
        latest_event_seq = runtime.core_state.next_event_seq,
        gap = gap,
        snapshot = (gap or request.want_snapshot) and runtime.latest_snapshot or nil,
        events = collect_events_after(buffer, after_seq),
        finished = runtime.finished_result ~= nil,
        result = runtime.finished_result,
    }
end

-- 主动停止并释放一场在线 Battle。
-- 控制权按当前 Gateway connection_id 校验；成功返回关闭前的最终 Snapshot。
-- 不执行外部 call/yield；Context 立即显式 close。
local function stop_runtime(request)
    assert(type(request) == "table", "stop request must be table")
    local battle_id = assert(request.battle_id)
    assert_shard(battle_id)

    local runtime = state.battles[battle_id]
    if runtime == nil then
        return nil, { code = "BATTLE_NOT_FOUND", message = "battle not found" }
    end
    if runtime.controller_connection_id ~= request.connection_id then
        return nil, { code = "NOT_CONTROLLER", message = "connection does not control battle" }
    end

    local snapshot = battle_core.build_snapshot(runtime.core_state)
    close_runtime(runtime, "STOP_REQUEST")
    return { battle_id = battle_id, snapshot = snapshot }
end

-- 第二课兼容路径：一次性快速模拟。
-- 为避免教学 Demo 误导：它与 online 共用同一个 battle_core，但不要在性能验收时让长 batch simulate 和在线 Battle 抢同一 Worker；生产项目通常会分 QoS/池。
-- 当前函数从进入 Core 到返回 no-yield，成功或异常都显式 close Context。
local function simulate(snapshot)
    assert(type(snapshot) == "table", "simulate snapshot must be table")
    assert_shard(assert(snapshot.battle_id))

    local context, nav_error = navigation.new_context(
        snapshot.map_id,
        snapshot.map_version)
    if context == nil then
        return nil, {
            code = nav_error and nav_error.code or "CONTEXT_CREATE_FAILED",
            message = nav_error and nav_error.message or "new_context failed",
        }
    end

    local ok, result = xpcall(
        battle_core.simulate,
        debug.traceback,
        snapshot,
        context)
    context:close()

    if not ok then
        return nil, { code = "SIMULATE_FAILED", message = result }
    end
    return result
end

-- 返回当前 Shard 诊断数据。
-- service_mqlen 是 Skynet Service mailbox 长度，不等于某场 Battle 的 PlayerCommand queue。
-- 仅用于 debug/验收；不影响 Battle 结果。
local function stats()
    local finished_count = finished_stats()
    return {
        worker_index = state.worker_index,
        active_battles = #state.active_ids,
        retained_finished = finished_count,
        service_mqlen = skynet.mqlen(),
        now_cs = skynet.now(),
        next_heartbeat_cs = state.next_heartbeat_cs or 0,
    }
end

-- 安装固定签名 Lua dispatch。session/source 是 Skynet 元数据；业务稳定接口不转发可变参数。
skynet.start(function()
    skynet.dispatch("lua", function(_session, _source, command, payload)
        if command == "configure" then
            skynet.retpack(configure(assert(payload)))
        elseif command == "ready" then
            skynet.retpack(state.worker_index ~= nil and state.heartbeat_started)
        elseif command == "create_online" then
            skynet.retpack(create_online(assert(payload)))
        elseif command == "resume_online" then
            skynet.retpack(resume_online(assert(payload)))
        elseif command == "submit_command" then
            skynet.retpack(submit_command(assert(payload)))
        elseif command == "sync" then
            skynet.retpack(sync_runtime(assert(payload)))
        elseif command == "stop" then
            skynet.retpack(stop_runtime(assert(payload)))
        elseif command == "simulate" then
            skynet.retpack(simulate(assert(payload)))
        elseif command == "stats" then
            skynet.retpack(stats())
        else
            error("unknown battle worker command: " .. tostring(command))
        end
    end)
end)
```

### 11.1 Manager 如何创建多个 Worker

项目自有 Lua 稳定接口不使用 `...`。因此 Worker index 不通过 Lua chunk vararg 继续传播，而是 `newservice()` 后显式配置：

```lua
for index = 1, battle_config.worker_count do
    workers[index] = skynet.newservice("battle/battle_worker")
    assert(skynet.call(workers[index], "lua", "configure", {
        worker_index = index,
    }))
    assert(skynet.call(workers[index], "lua", "ready"))
end
```

这里三个动作的语义不同：

```text
newservice
  -> 让 launcher 创建新的 snlua Service
  -> 新 Service 有自己的 Service Context / mailbox / Lua State
  -> Manager 在等待 LAUNCH 返回时会 yield

configure
  -> 把当前业务 Shard index 作为明确 record 注入
  -> Worker 启动唯一 heartbeat

ready
  -> 启动门禁
  -> Battle Process 不在 Worker 未完成初始化时对外发布 READY
```

### 11.2 heartbeat callback 为什么可以直接推进多场 Battle

关键不是“Skynet 单线程”，而是当前 callback 从进入核心到返回 **没有 yield 点**：

```text
heartbeat coroutine
  -> Battle A step      no-yield
  -> Battle B step      no-yield
  -> Battle C step      no-yield
  -> cleanup lifecycle  no-yield
  -> return
```

因此同一 Service 的 `submit_command/sync` 消息协程只能在这些完整 step 之间获得执行机会，不会插进某场 Battle 的半步状态。

如果以后在 `battle_core.step()` 内加入：

```lua
skynet.call(db, "lua", "save", save_request)
```

问题不是单纯“DB 慢”，而是当前协程会挂起；同一 Service 里的其他消息协程可以继续执行，从而看到半更新状态。第三课通过 **core no-yield** 从结构上消掉这类重入，而不是用锁把问题盖住。

### 11.3 已结束 Battle 为什么不能立刻删除，也不能永久保留

在线 Client 可能在最后一个 Tick 之后才来下一次 `SyncBattle`。如果 `BATTLE_END` 一生成就删除 Runtime，客户端会得到 `BATTLE_NOT_FOUND`，最终 Event/Snapshot 反而丢失。

所以本课使用两个明确上限：

```text
finished_retention_cs = 3000       -> 最多保留 30 秒
max_finished_retained = 128        -> 每个 Worker 最多保留 128 个 finished Runtime
```

这段墙钟时间只属于 **Server 生命周期缓存**：

```text
可以影响：最终结果什么时候被回收
不能影响：伤害、技能 CD、Buff 过期、Projectile、Event seq、胜负
```

这也是区分 `skynet.now()` 和 Battle `logic_tick` 的一个实际例子。

### 11.4 为什么这里要真正做 ring buffer

在线 Event 缓存是热路径。下面这种写法：

```lua
-- 不采用：首元素删除会搬移整个数组。
table.remove(events, 1)
```

在缓存接近 1024 条时，每覆盖一条都要 O(n) 搬移。

本课用固定 `slots/head/count`：

```text
append     O(1)
覆盖最旧   O(1)
按逻辑顺序读取 O(k)
```

这不是为了炫数据结构，而是因为 **有界缓存本身就是在线同步合同的一部分**。

# 第六部分：PlayerCommand——客户端提交意图，Server 决定结果

## 12. Command 只描述“想做什么”

第三课正式加入：

```text
MoveCommand
CastSkillCommand
```

客户端不能提交：

```text
我的最终位置是 X
我的 Path 是这些点
这次技能命中了
目标扣了 100 HP
目标死了
```

客户端可以提交：

```text
我想走到这个 WorldPosition
我想对 unit_id=2001 使用 skill_id=1002
我想在这个 WorldPosition 放 FireWall
```

## 13. Command 的稳定字段

Battle Core 内使用的纯 Lua record：

```lua
{
    unit_id = 1001,
    command_seq = 17,
    kind = "MOVE",
    move = {
        target_world = { x_mm = 3000, y_mm = 0, z_mm = -2000 },
    },
}
```

或：

```lua
{
    unit_id = 1001,
    command_seq = 18,
    kind = "CAST",
    cast = {
        skill_id = 1004,
        target_unit_id = 0,
        target_world = { x_mm = 5000, y_mm = 0, z_mm = 1000 },
        orientation = "X_AXIS",
    },
}
```

### 13.1 `command_seq` 解决什么

最小规则：

```text
每场 Battle / 每个 PlayerUnit 的 command_seq 单调递增
seq <= last_accepted_seq -> STALE_OR_DUPLICATE_COMMAND
```

本课不实现网络层重传协议，但 Server 仍要有幂等边界，避免客户端重复提交同一操作时重复施法。

### 13.2 Command 在哪个 Tick 生效

Worker 收到 command 时，不立即推进战斗。

Core 只做：

```text
current logic_tick = 100
收到 command
-> apply_tick = 101
-> 放进 command_queue
```

下一个 `step()` 的第一阶段统一消费 `apply_tick == current_tick` 的 command。

这样：

```text
网络到达时间
-> 被 Server 映射成明确 logical tick
-> Replay / Regression 可记录
```

## 14. 在 `battle_core.lua` 增加 command queue

[局部修改]

```text
server/lualib/battle/battle_core.lua
```

第三课的最终命名从这里就固定下来，后面不要再出现另一套 `pending_commands/last_command_seq`：

```text
BattleState.command_queue
BattleState.recorded_commands
UnitRuntime.last_received_command_seq
BattleState.logic_tick
```

为什么 `last_received_command_seq` 放 UnitRuntime，而不是 `state.last_command_seq[unit_id]`：它本来就是“这个 Player Unit 最近接受到哪个 seq”的状态，跟 Unit 生命周期一致；没有必要额外维护第二张索引表。

在线命令接收入口最终会变成：

```lua
-- 在线入口：把命令映射到下一 Tick；这里只做结构/序号/资源预算，不提前执行技能或导航。
function M.enqueue_player_command(state, command, max_queue)
    assert(type(state) == "table" and not state.finished,
           "cannot enqueue command to finished battle")
    assert(math.type(max_queue) == "integer" and max_queue >= 1,
           "max_queue must be positive integer")
    if #state.command_queue >= max_queue then
        return false, {
            code = "COMMAND_QUEUE_FULL",
            message = "command queue limit reached",
        }
    end

    -- normalize_player_command 会重新查 Player Unit、复制 WorldPosition、检查 seq，
    -- 但不会寻路/施法；失败时 state 仍没有提交任何 command 状态。
    local normalized, unit_or_error = normalize_player_command(state, command)
    if normalized == nil then return false, unit_or_error end
    if #state.recorded_commands >= MAX_RECORDED_COMMANDS then
        return false, {
            code = "COMMAND_RECORD_LIMIT",
            message = "recorded command budget reached",
        }
    end

    local unit = unit_or_error
    local recorded = {
        unit_id = normalized.unit_id,
        command_seq = normalized.command_seq,
        apply_tick = normalized.apply_tick,
        kind = normalized.kind,
        skill_id = normalized.skill_id,
        target_unit_id = normalized.target_unit_id,
        orientation = normalized.orientation,
        target_world = normalized.target_world and
            copy_position(normalized.target_world) or nil,
    }

    -- 所有可能失败的预算/结构检查都已经完成，最后才一次性 commit。
    state.recorded_commands[#state.recorded_commands + 1] = recorded
    state.command_queue[#state.command_queue + 1] = normalized
    unit.last_received_command_seq = normalized.command_seq
    return true, {
        command_seq = normalized.command_seq,
        apply_tick = normalized.apply_tick,
    }
end
```

这里的顺序很重要。不要先写：

```text
last_received_command_seq = seq
```

然后才发现 `recorded_commands` 已满。否则一个**被拒绝的命令**也会吃掉 seq，客户端重试同一个命令反而会收到 stale。

消费时不对数组反复 `table.remove(1)`，而是一次分离当前 Tick 与未来命令，再稳定排序：

```lua
-- 取出当前 Tick 应执行命令；未来命令保留在新数组中。
local function take_commands_for_tick(state)
    local ready = {}
    local future = {}
    for _, command in ipairs(state.command_queue) do
        if command.apply_tick <= state.logic_tick then
            ready[#ready + 1] = command
        else
            future[#future + 1] = command
        end
    end
    state.command_queue = future
    table.sort(ready, function(a, b)
        if a.unit_id ~= b.unit_id then return a.unit_id < b.unit_id end
        return a.command_seq < b.command_seq
    end)
    return ready
end
```

在线接收时 `apply_tick` 永远是“接收时当前逻辑 Tick + 1”，所以同一个 `BattleWorker` 中不会出现来自在线入口的过去 Tick；batch regression 则直接注入已经记录好的 `apply_tick`，后面 39.8 的累计完整代码会把两种入口统一起来。

### 14.1 接收时验证与执行时验证为什么都要有

接收时：

```text
结构
seq
资源预算
```

执行时：

```text
Unit 还活着吗
当前是否允许移动
Skill 是否存在
CD 是否结束
TargetMask 是否匹配
目标是否还活着
距离是否仍合法
```

网络到达和实际 apply tick 之间可能已经发生战斗状态变化，所以不能只在 Gateway 收包那一刻验证业务合法性。

# 第七部分：先把 Battle Unit 扩展到 Ground / Air，再做技能

## 15. Unit 最小模型

第三课只增加技能和移动真正需要的字段。

不要建立几十种 RPG Attribute。

单位核心：

```lua
{
    id = 1001,
    camp = 1,
    control = "PLAYER",          -- PLAYER / AI
    movement_layer = "GROUND",   -- GROUND / AIR

    position = { x_mm = 0, y_mm = 0, z_mm = 0 },
    base_move_speed_mm_per_sec = 2500,

    hp = 100,
    max_hp = 100,

    agent_profile_id = 1,         -- Ground 使用
    flight_height_mm = 0,         -- Air 使用

    target_id = nil,
    move_target = nil,
    path = nil,

    cooldowns = {},
    buffs = {},
}
```

### 15.1 为什么不做通用 Attribute Tree

本课只真正需要：

```text
HP
MoveSpeed
```

Attack Damage 直接来自 SkillDefinition。

所以先实现：

```text
base_move_speed
+ Buff modifier
-> effective_move_speed
```

不创建：

```text
AttributeManager
FormulaGraph
PropertyTree
ModifierPipeline 20 种阶段
```

真实需求出现后再演进。

## 16. Ground / Air TargetMask

固定 bit：

```lua
local TARGET_GROUND = 0x01
local TARGET_AIR = 0x02
local TARGET_ALL = TARGET_GROUND | TARGET_AIR
```

单位：

```lua
unit.target_layer = unit.movement_layer == "AIR" and TARGET_AIR or TARGET_GROUND
```

技能：

```lua
target_mask = TARGET_GROUND
```

或：

```lua
target_mask = TARGET_ALL
```

Server 检查：

```lua
(skill.target_mask & target.target_layer) ~= 0
```

Unity 模型看起来“飞在空中”不构成 Server Air 身份。

### 16.1 Air 是完整战斗目标层，不只是移动表现

`movement_layer` 和 `target_layer` 解决的是两个不同问题：

```text
movement_layer
  -> 这个单位怎样移动
  -> GROUND 使用 Ground Grid / DynamicOccupancy
  -> AIR 使用 Air Grid / NoFly

target_layer
  -> 这个单位能被哪些技能选中
  -> TARGET_GROUND / TARGET_AIR
```

因此一个 Flying Dragon 可以同时满足：

```text
movement_layer = AIR
 target_layer = TARGET_AIR
```

而技能是否允许命中它，只看 SkillDefinition 的 `target_mask`。本课固定验证下面四种组合：

```text
Ground -> Ground
  Slash：允许

Ground -> Air
  Slash：拒绝
  Fireball / FrostBolt：允许

Air -> Ground
  Fireball：允许

Air -> Air
  Fireball：允许
```

所以第三课里的空中单位不是“只会在天上移动的装饰对象”。它拥有和地面单位相同的：

```text
camp
HP / Death
Skill cooldown
Buff
AI target
BattleEvent / Snapshot
```

区别只在移动导航层和技能 TargetMask。后面的 AirCombat Golden Case 会专门放两只 Flying Dragon，真实跑通 Air -> Air；混合场景则验证 Air -> Ground。

本课仍然不把 Air 扩成完整 3D 空域。支持的是固定离地高度的 2D Air Grid：

```text
支持：空对空、空对地、飞越 Ground 障碍、绕 NoFly
不支持：同一 XZ 多飞行高度层、俯冲/爬升 3D 寻路、空中动态碰撞体积
```

---

# 第八部分：Air Grid / NoFly——第三课新增的地图知识

## 17. 空中导航的课程模型

本课只实现：

```text
二维 XZ Air Grid
NoFly Cell
固定离地高度
```

定义：

```text
FlyingEnemy 可以越过普通 Ground blocked cell
但不能进入 NoFly
worldY = groundHeight(XZ) + flightHeight
```

不实现：

```text
3D voxel
同一个 XZ 多个飞行层
动态空中 crowd
空中碰撞体积导航
```

## 18. 为什么 Air Grid 单独做资产，不修改 BMAP V1

BMAP V1 已经是第一课冻结的 Ground Asset Contract。

第三课不要为了 NoFly 静默改变 BMAP payload。

新增 sidecar：

```text
shared/navigation/<已验证候选目录>/map.amap
```

身份仍然绑定：

```text
map_id
map_version
width
height
```

坐标系、origin、cell_size 继续以同版本 BMAP 为准。

这样：

```text
BMAP = Ground static navigation
AMAP = Air NoFly overlay
```

二者必须同 map/version 配对加载。

## 19. AMAP V1 最小格式

本课固定 little-endian：

```text
Header
  magic[4]       = "AMAP"
  format_version = 1
  header_size
  map_id
  map_version
  width
  height
  payload_size
  payload_crc32

Payload
  width * height bytes
  0 = flyable
  1 = no_fly
```

为什么暂时一 Cell 一 byte：

```text
地图很小
实现/调试直观
Overlay 容易检查
```

等真实资产规模证明需要，再压 bitset；本课不为省几个 KB 增加位运算和工具链复杂度。

### 19.1 资产校验

Server 加载 AMAP 时必须拒绝：

```text
magic 错
version 错
header_size 错
width*height overflow
payload_size 不等于 width*height
CRC 错
map_id/version 与 Ground Grid 不一致
width/height 与 Ground Grid 不一致
truncated
```

## 20. Unity NoFly Authoring

新增两个最小脚本：

```text
server/third_party/skynet-flywow/navigation/unity/Runtime/NoFlyVolume.cs
server/third_party/skynet-flywow/navigation/unity/Editor/AirMapExporter.cs
```

`NoFlyVolume` 只表示 Authoring 语义：

```csharp
// 职责：标记一个只参与 AMAP Bake 的 NoFly 盒形区域。
// 边界：Unity Authoring；不在 Client Runtime 决定 Server 飞行合法性。
// 输入/输出：BoxCollider 世界 Bounds -> AirMapExporter 采样 NoFly。
// 生命周期：编辑期 Scene 对象；构建出的 AMAP 才是 Server 发布资产。
// 不负责：不控制 FlyingEnemy、不参与 Unity NavMesh Agent。
using UnityEngine;

namespace FlyWow.Navigation
{
    /// <summary>编辑期 NoFly 盒形区域；Server Runtime 不读取本组件。</summary>
    [RequireComponent(typeof(BoxCollider))]
    public sealed class NoFlyVolume : MonoBehaviour
    {
        /// <summary>返回当前 Authoring 盒体的世界空间 Bounds。</summary>
        public Bounds WorldBounds
        {
            get
            {
                var box = GetComponent<BoxCollider>();
                return box.bounds;
            }
        }
    }
}
```

AirMapExporter 不重新定义 Grid Origin/CellSize，而是读取第一课同一个地图根配置。每个 Cell 取世界中心点，只测试 XZ 是否落入任一 NoFly Volume 的 XZ Bounds。

课程验证地图至少放：

```text
普通 Ground 障碍：FlyingEnemy 可以越过
NoFly_Box_01：FlyingEnemy 必须绕开
```

### 20.1 Unity Overlay

SceneView Overlay 至少显示：

```text
透明蓝：Flyable
透明红：NoFly
```

并在鼠标悬停/选中时显示：

```text
cell x/z
world center
nofly flag
```

不要只输出二进制后靠 Server 猜 Bake 是否正确。

### 20.2 复用已抽取的 FlyWow Navigation Authoring 与资产发布入口

地图 Authoring 已在 FlyWow UPM 包中。第三课不再从课程 Unity 工程复制 BattleMapExporter，也不新增 RepositoryPathResolver；使用 FlyWow.Navigation.NavigationMapRoot、NavigationMapExporter 和 NavigationAssetPublisher。AirMap 源码归 server/third_party/skynet-flywow/navigation/unity/；Battle 场景、出生点校验和 Interactive Client 仍归课程 Unity 工程。

Unity 工程通过内容寻址的 .tgz 消费该包，不直接引用 WSL 子模块目录。修改 FlyWow 包源码后，按 WORKSPACE_WORKFLOW.md 完成 FlyWow 提交、主仓库 gitlink 同步，再让 Windows 工作区获取对应版本。每个新增 Package 文件都要一并提供稳定唯一的 .meta；package_unity.py 会拒绝缺少 .meta 的文件。

在 Windows 仓库根目录运行下面命令，生成离线包并更新 Unity manifest；之后打开 Unity，等待 Package Manager 刷新并更新 packages-lock.json：

```powershell
python server/third_party/skynet-flywow/navigation/tools/package_unity.py --output .tmp/navigation-packages --manifest unity/BattleNavigation/Packages/manifest.json
```

不要把包源码复制进 unity/BattleNavigation/Assets，也不要把 .tgz 当作第二份可编辑源码。

NavigationMapRoot.exportDirectory 是候选资产输出根。BMAP、AMAP 和 Manifest 必须由同一个候选发布流程写入 staging，校验通过后原子发布；不能由两个导出器分别覆盖正式文件。

### 20.3 `AirMapSnapshot`：Authoring 结果先冻结成纯数据，再写磁盘

不要让 Writer 直接遍历 Scene。第一课 BMAP 已经证明“采样/校验”和“二进制写盘”分离更容易测试，AMAP 继续保持同一纪律。

[新建文件]

```text
server/third_party/skynet-flywow/navigation/unity/Editor/AirMapSnapshot.cs
```

```csharp
// 职责：保存一次 AMAP Bake 已完成后的确定性内存快照。
// 边界：Unity Editor Asset Data；Writer/Validator 只消费本对象，不再读取 Scene。
// 输入/输出：map/grid 元数据 + z-major NoFly byte 数组 -> 不可变语义快照。
// 生命周期：一次导出流程内存活；成功写盘后即可释放。
// 不负责：不查 Scene、不计算 Bounds、不执行文件 I/O。
using System;

namespace FlyWow.Navigation.Editor
{
    /// <summary>一次 AirMap 导出的内存快照；NoFly 使用 0/1 byte，索引为 z*width+x。</summary>
    public sealed class AirMapSnapshot
    {
        public uint mapId;          // 与同版本 BMAP 一致的业务地图 ID。
        public uint mapVersion;     // 与同版本 BMAP 一致的地图版本。
        public int width;           // X 方向 Cell 数。
        public int height;          // Z 方向 Cell 数。
        public byte[] noFly = Array.Empty<byte>(); // 0=flyable,1=no_fly；z-major。

        /// <summary>返回 Cell 总数；乘法使用 checked，异常表示 Authoring 合同已破坏。</summary>
        public int CellCount
        {
            get { return checked(width * height); }
        }

        /// <summary>把合法 Grid 坐标转换成 z-major 下标；越界直接抛异常。</summary>
        public int IndexOf(int x, int z)
        {
            if (x < 0 || x >= width || z < 0 || z >= height)
                throw new ArgumentOutOfRangeException($"air grid outside map: ({x},{z})");
            return checked(z * width + x);
        }
    }
}
```

为什么这里没有 `origin/cell_size`：AMAP V1 明确依赖同 `map_id/map_version` 的 BMAP 空间合同，不维护第二份可能漂移的空间元数据。Exporter 仍然通过同一个 `NavigationMapRoot` 计算 Cell Center，所以 Authoring 过程中不会失去坐标信息。

---

### 20.4 `AirMapFormat.cs`：把磁盘 offset 固定下来

[新建文件]

```text
server/third_party/skynet-flywow/navigation/unity/Editor/AirMapFormat.cs
```

```csharp
// 职责：集中声明 AMAP V1 的二进制布局常量。
// 边界：Unity Editor Binary Asset Contract；必须与 Server air_map_format.h 一致。
// 输入/输出：无运行时输入；为 Writer/Test 提供固定 offset 和版本。
// 生命周期：编译期常量；修改属于资产格式变更，不能静默替换。
// 不负责：不执行采样、CRC、文件 I/O 或 Server 查询。
namespace FlyWow.Navigation.Editor
{
    public static class AirMapFormat
    {
        public const ushort FormatVersion = 1; // AMAP V1。
        public const ushort HeaderSize = 32;   // 当前 Header 固定 32 bytes。
        public const int MagicSize = 4;        // ASCII "AMAP"。
        public const int PayloadCrcOffset = 28;// uint32 payload_crc32。

        // Magic 使用显式 byte，避免依赖运行平台字符串编码行为。
        public static readonly byte[] Magic = { (byte)'A', (byte)'M', (byte)'A', (byte)'P' };
    }
}
```

AMAP 当前没有 Header CRC。原因不是 Header 不重要，而是 Header 只有 32 bytes，且所有关键尺寸/身份字段都会被显式校验；Payload CRC 已经覆盖真正的大块数据。以后如果格式扩展为复杂目录，可以升级到 V2 再增加 Header CRC，不在 V1 中为“看起来和 BMAP 一样”机械复制字段。

---

### 20.5 `AirMapWriter.cs`：完整写盘与回读验证

[新建文件]

```text
server/third_party/skynet-flywow/navigation/unity/Editor/AirMapWriter.cs
```

学习导航：精读 Header offset、Payload 长度、CRC 和临时文件替换；可以略读目录创建。输入是已经校验的 `AirMapSnapshot`，输出正式 `.amap`；失败时不得留下半个正式资产。

```csharp
// 职责：把已验证的 AirMapSnapshot 编码为 AMAP V1，并在替换正式文件前回读验证。
// 边界：Unity Editor Asset Writer；不读取 Scene，不修改 BMAP。
// 输入/输出：AirMapSnapshot + 输出路径 -> AMAP V1 文件或明确异常。
// 生命周期：临时 byte[]/文件只覆盖一次 Write；正式文件通过临时文件原子式替换语义更新。
// 不负责：不采样 NoFly、不提交 Git、不通知运行中的 Server 热加载。
using System;
using System.IO;

namespace FlyWow.Navigation.Editor
{
    public static class AirMapWriter
    {
        /// <summary>编码并验证 AMAP；snapshot 的 noFly 必须恰好 width*height 且只含 0/1。</summary>
        public static void Write(AirMapSnapshot snapshot, string path)
        {
            if (snapshot == null) throw new ArgumentNullException(nameof(snapshot));
            if (string.IsNullOrWhiteSpace(path))
                throw new ArgumentException("output path is empty", nameof(path));
            if (snapshot.mapId == 0 || snapshot.mapVersion == 0 ||
                snapshot.width <= 0 || snapshot.height <= 0)
                throw new InvalidOperationException("AMAP identity/dimensions are invalid");

            int cellCount = snapshot.CellCount;
            if (snapshot.noFly == null || snapshot.noFly.Length != cellCount)
                throw new InvalidOperationException("AMAP_CELL_COUNT_MISMATCH");
            for (int i = 0; i < snapshot.noFly.Length; ++i)
            {
                if (snapshot.noFly[i] != 0 && snapshot.noFly[i] != 1)
                    throw new InvalidOperationException("AMAP_CELL_VALUE_INVALID index=" + i);
            }

            byte[] payload = new byte[cellCount];
            Buffer.BlockCopy(snapshot.noFly, 0, payload, 0, cellCount);
            uint payloadCrc = BMapCrc32.Compute(payload); // 与 BMAP 使用完全相同的 CRC-32 参数。

            byte[] header = new byte[AirMapFormat.HeaderSize];
            Buffer.BlockCopy(AirMapFormat.Magic, 0, header, 0, AirMapFormat.MagicSize);
            BMapLittleEndian.WriteU16(header, 4, AirMapFormat.FormatVersion);
            BMapLittleEndian.WriteU16(header, 6, AirMapFormat.HeaderSize);
            BMapLittleEndian.WriteU32(header, 8, snapshot.mapId);
            BMapLittleEndian.WriteU32(header, 12, snapshot.mapVersion);
            BMapLittleEndian.WriteU32(header, 16, checked((uint)snapshot.width));
            BMapLittleEndian.WriteU32(header, 20, checked((uint)snapshot.height));
            BMapLittleEndian.WriteU32(header, 24, checked((uint)payload.Length));
            BMapLittleEndian.WriteU32(header, AirMapFormat.PayloadCrcOffset, payloadCrc);

            string fullPath = Path.GetFullPath(path);
            string directory = Path.GetDirectoryName(fullPath)
                ?? throw new InvalidOperationException("AMAP output directory missing");
            Directory.CreateDirectory(directory);
            string temporaryPath = fullPath + ".tmp";

            using (var stream = new FileStream(
                       temporaryPath, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                stream.Write(header, 0, header.Length);
                stream.Write(payload, 0, payload.Length);
                stream.Flush(true);
            }

            Verify(temporaryPath);
            if (File.Exists(fullPath)) File.Replace(temporaryPath, fullPath, null);
            else File.Move(temporaryPath, fullPath);
        }

        /// <summary>按不信任磁盘输入的方式回读 AMAP，验证格式、尺寸、CRC 和 Cell 值。</summary>
        public static void Verify(string path)
        {
            byte[] file = File.ReadAllBytes(path);
            if (file.Length < AirMapFormat.HeaderSize)
                throw new InvalidDataException("AMAP_TRUNCATED_HEADER");

            for (int i = 0; i < AirMapFormat.MagicSize; ++i)
                if (file[i] != AirMapFormat.Magic[i])
                    throw new InvalidDataException("AMAP_BAD_MAGIC");

            ushort version = BMapLittleEndian.ReadU16(file, 4);
            ushort headerSize = BMapLittleEndian.ReadU16(file, 6);
            uint width = BMapLittleEndian.ReadU32(file, 16);
            uint height = BMapLittleEndian.ReadU32(file, 20);
            uint payloadSize = BMapLittleEndian.ReadU32(file, 24);
            uint expectedCrc = BMapLittleEndian.ReadU32(file, 28);

            if (version != AirMapFormat.FormatVersion ||
                headerSize != AirMapFormat.HeaderSize)
                throw new InvalidDataException("AMAP_HEADER_VERSION_OR_SIZE");
            if (width == 0 || height == 0)
                throw new InvalidDataException("AMAP_INVALID_DIMENSIONS");

            ulong expectedPayload = (ulong)width * height;
            if (expectedPayload > int.MaxValue || payloadSize != expectedPayload)
                throw new InvalidDataException("AMAP_PAYLOAD_SIZE_MISMATCH");
            if ((ulong)file.Length != (ulong)headerSize + expectedPayload)
                throw new InvalidDataException("AMAP_FILE_SIZE_MISMATCH");
            if (BMapCrc32.Compute(file, headerSize, checked((int)payloadSize)) != expectedCrc)
                throw new InvalidDataException("AMAP_PAYLOAD_CRC_MISMATCH");

            for (int i = headerSize; i < file.Length; ++i)
                if (file[i] != 0 && file[i] != 1)
                    throw new InvalidDataException("AMAP_CELL_VALUE_INVALID");
        }
    }
}
```

这里继续使用第一课已有的 `BMapLittleEndian/BMapCrc32`，因为它们本身就是“通用 byte 编码/CRC”能力，不绑定 BMAP 业务语义。若后续准备把它们抽到 FlyWow 或更通用的 Asset Tooling，再等第三个真实二进制资产消费者出现，不在第三课顺手重构目录。

---

### 20.6 AirMap 进入同一候选资产发布流程

[局部修改]

```text
server/third_party/skynet-flywow/navigation/unity/Editor/NavigationMapExporter.cs
server/third_party/skynet-flywow/navigation/unity/Editor/NavigationAssetPublisher.cs
```

AirMapExporter 不再提供独立菜单，也不直接写 shared/navigation 下的正式文件。它只负责从当前唯一 NavigationMapRoot 和 NoFlyVolume[] 生成 AirMapSnapshot。NavigationMapExporter 在现有 Sample → Clearance → Validate 流程中取得这份快照，并与 BMAP Snapshot 一起检查 mapId、mapVersion、width、height。

扩展 NavigationAssetPublisher，使其在一个私有 staging 目录中写出 map.bmap、map.amap 和同一份 Manifest。Manifest 的内容身份覆盖两份资产，并记录各自格式版本及校验信息；全部回读验证通过后，使用同文件系统目录 rename 提交候选。失败时清理 staging，不能留下只更新 BMAP 或只更新 AMAP 的半成品。为成功发布、损坏 AMAP、身份不匹配和写入失败分别补 Editor Test。

Server 配置只指向已验证并提交的候选目录中的 BMAP/AMAP；更新地图语义时递增共同 mapVersion，并重新生成整包，不覆盖正在使用的已发布目录。

### 20.7 Unity 侧 AMAP EditMode Test

[新建文件]

```text
server/third_party/skynet-flywow/navigation/unity/Tests/Editor/AirMapBinaryTests.cs
```

课程不需要测试 Unity 菜单 UI，本测试直接验证 Writer 的二进制合同和损坏路径。

```csharp
// 职责：验证 AMAP V1 Writer/Verifier 的成功与损坏输入路径。
// 边界：Unity EditMode Test；只操作临时文件，不读取正式 shared/navigation 资产。
// 输入/输出：人工构造 Snapshot -> 写盘/损坏/Verify 结果。
// 生命周期：每个测试拥有自己的临时文件并在 finally 清理。
// 不负责：不启动 Server、不执行 Air A*、不测试 Scene Authoring UI。
using System;
using System.IO;
using NUnit.Framework;

namespace FlyWow.Navigation.Tests
{
    public sealed class AirMapBinaryTests
    {
        /// <summary>验证合法 2x2 AMAP 能写出并通过回读校验。</summary>
        [Test]
        public void WriteAndVerifyGoldenMap()
        {
            string path = Path.GetTempFileName();
            try
            {
                AirMapWriter.Write(new AirMapSnapshot
                {
                    mapId = 1001,
                    mapVersion = 7,
                    width = 2,
                    height = 2,
                    noFly = new byte[] { 0, 1, 0, 0 },
                }, path);
                Assert.DoesNotThrow(() => AirMapWriter.Verify(path));
            }
            finally { if (File.Exists(path)) File.Delete(path); }
        }

        /// <summary>Payload 任意 bit 被修改后 CRC 必须失败，不能静默接受损坏资产。</summary>
        [Test]
        public void RejectsPayloadCrcCorruption()
        {
            string path = Path.GetTempFileName();
            try
            {
                AirMapWriter.Write(new AirMapSnapshot
                {
                    mapId = 1001,
                    mapVersion = 1,
                    width = 2,
                    height = 2,
                    noFly = new byte[] { 0, 1, 0, 0 },
                }, path);
                byte[] bytes = File.ReadAllBytes(path);
                bytes[AirMapFormat.HeaderSize + 1] ^= 1;
                File.WriteAllBytes(path, bytes);
                InvalidDataException error = Assert.Throws<InvalidDataException>(
                    () => AirMapWriter.Verify(path));
                StringAssert.Contains("CRC", error.Message);
            }
            finally { if (File.Exists(path)) File.Delete(path); }
        }

        /// <summary>即使 CRC 被同步重算，Payload 中 0/1 之外的值仍必须被格式规则拒绝。</summary>
        [Test]
        public void RejectsUnknownCellValue()
        {
            string path = Path.GetTempFileName();
            try
            {
                AirMapWriter.Write(new AirMapSnapshot
                {
                    mapId = 1001,
                    mapVersion = 1,
                    width = 1,
                    height = 1,
                    noFly = new byte[] { 0 },
                }, path);
                byte[] bytes = File.ReadAllBytes(path);
                bytes[AirMapFormat.HeaderSize] = 7;
                uint crc = BMapCrc32.Compute(bytes, AirMapFormat.HeaderSize, 1);
                BMapLittleEndian.WriteU32(bytes, 28, crc);
                File.WriteAllBytes(path, bytes);
                InvalidDataException error = Assert.Throws<InvalidDataException>(
                    () => AirMapWriter.Verify(path));
                StringAssert.Contains("CELL_VALUE", error.Message);
            }
            finally { if (File.Exists(path)) File.Delete(path); }
        }
    }
}
```

实际操作：

```text
1. 在 Battle_1001 Scene 放一个普通 Ground 障碍，不加 NoFlyVolume。
2. 再放一个 NoFly_Box_01，并调整 BoxCollider 覆盖几列 Cell。
3. 先重新导出 BMAP，确认 mapVersion 已是本次要发布的版本。
4. 执行 Tools/战斗导航/04 导出当前场景 AMAP。
5. 打开 *.amap.manifest.json，核对 map/version/width/height/nofly count。
6. 用 Overlay 看 NoFly 与 Scene Box 是否对齐。
7. 再进入 Server Reader 测试；不要只凭 Unity Console 的 AMAP_EXPORT_OK 宣布完成。
```

---


## 21. Native `AirMap`

[新建文件]

```text
server/third_party/skynet-flywow/navigation/native/grid_map/air_map.h
server/third_party/skynet-flywow/navigation/native/grid_map/air_map.cpp
```

公开合同保持很小：

```cpp
// 职责：持有与一个 Ground Grid 同维度的 immutable NoFly overlay。
// 边界：Server Native Static Asset；加载后只读，可被多个 Service/OS Thread 查询。
// 输入/输出：AMAP V1 bytes -> map/version/width/height/nofly 查询。
// 生命周期：由 Native Registry 共享持有；Battle Context 只借用 shared_ptr<const AirMap>。
// 不负责：不保存 Flying Unit、不执行 A*、不保存动态占位。
class AirMap {
public:
    AirMap(std::uint32_t map_id,
           std::uint32_t map_version,
           std::uint32_t width,
           std::uint32_t height,
           std::vector<std::uint8_t> no_fly);

    std::uint32_t map_id() const noexcept;
    std::uint32_t map_version() const noexcept;
    std::uint32_t width() const noexcept;
    std::uint32_t height() const noexcept;

    // x/z 是 0-based Grid index；越界返回 true，确保路径算法 fail closed。
    bool IsNoFly(std::int32_t x, std::int32_t z) const noexcept;

private:
    std::uint32_t map_id_ = 0;
    std::uint32_t map_version_ = 0;
    std::uint32_t width_ = 0;
    std::uint32_t height_ = 0;
    std::vector<std::uint8_t> no_fly_;
};
```

实现 index 时继续使用显式 overflow/bounds 检查，不用 raw struct dump 解析 Header。CRC helper 可以复用 BMAP Reader 已有实现，但不要把 `AirMap` 塞进 `GridMap` 的 mutable 字段。

### 21.1 AMAP 不是只有 `AirMap`，还需要 Reader 和 Registry

如果这里只定义一个 `AirMap` class，第三课实际上还没有打通：

```text
Unity .amap 文件
-> ?
-> AirMap
-> ?
-> Battle NavigationContext
```

所以 Native 侧最小完整链路应该是：

```text
AirMapExporter
  -> <已验证候选目录>/map.amap
  -> AirMapReader
  -> AirMapRegistry（进程级 immutable asset registry）
  -> navigation.new_context(map_id, map_version)
  -> Battle-local NavigationContext
  -> AirGridPathfinder
```

新增文件控制在：

```text
server/third_party/skynet-flywow/navigation/native/grid_map/air_map_format.h
server/third_party/skynet-flywow/navigation/native/grid_map/air_map.h
server/third_party/skynet-flywow/navigation/native/grid_map/air_map_reader.h
server/third_party/skynet-flywow/navigation/native/grid_map/air_map_registry.h
server/third_party/skynet-flywow/navigation/native/grid_map/air_grid_pathfinder.h

server/third_party/skynet-flywow/navigation/native/grid_map/air_map.cpp
server/third_party/skynet-flywow/navigation/native/grid_map/air_map_reader.cpp
server/third_party/skynet-flywow/navigation/native/grid_map/air_map_registry.cpp
server/third_party/skynet-flywow/navigation/native/grid_map/air_grid_pathfinder.cpp
```

没有创建新的 Skynet `AirMapService`。静态地图仍然是 Native immutable asset，不需要把每次 Air Query 代理成 Service RPC。

### 21.2 AMAP V1 的 byte layout 固定下来

`air_map_format.h` 不使用 `#pragma pack + reinterpret_cast` 直接映射磁盘 struct。和 BMAP 一样，Binary Protocol 必须逐字段 little-endian 读取。

本课固定 32-byte Header：

| Offset | Size | Field | 规则 |
|---:|---:|---|---|
| 0 | 4 | magic | ASCII `AMAP` |
| 4 | 2 | format_version | `1` |
| 6 | 2 | header_size | `32` |
| 8 | 4 | map_id | 与 BMAP 相同 |
| 12 | 4 | map_version | 与 BMAP 相同 |
| 16 | 4 | width | 与 BMAP 相同 |
| 20 | 4 | height | 与 BMAP 相同 |
| 24 | 4 | payload_size | 必须等于 `width * height` |
| 28 | 4 | payload_crc32 | 只覆盖 Payload |

Payload：

```text
index = z * width + x
byte 0 = Flyable
byte 1 = NoFly
其他值 = 格式错误
```

为什么 AMAP 不重复保存：

```text
origin_x_mm
origin_z_mm
cell_size_mm
height
```

因为它必须与同 `map_id/map_version` 的 BMAP 配对。重复写两份空间元数据反而会制造“BMAP 与 AMAP 谁是权威”的一致性问题。

### 21.3 `AirMapReader` 的失败合同

[新建文件]

```text
server/third_party/skynet-flywow/navigation/native/grid_map/air_map_reader.h
server/third_party/skynet-flywow/navigation/native/grid_map/air_map_reader.cpp
```

公开接口只需要：

```cpp
// 职责：读取并完整校验 AMAP V1，成功后返回 immutable AirMap。
// 边界：Server Native Asset Loader；只在启动阶段执行文件 I/O。
// 输入/输出：AMAP 文件路径 -> shared_ptr<const AirMap> 或明确 NavError。
// 生命周期：返回对象由 Registry shared_ptr 接管；Reader 不保存文件句柄或全局状态。
// 不负责：不配对 BMAP、不执行 A*、不保存 Flying Unit。
class AirMapReader final {
public:
    static NavResult<std::shared_ptr<const AirMap>> Read(
        const std::string& path);
};
```

实现顺序必须固定：

```text
1. 打开文件并取得 file_size
2. 要求 file_size >= 32
3. 精确读取 32-byte Header
4. little-endian 解出所有整数
5. magic/version/header_size
6. width/height > 0
7. checked_mul(width,height)
8. payload_size == checked cell_count
9. file_size == 32 + payload_size
10. 精确读取 Payload
11. CRC32(Payload)
12. 每个 byte 只能是 0/1
13. 构造 immutable AirMap
```

特别注意：

```cpp
std::uint64_t cell_count =
    static_cast<std::uint64_t>(width) * height;
```

必须先在更宽类型计算，再检查：

```text
cell_count <= size_t max
cell_count <= uint32 payload_size max
```

不能先在 `uint32_t` 乘完再判断，因为 overflow 已经发生。

### 21.4 `AirMapRegistry` 为什么单独存在

第一二课已经有：

```text
MapRegistry -> shared_ptr<const GridMap>
```

第三课不要把 `MapRegistry` 改成一个塞各种 asset 的 `void*` 容器，也不为了两个资产提前建立通用 `AssetRegistry<T>` 模板体系。

增加一个很小的：

```cpp
// 职责：按 map_id/map_version 注册、冻结和查找 immutable AirMap。
// 边界：Server Native Process-level Asset Registry；启动阶段写入，运行期只读。
// 输入/输出：AMAP path 或 map key -> shared_ptr<const AirMap> / NavError。
// 生命周期：进程级 singleton；对象由 Registry 持有到进程退出。
// 不负责：不执行路径查询、不保存 Battle 动态状态。
class AirMapRegistry final {
public:
    static AirMapRegistry& Instance();

    NavResult<std::shared_ptr<const AirMap>> Load(const std::string& path);
    NavResult<bool> Freeze();
    NavResult<std::shared_ptr<const AirMap>> Find(
        std::uint32_t map_id,
        std::uint32_t map_version) const;
    std::size_t map_count() const;
};
```

实现方式和 `MapRegistry` 一致：

```text
文件 I/O / CRC 在 mutex 外
注册/Find 只持短锁
Freeze 后拒绝 Load
AirMap 自己 immutable
```

这里真正需要理解的 Skynet/Native 关系是：

```text
BattleWorker #1 Lua State -> require flywow_navigation
BattleWorker #2 Lua State -> require flywow_navigation
BattleWorker #3 Lua State -> require flywow_navigation

                 ↓ 同一个 Battle Process

         flywow_navigation_native.so process image
                 ↓
        C++ static MapRegistry / AirMapRegistry / AgentProfileRegistry
```

每个 Skynet Service 有独立 Lua State，不代表同一个进程里动态库的 C++ process-global static 会自动复制一份。Map、AirMap 和 Profile Registry 都是进程级只读资产；启动时完成注册，运行期只读。Registry 的注册与查找必须线程安全，返回的资产必须 immutable。`load_profiles(config.profiles)` 在 `navigation_query.start()` 执行一次；各 BattleWorker 只用 `new_context(map_id, map_version)` 创建自己的 Context 和 scratch，不再重复传入 Profile 表。

这正好和每场 Battle 私有的：

```text
NavigationContext
Ground scratch
Air scratch
DynamicOccupancy
```

形成对照。

### 21.5 `NavigationContext` 增加 AirMap，但不改变 Ground API

[局部修改]

```text
server/third_party/skynet-flywow/navigation/native/grid_map/navigation_context.h
server/third_party/skynet-flywow/navigation/native/grid_map/navigation_context.cpp
```

保持第二课构造调用兼容，可以增加 optional AirMap：

```cpp
// 为一场 Battle 创建独立 Navigation Context。
// grid_map 必须非空；air_map 可以为空，Ground-only 测试仍能运行。
// 两张地图若同时存在，map_id/version/width/height 必须一致，否则构造失败。
NavigationContext(
    std::shared_ptr<const GridMap> grid_map,
    std::shared_ptr<const AirMap> air_map = nullptr);
```

新增私有状态：

```cpp
std::shared_ptr<const AirMap> air_map_; // immutable，共享资产；可以为空。

std::vector<NodeScratch> air_nodes_;   // 当前 Battle 独占的 Air A* scratch。
std::vector<std::int32_t> air_heap_;   // 当前 Battle 独占的 Air binary heap storage。
std::size_t air_heap_size_ = 0;
std::uint32_t air_query_generation_ = 0;
std::uint32_t air_visited_nodes_ = 0;
```

这里**不要**复用 Ground `nodes_/heap_` 同时跑两种查询然后用一个 flag 判断当前类型。独立两份 scratch 的内存成本可计算，但 ownership 和并发/重入边界更直接：

```text
Ground Query -> Ground Scratch
Air Query    -> Air Scratch
```

同一个 Battle Core 本身 no-yield，不会同时并发调用同一个 Context；但测试可以明确证明 Ground/Air 交替查询不会互相污染 generation/heap state。

### 21.6 Lua Binding：启动时加载 AMAP，Context 创建时配对

[局部修改]

```text
server/third_party/skynet-flywow/navigation/native/navigation_binding.cpp
```

模块增加：

```lua
navigation.load_air_map(path)
```

合同和 `load_map(path)` 一致：

```text
启动阶段文件 I/O
成功 -> {map_id,map_version,width,height}
失败 -> nil,{code,message}
```

`l_new_context()` 仍然保持第二课公开 Lua 调用：

```lua
navigation.new_context(map_id, map_version)
```

内部改成：

```text
MapRegistry.Find(map_id,map_version)
AirMapRegistry.Find(map_id,map_version)
  |
  +-- 找到 -> 校验 width/height 与 GridMap 一致，传入 Context
  |
  +-- 未找到 -> Context 的 air_map=nil
```

因此第二课 Ground-only 单元测试不用全部改签名；只有调用：

```text
find_air_path
advance_air_path
```

时才要求 `air_map != nil`，否则返回稳定 `AIR_MAP_NOT_LOADED`。

### 21.7 Server 启动链把 AMAP 真正加载进去

[局部修改]

```text
server/config/battle.lua
```

在现有 config.battle 的 map table 中追加 AMAP 路径；保留 profiles、cluster 和 Runtime 字段。发布新 AMAP 时，先生成并验证一套新的 BMAP/AMAP/Manifest 候选包，再把 map table 一次切换到该候选；不要将新 AMAP 与当前旧版 BMAP 混用：

```lua
map = {
    id = 1001,
    version = 2, -- 示例：新候选的 BMAP 和 AMAP 必须使用同一 map_version。
    bmap = "../shared/navigation/<已验证候选目录>/map.bmap",
    amap = "../shared/navigation/<已验证候选目录>/map.amap",
},
```

[局部修改]

```text
server/lualib/battle/navigation/query_logic.lua
```

启动顺序：

```lua
local profiles_loaded, profiles_error = navigation.load_profiles(config.profiles)
assert(profiles_loaded, profiles_error and profiles_error.message or "load_profiles failed")

local ground, ground_error = navigation.load_map(config.map.bmap)
assert(ground, ground_error and ground_error.message or "load BMAP failed")

local air, air_error = navigation.load_air_map(config.map.amap)
assert(air, air_error and air_error.message or "load AMAP failed")

assert(ground.map_id == air.map_id and
       ground.map_version == air.map_version,
       "BMAP/AMAP identity mismatch")
```

为什么仍然由启动阶段完成：

```text
Battle 开始
-X-> 临时去磁盘读 AMAP
-X-> 每场 Battle 各解析一份 AMAP
```

正确：

```text
Battle Process startup
-> Load + Validate BMAP
-> Load + Validate AMAP
-> process-level immutable registry

Battle create
-> shared_ptr static assets
-> allocate only battle-local scratch/dynamic state
```

如果 Loader/Registry 已提供 `Freeze()` 的 Lua binding，则在两份资产完成加载后一起 Freeze；如果第二课当前 Binding 尚未暴露 Freeze，就保持“composition root 启动完成后不再调用 Load”的现有规则，不要为了第三课随意制造另一套热加载语义。

### 21.3.1 第二个 Binary Asset 出现后，Native 侧再提取最小 byte helper

第一课 `bmap_reader.cpp` 内部有私有 Little Endian 与 CRC helper。第三课 `AirMapReader` 成为第二个真实二进制读取者，此时复制一套会增加格式漂移风险，因此现在才提取：

```text
server/third_party/skynet-flywow/navigation/native/grid_map/binary_asset_codec.h
server/third_party/skynet-flywow/navigation/native/grid_map/binary_asset_codec.cpp
```

它不是“通用序列化框架”，只包含当前两个 Reader 都真实需要的：

```cpp
ReadU16Le
ReadU32Le
ReadI32Le
WriteU32Le
Crc32IsoHdlc
```

[新建文件] `binary_asset_codec.h`

```cpp
// 职责：提供 BMAP/AMAP Reader 共同使用的 Little Endian 基础读取和 CRC-32。
// 边界：Server Native Asset Utility；只操作调用方提供的 byte 范围。
// 输入/输出：已保证长度的 byte 指针 -> 整数/CRC 值。
// 生命周期：纯函数，无全局可变状态、无堆分配。
// 不负责：不判断任何具体资产 magic/version/offset，也不执行文件 I/O。
#pragma once

#include <cstddef>
#include <cstdint>

namespace flywow_navigation {
namespace binary_asset {

std::uint16_t ReadU16Le(const std::uint8_t* bytes) noexcept;
std::uint32_t ReadU32Le(const std::uint8_t* bytes) noexcept;
std::int32_t ReadI32Le(const std::uint8_t* bytes) noexcept;
void WriteU32Le(std::uint8_t* bytes, std::uint32_t value) noexcept;
std::uint32_t Crc32IsoHdlc(
    const std::uint8_t* bytes,
    std::size_t size) noexcept;

} // namespace binary_asset
} // namespace flywow_navigation
```

[新建文件] `binary_asset_codec.cpp`

```cpp
// 职责：实现资产格式共同的 Little Endian 解码与 reflected CRC-32/ISO-HDLC。
// 边界：Server Native Asset Utility；调用者负责保证输入范围有效。
// 输入/输出：byte 范围 -> 确定性整数/CRC；不分配、不加锁。
// 生命周期：无状态纯函数。
// 不负责：不处理文件、错误码、地图身份或业务规则。
#include "binary_asset_codec.h"

namespace flywow_navigation {
namespace binary_asset {

std::uint16_t ReadU16Le(const std::uint8_t* bytes) noexcept {
    return static_cast<std::uint16_t>(bytes[0]) |
        static_cast<std::uint16_t>(bytes[1]) << 8;
}

std::uint32_t ReadU32Le(const std::uint8_t* bytes) noexcept {
    return static_cast<std::uint32_t>(bytes[0]) |
        static_cast<std::uint32_t>(bytes[1]) << 8 |
        static_cast<std::uint32_t>(bytes[2]) << 16 |
        static_cast<std::uint32_t>(bytes[3]) << 24;
}

std::int32_t ReadI32Le(const std::uint8_t* bytes) noexcept {
    return static_cast<std::int32_t>(ReadU32Le(bytes));
}

void WriteU32Le(std::uint8_t* bytes, std::uint32_t value) noexcept {
    bytes[0] = static_cast<std::uint8_t>(value);
    bytes[1] = static_cast<std::uint8_t>(value >> 8);
    bytes[2] = static_cast<std::uint8_t>(value >> 16);
    bytes[3] = static_cast<std::uint8_t>(value >> 24);
}

std::uint32_t Crc32IsoHdlc(
    const std::uint8_t* bytes,
    std::size_t size) noexcept {
    std::uint32_t crc = 0xffffffffu;
    for (std::size_t i = 0; i < size; ++i) {
        crc ^= bytes[i];
        for (int bit = 0; bit < 8; ++bit) {
            crc = (crc & 1u) != 0
                ? 0xedb88320u ^ (crc >> 1)
                : crc >> 1;
        }
    }
    return crc ^ 0xffffffffu;
}

} // namespace binary_asset
} // namespace flywow_navigation
```

[局部修改] `bmap_reader.cpp`：删除文件内重复的 `ReadU16Le/ReadU32Le/ReadI32Le/WriteU32Le/Crc32`，include `binary_asset_codec.h`，其余 BMAP 流程不改。这个重构必须先跑第一课 BMAP corruption regression，证明第三课没有破坏旧资产读取。

---

### 21.3.2 `air_map_format.h` 与 `air_map.h/.cpp` 完整代码

[新建文件] `server/third_party/skynet-flywow/navigation/native/grid_map/air_map_format.h`

```cpp
// 职责：声明 AMAP V1 的固定二进制格式常量。
// 边界：Server Native Asset Contract；必须与 Unity AirMapFormat.cs 一致。
// 输入/输出：编译期常量；Reader/Test 共同使用。
// 生命周期：格式版本级；修改布局必须升级 format_version。
// 不负责：不读文件、不保存地图对象、不执行寻路。
#pragma once

#include <cstddef>
#include <cstdint>

namespace flywow_navigation {

constexpr std::uint16_t kAirMapFormatVersion = 1;
constexpr std::size_t kAirMapHeaderSize = 32;
constexpr std::size_t kAirMapPayloadCrcOffset = 28;

} // namespace flywow_navigation
```

[新建文件] `server/third_party/skynet-flywow/navigation/native/grid_map/air_map.h`

```cpp
// 职责：保存一张与 Ground Grid 同尺寸的 immutable NoFly overlay。
// 边界：Server Native Static Asset；加载完成后可被多个 Skynet OS Thread 只读共享。
// 输入/输出：map/version/width/height + z-major 0/1 no_fly -> 只读查询。
// 生命周期：通常由 AirMapRegistry shared_ptr 持有到进程退出。
// 不负责：不读取磁盘、不管理 Flying Unit、不执行 A* 或动态空中占位。
#pragma once

#include "bmap_format.h"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace flywow_navigation {

class AirMap final {
public:
    AirMap(
        std::uint32_t map_id,
        std::uint32_t map_version,
        std::uint32_t width,
        std::uint32_t height,
        std::vector<std::uint8_t> no_fly);

    std::uint32_t map_id() const noexcept { return map_id_; }
    std::uint32_t map_version() const noexcept { return map_version_; }
    std::uint32_t width() const noexcept { return width_; }
    std::uint32_t height() const noexcept { return height_; }
    std::size_t cell_count() const noexcept { return no_fly_.size(); }
    std::size_t memory_bytes() const noexcept;

    // 越界按 NoFly 处理，保证调用者 fail closed；grid 使用 Ground Grid 相同 0-based X/Z。
    bool IsNoFly(const GridPos& grid) const noexcept;

private:
    bool Contains(const GridPos& grid) const noexcept;
    std::size_t IndexOf(const GridPos& grid) const noexcept;

    const std::uint32_t map_id_;
    const std::uint32_t map_version_;
    const std::uint32_t width_;
    const std::uint32_t height_;
    const std::vector<std::uint8_t> no_fly_;
};

} // namespace flywow_navigation
```

[新建文件] `server/third_party/skynet-flywow/navigation/native/grid_map/air_map.cpp`

```cpp
// 职责：实现 AirMap 构造不变量和 O(1) NoFly 查询。
// 边界：Server Native Immutable Asset；运行期公开方法只读、无锁、无分配。
// 输入/输出：合法 z-major 0/1 数组 -> NoFly 查询结果。
// 生命周期：构造完成后数据不再修改。
// 不负责：不做 World/Grid 换算，空间坐标继续由配对 GridMap 提供。
#include "air_map.h"

#include <stdexcept>
#include <utility>

namespace flywow_navigation {

AirMap::AirMap(
    std::uint32_t map_id,
    std::uint32_t map_version,
    std::uint32_t width,
    std::uint32_t height,
    std::vector<std::uint8_t> no_fly)
    : map_id_(map_id),
      map_version_(map_version),
      width_(width),
      height_(height),
      no_fly_(std::move(no_fly)) {
    const std::uint64_t expected =
        static_cast<std::uint64_t>(width_) * height_;
    if (map_id_ == 0 || map_version_ == 0 ||
        width_ == 0 || height_ == 0 || expected != no_fly_.size()) {
        throw std::invalid_argument("AirMap identity/dimensions mismatch");
    }
    for (std::uint8_t value : no_fly_) {
        if (value != 0 && value != 1) {
            throw std::invalid_argument("AirMap cell must be 0 or 1");
        }
    }
}

std::size_t AirMap::memory_bytes() const noexcept {
    return sizeof(*this) + no_fly_.capacity() * sizeof(std::uint8_t);
}

bool AirMap::IsNoFly(const GridPos& grid) const noexcept {
    if (!Contains(grid)) return true;
    return no_fly_[IndexOf(grid)] != 0;
}

bool AirMap::Contains(const GridPos& grid) const noexcept {
    return grid.x >= 0 && grid.z >= 0 &&
        static_cast<std::uint32_t>(grid.x) < width_ &&
        static_cast<std::uint32_t>(grid.z) < height_;
}

std::size_t AirMap::IndexOf(const GridPos& grid) const noexcept {
    return static_cast<std::size_t>(grid.z) * width_ +
        static_cast<std::size_t>(grid.x);
}

} // namespace flywow_navigation
```

---

### 21.3.3 `AirMapReader` 完整实现

[新建文件] `server/third_party/skynet-flywow/navigation/native/grid_map/air_map_reader.h`

```cpp
// 职责：读取并完整校验 AMAP V1，成功后创建 immutable AirMap。
// 边界：Server Native Asset Loader；磁盘输入在全部校验完成前一律不可信。
// 输入/输出：文件路径 -> shared_ptr<const AirMap> 或稳定 NavError。
// 生命周期：文件 byte 缓冲只在 Read 内存活；返回对象交给 Registry 持有。
// 不负责：不与 BMAP 配对、不注册地图、不执行 A*。
#pragma once

#include "air_map.h"
#include "nav_result.h"

#include <memory>
#include <string>

namespace flywow_navigation {

class AirMapReader final {
public:
    static NavResult<std::shared_ptr<const AirMap>> Read(
        const std::string& path);
};

} // namespace flywow_navigation
```

[新建文件] `server/third_party/skynet-flywow/navigation/native/grid_map/air_map_reader.cpp`

```cpp
// 职责：逐字段读取 AMAP V1，验证尺寸/CRC/Cell 值后创建 AirMap。
// 边界：Server Asset Loader；不使用 struct cast，不信任文件内长度字段。
// 输入/输出：AMAP 文件 bytes -> immutable AirMap 或明确 NavError。
// 生命周期：临时 file vector 在 Read 返回后释放。
// 不负责：不读取 BMAP、不修复损坏资产、不做运行期热加载。
#include "air_map_reader.h"
#include "air_map_format.h"
#include "binary_asset_codec.h"

#include <cstdint>
#include <fstream>
#include <limits>
#include <sstream>
#include <utility>
#include <vector>

namespace flywow_navigation {
namespace {

std::string SizeDetail(std::uint64_t expected, std::uint64_t actual) {
    std::ostringstream stream;
    stream << "expected=" << expected << " actual=" << actual;
    return stream.str();
}

} // namespace

NavResult<std::shared_ptr<const AirMap>> AirMapReader::Read(
    const std::string& path) {
    std::ifstream stream(path, std::ios::binary | std::ios::ate);
    if (!stream) {
        return NavResult<std::shared_ptr<const AirMap>>::Failure(
            NavError::kIoError, "cannot open: " + path);
    }

    const std::streamoff end = stream.tellg();
    if (end < 0) {
        return NavResult<std::shared_ptr<const AirMap>>::Failure(
            NavError::kIoError, "tellg failed: " + path);
    }
    const std::uint64_t file_size = static_cast<std::uint64_t>(end);
    if (file_size < kAirMapHeaderSize) {
        return NavResult<std::shared_ptr<const AirMap>>::Failure(
            NavError::kTruncated, SizeDetail(kAirMapHeaderSize, file_size));
    }
    if (file_size > std::numeric_limits<std::size_t>::max()) {
        return NavResult<std::shared_ptr<const AirMap>>::Failure(
            NavError::kSizeOverflow, "AMAP larger than addressable memory");
    }

    stream.seekg(0, std::ios::beg);
    std::vector<std::uint8_t> file(static_cast<std::size_t>(file_size));
    stream.read(reinterpret_cast<char*>(file.data()),
                static_cast<std::streamsize>(file.size()));
    if (!stream || static_cast<std::size_t>(stream.gcount()) != file.size()) {
        return NavResult<std::shared_ptr<const AirMap>>::Failure(
            NavError::kTruncated, "AMAP short read: " + path);
    }

    if (file[0] != 'A' || file[1] != 'M' ||
        file[2] != 'A' || file[3] != 'P') {
        return NavResult<std::shared_ptr<const AirMap>>::Failure(
            NavError::kBadMagic, "magic is not AMAP");
    }

    using binary_asset::ReadU16Le;
    using binary_asset::ReadU32Le;
    using binary_asset::Crc32IsoHdlc;

    const std::uint16_t format_version = ReadU16Le(file.data() + 4);
    const std::uint16_t header_size = ReadU16Le(file.data() + 6);
    const std::uint32_t map_id = ReadU32Le(file.data() + 8);
    const std::uint32_t map_version = ReadU32Le(file.data() + 12);
    const std::uint32_t width = ReadU32Le(file.data() + 16);
    const std::uint32_t height = ReadU32Le(file.data() + 20);
    const std::uint32_t payload_size = ReadU32Le(file.data() + 24);
    const std::uint32_t expected_crc = ReadU32Le(file.data() + 28);

    if (format_version != kAirMapFormatVersion) {
        return NavResult<std::shared_ptr<const AirMap>>::Failure(
            NavError::kUnsupportedVersion,
            "AMAP format_version=" + std::to_string(format_version));
    }
    if (header_size != kAirMapHeaderSize) {
        return NavResult<std::shared_ptr<const AirMap>>::Failure(
            NavError::kInvalidHeaderSize,
            "AMAP header_size=" + std::to_string(header_size));
    }
    if (map_id == 0 || map_version == 0 || width == 0 || height == 0) {
        return NavResult<std::shared_ptr<const AirMap>>::Failure(
            NavError::kInvalidDimensions, "AMAP zero identity/dimension");
    }

    const std::uint64_t cell_count =
        static_cast<std::uint64_t>(width) * height;
    if (cell_count > std::numeric_limits<std::size_t>::max() ||
        cell_count > std::numeric_limits<std::uint32_t>::max()) {
        return NavResult<std::shared_ptr<const AirMap>>::Failure(
            NavError::kSizeOverflow, "AMAP dimension multiplication overflow");
    }
    if (payload_size != cell_count) {
        return NavResult<std::shared_ptr<const AirMap>>::Failure(
            NavError::kPayloadSizeMismatch,
            SizeDetail(cell_count, payload_size));
    }

    const std::uint64_t expected_file_size =
        static_cast<std::uint64_t>(header_size) + cell_count;
    if (file_size < expected_file_size) {
        return NavResult<std::shared_ptr<const AirMap>>::Failure(
            NavError::kTruncated, SizeDetail(expected_file_size, file_size));
    }
    if (file_size > expected_file_size) {
        return NavResult<std::shared_ptr<const AirMap>>::Failure(
            NavError::kTrailingBytes, SizeDetail(expected_file_size, file_size));
    }

    const std::uint8_t* payload = file.data() + header_size;
    if (Crc32IsoHdlc(payload, payload_size) != expected_crc) {
        return NavResult<std::shared_ptr<const AirMap>>::Failure(
            NavError::kPayloadCrcMismatch, "AMAP payload crc mismatch");
    }

    std::vector<std::uint8_t> no_fly(static_cast<std::size_t>(cell_count));
    for (std::size_t index = 0; index < no_fly.size(); ++index) {
        const std::uint8_t value = payload[index];
        if (value != 0 && value != 1) {
            return NavResult<std::shared_ptr<const AirMap>>::Failure(
                NavError::kInvalidArgument,
                "AMAP payload contains value outside 0/1");
        }
        no_fly[index] = value;
    }

    try {
        std::shared_ptr<const AirMap> map = std::make_shared<const AirMap>(
            map_id, map_version, width, height, std::move(no_fly));
        return NavResult<std::shared_ptr<const AirMap>>::Success(std::move(map));
    } catch (const std::exception& exception) {
        return NavResult<std::shared_ptr<const AirMap>>::Failure(
            NavError::kInvalidDimensions, exception.what());
    }
}

} // namespace flywow_navigation
```

---

### 21.4.1 `AirMapRegistry` 完整代码

[新建文件] `server/third_party/skynet-flywow/navigation/native/grid_map/air_map_registry.h`

```cpp
// 职责：按 map_id/map_version 注册和查找已经校验的 immutable AirMap。
// 边界：Server Runtime 进程级 Air Asset Registry；启动阶段写，Freeze 后只读。
// 输入/输出：AMAP 路径或地图键 -> shared_ptr<const AirMap> / NavError。
// 生命周期：进程级 singleton；Registry shared_ptr 持有地图到进程退出。
// 不负责：不执行 Air A*、不保存 Battle 动态状态、不替代 Ground MapRegistry。
#pragma once

#include "air_map.h"
#include "air_map_reader.h"
#include "nav_result.h"

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

namespace flywow_navigation {

class AirMapRegistry final {
public:
    static AirMapRegistry& Instance();
    NavResult<std::shared_ptr<const AirMap>> Load(const std::string& path);
    NavResult<bool> Freeze();
    NavResult<std::shared_ptr<const AirMap>> Find(
        std::uint32_t map_id,
        std::uint32_t map_version) const;
    std::size_t map_count() const;

private:
    struct Key {
        std::uint32_t map_id;
        std::uint32_t map_version;
        bool operator==(const Key& other) const noexcept {
            return map_id == other.map_id && map_version == other.map_version;
        }
    };
    struct KeyHash {
        std::size_t operator()(const Key& key) const noexcept {
            return static_cast<std::size_t>(key.map_id) * 0x9e3779b1u ^
                key.map_version;
        }
    };

    AirMapRegistry() = default;
    mutable std::mutex mutex_;
    bool frozen_ = false;
    std::unordered_map<Key, std::shared_ptr<const AirMap>, KeyHash> maps_;
};

} // namespace flywow_navigation
```

[新建文件] `server/third_party/skynet-flywow/navigation/native/grid_map/air_map_registry.cpp`

```cpp
// 职责：实现 AirMap 的加载、重复键拒绝、冻结和线程安全查找。
// 边界：Server Runtime Asset Registry；文件读取在锁外，容器变更只持短锁。
// 输入/输出：AMAP path/map key -> immutable shared_ptr 或稳定错误。
// 生命周期：进程级；Freeze 后运行期不再新增资产。
// 不负责：锁不包围 Air A*，不管理任何 Flying Unit。
#include "air_map_registry.h"

#include <sstream>
#include <utility>

namespace flywow_navigation {

AirMapRegistry& AirMapRegistry::Instance() {
    static AirMapRegistry registry;
    return registry;
}

NavResult<std::shared_ptr<const AirMap>> AirMapRegistry::Load(
    const std::string& path) {
    auto loaded = AirMapReader::Read(path); // I/O/CRC 在 mutex 外完成。
    if (!loaded.ok()) return loaded;

    const Key key{loaded.value->map_id(), loaded.value->map_version()};
    std::lock_guard<std::mutex> lock(mutex_);
    if (frozen_) {
        return NavResult<std::shared_ptr<const AirMap>>::Failure(
            NavError::kRegistryFrozen, "air map load attempted after freeze");
    }
    if (maps_.find(key) != maps_.end()) {
        return NavResult<std::shared_ptr<const AirMap>>::Failure(
            NavError::kDuplicateMap, "duplicate air map/version");
    }
    maps_.emplace(key, loaded.value);
    return loaded;
}

NavResult<bool> AirMapRegistry::Freeze() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (frozen_) return NavResult<bool>::Success(false);
    frozen_ = true;
    return NavResult<bool>::Success(true);
}

NavResult<std::shared_ptr<const AirMap>> AirMapRegistry::Find(
    std::uint32_t map_id,
    std::uint32_t map_version) const {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto iterator = maps_.find(Key{map_id, map_version});
    if (iterator == maps_.end()) {
        std::ostringstream detail;
        detail << "air map_id=" << map_id << " map_version=" << map_version;
        return NavResult<std::shared_ptr<const AirMap>>::Failure(
            NavError::kMapNotFound, detail.str());
    }
    return NavResult<std::shared_ptr<const AirMap>>::Success(iterator->second);
}

std::size_t AirMapRegistry::map_count() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return maps_.size();
}

} // namespace flywow_navigation
```

注意：Ground/AMAP 使用相同 `kDuplicateMap/kMapNotFound` 稳定错误码是可以的，调用边界通过 detail 和调用 API 知道是哪种资产。这里不为了一个课程 sidecar 把 NavError 扩成几十个“AirXXX”枚举；真正需要跨协议区分时再增加稳定码。

---

### 21.5.1 `NavigationContext` 的 Air Scratch 具体怎么加

在 `navigation_context.h` 的公开区增加：

```cpp
// 返回当前 Battle 配对的 AirMap；Ground-only Context 可以为空。
const std::shared_ptr<const AirMap>& air_map() const noexcept { return air_map_; }

// 开始一次独立 Air A*；只重置 Air heap/generation，不影响 Ground Query。
void BeginAirQuery();
// 触达一个 Air node；generation 语义与 Ground TouchNode 相同。
NodeScratch& TouchAirNode(std::int32_t node_index);
std::vector<std::int32_t>& air_heap_storage() noexcept { return air_heap_; }
std::size_t air_heap_size() const noexcept { return air_heap_size_; }
void set_air_heap_size(std::size_t value) noexcept { air_heap_size_ = value; }
std::uint32_t air_visited_nodes() const noexcept { return air_visited_nodes_; }
```

私有区增加：

```cpp
std::shared_ptr<const AirMap> air_map_; // immutable static asset，可为空。
std::vector<NodeScratch> air_nodes_;    // 每 Cell 一个 Air A* scratch，本 Context 独占。
std::vector<std::int32_t> air_heap_;    // Air Binary Heap backing array。
std::size_t air_heap_size_ = 0;
std::uint32_t air_query_generation_ = 0;
std::uint32_t air_visited_nodes_ = 0;
```

构造函数改为：

```cpp
NavigationContext::NavigationContext(
    std::shared_ptr<const GridMap> map,
    std::shared_ptr<const AirMap> air_map)
    : map_(std::move(map)),
      occupancy_(RequireMap(map_)),
      air_map_(std::move(air_map)) {
    if (map_->cell_count() >
        static_cast<std::size_t>(std::numeric_limits<std::int32_t>::max())) {
        throw std::invalid_argument("map has too many cells for int32 node index");
    }
    if (air_map_ &&
        (air_map_->map_id() != map_->metadata().map_id ||
         air_map_->map_version() != map_->metadata().map_version ||
         air_map_->width() != map_->metadata().width ||
         air_map_->height() != map_->metadata().height)) {
        throw std::invalid_argument("AirMap does not match GridMap identity/dimensions");
    }

    nodes_.resize(map_->cell_count());
    heap_.resize(map_->cell_count());
    if (air_map_) {
        air_nodes_.resize(map_->cell_count());
        air_heap_.resize(map_->cell_count());
    }
}
```

`BeginAirQuery/TouchAirNode` 完整实现：

```cpp
// 开始一个 Air A* generation；不扫描清零整个地图，只有 uint32 回卷才全量清 generation。
void NavigationContext::BeginAirQuery() {
    if (!air_map_) {
        throw std::logic_error("Air query requires AirMap");
    }
    ++air_query_generation_;
    if (air_query_generation_ == 0) {
        for (NodeScratch& node : air_nodes_) node.generation = 0;
        air_query_generation_ = 1;
    }
    air_heap_size_ = 0;
    air_visited_nodes_ = 0;
}

// 返回当前 Air generation 对应的 scratch；首次触达惰性初始化。
NavigationContext::NodeScratch& NavigationContext::TouchAirNode(
    std::int32_t node_index) {
    if (node_index < 0 ||
        static_cast<std::size_t>(node_index) >= air_nodes_.size()) {
        throw std::out_of_range("Air A* node_index outside scratch array");
    }
    NodeScratch& node = air_nodes_[static_cast<std::size_t>(node_index)];
    if (node.generation != air_query_generation_) {
        node.generation = air_query_generation_;
        node.g_cost = std::numeric_limits<std::uint64_t>::max();
        node.parent_index = -1;
        node.heap_index = -1;
        node.state = NodeState::kUnseen;
        ++air_visited_nodes_;
    }
    return node;
}
```

这里多占一份 `NodeScratch + heap` 内存是刻意选择。第三课要先把 Ground/Air 状态边界做清楚，再用 benchmark 判断是否值得做 scratch 复用。不要在没有内存证据时通过一个 `mode` 共用数组，把两套 generation/heap 语义缠在一起。

---


## 22. `AirGridPathfinder`

[新建文件]

```text
server/third_party/skynet-flywow/navigation/native/grid_map/air_grid_pathfinder.h
server/third_party/skynet-flywow/navigation/native/grid_map/air_grid_pathfinder.cpp
```

它解决：

```text
start WorldPosition
-> 使用 Ground Grid 做 World/Grid 坐标转换
-> 只按 AMAP NoFly 做 XZ passability
-> 8-way A*
-> 禁止 NoFly corner cutting
-> 输出 WorldPosition Path
-> 每个点 Y = ground cell height + flight_height_mm
```

本课不创建 `INavigationBackend`。

`AirGridPathfinder` 是当前真实出现的“空中规则”，不是 Ground/Detour Backend 抽象。

### 22.1 不重新造一份 global scratch

最简单且正确的实现有两种：

```text
A. Air 查询复用当前 Battle NavigationContext 的 scratch，但每次查询独占使用；
B. NavigationContext 内增加独立 AirQueryScratch。
```

课程采用 B，更容易通过测试证明 Ground/Air 查询互不污染：

```text
NavigationContext
  ground scratch
  air scratch
  DynamicOccupancy ground
```

Air 当前不做 dynamic occupancy。

### 22.2 Air A* 固定规则

```text
8-way
Binary Heap
generation stamp
no per-node heap allocation
NoFly = blocked
对角时两个 side cell 都必须 flyable
heuristic = Octile
```

和 Ground A* 相同的算法知识不重复大讲，但代码仍遵守相同性能纪律。

### 22.3 Lua Binding

第三课新增稳定调用：

```lua
context:find_air_path(
    start_world,
    end_world,
    flight_height_mm)
```

返回仍然是第二课同一个 Path userdata：

```text
path:count()
path:world_point(i)
path:length_mm()
```

禁止新增一个 `AirPath` 只因为来源不同。

还新增一个给技能落点使用的只读 Ground 投影：

```lua
context:normalize_ground_position(world_position)
```

它只做：

```text
World XZ -> Ground Grid Cell
-> 越界明确失败
-> 保留输入 X/Z
-> Y 改成 BMAP 权威 cell height
```

它不检查 Unit footprint、不写 DynamicOccupancy，因此 FireWall 选择地面落点时不需要假装移动一个单位来取得高度。

Air advance 仍新增：

```lua
context:advance_air_path({
    unit_id = unit_id,
    path = path,
    from_world = current_world,
    distance_mm = tick_distance_mm,
    flight_height_mm = flight_height_mm,
})
```

Air advance 不提交 Ground DynamicOccupancy，只验证下一 XZ 子步没有进入 NoFly，并重新计算 Y。

### 22.4 Native 测试

在现有统一：

```text
server/third_party/skynet-flywow/navigation/native/grid_map/tests/navigation_test.cpp
```

增加：

```text
straight air path
fly over ground blocked cell
NoFly detour
NoFly no path
NoFly diagonal corner cutting
height = ground height + flight height
Ground query 后 Air query 不污染 scratch
Air query 后 Ground query 不污染 scratch
多个线程共享 immutable GridMap/AirMap + 独立 Context
```

仍然输出：

```text
ALL_TESTS_OK
```

不为 AirMap 再创建一套散乱测试程序。

### 22.5 `AirGridPathfinder` 的完整公开合同

[新建文件] `server/third_party/skynet-flywow/navigation/native/grid_map/air_grid_pathfinder.h`

```cpp
// 职责：在 AMAP NoFly 约束下执行二维 Air Grid A*，返回业务 WorldPosition Path。
// 边界：Server Native Battle Navigation；只借用当前 Battle 的 NavigationContext。
// 输入/输出：start/end WorldPosition + flight profile -> Path/NavError。
// 生命周期：A* scratch 归 Context；返回 Path 按值拥有自己的 world points。
// 不负责：不做动态空中 crowd、不修改 Ground Occupancy、不执行 Skynet/I/O/yield。
#pragma once

#include "navigation_context.h"
#include "navigation_path.h"
#include "nav_result.h"

#include <cstdint>

namespace flywow_navigation {

struct AirMoveProfile {
    std::int32_t flight_height_mm = 2500;      // 相对 BMAP 地表的目标离地高度。
    std::int32_t max_height_delta_mm = 2000;   // 相邻 Cell 地表允许的最大高度差。
};

class AirGridPathfinder final {
public:
    // start/end 的 XZ 先由 Ground Grid 做 WorldToGrid；Y 只用于调用边界，不决定 Cell。
    // 成功 Path 每个点的 Y = 对应 Ground Cell height + flight_height_mm。
    // NoFly/边界/高度差非法返回明确 NavError；同步执行、不分配 per-node heap object。
    static NavResult<Path> FindPath(
        NavigationContext& context,
        const WorldPosition& start,
        const WorldPosition& end,
        const AirMoveProfile& profile);
};

} // namespace flywow_navigation
```

`max_height_delta_mm` 是当前课程对“爬升/下降限制”的最小表达：它限制相邻 XZ Cell 所需跟随的地表高度变化。如果以后要做真实飞行速度学，才把垂直速度、加速度、独立 Y 轨迹提升为完整运动系统；本课不把 2D Air Grid 偷偷升级成 3D Navigation。

---

### 22.5.1 第二个 Path 推进实现出现后，再提取最小整数导航数学

第二课的 Ground `GridPathfinder` 已经有两段很关键的私有数值代码：

```text
SegmentLengthMm
InterpolateAxis
```

第三课 `AirGridPathfinder` 现在成为第二个真实消费者。如果直接在 Air 文件里再写一份 `sqrt/插值`，后面很容易出现 Ground 与 Air 的整数舍入不一致；但也没有必要因此创建一整套“通用 Navigation Framework”。本课只提取这两个已经被两个真实实现共同使用的最小 helper。

[新建文件]

```text
server/third_party/skynet-flywow/navigation/native/grid_map/navigation_math.h
```

```cpp
// 职责：提供 Ground/Air Path 推进共同使用的确定性整数长度与插值函数。
// 边界：Server Native Navigation Math；只处理 WorldPosition 单轴/线段整数计算。
// 输入/输出：int32 世界毫米坐标与 uint64 距离 -> 精确受限的整数结果或 false。
// 生命周期：header-only 纯函数；无全局状态、无堆分配、无 I/O/锁/yield。
// 不负责：不判断 Grid 可走性、不推进 Occupancy、不决定 Battle 速度或导航策略。
#pragma once

#include "bmap_format.h"

#include <cstdint>
#include <limits>

namespace flywow_navigation {
namespace navigation_math {

// 返回非负 uint64 的整数平方根，结果向下取整。
// Newton 迭代只使用整数除法；value=0/1 直接返回，不依赖 libm 浮点行为。
inline std::uint64_t IntegerSqrt(std::uint64_t value) noexcept {
    if (value < 2) return value;
    std::uint64_t x = value;
    std::uint64_t y = value / 2 + 1;
    while (y < x) {
        x = y;
        y = (x + value / x) / 2;
    }
    return x;
}

// 计算 XZ 线段整数毫米长度；平方和无法用 uint64 表示时返回 false。
// a/b 是借用的世界坐标；out 由调用方提供；不修改输入、不分配。
inline bool SegmentLengthMm(
    const WorldPosition& a,
    const WorldPosition& b,
    std::uint64_t* out) noexcept {
    if (out == nullptr) return false;

    const std::int64_t signed_dx =
        static_cast<std::int64_t>(b.x_mm) - a.x_mm;
    const std::int64_t signed_dz =
        static_cast<std::int64_t>(b.z_mm) - a.z_mm;
    const std::uint64_t dx = static_cast<std::uint64_t>(
        signed_dx < 0 ? -signed_dx : signed_dx);
    const std::uint64_t dz = static_cast<std::uint64_t>(
        signed_dz < 0 ? -signed_dz : signed_dz);
    const std::uint64_t max = std::numeric_limits<std::uint64_t>::max();

    if ((dx != 0 && dx > max / dx) ||
        (dz != 0 && dz > max / dz)) {
        return false;
    }
    const std::uint64_t dx2 = dx * dx;
    const std::uint64_t dz2 = dz * dz;
    if (dx2 > max - dz2) return false;

    *out = IntegerSqrt(dx2 + dz2);
    return true;
}

// 按 progress/length 在线段单轴做确定性整数插值；除法向 0 截断。
// origin/target 是世界毫米；progress 必须不大于 length；溢出返回 false。
inline bool InterpolateAxis(
    std::int32_t origin,
    std::int32_t target,
    std::uint64_t progress,
    std::uint64_t length,
    std::int32_t* out) noexcept {
    if (out == nullptr || length == 0 || progress > length ||
        length > static_cast<std::uint64_t>(
            std::numeric_limits<std::int64_t>::max())) {
        return false;
    }

    const std::int64_t delta =
        static_cast<std::int64_t>(target) - origin;
    const std::uint64_t magnitude = static_cast<std::uint64_t>(
        delta < 0 ? -delta : delta);
    if (magnitude != 0 &&
        progress > static_cast<std::uint64_t>(
            std::numeric_limits<std::int64_t>::max()) / magnitude) {
        return false;
    }

    const std::int64_t offset =
        delta * static_cast<std::int64_t>(progress) /
        static_cast<std::int64_t>(length);
    const std::int64_t value = static_cast<std::int64_t>(origin) + offset;
    if (value < std::numeric_limits<std::int32_t>::min() ||
        value > std::numeric_limits<std::int32_t>::max()) {
        return false;
    }
    *out = static_cast<std::int32_t>(value);
    return true;
}

} // namespace flywow_navigation_math
} // namespace flywow_navigation
```

[局部修改] 第二课已有 `grid_pathfinder.cpp`：删除它匿名 namespace 中重复的 `InterpolateAxis/SegmentLengthMm` 私有实现，加入：

```cpp
#include "navigation_math.h"
```

并把调用改成：

```cpp
std::uint64_t length = 0;
if (!navigation_math::SegmentLengthMm(origin, goal, &length)) {
    return NavResult<PathAdvanceResult>::Failure(
        NavError::kSizeOverflow, "Ground path segment length overflow");
}

navigation_math::InterpolateAxis(...)
```

这不是为了 Air 重构整个 Ground A*；只是把两个已经有第二个真实调用者的确定性数值原语收敛成一份。

Air `air_grid_pathfinder.cpp` 同样加入 `navigation_math.h`，后面的 Build/Advance 都使用同一整数实现。这样 Ground/Air 不会因为一个使用整数、另一个使用 `std::sqrt(long double)` 而产生跨平台边界差异。

---

### 22.6 `AirGridPathfinder.cpp`：完整 A* 主体

这段代码故意和第二课 Ground A* 的工程纪律一致：Binary Heap、generation stamp、稳定 tie-break、禁止 corner cutting。算法概念不重复讲，但完整代码必须落地，否则“Air Grid”只是架构图。

[新建文件] `server/third_party/skynet-flywow/navigation/native/grid_map/air_grid_pathfinder.cpp`

```cpp
// 职责：实现 NoFly + 高度差约束的 8-way Air Grid A*。
// 边界：Server Native Battle Navigation；使用 Context 独立 Air scratch，不修改 Ground Occupancy。
// 输入/输出：WorldPosition/profile -> 世界坐标 Path；失败返回稳定 NavError。
// 生命周期：查询中不创建 per-node 对象；最终 Path points 是本次返回值独占分配。
// 不负责：不做动态空中避障、不做 3D voxel、不执行 I/O/Skynet/yield。
#include "air_grid_pathfinder.h"
#include "navigation_math.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <vector>

namespace flywow_navigation {
namespace {

constexpr std::uint64_t kStraightCost = 1000;
constexpr std::uint64_t kDiagonalCost = 1414;

struct Candidate {
    std::int32_t node_index = -1;
    std::uint64_t f = 0;
    std::uint64_t h = 0;
};

std::int32_t NodeIndex(const GridMap& map, const GridPos& grid) {
    return static_cast<std::int32_t>(
        static_cast<std::uint64_t>(grid.z) * map.metadata().width +
        static_cast<std::uint32_t>(grid.x));
}

GridPos GridFromIndex(const GridMap& map, std::int32_t node_index) {
    const std::uint32_t width = map.metadata().width;
    return GridPos{
        static_cast<std::int32_t>(static_cast<std::uint32_t>(node_index) % width),
        static_cast<std::int32_t>(static_cast<std::uint32_t>(node_index) / width),
    };
}

std::uint64_t Octile(const GridPos& a, const GridPos& b) {
    const std::uint64_t dx = static_cast<std::uint64_t>(
        std::abs(static_cast<std::int64_t>(a.x) - b.x));
    const std::uint64_t dz = static_cast<std::uint64_t>(
        std::abs(static_cast<std::int64_t>(a.z) - b.z));
    const std::uint64_t diagonal = std::min(dx, dz);
    const std::uint64_t straight = std::max(dx, dz) - diagonal;
    return diagonal * kDiagonalCost + straight * kStraightCost;
}

bool IsFlyable(
    const NavigationContext& context,
    const GridPos& grid) {
    return context.air_map() && !context.air_map()->IsNoFly(grid) &&
        context.map()->TryCell(grid) != nullptr;
}

bool HeightEdgeAllowed(
    const NavigationContext& context,
    const GridPos& from,
    const GridPos& to,
    const AirMoveProfile& profile) {
    const NavCell* a = context.map()->TryCell(from);
    const NavCell* b = context.map()->TryCell(to);
    if (a == nullptr || b == nullptr) return false;
    const std::int64_t delta =
        static_cast<std::int64_t>(b->height_mm) - a->height_mm;
    const std::int64_t magnitude = delta < 0 ? -delta : delta;
    return magnitude <= profile.max_height_delta_mm;
}

bool CanTraverse(
    const NavigationContext& context,
    const GridPos& from,
    const GridPos& to,
    const AirMoveProfile& profile) {
    if (!IsFlyable(context, to) || !HeightEdgeAllowed(context, from, to, profile))
        return false;

    const int dx = to.x - from.x;
    const int dz = to.z - from.z;
    if (dx != 0 && dz != 0) {
        const GridPos side_x{from.x + dx, from.z};
        const GridPos side_z{from.x, from.z + dz};
        // NoFly corner cutting 与 Ground obstacle corner cutting 同理：
        // 斜线不能从两个禁止飞行 Cell 的夹角“擦过去”。
        if (!IsFlyable(context, side_x) || !IsFlyable(context, side_z) ||
            !HeightEdgeAllowed(context, from, side_x, profile) ||
            !HeightEdgeAllowed(context, from, side_z, profile)) {
            return false;
        }
    }
    return true;
}

bool Better(
    NavigationContext& context,
    std::int32_t left,
    std::int32_t right,
    const GridPos& goal) {
    const auto& l = context.TouchAirNode(left);
    const auto& r = context.TouchAirNode(right);
    const GridPos lg = GridFromIndex(*context.map(), left);
    const GridPos rg = GridFromIndex(*context.map(), right);
    const std::uint64_t lh = Octile(lg, goal);
    const std::uint64_t rh = Octile(rg, goal);
    const std::uint64_t lf = l.g_cost + lh;
    const std::uint64_t rf = r.g_cost + rh;
    if (lf != rf) return lf < rf;
    if (lh != rh) return lh < rh;
    return left < right; // 最后按 node_index，保证相同输入稳定。
}

void HeapSwap(
    NavigationContext& context,
    std::size_t a,
    std::size_t b) {
    auto& heap = context.air_heap_storage();
    std::swap(heap[a], heap[b]);
    context.TouchAirNode(heap[a]).heap_index = static_cast<std::int32_t>(a);
    context.TouchAirNode(heap[b]).heap_index = static_cast<std::int32_t>(b);
}

void HeapUp(
    NavigationContext& context,
    std::size_t index,
    const GridPos& goal) {
    auto& heap = context.air_heap_storage();
    while (index > 0) {
        const std::size_t parent = (index - 1) / 2;
        if (!Better(context, heap[index], heap[parent], goal)) break;
        HeapSwap(context, index, parent);
        index = parent;
    }
}

void HeapDown(
    NavigationContext& context,
    std::size_t index,
    const GridPos& goal) {
    auto& heap = context.air_heap_storage();
    const std::size_t size = context.air_heap_size();
    while (true) {
        const std::size_t left = index * 2 + 1;
        const std::size_t right = left + 1;
        std::size_t best = index;
        if (left < size && Better(context, heap[left], heap[best], goal)) best = left;
        if (right < size && Better(context, heap[right], heap[best], goal)) best = right;
        if (best == index) break;
        HeapSwap(context, index, best);
        index = best;
    }
}

void HeapPush(
    NavigationContext& context,
    std::int32_t node_index,
    const GridPos& goal) {
    auto& heap = context.air_heap_storage();
    const std::size_t slot = context.air_heap_size();
    heap[slot] = node_index;
    context.set_air_heap_size(slot + 1);
    context.TouchAirNode(node_index).heap_index = static_cast<std::int32_t>(slot);
    HeapUp(context, slot, goal);
}

std::int32_t HeapPop(
    NavigationContext& context,
    const GridPos& goal) {
    auto& heap = context.air_heap_storage();
    const std::size_t size = context.air_heap_size();
    const std::int32_t result = heap[0];
    context.TouchAirNode(result).heap_index = -1;
    if (size == 1) {
        context.set_air_heap_size(0);
        return result;
    }
    heap[0] = heap[size - 1];
    context.set_air_heap_size(size - 1);
    context.TouchAirNode(heap[0]).heap_index = 0;
    HeapDown(context, 0, goal);
    return result;
}

NavResult<Path> BuildPath(
    NavigationContext& context,
    std::int32_t goal_index,
    const AirMoveProfile& profile) {
    std::vector<GridPos> reversed;
    reversed.reserve(64);
    std::int32_t current = goal_index;
    while (current >= 0) {
        reversed.push_back(GridFromIndex(*context.map(), current));
        const auto& node = context.TouchAirNode(current);
        current = node.parent_index;
        if (reversed.size() > context.map()->cell_count()) {
            return NavResult<Path>::Failure(
                NavError::kInternalError, "Air path parent chain loop");
        }
    }
    std::reverse(reversed.begin(), reversed.end());

    std::vector<WorldPosition> points;
    points.reserve(reversed.size());
    for (const GridPos& grid : reversed) {
        auto world = context.map()->GridToWorldCenter(grid);
        if (!world.ok()) {
            return NavResult<Path>::Failure(world.error, world.detail);
        }
        const std::int64_t y =
            static_cast<std::int64_t>(world.value.y_mm) + profile.flight_height_mm;
        if (y < std::numeric_limits<std::int32_t>::min() ||
            y > std::numeric_limits<std::int32_t>::max()) {
            return NavResult<Path>::Failure(
                NavError::kSizeOverflow, "Air path worldY overflow");
        }
        world.value.y_mm = static_cast<std::int32_t>(y);
        points.push_back(world.value);
    }
    std::uint64_t length_mm = 0;
    for (std::size_t index = 1; index < points.size(); ++index) {
        std::uint64_t segment = 0;
        if (!navigation_math::SegmentLengthMm(
                points[index - 1], points[index], &segment)) {
            return NavResult<Path>::Failure(
                NavError::kSizeOverflow, "Air path segment length overflow");
        }
        if (length_mm > std::numeric_limits<std::uint64_t>::max() - segment) {
            return NavResult<Path>::Failure(
                NavError::kPathTooLong, "Air path length overflow");
        }
        length_mm += segment;
    }
    return NavResult<Path>::Success(Path(std::move(points), length_mm));
}

} // namespace

NavResult<Path> AirGridPathfinder::FindPath(
    NavigationContext& context,
    const WorldPosition& start,
    const WorldPosition& end,
    const AirMoveProfile& profile) {
    if (!context.air_map()) {
        return NavResult<Path>::Failure(
            NavError::kMapNotFound, "AirMap is not loaded for NavigationContext");
    }
    if (profile.flight_height_mm <= 0 || profile.max_height_delta_mm < 0) {
        return NavResult<Path>::Failure(
            NavError::kInvalidArgument, "invalid AirMoveProfile");
    }

    auto start_grid = context.map()->WorldToGrid(start);
    auto end_grid = context.map()->WorldToGrid(end);
    if (!start_grid.ok()) return NavResult<Path>::Failure(start_grid.error, start_grid.detail);
    if (!end_grid.ok()) return NavResult<Path>::Failure(end_grid.error, end_grid.detail);
    if (!IsFlyable(context, start_grid.value)) {
        return NavResult<Path>::Failure(
            NavError::kStartNotNavigable, "Air start is NoFly/outside map");
    }
    if (!IsFlyable(context, end_grid.value)) {
        return NavResult<Path>::Failure(
            NavError::kEndNotNavigable, "Air end is NoFly/outside map");
    }

    context.BeginAirQuery();
    const std::int32_t start_index = NodeIndex(*context.map(), start_grid.value);
    const std::int32_t end_index = NodeIndex(*context.map(), end_grid.value);
    auto& start_node = context.TouchAirNode(start_index);
    start_node.g_cost = 0;
    start_node.parent_index = -1;
    start_node.state = NavigationContext::NodeState::kOpen;
    HeapPush(context, start_index, end_grid.value);

    static const int kDx[8] = {1,-1,0,0,1,1,-1,-1};
    static const int kDz[8] = {0,0,1,-1,1,-1,1,-1};

    while (context.air_heap_size() > 0) {
        const std::int32_t current_index = HeapPop(context, end_grid.value);
        auto& current_node = context.TouchAirNode(current_index);
        if (current_node.state == NavigationContext::NodeState::kClosed) continue;
        current_node.state = NavigationContext::NodeState::kClosed;
        if (current_index == end_index) {
            return BuildPath(context, current_index, profile);
        }

        const GridPos current = GridFromIndex(*context.map(), current_index);
        for (int direction = 0; direction < 8; ++direction) {
            const GridPos next{current.x + kDx[direction], current.z + kDz[direction]};
            if (!CanTraverse(context, current, next, profile)) continue;
            const std::int32_t next_index = NodeIndex(*context.map(), next);
            auto& next_node = context.TouchAirNode(next_index);
            if (next_node.state == NavigationContext::NodeState::kClosed) continue;

            const bool diagonal = kDx[direction] != 0 && kDz[direction] != 0;
            const std::uint64_t step = diagonal ? kDiagonalCost : kStraightCost;
            if (current_node.g_cost > std::numeric_limits<std::uint64_t>::max() - step) {
                return NavResult<Path>::Failure(
                    NavError::kSizeOverflow, "Air A* g_cost overflow");
            }
            const std::uint64_t candidate = current_node.g_cost + step;
            if (next_node.state == NavigationContext::NodeState::kUnseen ||
                candidate < next_node.g_cost) {
                next_node.g_cost = candidate;
                next_node.parent_index = current_index;
                if (next_node.state == NavigationContext::NodeState::kUnseen) {
                    next_node.state = NavigationContext::NodeState::kOpen;
                    HeapPush(context, next_index, end_grid.value);
                } else {
                    HeapUp(context,
                           static_cast<std::size_t>(next_node.heap_index),
                           end_grid.value);
                }
            }
        }
    }

    return NavResult<Path>::Failure(
        NavError::kNoPath, "No Air path under current NoFly/height rules");
}

} // namespace flywow_navigation
```

这里没有 path smoothing。原因是第三课 Air Grid 的目标是先验证 NoFly/高度/Server 权威链；Ground smoothing 已在第二课完整学习。等 Air Path 在 benchmark 中证明路点过多确实值得优化时，可以复用相同 Supercover 思路增加 Air line-of-sight，但必须重新验证所有跨过 Cell 的 NoFly 与高度约束，不能简单删中间点。

---

### 22.7 Lua Binding：把 Air 资产和查询接到现有 flywow_navigation 模块

[局部修改]

```text
server/third_party/skynet-flywow/navigation/native/navigation_binding.cpp
server/third_party/skynet-flywow/navigation/lualib/flywow_navigation.lua
```

Lua 调用方继续使用 FlyWow 公开入口：

```lua
local navigation = require "flywow_navigation"
```

Native 在同一模块中扩展 load_air_map(path)、new_context(map_id, map_version) 和 Context 的 Air 查询方法。沿用现有 LuaBinding/LuaTable 约定：参数读取失败及领域错误统一返回 nil, { code = ..., message = ... }；公开 Binding API 不新增 luaL_check* 或 luaL_error。

load_air_map 在 Battle Process 启动阶段读取并注册 immutable AMAP，返回实际 map_id、map_version、width、height。new_context 通过进程级 MapRegistry 与 AirMapRegistry 查找资产：找不到 AMAP 时允许 Ground-only Context；找到时校验身份和尺寸，再把 shared_ptr<const AirMap> 传入 Context。Ground/Air scratch 仍由每个 Context 独占。

注册入口时沿用 module.setFunction(...) 与 registerContext(...) 模式；闭包捕获进程级 Registry 地址，不捕获 Lua State 私有 Context。同步更新 FlyWow Wrapper 的 LuaDoc，说明失败 record、ownership 和同步不 yield 合同。

### 22.8 Server 启动时怎样保证 BMAP/AMAP 是同一个发布版本

[局部修改] server/config/battle.lua：该文件已有 map、profiles、cluster 和 Battle Runtime 配置。只在现有 map table 中同步更新版本和 BMAP/AMAP 路径；下方是 map 字段片段，不要替换整个 return table。

```lua
map = {
    id = 1001,
    version = 2, -- 本次发布将 BMAP 与 AMAP 统一到版本 2；先重导出整包并校验 Manifest。
    bmap = "../shared/navigation/<已验证候选目录>/map.bmap",
    amap = "../shared/navigation/<已验证候选目录>/map.amap",
},
```

只有当 BMAP、AMAP、Manifest 都通过验证并进入同一个已提交候选目录后，才把配置切到该目录。旧版 battle_1001.bmap 不能与新版本 AMAP 混用。

[局部修改] server/lualib/battle/navigation/query_logic.lua 的 start(options)：先加载 Profile，再加载 BMAP 和 AMAP，并逐字段核对身份：

```lua
local profiles_loaded, profiles_error = navigation.load_profiles(config.profiles)
assert(profiles_loaded,
       profiles_error and (profiles_error.code .. ": " .. profiles_error.message) or
       "load_profiles failed")

local ground, ground_error = navigation.load_map(config.map.bmap)
assert(ground,
       ground_error and (ground_error.code .. ": " .. ground_error.message) or
       "load_map failed")
assert(ground.map_id == config.map.id, "BMAP map_id does not match config")
assert(ground.map_version == config.map.version,
       "BMAP map_version does not match config")

local loaded_air, air_error = navigation.load_air_map(config.map.amap)
assert(loaded_air,
       air_error and (air_error.code .. ": " .. air_error.message) or
       "load_air_map failed")
assert(loaded_air.map_id == config.map.id, "AMAP map_id does not match config")
assert(loaded_air.map_version == config.map.version,
       "AMAP map_version does not match config")
assert(ground.width == loaded_air.width and ground.height == loaded_air.height,
       "BMAP/AMAP dimensions mismatch")
```

navigation_query 在启动阶段加载 Profile 与两份静态资产；Worker 不重新读磁盘。进程级 Native Registry 持有不可变资产，new_context(map_id, map_version) 取得共享资产并创建 Battle-local scratch/occupancy。

故障检查覆盖：AMAP 缺失、payload CRC 错、map_id/map_version 不匹配、宽高不一致，以及 BMAP/AMAP 只更新一份。每种情况都应在 Battle Process ready 前明确失败。

### 22.9 Native AirMap/A* 回归测试：在现有 navigation_test 中补齐关键 Case

继续放进现有：

```text
server/third_party/skynet-flywow/navigation/native/grid_map/tests/navigation_test.cpp
```

不要另造 `air_test.cpp`。下面给出建议 helper 和关键 case，具体测试宏继续使用仓库现有风格。

```cpp
// 构造一个与现有 Golden Grid 同尺寸的 AirMap；nofly_cells 使用 z*width+x 下标。
// 返回 immutable shared_ptr，测试拥有 shared_ptr 生命周期；不执行 I/O。
std::shared_ptr<const flywow_navigation::AirMap> MakeAirMap(
    std::uint32_t map_id,
    std::uint32_t map_version,
    std::uint32_t width,
    std::uint32_t height,
    const std::vector<std::size_t>& nofly_cells) {
    std::vector<std::uint8_t> values(
        static_cast<std::size_t>(width) * height, 0);
    for (std::size_t index : nofly_cells) {
        if (index >= values.size()) throw std::runtime_error("test nofly index out of range");
        values[index] = 1;
    }
    return std::make_shared<const flywow_navigation::AirMap>(
        map_id, map_version, width, height, std::move(values));
}

// 飞行应无视 Ground walkable bit，只受 map bounds、NoFly 和高度差限制。
void TestAirFliesAcrossGroundBlocked() {
    auto ground = MakeNavigationGoldenGrid();
    auto air = MakeAirMap(
        ground->metadata().map_id,
        ground->metadata().map_version,
        ground->metadata().width,
        ground->metadata().height,
        {});
    flywow_navigation::NavigationContext context(ground, air);
    flywow_navigation::AirMoveProfile profile{2500, 5000};
    auto path = flywow_navigation::AirGridPathfinder::FindPath(
        context,
        WorldAt(*ground, 1, 1),
        WorldAt(*ground, 6, 1),
        profile);
    CHECK(path.ok());
    CHECK(path.value.count() >= 2);
}

// 两个正交 NoFly 夹角必须阻止对角穿越。
void TestAirNoFlyCornerCutting() {
    auto ground = MakeOpenGoldenGrid(4, 4);
    auto air = MakeAirMap(ground->metadata().map_id,
                          ground->metadata().map_version, 4, 4,
                          {1, 4}); // (1,0) 和 (0,1) blocked。
    flywow_navigation::NavigationContext context(ground, air);
    flywow_navigation::AirMoveProfile profile{2500, 5000};
    auto path = flywow_navigation::AirGridPathfinder::FindPath(
        context, WorldAt(*ground, 0, 0), WorldAt(*ground, 1, 1), profile);
    CHECK(!path.ok());
    CHECK(path.error == flywow_navigation::NavError::kNoPath ||
          path.error == flywow_navigation::NavError::kEndNotNavigable);
}

// Ground/Air 使用独立 generation/heap；交替查询不能污染结果。
void TestGroundAirScratchIsolation() {
    auto ground = MakeNavigationGoldenGrid();
    auto air = MakeAirMap(ground->metadata().map_id,
                          ground->metadata().map_version,
                          ground->metadata().width,
                          ground->metadata().height,
                          {});
    flywow_navigation::NavigationContext context(ground, air);
    const auto ground_before = RunKnownGroundPath(context);
    const auto air_path = RunKnownAirPath(context);
    const auto ground_after = RunKnownGroundPath(context);
    CHECK(air_path.ok());
    CHECK(ground_before.ok());
    CHECK(ground_after.ok());
    CHECK(SameWorldPoints(ground_before.value, ground_after.value));
}
```

还要加 Reader corruption：

```text
bad magic
unsupported version
header size 31/33
zero dimensions
width*height overflow
payload size mismatch
truncated
trailing bytes
payload CRC mismatch
cell value=2
```

测试顺序建议：先 Reader/Asset，再 A*，最后并发。Reader 都不可信时直接跑 A* 没有意义。

# 第九部分：Skill Runtime——只实现五个能覆盖核心模型的技能

## 23. 技能列表先固定，不继续膨胀

主课必须完成的是 Spec 规定的三类执行模型：瞬发、表现型弹丸、Server 权威逻辑弹丸，以及最小 Player/AI 技能组合。FireWall AreaEffect 与本课 Buff 示例是可选扩展；不影响主课验收，建议先跳过，等核心链路通过后再单独学习。

本课使用：

```text
1001 Slash
  瞬发近战
  Ground target only

1002 Fireball
  表现型弹丸
  Ground / Air target
  既用于 Air -> Ground，也用于 Air -> Air Golden Case

1003 FrostBolt
  Server 权威逻辑弹丸
  Ground / Air target
  命中附加 Slow

1004 FireWall
  持续 AreaEffect
  Ground only
  周期伤害 + Burning

1005 Haste
  Self Buff
  +30% MoveSpeed
```

GroundEnemy：

```text
Slash
```

FlyingEnemy：

```text
Fireball
```

Player：

```text
Move
Slash
Fireball
FrostBolt
FireWall
Haste
```

这五个案例已经覆盖：

```text
即时结算
延迟但不模拟轨迹
Server 模拟轨迹和碰撞
持续区域对象
Buff / Debuff / Periodic Effect
```

到这里停止，不继续加几十个技能。

## 24. `skill_defs.lua`

[新建文件]

```text
server/lualib/battle/skill_defs.lua
```

```lua
-- 职责：声明第三课固定 SkillDefinition；定义数据，不持有任何运行时状态。
-- 边界：Server Battle Config；由 skill_runtime 只读使用。
-- 输入/输出：skill_id -> immutable definition table。
-- 生命周期：当前 Lua State require 后常驻；业务代码不得运行中修改 definition。
-- 不负责：不计 CD、不生成 Projectile、不扣 HP、不读取 Unity 配置。
local M = {}

M.TARGET_GROUND = 0x01
M.TARGET_AIR = 0x02
M.TARGET_ALL = M.TARGET_GROUND | M.TARGET_AIR

local definitions = {
    [1001] = {
        id = 1001,
        name = "Slash",
        model = "INSTANT_TARGET",
        target_mask = M.TARGET_GROUND,
        range_mm = 1200,
        cooldown_ticks = 20, -- 1 秒；tick_ms=50。
        damage = 20,
    },
    [1002] = {
        id = 1002,
        name = "Fireball",
        model = "PRESENTATION_PROJECTILE",
        target_mask = M.TARGET_ALL,
        range_mm = 12000,
        cooldown_ticks = 30,
        damage = 24,
        travel_ticks = 8,
    },
    [1003] = {
        id = 1003,
        name = "FrostBolt",
        model = "LOGIC_PROJECTILE",
        target_mask = M.TARGET_ALL,
        range_mm = 14000,
        cooldown_ticks = 40,
        damage = 16,
        projectile_speed_mm_per_sec = 10000,
        projectile_radius_mm = 300,
        slow_buff_id = 2002,
    },
    [1004] = {
        id = 1004,
        name = "FireWall",
        model = "AREA_EFFECT",
        target_mask = M.TARGET_GROUND,
        range_mm = 10000,
        cooldown_ticks = 100,
        duration_ticks = 80,
        pulse_interval_ticks = 10,
        pulse_damage = 6,
        half_long_mm = 3000,
        half_thick_mm = 600,
        burning_buff_id = 2003,
    },
    [1005] = {
        id = 1005,
        name = "Haste",
        model = "SELF_BUFF",
        target_mask = M.TARGET_GROUND,
        range_mm = 0,
        cooldown_ticks = 120,
        buff_id = 2001,
    },
}

-- 返回只读 SkillDefinition；调用方不得修改返回 table。
-- skill_id 必须为整数；不存在返回 nil；不分配外部资源、不 yield。
function M.get(skill_id)
    return definitions[skill_id]
end

return M
```

### 24.1 为什么 cooldown 用 Tick

第三课 `tick_ms` 固定后：

```text
cooldown_end_tick
```

比：

```text
os.time + 秒
skynet.now + centisecond
```

更适合确定性 Battle。

如果未来不同 Battle tick_ms 不同，SkillDefinition 可以改成毫秒，再在 Battle 创建时转换成整 Tick 规则；本课不增加这一层。

## 25. 最小 Buff Definition

[新建文件]

```text
server/lualib/battle/buff_defs.lua
```

```lua
-- 职责：声明第三课最小 Buff 数据，只覆盖 Haste、Slow、Burning 三种核心模型。
-- 边界：Server Battle Config；Buff Runtime 只读使用。
-- 输入/输出：buff_id -> immutable definition。
-- 生命周期：Lua State 内常驻；不保存 Battle/Unit 引用。
-- 不负责：不实现完整驱散、Aura、Trigger Graph 或配置 DSL。
local M = {}

local definitions = {
    [2001] = {
        id = 2001,
        name = "Haste",
        duration_ticks = 60,
        max_stacks = 1,
        reapply = "REFRESH",
        move_speed_permille = 300, -- +30%。
    },
    [2002] = {
        id = 2002,
        name = "Slow",
        duration_ticks = 50,
        max_stacks = 1,
        reapply = "REFRESH",
        move_speed_permille = -400, -- -40%。
    },
    [2003] = {
        id = 2003,
        name = "Burning",
        duration_ticks = 60,
        max_stacks = 3,
        reapply = "ADD_STACK_REFRESH",
        periodic_interval_ticks = 10,
        periodic_damage_per_stack = 2,
        move_speed_permille = 0,
    },
}

-- 返回固定 BuffDefinition；不存在返回 nil；调用方不得修改 definition。
function M.get(buff_id)
    return definitions[buff_id]
end

return M
```

完整 Buff 系统仍然不属于第三课。

这里故意只支持两种 reapply policy：

```text
REFRESH
ADD_STACK_REFRESH
```

不做：

```text
独立来源堆叠
优先级覆盖
驱散分类
免疫标签
Aura child buff
trigger on hit/on kill
```

# 第十部分：最小 Buff Runtime

> 可选扩展：本部分的 Haste、Slow、Burning 不属于 Lesson 3 Spec 的主课验收。先完成三类技能、Ground/Air 目标约束、命中/伤害/死亡和确定性验收；需要练习状态效果时再回来。

## 26. Buff 的 owner 是 Unit，不是 Skynet Timer

错误做法：

```text
Apply Haste
-> skynet.timeout(300, remove_haste)
```

问题：

```text
自动快速模拟无法复用
Replay 依赖墙钟
Battle 暂停/快速推进语义混乱
每个 Buff 都产生 Timer
```

正确：

```text
BuffInstance.expire_tick
BuffInstance.next_periodic_tick
```

由：

```text
battle_core.step()
```

统一推进。

## 27. `buff_runtime.lua`

[新建文件]

```text
server/lualib/battle/buff_runtime.lua
```

```lua
-- 职责：管理一场 Battle 内 Unit 的最小 Buff 生命周期、移速 Modifier 和周期伤害时机。
-- 边界：Server Battle Core Library；只操作传入 state/unit，不 require skynet。
-- 输入/输出：apply/remove/tick/effective speed 的纯 Lua 状态变化与效果 record。
-- 生命周期：BuffInstance 存在于 unit.buffs 数组，随 Unit/Battle 销毁。
-- 不负责：不做 Aura、驱散分类、复杂属性图或外部 Timer。
local buff_defs = require "battle.buff_defs"

local M = {}

-- 构造稳定 key；本课同一 target/buff 合并，不按 source 拆多个独立实例。
local function buff_key(buff_id)
    return tostring(buff_id)
end

-- 找到一个 Unit 当前 Buff；数组顺序用于稳定 tick，不依赖 pairs()。
local function find_buff(unit, buff_id)
    local key = buff_key(buff_id)
    local index = unit.buff_index[key]
    if index == nil then return nil end
    return unit.buffs[index]
end

-- 应用或刷新 Buff；返回用于 BattleEvent 的纯值 record。
-- source_unit_id 只记录归因；不保存 source unit table 引用；不 I/O、不 yield。
function M.apply(state, unit, buff_id, source_unit_id)
    local def = assert(buff_defs.get(buff_id), "unknown buff_id")
    local current = find_buff(unit, buff_id)
    if current == nil then
        current = {
            buff_id = buff_id,
            source_unit_id = source_unit_id,
            stack_count = 1,
            expire_tick = state.logic_tick + def.duration_ticks,
            next_periodic_tick = def.periodic_interval_ticks and
                (state.logic_tick + def.periodic_interval_ticks) or nil,
        }
        unit.buffs[#unit.buffs + 1] = current
        unit.buff_index[buff_key(buff_id)] = #unit.buffs
        return {
            type = "BUFF_ADDED",
            unit_id = unit.id,
            source_unit_id = source_unit_id,
            buff_id = buff_id,
            stack_count = current.stack_count,
            expire_tick = current.expire_tick,
        }
    end

    if def.reapply == "REFRESH" then
        current.expire_tick = state.logic_tick + def.duration_ticks
    elseif def.reapply == "ADD_STACK_REFRESH" then
        current.stack_count = math.min(current.stack_count + 1, def.max_stacks)
        current.expire_tick = state.logic_tick + def.duration_ticks
        if def.periodic_interval_ticks ~= nil and current.next_periodic_tick == nil then
            current.next_periodic_tick = state.logic_tick + def.periodic_interval_ticks
        end
    else
        error("unsupported buff reapply policy: " .. tostring(def.reapply))
    end

    current.source_unit_id = source_unit_id
    return {
        type = "BUFF_REFRESHED",
        unit_id = unit.id,
        source_unit_id = source_unit_id,
        buff_id = buff_id,
        stack_count = current.stack_count,
        expire_tick = current.expire_tick,
    }
end

-- 移除数组项并修复后续 index；Buff 数量在课程场景很小，O(n) 可接受。
local function remove_at(unit, index)
    local removed = unit.buffs[index]
    table.remove(unit.buffs, index)
    unit.buff_index[buff_key(removed.buff_id)] = nil
    for i = index, #unit.buffs do
        unit.buff_index[buff_key(unit.buffs[i].buff_id)] = i
    end
    return removed
end

-- 推进一个 Unit 的 Buff 周期与过期；返回 effect/event 数组，由 Battle Core 决定伤害顺序。
-- 先处理到期前应触发的 periodic，再在 expire_tick 移除；整个函数不 yield。
function M.tick(state, unit)
    local effects = {}
    local index = 1
    while index <= #unit.buffs do
        local instance = unit.buffs[index]
        local def = assert(buff_defs.get(instance.buff_id))

        if def.periodic_interval_ticks ~= nil and
           instance.next_periodic_tick ~= nil and
           state.logic_tick >= instance.next_periodic_tick and
           state.logic_tick <= instance.expire_tick then
            effects[#effects + 1] = {
                kind = "PERIODIC_DAMAGE",
                source_unit_id = instance.source_unit_id,
                target_unit_id = unit.id,
                buff_id = instance.buff_id,
                damage = def.periodic_damage_per_stack * instance.stack_count,
            }
            instance.next_periodic_tick =
                instance.next_periodic_tick + def.periodic_interval_ticks
        end

        if state.logic_tick >= instance.expire_tick then
            local removed = remove_at(unit, index)
            effects[#effects + 1] = {
                kind = "BUFF_REMOVED",
                target_unit_id = unit.id,
                buff_id = removed.buff_id,
            }
        else
            index = index + 1
        end
    end
    return effects
end

-- 计算当前生效移动速度。
-- 本课规则：所有 move_speed_permille 做加法，再乘 base；结果至少 0，使用整数除法。
-- 例：Haste +300 与 Slow -400 同时存在 -> 1000-100 = 900，即基础速度 90%。
function M.effective_move_speed(unit)
    local modifier = 0
    for _, instance in ipairs(unit.buffs) do
        local def = assert(buff_defs.get(instance.buff_id))
        modifier = modifier + (def.move_speed_permille or 0) * instance.stack_count
    end
    local scale = math.max(0, 1000 + modifier)
    return (unit.base_move_speed_mm_per_sec * scale) // 1000
end

return M
```

### 27.1 为什么不在 Buff 结束时把 speed 改回来

不要：

```text
Apply Haste: unit.speed = unit.speed * 1.3
Expire Haste: unit.speed = unit.speed / 1.3
```

叠加 Haste/Slow、刷新、顺序变化后很容易恢复错误。

本课始终：

```text
BaseMoveSpeed
+ 当前 Buff modifiers
-> 每 Tick 计算 EffectiveMoveSpeed
```

### 27.2 加速/减速为什么通常不需要重新 A*

Path 回答：

> 往哪里走。

MoveSpeed 回答：

> 这一 Tick 最多沿 Path 走多远。

所以：

```text
Haste / Slow
-> 不改 AgentProfile
-> 不改可通行性
-> 不立即重寻路
-> 只改变 advance_path 的 distance_mm
```

如果未来 Buff 改的是：

```text
体型
飞行状态
可走 Area
碰撞半径
```

才可能使 Navigation Profile 或 Path 合法性变化。

# 第十一部分：SkillRuntime、Projectile 与 FireWall

> 本部分中瞬发技能、两类弹丸和统一 Server 结算属于主线；FireWall AreaEffect 是可选扩展，不是第三课通过条件。

## 28. Runtime 数据不做成 Service

这些都是一场 Battle 内的普通模块/对象：

```text
Skill Runtime
Projectile
AreaEffect
Buff
```

所以文件放：

```text
server/lualib/battle/
```

不要因为名字里有 `Runtime/System/Manager` 就放进 `service/`。

它们与 BattleWorker 处在同一个 Lua State，调用是普通 Lua 函数，不是 `skynet.call`。

## 29. `skill_runtime.lua`

[新建文件]

```text
server/lualib/battle/skill_runtime.lua
```

为了保持课程边界，本文件统一拥有：

```text
cast validation
cooldown
presentation projectile scheduled impact
logic projectile
FireWall AreaEffect
```

不再拆出五六个只有几十行的 Manager。

核心结构：

```lua
-- 职责：执行第三课五个代表性 Skill 的 Server 权威运行时逻辑。
-- 边界：Server Battle Core Library；只读 SkillDefinition，修改当前 Battle state。
-- 输入/输出：cast intent / tick -> projectile、area effect、damage/buff effect record。
-- 生命周期：projectile/area effect 都属于一场 Battle；Battle 结束统一销毁。
-- 不负责：不解析网络、不播放特效、不使用墙钟 Timer、不访问 DB。
local skill_defs = require "battle.skill_defs"
local buff_runtime = require "battle.buff_runtime"

local M = {}

-- 二维整数距离平方；坐标范围由 Battle Core 输入校验保证不会溢出 int64。
local function distance2(a, b)
    local dx = a.x_mm - b.x_mm
    local dz = a.z_mm - b.z_mm
    return dx * dx + dz * dz
end

-- 检查 target layer；nil target 由 Area/Self 技能单独处理。
local function target_allowed(def, target)
    return target ~= nil and (def.target_mask & target.target_layer) ~= 0
end

-- 检查 CD，并在成功 cast 时提交 next_ready_tick。
local function commit_cooldown(state, caster, def)
    local ready = caster.cooldowns[def.id] or 0
    if state.logic_tick < ready then
        return false, { code = "SKILL_COOLDOWN", message = "skill is on cooldown" }
    end
    caster.cooldowns[def.id] = state.logic_tick + def.cooldown_ticks
    return true
end

-- 对目标施加权威伤害；真正实现由 battle_core 注入 callback，避免循环 require。
local function apply_damage(callbacks, source_id, target_id, damage, reason)
    return callbacks.apply_damage(source_id, target_id, damage, reason)
end
```

### 29.1 Instant：Slash

```lua
local function cast_instant_target(state, caster, target, def, callbacks)
    if not target_allowed(def, target) then
        return false, { code = "INVALID_TARGET_LAYER", message = "target layer rejected" }
    end
    if distance2(caster.position, target.position) > def.range_mm * def.range_mm then
        return false, { code = "OUT_OF_RANGE", message = "target is out of range" }
    end
    local ok, err = commit_cooldown(state, caster, def)
    if not ok then return false, err end

    callbacks.emit({
        type = "SKILL_CAST",
        unit_id = caster.id,
        target_id = target.id,
        skill_id = def.id,
    })
    apply_damage(callbacks, caster.id, target.id, def.damage, "SKILL_" .. def.id)
    return true
end
```

### 29.2 表现型 Fireball

Server 不每 Tick 模拟它的轨迹。

Cast 时创建：

```lua
{
    id = projectile_id,
    model = "PRESENTATION",
    skill_id = 1002,
    source_unit_id = caster.id,
    target_unit_id = target.id,
    launch_tick = state.logic_tick,
    impact_tick = state.logic_tick + def.travel_ticks,
    damage = def.damage,
}
```

并发出：

```text
PROJECTILE_LAUNCHED
```

到 `impact_tick`：

```text
如果目标仍存在且存活
-> 应用预先确定的目标型伤害
-> PROJECTILE_IMPACT
```

不做碰撞采样。

这类弹丸适用于：

> 弹道只是表现，轨迹本身不改变命中对象。

### 29.3 Server 权威 FrostBolt

FrostBolt 必须真正存在于 Server state：

```lua
{
    id
    model = "LOGIC"
    source_unit_id
    skill_id
    position
    end_position
    speed_mm_per_sec
    radius_mm
    progress_mm
    length_mm
    move_remainder
}
```

本课使用**直线 + 有界子步**，不实现弹丸 NavMesh。

每个 Tick：

```text
根据 speed 计算整数 distance budget
-> 把 budget 切成 <= projectile_radius/2 的 substep
-> 每个 substep 更新权威世界位置
-> 按 unit.id 升序检查允许 TargetMask 的单位
-> 第一个进入碰撞半径的目标命中
-> Damage + Slow
-> 销毁 Projectile
```

达到最大 range / end_position 未命中：

```text
PROJECTILE_EXPIRED
```

为什么用有界 substep：避免高速弹丸一 Tick 跨过目标产生 tunneling。

课程资源上限：

```text
MAX_LOGIC_PROJECTILES = 128 / Battle
MAX_PROJECTILE_SUBSTEPS_PER_TICK = 64 / projectile
```

超过直接拒绝 cast 或终止异常状态，不让 CPU 无界增长。

### 29.4 FireWall：持续 AreaEffect

FireWall 不是 Projectile。

Cast 完成以后立即产生：

```lua
{
    id
    skill_id
    owner_unit_id
    center_world
    orientation = "X_AXIS" / "Z_AXIS"
    half_long_mm
    half_thick_mm
    create_tick
    expire_tick
    next_pulse_tick
    pulse_interval_ticks
}
```

本课不用任意旋转浮点矩阵。

只支持：

```text
X_AXIS
Z_AXIS
```

目的：学习持续区域效果，不把课程变成几何库。

范围判定：

```lua
local function inside_firewall(area, position)
    local dx = math.abs(position.x_mm - area.center_world.x_mm)
    local dz = math.abs(position.z_mm - area.center_world.z_mm)
    if area.orientation == "X_AXIS" then
        return dx <= area.half_long_mm and dz <= area.half_thick_mm
    end
    return dz <= area.half_long_mm and dx <= area.half_thick_mm
end
```

每次 pulse：

```text
按 unit.id 升序扫描存活单位
-> 只接受 Ground target
-> 在矩形内
-> pulse damage
-> Apply Burning
```

FireWall 创建后，即使 caster 后续死亡，本课仍持续到 `expire_tick`。

这是明确规则，不是遗漏。

如果真实游戏需要“施法者死亡立即销毁”，那是新的 SkillDefinition policy。

## 30. Haste

Haste 是最简单的 Self Buff：

```text
Cast
-> Cooldown check
-> buff_runtime.apply(unit, Haste)
-> BUFF_ADDED/REFRESHED Event
```

它不会创建 Projectile 或 AreaEffect。

## 31. 技能 Runtime 的统一入口

完整公开调用面控制在：

```lua
skill_runtime.cast(state, caster, cast_intent, callbacks)
skill_runtime.tick(state, callbacks)
```

不要让 Battle Core 知道：

```text
Fireball scheduled impact 内部数组
Projectile substep 细节
FireWall pulse 实现
```

但也不要提前创建通用 `ISkillEffect`、Effect Graph 等抽象。

### 31.1 `skill_runtime.lua` 的完整第一版

前面分别解释了四种执行模型。真正落到代码时，不要让 `battle_core` 通过大量 `if skill_id == ...` 重新实现这些规则。下面给出本课完整第一版；后面 Battle Core 只负责把 `state/context/callbacks` 交给它。

[完整内容]

```lua
-- 职责：执行第三课五个代表性 Skill 的 Server 权威运行时逻辑。
-- 边界：Server Battle Core Library；只读 Skill/Buff Definition，修改当前 Battle state。
-- 输入/输出：cast intent / projectile phase / area phase -> 状态变化与 BattleEvent。
-- 生命周期：Projectile/AreaEffect 都属于一场 Battle；Battle 结束随 Core State 一起销毁。
-- 不负责：不解析网络、不播放特效、不使用墙钟 Timer、不访问 DB、不实现完整技能编辑器。
local skill_defs = require "battle.skill_defs"
local buff_runtime = require "battle.buff_runtime"

local M = {}

local MAX_LOGIC_PROJECTILES = 128
local MAX_PRESENTATION_PROJECTILES = 128
local MAX_AREA_EFFECTS = 32
local MAX_PROJECTILE_SUBSTEPS_PER_TICK = 64

-- 复制 WorldPosition，避免 Runtime/Event 与可变 Unit.position 共用同一 table。
local function copy_position(value)
    return {
        x_mm = value.x_mm,
        y_mm = value.y_mm,
        z_mm = value.z_mm,
    }
end

-- 二维距离平方用于地面范围与 FireWall；输入坐标范围由 Battle Core 创建时统一校验。
local function distance2_xz(a, b)
    local dx = a.x_mm - b.x_mm
    local dz = a.z_mm - b.z_mm
    return dx * dx + dz * dz
end

-- 三维距离平方用于逻辑 Projectile 的空间碰撞。
local function distance2_xyz(a, b)
    local dx = a.x_mm - b.x_mm
    local dy = a.y_mm - b.y_mm
    local dz = a.z_mm - b.z_mm
    return dx * dx + dy * dy + dz * dz
end

-- 64-bit 非负整数平方根，向下取整。
-- 本课坐标限制确保 x*x+y*y+z*z 不超过 Lua 5.4 integer 范围；无浮点、无 I/O、无 yield。
local function integer_sqrt(value)
    assert(math.type(value) == "integer" and value >= 0,
           "integer_sqrt requires non-negative integer")
    if value < 2 then return value end

    local x = value
    local y = (x + 1) // 2
    while y < x do
        x = y
        y = (x + value // x) // 2
    end
    return x
end

-- 根据固定起点/终点和 progress/length 做整数插值。
-- 除法向 0 截断；progress 必须位于 [0,length]；不使用浮点。
local function interpolate_axis(origin, target, progress, length)
    assert(length > 0 and progress >= 0 and progress <= length,
           "invalid projectile interpolation range")
    local delta = target - origin
    return origin + (delta * progress) // length
end

-- 返回某定义是否允许命中目标的 Ground/Air layer。
local function target_allowed(def, target)
    return target ~= nil and target.hp > 0 and
        (def.target_mask & target.target_layer) ~= 0
end

-- 只检查技能 CD，不提前提交状态；其他 cast validation 失败时不能吃掉 CD。
local function cooldown_ready(state, caster, def)
    local ready_tick = caster.cooldowns[def.id] or 0
    if state.logic_tick < ready_tick then
        return false, {
            code = "SKILL_COOLDOWN",
            message = "skill is on cooldown",
        }
    end
    return true
end

-- 在所有 cast 条件通过以后提交 CD；只修改当前 Unit runtime，不 I/O、不 yield。
local function commit_cooldown(state, caster, def)
    caster.cooldowns[def.id] = state.logic_tick + def.cooldown_ticks
end

-- 从 state.by_id 取一个存活目标并检查敌对关系和 TargetMask。
-- 返回 target 或 nil,error；不修改状态。
local function require_enemy_target(state, caster, def, target_unit_id)
    if math.type(target_unit_id) ~= "integer" or target_unit_id <= 0 then
        return nil, { code = "INVALID_TARGET", message = "target_unit_id is required" }
    end
    local target = state.by_id[target_unit_id]
    if target == nil or target.hp <= 0 then
        return nil, { code = "TARGET_NOT_ALIVE", message = "target is not alive" }
    end
    if target.camp == caster.camp then
        return nil, { code = "FRIENDLY_TARGET", message = "friendly target is not allowed" }
    end
    if not target_allowed(def, target) then
        return nil, { code = "INVALID_TARGET_LAYER", message = "target layer rejected" }
    end
    return target
end

-- 统计某类尚未结束的 Projectile；数组规模被 Battle 资源预算限制，O(n) 可接受。
local function count_projectiles(state, model)
    local count = 0
    for _, projectile in ipairs(state.projectiles) do
        if projectile.model == model then count = count + 1 end
    end
    return count
end

-- 单调分配 Battle 内 Projectile ID；不跨 Battle 持久化。
local function next_projectile_id(state)
    state.next_projectile_id = state.next_projectile_id + 1
    return state.next_projectile_id
end

-- 单调分配 Battle 内 AreaEffect ID；不跨 Battle 持久化。
local function next_area_effect_id(state)
    state.next_area_effect_id = state.next_area_effect_id + 1
    return state.next_area_effect_id
end

-- 统一发出 Buff Runtime 返回的 BUFF_ADDED/BUFF_REFRESHED 事件。
local function apply_buff(state, target, buff_id, source_unit_id, callbacks)
    local event = buff_runtime.apply(
        state, target, buff_id, source_unit_id)
    callbacks.emit(event)
end

-- Instant Target：当前课程用 Slash 验证“Cast 成功即结算”。
local function cast_instant_target(state, caster, intent, def, callbacks)
    local target, target_error = require_enemy_target(
        state, caster, def, intent.target_unit_id)
    if target == nil then return false, target_error end
    if distance2_xz(caster.position, target.position) >
       def.range_mm * def.range_mm then
        return false, { code = "OUT_OF_RANGE", message = "target is out of range" }
    end
    local ready, cooldown_error = cooldown_ready(state, caster, def)
    if not ready then return false, cooldown_error end

    commit_cooldown(state, caster, def)
    callbacks.emit({
        type = "SKILL_CAST",
        unit_id = caster.id,
        target_id = target.id,
        skill_id = def.id,
        position = copy_position(caster.position),
    })
    callbacks.apply_damage(
        caster.id, target.id, def.damage, "SKILL_" .. def.id)
    return true
end

-- 表现型 Fireball：轨迹不影响命中，所以 Server 只保存 launch/impact 的逻辑事实。
local function cast_presentation_projectile(state, caster, intent, def, callbacks)
    local target, target_error = require_enemy_target(
        state, caster, def, intent.target_unit_id)
    if target == nil then return false, target_error end
    if distance2_xz(caster.position, target.position) >
       def.range_mm * def.range_mm then
        return false, { code = "OUT_OF_RANGE", message = "target is out of range" }
    end
    if count_projectiles(state, "PRESENTATION") >= MAX_PRESENTATION_PROJECTILES then
        return false, { code = "PROJECTILE_LIMIT", message = "presentation projectile limit reached" }
    end
    local ready, cooldown_error = cooldown_ready(state, caster, def)
    if not ready then return false, cooldown_error end

    commit_cooldown(state, caster, def)
    local projectile = {
        id = next_projectile_id(state),
        model = "PRESENTATION",
        skill_id = def.id,
        source_unit_id = caster.id,
        source_camp = caster.camp,
        target_unit_id = target.id,
        launch_tick = state.logic_tick,
        impact_tick = state.logic_tick + def.travel_ticks,
        launch_position = copy_position(caster.position),
        target_position_at_launch = copy_position(target.position),
        damage = def.damage,
    }
    state.projectiles[#state.projectiles + 1] = projectile

    callbacks.emit({
        type = "SKILL_CAST",
        unit_id = caster.id,
        target_id = target.id,
        skill_id = def.id,
        position = copy_position(caster.position),
    })
    callbacks.emit({
        type = "PROJECTILE_LAUNCHED",
        unit_id = caster.id,
        target_id = target.id,
        skill_id = def.id,
        projectile_id = projectile.id,
        position = copy_position(caster.position),
    })
    return true
end

-- Logic FrostBolt：固定直线终点，运行时按整数距离推进并真正做单位碰撞。
-- 它不是 homing projectile；目标移动后弹丸不会自动拐弯追踪。
local function cast_logic_projectile(state, caster, intent, def, callbacks)
    local target, target_error = require_enemy_target(
        state, caster, def, intent.target_unit_id)
    if target == nil then return false, target_error end
    local range2 = def.range_mm * def.range_mm
    if distance2_xz(caster.position, target.position) > range2 then
        return false, { code = "OUT_OF_RANGE", message = "target is out of range" }
    end
    if count_projectiles(state, "LOGIC") >= MAX_LOGIC_PROJECTILES then
        return false, { code = "PROJECTILE_LIMIT", message = "logic projectile limit reached" }
    end
    local ready, cooldown_error = cooldown_ready(state, caster, def)
    if not ready then return false, cooldown_error end

    local start_position = copy_position(caster.position)
    local end_position = copy_position(target.position)
    local length2 = distance2_xyz(start_position, end_position)
    local length_mm = integer_sqrt(length2)
    if length_mm == 0 then
        return false, { code = "INVALID_PROJECTILE_PATH", message = "zero-length projectile" }
    end

    commit_cooldown(state, caster, def)
    local projectile = {
        id = next_projectile_id(state),
        model = "LOGIC",
        skill_id = def.id,
        source_unit_id = caster.id,
        source_camp = caster.camp,
        target_mask = def.target_mask,
        position = start_position,
        start_position = start_position,
        end_position = end_position,
        speed_mm_per_sec = def.projectile_speed_mm_per_sec,
        radius_mm = def.projectile_radius_mm,
        damage = def.damage,
        slow_buff_id = def.slow_buff_id,
        progress_mm = 0,
        length_mm = length_mm,
        move_remainder = 0,
    }
    state.projectiles[#state.projectiles + 1] = projectile

    callbacks.emit({
        type = "SKILL_CAST",
        unit_id = caster.id,
        target_id = target.id,
        skill_id = def.id,
        position = copy_position(caster.position),
    })
    callbacks.emit({
        type = "PROJECTILE_LAUNCHED",
        unit_id = caster.id,
        target_id = target.id,
        skill_id = def.id,
        projectile_id = projectile.id,
        position = copy_position(start_position),
    })
    return true
end

-- FireWall：在 Ground 世界坐标创建持续矩形 AreaEffect。
-- target_world 由 Battle Core callback 用 Ground Grid 归一化，避免把客户端任意 Y 当权威高度。
local function cast_area_effect(state, caster, intent, def, callbacks)
    if type(intent.target_world) ~= "table" then
        return false, { code = "INVALID_TARGET_POSITION", message = "target_world is required" }
    end
    if intent.orientation ~= "X_AXIS" and intent.orientation ~= "Z_AXIS" then
        return false, { code = "INVALID_ORIENTATION", message = "FireWall orientation must be X_AXIS or Z_AXIS" }
    end
    if #state.area_effects >= MAX_AREA_EFFECTS then
        return false, { code = "AREA_LIMIT", message = "area effect limit reached" }
    end
    if distance2_xz(caster.position, intent.target_world) >
       def.range_mm * def.range_mm then
        return false, { code = "OUT_OF_RANGE", message = "target position is out of range" }
    end
    local ready, cooldown_error = cooldown_ready(state, caster, def)
    if not ready then return false, cooldown_error end

    local center, position_error = callbacks.normalize_ground_position(
        intent.target_world)
    if center == nil then
        return false, position_error or {
            code = "INVALID_TARGET_POSITION",
            message = "FireWall target is not on map",
        }
    end

    commit_cooldown(state, caster, def)
    local area = {
        id = next_area_effect_id(state),
        skill_id = def.id,
        owner_unit_id = caster.id,
        owner_camp = caster.camp,
        center_world = copy_position(center),
        orientation = intent.orientation,
        half_long_mm = def.half_long_mm,
        half_thick_mm = def.half_thick_mm,
        expire_tick = state.logic_tick + def.duration_ticks,
        next_pulse_tick = state.logic_tick + def.pulse_interval_ticks,
        pulse_interval_ticks = def.pulse_interval_ticks,
        pulse_damage = def.pulse_damage,
        burning_buff_id = def.burning_buff_id,
    }
    state.area_effects[#state.area_effects + 1] = area

    callbacks.emit({
        type = "SKILL_CAST",
        unit_id = caster.id,
        skill_id = def.id,
        position = copy_position(caster.position),
    })
    callbacks.emit({
        type = "AREA_CREATED",
        unit_id = caster.id,
        skill_id = def.id,
        area_effect_id = area.id,
        position = copy_position(area.center_world),
        expire_tick = area.expire_tick,
    })
    return true
end

-- Haste：Self Buff，没有目标查询，也不创建独立 Service/Timer。
local function cast_self_buff(state, caster, _intent, def, callbacks)
    local ready, cooldown_error = cooldown_ready(state, caster, def)
    if not ready then return false, cooldown_error end

    commit_cooldown(state, caster, def)
    callbacks.emit({
        type = "SKILL_CAST",
        unit_id = caster.id,
        target_id = caster.id,
        skill_id = def.id,
        position = copy_position(caster.position),
    })
    apply_buff(state, caster, def.buff_id, caster.id, callbacks)
    return true
end

-- 初始化 Skill Runtime 容器；由 battle_core.create 调一次。
-- 返回无；所有容器归当前 Battle state，绝不跨 Battle 共享。
function M.initialize_state(state)
    state.projectiles = {}
    state.area_effects = {}
    state.next_projectile_id = 0
    state.next_area_effect_id = 0
end

-- 统一处理一个已经到达当前 Tick 的 Cast intent。
-- intent 只表达 skill/target/position；成功后 Runtime 自己提交 CD/Projectile/Area/Buff。
-- callbacks 由 Battle Core 提供同步函数；所有 callback 必须 no-yield。
function M.cast(state, caster, intent, callbacks)
    assert(type(state) == "table" and type(caster) == "table",
           "skill_runtime.cast requires state and caster")
    assert(type(intent) == "table" and type(callbacks) == "table",
           "skill_runtime.cast requires intent and callbacks")

    if caster.hp <= 0 then
        return false, { code = "CASTER_DEAD", message = "dead unit cannot cast" }
    end
    local def = skill_defs.get(intent.skill_id)
    if def == nil then
        return false, { code = "UNKNOWN_SKILL", message = "skill_id is not defined" }
    end

    if def.model == "INSTANT_TARGET" then
        return cast_instant_target(state, caster, intent, def, callbacks)
    elseif def.model == "PRESENTATION_PROJECTILE" then
        return cast_presentation_projectile(state, caster, intent, def, callbacks)
    elseif def.model == "LOGIC_PROJECTILE" then
        return cast_logic_projectile(state, caster, intent, def, callbacks)
    elseif def.model == "AREA_EFFECT" then
        return cast_area_effect(state, caster, intent, def, callbacks)
    elseif def.model == "SELF_BUFF" then
        return cast_self_buff(state, caster, intent, def, callbacks)
    end

    return false, { code = "UNSUPPORTED_SKILL_MODEL", message = "unsupported skill model" }
end

-- 找到逻辑弹丸当前 substep 第一个碰撞的敌方 Unit。
-- state.units 已按 unit.id 稳定排序，因此多目标同时命中时结果确定。
local function first_projectile_hit(state, projectile, position)
    local radius2 = projectile.radius_mm * projectile.radius_mm
    for _, unit in ipairs(state.units) do
        if unit.hp > 0 and unit.camp ~= projectile.source_camp and
           (projectile.target_mask & unit.target_layer) ~= 0 and
           distance2_xyz(position, unit.position) <= radius2 then
            return unit
        end
    end
    return nil
end

-- 推进一枚逻辑弹丸一个 Tick。
-- 返回 true 表示弹丸继续存在，false 表示已命中或到达终点；全程整数计算、no-yield。
local function step_logic_projectile(state, projectile, callbacks)
    local numerator = projectile.speed_mm_per_sec * state.tick_ms +
        projectile.move_remainder
    local budget = numerator // 1000
    projectile.move_remainder = numerator % 1000

    local max_substep = math.max(1, projectile.radius_mm // 2)
    if budget > max_substep * MAX_PROJECTILE_SUBSTEPS_PER_TICK then
        error("logic projectile distance exceeds bounded substep budget")
    end

    local remaining = math.min(budget,
        projectile.length_mm - projectile.progress_mm)
    while remaining > 0 do
        local step = math.min(remaining, max_substep)
        local progress = projectile.progress_mm + step
        local candidate = {
            x_mm = interpolate_axis(
                projectile.start_position.x_mm,
                projectile.end_position.x_mm,
                progress,
                projectile.length_mm),
            y_mm = interpolate_axis(
                projectile.start_position.y_mm,
                projectile.end_position.y_mm,
                progress,
                projectile.length_mm),
            z_mm = interpolate_axis(
                projectile.start_position.z_mm,
                projectile.end_position.z_mm,
                progress,
                projectile.length_mm),
        }

        projectile.progress_mm = progress
        projectile.position = candidate
        remaining = remaining - step

        local hit = first_projectile_hit(state, projectile, candidate)
        if hit ~= nil then
            callbacks.apply_damage(
                projectile.source_unit_id,
                hit.id,
                projectile.damage,
                "PROJECTILE_" .. projectile.skill_id)
            if hit.hp > 0 and projectile.slow_buff_id ~= nil then
                apply_buff(
                    state, hit, projectile.slow_buff_id,
                    projectile.source_unit_id, callbacks)
            end
            callbacks.emit({
                type = "PROJECTILE_IMPACT",
                unit_id = projectile.source_unit_id,
                target_id = hit.id,
                skill_id = projectile.skill_id,
                projectile_id = projectile.id,
                position = copy_position(candidate),
            })
            return false
        end
    end

    if projectile.progress_mm >= projectile.length_mm then
        callbacks.emit({
            type = "PROJECTILE_EXPIRED",
            unit_id = projectile.source_unit_id,
            skill_id = projectile.skill_id,
            projectile_id = projectile.id,
            position = copy_position(projectile.position),
        })
        return false
    end

    callbacks.emit({
        type = "PROJECTILE_MOVED",
        unit_id = projectile.source_unit_id,
        skill_id = projectile.skill_id,
        projectile_id = projectile.id,
        position = copy_position(projectile.position),
    })
    return true
end

-- 处理表现型弹丸到期。
-- 目标在 launch 后移动仍不改变已选中的命中对象；如果目标在 impact 前已经死亡，则只发 Impact、不重复伤害。
local function step_presentation_projectile(state, projectile, callbacks)
    if state.logic_tick < projectile.impact_tick then return true end

    local target = state.by_id[projectile.target_unit_id]
    if target ~= nil and target.hp > 0 then
        callbacks.apply_damage(
            projectile.source_unit_id,
            target.id,
            projectile.damage,
            "PROJECTILE_" .. projectile.skill_id)
    end
    callbacks.emit({
        type = "PROJECTILE_IMPACT",
        unit_id = projectile.source_unit_id,
        target_id = projectile.target_unit_id,
        skill_id = projectile.skill_id,
        projectile_id = projectile.id,
        position = target and copy_position(target.position) or
            copy_position(projectile.target_position_at_launch),
    })
    return false
end

-- Projectile phase：按创建顺序稳定推进，并用 stable compaction 移除已经结束的 Projectile。
-- 不用 swap-remove，避免同 Tick 多 Projectile 的处理顺序随删除位置变化。
function M.tick_projectiles(state, callbacks)
    local write = 1
    for read = 1, #state.projectiles do
        local projectile = state.projectiles[read]
        local keep
        if projectile.model == "PRESENTATION" then
            keep = step_presentation_projectile(state, projectile, callbacks)
        elseif projectile.model == "LOGIC" then
            keep = step_logic_projectile(state, projectile, callbacks)
        else
            error("unknown projectile model: " .. tostring(projectile.model))
        end

        if keep then
            state.projectiles[write] = projectile
            write = write + 1
        end
    end
    for index = write, #state.projectiles do
        state.projectiles[index] = nil
    end
end

-- 判断世界 XZ 点是否落在 FireWall 矩形内；只支持 X/Z 两个轴向，避免任意角度浮点旋转。
local function inside_firewall(area, position)
    local dx = math.abs(position.x_mm - area.center_world.x_mm)
    local dz = math.abs(position.z_mm - area.center_world.z_mm)
    if area.orientation == "X_AXIS" then
        return dx <= area.half_long_mm and dz <= area.half_thick_mm
    end
    return dz <= area.half_long_mm and dx <= area.half_thick_mm
end

-- AreaEffect phase：过期先移除；未过期且到 pulse_tick 时按 unit.id 顺序结算一次。
-- caster 死亡不会删除已创建 FireWall，这是本课固定 Skill policy。
function M.tick_area_effects(state, callbacks)
    local write = 1
    for read = 1, #state.area_effects do
        local area = state.area_effects[read]
        local keep = true

        if state.logic_tick >= area.expire_tick then
            callbacks.emit({
                type = "AREA_EXPIRED",
                unit_id = area.owner_unit_id,
                skill_id = area.skill_id,
                area_effect_id = area.id,
                position = copy_position(area.center_world),
            })
            keep = false
        elseif state.logic_tick >= area.next_pulse_tick then
            callbacks.emit({
                type = "AREA_PULSE",
                unit_id = area.owner_unit_id,
                skill_id = area.skill_id,
                area_effect_id = area.id,
                position = copy_position(area.center_world),
            })
            for _, unit in ipairs(state.units) do
                if unit.hp > 0 and unit.camp ~= area.owner_camp and
                   unit.target_layer == skill_defs.TARGET_GROUND and
                   inside_firewall(area, unit.position) then
                    callbacks.apply_damage(
                        area.owner_unit_id,
                        unit.id,
                        area.pulse_damage,
                        "AREA_" .. area.skill_id)
                    if unit.hp > 0 then
                        apply_buff(
                            state, unit, area.burning_buff_id,
                            area.owner_unit_id, callbacks)
                    end
                end
            end
            area.next_pulse_tick =
                area.next_pulse_tick + area.pulse_interval_ticks
        end

        if keep then
            state.area_effects[write] = area
            write = write + 1
        end
    end
    for index = write, #state.area_effects do
        state.area_effects[index] = nil
    end
end

return M
```

这段实现故意保留几个边界：

```text
FrostBolt：只做 Unit collision，不做复杂 projectile-vs-world 几何碰撞。
FireWall：只做 X_AXIS/Z_AXIS 矩形，不做任意角旋转。
Fireball：Server 固定目标与 impact tick，Client 只插值表现。
Buff：只有 Haste/Slow/Burning 两种 reapply policy，不扩成通用 Effect Graph。
```

但这已经足够让你真正实现并区分：

```text
即时结算
表现型弹丸
逻辑弹丸
持续区域效果
Buff/周期效果
```

### 31.2 为什么逻辑弹丸使用 stable compaction

假设同 Tick 有三枚弹丸：

```text
P1 -> 命中销毁
P2 -> 继续
P3 -> 继续
```

如果用 swap-remove，把最后一枚直接换到 P1 的位置，那么后续处理顺序可能变成：

```text
P3 -> P2
```

当两个 Projectile 同 Tick 能杀死同一个单位时，这会进入确定性结果。

所以本课在 Battle Core 数据上优先：

```text
稳定顺序
> 删除 O(1)
```

Projectile/Area 数量又已经有上限，因此 stable compaction 的成本可预测。

# 第十二部分：Battle Core 的第三课演进

## 32. `battle_core.create` 现在创建统一运行时状态

[局部修改]

```text
server/lualib/battle/battle_core.lua
```

在第二课 state 基础上增加：

```lua
state.logic_tick = 0
state.mode = mode or "batch"
state.command_queue = {}
state.recorded_commands = {}
state.projectiles = {}
state.area_effects = {}
state.next_projectile_id = 0
state.next_area_effect_id = 0
state.pending_events = {}
```

单位增加：

```lua
base_move_speed_mm_per_sec
movement_layer
target_layer
flight_height_mm
cooldowns = {}
buffs = {}
buff_index = {}
last_received_command_seq = 0
move_target
control
```

第二课 `move_speed_mm_per_sec` 改名为：

```text
base_move_speed_mm_per_sec
```

不要同时保留两个容易漂移的字段。

## 33. Event 从“完整 Log”拆成“本 Tick Pending + Batch Full Log”

第二课 `emit()` 直接 append 到完整 `state.events`。

第三课在线模式不能永久保存全部 Event。

改成：

```lua
local function emit(state, event)
    state.next_event_seq = state.next_event_seq + 1
    event.seq = state.next_event_seq
    event.logic_tick = state.logic_tick
    event.logic_ms = state.logic_ms
    state.pending_events[#state.pending_events + 1] = event

    if state.mode == "batch" then
        assert(#state.events < MAX_EVENTS, "battle event limit exceeded")
        state.events[#state.events + 1] = event
    end
end
```

新增：

```lua
-- 把从上次 drain 以来的新 Event 所有权交给 Worker；返回后 Core 使用新数组。
-- Event table 不再被 Core 修改；不 I/O、不 yield。
function M.drain_events(state)
    local result = state.pending_events
    state.pending_events = {}
    return result
end
```

Batch：

```text
state.events 保存完整 Log
```

Online：

```text
Worker drain -> ring buffer
```

规则只写一套。

## 34. 一个 Tick 的固定 Phase 顺序

第三课必须把顺序写死，否则以后技能/Buff 多了会出现“同 Tick 到底谁先算”的隐性规则。

本课：

```text
1. logic_tick += 1 / logic_ms += tick_ms
2. 应用本 Tick PlayerCommand
3. Buff expire / periodic
4. AI 产生 intent
5. Skill cast
6. Ground / Air movement
7. Logic Projectile advance / collision
8. AreaEffect pulse
9. 检查 Battle End
```

表现型 Projectile 的 scheduled impact 在 Skill Runtime tick 中按固定位置处理，放在第 7 阶段，与逻辑弹丸统一属于 Projectile phase。

### 34.1 为什么 Buff 先于 Movement

如果 Slow 在 Tick 100 到期：

```text
Tick 100 movement
```

应该按已经过期后的速度还是旧速度？

本课固定：

```text
先处理 expire
再算 movement budget
```

所以 Tick 100 开始时到期的 Slow 不再影响 Tick 100 的移动。

规则一旦写下，测试就能锁定。

## 35. Player Move 与 AI Move 共用同一个 Ground 移动链

Player `MoveCommand` 只设置：

```text
unit.move_target
unit.need_repath = true
```

后续仍然使用第二课：

```text
context:find_path(...)
context:advance_path(...)
```

不要给 Player 写一套 `client_move()`。

GroundEnemy AI 只是自动决定：

```text
move_target
cast intent
```

Player 和 AI 最终进入相同移动/技能结算。

## 36. Ground movement 改用 Buff 后速度

第二课：

```lua
movement_budget(self, tick_ms)
```

第三课：

```lua
local speed = buff_runtime.effective_move_speed(self)
local numerator = speed * tick_ms + self.move_numerator_remainder
```

当 speed 改变：

```text
Path userdata 继续使用
Native cursor 继续使用
每 Tick distance_mm 改变
```

## 37. FlyingEnemy 的移动

FlyingEnemy 不调用 Ground：

```text
find_path_to_range
DynamicOccupancy
```

它使用：

```text
context:find_air_path
context:advance_air_path
```

AI 仍然遵守：

```text
目标变化 / Path 失效 / PathEnd 才重寻路
不每 Tick A*
```

进入技能范围后停止移动并施放 Fireball。

### 37.1 `advance_air_path` 到真实 FlyingEnemy 出现时才实现

第 22 节只需要证明 Air Path 能正确查询；现在 `FlyingEnemy` 第一次真的要按 fixed tick 沿路径移动，因此此处才给 Native 增加 Air Path Follow。这样仍然遵守“真实调用者出现后再扩 API”。

[局部修改]

```text
server/third_party/skynet-flywow/navigation/native/grid_map/air_grid_pathfinder.h
server/third_party/skynet-flywow/navigation/native/grid_map/air_grid_pathfinder.cpp
server/third_party/skynet-flywow/navigation/native/navigation_binding.cpp
```

在 `AirGridPathfinder` 增加：

```cpp
// 沿已有 Air Path 消耗一个 fixed-tick 距离预算。
// path/cursor 由当前 Lua Path userdata 独占；函数不修改 Ground DynamicOccupancy。
// 每个子步重新验证 NoFly/高度差，返回最后成功位置；同步执行、不 I/O、不 yield。
static NavResult<PathAdvanceResult> AdvancePath(
    NavigationContext& context,
    const Path& path,
    PathFollowCursor& cursor,
    const WorldPosition& from,
    std::uint32_t distance_mm,
    const AirMoveProfile& profile);
```

实现原则与第二课 Ground `AdvancePath()` 一致：

```text
1. 使用 Path userdata 自己的 cursor；
2. 一次调用最多固定数量 substep；
3. 每个 substep 的 X/Z 由固定 segment origin + progress 做整数插值；
4. candidate X/Z -> GridPos；
5. 校验 AMAP NoFly；
6. 对跨 Cell 的边重新校验高度差；
7. Y 永远由当前 Ground Cell height + flight_height_mm 重新计算；
8. 不写 Ground DynamicOccupancy；
9. blocked 返回正常业务状态，不把已成功移动的位置回滚。
```

核心实现使用 22.5.1 已经提取的 `navigation_math::InterpolateAxis` 与 `navigation_math::SegmentLengthMm`，Ground/Air 共用同一套确定性整数舍入。真正不同的是提交规则：Ground 调 `MoveUnit()`，Air 只验证 static Air rule 并更新返回位置。

关键主体如下：

```cpp
// 沿已有 Air Path 推进一次距离预算；完整参数合同见头文件。
NavResult<PathAdvanceResult> AirGridPathfinder::AdvancePath(
    NavigationContext& context,
    const Path& path,
    PathFollowCursor& cursor,
    const WorldPosition& from,
    std::uint32_t distance_mm,
    const AirMoveProfile& profile) {
    if (!context.air_map() || path.count() == 0 ||
        profile.flight_height_mm <= 0 || profile.max_height_delta_mm < 0) {
        return NavResult<PathAdvanceResult>::Failure(
            NavError::kInvalidArgument,
            "AdvanceAirPath requires AirMap, non-empty path and valid profile");
    }
    if (cursor.next_point_index > path.count() ||
        (path.count() > 1 && cursor.next_point_index == 0)) {
        return NavResult<PathAdvanceResult>::Failure(
            NavError::kInvalidArgument, "Air Path cursor is outside path");
    }

    PathAdvanceResult output;
    output.position = from;
    if (cursor.next_point_index == path.count()) {
        output.status = PathAdvanceStatus::kReached;
        return NavResult<PathAdvanceResult>::Success(output);
    }

    const std::uint64_t cell_size_mm = context.map()->metadata().cell_size_mm;
    const std::uint64_t max_substep_mm =
        std::max<std::uint64_t>(1, cell_size_mm / 2);
    constexpr std::uint64_t kMaxSubstepsPerCall = 4096;
    if (distance_mm > max_substep_mm * kMaxSubstepsPerCall) {
        return NavResult<PathAdvanceResult>::Failure(
            NavError::kInvalidArgument,
            "air distance budget exceeds bounded substep count");
    }

    std::uint64_t budget = distance_mm;
    std::uint64_t substeps = 0;
    GridPos previous_grid{};
    bool has_previous_grid = false;
    auto from_grid = context.map()->WorldToGrid(from);
    if (from_grid.ok()) {
        previous_grid = from_grid.value;
        has_previous_grid = true;
    }

    while (budget > 0 && cursor.next_point_index < path.count()) {
        const WorldPosition& origin = path.WorldPoint(cursor.next_point_index - 1);
        const WorldPosition& goal = path.WorldPoint(cursor.next_point_index);
        std::uint64_t length = 0;
        if (!navigation_math::SegmentLengthMm(origin, goal, &length)) {
            return NavResult<PathAdvanceResult>::Failure(
                NavError::kSizeOverflow, "Air path segment length overflow");
        }
        if (length == 0) {
            ++cursor.next_point_index;
            cursor.segment_progress_mm = 0;
            continue;
        }
        if (++substeps > kMaxSubstepsPerCall) {
            return NavResult<PathAdvanceResult>::Failure(
                NavError::kInternalError, "Air advance exceeded substep budget");
        }

        const std::uint64_t remaining = length - cursor.segment_progress_mm;
        const std::uint64_t step =
            std::min<std::uint64_t>(budget, std::min(remaining, max_substep_mm));
        const std::uint64_t progress = cursor.segment_progress_mm + step;

        WorldPosition candidate = output.position;
        if (progress == length) {
            candidate.x_mm = goal.x_mm;
            candidate.z_mm = goal.z_mm;
        } else if (!navigation_math::InterpolateAxis(origin.x_mm, goal.x_mm, progress, length,
                                    &candidate.x_mm) ||
                   !navigation_math::InterpolateAxis(origin.z_mm, goal.z_mm, progress, length,
                                    &candidate.z_mm)) {
            return NavResult<PathAdvanceResult>::Failure(
                NavError::kInvalidArgument,
                "Air path interpolation exceeds integer range");
        }

        auto candidate_grid = context.map()->WorldToGrid(candidate);
        if (!candidate_grid.ok() || context.air_map()->IsNoFly(candidate_grid.value)) {
            output.status = PathAdvanceStatus::kBlocked;
            return NavResult<PathAdvanceResult>::Success(output);
        }
        if (has_previous_grid &&
            !HeightEdgeAllowed(context, previous_grid, candidate_grid.value, profile)) {
            output.status = PathAdvanceStatus::kBlocked;
            return NavResult<PathAdvanceResult>::Success(output);
        }

        auto ground = context.map()->GridToWorldCenter(candidate_grid.value);
        if (!ground.ok()) return NavResult<PathAdvanceResult>::Failure(ground.error, ground.detail);
        const std::int64_t y =
            static_cast<std::int64_t>(ground.value.y_mm) + profile.flight_height_mm;
        if (y < std::numeric_limits<std::int32_t>::min() ||
            y > std::numeric_limits<std::int32_t>::max()) {
            return NavResult<PathAdvanceResult>::Failure(
                NavError::kSizeOverflow, "Air worldY overflow");
        }

        candidate.y_mm = static_cast<std::int32_t>(y);
        output.position = candidate;
        output.moved = output.moved ||
            candidate.x_mm != from.x_mm || candidate.z_mm != from.z_mm;
        previous_grid = candidate_grid.value;
        has_previous_grid = true;

        cursor.segment_progress_mm = progress;
        budget -= step;
        output.consumed_mm += static_cast<std::uint32_t>(step);
        if (progress == length) {
            ++cursor.next_point_index;
            cursor.segment_progress_mm = 0;
        }
    }

    output.status = cursor.next_point_index == path.count()
        ? PathAdvanceStatus::kReached
        : PathAdvanceStatus::kMoving;
    return NavResult<PathAdvanceResult>::Success(output);
}
```

Binding 的稳定 Lua API：

```lua
context:advance_air_path({
    path = path,
    from_world = unit.position,
    distance_mm = budget,
    flight_height_mm = unit.flight_height_mm,
    max_height_delta_mm = unit.max_air_height_delta_mm,
})
```

它和 Ground `advance_path` 都返回：

```text
{ status="moving|reached|blocked", position=WorldPosition, moved=bool, consumed_mm=... }
```

因此 Battle 层可以共用很多“Path 结束/blocked/repath cooldown”逻辑，但仍然不需要为 Ground/Air 提前抽一个泛化 Backend interface。

---


## 38. Damage 与 Death 统一

所有伤害来源必须进入一个函数：

```text
Slash
Presentation Fireball Impact
FrostBolt Hit
FireWall Pulse
Burning Tick
```

都调用：

```lua
apply_damage(state, context, source_id, target_id, damage, reason)
```

这一个函数负责：

```text
检查 target 存活
HP clamp 到 0
DAMAGE Event
死亡时释放 Ground Occupancy（Ground Unit）
清理移动 Path
UNIT_DEAD Event
```

Air Unit 当前没有 AirDynamicOccupancy，所以死亡时不做 Air occupancy release。

禁止每个技能各自写一套死亡逻辑。

## 39. Snapshot

新增：

```lua
function M.build_snapshot(state)
```

只返回跨 Service 需要的稳定事实：

```text
battle_id
battle_version
map_id/map_version
air_map_version
logic_tick/logic_ms
last_event_seq
finished/result
units[]
  id
  camp
  movement_layer
  position
  hp/max_hp
  effective_move_speed
  current buffs(id/stack/expire_tick)
projectiles[]（在线校正需要的最小表现字段）
area_effects[]（FireWall center/orientation/expire_tick）
```

不进入 Snapshot：

```text
Path userdata
NavigationContext
GridPos
A* scratch
Lua closure
Service handle
connection_id
```

### 39.1 Snapshot 与 Event 的职责

Event：

```text
发生过什么
用于增量表现/Replay/调试
```

Snapshot：

```text
现在是什么状态
用于首次进入、周期校正、Event gap 后恢复
```

它们不是二选一。

### 39.2 `battle_core.step()` 不是“调用几个 System”这么简单，顺序要落成代码

第三课不要把 Phase 顺序只画在图上。`battle_core.lua` 至少要收敛成下面这种结构，使 Online 和 Batch 都只能经过同一个入口：

```lua
-- 推进一场 Battle 一个固定逻辑 Tick。
-- state/context 只属于当前 Battle；本函数及其全部下游禁止 skynet.call/sleep/socket/DB/yield。
-- 返回无；所有可观察变化写入 state，并通过 emit 形成有序 Event。
function M.step(state, context)
    assert(not state.finished, "cannot step finished battle")

    state.logic_tick = state.logic_tick + 1
    state.logic_ms = state.logic_ms + state.tick_ms

    apply_player_commands(state, context)
    tick_buffs(state, context)
    collect_ai_intents(state, context)
    execute_cast_intents(state, context)
    advance_units(state, context)
    skill_runtime.tick_projectiles(state, make_skill_callbacks(state, context))
    skill_runtime.tick_area_effects(state, make_skill_callbacks(state, context))
    update_battle_end(state)
end
```

这里 `make_skill_callbacks()` 不是为了做“万能插件系统”，而是避免 `skill_runtime.lua` 反向 require `battle_core.lua` 形成循环依赖：

```lua
-- 为当前 Tick 组装同步 callback；每个 callback 都必须 no-yield。
local function make_skill_callbacks(state, context)
    return {
        emit = function(event)
            emit(state, event)
        end,
        apply_damage = function(source_id, target_id, damage, reason)
            return apply_damage(
                state, context, source_id, target_id, damage, reason)
        end,
        normalize_ground_position = function(world_position)
            return context:normalize_ground_position(world_position)
        end,
    }
end
```

这是一个很小的 dependency inversion：

```text
battle_core owns Battle rule ordering
skill_runtime owns Skill execution details
skill_runtime -X-> require battle_core
```

不需要创建 `ISkillContext`、IoC Container 或几十个 Effect interface。

### 39.3 PlayerCommand 与 AI 最终都变成同一种 Intent

建议 Core 内部统一两个 transient 数组：

```lua
state.move_intents = {}
state.cast_intents = {}
```

每 Tick 开始清空。PlayerCommand：

```lua
local function apply_player_commands(state, _context)
    state.move_intents = {}
    state.cast_intents = {}

    local commands = take_commands_for_tick(state)
    for _, command in ipairs(commands) do
        local unit = state.by_id[command.unit_id]
        if unit ~= nil and unit.hp > 0 and unit.control == "PLAYER" then
            if command.kind == "MOVE" then
                state.move_intents[#state.move_intents + 1] = {
                    unit_id = unit.id,
                    target_world = command.target_world,
                }
            elseif command.kind == "CAST" then
                state.cast_intents[#state.cast_intents + 1] = {
                    unit_id = unit.id,
                    skill_id = command.skill_id,
                    target_unit_id = command.target_unit_id,
                    target_world = command.target_world,
                    orientation = command.orientation,
                }
            end
        end
    end
end
```

AI 不直接扣血或调用 Native movement，而是继续 append 相同格式：

```text
GroundEnemy AI
-> move_intents / cast_intents

FlyingEnemy AI
-> move_intents / cast_intents

PlayerCommand
-> move_intents / cast_intents
```

之后统一：

```lua
local function execute_cast_intents(state, context)
    local callbacks = make_skill_callbacks(state, context)
    table.sort(state.cast_intents, function(a, b)
        if a.unit_id ~= b.unit_id then return a.unit_id < b.unit_id end
        return a.skill_id < b.skill_id
    end)

    for _, intent in ipairs(state.cast_intents) do
        local caster = state.by_id[intent.unit_id]
        if caster ~= nil and caster.hp > 0 then
            local ok, error_info = skill_runtime.cast(
                state, caster, intent, callbacks)
            if not ok and caster.control == "PLAYER" then
                emit(state, {
                    type = "CAST_REJECTED",
                    unit_id = caster.id,
                    skill_id = intent.skill_id,
                    reason = error_info.code,
                })
            end
        end
    end
end
```

AI cast 失败通常不需要给客户端报协议错误，因为那只是该 Tick AI 决策已经失效；下一 Tick AI 会重新判断。Player cast 失败则应该产生可观察的业务 Event 或在命令 ACK 中返回“已接收但执行失败”的后续结果，不能把“Command 入队成功”和“技能最终施放成功”混为一件事。

### 39.4 Buff phase 的完整接法

`buff_runtime.tick()` 返回纯 effect，不直接 require Battle Core：

```lua
local function tick_buffs(state, context)
    for _, unit in ipairs(state.units) do
        if unit.hp > 0 then
            local effects = buff_runtime.tick(state, unit)
            for _, effect in ipairs(effects) do
                if effect.kind == "PERIODIC_DAMAGE" then
                    apply_damage(
                        state,
                        context,
                        effect.source_unit_id,
                        effect.target_unit_id,
                        effect.damage,
                        "BUFF_" .. effect.buff_id)
                elseif effect.kind == "BUFF_REMOVED" then
                    emit(state, {
                        type = "BUFF_REMOVED",
                        unit_id = effect.target_unit_id,
                        buff_id = effect.buff_id,
                    })
                else
                    error("unknown buff effect: " .. tostring(effect.kind))
                end
            end
        end
    end
end
```

单位数组在 `create()` 阶段按 `unit.id` 排序并冻结顺序，所以同 Tick 多个 Burning 的伤害顺序稳定。

### 39.5 Damage/Death 的统一实现至少要有这个边界

```lua
-- 应用一次已经通过技能/碰撞规则确认的权威伤害。
-- damage 必须是非负整数；死亡只发生一次；Ground Occupancy 在这里统一释放。
-- 不 I/O、不 yield；返回实际扣除 HP。
local function apply_damage(
    state,
    context,
    source_id,
    target_id,
    damage,
    reason)
    assert(math.type(damage) == "integer" and damage >= 0,
           "damage must be non-negative integer")

    local target = state.by_id[target_id]
    if target == nil or target.hp <= 0 then return 0 end

    local old_hp = target.hp
    target.hp = math.max(0, target.hp - damage)
    local applied = old_hp - target.hp
    emit(state, {
        type = "DAMAGE",
        unit_id = target.id,
        source_unit_id = source_id,
        value = applied,
        hp = target.hp,
        reason = reason,
        position = copy_position(target.position),
    })

    if old_hp > 0 and target.hp == 0 then
        target.path = nil
        target.move_target = nil
        target.cast_intent = nil

        if target.movement_layer == "GROUND" then
            local released, release_error = context:release_unit(target.id)
            if released == nil then
                error("release dead ground unit failed: " ..
                    tostring(release_error and release_error.code))
            end
        end

        emit(state, {
            type = "UNIT_DEAD",
            unit_id = target.id,
            source_unit_id = source_id,
            position = copy_position(target.position),
        })
    end
    return applied
end
```

不要在 Slash、Fireball、FrostBolt、FireWall、Burning 中复制这段代码。

### 39.6 Batch `simulate()` 仍然只是不断调用同一个 `step()`

第二课的快速模拟保留，但第三课输入多了 `recorded_commands`：

```lua
function M.simulate(snapshot, context)
    local state = M.create(snapshot, context, "batch")
    load_recorded_commands(state, snapshot.recorded_commands or {})

    while not M.is_finished(state) do
        M.step(state, context)
        assert(state.logic_tick <= snapshot.max_ticks,
               "battle exceeded max_ticks")
    end
    return M.finish(state)
end
```

所以 Online 与 Batch 的区别只在外层驱动：

```text
Online
  heartbeat -> step -> heartbeat -> step

Batch
  while -> step -> step -> step -> end
```

Skill、Buff、AI、Ground/Air Navigation、Damage、Event 顺序没有第二套。

### 39.7 `battle_ai.lua`：AI 只产生与 Player 相同的 Intent

当前草稿只说明“AI 产生 intent”，但第三课需要一份真实可复制实现，否则 GroundEnemy/FlyingEnemy 仍然只是概念。

[新建文件]

```text
server/lualib/battle/battle_ai.lua
```

```lua
-- 职责：为第三课 GroundEnemy/FlyingEnemy 产生最小确定性 move/cast intent。
-- 边界：Server Battle Core Library；只读当前 Battle state，不直接移动、不扣血、不调用 Skynet。
-- 输入/输出：state -> 追加到 state.move_intents/state.cast_intents。
-- 生命周期：无私有长期状态；目标选择结果保存在 Unit runtime。
-- 不负责：不执行 A*、SkillRuntime、Projectile、Buff 或网络同步。
local skill_defs = require "battle.skill_defs"

local M = {}

-- XZ 整数距离平方；目标选择只需要平面距离，避免浮点。
local function distance2(a, b)
    local dx = a.x_mm - b.x_mm
    local dz = a.z_mm - b.z_mm
    return dx * dx + dz * dz
end

-- 判断某个单位是否属于 skill_id 允许的目标层；AI 只做候选过滤，SkillRuntime 仍会再次权威校验。
-- target.target_layer 是 Battle Runtime 事实；函数只读 Definition/Unit，不分配外部资源、不 yield。
local function can_target_with_skill(target, skill_id)
    local def = assert(skill_defs.get(skill_id), "AI skill not defined")
    return (def.target_mask & target.target_layer) ~= 0
end

-- 按技能 TargetMask 过滤后，再按最近距离、再按更小 unit.id 选择存活敌人。
-- 这一步避免 GroundEnemy 选中 Air 后一直追，而 Slash 永远被 SkillRuntime 拒绝。
-- state.units 已按 id 升序，但仍显式写 tie-break，避免以后容器变化后规则漂移。
local function choose_enemy(state, self, skill_id)
    local best = nil
    local best_distance2 = nil
    for _, candidate in ipairs(state.units) do
        if candidate.hp > 0 and candidate.camp ~= self.camp and
           can_target_with_skill(candidate, skill_id) then
            local value = distance2(self.position, candidate.position)
            if best == nil or value < best_distance2 or
               (value == best_distance2 and candidate.id < best.id) then
                best = candidate
                best_distance2 = value
            end
        end
    end
    return best
end

-- 判断当前技能是否已进入施法距离；这里只做 AI 决策提示，SkillRuntime 仍会再次权威校验。
local function in_skill_range(self, target, skill_id)
    local def = assert(skill_defs.get(skill_id), "AI skill not defined")
    return distance2(self.position, target.position) <= def.range_mm * def.range_mm
end

-- GroundEnemy：进入 Slash 范围就产生 CastIntent，否则产生追击 MoveIntent。
local function think_ground_enemy(state, self, target)
    if in_skill_range(self, target, 1001) then
        state.cast_intents[#state.cast_intents + 1] = {
            unit_id = self.id,
            skill_id = 1001,
            target_unit_id = target.id,
        }
    else
        state.move_intents[#state.move_intents + 1] = {
            unit_id = self.id,
            target_world = target.position,
            stop_range_mm = assert(skill_defs.get(1001)).range_mm,
            source = "AI",
        }
    end
end

-- FlyingEnemy：Fireball 距离足够时施法，否则使用 Air Navigation 接近。
local function think_flying_enemy(state, self, target)
    if in_skill_range(self, target, 1002) then
        state.cast_intents[#state.cast_intents + 1] = {
            unit_id = self.id,
            skill_id = 1002,
            target_unit_id = target.id,
        }
    else
        state.move_intents[#state.move_intents + 1] = {
            unit_id = self.id,
            target_world = target.position,
            stop_range_mm = assert(skill_defs.get(1002)).range_mm,
            source = "AI",
        }
    end
end

-- 按 unit.id 稳定顺序为全部 Server AI Unit 产生意图。
-- Player Unit 完全跳过；AI 失败不会直接形成网络错误，下一个 Tick 会重新决策。
function M.collect(state)
    for _, self in ipairs(state.units) do
        if self.hp > 0 and self.control == "AI" then
            local skill_id = nil
            if self.ai_kind == "GROUND_ENEMY" then
                skill_id = 1001 -- Slash：只能选择 Ground。
            elseif self.ai_kind == "FLYING_ENEMY" then
                skill_id = 1002 -- Fireball：可以选择 Ground / Air。
            else
                error("unknown ai_kind: " .. tostring(self.ai_kind))
            end

            local target = self.ai_target_id and state.by_id[self.ai_target_id] or nil
            if target == nil or target.hp <= 0 or target.camp == self.camp or
               not can_target_with_skill(target, skill_id) then
                target = choose_enemy(state, self, skill_id)
                self.ai_target_id = target and target.id or nil
            end
            if target ~= nil then
                if self.ai_kind == "GROUND_ENEMY" then
                    think_ground_enemy(state, self, target)
                else
                    think_flying_enemy(state, self, target)
                end
            end
        end
    end
end

return M
```

注意两层校验：

```text
AI in_skill_range
  -> 只是减少无意义 CastIntent

skill_runtime.cast
  -> 最终权威 range/target/cooldown 校验
```

不要因为 AI 与 Server 同进程，就跳过技能运行时的正式验证。以后 AI 逻辑改复杂时，这个边界能避免“AI 技能”和“Player 技能”形成两套规则。

---

### 39.8 `battle_core.lua` 最终累计版：第三课所有 Runtime 真正汇合的位置

这一节是第三课最重要的完整代码。前面的 32～39 节分别解释了 Unit、Command、Buff、Skill、Movement、Snapshot 和 Event；现在把这些累计成一份可以直接替换第二课 `battle_core.lua` 的第三课版本。

[完整替换]

```text
server/lualib/battle/battle_core.lua
```

学习导航：

```text
必须精读：
create()
enqueue_player_command()
step()
apply_player_commands()
execute_move_intents()
execute_cast_intents()
apply_damage()
update_battle_end()
build_snapshot()
simulate()

可以略读：
纯 table copy / Snapshot 字段搬运样板
```

输入、输出和失败：

```text
create(snapshot,context,mode)
  -> Battle State
  -> snapshot/asset/unit 不合法时 error，由 Worker xpcall 收敛

enqueue_player_command(state,command,max_queue)
  -> true,{apply_tick,...}
  -> false,{code,message}

step(state,context)
  -> 推进一步，无返回
  -> 编程不变量破坏时 error，不能静默继续

build_snapshot(state)
  -> 可跨 Service/Proto 的纯 Lua record

simulate(snapshot,context)
  -> batch 完整 result + events
```

所有函数都不执行外部 I/O、不 `skynet.call/sleep`、不读取墙钟。

```lua
-- 职责：执行第三课统一的 Server 权威 fixed-tick Battle Core。
-- 边界：Server Battle Pure Runtime；不 require skynet，不访问 Socket/DB/墙钟时间。
-- 输入/输出：冻结 Snapshot + Battle-local NavigationContext + PlayerCommand -> State/Event/Snapshot/Result。
-- 生命周期：State 只属于一场 Battle；online 由 Worker 长期持有，batch 在一次 simulate 内持有。
-- yield：本文件及下游 battle_ai/skill_runtime/buff_runtime/native 同步调用全部禁止 yield。
-- 不负责：不解析 Protobuf、不拥有 Service handle、不做账号/断线恢复、不实现完整商业技能配置系统。
local battle_ai = require "battle.battle_ai"
local buff_runtime = require "battle.buff_runtime"
local skill_runtime = require "battle.skill_runtime"
local skill_defs = require "battle.skill_defs"

local M = {}

local MAX_UNITS = 128
local MAX_TICKS = 4000
local MAX_BATCH_EVENTS = 40000
local MAX_RECORDED_COMMANDS = 4096
local MAX_WORLD_MM = 800000000
local REPATH_COOLDOWN_TICKS = 6

-- 验证 Lua integer 位于闭区间；错误属于冻结输入合同错误，由 Worker 的 xpcall 收敛。
local function integer_between(value, name, minimum, maximum)
    if math.type(value) ~= "integer" or value < minimum or value > maximum then
        error(string.format("%s must be integer in [%d,%d]", name, minimum, maximum))
    end
    return value
end

-- 深复制一个毫米 WorldPosition；避免 Event/Snapshot 与可变 Unit.position 共用 table。
local function copy_position(value)
    return {
        x_mm = value.x_mm,
        y_mm = value.y_mm,
        z_mm = value.z_mm,
    }
end

-- 校验并复制业务 WorldPosition。XYZ 都限制在正负 8×10^8mm；任意两点的三维差值平方和仍小于 int64 上限，逻辑弹丸距离不会整数回绕。
local function checked_position(value, name)
    assert(type(value) == "table", name .. " must be table")
    return {
        x_mm = integer_between(value.x_mm, name .. ".x_mm", -MAX_WORLD_MM, MAX_WORLD_MM),
        y_mm = integer_between(value.y_mm, name .. ".y_mm", -MAX_WORLD_MM, MAX_WORLD_MM),
        z_mm = integer_between(value.z_mm, name .. ".z_mm", -MAX_WORLD_MM, MAX_WORLD_MM),
    }
end

-- XZ 距离平方；Battle Ground/Air 追击范围都以水平距离为主。
local function distance2_xz(a, b)
    local dx = a.x_mm - b.x_mm
    local dz = a.z_mm - b.z_mm
    return dx * dx + dz * dz
end

-- 事件唯一写入口。online 只保留 pending_events；batch 额外保存完整 events。
-- append 顺序就是同一 Tick 内的权威顺序；函数不 I/O、不 yield。
local function emit(state, event)
    state.next_event_seq = state.next_event_seq + 1
    event.seq = state.next_event_seq
    event.logic_tick = state.logic_tick
    event.logic_ms = state.logic_ms
    state.pending_events[#state.pending_events + 1] = event

    if state.mode == "batch" then
        assert(#state.events < MAX_BATCH_EVENTS, "battle event limit exceeded")
        state.events[#state.events + 1] = event
    end
end

-- 按 unit.id 构造稳定数组。输入顺序不参与确定性结果。
local function sorted_unit_sources(snapshot)
    assert(type(snapshot.units) == "table", "snapshot.units is required")
    assert(#snapshot.units >= 1 and #snapshot.units <= MAX_UNITS,
           "snapshot unit count outside course budget")
    local sources = {}
    for index, source in ipairs(snapshot.units) do
        assert(type(source) == "table", "unit source must be table")
        sources[index] = source
    end
    table.sort(sources, function(a, b)
        return assert(a.id) < assert(b.id)
    end)
    return sources
end

-- 把冻结 UnitDefinition 转成当前 Battle 可变 UnitRuntime。
-- movement_layer/control/ai_kind 是 Server Snapshot 事实，不接受 Client Runtime 修改。
local function make_unit(source, index)
    local prefix = string.format("units[%d]", index)
    local layer = assert(source.movement_layer, prefix .. ".movement_layer is required")
    assert(layer == "GROUND" or layer == "AIR", "unsupported movement_layer")
    local control = assert(source.control, prefix .. ".control is required")
    assert(control == "PLAYER" or control == "AI", "unsupported control")

    local unit = {
        id = integer_between(source.id, prefix .. ".id", 1, 0x7fffffff),
        camp = integer_between(source.camp, prefix .. ".camp", 1, 0x7fffffff),
        movement_layer = layer,
        target_layer = layer == "GROUND" and
            skill_defs.TARGET_GROUND or skill_defs.TARGET_AIR,
        control = control,
        ai_kind = source.ai_kind,
        ai_target_id = nil,
        position = checked_position(source.position, prefix .. ".position"),
        hp = integer_between(source.hp, prefix .. ".hp", 1, 0x7fffffff),
        max_hp = integer_between(source.hp, prefix .. ".hp", 1, 0x7fffffff),
        base_move_speed_mm_per_sec = integer_between(
            source.base_move_speed_mm_per_sec,
            prefix .. ".base_move_speed_mm_per_sec", 1, 1000000),
        agent_profile_id = source.agent_profile_id,
        flight_height_mm = source.flight_height_mm,
        max_air_height_delta_mm = source.max_air_height_delta_mm,
        cooldowns = {},
        buffs = {},
        buff_index = {},
        path = nil,
        path_kind = nil,
        move_target = nil,
        move_stop_range_mm = 0,
        need_repath = false,
        repath_not_before_tick = 0,
        last_path_target = nil,
        move_numerator_remainder = 0,
        last_received_command_seq = 0,
    }

    if layer == "GROUND" then
        unit.agent_profile_id = integer_between(
            source.agent_profile_id, prefix .. ".agent_profile_id", 1, 0x7fffffff)
    else
        unit.flight_height_mm = integer_between(
            source.flight_height_mm, prefix .. ".flight_height_mm", 1, 1000000)
        unit.max_air_height_delta_mm = integer_between(
            source.max_air_height_delta_mm,
            prefix .. ".max_air_height_delta_mm", 0, 1000000000)
    end

    if control == "AI" then
        assert(unit.ai_kind == "GROUND_ENEMY" or unit.ai_kind == "FLYING_ENEMY",
               prefix .. ".ai_kind is invalid")
    else
        unit.ai_kind = nil
    end
    return unit
end

-- 建立 id->UnitRuntime；重复 ID 属于冻结输入错误。
local function index_units(units)
    local by_id = {}
    for _, unit in ipairs(units) do
        assert(by_id[unit.id] == nil, "duplicate unit id: " .. unit.id)
        by_id[unit.id] = unit
    end
    return by_id
end

-- 停止当前移动；只有确实有 Path 时才发 MOVE_STOPPED，避免空闲 Tick 刷事件。
local function stop_movement(state, unit, reason)
    if unit.path == nil then return end
    unit.path = nil
    unit.path_kind = nil
    unit.last_path_target = nil
    emit(state, {
        type = "MOVE_STOPPED",
        unit_id = unit.id,
        reason = reason,
        position = copy_position(unit.position),
    })
end

-- 复制 Path userdata 的公开世界点，仅用于 MOVE_PATH Event/客户端表现。
local function copy_path_points(path)
    local points = {}
    for index = 1, path:count() do
        points[index] = path:world_point(index)
    end
    return points
end

-- 当前目标相对上次规划点移动是否足以触发重寻路；阈值固定为一个 Grid Cell。
local function path_target_changed(unit, target, threshold_mm)
    if unit.last_path_target == nil then return true end
    return distance2_xz(unit.last_path_target, target) >= threshold_mm * threshold_mm
end

-- 为一个 Unit 计算本 Tick 整数毫米移动预算；remainder 消除长期除法截断漂移。
local function movement_budget(unit, tick_ms)
    local speed = buff_runtime.effective_move_speed(unit)
    local numerator = speed * tick_ms + unit.move_numerator_remainder
    local whole = numerator // 1000
    unit.move_numerator_remainder = numerator % 1000
    return whole, speed
end

-- Player MoveCommand 和 AI MoveIntent 最终都只更新同一组移动目标字段。
-- Intent 不立即执行 A*，实际路径在 movement phase 按 cooldown/target 变化决定。
local function apply_move_intent(state, unit, intent)
    if unit.hp <= 0 then return end
    local target = checked_position(intent.target_world, "move_intent.target_world")
    local stop_range = integer_between(
        intent.stop_range_mm or 0, "move_intent.stop_range_mm", 0, MAX_WORLD_MM)

    if unit.move_target == nil or
       distance2_xz(unit.move_target, target) > 0 or
       unit.move_stop_range_mm ~= stop_range then
        unit.move_target = target
        unit.move_stop_range_mm = stop_range
        unit.need_repath = true
    end
end

-- Ground Unit 必须使用第二课已经稳定的 Grid Navigation API。
local function ensure_ground_path(state, context, unit)
    if unit.move_target == nil then return false, false end
    if unit.move_stop_range_mm > 0 and
       distance2_xz(unit.position, unit.move_target) <=
           unit.move_stop_range_mm * unit.move_stop_range_mm then
        stop_movement(state, unit, "IN_MOVE_STOP_RANGE")
        unit.move_target = nil
        unit.need_repath = false
        return false, false
    end

    local cell_size = context:cell_size_mm()
    if path_target_changed(unit, unit.move_target, cell_size) then
        unit.need_repath = true
    end
    if not unit.need_repath or state.logic_tick < unit.repath_not_before_tick then
        return unit.path ~= nil, false
    end

    local path, err
    if unit.move_stop_range_mm > 0 then
        path, err = context:find_path_to_range(
            unit.agent_profile_id,
            unit.position,
            unit.move_target,
            unit.move_stop_range_mm,
            unit.id)
    else
        path, err = context:find_path(
            unit.agent_profile_id,
            unit.position,
            unit.move_target,
            unit.id)
    end
    if path == nil then
        unit.path = nil
        unit.path_kind = nil
        unit.repath_not_before_tick = state.logic_tick + REPATH_COOLDOWN_TICKS
        emit(state, {
            type = "MOVE_REJECTED",
            unit_id = unit.id,
            reason = err and err.code or "NO_PATH",
            position = copy_position(unit.position),
        })
        return false, false
    end

    unit.path = path
    unit.path_kind = "GROUND"
    unit.need_repath = false
    unit.repath_not_before_tick = state.logic_tick + REPATH_COOLDOWN_TICKS
    unit.last_path_target = copy_position(unit.move_target)
    local speed = buff_runtime.effective_move_speed(unit)
    emit(state, {
        type = "MOVE_PATH",
        unit_id = unit.id,
        speed_mm_per_sec = speed,
        points = copy_path_points(path),
    })
    return true, true
end

-- Air Unit 使用 NoFly Air Path；不占用 Ground DynamicOccupancy。
local function ensure_air_path(state, context, unit)
    if unit.move_target == nil then return false, false end
    if unit.move_stop_range_mm > 0 and
       distance2_xz(unit.position, unit.move_target) <=
           unit.move_stop_range_mm * unit.move_stop_range_mm then
        stop_movement(state, unit, "IN_MOVE_STOP_RANGE")
        unit.move_target = nil
        unit.need_repath = false
        return false, false
    end

    local cell_size = context:cell_size_mm()
    if path_target_changed(unit, unit.move_target, cell_size) then
        unit.need_repath = true
    end
    if not unit.need_repath or state.logic_tick < unit.repath_not_before_tick then
        return unit.path ~= nil, false
    end

    local path, err = context:find_air_path(
        unit.position,
        unit.move_target,
        unit.flight_height_mm,
        unit.max_air_height_delta_mm)
    if path == nil then
        unit.path = nil
        unit.path_kind = nil
        unit.repath_not_before_tick = state.logic_tick + REPATH_COOLDOWN_TICKS
        emit(state, {
            type = "MOVE_REJECTED",
            unit_id = unit.id,
            reason = err and err.code or "NO_AIR_PATH",
            position = copy_position(unit.position),
        })
        return false, false
    end

    unit.path = path
    unit.path_kind = "AIR"
    unit.need_repath = false
    unit.repath_not_before_tick = state.logic_tick + REPATH_COOLDOWN_TICKS
    unit.last_path_target = copy_position(unit.move_target)
    emit(state, {
        type = "MOVE_PATH",
        unit_id = unit.id,
        speed_mm_per_sec = buff_runtime.effective_move_speed(unit),
        points = copy_path_points(path),
    })
    return true, true
end

-- 沿 Ground Path 推进一个 Tick；blocked/reached 都通过统一状态回到 repath 逻辑。
local function advance_ground(state, context, unit)
    if unit.path == nil then return end
    local budget = movement_budget(unit, state.tick_ms)
    local result, err = context:advance_path({
        profile_id = unit.agent_profile_id,
        unit_id = unit.id,
        path = unit.path,
        from_world = unit.position,
        distance_mm = budget,
    })
    if result == nil then
        error("advance ground path failed: " .. tostring(err and err.code))
    end
    unit.position = result.position
    if result.status == "blocked" then
        stop_movement(state, unit, "MOVE_BLOCKED")
        unit.need_repath = true
    elseif result.status == "reached" then
        stop_movement(state, unit, "PATH_END")
        unit.need_repath = true
    elseif result.status ~= "moving" then
        error("unknown ground advance status: " .. tostring(result.status))
    end
end

-- 沿 Air Path 推进一个 Tick；Y 由 Native 根据 Ground height+flightHeight 权威更新。
local function advance_air(state, context, unit)
    if unit.path == nil then return end
    local budget = movement_budget(unit, state.tick_ms)
    local result, err = context:advance_air_path({
        path = unit.path,
        from_world = unit.position,
        distance_mm = budget,
        flight_height_mm = unit.flight_height_mm,
        max_height_delta_mm = unit.max_air_height_delta_mm,
    })
    if result == nil then
        error("advance air path failed: " .. tostring(err and err.code))
    end
    unit.position = result.position
    if result.status == "blocked" then
        stop_movement(state, unit, "AIR_MOVE_BLOCKED")
        unit.need_repath = true
    elseif result.status == "reached" then
        stop_movement(state, unit, "AIR_PATH_END")
        unit.need_repath = true
    elseif result.status ~= "moving" then
        error("unknown air advance status: " .. tostring(result.status))
    end
end

-- 全部伤害来源唯一入口；Ground death 在这里释放 DynamicOccupancy，死亡事件只发一次。
local function apply_damage(state, context, source_id, target_id, damage, reason)
    assert(math.type(damage) == "integer" and damage >= 0,
           "damage must be non-negative integer")
    local target = state.by_id[target_id]
    if target == nil or target.hp <= 0 or damage == 0 then return 0 end

    local old_hp = target.hp
    target.hp = math.max(0, old_hp - damage)
    local applied = old_hp - target.hp
    emit(state, {
        type = "DAMAGE",
        unit_id = target.id,
        source_unit_id = source_id or 0,
        damage = applied,
        target_hp = target.hp,
        reason = reason or "",
        position = copy_position(target.position),
    })

    if old_hp > 0 and target.hp == 0 then
        target.path = nil
        target.path_kind = nil
        target.move_target = nil
        target.need_repath = false
        if target.movement_layer == "GROUND" then
            local released, release_error = context:release_unit(target.id)
            if released == nil then
                error("release dead unit failed: " ..
                    tostring(release_error and release_error.code))
            end
        end
        emit(state, {
            type = "UNIT_DEAD",
            unit_id = target.id,
            source_unit_id = source_id or 0,
            position = copy_position(target.position),
        })
    end
    return applied
end

-- SkillRuntime 回调只有同步 no-yield 能力；避免 skill_runtime 反向 require battle_core。
local function make_skill_callbacks(state, context)
    return {
        emit = function(event)
            emit(state, event)
        end,
        apply_damage = function(source_id, target_id, damage, reason)
            return apply_damage(state, context, source_id, target_id, damage, reason)
        end,
        normalize_ground_position = function(world_position)
            local normalized, err = context:normalize_ground_position(world_position)
            if normalized == nil then return nil, err end
            return normalized
        end,
    }
end

-- 只校验稳定 Command record，不在接收阶段提前执行路径/技能规则。
local function normalize_player_command(state, command)
    if type(command) ~= "table" then
        return nil, { code = "INVALID_COMMAND", message = "command must be table" }
    end
    if math.type(command.unit_id) ~= "integer" or command.unit_id <= 0 or
       math.type(command.command_seq) ~= "integer" or command.command_seq <= 0 then
        return nil, { code = "INVALID_COMMAND", message = "unit_id/command_seq invalid" }
    end
    local unit = state.by_id[command.unit_id]
    if unit == nil or unit.control ~= "PLAYER" then
        return nil, { code = "NOT_PLAYER_UNIT", message = "unit is not player controlled" }
    end
    if unit.hp <= 0 then
        return nil, { code = "UNIT_DEAD", message = "dead unit cannot accept command" }
    end
    if command.command_seq <= unit.last_received_command_seq then
        return nil, {
            code = "STALE_OR_DUPLICATE_COMMAND",
            message = "command_seq must be strictly increasing",
        }
    end

    local normalized = {
        unit_id = command.unit_id,
        command_seq = command.command_seq,
        apply_tick = state.logic_tick + 1,
    }
    if command.kind == "MOVE" then
        local ok, target = pcall(checked_position,
            command.target_world, "command.target_world")
        if not ok then
            return nil, { code = "INVALID_COMMAND", message = tostring(target) }
        end
        normalized.kind = "MOVE"
        normalized.target_world = target
    elseif command.kind == "CAST" then
        if math.type(command.skill_id) ~= "integer" or
           skill_defs.get(command.skill_id) == nil then
            return nil, { code = "UNKNOWN_SKILL", message = "skill_id is not defined" }
        end
        normalized.kind = "CAST"
        normalized.skill_id = command.skill_id
        normalized.target_unit_id = command.target_unit_id or 0
        normalized.orientation = command.orientation
        if command.target_world ~= nil then
            local ok, target = pcall(checked_position,
                command.target_world, "command.target_world")
            if not ok then
                return nil, { code = "INVALID_COMMAND", message = tostring(target) }
            end
            normalized.target_world = target
        end
    else
        return nil, { code = "INVALID_COMMAND_KIND", message = "kind must be MOVE or CAST" }
    end
    return normalized, unit
end

-- 在线入口：把命令变成下一 Tick 的确定性输入；队列有界，接收成功不等于最终技能必定成功。
function M.enqueue_player_command(state, command, max_queue)
    assert(type(state) == "table" and not state.finished,
           "cannot enqueue command to finished battle")
    assert(math.type(max_queue) == "integer" and max_queue >= 1,
           "max_queue must be positive integer")
    if #state.command_queue >= max_queue then
        return false, { code = "COMMAND_QUEUE_FULL", message = "command queue limit reached" }
    end

    local normalized, unit_or_error = normalize_player_command(state, command)
    if normalized == nil then return false, unit_or_error end
    if #state.recorded_commands >= MAX_RECORDED_COMMANDS then
        return false, {
            code = "COMMAND_RECORD_LIMIT",
            message = "recorded command budget reached",
        }
    end
    local unit = unit_or_error
    local recorded = {
            unit_id = normalized.unit_id,
            command_seq = normalized.command_seq,
            apply_tick = normalized.apply_tick,
            kind = normalized.kind,
            skill_id = normalized.skill_id,
            target_unit_id = normalized.target_unit_id,
            orientation = normalized.orientation,
            target_world = normalized.target_world and copy_position(normalized.target_world) or nil,
        }
    state.recorded_commands[#state.recorded_commands + 1] = recorded
    state.command_queue[#state.command_queue + 1] = normalized
    unit.last_received_command_seq = normalized.command_seq

    return true, {
        command_seq = normalized.command_seq,
        apply_tick = normalized.apply_tick,
    }
end

-- Batch regression 注入已经带 apply_tick 的记录命令；不重写 apply_tick。
local function load_recorded_commands(state, commands)
    assert(type(commands) == "table", "recorded_commands must be table")
    assert(#commands <= MAX_RECORDED_COMMANDS, "too many recorded commands")
    for index, command in ipairs(commands) do
        assert(type(command) == "table", "recorded command must be table")
        local unit = assert(state.by_id[command.unit_id], "recorded command unit missing")
        assert(unit.control == "PLAYER", "recorded command unit is not player")
        local copy = {
            unit_id = integer_between(command.unit_id, "recorded.unit_id", 1, 0x7fffffff),
            command_seq = integer_between(command.command_seq, "recorded.command_seq", 1, 0x7fffffff),
            apply_tick = integer_between(command.apply_tick, "recorded.apply_tick", 1, MAX_TICKS),
            kind = command.kind,
            skill_id = command.skill_id,
            target_unit_id = command.target_unit_id,
            orientation = command.orientation,
            target_world = command.target_world and
                checked_position(command.target_world, "recorded.target_world") or nil,
        }
        state.command_queue[#state.command_queue + 1] = copy
        unit.last_received_command_seq = math.max(unit.last_received_command_seq, copy.command_seq)
    end
    table.sort(state.command_queue, function(a, b)
        if a.apply_tick ~= b.apply_tick then return a.apply_tick < b.apply_tick end
        if a.unit_id ~= b.unit_id then return a.unit_id < b.unit_id end
        return a.command_seq < b.command_seq
    end)
end

-- 取出当前 Tick 应执行命令并稳定保留未来命令；不使用 table.remove(1) 反复搬移。
local function take_commands_for_tick(state)
    local ready = {}
    local future = {}
    for _, command in ipairs(state.command_queue) do
        if command.apply_tick <= state.logic_tick then
            ready[#ready + 1] = command
        else
            future[#future + 1] = command
        end
    end
    state.command_queue = future
    table.sort(ready, function(a, b)
        if a.unit_id ~= b.unit_id then return a.unit_id < b.unit_id end
        return a.command_seq < b.command_seq
    end)
    return ready
end

-- 将 PlayerCommand 转为当前 Tick transient intents；执行时再次验证 Unit 仍然存活。
local function apply_player_commands(state)
    state.move_intents = {}
    state.cast_intents = {}
    local commands = take_commands_for_tick(state)
    for _, command in ipairs(commands) do
        local unit = state.by_id[command.unit_id]
        if unit ~= nil and unit.hp > 0 and unit.control == "PLAYER" then
            if command.kind == "MOVE" then
                state.move_intents[#state.move_intents + 1] = {
                    unit_id = unit.id,
                    target_world = command.target_world,
                    stop_range_mm = 0,
                    source = "PLAYER",
                }
            elseif command.kind == "CAST" then
                state.cast_intents[#state.cast_intents + 1] = {
                    unit_id = unit.id,
                    skill_id = command.skill_id,
                    target_unit_id = command.target_unit_id,
                    target_world = command.target_world,
                    orientation = command.orientation,
                    command_seq = command.command_seq,
                }
            end
        end
    end
end

-- Buff expire/periodic phase；Unit 顺序稳定，所有伤害仍走 apply_damage。
local function tick_buffs(state, context)
    for _, unit in ipairs(state.units) do
        if unit.hp > 0 then
            local effects = buff_runtime.tick(state, unit)
            for _, effect in ipairs(effects) do
                if effect.kind == "PERIODIC_DAMAGE" then
                    apply_damage(
                        state, context,
                        effect.source_unit_id,
                        effect.target_unit_id,
                        effect.damage,
                        "BUFF_" .. effect.buff_id)
                elseif effect.kind == "BUFF_REMOVED" then
                    emit(state, {
                        type = "BUFF_REMOVED",
                        unit_id = effect.target_unit_id,
                        buff_id = effect.buff_id,
                    })
                else
                    error("unknown buff effect: " .. tostring(effect.kind))
                end
            end
        end
    end
end

-- 稳定执行全部 CastIntent；Player 失败产生 CAST_REJECTED，AI 失败只在下一 Tick 重算。
local function execute_cast_intents(state, context)
    table.sort(state.cast_intents, function(a, b)
        if a.unit_id ~= b.unit_id then return a.unit_id < b.unit_id end
        return (a.command_seq or 0) < (b.command_seq or 0)
    end)
    local callbacks = make_skill_callbacks(state, context)
    for _, intent in ipairs(state.cast_intents) do
        local caster = state.by_id[intent.unit_id]
        if caster ~= nil and caster.hp > 0 then
            local ok, error_info = skill_runtime.cast(state, caster, intent, callbacks)
            if not ok and caster.control == "PLAYER" then
                emit(state, {
                    type = "CAST_REJECTED",
                    unit_id = caster.id,
                    skill_id = intent.skill_id,
                    reason = error_info and error_info.code or "CAST_FAILED",
                })
            end
        end
    end
end

-- 应用当前 Tick MoveIntent；一个 Unit 最终只保留本次排序后最后一个意图。
-- 当前课程不会让 Player 与 AI 同时控制同一 Unit，因此冲突主要用于防未来误接。
local function execute_move_intents(state)
    table.sort(state.move_intents, function(a, b)
        if a.unit_id ~= b.unit_id then return a.unit_id < b.unit_id end
        return tostring(a.source or "") < tostring(b.source or "")
    end)
    local last_unit_id = nil
    for _, intent in ipairs(state.move_intents) do
        assert(intent.unit_id ~= last_unit_id,
               "multiple move intents for one unit in same tick")
        last_unit_id = intent.unit_id
        local unit = state.by_id[intent.unit_id]
        if unit ~= nil and unit.hp > 0 then apply_move_intent(state, unit, intent) end
    end
end

-- Movement phase：Ground/Air 都复用同一目标/repath policy，但调用各自真实 Navigation API。
local function advance_units(state, context)
    for _, unit in ipairs(state.units) do
        if unit.hp > 0 and unit.move_target ~= nil then
            local _, new_path
            if unit.movement_layer == "GROUND" then
                _, new_path = ensure_ground_path(state, context, unit)
                if not new_path then advance_ground(state, context, unit) end
            else
                _, new_path = ensure_air_path(state, context, unit)
                if not new_path then advance_air(state, context, unit) end
            end
        end
    end
end

-- 返回当前仍存活的 camp 数和唯一 camp；按 units 稳定扫描，不依赖 pairs() 顺序。
local function alive_camps(state)
    local seen = {}
    local count = 0
    local only = nil
    for _, unit in ipairs(state.units) do
        if unit.hp > 0 and not seen[unit.camp] then
            seen[unit.camp] = true
            count = count + 1
            only = unit.camp
        end
    end
    return count, only
end

-- Tick 末统一决定胜负；只允许第一次把 finished 从 false 改成 true。
local function update_battle_end(state)
    if state.finished then return end
    local count, only = alive_camps(state)
    if count <= 1 then
        state.finished = true
        state.result = only and ("CAMP_" .. only .. "_WIN") or "DRAW"
    elseif state.logic_tick >= state.max_ticks then
        state.finished = true
        state.result = "TIMEOUT"
    end
    if state.finished then
        emit(state, {
            type = "BATTLE_END",
            result = state.result,
        })
    end
end

-- 从冻结 Snapshot 创建一场 Runtime，并完成 Ground Occupancy 与 Air 高度归一化。
function M.create(snapshot, context, mode)
    assert(type(snapshot) == "table" and context ~= nil,
           "battle_core.create requires snapshot/context")
    assert(mode == "online" or mode == "batch", "mode must be online or batch")

    local tick_ms = integer_between(snapshot.tick_ms, "tick_ms", 10, 1000)
    local max_ticks = integer_between(
        snapshot.max_ticks or MAX_TICKS, "max_ticks", 1, MAX_TICKS)
    local map_version = integer_between(
        snapshot.map_version, "map_version", 1, 0x7fffffff)
    local air_map_version = integer_between(
        snapshot.air_map_version or snapshot.map_version,
        "air_map_version", 1, 0x7fffffff)
    assert(map_version == air_map_version,
           "Ground BMAP and Air AMAP must use the same published map version")
    local sources = sorted_unit_sources(snapshot)
    local units = {}
    for index, source in ipairs(sources) do units[index] = make_unit(source, index) end

    local state = {
        mode = mode,
        battle_id = integer_between(snapshot.battle_id, "battle_id", 1, 0x7fffffff),
        battle_version = integer_between(snapshot.battle_version, "battle_version", 1, 0x7fffffff),
        map_id = integer_between(snapshot.map_id, "map_id", 1, 0x7fffffff),
        map_version = map_version,
        air_map_version = air_map_version,
        skill_version = integer_between(snapshot.skill_version or 1,
                                        "skill_version", 1, 0x7fffffff),
        seed = integer_between(snapshot.seed or 1, "seed", -0x7fffffff, 0x7fffffff),
        tick_ms = tick_ms,
        max_ticks = max_ticks,
        logic_tick = 0,
        logic_ms = 0,
        units = units,
        by_id = index_units(units),
        command_queue = {},
        recorded_commands = {},
        move_intents = {},
        cast_intents = {},
        pending_events = {},
        events = {},
        next_event_seq = 0,
        finished = false,
        result = nil,
    }
    skill_runtime.initialize_state(state)

    -- Ground Unit 在 create 阶段登记 DynamicOccupancy；Air Unit 只校正到 groundHeight+flightHeight。
    for _, unit in ipairs(state.units) do
        if unit.movement_layer == "GROUND" then
            local normalized, err = context:place_unit(
                unit.agent_profile_id, unit.id, unit.position)
            if normalized == nil then
                error("place ground unit failed unit=" .. unit.id ..
                    " code=" .. tostring(err and err.code))
            end
            unit.position = normalized
        else
            local ground, err = context:normalize_ground_position(unit.position)
            if ground == nil then
                error("normalize air spawn failed unit=" .. unit.id ..
                    " code=" .. tostring(err and err.code))
            end
            ground.y_mm = ground.y_mm + unit.flight_height_mm
            unit.position = ground
        end
    end

    emit(state, { type = "BATTLE_BEGIN" })
    for _, unit in ipairs(state.units) do
        emit(state, {
            type = "UNIT_SPAWN",
            unit_id = unit.id,
            position = copy_position(unit.position),
            target_layer = unit.target_layer,
            target_hp = unit.hp,
        })
    end

    if mode == "batch" then
        load_recorded_commands(state, snapshot.recorded_commands or {})
    end
    return state
end

-- 推进一个 fixed tick；Phase 顺序就是本课正式 Battle 规则的一部分。
function M.step(state, context)
    assert(type(state) == "table" and not state.finished,
           "cannot step a finished battle")
    assert(state.logic_tick < state.max_ticks, "cannot step past max_ticks")

    state.logic_tick = state.logic_tick + 1
    state.logic_ms = state.logic_tick * state.tick_ms

    -- 1. PlayerCommand 在明确 apply_tick 生效；只产生 transient intent。
    apply_player_commands(state)
    -- 2. Tick 开始先处理 Buff 周期/过期，决定本 Tick 生效移速。
    tick_buffs(state, context)
    -- 3. AI 只产生与 Player 相同格式的 Intent。
    battle_ai.collect(state)
    -- 4. Cast 在 Movement 前结算。本课固定此顺序，测试必须锁定。
    execute_cast_intents(state, context)
    -- 5. MoveIntent 更新目标，然后 Ground/Air 各自沿权威 Path 推进。
    execute_move_intents(state)
    advance_units(state, context)
    -- 6. Projectile phase：表现型 impact 与逻辑弹丸碰撞都在这里。
    local callbacks = make_skill_callbacks(state, context)
    skill_runtime.tick_projectiles(state, callbacks)
    -- 7. Area phase：FireWall pulse/Burning apply。
    skill_runtime.tick_area_effects(state, callbacks)
    -- 8. 最后判断胜负/超时，BATTLE_END 永远晚于本 Tick 其他事件。
    update_battle_end(state)
end

-- 是否已经产生唯一 Battle End 结果；只读、零分配。
function M.is_finished(state)
    return state.finished == true
end

-- 把从上次 drain 以后产生的新事件所有权交给 Worker；Core 换一个新数组继续写。
function M.drain_events(state)
    local result = state.pending_events
    state.pending_events = {}
    return result
end

-- 构造当前权威 Snapshot；只返回可序列化纯值，不泄露 Path/userdata/Context/Service handle。
function M.build_snapshot(state)
    local units = {}
    for index, unit in ipairs(state.units) do
        local buffs = {}
        for buff_index, instance in ipairs(unit.buffs) do
            buffs[buff_index] = {
                buff_id = instance.buff_id,
                source_unit_id = instance.source_unit_id,
                stack_count = instance.stack_count,
                expire_tick = instance.expire_tick,
            }
        end
        units[index] = {
            id = unit.id,
            camp = unit.camp,
            movement_layer = unit.movement_layer,
            target_layer = unit.target_layer,
            position = copy_position(unit.position),
            hp = unit.hp,
            max_hp = unit.max_hp,
            effective_move_speed_mm_per_sec = buff_runtime.effective_move_speed(unit),
            buffs = buffs,
            last_accepted_command_seq = unit.last_received_command_seq,
        }
    end

    local projectiles = {}
    for index, projectile in ipairs(state.projectiles) do
        projectiles[index] = {
            id = projectile.id,
            model = projectile.model,
            skill_id = projectile.skill_id,
            source_unit_id = projectile.source_unit_id,
            target_unit_id = projectile.target_unit_id or 0,
            position = projectile.position and copy_position(projectile.position) or
                copy_position(projectile.launch_position),
        }
    end

    local areas = {}
    for index, area in ipairs(state.area_effects) do
        areas[index] = {
            id = area.id,
            skill_id = area.skill_id,
            owner_unit_id = area.owner_unit_id,
            center_world = copy_position(area.center_world),
            orientation = area.orientation,
            expire_tick = area.expire_tick,
        }
    end

    return {
        battle_id = state.battle_id,
        battle_version = state.battle_version,
        map_id = state.map_id,
        map_version = state.map_version,
        air_map_version = state.air_map_version,
        skill_version = state.skill_version,
        seed = state.seed,
        logic_tick = state.logic_tick,
        logic_ms = state.logic_ms,
        last_event_seq = state.next_event_seq,
        finished = state.finished,
        result = state.result or "",
        units = units,
        projectiles = projectiles,
        area_effects = areas,
    }
end

-- Batch 模式最终结果；online Worker 通常通过 build_snapshot + Event ring 对外同步。
function M.finish(state)
    assert(state.finished, "finish requires completed battle")
    return {
        battle_id = state.battle_id,
        battle_version = state.battle_version,
        map_id = state.map_id,
        map_version = state.map_version,
        air_map_version = state.air_map_version,
        skill_version = state.skill_version,
        seed = state.seed,
        result = state.result,
        end_logic_ms = state.logic_ms,
        end_logic_tick = state.logic_tick,
        events = state.events,
        final_snapshot = M.build_snapshot(state),
        recorded_commands = state.recorded_commands,
    }
end

-- 快速自动模拟只是不等待墙钟，不是第二套战斗规则。
function M.simulate(snapshot, context)
    local state = M.create(snapshot, context, "batch")
    while not M.is_finished(state) do
        M.step(state, context)
    end
    return M.finish(state)
end

return M
```

#### 39.8.1 为什么 Cast 在 Movement 前，而不是移动后再判距离

第三课必须选择一个确定规则，不能让 Player 和 AI 各自理解。

本课固定：

```text
Tick N 开始时的位置
-> command/buff/AI
-> Cast 校验/结算
-> Movement
-> Projectile/Area
```

所以：

```text
Tick N 开始时还差 100mm 才进 Slash range
同 Tick Movement 进入范围
-> Slash 要到 Tick N+1 才能成功
```

这不是唯一正确设计，但它简单、稳定、容易复现。以后如果产品要求“移动后立即攻击”，应该修改统一 Phase 顺序和测试，而不是只给某个 AI 加特殊分支。

#### 39.8.2 `recorded_commands` 为什么不能把网络接收时间写进去

需要保存的是：

```text
apply_tick
command_seq
业务字段
```

不保存：

```text
socket receive timestamp
Unity frame timestamp
RTT
Gateway wall clock
```

因为确定性回放需要的是“哪个逻辑 Tick 输入了什么”，不是“现实世界哪一毫秒网络包到达”。

#### 39.8.3 为什么 Online 不保存完整 Event Log

`state.events` 只在 `mode=batch` 写入。Online：

```text
pending_events
-> Worker drain
-> 有界 ring buffer
-> Client Sync
-> ring 覆盖旧事件
```

这样一场持续很久的在线 Battle 不会因为 Event Log 永久增长而形成内存泄漏。需要长期战报时，应该在 Core 外部另做异步归档/战报存储；第三课不把持久化塞进 Battle Core。

---

### 39.9 `scenario_1001.lua` 完整累计版本

前面的场景说明只有字段列表。为了让第三课可以直接实操，这里给出最终累计文件，同时保留第二课 `make_snapshot()` 兼容入口。

[完整替换]

```text
server/lualib/battle/scenario_1001.lua
```

```lua
-- 职责：构造第二/三课共享的固定 Battle_1001 Snapshot，供 batch 与在线入口复用。
-- 边界：Server Battle Input Factory；只产生全新纯 Lua 数据，不持有任何运行时状态。
-- 输入/输出：scenario/battle_id -> Snapshot；未知场景返回 nil,错误码。
-- 生命周期：每次调用都创建新 table；调用者独占后续可变副本。
-- 不负责：不接受客户端上传 HP/位置、不执行 AI/导航/技能、不读取 Unity Scene。
local M = {}

local function profiles()
    return {
        {
            id = 1,
            radius_mm = 200,
            max_step_mm = 600,
            max_slope_permille = 1000,
            area_cost_permille = {
                [0] = 1000, [1] = 3000, [2] = 1000, [3] = 1500,
            },
        },
    }
end

-- 第三课交互场景：一个 Player、一个 GroundEnemy、一个 FlyingEnemy。
function M.make_interactive_snapshot(battle_id)
    if math.type(battle_id) ~= "integer" or battle_id <= 0 then
        return nil, "BAD_BATTLE_ID"
    end
    return {
        battle_id = battle_id,
        battle_version = 3,
        map_id = 1001,
        map_version = 2,
        air_map_version = 2,
        skill_version = 1,
        seed = 123456,
        tick_ms = 50,
        max_ticks = 2400,
        profiles = profiles(),
        units = {
            {
                id = 1001,
                camp = 1,
                control = "PLAYER",
                movement_layer = "GROUND",
                agent_profile_id = 1,
                position = { x_mm = -11000, y_mm = 0, z_mm = 4000 },
                base_move_speed_mm_per_sec = 3000,
                hp = 160,
            },
            {
                id = 2001,
                camp = 2,
                control = "AI",
                ai_kind = "GROUND_ENEMY",
                movement_layer = "GROUND",
                agent_profile_id = 1,
                position = { x_mm = 9000, y_mm = 0, z_mm = -3000 },
                base_move_speed_mm_per_sec = 2200,
                hp = 120,
            },
            {
                id = 2002,
                camp = 2,
                control = "AI",
                ai_kind = "FLYING_ENEMY",
                movement_layer = "AIR",
                position = { x_mm = 11000, y_mm = 0, z_mm = 5000 },
                base_move_speed_mm_per_sec = 2600,
                flight_height_mm = 2500,
                max_air_height_delta_mm = 2500,
                hp = 90,
            },
        },
    }
end

-- 第二课兼容入口：仍然允许固定场景快速自动战斗。
-- 第三课测试可以在此基础上附加 recorded_commands 后交给同一个 battle_core.simulate。
function M.make_snapshot(scenario_id)
    if scenario_id ~= 1001 then return nil, "BAD_SCENARIO" end
    local snapshot = assert(M.make_interactive_snapshot(70001))
    -- 第二课没有 Player 输入时，把 Player 也交给最小 AI，保证 batch 能自动结束。
    snapshot.units[1].control = "AI"
    snapshot.units[1].ai_kind = "GROUND_ENEMY"
    return snapshot
end

return M
```

这里 `map_version=2` 只是教程示例：**落实到你的仓库时必须使用你实际重新 Bake/提交后的版本**，不能机械照抄数字。如果你当前 BMAP 仍是 V1 业务版本 1，就在加入 NoFly 资产并确认是否改变同一地图发布语义后统一决定版本；BMAP 与 AMAP 必须最终一致。

---

### 39.10 先写一个纯 Lua Battle Core 回归，再接 Gateway

不要写完 `battle_core.lua` 就立刻从 Unity 点按钮排查所有层。先在 Server 侧增加一个专门验证 Core 的批量入口或测试模块，输入固定 Snapshot + recorded commands，直接调用已有 BattleMgr/Worker simulate。

建议在现有 `server/service/battle/batch_runner.lua` 的第三课分支增加：

```lua
-- 构造第三课固定命令流；apply_tick 是确定性输入，不来自真实墙钟。
local function lesson3_commands()
    return {
        {
            apply_tick = 5,
            unit_id = 1001,
            command_seq = 1,
            kind = "MOVE",
            target_world = { x_mm = -3000, y_mm = 0, z_mm = 1000 },
        },
        {
            apply_tick = 25,
            unit_id = 1001,
            command_seq = 2,
            kind = "CAST",
            skill_id = 1005,
        },
        {
            apply_tick = 60,
            unit_id = 1001,
            command_seq = 3,
            kind = "CAST",
            skill_id = 1003,
            target_unit_id = 2002,
        },
        {
            apply_tick = 90,
            unit_id = 1001,
            command_seq = 4,
            kind = "CAST",
            skill_id = 1004,
            target_world = { x_mm = 3000, y_mm = 0, z_mm = 0 },
            orientation = "X_AXIS",
        },
    }
end
```

构造两份完全独立 Snapshot：

```lua
local first = assert(scenario.make_interactive_snapshot(71001))
first.recorded_commands = lesson3_commands()
local second = assert(scenario.make_interactive_snapshot(71001))
second.recorded_commands = lesson3_commands()

local result1 = assert(skynet.call(mgr, "lua", "simulate", first))
local result2 = assert(skynet.call(mgr, "lua", "simulate", second))
assert(deep_equal(result1.events, result2.events), "Lesson3 event determinism mismatch")
assert(deep_equal(result1.final_snapshot, result2.final_snapshot),
       "Lesson3 final snapshot determinism mismatch")
skynet.error("BATTLE_SKILL_REGRESSION_OK events=", #result1.events)
```

这里先证明：

```text
Command -> Buff -> AI -> Skill -> Ground/Air Move -> Projectile -> FireWall -> Death
```

在没有 Unity/Gateway 干扰时本身就是确定的。之后出现客户端表现问题，定位范围会小很多。

### 39.9.1 Ground BMAP 与 Air AMAP 的版本身份必须在 `create()` 阶段一起拒绝

第三课的 AMAP 是同一张 Ground Map 的 Air NoFly sidecar，所以它**复用 `map_id`**，不再发明一个 `air_map_id`。当前课程最简单、可验证的发布合同是：

```text
Ground BMAP: map_id=1001, map_version=N
Air AMAP:    map_id=1001, map_version=N
```

`navigation.new_context(map_id, map_version)` 会用同一个 `map_id` 分别从 Ground Registry 与 Air Registry 取资产；因此 Snapshot 只需要额外保存 `air_map_version` 用于确定性身份和显式校验。

上面的 `battle_core.create()` 完整累计版已经在创建任何 Unit/Occupancy 之前执行：

```lua
local map_version = integer_between(
    snapshot.map_version, "map_version", 1, 0x7fffffff)
local air_map_version = integer_between(
    snapshot.air_map_version or snapshot.map_version,
    "air_map_version", 1, 0x7fffffff)
assert(map_version == air_map_version,
       "Ground BMAP and Air AMAP must use the same published map version")
```

对应测试至少覆盖：

```text
Ground 1001/v2 + Air 1001/v2 -> success
Ground 1001/v2 + Air 1001/v3 -> reject before first Tick
AMAP Registry 中不存在 1001/v2       -> new_context 失败，Battle 不开始
```

如果以后出现“同一 Ground Map 可以热切换不同 Air Layer 版本”的真实需求，再设计独立资产版本/hash；第三课没有这个需求，不提前扩张身份模型。

---

# 第十三部分：协议扩展——在线命令仍走同一 FlyWow Gateway

## 40. 本课不为了在线战斗重写 Gateway

现有 FlyWow Gateway 是 request/response 模型。

为了保持课程边界，本课使用：

```text
StartInteractiveBattle
SubmitBattleCommand
SyncBattle
StopInteractiveBattle
ResumeInteractiveBattle
```

Unity 以固定频率调用 `SyncBattle` 拉取增量 Event。

这不是宣称商业游戏都应该 polling。

它只是说明：

> 第二课已经打通 Gateway 与 Battle 的双向异步 send/回推链路。本课在该传输边界上加入在线命令与 Battle Snapshot/Event 响应；不把玩家路由、命令确认或恢复逻辑放进 Gateway。

Gateway 仍只承载传输和协议；Battle Worker 产生权威 Event/Snapshot，Battle 侧决定投递对象与顺序。异步传输不可用时，按本课定义的确认、序号、Snapshot 恢复合同处理，不能把 `cluster.send` 本身视为可靠送达。

Gateway 回包关联遵守 D039：请求携带由可信 Gateway 提供的 `gateway_epoch`、数字 `connection_id`、`command_id` 和 `request_id`；Proxy 保留有限期的返回路由，Battle 回包仍是独立消息。`gateway_epoch + connection_id` 标识当前传输连接，`command_id + request_id` 关联一次协议请求。它们都不是玩家身份或 Battle 身份；不要把连接号改成拼接字符串，也不要让 Battle 保存 Gateway fd。

[局部修改] `server/service/gateway/gateway_proxy.lua`：沿用当前 D039 Proxy 合同。保留并校验 Gateway 提供的 gateway_epoch、数字 connection_id、command_id、request_id，由 Proxy 的有限返回路由关联独立响应消息；不创建旧版 route_epoch/route_token，不等待原请求协程。

当前请求转发只需保留 Gateway 已提供的关联字段（`forwarded` 是 Proxy 构造的请求 record）：

```lua
forwarded.gateway_epoch = payload.gateway_epoch
forwarded.connection_id = payload.connection_id
forwarded.command_id = payload.command_id
forwarded.request_id = payload.request_id
```

## 41. 修改 Protobuf

[局部修改]

```text
shared/protocol/navigation_query.proto
```

第二课已经占用：

```text
1001 QueryCell
1002 RunAutoBattle
```

第三课只做兼容追加，不改已有 command id 和字段号：

```text
1003 StartInteractiveBattle
1004 SubmitBattleCommand
1005 SyncBattle
1006 StopInteractiveBattle
1007 ResumeInteractiveBattle
```

新增消息按职责分成四组：

```text
Command
  MoveCommand
  CastSkillCommand
  BattleCommand(oneof)

Online RPC
  StartInteractiveBattleRequest/Response
  SubmitBattleCommandRequest/Response
  SyncBattleRequest/Response
  StopInteractiveBattleRequest/Response
  ResumeInteractiveBattleRequest/Response

Authoritative Sync
  BattleSnapshot
  BattleUnitSnapshot
  BattleBuffSnapshot
  BattleProjectileSnapshot
  BattleAreaEffectSnapshot

Event Extension
  BattleEvent 只从第二课 field 15 以后追加技能/弹丸/Buff/logic_tick 字段
```

这里先理解协议边界，**不要按一段段草图手工拼字段号**。41.2 给出基于第二课协议累计得到的完整最终 Schema，它才是第三课真正应该落到唯一 `.proto` 源文件里的版本。

最重要的权限边界仍然是：

```text
Client 可以提交
  scenario_id
  battle_id
  unit_id
  command_seq
  Move target
  Skill/target intent
  after_event_seq

Client 不可以提交
  connection_id
  authority owner
  Unit HP
  authoritative position/path
  hit/damage/death
  Snapshot
  Worker index routing
```

`connection_id` 由 FlyWow Gateway 的当前真实连接上下文附加到 handler payload；`worker_index` 只作为调试响应字段返回，客户端不能拿它绕过 BattleMgr 直接寻址 Worker。

### 41.1 构建规则不变

WSL：

```bash
./server/protocol/build_server_descriptor.sh
cd server
./scripts/linux/run_server.sh build
```

Windows 同步同一协议提交以后：

```powershell
./shared/protocol/build_unity_cs.ps1
```

确认 registry：

```text
1001 QueryCell
1002 RunAutoBattle
1003 StartInteractiveBattle
1004 SubmitBattleCommand
1005 SyncBattle
1006 StopInteractiveBattle
1007 ResumeInteractiveBattle
```

不手工改生成的 `navigation_registry.lua`。

### 41.2 `navigation_query.proto` 第三课最终累计版

前面的字段草图不足以直接落地。第三课真正修改协议时，应以**当前唯一源文件**为基础累计扩展，而不是新建 `battle.proto` 复制一份 `Envelope/WorldPosition`。下面给出第三课完成时建议的完整结构；已有字段号必须保持不变。

[局部修改后的最终累计内容]

```text
shared/protocol/navigation_query.proto
```

```proto
// 职责：定义 Unity 与 Skynet 的地图查询、自动战斗和第三课交互战斗 Runtime Message Contract。
// 边界：跨进程/跨语言协议唯一源；生成 Lua descriptor/registry 与 Unity C# 类型。
// 输入/输出：客户端意图 -> Server 权威查询/战斗响应、Event 和 Snapshot。
// 生命周期：随 Git/发布版本原子提交；已有字段号不得重排或复用。
// 不负责：不表达 Native GridPos/A* scratch，不保存 Service handle，不承载完整持久化角色数据。
syntax = "proto3";

package battle.navigation.v1;

message Envelope {
  uint32 protocol_version = 1; // 线协议兼容边界版本。
  uint32 command = 2;          // body 对应 RPC command_id。
  uint64 request_id = 3;       // 请求/响应关联 ID；Server 原样返回。
  bytes body = 4;              // command 对应 request/response Protobuf bytes。
}

message WorldPosition {
  sint64 x_mm = 1; // 世界 X，毫米。
  sint64 y_mm = 2; // 世界 Y，毫米。
  sint64 z_mm = 3; // 世界 Z，毫米。
}

message QueryCellRequest {
  uint32 map_id = 1;
  uint32 map_version = 2;
  WorldPosition position = 3;
}

message QueryCellResponse {
  enum ResultCode {
    RESULT_UNSPECIFIED = 0;
    OK = 1;
    MAP_NOT_FOUND = 2;
    MAP_VERSION_MISMATCH = 3;
    OUT_OF_BOUNDS = 4;
    NOT_WALKABLE = 5;
    BAD_REQUEST = 6;
    INTERNAL_ERROR = 7;
  }
  ResultCode result = 1;
  string message = 2;
  uint32 map_id = 3;
  uint32 map_version = 4;
  int32 grid_x = 5;
  int32 grid_z = 6;
  int32 cell_height_mm = 7;
  uint32 area = 8;
  uint32 clearance = 9;
}

// 第二课一次性自动战斗仍只允许客户端选择 Server 已发布场景。
message RunAutoBattleRequest {
  uint32 scenario_id = 1;
}

// 一条权威逻辑 Event。1..14 继承第二课，第三课只追加字段。
message BattleEvent {
  uint32 seq = 1;
  uint32 logic_ms = 2;
  string type = 3;
  uint32 unit_id = 4;
  uint32 target_id = 5;
  uint32 attacker_id = 6;
  uint32 killer_id = 7;
  uint32 damage = 8;
  uint32 target_hp = 9;
  uint32 speed_mm_per_sec = 10;
  string reason = 11;
  string result = 12;
  WorldPosition position = 13;
  repeated WorldPosition points = 14;

  // 第三课追加；已有字段号禁止改变。
  uint32 skill_id = 15;
  uint32 projectile_id = 16;
  uint32 area_effect_id = 17;
  uint32 buff_id = 18;
  uint32 stack_count = 19;
  uint32 expire_tick = 20;
  uint32 source_unit_id = 21;
  uint32 logic_tick = 22;
}

message BattleBuffSnapshot {
  uint32 buff_id = 1;
  uint32 source_unit_id = 2;
  uint32 stack_count = 3;
  uint32 expire_tick = 4;
}

message BattleUnitSnapshot {
  uint32 unit_id = 1;
  uint32 camp = 2;
  string movement_layer = 3; // GROUND/AIR；课程调试字段，正式产品可改稳定 enum。
  uint32 target_layer = 4;
  WorldPosition position = 5;
  uint32 hp = 6;
  uint32 max_hp = 7;
  uint32 effective_move_speed_mm_per_sec = 8;
  repeated BattleBuffSnapshot buffs = 9;
  uint32 last_accepted_command_seq = 10; // Server 已接受的最大 Player 命令号，恢复后用于消除丢失 Ack 歧义。
}

message BattleProjectileSnapshot {
  uint32 projectile_id = 1;
  string model = 2; // PRESENTATION/LOGIC；课程阶段保留可读调试值。
  uint32 skill_id = 3;
  uint32 source_unit_id = 4;
  uint32 target_unit_id = 5;
  WorldPosition position = 6;
}

message BattleAreaEffectSnapshot {
  uint32 area_effect_id = 1;
  uint32 skill_id = 2;
  uint32 owner_unit_id = 3;
  WorldPosition center_world = 4;
  string orientation = 5; // X_AXIS/Z_AXIS；本课固定两种。
  uint32 expire_tick = 6;
}

message BattleSnapshot {
  uint32 battle_id = 1;
  uint32 battle_version = 2;
  uint32 map_id = 3;
  uint32 map_version = 4;
  uint32 air_map_version = 5;
  uint32 skill_version = 6;
  sint64 seed = 7;
  uint32 logic_tick = 8;
  uint32 logic_ms = 9;
  uint32 last_event_seq = 10;
  bool finished = 11;
  string result = 12;
  repeated BattleUnitSnapshot units = 13;
  repeated BattleProjectileSnapshot projectiles = 14;
  repeated BattleAreaEffectSnapshot area_effects = 15;
}

message RunAutoBattleResponse {
  enum ResultCode {
    RESULT_UNSPECIFIED = 0;
    OK = 1;
    BAD_SCENARIO = 2;
    BUSY = 3;
    BATTLE_FAILED = 4;
    RESULT_TOO_LARGE = 5;
  }
  ResultCode result = 1;
  string message = 2;
  uint32 battle_id = 3;
  uint32 battle_version = 4;
  uint32 map_id = 5;
  uint32 map_version = 6;
  sint64 seed = 7;
  string battle_result = 8;
  uint32 end_logic_ms = 9;
  repeated BattleEvent events = 10;
  BattleSnapshot final_snapshot = 11;
}

// 一份正式跨语言 Replay Payload；文件层由 BRPL Header 保护。
// 它用于表现回放，不等同于 deterministic re-simulate 的完整输入。
message BattleReplay {
  uint32 replay_format_version = 1;
  uint32 battle_id = 2;
  uint32 battle_version = 3;
  uint32 map_id = 4;
  uint32 map_version = 5;
  uint32 air_map_version = 6;
  uint32 skill_version = 7;
  sint64 seed = 8;
  string battle_result = 9;
  uint32 end_logic_tick = 10;
  uint32 end_logic_ms = 11;
  repeated BattleEvent events = 12;
  BattleSnapshot final_snapshot = 13;
}

message MoveCommand {
  WorldPosition target_world = 1; // 只是意图；Server 重新做边界/寻路/高度校验。
}

message CastSkillCommand {
  uint32 skill_id = 1;
  uint32 target_unit_id = 2;
  WorldPosition target_world = 3; // FireWall 等位置型技能使用；无则保持默认。
  string orientation = 4;        // FireWall 本课只接受 X_AXIS/Z_AXIS。
}

message BattleCommand {
  uint32 unit_id = 1;
  uint32 command_seq = 2; // 当前 Player Unit 内严格递增。
  oneof action {
    MoveCommand move = 3;
    CastSkillCommand cast = 4;
  }
}

message StartInteractiveBattleRequest {
  uint32 scenario_id = 1; // 本课只允许 1001；客户端不上传 Snapshot。
}

message StartInteractiveBattleResponse {
  enum ResultCode {
    RESULT_UNSPECIFIED = 0;
    OK = 1;
    BAD_SCENARIO = 2;
    BUSY = 3;
    BATTLE_FAILED = 4;
  }
  ResultCode result = 1;
  string message = 2;
  uint32 battle_id = 3;
  uint32 worker_index = 4; // 仅课程诊断；Client 不应依赖此值做路由。
  BattleSnapshot snapshot = 5;
  string resume_token = 6; // Server 签发的当前 Battle 临时 bearer 凭据；只交给发起连接。
}

message ResumeInteractiveBattleRequest {
  uint32 battle_id = 1;
  string resume_token = 2; // 新连接必须持有 Start 返回的原始凭据。
}

message ResumeInteractiveBattleResponse {
  enum ResultCode {
    RESULT_UNSPECIFIED = 0;
    OK = 1;
    NOT_CONTROLLER = 2;
    WORKER_UNAVAILABLE = 3;
  }
  ResultCode result = 1;
  string message = 2;
  uint32 battle_id = 3;
  BattleSnapshot snapshot = 4; // 当前即时权威状态；其 last_event_seq 是恢复锚点。
  bool finished = 5;
}

message SubmitBattleCommandRequest {
  uint32 battle_id = 1;
  BattleCommand command = 2;
}

message SubmitBattleCommandResponse {
  enum ResultCode {
    RESULT_UNSPECIFIED = 0;
    OK = 1;
    BATTLE_NOT_FOUND = 2;
    NOT_CONTROLLER = 3;
    STALE_OR_DUPLICATE_COMMAND = 4;
    COMMAND_QUEUE_FULL = 5;
    BATTLE_FINISHED = 6;
    INVALID_COMMAND = 7;
    WORKER_UNAVAILABLE = 8;
  }
  ResultCode result = 1;
  string message = 2;
  uint32 command_seq = 3;
  uint32 apply_tick = 4;
}

message SyncBattleRequest {
  uint32 battle_id = 1;
  uint32 after_event_seq = 2; // Client 已完整应用的最后 seq；0 表示从头拉。
  bool want_snapshot = 3;     // 调试/主动校正时请求当前 Snapshot。
}

message SyncBattleResponse {
  enum ResultCode {
    RESULT_UNSPECIFIED = 0;
    OK = 1;
    BATTLE_NOT_FOUND = 2;
    NOT_CONTROLLER = 3;
    WORKER_UNAVAILABLE = 4;
  }
  ResultCode result = 1;
  string message = 2;
  uint32 battle_id = 3;
  uint32 logic_tick = 4;
  uint32 first_available_seq = 5;
  uint32 latest_event_seq = 6;
  bool event_gap = 7;
  BattleSnapshot snapshot = 8;
  repeated BattleEvent events = 9;
  bool finished = 10;
  string battle_result = 11;
}

message StopInteractiveBattleRequest {
  uint32 battle_id = 1;
}

message StopInteractiveBattleResponse {
  enum ResultCode {
    RESULT_UNSPECIFIED = 0;
    OK = 1;
    BATTLE_NOT_FOUND = 2;
    NOT_CONTROLLER = 3;
    WORKER_UNAVAILABLE = 4;
  }
  ResultCode result = 1;
  string message = 2;
  uint32 battle_id = 3;
  BattleSnapshot final_snapshot = 4;
}

// 保留第一课已有 NavigationService，不为了第三课移动既有 RPC。
service NavigationService {
  // command_id=1001
  rpc QueryCell(QueryCellRequest) returns (QueryCellResponse);
}

// 保留第二课已经出现的 BattleService，并在这里兼容追加第三课 RPC。
// 所有 command_id 由 FlyWow 构建生成器从 RPC 注释读取；业务代码不手工维护另一份表。
service BattleService {
  // command_id=1002
  rpc RunAutoBattle(RunAutoBattleRequest) returns (RunAutoBattleResponse);

  // command_id=1003
  rpc StartInteractiveBattle(StartInteractiveBattleRequest)
      returns (StartInteractiveBattleResponse);

  // command_id=1004
  rpc SubmitBattleCommand(SubmitBattleCommandRequest)
      returns (SubmitBattleCommandResponse);

  // command_id=1005
  rpc SyncBattle(SyncBattleRequest) returns (SyncBattleResponse);

  // command_id=1006
  rpc StopInteractiveBattle(StopInteractiveBattleRequest)
      returns (StopInteractiveBattleResponse);

  // command_id=1007
  rpc ResumeInteractiveBattle(ResumeInteractiveBattleRequest)
      returns (ResumeInteractiveBattleResponse);
}
```

为什么 Snapshot 内的 `movement_layer/model/orientation` 暂时仍是 string：本课重点是 Runtime 边界，不是把每一个调试维度都升级成长期公有协议 enum。真正准备对外发布/长期兼容时，应该把稳定集合改 enum，并新增字段而不是重解释旧字符串。文档要明确这属于当前课程协议的已知可演进点。

---


### 41.3 第二课 JSON Replay 到这里正式降级为 Debug Artifact

第二课的 `battle_replay.json` 有明确的阶段价值：当时 Battle Event 刚刚形成，JSON 可以直接打开检查 `seq / logic_ms / position / points`，非常适合验证“Server 自动战斗 -> Unity Replay”这条链是否成立。

第三课已经出现：

```text
BattleEvent
BattleSnapshot
Skill / Projectile / Buff / AreaEffect
在线增量同步
跨进程 Protobuf
Unity 强类型生成代码
```

如果此时正式 Replay 仍然单独维护一套 JSON 字段，系统会变成：

```text
Battle Core
  |
  +-- Online -> Protobuf BattleEvent / BattleSnapshot
  |
  +-- Replay -> 手工 JSON ReplayEvent / ReplayDocument
```

同一个逻辑事实有两套长期序列化合同，后续每增加：

```text
skill_id
projectile_id
area_effect_id
buff_id
logic_tick
Air Unit
Snapshot
```

都必须同时修改 Proto 和 JSON DTO/Writer，极易漂移。

因此第三课把边界收敛为：

```text
Battle Core
  |
  +-- 纯 Lua BattleEvent / BattleSnapshot
          |
          +-- Online Adapter -> Protobuf -> FlyWow Gateway
          |
          +-- Replay Adapter -> Protobuf -> BRPL file
```

这里要明确三个结论：

1. `BattleEvent` / `BattleSnapshot` 才是业务事实；JSON、Protobuf、文件 Header 都只是 Adapter。
2. Native C++ Navigation 不知道 Replay 使用什么序列化格式，因此不引入 JSON/Protobuf C++ 依赖。
3. JSON 不删除历史价值，但从第三课起只保留为**可选人工调试导出**，不再作为正式 Replay Runtime Contract。

这也是第二课到第三课一次合理的工程演进，而不是否定第二课的选择。

---

### 41.4 `BattleReplay`：复用同一份 BattleEvent / Snapshot Proto 合同

在 41.2 的唯一协议源中，`RunAutoBattleResponse` 后、`MoveCommand` 前增加：

```proto
// 一份已经结算完成、可跨语言长期读取的权威 Replay Payload。
// 它只用于表现回放，不是“重新模拟输入”；重新模拟仍需要 initial snapshot + recorded commands + versions + seed。
message BattleReplay {
  uint32 replay_format_version = 1; // 当前固定为 1；与 BRPL 文件 Header version 双重校验。

  uint32 battle_id = 2;
  uint32 battle_version = 3;
  uint32 map_id = 4;
  uint32 map_version = 5;
  uint32 air_map_version = 6;
  uint32 skill_version = 7;
  sint64 seed = 8;

  string battle_result = 9;
  uint32 end_logic_tick = 10;
  uint32 end_logic_ms = 11;

  repeated BattleEvent events = 12;      // 顺序就是权威 seq 顺序，禁止重新排序。
  BattleSnapshot final_snapshot = 13;    // 回放结束后的权威状态，便于校验和调试。
}
```

为什么不为 Replay 再复制 `ReplayEvent`：

```text
BattleEvent 已经是跨端正式合同
BattleSnapshot 已经是跨端正式合同
```

Replay 只需要把它们组合起来即可。

为什么不把 `recorded_commands` 也塞进 `BattleReplay`：本节定义的是**表现型战报**，用途是 Unity 重放已经权威结算完成的结果；确定性重模拟测试仍使用：

```text
initial snapshot
+ recorded command stream
+ versions
+ seed
```

两种用途不能混成一个“大而全战报文件”。如果以后需要审计型重模拟资产，再新增独立 `BattleSimulationInput` 合同，而不是偷偷改变 `BattleReplay` 语义。

完成 `.proto` 修改后，41.1 的生成流程仍然是唯一入口：

```bash
./server/protocol/build_server_descriptor.sh
cd server
./scripts/linux/run_server.sh build
```

Windows 同步同一提交后：

```powershell
./shared/protocol/build_unity_cs.ps1
```

生成结果必须同时出现：

```text
BattleReplay Lua descriptor type
BattleReplay C# generated type
```

不手写另一套 C# Replay DTO。

---

### 41.5 为什么文件不直接裸写 Protobuf bytes：增加一个极薄的 BRPL V1 Header

> 可选扩展：Lesson 3 要求完整模拟与 Replay，但 BRPL 自定义文件 Header 和 Protobuf 文件封装不是主课前置条件。先使用第二课已有 Replay 链路完成主课，再单独验证该文件格式。

Protobuf 解决：

```text
BattleReplay 字段怎样编码
旧 Reader 怎样跳过未知字段
跨语言怎样读取同一消息
```

它不解决磁盘文件层的这些问题：

```text
这个文件是不是 Battle Replay？
文件容器版本是什么？
payload 声明多大？
文件是不是被截断？
payload 是否损坏？
```

因此第三课定义一个非常薄的文件容器：

```text
BRPL V1
```

固定 Little-Endian Header：

| Offset | Size | Field | 说明 |
|---:|---:|---|---|
| 0 | 4 | magic | ASCII `BRPL` |
| 4 | 2 | format_version | `1` |
| 6 | 2 | header_size | `16` |
| 8 | 4 | payload_size | Protobuf payload byte 数 |
| 12 | 4 | payload_crc32 | CRC-32/ISO-HDLC |
| 16 | N | payload | `battle.navigation.v1.BattleReplay` bytes |

即：

```text
+------------------------+
| "BRPL"                 | 4
+------------------------+
| version = 1            | 2
+------------------------+
| header_size = 16       | 2
+------------------------+
| payload_size           | 4
+------------------------+
| payload_crc32          | 4
+------------------------+
| BattleReplay protobuf  | N
+------------------------+
```

这里不再重新教学 CRC 算法理论。第一课 BMAP 已经完整学习过：

```text
magic
version
size
endian
CRC
truncated
```

第三课只是把同一个资产工程纪律应用到 Replay 文件。

BRPL 的 Header version 与 Proto 里的 `replay_format_version` 不是重复浪费：

```text
Header version
-> 文件容器怎样读

replay_format_version
-> payload 的 Replay 业务语义版本
```

当前二者都为 1，但以后可以独立演进。

课程文件命名固定：

```text
server/tmp/battle_70001.breplay
```

扩展名只是人类约定；真正识别依据是文件内 `BRPL` magic。

为了避免离线结果无界占用内存/磁盘，本课给单文件一个保守保护上限：

```text
MAX_REPLAY_PAYLOAD_BYTES = 16 MiB
```

这不是商业系统通用数字，只是当前课程的显式资源边界。超过以后应改成分页战报、对象存储或分段下载，而不是继续扩大单个 Gateway frame。

---

### 41.6 `battle_replay_file.lua`：Lua 只复用项目已经存在的 lua-protobuf

第二课 `replay_writer.lua` 的手写 JSON 从这里退出正式链路。保留它可以用于人工 Debug，但 `batch_runner` 不再依赖它作为最终 Replay 产物。

[新建文件]

```text
server/lualib/battle/battle_replay_file.lua
```

学习导航：

必须精读：

```text
start() 为什么显式加载同一份 descriptor
make_replay() 为什么只做 Battle result -> Proto record 映射
write() 为什么先 encode 再写 .tmp
read() 为什么先校验 Header/size/CRC 再 pb.decode
```

可以略读：CRC32 的 8-bit 循环实现；第一课已经理解算法目的。

输入、输出和失败：

```text
start(descriptor_path)
  输入：已经由构建流程生成的 FileDescriptorSet
  输出：true
  失败：文件 I/O / descriptor 损坏 -> error，阻止 Replay Writer 使用

write(path, result)
  输入：battle_core.finish() 返回的纯 Lua result
  输出：true 或 nil,error
  I/O：有；只允许在 simulate 已经完成后执行
  yield：无 Skynet yield，但有同步磁盘 I/O

read(path)
  输入：BRPL 文件
  输出：BattleReplay 普通 Lua table 或 nil,error
  失败：magic/version/size/CRC/Proto 任一非法都明确拒绝
```

完整代码：

```lua
-- 职责：把已完成 Battle result 编码成 BRPL V1 + BattleReplay Protobuf，并支持回读校验。
-- 边界：Server Replay Artifact Adapter；只在 Battle Core 之外执行文件/Proto I/O。
-- 输入/输出：battle_core.finish() result <-> battle.navigation.v1.BattleReplay 文件。
-- 生命周期：每个 Lua State start 一次 descriptor；每次 write/read 独立打开并关闭文件。
-- 不负责：不推进 Battle、不修改 Event、不处理 Gateway、不向 Native C++ 引入序列化依赖。
local pb = require "pb"

local M = {}

local MAGIC = "BRPL"                       -- 文件容器 Magic，固定 4 byte ASCII。
local FORMAT_VERSION = 1                   -- BRPL Header 版本。
local HEADER_SIZE = 16                     -- <c4I2I2I4I4 的固定字节数。
local REPLAY_TYPE = "battle.navigation.v1.BattleReplay"
local MAX_REPLAY_PAYLOAD_BYTES = 16 * 1024 * 1024

local started = false                      -- 当前 Lua State 是否已加载 descriptor。
local loaded_descriptor_path = nil         -- 只用于拒绝同一 State 静默切换协议源。

-- 读取整个小型构建资产；返回新 Lua string，文件句柄在本函数关闭。
-- path 必须是已发布 descriptor 路径；函数执行同步文件 I/O，不 yield。
local function read_all(path)
    local file, open_error = io.open(path, "rb")
    if file == nil then return nil, open_error end
    local bytes = file:read("*a")
    local closed, close_error = file:close()
    if bytes == nil then return nil, "cannot read file: " .. tostring(path) end
    if closed == nil then return nil, close_error end
    return bytes
end

-- 计算 reflected CRC-32/ISO-HDLC；与第一课 BMAP 使用相同参数。
-- bytes 是当前调用拥有的 Lua string；返回 0..0xffffffff 整数；O(n)，不 I/O、不 yield。
local function crc32(bytes)
    local crc = 0xffffffff
    for index = 1, #bytes do
        crc = (crc ~ string.byte(bytes, index)) & 0xffffffff
        for _bit = 1, 8 do
            if (crc & 1) ~= 0 then
                crc = ((crc >> 1) ~ 0xedb88320) & 0xffffffff
            else
                crc = (crc >> 1) & 0xffffffff
            end
        end
    end
    return (~crc) & 0xffffffff
end

-- 确保当前模块已绑定唯一 descriptor；防止 Batch Writer 忘记初始化 Proto 类型。
-- 无参数/返回；失败抛 error；不 I/O、不 yield。
local function require_started()
    assert(started, "battle_replay_file.start(descriptor_path) must run first")
end

-- 在当前 Lua State 加载第三课唯一 Proto descriptor。
-- path 由调用方显式注入；成功后只读复用；重复使用相同 path 幂等成功。
-- 本函数执行一次同步文件 I/O 和 pb.load，不执行 Skynet call/yield。
function M.start(path)
    assert(type(path) == "string" and path ~= "", "descriptor path is required")
    if started then
        assert(path == loaded_descriptor_path,
               "BattleReplay descriptor cannot change inside one Lua State")
        return true
    end

    local bytes, read_error = read_all(path)
    assert(bytes ~= nil, "cannot read Replay descriptor: " .. tostring(read_error))
    assert(pb.load(bytes), "cannot load Replay protobuf descriptor")

    loaded_descriptor_path = path
    started = true
    return true
end

-- 把 battle_core.finish() 的纯 Lua result 映射成 BattleReplay Proto record。
-- result/events/final_snapshot 只读借用；返回新 table，不修改输入，不 I/O、不 yield。
function M.make_replay(result)
    require_started()
    assert(type(result) == "table", "battle result is required")
    assert(type(result.events) == "table", "battle result.events is required")
    assert(type(result.final_snapshot) == "table", "battle final_snapshot is required")

    return {
        replay_format_version = FORMAT_VERSION,
        battle_id = assert(result.battle_id),
        battle_version = assert(result.battle_version),
        map_id = assert(result.map_id),
        map_version = assert(result.map_version),
        air_map_version = assert(result.air_map_version),
        skill_version = assert(result.skill_version),
        seed = assert(result.seed),
        battle_result = assert(result.result),
        end_logic_tick = assert(result.end_logic_tick),
        end_logic_ms = assert(result.end_logic_ms),
        events = result.events,
        final_snapshot = result.final_snapshot,
    }
end

-- 把 Proto record 编码成受 BRPL Header 保护的完整文件 bytes。
-- replay 是 make_replay() 或 read() 同结构 table；返回新 Lua string。
-- 超过课程文件预算时返回 nil,error；不执行文件 I/O、不 yield。
function M.encode_file(replay)
    require_started()
    assert(type(replay) == "table", "BattleReplay record is required")
    assert(replay.replay_format_version == FORMAT_VERSION,
           "unsupported BattleReplay payload version")

    local payload = assert(pb.encode(REPLAY_TYPE, replay))
    if #payload > MAX_REPLAY_PAYLOAD_BYTES then
        return nil, "BattleReplay payload exceeds 16 MiB course limit"
    end

    local header = string.pack(
        "<c4I2I2I4I4",
        MAGIC,
        FORMAT_VERSION,
        HEADER_SIZE,
        #payload,
        crc32(payload))
    assert(#header == HEADER_SIZE, "BRPL header size invariant failed")
    return header .. payload
end

-- 原子发布一份 Replay 文件：完整编码后先写 path.tmp，再 rename 到正式路径。
-- path 是 Server Debug/Artifact 输出路径；result 是已结束 Battle 的纯数据结果。
-- 成功返回 true；I/O/rename 失败返回 nil,error；不会留下半写正式文件。
function M.write(path, result)
    assert(type(path) == "string" and path ~= "", "Replay output path is required")
    local replay = M.make_replay(result)
    local bytes, encode_error = M.encode_file(replay)
    if bytes == nil then return nil, encode_error end

    local temporary_path = path .. ".tmp"
    os.remove(temporary_path)
    local file, open_error = io.open(temporary_path, "wb")
    if file == nil then return nil, open_error end

    local written, write_error = file:write(bytes)
    if written == nil then
        file:close()
        os.remove(temporary_path)
        return nil, write_error
    end
    local flushed, flush_error = file:flush()
    if flushed == nil then
        file:close()
        os.remove(temporary_path)
        return nil, flush_error
    end
    local closed, close_error = file:close()
    if closed == nil then
        os.remove(temporary_path)
        return nil, close_error
    end

    local renamed, rename_error = os.rename(temporary_path, path)
    if renamed == nil then
        os.remove(temporary_path)
        return nil, rename_error
    end
    return true
end

-- 校验完整 BRPL bytes 并解析 BattleReplay；所有长度先验证，再进入 Proto decoder。
-- bytes 由调用方拥有；返回新 Lua table 或 nil,error；不 I/O、不 yield。
function M.decode_file(bytes)
    require_started()
    if type(bytes) ~= "string" or #bytes < HEADER_SIZE then
        return nil, "BRPL_TRUNCATED_HEADER"
    end

    local magic, version, header_size, payload_size, expected_crc, next_index =
        string.unpack("<c4I2I2I4I4", bytes)
    if magic ~= MAGIC then return nil, "BRPL_BAD_MAGIC" end
    if version ~= FORMAT_VERSION then return nil, "BRPL_UNSUPPORTED_VERSION" end
    if header_size ~= HEADER_SIZE or next_index ~= HEADER_SIZE + 1 then
        return nil, "BRPL_BAD_HEADER_SIZE"
    end
    if payload_size > MAX_REPLAY_PAYLOAD_BYTES then
        return nil, "BRPL_PAYLOAD_LIMIT"
    end
    if #bytes ~= HEADER_SIZE + payload_size then
        return nil, "BRPL_PAYLOAD_SIZE_MISMATCH"
    end

    local payload = string.sub(bytes, HEADER_SIZE + 1)
    if crc32(payload) ~= expected_crc then
        return nil, "BRPL_PAYLOAD_CRC_MISMATCH"
    end

    local decode_ok, replay = pcall(pb.decode, REPLAY_TYPE, payload)
    if not decode_ok or replay == nil then
        return nil, "BRPL_PROTO_DECODE_FAILED"
    end
    if replay.replay_format_version ~= FORMAT_VERSION then
        return nil, "BRPL_REPLAY_VERSION_MISMATCH"
    end
    return replay
end

-- 从磁盘读取并验证一份 Replay；文件只在本调用存活。
-- 成功返回 BattleReplay table；I/O/格式损坏返回 nil,error；同步 I/O，不 yield。
function M.read(path)
    local bytes, read_error = read_all(path)
    if bytes == nil then return nil, read_error end
    return M.decode_file(bytes)
end

return M
```

这里故意没有：

```text
rapidjson
cjson
nlohmann/json
protobuf-c++
```

Server Lua 只复用项目已经因 FlyWow Gateway 固定存在的：

```text
lua-protobuf
```

Native C++ 仍然完全不知道 Replay serialization。

---

### 41.7 `config/replay.lua`：协议路径和输出预算显式注入

不要在 `battle_replay_file.lua` 里隐藏开发机路径。

[新建文件]

```text
server/config/replay.lua
```

```lua
-- 职责：声明第三课离线 BattleReplay Artifact 的 descriptor、输出目录和文件预算。
-- 边界：Server Runtime/Batch Debug Config；由 batch_runner 只读加载。
-- 输入/输出：无运行时输入 -> Replay 文件配置 table。
-- 生命周期：Batch Service 启动时读取一次；运行期不修改。
-- 不负责：不加载 Proto、不创建目录、不执行 Battle、不配置 Gateway frame。
return {
    descriptor_path = "../shared/protocol/generated/server/navigation_query.pb",
    output_directory = "tmp",
    max_payload_bytes = 16 * 1024 * 1024,
}
```

`max_payload_bytes` 目前与模块保护值相同。课程阶段保留两边是为了让配置意图可见；真正抽取框架时，应把数值作为 `start(options)` 参数传入模块，避免常量重复。第三课不为了这一点提前做配置框架抽象。

---

### 41.8 修改 `batch_runner.lua`：正式产物从 `.json` 切成 `.breplay`

[局部修改]

```text
server/service/battle/batch_runner.lua
```

文件顶部增加：

```lua
local replay_config = require "config.replay"
local replay_file = require "battle.battle_replay_file"
```

在 `skynet.start(function()` 内、第一次运行 Battle 前初始化 descriptor：

```lua
replay_file.start(replay_config.descriptor_path)
```

第三课 deterministic comparison 成功以后，不再把正式 Replay 写成：

```text
tmp/battle_replay.json
```

改为：

```lua
local replay_path = string.format(
    "%s/battle_%d.breplay",
    replay_config.output_directory,
    first.battle_id)
local replay_ok, replay_error = replay_file.write(replay_path, first)
assert(replay_ok, replay_error)

-- 写完立刻回读一次，证明刚发布的 artifact 不是只“写成功”而是能够完整解码。
local verified, verify_error = replay_file.read(replay_path)
assert(verified ~= nil, verify_error)
assert(verified.battle_id == first.battle_id)
assert(verified.battle_version == first.battle_version)
assert(verified.map_id == first.map_id)
assert(verified.map_version == first.map_version)
assert(verified.air_map_version == first.air_map_version)
assert(verified.skill_version == first.skill_version)
assert(verified.seed == first.seed)
assert(#verified.events == #first.events)
assert(verified.final_snapshot.last_event_seq == first.final_snapshot.last_event_seq)

skynet.error(
    "BATTLE_REPLAY_PROTO_OK path=", replay_path,
    " events=", #verified.events)
```

为什么“写完立即回读”值得保留：

```text
Battle determinism test
```

只能证明 Core 结果稳定；它不能证明：

```text
Proto descriptor 正确
BRPL Header 正确
文件长度正确
CRC 正确
Unity 将来拿到的是可读取资产
```

回读把序列化/文件层也纳入当前 Stage 的证据链。

第二课的 `replay_writer.lua` 可以继续留在仓库供对照，不要求删除历史教学代码。但第三课正式验收脚本不再把：

```text
BATTLE_REPLAY_OK path=tmp/battle_replay.json
```

作为完成证据，而改成：

```text
BATTLE_REPLAY_PROTO_OK path=tmp/battle_<id>.breplay
```

---

### 41.9 Unity `BattleReplayFile.cs`：先验证 BRPL，再交给 Google.Protobuf

Unity 已经因为跨端协议生成而拥有：

```text
Google.Protobuf
Battle.Navigation.V1.BattleReplay
```

因此不要再引入 JSON 包，也不要在客户端复制一套 Replay DTO。

[新建文件]

```text
unity/BattleNavigation/Assets/BattleNavigation/Scripts/Protocol/BattleReplayFile.cs
```

学习导航：精读 Header/size/CRC 验证顺序，以及为什么只有完整合法 payload 才调用 `BattleReplay.Parser.ParseFrom()`。

```csharp
// 职责：读取第三课 BRPL V1 文件并解析唯一 BattleReplay Protobuf Payload。
// 边界：Unity Client Runtime Replay File Adapter；不执行战斗、不修改 Server Event。
// 输入/输出：BRPL bytes/path -> Battle.Navigation.V1.BattleReplay。
// 生命周期：静态无状态工具；每次调用拥有自己的 byte[] 和解析结果。
// 不负责：不联网、不做寻路/伤害、不兼容第二课 JSON Replay。
using System;
using System.IO;
using Battle.Navigation.V1;

namespace BattleNavigation.Client
{
    /// <summary>第三课正式 Replay 文件容器 Reader。</summary>
    public static class BattleReplayFile
    {
        private const ushort FormatVersion = 1;          // BRPL Header 版本。
        private const ushort HeaderSize = 16;            // 固定 Little-Endian Header 长度。
        private const uint MaxPayloadBytes = 16u * 1024u * 1024u;

        /// <summary>同步读取一个本地 BRPL 文件；失败抛 I/O 或格式异常。</summary>
        /// <param name="path">当前平台可直接读取的 Replay 文件路径。</param>
        /// <returns>新解析的权威 BattleReplay；调用方只读使用。</returns>
        /// <remarks>执行同步文件 I/O；不要放在 Unity 每帧 Update 中调用。</remarks>
        public static BattleReplay ReadFromPath(string path)
        {
            if (string.IsNullOrWhiteSpace(path))
                throw new ArgumentException("Replay path is required", nameof(path));
            return Parse(File.ReadAllBytes(path));
        }

        /// <summary>验证完整 BRPL bytes 并解析 BattleReplay。</summary>
        /// <param name="file">调用方拥有的完整文件 bytes；本函数不会修改。</param>
        /// <returns>新解析的 Protobuf 对象。</returns>
        public static BattleReplay Parse(byte[] file)
        {
            if (file == null) throw new ArgumentNullException(nameof(file));
            if (file.Length < HeaderSize)
                throw new InvalidDataException("BRPL_TRUNCATED_HEADER");
            if (file[0] != (byte)'B' || file[1] != (byte)'R' ||
                file[2] != (byte)'P' || file[3] != (byte)'L')
                throw new InvalidDataException("BRPL_BAD_MAGIC");

            var version = ReadUInt16LittleEndian(file, 4);
            var headerSize = ReadUInt16LittleEndian(file, 6);
            var payloadSize = ReadUInt32LittleEndian(file, 8);
            var expectedCrc = ReadUInt32LittleEndian(file, 12);

            if (version != FormatVersion)
                throw new InvalidDataException("BRPL_UNSUPPORTED_VERSION");
            if (headerSize != HeaderSize)
                throw new InvalidDataException("BRPL_BAD_HEADER_SIZE");
            if (payloadSize > MaxPayloadBytes)
                throw new InvalidDataException("BRPL_PAYLOAD_LIMIT");
            if ((ulong)HeaderSize + payloadSize != (ulong)file.Length)
                throw new InvalidDataException("BRPL_PAYLOAD_SIZE_MISMATCH");

            var payload = new byte[payloadSize];
            Buffer.BlockCopy(file, HeaderSize, payload, 0, checked((int)payloadSize));
            if (ComputeCrc32(payload) != expectedCrc)
                throw new InvalidDataException("BRPL_PAYLOAD_CRC_MISMATCH");

            var replay = BattleReplay.Parser.ParseFrom(payload);
            if (replay.ReplayFormatVersion != FormatVersion)
                throw new InvalidDataException("BRPL_REPLAY_VERSION_MISMATCH");
            return replay;
        }

        /// <summary>按 Little-Endian 读取 uint16；offset 必须已由调用方保证范围合法。</summary>
        private static ushort ReadUInt16LittleEndian(byte[] bytes, int offset)
        {
            return (ushort)(bytes[offset] | (bytes[offset + 1] << 8));
        }

        /// <summary>按 Little-Endian 读取 uint32；offset 必须已由调用方保证范围合法。</summary>
        private static uint ReadUInt32LittleEndian(byte[] bytes, int offset)
        {
            return (uint)(bytes[offset] |
                          (bytes[offset + 1] << 8) |
                          (bytes[offset + 2] << 16) |
                          (bytes[offset + 3] << 24));
        }

        /// <summary>计算 reflected CRC-32/ISO-HDLC；参数与 Server Writer 一致。</summary>
        private static uint ComputeCrc32(byte[] bytes)
        {
            uint crc = 0xffffffffu;
            for (var index = 0; index < bytes.Length; ++index)
            {
                crc ^= bytes[index];
                for (var bit = 0; bit < 8; ++bit)
                    crc = (crc & 1u) != 0
                        ? 0xedb88320u ^ (crc >> 1)
                        : crc >> 1;
            }
            return crc ^ 0xffffffffu;
        }
    }
}
```

这里 Unity 和 Lua 的 CRC 实现是一个**16 MiB 上限的离线/Debug Replay 文件校验**，不是 Battle Tick 热路径。课程不为它提前抽公共跨语言 CRC 框架；真正出现第二个 Runtime binary artifact consumer 时再考虑抽取。

---

### 41.10 `BattleReplayPlayer` 从 JSON DTO 切到生成的 Proto Event

第二课播放器曾经定义：

```text
ReplayDocument
ReplayEvent
ReplayPosition
```

并通过：

```text
JsonUtility.FromJson<ReplayDocument>()
```

加载离线 Replay。

第三课完成 41.4~41.9 后，这些类型已经与生成的：

```text
BattleReplay
BattleEvent
WorldPosition
```

重复，因此正式路径应删除 JSON DTO 依赖。

[局部修改]

```text
unity/BattleNavigation/Assets/BattleNavigation/client/BattleReplayPlayer.cs
```

核心改法不是重写表现逻辑，而是把“输入 DTO”换成生成的 Proto：

```csharp
using Battle.Navigation.V1;
```

播放器保存：

```csharp
private BattleReplay replay;
```

正式离线入口：

```csharp
/// <summary>从一份已经通过 BRPL/Proto 校验的权威 Replay 开始纯表现回放。</summary>
/// <param name="document">调用方拥有的 BattleReplay；播放器只读事件顺序。</param>
/// <exception cref="InvalidOperationException">seq/logic_ms/结束时间不合法。</exception>
public void Play(BattleReplay document)
{
    if (document == null)
        throw new ArgumentNullException(nameof(document));
    if (document.Events.Count == 0 || document.Events[0].Seq != 1)
        throw new InvalidOperationException("Replay event seq must start at 1");

    for (var index = 0; index < document.Events.Count; ++index)
    {
        var current = document.Events[index];
        if (current.LogicMs > document.EndLogicMs ||
            (index > 0 &&
             (current.Seq != document.Events[index - 1].Seq + 1 ||
              current.LogicMs < document.Events[index - 1].LogicMs)))
            throw new InvalidOperationException("Replay event order is invalid");
    }

    foreach (var unit in units.Values) Destroy(unit);
    units.Clear();
    moves.Clear();
    replay = document;
    nextEvent = 0;
    logicMs = 0f;
}
```

原来：

```csharp
private void Apply(ReplayEvent value)
```

改为：

```csharp
private void Apply(BattleEvent value)
```

字段访问从 JSON DTO 的 snake_case：

```text
value.unit_id
value.logic_ms
value.speed_mm_per_sec
```

改为生成 C# 类型：

```text
value.UnitId
value.LogicMs
value.SpeedMmPerSec
```

`WorldPosition` 也直接使用生成类型：

```csharp
/// <summary>把 Server 毫米世界坐标转换成 Unity 世界米。</summary>
private static Vector3 ToUnity(WorldPosition value)
{
    return new Vector3(
        value.XMm / 1000f,
        value.YMm / 1000f,
        value.ZMm / 1000f);
}
```

离线 Debug Loader 可以非常薄：

```csharp
// 职责：在 Unity Editor/PC 验收时从本地 BRPL 文件启动已有 BattleReplayPlayer。
// 边界：Unity Debug Presentation Entry；文件解析交给 BattleReplayFile。
// 输入/输出：本地 .breplay path -> BattleReplayPlayer.Play。
// 生命周期：Start 执行一次；不保留文件句柄。
// 不负责：不联网、不计算战斗、不在 Update 重复读文件。
using System;
using System.IO;
using UnityEngine;

namespace BattleNavigation.Client
{
    public sealed class BattleReplayFilePlayer : MonoBehaviour
    {
        [SerializeField] private string replayPath = ""; // Inspector 显式配置；不硬编码开发机绝对路径。
        [SerializeField] private BattleReplayPlayer replayPlayer;

        /// <summary>Play Mode 启动时读取一次 BRPL；失败明确写 Unity Console。</summary>
        private void Start()
        {
            if (replayPlayer == null)
                throw new InvalidOperationException("BattleReplayPlayer is not assigned");
            if (string.IsNullOrWhiteSpace(replayPath))
                throw new InvalidOperationException("Replay path is not assigned");

            try
            {
                var replay = BattleReplayFile.ReadFromPath(Path.GetFullPath(replayPath));
                replayPlayer.Play(replay);
                Debug.Log("BATTLE_REPLAY_PROTO_LOADED events=" + replay.Events.Count);
            }
            catch (Exception exception)
            {
                Debug.LogException(exception);
            }
        }
    }
}
```

课程验收可以把：

```text
server/tmp/battle_70001.breplay
```

复制到一个本机临时/测试目录，再通过 Inspector 显式指定。不要把 WSL 或 Windows 绝对路径写进仓库 Runtime 配置。

第二课 `BattleReplayRequester` 的在线 `RunAutoBattleResponse` 不需要先落盘再播放。它可以继续直接消费 `response.Events`，或者构造一个只用于播放器输入的 `BattleReplay`：

```csharp
var replay = new BattleReplay
{
    ReplayFormatVersion = 1,
    BattleId = response.BattleId,
    BattleVersion = response.BattleVersion,
    MapId = response.MapId,
    MapVersion = response.MapVersion,
    Seed = response.Seed,
    BattleResult = response.BattleResult,
    EndLogicMs = response.EndLogicMs,
    FinalSnapshot = response.FinalSnapshot,
};
replay.Events.Add(response.Events);
replayPlayer.Play(replay);
```

这样：

```text
文件 Replay
网络 RunAutoBattle
```

最终都投影到同一个生成的 `BattleReplay/BattleEvent` 模型，不再维护 JSON DTO。

---

### 41.11 网络传输边界：Protobuf 并不意味着把整场大 Replay 塞进一个 Gateway Frame

用户真正关心的“JSON 对网络不友好”在第三课要拆成两个问题：

```text
序列化格式
传输策略
```

第三课现在统一：

```text
在线 Event/Snapshot -> Protobuf
离线 Replay       -> Protobuf
```

解决了格式重复、字符串字段冗余、跨语言第三方 JSON 依赖问题。

但完整 Replay 如果未来达到数 MB，仍然不能写成：

```text
一个 FlyWow uint16 frame
-> 塞完整 BattleReplay
```

当前 Gateway framing 上限仍是：

```text
0xffff bytes
```

因此第三课保留：

```text
RunAutoBattleResponse
```

只服务于当前有界小场景；超过响应预算继续返回：

```text
RESULT_TOO_LARGE
```

正式大规模战报通常会演进成：

```text
Battle 完成
-> 生成 BRPL / Replay Asset
-> 返回 replay_id / version / hash
-> Client 分段/对象存储/CDN/专用下载协议获取
```

或：

```text
Chunked BattleReplay
```

这属于后续网络/战报基础设施专题，不在第三课继续扩张。

所以第三课的结论是：

> Protobuf 统一的是正式数据合同；BRPL 解决离线文件完整性；大 Replay 的网络传输仍然必须单独做有界传输设计。



## 42. `battle_dispatch.lua` 扩展

第三课 `battle_dispatch` 继续只做 RPC Adapter。

它持有：

```text
query_service handle
battle_mgr handle
```

不持有：

```text
Battle Runtime
NavigationContext
技能状态
客户端 fd
```

Start：

```text
payload.connection_id
+ scenario_id
-> BattleMgr.create_online
```

Command：

```text
payload.connection_id
+ battle_id
+ command
-> BattleMgr.submit_command
```

Sync / Stop 同理。

`connection_id` 由 Gateway 提供，不从 Protobuf request 信任客户端上传。

这是一个重要边界：

```text
客户端不能伪造另一个 connection_id
```

### 42.1 错误映射

Worker 内部错误码映射成稳定 Proto enum：

```text
BATTLE_NOT_FOUND
NOT_CONTROLLER
STALE_OR_DUPLICATE_COMMAND
COMMAND_QUEUE_FULL
BATTLE_FINISHED
INVALID_COMMAND
WORKER_UNAVAILABLE -> BATTLE_FAILED / REMOTE_UNAVAILABLE（按现有边界）
```

不要让客户端按 Lua traceback 字符串分支。

### 42.2 `battle_dispatch.lua` 第三课完整累计版

`battle_dispatch` 是非常重要的边界：它把 **FlyWow Gateway 的 transport identity** 转成 **BattleMgr 的业务 request**，同时把内部错误收敛成稳定 Proto ResultCode。它不能拥有 Battle state。

[完整替换]

```text
server/service/battle/battle_dispatch.lua
```

```lua
-- 职责：把 Battle Process 的 Gateway RPC 分发到 Query/BattleMgr，并映射稳定协议结果。
-- 边界：Server Runtime RPC Adapter Service；不拥有 fd、Protobuf codec 或 Battle mutable state。
-- 输入/输出：FlyWow gateway_dispatch payload -> {ok=true,response=<Proto table>} / handler error。
-- 生命周期：battle_main 注入 query_service/battle_mgr 后长驻并注册为 cluster 入口。
-- 不负责：不执行 AI/A*/技能、不信任客户端 connection_id、不保存 NavigationContext。
local cluster = require "skynet.cluster"
local skynet = require "skynet"
local process = require "config.process_battle"

local query_service = nil
local battle_mgr = nil

local AUTO_RESULT = {
    OK = 1,
    BAD_SCENARIO = 2,
    BUSY = 3,
    BATTLE_FAILED = 4,
    RESULT_TOO_LARGE = 5,
}

local START_RESULT = {
    OK = 1,
    BAD_SCENARIO = 2,
    BUSY = 3,
    BATTLE_FAILED = 4,
}

local COMMAND_RESULT = {
    OK = 1,
    BATTLE_NOT_FOUND = 2,
    NOT_CONTROLLER = 3,
    STALE_OR_DUPLICATE_COMMAND = 4,
    COMMAND_QUEUE_FULL = 5,
    BATTLE_FINISHED = 6,
    INVALID_COMMAND = 7,
    WORKER_UNAVAILABLE = 8,
}

local SYNC_RESULT = {
    OK = 1,
    BATTLE_NOT_FOUND = 2,
    NOT_CONTROLLER = 3,
    WORKER_UNAVAILABLE = 4,
}

local STOP_RESULT = {
    OK = 1,
    BATTLE_NOT_FOUND = 2,
    NOT_CONTROLLER = 3,
    WORKER_UNAVAILABLE = 4,
}

local RESUME_RESULT = {
    OK = 1,
    NOT_CONTROLLER = 2,
    WORKER_UNAVAILABLE = 3,
}

-- 启动时显式注入本进程 Service handle；重复配置是 composition root bug。
local function configure(handles)
    assert(query_service == nil and battle_mgr == nil,
           "battle_dispatch already configured")
    assert(type(handles) == "table" and
           type(handles.query_service) == "number" and
           type(handles.battle_mgr) == "number",
           "battle_dispatch handles are invalid")
    query_service = handles.query_service
    battle_mgr = handles.battle_mgr
    return true
end

-- 把 Core/Worker Snapshot record 转成协议 field 名；全部是新 table，不能泄露 Runtime 引用。
local function proto_position(value)
    if value == nil then return nil end
    return { x_mm = value.x_mm, y_mm = value.y_mm, z_mm = value.z_mm }
end

local function proto_snapshot(value)
    if value == nil then return nil end
    local units = {}
    for index, unit in ipairs(value.units or {}) do
        local buffs = {}
        for buff_index, buff in ipairs(unit.buffs or {}) do
            buffs[buff_index] = {
                buff_id = buff.buff_id,
                source_unit_id = buff.source_unit_id or 0,
                stack_count = buff.stack_count,
                expire_tick = buff.expire_tick,
            }
        end
        units[index] = {
            unit_id = unit.id,
            camp = unit.camp,
            movement_layer = unit.movement_layer,
            target_layer = unit.target_layer,
            position = proto_position(unit.position),
            hp = unit.hp,
            max_hp = unit.max_hp,
            effective_move_speed_mm_per_sec = unit.effective_move_speed_mm_per_sec,
            buffs = buffs,
            last_accepted_command_seq = unit.last_accepted_command_seq or 0,
        }
    end

    local projectiles = {}
    for index, projectile in ipairs(value.projectiles or {}) do
        projectiles[index] = {
            projectile_id = projectile.id,
            model = projectile.model,
            skill_id = projectile.skill_id,
            source_unit_id = projectile.source_unit_id,
            target_unit_id = projectile.target_unit_id or 0,
            position = proto_position(projectile.position),
        }
    end

    local areas = {}
    for index, area in ipairs(value.area_effects or {}) do
        areas[index] = {
            area_effect_id = area.id,
            skill_id = area.skill_id,
            owner_unit_id = area.owner_unit_id,
            center_world = proto_position(area.center_world),
            orientation = area.orientation,
            expire_tick = area.expire_tick,
        }
    end

    return {
        battle_id = value.battle_id,
        battle_version = value.battle_version,
        map_id = value.map_id,
        map_version = value.map_version,
        air_map_version = value.air_map_version,
        skill_version = value.skill_version,
        seed = value.seed,
        logic_tick = value.logic_tick,
        logic_ms = value.logic_ms,
        last_event_seq = value.last_event_seq,
        finished = value.finished,
        result = value.result or "",
        units = units,
        projectiles = projectiles,
        area_effects = areas,
    }
end

-- Event record 只复制协议已知字段；Runtime 内部临时字段不能直接整个 table 交给 codec。
local function proto_event(value)
    local points = {}
    for index, point in ipairs(value.points or {}) do points[index] = proto_position(point) end
    return {
        seq = value.seq or 0,
        logic_ms = value.logic_ms or 0,
        type = value.type or "",
        unit_id = value.unit_id or 0,
        target_id = value.target_id or 0,
        attacker_id = value.attacker_id or 0,
        killer_id = value.killer_id or 0,
        damage = value.damage or 0,
        target_hp = value.target_hp or 0,
        speed_mm_per_sec = value.speed_mm_per_sec or 0,
        reason = value.reason or "",
        result = value.result or "",
        position = proto_position(value.position),
        points = points,
        skill_id = value.skill_id or 0,
        projectile_id = value.projectile_id or 0,
        area_effect_id = value.area_effect_id or 0,
        buff_id = value.buff_id or 0,
        stack_count = value.stack_count or 0,
        expire_tick = value.expire_tick or 0,
        source_unit_id = value.source_unit_id or 0,
        logic_tick = value.logic_tick or 0,
    }
end

local function proto_events(values)
    local result = {}
    for index, value in ipairs(values or {}) do result[index] = proto_event(value) end
    return result
end

-- 把 lua-protobuf oneof request 映射为 Core 固定 Command record。
-- connection_id 不从 request 读取，它来自 FlyWow 当前真实连接上下文。
local function core_command(request)
    assert(type(request) == "table" and type(request.command) == "table",
           "battle command request is missing")
    local command = request.command
    local record = {
        unit_id = command.unit_id,
        command_seq = command.command_seq,
    }
    if command.move ~= nil then
        assert(command.cast == nil, "BattleCommand oneof contains both move and cast")
        record.kind = "MOVE"
        record.target_world = command.move.target_world
    elseif command.cast ~= nil then
        record.kind = "CAST"
        record.skill_id = command.cast.skill_id
        record.target_unit_id = command.cast.target_unit_id
        record.target_world = command.cast.target_world
        record.orientation = command.cast.orientation
    else
        return nil, { code = "INVALID_COMMAND", message = "command action is missing" }
    end
    return record
end

-- 所有 Manager call 都会 yield；Adapter 在 yield 前只保存纯值/Service handle，不保存 fd/buffer。
local function manager_call(command, payload)
    local ok, result, err = pcall(skynet.call, battle_mgr, "lua", command, payload)
    if not ok then
        skynet.error("battle manager call failed command=", command,
                     " error=", tostring(result))
        return nil, { code = "WORKER_UNAVAILABLE", message = "battle runtime unavailable" }
    end
    if result == nil then return nil, err or { code = "BATTLE_FAILED", message = "battle rejected" } end
    return result
end

local function run_auto_battle(request)
    if type(request) ~= "table" or request.scenario_id ~= 1001 then
        return { result = AUTO_RESULT.BAD_SCENARIO, message = "unknown scenario_id" }
    end
    local result, err = manager_call("simulate_scenario", { scenario_id = request.scenario_id })
    if result == nil then
        return { result = AUTO_RESULT.BATTLE_FAILED, message = err.message or "battle failed" }
    end
    return {
        result = AUTO_RESULT.OK,
        message = "",
        battle_id = result.battle_id,
        battle_version = result.battle_version,
        map_id = result.map_id,
        map_version = result.map_version,
        seed = result.seed,
        battle_result = result.result,
        end_logic_ms = result.end_logic_ms,
        events = proto_events(result.events),
        final_snapshot = proto_snapshot(result.final_snapshot),
    }
end

local function start_interactive(payload)
    local request = payload.request
    if type(request) ~= "table" or request.scenario_id ~= 1001 then
        return { result = START_RESULT.BAD_SCENARIO, message = "unknown scenario_id" }
    end
    local result, err = manager_call("create_online", {
        connection_id = payload.connection_id,
        scenario_id = request.scenario_id,
    })
    if result == nil then
        local code = err.code == "WORKER_BUSY" and START_RESULT.BUSY or START_RESULT.BATTLE_FAILED
        return { result = code, message = err.message or err.code or "battle create failed" }
    end
    return {
        result = START_RESULT.OK,
        message = "",
        battle_id = result.battle_id,
        worker_index = result.worker_index,
        snapshot = proto_snapshot(result.snapshot),
        resume_token = result.resume_token,
    }
end

-- 新连接使用 Battle 签发的短期凭据恢复控制权；错误不泄露 Battle 是否存在。
-- payload.connection_id 只能由 Gateway/Proxy 注入；Manager/Worker call 会 yield。
local function resume_interactive(payload)
    local request = assert(payload.request)
    local result, err = manager_call("resume_online", {
        battle_id = request.battle_id,
        resume_token = request.resume_token,
        connection_id = payload.connection_id,
    })
    if result == nil then
        return {
            result = RESUME_RESULT[err.code] or RESUME_RESULT.WORKER_UNAVAILABLE,
            message = err.message or "resume failed",
        }
    end
    return {
        result = RESUME_RESULT.OK,
        message = "",
        battle_id = result.battle_id,
        snapshot = proto_snapshot(result.snapshot),
        finished = result.finished,
    }
end

local function submit_command(payload)
    local request = assert(payload.request)
    local command, parse_error = core_command(request)
    if command == nil then
        return { result = COMMAND_RESULT.INVALID_COMMAND, message = parse_error.message }
    end
    local result, err = manager_call("submit_command", {
        connection_id = payload.connection_id,
        battle_id = request.battle_id,
        command = command,
    })
    if result == nil then
        return {
            result = COMMAND_RESULT[err.code] or COMMAND_RESULT.INVALID_COMMAND,
            message = err.message or err.code or "command rejected",
        }
    end
    return {
        result = COMMAND_RESULT.OK,
        message = "",
        command_seq = result.command_seq,
        apply_tick = result.apply_tick,
    }
end

local function sync_battle(payload)
    local request = assert(payload.request)
    local result, err = manager_call("sync", {
        connection_id = payload.connection_id,
        battle_id = request.battle_id,
        after_event_seq = request.after_event_seq,
        want_snapshot = request.want_snapshot,
    })
    if result == nil then
        return {
            result = SYNC_RESULT[err.code] or SYNC_RESULT.WORKER_UNAVAILABLE,
            message = err.message or err.code or "sync failed",
        }
    end
    return {
        result = SYNC_RESULT.OK,
        message = "",
        battle_id = result.battle_id,
        logic_tick = result.logic_tick,
        first_available_seq = result.first_available_seq,
        latest_event_seq = result.latest_event_seq,
        event_gap = result.gap,
        snapshot = proto_snapshot(result.snapshot),
        events = proto_events(result.events),
        finished = result.finished,
        battle_result = result.result and result.result.result or "",
    }
end

local function stop_battle(payload)
    local request = assert(payload.request)
    local result, err = manager_call("stop", {
        connection_id = payload.connection_id,
        battle_id = request.battle_id,
    })
    if result == nil then
        return {
            result = STOP_RESULT[err.code] or STOP_RESULT.WORKER_UNAVAILABLE,
            message = err.message or err.code or "stop failed",
        }
    end
    return {
        result = STOP_RESULT.OK,
        message = "",
        battle_id = result.battle_id,
        final_snapshot = proto_snapshot(result.snapshot),
    }
end

-- Gateway 已完成 command_id/类型匹配和 Protobuf decode；这里仍检查业务 command 名，防错误接线。
local function dispatch_gateway(payload)
    assert(query_service ~= nil and battle_mgr ~= nil, "battle_dispatch is not ready")
    assert(type(payload) == "table", "gateway payload must be table")

    if payload.command == "QueryCell" and payload.command_id == 1001 then
        return skynet.call(query_service, "lua", "gateway_dispatch", payload)
    elseif payload.command == "RunAutoBattle" and payload.command_id == 1002 then
        return { ok = true, response = run_auto_battle(payload.request) }
    elseif payload.command == "StartInteractiveBattle" and payload.command_id == 1003 then
        return { ok = true, response = start_interactive(payload) }
    elseif payload.command == "SubmitBattleCommand" and payload.command_id == 1004 then
        return { ok = true, response = submit_command(payload) }
    elseif payload.command == "SyncBattle" and payload.command_id == 1005 then
        return { ok = true, response = sync_battle(payload) }
    elseif payload.command == "StopInteractiveBattle" and payload.command_id == 1006 then
        return { ok = true, response = stop_battle(payload) }
    elseif payload.command == "ResumeInteractiveBattle" and payload.command_id == 1007 then
        return { ok = true, response = resume_interactive(payload) }
    end

    return { ok = false, error = {
        code = "UNKNOWN_COMMAND",
        message = "command/id mismatch",
    } }
end

-- D039 使用独立响应消息及显式传输关联字段，不等待 Gateway 原请求协程。
-- Gateway Proxy 的有限返回路由只关联协议响应，不代表 Battle/玩家身份。
-- 下面的旧版 route_token 回包实现仅作历史对照，不能照抄；应按 D039 构造独立 send_data 响应 record。
local function forward_result(payload)
    assert(type(payload) == "table" and type(payload.route_token) == "string" and
           #payload.route_token > 0 and #payload.route_token <= 128,
           "invalid gateway route token")
    local token = payload.route_token
    local ok, result = pcall(dispatch_gateway, payload)
    if not ok then
        skynet.error("BATTLE_GATEWAY_DISPATCH_FAILED error=", tostring(result))
        result = { ok = false, error = {
            code = "BATTLE_FAILED", message = "battle request failed",
        } }
    end
    local sent, send_error = pcall(
        cluster.send,
        process.cluster.gateway_node,
        "@" .. process.cluster.gateway_proxy_service,
        "battle_result", token, result)
    if not sent then
        skynet.error("BATTLE_RESULT_FORWARD_FAILED error=", tostring(send_error))
    end
end

skynet.start(function()
    skynet.dispatch("lua", function(_session, _source, command, payload)
        if command == "configure" then
            skynet.retpack(configure(assert(payload)))
        elseif command == "ready" then
            skynet.retpack(query_service ~= nil and battle_mgr ~= nil)
        elseif command == "gateway_dispatch" then
            forward_result(assert(payload))
        else
            error("unknown battle_dispatch command: " .. tostring(command))
        end
    end)
end)
```

第 8 节的完整 `battle_mgr.lua` 已包含 `simulate_scenario` 及其 dispatch 分支；这里不再重复追加。客户端依然不能上传权威 Snapshot。

---

### 42.3 `battle_main.lua` 第三课 Composition Root 最终版

第三课 `battle_main` 必须真实创建：

```text
navigation_query
battle_mgr
battle_dispatch
可选 debug_console
cluster listener
```

而不是继续把 Query Service 直接注册成跨进程入口。

[完整替换]

```text
server/service/battle/battle_main.lua
```

```lua
-- 职责：组装第三课 Map/Battle Process，按依赖顺序创建 Query、BattleMgr、Dispatch 和开发调试入口。
-- 边界：Skynet Process Composition Root；只注入 Service handle，不拥有 Battle/Socket 状态。
-- 输入/输出：固定 config -> READY 的 cluster battle_dispatch 入口。
-- 生命周期：启动接线完成后本 Service 退出；子 Service/cluster/debug_console 继续运行。
-- 不负责：不解析 Protobuf、不执行导航/技能、不保存 Client connection。
local cluster = require "skynet.cluster"
local skynet = require "skynet"
local process = require "config.process_battle"
local battle_config = require "config.battle"

skynet.start(function()
    -- 先加载/校验 BMAP+AMAP；ready 成功意味着 process-level static asset 已可用。
    local query_service = skynet.newservice("battle/navigation_query")
    assert(skynet.call(query_service, "lua", "ready"),
           "navigation query did not become ready")

    -- Manager 会创建固定 BattleWorker Shard Pool，并等待每个 Worker ready。
    local battle_mgr = skynet.newservice("battle/battle_mgr")
    assert(skynet.call(battle_mgr, "lua", "ready"),
           "battle manager did not become ready")

    local dispatcher = skynet.newservice("battle/battle_dispatch")
    assert(skynet.call(dispatcher, "lua", "configure", {
        query_service = query_service,
        battle_mgr = battle_mgr,
    }))
    assert(skynet.call(dispatcher, "lua", "ready"))

    if battle_config.debug_console_port > 0 then
        skynet.newservice("debug_console", battle_config.debug_console_port)
    end

    -- 只有所有本地 owner ready 后才对 Gateway Process 发布 cluster 服务名。
    cluster.open(process.cluster.local_listen, process.cluster.max_clients)
    cluster.register(process.cluster.service_name, dispatcher)

    skynet.error(
        "LESSON3_BATTLE_PROCESS_READY node=", process.cluster.service_name,
        " query=", skynet.address(query_service),
        " manager=", skynet.address(battle_mgr),
        " dispatch=", skynet.address(dispatcher),
        " workers=", battle_config.worker_count,
        " cluster=", process.cluster.local_listen)
    skynet.exit()
end)
```

`gateway_main.lua` 不需要知道 Skill/Worker/AirMap。`gateway_proxy.lua` 只按第 40 节封装真实连接的作用域身份，继续使用第二课的 `cluster.send` 转发与 `battle_result` 回推；registry 新增 1003～1007。Proxy 不解释 Battle/Skill/Event 内容。

---

# 第十四部分：场景输入——三种单位、五个技能，但仍是一个很小的沙盒

## 43. 修改 `scenario_1001.lua`

[局部修改]

```text
server/lualib/battle/scenario_1001.lua
```

保留第二课自动 Battle 的入口，同时增加：

```lua
scenario.make_interactive_snapshot(battle_id)
```

最小场景：

```text
Player 1001
  camp=1
  GROUND
  base speed=3000
  HP=160
  skills=1001,1002,1003,1004,1005

GroundEnemy 2001
  camp=2
  GROUND
  base speed=2200
  HP=120
  AI uses Slash

FlyingEnemy 2002
  camp=2
  AIR
  base speed=2600
  flight_height=2500mm
  HP=90
  AI uses Fireball
```

Server 决定出生位置。

客户端只拿到 Snapshot。

### 43.1 为什么固定场景仍然有价值

本课学习的是：

```text
Battle Runtime
Skynet
Navigation
Skill
Sync
```

不是角色配置后台。

固定场景带来：

```text
可重复
可 Regression
容易故障注入
容易对比在线/自动结果
```

等这些核心稳定以后，再把配置读取替换为真实 DataTable 不会改变 Battle owner model。

# 第十五部分：AI——只产生意图，不复制技能/移动逻辑

## 44. GroundEnemy AI

第二课已经有：

```text
choose target
find path to attack range
move
basic attack
```

第三课把“basic attack”改成：

```text
AI 产生 CastIntent(skill_id=1001)
-> SkillRuntime
```

这样 Player Slash 和 GroundEnemy Slash 走同一结算链。

AI 本身只决定：

```text
目标是谁
当前要移动还是施法
```

## 45. FlyingEnemy AI

固定规则：

```text
从 Fireball 合法目标中选择敌方存活单位
距离优先，相同距离用更小 unit.id 打破平局
目标可以是 Ground，也可以是 Air
如果超出 Fireball range：Air A* 接近
进入 range：停止 Air Path，Cast Fireball
CD 中：保持位置或继续简单跟随
```

这里不要写死“只打 Player”。第三课需要证明 FlyingEnemy/FlyingDragon 是完整 Air Combat Unit：同一套 AI 在混合场景里可以 Air -> Ground，在 AirCombat Golden Case 里可以 Air -> Air。

它不重新实现伤害。

最终：

```text
Player Cast
GroundEnemy AI Cast
FlyingEnemy AI Cast
        |
        v
同一个 SkillRuntime
```

这就是第三课要求证明的“人工输入和 Server AI 走同一条结算链”。

# 第十六部分：Unity 在线验证客户端

## 46. Unity 仍然不是权威模拟器

第三课 Unity 新增职责：

```text
键盘/鼠标生成 PlayerCommand
StartInteractiveBattle
SubmitBattleCommand
定期 SyncBattle
按 Server Event 表现
用 Snapshot 做初始化/校正
```

不能：

```text
NavMeshAgent 自己决定最终位置
客户端计算 Damage
客户端决定 FrostBolt 命中谁
客户端自己执行 FireWall 伤害
客户端自己过期 Buff
```

## 47. 复用第二课 `GatewayEnvelopeClient`，但这次连接必须贯穿一场在线 Battle

第二课已经有：

```text
unity/BattleNavigation/Assets/BattleNavigation/Scripts/Protocol/GatewayEnvelopeClient.cs
```

它的一个实例在构造时建立 `TcpClient`，之后可以连续执行多个 `RoundTrip()`，直到 `Dispose()`。第三课必须利用这个性质。

原因是 Server 的最小课程控制权使用：

```text
FlyWow Gateway connection_id
```

FlyWow 生成数字连接号，Proxy 给它加进程作用域后成为 Battle 使用的 `connection_id`；业务请求里只能读取，客户端不能上传伪造。于是：

```text
StartInteractiveBattle
SubmitBattleCommand
SyncBattle
StopInteractiveBattle
```

正常请求来自 **同一条 TCP 连接**；断线后必须先通过 `ResumeInteractiveBattle` 重新绑定新连接，随后才能继续 Command/Sync/Stop。

不要这样写：

```text
Start -> new GatewayEnvelopeClient -> Dispose
Command -> new GatewayEnvelopeClient -> Dispose
Sync -> new GatewayEnvelopeClient -> Dispose
```

未经 Resume 的新连接有新的 `connection_id`，Server 会返回 `NOT_CONTROLLER`。

本课不引入账号/登录；正常控制权先绑定当前 Gateway 连接。Start 额外返回一次短期 `resume_token`，仅用于把同一场 Battle 的控制权恢复到新连接。这正好能把边界讲清：

```text
connection_id = transport session identity
connection_id != player_id
connection_id != account_id
connection_id 不能持久化
resume_token = 当前 Battle 的短期 bearer 凭据；不等于账号或长期会话
```

断线恢复只在当前 Battle Runtime 仍存在时成功；Worker 关闭后返回拒绝，不能从 Snapshot 凭空重建已释放的 Context。账号级登录、跨进程故障恢复和持久化会话属于后续工程专题。

### 47.1 新建 `ServerInteractiveBattleClient.cs`

[新建文件]

```text
unity/BattleNavigation/Assets/BattleNavigation/Scripts/Protocol/ServerInteractiveBattleClient.cs
```

它独占一个 `GatewayEnvelopeClient`，整个在线 Battle 生命周期只创建一次：

```csharp
// 职责：在当前 FlyWow Gateway TCP 连接上完成 Start/Resume/Command/Sync/Stop。
// 边界：Unity Client Runtime RPC Adapter；只处理强类型 Protobuf，不计算任何权威战斗结果。
// 输入/输出：交互战斗请求 -> 对应强类型响应；网络/协议错误抛异常。
// 生命周期：构造时建立连接；整个在线 Battle 共用；Dispose 时关闭连接。
// 不负责：不保存账号身份、不在 Unity 主线程每帧同步阻塞；重连由上层控制器创建新实例。
using System;
using Battle.Navigation.V1;

namespace BattleNavigation.Client
{
    /// <summary>
    /// 一个在线 Battle 会话独占的 Gateway Client。
    /// 同一实例的 RoundTrip 必须串行，保证 request/response 与 Gateway 单连接顺序合同一致。
    /// </summary>
    public sealed class ServerInteractiveBattleClient : IDisposable
    {
        private const uint StartCommand = 1003;
        private const uint SubmitCommand = 1004;
        private const uint SyncCommand = 1005;
        private const uint StopCommand = 1006;
        private const uint ResumeCommand = 1007;

        private readonly GatewayEnvelopeClient gateway;
        private readonly object roundTripLock = new object();

        /// <summary>
        /// 建立并独占一条 Gateway TCP 连接。
        /// </summary>
        /// <param name="host">Gateway 主机名或 IP。</param>
        /// <param name="port">Gateway TCP 端口。</param>
        public ServerInteractiveBattleClient(string host, int port)
        {
            gateway = new GatewayEnvelopeClient(host, port);
        }

        /// <summary>
        /// 创建 Server 预定义交互场景；业务失败保留在 response.Result。
        /// 本方法执行同步 Socket I/O，调用方必须放在后台网络线程，不要直接放 Unity Update。
        /// </summary>
        public StartInteractiveBattleResponse Start(uint scenarioId)
        {
            lock (roundTripLock)
            {
                var envelope = gateway.RoundTrip(
                    StartCommand,
                    new StartInteractiveBattleRequest { ScenarioId = scenarioId });
                return StartInteractiveBattleResponse.Parser.ParseFrom(envelope.Body);
            }
        }

        /// <summary>
        /// 在新 TCP 连接上提交当前 Battle 的短期恢复凭据；成功响应含即时 Snapshot。
        /// 凭据只保存在本次运行的内存中，不写日志或 PlayerPrefs；本方法执行同步 Socket I/O。
        /// </summary>
        public ResumeInteractiveBattleResponse Resume(uint battleId, string resumeToken)
        {
            if (string.IsNullOrEmpty(resumeToken))
                throw new ArgumentException("resume token is required", nameof(resumeToken));
            lock (roundTripLock)
            {
                var envelope = gateway.RoundTrip(
                    ResumeCommand,
                    new ResumeInteractiveBattleRequest
                    {
                        BattleId = battleId,
                        ResumeToken = resumeToken,
                    });
                return ResumeInteractiveBattleResponse.Parser.ParseFrom(envelope.Body);
            }
        }

        /// <summary>
        /// 提交一个只描述意图的 PlayerCommand；Server 返回真正 apply_tick。
        /// </summary>
        public SubmitBattleCommandResponse Submit(uint battleId, BattleCommand command)
        {
            if (command == null) throw new ArgumentNullException(nameof(command));
            lock (roundTripLock)
            {
                var envelope = gateway.RoundTrip(
                    SubmitCommand,
                    new SubmitBattleCommandRequest
                    {
                        BattleId = battleId,
                        Command = command,
                    });
                return SubmitBattleCommandResponse.Parser.ParseFrom(envelope.Body);
            }
        }

        /// <summary>
        /// 拉取 afterEventSeq 后的增量 Event；event_gap 时 Snapshot 是新的权威恢复点。
        /// </summary>
        public SyncBattleResponse Sync(uint battleId, uint afterEventSeq, bool wantSnapshot)
        {
            lock (roundTripLock)
            {
                var envelope = gateway.RoundTrip(
                    SyncCommand,
                    new SyncBattleRequest
                    {
                        BattleId = battleId,
                        AfterEventSeq = afterEventSeq,
                        WantSnapshot = wantSnapshot,
                    });
                return SyncBattleResponse.Parser.ParseFrom(envelope.Body);
            }
        }

        /// <summary>
        /// 主动停止当前 Battle；正常胜负结束后调用可用于尽早释放最终结果缓存。
        /// </summary>
        public StopInteractiveBattleResponse Stop(uint battleId)
        {
            lock (roundTripLock)
            {
                var envelope = gateway.RoundTrip(
                    StopCommand,
                    new StopInteractiveBattleRequest { BattleId = battleId });
                return StopInteractiveBattleResponse.Parser.ParseFrom(envelope.Body);
            }
        }

        /// <summary>关闭本在线会话独占的 Gateway 连接。</summary>
        public void Dispose()
        {
            gateway.Dispose();
        }
    }
}
```

`roundTripLock` 不是用来实现游戏逻辑线程安全，而是保护一个 **顺序 request/response TCP client** 不被两个 Unity 后台任务同时读写。同一连接的网络调用本来也不应该并发抢一个 `NetworkStream`。

## 48. `InteractiveBattleController.cs`：主线程只收输入，网络线程只做 RPC

[新建文件]

```text
unity/BattleNavigation/Assets/BattleNavigation/client/InteractiveBattleController.cs
```

第三课不要在 `Update()` 里直接同步 Socket I/O。最小结构是：

```text
Unity Main Thread
  Input
    -> ConcurrentQueue<BattleCommand>

一个后台 Network Loop
  -> 同一个 ServerInteractiveBattleClient
  -> Submit queued command
  -> 每约 100ms SyncBattle
  -> ConcurrentQueue<SyncBattleResponse>

Unity Main Thread
  -> 消费 response
  -> InteractiveBattleView
```

这样同时满足：

```text
同一 TCP 连接保持 controller_connection_id
网络不阻塞 Unity Update
同一连接始终顺序 RoundTrip
Server Tick 不由 Client 驱动
Unity 对象只在 Main Thread 修改
```

下面给出可直接实现的完整调试控制器。它故意没有把 UI 做复杂；选择目标先使用 Inspector 中的 `selectedTargetUnitId`，让课程重点保持在 Server。

```csharp
// 职责：收集 Unity 输入，并用一个后台网络循环驱动在线 Battle RPC 与增量 Sync。
// 边界：Unity Client Runtime Controller；只产生意图、消费 Server Snapshot/Event。
// 输入/输出：鼠标/数字键 -> BattleCommand；Server response -> InteractiveBattleView。
// 生命周期：OnEnable/Start 建立一个在线会话；OnDestroy 取消网络循环并关闭连接。
// 不负责：不计算路径、命中、Damage、Buff、Projectile collision 或 Battle Tick。
using System;
using System.Collections.Concurrent;
using System.Threading;
using System.Threading.Tasks;
using Battle.Navigation.V1;
using UnityEngine;

namespace BattleNavigation.Client
{
    /// <summary>第三课在线联调入口；所有权威结果都来自 Server。</summary>
    public sealed class InteractiveBattleController : MonoBehaviour
    {
        [SerializeField] private string host = "127.0.0.1";
        [SerializeField] private int port = 19011;
        [SerializeField] private uint scenarioId = 1001;
        [SerializeField] private uint playerUnitId = 1001;
        [SerializeField] private uint selectedTargetUnitId = 2001;
        [SerializeField] private Camera inputCamera;
        [SerializeField] private InteractiveBattleView view;

        private readonly ConcurrentQueue<BattleCommand> outboundCommands =
            new ConcurrentQueue<BattleCommand>();
        private readonly ConcurrentQueue<StartInteractiveBattleResponse> startResponses =
            new ConcurrentQueue<StartInteractiveBattleResponse>();
        private readonly ConcurrentQueue<SyncBattleResponse> syncResponses =
            new ConcurrentQueue<SyncBattleResponse>();
        private readonly ConcurrentQueue<BattleSnapshot> recoverySnapshots =
            new ConcurrentQueue<BattleSnapshot>();
        private readonly ConcurrentQueue<string> errors =
            new ConcurrentQueue<string>();

        private CancellationTokenSource cancellation;
        private Task networkTask;
        private uint nextCommandSeq = 1;
        private bool battleReady;
        private volatile bool networkStopped;
        private Vector3 lastGroundPoint;
        private const int MaxPendingCommands = 64;
        private const int MaxPendingResponses = 128;

        /// <summary>限制 Unity 到后台网络循环的命令积压；满时拒绝本次输入。</summary>
        private void QueueCommand(BattleCommand command)
        {
            if (outboundCommands.Count >= MaxPendingCommands)
            {
                Debug.LogWarning("Battle command queue is full");
                return;
            }
            outboundCommands.Enqueue(command);
        }

        /// <summary>
        /// 启动唯一网络循环；不在主线程建立持续轮询逻辑。
        /// </summary>
        private void Start()
        {
            if (inputCamera == null) inputCamera = Camera.main;
            if (view == null) throw new InvalidOperationException("InteractiveBattleView is required");
            cancellation = new CancellationTokenSource();
            networkTask = Task.Run(() => NetworkLoop(cancellation.Token));
        }

        /// <summary>
        /// Unity 主线程只读取输入和应用已返回的数据；不执行同步网络调用。
        /// </summary>
        private void Update()
        {
            DrainNetworkResponses();
            if (networkStopped) battleReady = false;
            if (!battleReady) return;

            UpdateGroundPoint();
            if (Input.GetMouseButtonDown(1))
            {
                EnqueueMove(lastGroundPoint);
            }
            if (Input.GetKeyDown(KeyCode.Alpha1)) EnqueueTargetSkill(1001);
            if (Input.GetKeyDown(KeyCode.Alpha2)) EnqueueTargetSkill(1002);
            if (Input.GetKeyDown(KeyCode.Alpha3)) EnqueueTargetSkill(1003);
            if (Input.GetKeyDown(KeyCode.Alpha4))
            {
                EnqueueFireWall(
                    Input.GetKey(KeyCode.LeftShift) ? "Z_AXIS" : "X_AXIS");
            }
            if (Input.GetKeyDown(KeyCode.Alpha5)) EnqueueSelfSkill(1005);
        }

        /// <summary>
        /// 从 Camera 射线取得纯表现/输入世界点；Server 后续仍会重新校验和归一化。
        /// </summary>
        private void UpdateGroundPoint()
        {
            if (inputCamera == null) return;
            var ray = inputCamera.ScreenPointToRay(Input.mousePosition);
            if (Physics.Raycast(ray, out var hit, 10000f))
                lastGroundPoint = hit.point;
        }

        /// <summary>把 Unity 米坐标转换为客户端意图使用的整数毫米。</summary>
        private static WorldPosition ToServerPosition(Vector3 value)
        {
            return new WorldPosition
            {
                XMm = (long)Math.Round(value.x * 1000.0),
                YMm = (long)Math.Round(value.y * 1000.0),
                ZMm = (long)Math.Round(value.z * 1000.0),
            };
        }

        /// <summary>排队一个移动意图；真正路径由 Server Ground Navigation 决定。</summary>
        private void EnqueueMove(Vector3 target)
        {
            QueueCommand(new BattleCommand
            {
                UnitId = playerUnitId,
                CommandSeq = nextCommandSeq++,
                Move = new MoveCommand { TargetWorld = ToServerPosition(target) },
            });
        }

        /// <summary>排队目标型技能；命中、距离、TargetMask 全部由 Server 再验证。</summary>
        private void EnqueueTargetSkill(uint skillId)
        {
            QueueCommand(new BattleCommand
            {
                UnitId = playerUnitId,
                CommandSeq = nextCommandSeq++,
                Cast = new CastSkillCommand
                {
                    SkillId = skillId,
                    TargetUnitId = selectedTargetUnitId,
                },
            });
        }

        /// <summary>排队 FireWall；世界点和方向都只是意图。</summary>
        private void EnqueueFireWall(string orientation)
        {
            QueueCommand(new BattleCommand
            {
                UnitId = playerUnitId,
                CommandSeq = nextCommandSeq++,
                Cast = new CastSkillCommand
                {
                    SkillId = 1004,
                    TargetWorld = ToServerPosition(lastGroundPoint),
                    Orientation = orientation,
                },
            });
        }

        /// <summary>排队 Self Buff 技能。</summary>
        private void EnqueueSelfSkill(uint skillId)
        {
            QueueCommand(new BattleCommand
            {
                UnitId = playerUnitId,
                CommandSeq = nextCommandSeq++,
                Cast = new CastSkillCommand { SkillId = skillId },
            });
        }

        /// <summary>
        /// 唯一后台网络循环。正常请求复用同一连接；断线后使用短期凭据在新连接上恢复。
        /// Socket I/O 只发生在本后台 Task；最多重试三次，避免无界重连。
        /// </summary>
        private void NetworkLoop(CancellationToken token)
        {
            uint battleId = 0;
            uint afterEventSeq = 0;
            string resumeToken = null;
            ServerInteractiveBattleClient client = null;
            try
            {
                client = new ServerInteractiveBattleClient(host, port);
                var started = client.Start(scenarioId);
                startResponses.Enqueue(started);
                if (started.Result != StartInteractiveBattleResponse.Types.ResultCode.Ok)
                    return;

                battleId = started.BattleId;
                resumeToken = started.ResumeToken;
                if (string.IsNullOrEmpty(resumeToken) || started.Snapshot == null)
                    throw new InvalidOperationException("Start response lacks recovery state");
                afterEventSeq = started.Snapshot?.LastEventSeq ?? 0;

                while (!token.IsCancellationRequested)
                {
                    try
                    {
                        // Ack 丢失时保留队首命令；恢复 Snapshot 的已接受 seq 决定是否可移除。
                        while (outboundCommands.TryPeek(out var command))
                        {
                            var submitted = client.Submit(battleId, command);
                            if (submitted.Result != SubmitBattleCommandResponse.Types.ResultCode.Ok &&
                                submitted.Result != SubmitBattleCommandResponse.Types.ResultCode.StaleOrDuplicateCommand)
                                errors.Enqueue($"Submit rejected seq={command.CommandSeq} result={submitted.Result}");
                            outboundCommands.TryDequeue(out _);
                        }

                        var sync = client.Sync(battleId, afterEventSeq, false);
                        if (sync.Result != SyncBattleResponse.Types.ResultCode.Ok)
                            throw new InvalidOperationException("Sync rejected: " + sync.Result);

                        // Event 缺口时以即时 Snapshot 为恢复点，旧 Event 不再应用。
                        if (sync.EventGap)
                            afterEventSeq = sync.Snapshot?.LastEventSeq ??
                                throw new InvalidOperationException("Event gap lacks Snapshot");
                        else if (sync.Events.Count > 0)
                            afterEventSeq = sync.Events[sync.Events.Count - 1].Seq;
                        if (syncResponses.Count >= MaxPendingResponses)
                            throw new InvalidOperationException("Unity response queue is full");
                        syncResponses.Enqueue(sync);

                        if (sync.Finished) break;
                        if (token.WaitHandle.WaitOne(100)) break;
                    }
                    catch (Exception networkError) when (
                        !token.IsCancellationRequested &&
                        !(networkError is InvalidOperationException))
                    {
                        client.Dispose();
                        client = null;
                        bool resumed = false;
                        for (int attempt = 1; attempt <= 3 && !token.IsCancellationRequested; attempt++)
                        {
                            if (token.WaitHandle.WaitOne(500)) break;
                            try
                            {
                                client = new ServerInteractiveBattleClient(host, port);
                                var recovery = client.Resume(battleId, resumeToken);
                                if (recovery.Result != ResumeInteractiveBattleResponse.Types.ResultCode.Ok ||
                                    recovery.Snapshot == null)
                                    throw new InvalidOperationException("Resume denied: " + recovery.Result);
                                afterEventSeq = recovery.Snapshot.LastEventSeq;
                                uint acceptedSeq = 0;
                                bool foundPlayer = false;
                                foreach (var unit in recovery.Snapshot.Units)
                                {
                                    if (unit.UnitId != playerUnitId) continue;
                                    acceptedSeq = unit.LastAcceptedCommandSeq;
                                    foundPlayer = true;
                                    break;
                                }
                                if (!foundPlayer)
                                    throw new InvalidOperationException("Player missing from recovery Snapshot");
                                while (outboundCommands.TryPeek(out var pending) &&
                                       pending.CommandSeq <= acceptedSeq)
                                    outboundCommands.TryDequeue(out _);
                                while (syncResponses.TryDequeue(out _)) { }
                                while (recoverySnapshots.TryDequeue(out _)) { }
                                recoverySnapshots.Enqueue(recovery.Snapshot);
                                resumed = true;
                                break;
                            }
                            catch (Exception resumeError)
                            {
                                client?.Dispose();
                                client = null;
                                if (attempt == 3) errors.Enqueue("Resume failed: " + resumeError.Message);
                            }
                        }
                        if (!resumed) break;
                    }
                }

                if (battleId != 0 && client != null)
                {
                    try { client.Stop(battleId); }
                    catch (Exception stopError)
                    {
                        errors.Enqueue("Stop failed: " + stopError.Message);
                    }
                }
            }
            catch (Exception error)
            {
                errors.Enqueue(error.ToString());
            }
            finally
            {
                client?.Dispose();
                networkStopped = true;
            }
        }

        /// <summary>
        /// 只在 Unity 主线程消费网络结果和修改 GameObject。
        /// event_gap 时先用 Snapshot 覆盖显示状态，并忽略本次旧 Event 列表。
        /// </summary>
        private void DrainNetworkResponses()
        {
            while (errors.TryDequeue(out var error))
                Debug.LogError(error);

            while (startResponses.TryDequeue(out var started))
            {
                if (started.Result != StartInteractiveBattleResponse.Types.ResultCode.Ok)
                {
                    Debug.LogError("Start battle failed: " + started.Message);
                    continue;
                }
                view.ApplySnapshot(started.Snapshot);
                battleReady = true;
            }

            while (recoverySnapshots.TryDequeue(out var recoverySnapshot))
                view.ApplySnapshot(recoverySnapshot);

            while (syncResponses.TryDequeue(out var sync))
            {
                if (sync.EventGap)
                {
                    if (sync.Snapshot != null) view.ApplySnapshot(sync.Snapshot);
                    continue;
                }
                foreach (var battleEvent in sync.Events)
                    view.ApplyEvent(battleEvent);
                if (sync.Snapshot != null) view.ApplySnapshot(sync.Snapshot);
            }
        }

        /// <summary>停止网络循环；不在这里等待无限时间或继续操作 Unity 对象。</summary>
        private void OnDestroy()
        {
            battleReady = false;
            cancellation?.Cancel();
            // 网络 Task 可能仍在退出路径读取 token.WaitHandle；不要在主线程提前 Dispose CTS。
            cancellation = null;
            networkTask = null;
        }
    }
}
```

注意：这段 Client 代码里的 `Task/ConcurrentQueue` 只是为了避免 Unity Main Thread 被同步 Socket 阻塞。它不是 Server 并发模型，也不会改变 Server 权威性。

### 48.1 SyncBattle polling 为什么允许

本课固定：

```text
Server Battle Tick = 50ms
Client Sync interval ~= 100ms
```

关系是：

```text
Skynet Worker heartbeat
  -> 独立推进逻辑 Tick

Unity SyncBattle
  -> 只读取已经产生的 Event/Snapshot
```

即使 Unity 暂停 Sync 1 秒：

```text
Server 仍继续推进
```

恢复时：

```text
after_event_seq 仍在 ring 范围
  -> 补增量 Event

after_event_seq 已早于 first_available_seq
  -> event_gap=true
  -> Worker 当场生成新 Snapshot
  -> Client 直接跳到 Snapshot 的 last_event_seq
```

因此 polling 只是本课为了复用现有 FlyWow request/response Gateway 的**传输简化**，不是让 Client 驱动模拟，也不是宣称商业 SLG 必须 polling。以后 Gateway 增加 Server Push 时，Battle Core、Worker Shard、Event/Snapshot 合同都不需要重写。

### 48.2 断线后怎样恢复原 Battle

正常控制权是：

```text
controller_connection_id
```

断线重连会得到新 `connection_id`。Start 返回的 32 字节 OS 随机凭据是本课最小的持有者证明；Resume 成功后，Worker 在同一 no-yield 函数里把控制连接换成新连接，并返回即时 Snapshot。该 Snapshot 的 `last_event_seq` 是 Client 恢复点，Player 的 `last_accepted_command_seq` 用来判定丢失 Ack 的命令是否已被 Server 接受。

恢复失败时明确拒绝；不猜测旧连接的权限或战斗状态：

```text
断线 -> 原 Battle 继续由 Server 推进
新连接 + battle_id + resume_token -> Worker 校验 -> 即时 Snapshot + 新连接取得控制权
凭据错误/Runtime 已回收 -> NOT_CONTROLLER；Client 停止该场输入
finished 后最多保留 finished_retention_cs -> Runtime 自动回收
```

恢复只覆盖短时网络断线；账号登录、跨 Worker 故障恢复、持久化 session 和顶号策略放到后续专题。

### 48.3 `InteractiveBattleView.cs`：把 Event/Snapshot 真正投影到 Unity

当前草稿只有行为列表，实际联调时仍会缺一个可复制的 View。这里补一个**调试表现版**：只用 Capsule/Sphere/Cube 和 Console，不引入美术系统。

[新建文件]

```text
unity/BattleNavigation/Assets/BattleNavigation/client/InteractiveBattleView.cs
```

```csharp
// 职责：把 Server BattleSnapshot/BattleEvent 投影为 Unity 调试 GameObject 和日志。
// 边界：Unity Client Runtime Presentation；所有逻辑事实来自 Server。
// 输入/输出：Snapshot/Event -> Capsule/Sphere/Cube 位置、销毁和简单日志。
// 生命周期：一个 Scene 组件拥有当前显示对象；OnDestroy 清理本地表现状态。
// 不负责：不重新寻路、不计算技能命中/伤害、不把 Transform 回写 Server。
using System;
using System.Collections.Generic;
using Battle.Navigation.V1;
using UnityEngine;

namespace BattleNavigation.Client
{
    public sealed class InteractiveBattleView : MonoBehaviour
    {
        private sealed class MoveState
        {
            public readonly List<Vector3> points = new List<Vector3>();
            public int nextPoint;
            public float speedMetersPerSecond;
        }

        private readonly Dictionary<uint, GameObject> units = new Dictionary<uint, GameObject>();
        private readonly Dictionary<uint, GameObject> projectiles = new Dictionary<uint, GameObject>();
        private readonly Dictionary<uint, GameObject> areas = new Dictionary<uint, GameObject>();
        private readonly Dictionary<uint, MoveState> moves = new Dictionary<uint, MoveState>();

        /// <summary>应用一份当前权威 Snapshot；Event gap 后以它为新基线。</summary>
        public void ApplySnapshot(BattleSnapshot snapshot)
        {
            if (snapshot == null) throw new ArgumentNullException(nameof(snapshot));
            var alive = new HashSet<uint>();
            foreach (BattleUnitSnapshot unit in snapshot.Units)
            {
                alive.Add(unit.UnitId);
                GameObject value = GetOrCreateUnit(unit.UnitId, unit.Position);
                value.transform.position = ToUnity(unit.Position);
                // Snapshot 是校正点；旧 MOVE_PATH 的局部插值不能越过它继续播放。
                moves.Remove(unit.UnitId);
            }
            RemoveMissing(units, alive);

            var projectileIds = new HashSet<uint>();
            foreach (BattleProjectileSnapshot projectile in snapshot.Projectiles)
            {
                projectileIds.Add(projectile.ProjectileId);
                GameObject value = GetOrCreateProjectile(projectile.ProjectileId);
                value.transform.position = ToUnity(projectile.Position);
            }
            RemoveMissing(projectiles, projectileIds);

            var areaIds = new HashSet<uint>();
            foreach (BattleAreaEffectSnapshot area in snapshot.AreaEffects)
            {
                areaIds.Add(area.AreaEffectId);
                GameObject value = GetOrCreateArea(area.AreaEffectId);
                value.transform.position = ToUnity(area.CenterWorld);
            }
            RemoveMissing(areas, areaIds);
        }

        /// <summary>按 Server seq 顺序应用一个 Event；未知类型只记录，不自行猜规则。</summary>
        public void ApplyEvent(BattleEvent value)
        {
            switch (value.Type)
            {
                case "UNIT_SPAWN":
                    GetOrCreateUnit(value.UnitId, value.Position);
                    break;
                case "MOVE_PATH":
                    BeginMove(value);
                    break;
                case "MOVE_STOPPED":
                case "MOVE_REJECTED":
                    StopMove(value.UnitId, value.Position);
                    break;
                case "PROJECTILE_LAUNCHED":
                    GetOrCreateProjectile(value.ProjectileId).transform.position =
                        ToUnity(value.Position);
                    break;
                case "PROJECTILE_MOVED":
                    if (projectiles.TryGetValue(value.ProjectileId, out var projectile))
                        projectile.transform.position = ToUnity(value.Position);
                    break;
                case "PROJECTILE_IMPACT":
                case "PROJECTILE_EXPIRED":
                    DestroyAndRemove(projectiles, value.ProjectileId);
                    break;
                case "AREA_CREATED":
                    GetOrCreateArea(value.AreaEffectId).transform.position = ToUnity(value.Position);
                    break;
                case "AREA_EXPIRED":
                    DestroyAndRemove(areas, value.AreaEffectId);
                    break;
                case "DAMAGE":
                    Debug.Log($"DAMAGE target={value.UnitId} damage={value.Damage} hp={value.TargetHp}");
                    break;
                case "BUFF_ADDED":
                case "BUFF_REFRESHED":
                case "BUFF_REMOVED":
                    Debug.Log($"{value.Type} unit={value.UnitId} buff={value.BuffId} stack={value.StackCount}");
                    break;
                case "UNIT_DEAD":
                    moves.Remove(value.UnitId);
                    DestroyAndRemove(units, value.UnitId);
                    break;
                case "BATTLE_END":
                    moves.Clear();
                    Debug.Log("BATTLE_END result=" + value.Result);
                    break;
                case "SKILL_CAST":
                case "CAST_REJECTED":
                case "AREA_PULSE":
                case "TARGET_CHANGED":
                    Debug.Log($"{value.Type} unit={value.UnitId} skill={value.SkillId} reason={value.Reason}");
                    break;
                default:
                    Debug.LogWarning("Unknown BattleEvent type=" + value.Type);
                    break;
            }
        }

        /// <summary>只推进 Unity 表现插值；Server Snapshot/Event 随时可以覆盖本地显示。</summary>
        private void Update()
        {
            float dt = Time.deltaTime;
            foreach (var pair in moves)
            {
                if (!units.TryGetValue(pair.Key, out var unit)) continue;
                MoveState move = pair.Value;
                float remaining = move.speedMetersPerSecond * dt;
                while (remaining > 0f && move.nextPoint < move.points.Count)
                {
                    Vector3 target = move.points[move.nextPoint];
                    float distance = Vector3.Distance(unit.transform.position, target);
                    if (distance <= remaining || distance <= 0.0001f)
                    {
                        unit.transform.position = target;
                        remaining -= distance;
                        ++move.nextPoint;
                    }
                    else
                    {
                        unit.transform.position = Vector3.MoveTowards(
                            unit.transform.position, target, remaining);
                        remaining = 0f;
                    }
                }
            }
        }

        private void BeginMove(BattleEvent value)
        {
            if (!units.TryGetValue(value.UnitId, out var unit) || value.Points.Count == 0)
                return;
            var state = new MoveState
            {
                nextPoint = value.Points.Count > 1 ? 1 : value.Points.Count,
                speedMetersPerSecond = value.SpeedMmPerSec / 1000f,
            };
            foreach (WorldPosition point in value.Points) state.points.Add(ToUnity(point));
            unit.transform.position = state.points[0];
            moves[value.UnitId] = state;
        }

        private void StopMove(uint unitId, WorldPosition position)
        {
            moves.Remove(unitId);
            if (position != null && units.TryGetValue(unitId, out var value))
                value.transform.position = ToUnity(position);
        }

        private GameObject GetOrCreateUnit(uint id, WorldPosition position)
        {
            if (units.TryGetValue(id, out var value)) return value;
            value = GameObject.CreatePrimitive(PrimitiveType.Capsule);
            value.name = "BattleUnit_" + id;
            if (position != null) value.transform.position = ToUnity(position);
            units.Add(id, value);
            return value;
        }

        private GameObject GetOrCreateProjectile(uint id)
        {
            if (projectiles.TryGetValue(id, out var value)) return value;
            value = GameObject.CreatePrimitive(PrimitiveType.Sphere);
            value.name = "Projectile_" + id;
            value.transform.localScale = Vector3.one * 0.35f;
            projectiles.Add(id, value);
            return value;
        }

        private GameObject GetOrCreateArea(uint id)
        {
            if (areas.TryGetValue(id, out var value)) return value;
            value = GameObject.CreatePrimitive(PrimitiveType.Cube);
            value.name = "AreaEffect_" + id;
            value.transform.localScale = new Vector3(6f, 0.1f, 1.2f);
            areas.Add(id, value);
            return value;
        }

        private static Vector3 ToUnity(WorldPosition value)
        {
            if (value == null) return Vector3.zero;
            return new Vector3(
                value.XMm / 1000f,
                value.YMm / 1000f,
                value.ZMm / 1000f);
        }

        private static void DestroyAndRemove(
            Dictionary<uint, GameObject> values,
            uint id)
        {
            if (!values.TryGetValue(id, out var value)) return;
            Destroy(value);
            values.Remove(id);
        }

        private static void RemoveMissing(
            Dictionary<uint, GameObject> values,
            HashSet<uint> keep)
        {
            var remove = new List<uint>();
            foreach (var pair in values)
                if (!keep.Contains(pair.Key)) remove.Add(pair.Key);
            foreach (uint id in remove) DestroyAndRemove(values, id);
        }

        private void OnDestroy()
        {
            foreach (var pair in units) Destroy(pair.Value);
            foreach (var pair in projectiles) Destroy(pair.Value);
            foreach (var pair in areas) Destroy(pair.Value);
            units.Clear();
            projectiles.Clear();
            areas.Clear();
            moves.Clear();
        }
    }
}
```

`FireWall` 的 Cube 尺寸目前写死为课程定义的 6m×1.2m。如果以后 SkillDefinition 数值需要客户端准确显示，可以把 half_long/half_thick 追加到 `AREA_CREATED` Event；不要让 Client 自己读取另一份可能漂移的 Skill 配置后假定和 Server 一样。

---


## 49. Unity 表现模型

在线显示仍然坚持和第二课 Replay 相同的原则：

```text
Server Event/Snapshot = 权威事实
Unity GameObject       = 只读投影
```

至少处理：

```text
MOVE_PATH / MOVE_STOPPED
SKILL_CAST
PROJECTILE_LAUNCHED
PROJECTILE_MOVED
PROJECTILE_IMPACT / PROJECTILE_EXPIRED
AREA_CREATED / AREA_PULSE / AREA_EXPIRED
BUFF_ADDED / BUFF_REFRESHED / BUFF_REMOVED
DAMAGE
UNIT_DEAD
BATTLE_END
```

建议新建：

```text
unity/BattleNavigation/Assets/BattleNavigation/client/InteractiveBattleView.cs
```

它只保存：

```text
unit_id -> GameObject
projectile_id -> Debug Sphere
area_effect_id -> Debug Cube
unit_id -> 当前 MOVE_PATH 表现状态
```

Snapshot 到来时：

```text
直接把 Unit 显示位置/HP 校正到 Snapshot
清理 Snapshot 中已经不存在的逻辑 Projectile/AreaEffect
```

Event 到来时：

```text
MOVE_PATH            -> 开始/替换本地折线插值
MOVE_STOPPED         -> 停止并校正到 Server position
PROJECTILE_LAUNCHED  -> 创建 Sphere
PROJECTILE_MOVED     -> 校正逻辑弹丸位置
PROJECTILE_IMPACT    -> 删除 Sphere + 播放简单命中特效
AREA_CREATED         -> 创建半透明 Cube 表示 FireWall
AREA_EXPIRED         -> 删除 Cube
BUFF_*               -> Console/头顶文字显示即可
DAMAGE               -> 更新 HP 文本
UNIT_DEAD            -> 销毁/隐藏 Unit
```

表现型 Fireball 可以在 `PROJECTILE_LAUNCHED -> PROJECTILE_IMPACT` 之间用 Unity 插值飞向目标；它的轨迹只是表现。FrostBolt 则优先消费 Server 的 `PROJECTILE_MOVED` 做校正，不能让客户端自己的碰撞结果覆盖 Server。

为了保持第三课边界，不要求：

```text
Animator Controller
复杂 VFX
血条 UI 框架
对象池框架
客户端预测/回滚
```

基础 Capsule / Sphere / Cube 已经足够验证权威链路。

# 第十七部分：确定性——在线模式和自动模式必须共享同一个 Core

## 50. 什么叫“同一个 Core”

自动：

```text
snapshot
+ recorded commands(apply_tick)
-> create
-> step
-> step
-> step
-> finish
```

在线：

```text
snapshot
-> create
-> 收到 command，Server 标记 apply_tick
-> heartbeat step
-> heartbeat step
-> ...
-> finish
```

真正参与规则的：

```text
apply_tick
command contents
snapshot/version/seed
```

不参与规则的：

```text
Unity frame rate
网络 RTT
Server 实际每个 Tick 花多少微秒
```

### 50.1 在线录制 Command Stream

为了 Regression，Worker/测试可以记录：

```lua
{
    apply_tick = 12,
    unit_id = 1001,
    command_seq = 1,
    kind = "MOVE",
    target_world = { x_mm = 1000, y_mm = 0, z_mm = 2000 },
}
```

然后把同一份：

```text
initial snapshot + recorded command stream
```

交给 batch driver。

必须得到相同逻辑 Event 序列。

### 50.2 新的确定性输入身份

第三课：

```text
battle_version
map_id
map_version
air_map_version
skill_version
input snapshot
recorded commands + apply_tick
seed
```

得到同样：

```text
ordered BattleEvent
final Snapshot
```

## 51. 不使用浮点 Battle 规则

本课继续：

```text
位置 mm integer
Tick integer
Cooldown Tick integer
Buff duration Tick integer
Projectile progress mm integer
Damage integer
```

Unity interpolation 可以 float，因为它是表现。

# 第十八部分：Skynet 故障路径和调试

## 52. Worker 失败怎么处理

本课不做 Worker 自动恢复和 Battle 持久化。

但错误必须可观察：

```text
BattleMgr pcall(skynet.call)
-> Worker Service 已退出/地址失效
-> WORKER_UNAVAILABLE
-> battle_dispatch 映射稳定业务错误
-> Gateway 返回失败，不伪装成功
```

这符合课程边界：

```text
恢复/持久化
-> 后续 Server 工程专题
```

不能因为暂时不恢复，就吞掉错误。

## 53. 核心异常与 Service crash 分开

可预期 Battle 输入错误：

```text
return nil,{code,message}
```

Battle Core 编程错误：

```text
xpcall
-> 当前 Battle 失败
-> Context close
-> 记录 traceback
```

真正 Worker Service 自己 dispatch 外的严重错误可能导致 Service 退出。

三层不要混成一个 `pcall` 把所有 bug 吞掉。

## 54. 开发环境启动 debug_console

在 `battle_main.lua` composition root 中，读取：

```lua
local battle_config = require "config.battle"
```

在业务 Service READY 后：

```lua
if battle_config.debug_console_port > 0 then
    skynet.newservice("debug_console", battle_config.debug_console_port)
end
```

默认 `debug_console` 只用于本地开发。

不要直接暴露公网。

### 54.1 实际命令

```bash
telnet 127.0.0.1 8001
```

常用：

```text
list
stat
mem
task <service address>
info <service address>
ping <service address>
call <service address> "stats", {}
```

固定源码：

```text
third_party/skynet/service/debug_console.lua
```

### 54.2 Worker stats 应该观察什么

```text
worker_index
battle_count
service_mqlen
now_cs
next_heartbeat_cs
```

进一步 benchmark 时再增加：

```text
tick cost
max tick cost
command queue size
event buffer size
```

不要在第一版就接完整 Prometheus 系统。

### 54.3 用 `debug_console` 真正观察 Shard，而不是只知道命令名字

启动第三课 Battle Process 后：

```bash
telnet 127.0.0.1 8001
```

先：

```text
list
```

找到：

```text
battle/battle_mgr
多个 battle/battle_worker
battle_dispatch
navigation_query
```

对 Manager：

```text
call <manager-address> "stats", {}
```

预期结构类似：

```text
worker_count:4
workers:table
```

然后逐个 Worker：

```text
call <worker-address> "stats", {}
```

观察：

```text
worker_index
active_battles
retained_finished
service_mqlen
next_heartbeat_cs
```

做一次有意的 Shard 验证：连续创建 8 场 Battle，记录 `battle_id` 和 Start 响应中的 `worker_index`，手算：

```text
worker_index = battle_id % 4 + 1
```

必须全部一致。这里 `worker_index` 只用于课程观察；Client 不能据此直接绕过 Manager 调 Worker。

再用：

```text
stat
mem
task <worker-address>
```

如果 `service_mqlen` 持续上涨：

```text
先看 heartbeat 单次推进成本
再看 Sync/Command 请求频率
再看是否有 batch simulate 与 online 共用一个 Worker 抢 CPU
```

不要第一反应就把 `worker_count` 从 4 改成 64。先用证据判断瓶颈来自 CPU、消息队列、Native A* 还是 Event 编码。

---

# 第十九部分：测试——先证明边界，再看“能不能玩”

## 55. Command Tests

至少覆盖：

```text
command_seq 正常递增
重复 seq 拒绝
更小 seq 拒绝
不存在 unit 拒绝
死亡 unit command 拒绝
错误 connection_id 拒绝
Gateway Service 重启后相同数字 connection_id 不能取得旧 Battle 控制权
错误 resume_token / 不存在 Battle 的 Resume 都返回 NOT_CONTROLLER
正确 resume_token 可把控制权交给新连接，旧连接随后拒绝
Submit Ack 丢失后，Resume Snapshot 的 last_accepted_command_seq 可消除重复提交歧义
command queue 满明确拒绝
非法 WorldPosition 拒绝
未知 skill_id 拒绝
```

## 56. Worker Shard Tests

固定：

```text
worker_count = 4
```

构造：

```text
battle 70001
70002
70003
70004
70005
70006
70007
70008
```

验证：

```text
每个 battle_id 的 worker_index = battle_id % 4 + 1
同一个 Battle 的 create/command/sync/stop 永远命中相同 Worker
每个 Worker 可以同时持有多场 Battle
不同 Battle 的 NavigationContext / Buff / Projectile 不串状态
```

## 57. Ground / Air Tests

```text
GroundEnemy 不能走过 Ground blocked
FlyingEnemy 可以飞过 Ground blocked
FlyingEnemy 不能穿 NoFly
FlyingEnemy worldY 始终 = sampled groundHeight + flightHeight
Ground-only Slash 不能命中 FlyingEnemy
FireWall 不影响 FlyingEnemy
Fireball 可以命中 Ground/Air
```

### 57.1 `Battle_AirCombat_Golden`：两只 Flying Dragon 真实验证 Air -> Air

不要只靠 `target_mask = TARGET_ALL` 推断“理论上支持空对空”。增加一个最小 Golden Snapshot，让两只 Air Unit 真正互相选中、寻路、施法和死亡。

场景只需要：

```text
FlyingDragon_A
  id = 3101
  camp = 1
  movement_layer = AIR
  target_layer = TARGET_AIR
  ai_kind = FLYING_ENEMY
  flight_height_mm = 2500
  skill = Fireball(1002)

FlyingDragon_B
  id = 3201
  camp = 2
  movement_layer = AIR
  target_layer = TARGET_AIR
  ai_kind = FLYING_ENEMY
  flight_height_mm = 3000
  skill = Fireball(1002)
```

为了同时验证 Air Navigation，把两只 Dragon 放在 NoFly 区域两侧，初始距离大于 Fireball range。测试必须证明：

```text
[ ] 两只 Dragon 都只使用 Air Grid，不进入 Ground DynamicOccupancy
[ ] 两者都能把另一只 Air Unit 选为合法 target
[ ] 接近过程绕开 NoFly
[ ] worldY 分别保持 groundHeight + 自己的 flight_height_mm
[ ] 进入 Fireball range 后产生 CastIntent(1002)
[ ] SkillRuntime 的 TARGET_ALL 接受 Air target
[ ] PROJECTILE_LAUNCHED / IMPACT / DAMAGE 顺序稳定
[ ] HP 到 0 时产生一次 UNIT_DEAD
[ ] 相同 snapshot / versions / seed 重跑得到相同有序 Event
```

这个 Case 的目的不是增加“飞龙系统”，而是给现有 Air Unit + TargetMask + Fireball + AI 四个模块增加一条真正的交叉证据。

Golden 回归通过后，若要做第 69.2 节 Unity 人工回放，在同一测试入口的模拟结束并关闭 Context 后，调用第 41.6 节 `battle_replay_file.start(replay_config.descriptor_path)` 与 `battle_replay_file.write("tmp/air_combat.breplay", result)`，回读并核对 `battle_id/map_version/air_map_version/events`，再把这个文件交给 Unity Replay Player。`result` 必须是 `battle_core.simulate()` 的完整 batch 结果；不能把在线 Event ring 当作完整 Replay。该 BRPL 仅作测试产物，不进入线上 Gateway frame。

建议在现有 Battle Core 回归入口中构造独立 Snapshot，例如：

```lua
local function air_combat_snapshot()
    return {
        battle_id = 73001,
        battle_version = 3,
        map_id = 1001,
        map_version = 2,
        air_map_version = 2,
        seed = 73001,
        tick_ms = 50,
        max_ticks = 2000,
        units = {
            {
                id = 3101, camp = 1, control = "AI", ai_kind = "FLYING_ENEMY",
                movement_layer = "AIR", flight_height_mm = 2500,
                base_move_speed_mm_per_sec = 2600, hp = 96,
                position = { x_mm = -12000, y_mm = 2500, z_mm = 0 },
            },
            {
                id = 3201, camp = 2, control = "AI", ai_kind = "FLYING_ENEMY",
                movement_layer = "AIR", flight_height_mm = 3000,
                base_move_speed_mm_per_sec = 2400, hp = 96,
                position = { x_mm = 12000, y_mm = 3000, z_mm = 0 },
            },
        },
    }
end
```

这里的 Y 只是 Snapshot 输入值；`create/place/air movement` 后仍必须由 Server 按对应 XZ 的 Ground Height + Flight Height 归一，测试不要把示例初始 Y 当成最终权威高度。

### 57.2 混合目标 Golden：同一只 Flying Dragon 可以 Air -> Ground，也可以 Air -> Air

再构造一个很小的混合目标测试：

```text
FlyingDragon_A camp=1 AIR Fireball
GroundEnemy_B  camp=2 GROUND
FlyingDragon_C camp=2 AIR
```

验证 TargetMask 与稳定目标选择，而不是强行规定某种“职业仇恨规则”：

```text
[ ] GroundEnemy_B 和 FlyingDragon_C 都是 Fireball 合法目标
[ ] AI 按当前最近距离 + unit.id tie-break 稳定选择其中一个
[ ] 把 GroundEnemy_B 放近时，真实跑通 Air -> Ground
[ ] 把 FlyingDragon_C 放近时，真实跑通 Air -> Air
[ ] GroundEnemy 的 Slash 目标筛选不会选择 FlyingDragon_A
[ ] SkillRuntime 仍执行第二次 TargetMask 权威校验，不能只相信 AI
```

这两个测试完成后，才能把“第三课支持空中飞龙攻击地面或其它飞龙”写成工程已经证明的能力，而不是只看 Definition 推断。

## 58. Skill Tests

### Instant

```text
range 内命中
range 外拒绝
CD 内拒绝
伤害 / death event 顺序稳定
```

### Presentation Projectile

```text
launch_tick 稳定
impact_tick 稳定
不生成逐 Tick projectile movement
目标在 impact 前死亡时不重复 Damage
```

### Logic Projectile

```text
substep 不 tunneling
第一个合法单位拦截
TargetMask 生效
命中后销毁
超 range 销毁
Slow 正确附加
```

### FireWall

```text
创建范围正确
X_AXIS / Z_AXIS
只影响 Ground
pulse interval 稳定
expire 后不再伤害
caster 死亡后按本课规则继续存在
Burning reapply/stack 上限稳定
```

## 59. Buff Tests

```text
Haste +30%
Slow -40%
Haste + Slow -> 90% base（本课 additive permille 规则）
expire tick 边界
refresh
Burning stack 1/2/3
Burning 不超过 3
Burning periodic damage
死亡后不再继续执行 Unit Buff tick
```

## 60. Event / Snapshot Tests

```text
断线时 Server 继续 fixed tick；Resume 返回即时 Snapshot 与 last_event_seq
Client 在 Resume 后以 Snapshot 为锚点继续拉 Event，不重复应用断线前的 Event
事件 ring 覆盖后 Sync 的 event_gap 仍返回即时 Snapshot
finished Runtime 保留期内可 Resume；回收后必须拒绝
seq 连续
logic_tick / logic_ms 不倒退
Event ring overflow 后 first_seq 正确
客户端 after_seq 太旧 -> event_gap=true
Event gap 时返回 Snapshot
Snapshot 不包含 userdata/GridPos/Service handle
```


### 60.1 BRPL / Protobuf Replay Tests

第三课正式 Replay 迁移以后，测试对象不能只看 `pb.decode()` 成功。至少覆盖：

```text
valid round-trip
bad magic
unsupported BRPL version
wrong header_size
payload_size smaller/larger than file
truncated payload
trailing bytes
CRC mismatch
BattleReplay.replay_format_version mismatch
Proto payload corruption
16 MiB payload limit
```

Round-trip 还必须比较：

```text
battle/map/air-map/skill versions
seed
end_logic_tick / end_logic_ms
Event count / seq / type / logic_tick / logic_ms
最终 Snapshot 的 last_event_seq / HP / position / Buff / Projectile / AreaEffect
```

同一份 `battle_core.finish()` 结果重复两次编码，在固定 lua-protobuf/Proto Schema 版本下应得到相同 payload bytes；如果未来更换 Protobuf runtime，不把“不同版本 encoder 必须 bit-for-bit 完全相同”当跨版本长期合同，但语义解码结果必须一致。

Unity EditMode Test 使用 Server 生成的一份小 Golden `.breplay`，验证：

```text
BattleReplayFile.Parse() 成功
篡改 Header -> 拒绝
翻转 payload 1 byte -> CRC 拒绝
截断 1 byte -> size 拒绝
BattleReplayPlayer 消费生成 Proto Event，不经过 JsonUtility
```

JSON Debug Export 若保留，不进入这组正式 Replay compatibility test。

## 61. 在线 / Batch Determinism

固定：

```text
snapshot
recorded command stream
apply_tick
versions
seed
```

运行：

```text
A. online driver 的逻辑 step 模拟
B. batch 快速 simulate
```

比较：

```text
Event type
seq
logic_tick
source/target
skill/projectile/area/buff id
Damage/HP
final unit positions
final HP
Battle result
```

必须一致。

### 61.1 把“在线/Batch 一致”写成真正的测试入口

只写“比较 Event”还不够。第三课建议在 `batch_runner.lua` 中增加一个 helper，把 Online Driver 在**不等待墙钟**的情况下模拟出来：仍然调用同一个 Core `step()`，只是按照 recorded command 的 `apply_tick` 在 Tick 边界入队。

核心测试思想：

```text
Path A：batch_core(snapshot + recorded_commands)
Path B：create(mode=online-test)
        每 Tick 前注入 apply_tick==next_tick 的同一命令
        step()
        drain_events()
```

两条路径都不需要真实 Socket，因此能单独证明“online/batch 规则只有一套”。

比较函数必须递归检查：

```text
Event seq/type/logic_tick/logic_ms
unit/source/target/skill/projectile/area/buff id
position/points
Damage/HP
final Snapshot units/buffs/projectiles/areas
Battle result
```

不比较：

```text
Worker address
wall clock
Gateway connection_id
调试 worker_index
CPU elapsed time
```

如果比较失败，打印**第一条不同 Event 的 seq 和两个 record**，不要只打印 `determinism failed`。

---

### 61.2 Command 顺序测试：专门证明 yield 不会把半步状态暴露出去

构造：

```text
BattleWorker heartbeat 正在运行
Client A 连续 Submit seq=1,2,3
Sync 在中间穿插
```

要证明的不是“消息到达顺序永远等于网络发送顺序”，而是：

```text
Worker 接收每条 Command 时只做有界 enqueue，不推进半个 Battle；
真正状态变更只在完整 no-yield step 内发生；
Sync 要么看到 step 前状态，要么看到 step 后状态，不会看到：
  Unit 已移动但 Projectile 尚未推进
  HP 已扣但 UNIT_DEAD 尚未释放 Ground Occupancy
```

实现测试时可以给 `battle_core.step()` 的测试版 callback 记录 phase marker，但不要为了测试在生产 Core 中加入 `skynet.sleep()`。用同步 hook/纯 Lua instrumentation 验证 phase 即可。

---


## 62. Native Concurrency

至少启动多个 BattleWorker Service，同时：

```text
shared immutable GridMap
shared immutable AirMap
independent NavigationContext
Ground A*
Air A*
```

重复大量 Query。

重点证明：

```text
没有 global mutable scratch
没有 query race
结果稳定
```

## 63. 性能测试

本课不是追求漂亮 QPS 数字，而是建立可解释条件。

记录：

```text
CPU
Skynet thread count
BattleWorker count
active battles / worker
units / battle
tick_ms
AI 数量
Ground A* 次数
Air A* 次数
logic projectile 数
AreaEffect 数
Buff 数
每 Tick p50/p95/p99 CPU cost
Worker mailbox length
Lua memory
Native Context memory
```

重点检查：

```text
p99 Tick cost 是否接近/超过 50ms
worker_count 增加后是否改善
Native 查询是否成为热点
Event/Snapshot 是否造成大量分配
```

不要把 Unity 渲染耗时算进 Server Battle Tick benchmark。

### 63.1 Worker Shard Benchmark 应该怎样测才有意义

至少固定两类 workload：

```text
A. 轻战斗
  3 units
  几乎不重寻路
  少量 Skill/Projectile

B. 重战斗
  32 units
  Ground/Air 混合
  较高 repath
  多 Logic Projectile/FireWall/Buff
```

对每类分别测：

```text
1 Worker x N Battles
2 Workers x N Battles
4 Workers x N Battles
8 Workers x N Battles
```

同时固定 Skynet：

```text
thread=4
```

然后再固定 Worker=4，改变：

```text
thread=1/2/4/8
```

这样你才能回答两个不同问题：

```text
增加 BattleWorker Shard 是否减少单 Service mailbox/单 Lua State 热点？
增加 Skynet OS Worker Thread 是否真的给多个 Service 更多 CPU 并行度？
```

这也能实际证明：

> BattleWorker 数量与 Skynet `thread` 数不是一回事。

记录模板：

```text
CPU: <型号>
Build: Release -O2
Skynet: v1.8.0 thread=4
BattleWorkers: 4
Battles/Worker: 1/8/32/64
Units/Battle: 3 or 32
Tick: 50ms
Duration: 60s logical / batch equivalent

worker tick cost p50/p95/p99/max
worker service mqlen p95/max
Ground A* count/query p95
Air A* count/query p95
logic projectiles peak
area effects peak
Lua memory before/after
Native context estimated bytes
missed heartbeat / catchup count
```

课程不要求给一个“商业标准 QPS”。硬件、地图和战斗复杂度不同，脱离条件的数字没有价值。

---

### 63.2 Event Ring 的压力与 Gap 测试

把测试配置临时改成：

```text
max_events_buffered = 8
```

让一场 Battle 连续产生 >20 个 Event，然后：

```text
Client after_event_seq = 0
```

预期：

```text
event_gap = true
first_available_seq > 1
snapshot != nil
snapshot.last_event_seq == latest_event_seq
```

Client 行为必须是：

```text
丢弃自己尚未应用的旧增量假设
ApplySnapshot(snapshot)
after_event_seq = snapshot.last_event_seq
下一次 Sync 从新基线继续
```

禁止：

```text
先应用 ring 中残留的 Event
再套 Snapshot
```

否则同一 Damage/Death/Projectile 可能在表现层重复一次。

---

### 63.3 资源上限故障注入表

第三课“商业级边界”不等于功能多，而是达到上限时行为明确。至少手工/自动验证：

| 资源 | 上限来源 | 到达上限 | 预期行为 |
|---|---|---|---|
| 每 Worker 活跃 Battle | `max_battles_per_worker` | Start | `BUSY/WORKER_BUSY`，不创建半个 Context |
| 单 Battle Command queue | `max_commands_per_battle` | Submit | `COMMAND_QUEUE_FULL` |
| Online Event ring | `max_events_buffered` | Tick | 覆盖最旧，后续旧 seq 得到 `event_gap` |
| 每次 Sync Event 数 | `max_events_per_sync` | Sync | 最多返回 N 条，Client 下一轮继续 |
| Logic Projectile | SkillRuntime 常量 | Cast | `PROJECTILE_LIMIT`，不吃 CD |
| AreaEffect | SkillRuntime 常量 | Cast | `AREA_LIMIT`，不吃 CD |
| Batch Event | `MAX_BATCH_EVENTS` | simulate | 当前 Battle 失败并 close Context |
| Battle Tick | `max_ticks` | Tick | `TIMEOUT` + `BATTLE_END` |
| Finished 保留 | `max_finished_retained` | cleanup | 优先回收最旧 finished Runtime |

每一项都要检查：

```text
拒绝后 owner 状态是否仍一致
有没有 Context/Path/连接泄漏
有没有错误地提交 cooldown
有没有吞掉错误只写日志
```

---

# 第二十部分：完整构建与运行顺序

## 64. 不要边写边启动最终场景

建议严格按以下 Stage：

```text
Stage 1  BattleMgr stable shard
Stage 2  Multi-Battle Worker + heartbeat
Stage 3  PlayerCommand queue
Stage 4  Event/Snapshot online delta
Stage 5  AirMap / Air A*
Stage 6  Ground/Flying AI
Stage 7  Skill Runtime
Stage 8  Logic Projectile
Stage 9  FireWall（可选扩展；主课验收后再做）
Stage 10 Buff（可选扩展；主课验收后再做）
Stage 11 Proto / battle_dispatch
Stage 12 BRPL + Protobuf Replay migration（可选扩展；主课可沿用第二课 Replay）
Stage 13 Unity Interactive Client / Replay Player
Stage 14 Determinism / Replay Corruption / Concurrency / Benchmark
```

每 Stage 完成：

```text
build
focused test
故障注入
再进入下一 Stage
```

## 65. Native 构建

Navigation Native 源码位于：

```text
server/third_party/skynet-flywow/navigation/native/
```

不要在课程仓库创建 server/native 副本。新增 AirMap/AirPathfinder 文件时，更新 FlyWow Navigation 的 CMake：

```text
server/third_party/skynet-flywow/navigation/native/grid_map/CMakeLists.txt
server/third_party/skynet-flywow/navigation/native/CMakeLists.txt
```

从 server/ 唯一公开构建入口运行：

```bash
./scripts/linux/run_server.sh build
```

该入口调用 FlyWow 统一构建脚本，构建 Navigation Native、运行对应 CTest，并检查 third_party/skynet-flywow/build/native/flywow_navigation_native.so。不要运行旧的 server/native/grid_map/make_test.sh、server/native/lua_battle_nav/make.sh，也不要把 battle_nav.so 当作产物。

需要检查导出符号时，可在 WSL 运行：

```bash
nm -C third_party/skynet-flywow/build/native/flywow_navigation_native.so |
  grep -E 'AirMap|AirGridPathfinder'
```

nm 只用于诊断；CTest 和 Skynet Lua Smoke 分别验证 Native 行为与真实 Lua ABI 加载。

## 66. 协议生成

从仓库根：

```bash
./server/protocol/build_server_descriptor.sh
```

Server：

```bash
cd server
./scripts/linux/run_server.sh build
```

Windows：

```powershell
./shared/protocol/build_unity_cs.ps1
```

## 67. Batch Regression

第二课入口继续保留。

第三课增加带 Command Stream 的 regression 输入。

期望：

```text
BATTLE_DETERMINISM_OK
BATTLE_SKILL_REGRESSION_OK
AIR_NAVIGATION_OK
ALL_TESTS_OK
```

这些输出名字是第三课验收标记，不应成为运行时代码分支条件。

### 67.1 第三课建议新增的 Server 验收日志

不要依赖几十条随手 `print`。只保留少量稳定成功标记：

```text
AIR_NAVIGATION_OK
BATTLE_SKILL_REGRESSION_OK
BATTLE_ONLINE_BATCH_DETERMINISM_OK
BATTLE_SHARD_ROUTING_OK
BATTLE_GATEWAY_INTERACTIVE_OK
```

它们只用于课程脚本/人工验收，不作为 Runtime 分支条件。

日志中出现这些标记前，必须分别已经完成：

```text
AIR_NAVIGATION_OK
  -> Reader corruption + Air A* golden + Ground/Air scratch isolation

BATTLE_SKILL_REGRESSION_OK
  -> Instant/Presentation/Logic/FireWall/Buff 正常和失败路径

BATTLE_ONLINE_BATCH_DETERMINISM_OK
  -> 同 snapshot/commands/versions/seed Event+Final Snapshot 一致

BATTLE_SHARD_ROUTING_OK
  -> 多 battle_id 稳定命中 mod shard，Worker 内确实多 Battle 共存

BATTLE_GATEWAY_INTERACTIVE_OK
  -> Unity/FlyWow/cluster/dispatch/Manager/Worker 完整链能 Start/Command/Sync/Stop/Resume
  -> 断线、Ack 丢失、错误凭据、Gateway 重启后数字连接号重用均有负向验证
```

---


## 68. 双进程启动

沿用第二课：

```bash
cd server
./scripts/linux/run_server.sh doctor
./scripts/linux/run_server.sh start
./scripts/linux/run_server.sh status
```

脚本文件名虽然仍叫 `lesson2_processes.sh`，运行拓扑已经是课程公共双进程基线。第三课不要为了名字好看复制一份功能相同的 `run_lesson3_processes.sh`。

如果后续脚本职责真的扩大，再单独重命名并同步文档；当前先避免重复运维脚本。

## 69. Unity 验收

启动：

```text
Battle_1001 Scene
InteractiveBattleController
```

依次验证：

```text
Start Battle
Player Move
GroundEnemy 追击
FlyingEnemy 绕 NoFly
Slash
Fireball
FrostBolt（Server 权威轨迹/碰撞）
HP / Death
Event/Snapshot Sync
Battle End
```

然后故意暂停 Unity Sync 超过 Event ring 可覆盖窗口，恢复后必须：

```text
event_gap=true
-> Snapshot 校正
-> 继续消费后续 Event
```

这一步非常重要，因为它真正证明 Snapshot 不是“为了字段齐全而存在”。FireWall、AreaEffect、Buff/Slow/Haste 属于可选扩展，不作为第三课主线验收门槛。

### 69.1 Unity 最终人工验收脚本

不要只“玩一下感觉能动”。按固定步骤执行，任何一步失败先停在当前层排查：

```text
A. 启动 Battle Process + Gateway Process
   -> 日志必须看到 LESSON3_BATTLE_PROCESS_READY / Gateway READY

B. Unity StartInteractiveBattle
   -> 得到 battle_id + Snapshot
   -> 三个 Unit 出现，FlyingEnemy Y 高于地表

C. 右键移动 Player
   -> Submit ACK 有 apply_tick
   -> 后续 Sync 出现 MOVE_PATH
   -> Player 沿 Server points 插值

D. 观察 GroundEnemy
   -> 自己产生 AI intent
   -> Ground A* 绕静态障碍
   -> 进入 Slash 范围后 Damage

E. 观察 FlyingEnemy
   -> 可以跨普通 Ground blocked
   -> 遇到 NoFly 必须绕开
   -> Y 维持 GroundHeight + FlightHeight 规则
   -> 默认混合场景中 Fireball 可以命中 Ground Player/Enemy

F. 按 1 Slash
   -> 对 FlyingEnemy 必须被 TargetMask 拒绝
   -> 对 GroundEnemy 在 range 内才成功

G. 按 2 Fireball
   -> PROJECTILE_LAUNCHED
   -> 中间无 Server PROJECTILE_MOVED
   -> 固定 impact tick 出 DAMAGE/IMPACT

H. 按 3 FrostBolt
   -> Server 连续 PROJECTILE_MOVED
   -> 命中后 Slow
   -> Player/Enemy 有 Slow 时移动速度改变但旧 Path 不重算

I. 暂停 Sync 足够久让 Event ring 溢出
   -> event_gap=true
   -> Snapshot 校正
   -> 之后 Event seq 连续

J. 让一方全部死亡
   -> UNIT_DEAD
   -> BATTLE_END
   -> 最终 Sync 可拿到结果
   -> retention 到期后 Runtime 被回收
```

每个步骤都能对应到 Server 中一个明确 owner 和日志/测试层。这样联调出错时不会变成“Unity 看起来不对，不知道是网络、AI、Skill 还是表现”。

### 69.2 AirCombat 回放人工验收：Flying Dragon 对 Flying Dragon

默认 `Battle_1001` 保持三单位最小场景，不为了一个验收点把主场景继续膨胀。第 57.1 节的 AirCombat Golden 输入由 Server Batch 模拟并写成 BRPL；Unity 用同一 Replay Player 打开该产物验证表现。在线 `StartInteractiveBattle` 当前只允许 `scenario_id=1001`，所以本节不能要求它启动一个不存在的第二场景。

```text
FlyingDragon_A camp=1 AIR
FlyingDragon_B camp=2 AIR
中间存在 NoFly 区域
双方只使用 Fireball
```

Unity 复用 `BattleReplayPlayer` 和 Unit View，按下面顺序看证据：

```text
A. 加载第 57.1 节 Golden 模拟得到的 BRPL
   -> Snapshot 中两只 Unit 的 movement_layer 都是 AIR

B. 两只 Dragon 相互接近
   -> Server Event 的 Path 绕开 NoFly
   -> Unity 只按 Server Event 插值

C. 进入 Fireball range
   -> 两边都出现 PROJECTILE_LAUNCHED
   -> target_id 指向另一只 Air Unit

D. Impact
   -> Server 产生 DAMAGE
   -> Unity 不重新判定碰撞/伤害

E. 一只 Dragon HP 归零
   -> 只出现一次 UNIT_DEAD
   -> Battle 结束规则按 Server state 执行
```

如果 Air -> Ground 能跑，而这里 Air -> Air 失败，优先按这个顺序排查：

```text
Unit.target_layer 是否真的是 TARGET_AIR
-> Fireball.target_mask 是否仍是 TARGET_ALL
-> ai_runtime.choose_enemy 是否按 skill TargetMask 过滤
-> SkillRuntime 是否再次校验 TargetMask
-> Projectile impact 是否错误地只扫描 Ground Unit
```

这条人工验收与 57.1 的自动 Golden Test 是同一能力的两种证据：自动测试负责稳定回归，Unity 负责确认客户端表现没有偷偷把 Air target 当成 Ground 特例。

---

# 第二十一部分：Skynet 源码阅读点——只读本课真正用到的

## 70. `skynet.lua`

固定版本：

```text
Skynet v1.8.0
third_party/skynet/lualib/skynet.lua
```

必须找到并读：

```text
skynet.start
skynet.dispatch
raw_dispatch_message
skynet.call
yield_call
skynet.send
skynet.retpack
skynet.fork
skynet.timeout
skynet.sleep
skynet.exit
skynet.newservice
skynet.uniqueservice
skynet.mqlen
```

读完应该能解释：

```text
一个 lua dispatch 为什么跑在 coroutine
call 为什么 yield
response 怎样通过 session 找回 coroutine
fork 为什么不是 OS Thread
Service exit 时未完成 call 怎样失败
```

## 71. `skynet/queue.lua`

```text
third_party/skynet/lualib/skynet/queue.lua
```

理解：

```text
current_thread
thread_queue
wait/wakeup
可重入 ref
```

然后回答：

> 为什么本课 Battle Core 最终没有用 queue 包住整个 Tick？

答案应该来自 owner/no-yield 设计，而不是“queue 性能不好”。

## 72. `skynet/cluster.lua`

```text
third_party/skynet/lualib/skynet/cluster.lua
```

必须找到：

```text
cluster.call
cluster.send
get_sender
cluster.open
cluster.register
```

理解：

```text
cluster.call 用于启动期 ready 检查，内部等待 skynet.call 响应，会 yield
在线 data-plane 用独立 cluster.send 回包消息，并用 D039 传输字段关联
```

跨进程失败不能当成本地函数返回 nil 那么简单；本课由 Proxy/Dispatch/Manager 边界转换成结构化失败。

## 73. `debug_console.lua`

```text
third_party/skynet/service/debug_console.lua
```

至少知道：

```text
list
stat
mem
task
info
ping
call
```

这些已经足够本课定位：

```text
Worker 是否存在
mailbox 是否堆积
Service 内存是否异常
某个协程是否长期挂起
```

### 73.1 Skynet v1.8.0 源码阅读的最小结论要写进自己的笔记

读 `lualib/skynet.lua` 时至少把以下关系真正看懂，而不是只记 API 名：

```text
skynet.call
  -> pack
  -> 分配 session
  -> c.send
  -> 当前 coroutine yield "SUSPEND"
  -> response 根据 session 找回 coroutine
  -> resume

skynet.send
  -> session=0
  -> 不等待 response

收到普通 lua request
  -> raw_dispatch_message
  -> co_create(dispatch)
  -> 保存 session/source 到 coroutine metadata
  -> resume dispatch coroutine

skynet.timeout
  -> 生成 timer session
  -> timer 到达后 resume 对应 coroutine
```

然后回到本课代码回答：

```text
为什么 BattleMgr call Worker 时允许 yield？
为什么 Worker heartbeat callback 内不能再 call DB？
为什么同一个 Service 的另一条消息可以在前一 coroutine yield 时继续处理？
为什么 Core no-yield 比“我知道 Service 是 Actor”更具体？
```

读 `skynet/queue.lua` 时，要看到它本质是：

```text
当前 owner coroutine + wait queue + ref
```

它适合保护**确实需要跨 yield 的临界段**。本课核心不使用它，因为更好的边界是让 Battle step 根本不 yield。

读 `skynet/cluster.lua` 时，要看到 `cluster.call` 最终仍然走等待 response 的 `skynet.call`，所以跨进程 RPC 仍是 yield 点；它不会因为 API 叫 cluster 就变成“同步阻塞 OS Thread”。

---

# 第二十二部分：本课最终验收清单

## 74. 工程边界

```text
[ ] Gateway 不持有 Battle 状态
[ ] Battle Process 不接触 Client fd / frame buffer
[ ] battle_dispatch 只做 RPC Adapter
[ ] BattleMgr 只拥有 Worker handles / ID 路由
[ ] BattleWorker 是固定 Shard，不是一 Battle 一 Service
[ ] 一个 BattleWorker 可以同时持有多场 Battle
[ ] battle_id % worker_count + 1 稳定路由
[ ] Worker Service 不等同 OS Thread
[ ] worker_count 在在线 Battle 存活期间固定
```

## 75. Skynet

```text
[ ] 能从源码解释 call/session/yield/resume
[ ] 能解释同 Service 为什么跨 yield 会发生协程交错
[ ] Battle Core 全程 no-yield
[ ] heartbeat 使用 skynet.timeout，但 Battle 规则只用 logic_tick
[ ] 理解 fork 不是线程
[ ] 理解 queue 能解决什么，以及本课为什么不依赖它保护 Core
[ ] 启动期 cluster.call ready 失败会阻止对外监听
[ ] 在线回包使用 D039 的传输字段和有限返回路由；超时/迟到响应不会投递到错误连接
[ ] Worker Service crash 不被伪装成业务成功
[ ] debug_console 能观察 Service / task / mem / stat
```

## 76. Navigation

```text
[ ] Ground 继续使用 Lesson 2 Grid/Occupancy/Path
[ ] AMAP V1 是独立 NoFly sidecar
[ ] AMAP 与 BMAP map/version/dimension 一致
[ ] Air A* 8-way / no corner cutting
[ ] FlyingEnemy 可飞越 Ground blocked
[ ] FlyingEnemy 不进入 NoFly
[ ] Air Y = groundHeight + flightHeight
[ ] Ground/Air scratch 不互相污染
[ ] 多 Worker 并发 Native Query 无 global mutable race
```

## 77. Battle / Skill

```text
[ ] PlayerCommand 只有 Move / Cast intent
[ ] duplicate/stale command 明确拒绝
[ ] Command 映射到 Server apply_tick
[ ] GroundEnemy / FlyingEnemy / Player 最终进入同一 Skill Runtime
[ ] Slash = Instant
[ ] Fireball = Presentation Projectile
[ ] FrostBolt = Server Logic Projectile
- [ ] 可选扩展：FireWall = persistent AreaEffect
- [ ] 可选扩展：Haste / Slow / Burning 最小 Buff Runtime
- [ ] 可选扩展：MoveSpeed Modifier 不修改 AgentProfile
- [ ] 可选扩展：FireWall Ground only
[ ] Ground/Air TargetMask 生效
[ ] 所有 Damage / Death 走统一函数
```

## 78. Sync / Determinism

```text
[ ] Event seq 连续
[ ] Online Event 使用有界 ring buffer
[ ] Snapshot 带 last_event_seq
[ ] event_gap 时能用 Snapshot 恢复
[ ] Resume 在新连接上返回即时 Snapshot，旧连接失去控制权
[ ] 丢失 Submit Ack 后按 last_accepted_command_seq 去重
[ ] 错误凭据和已回收 Battle 的恢复明确拒绝
[ ] Unity 不重新结算伤害/寻路
[ ] Batch 与 Online 共用 create/step/skill/navigation
[ ] 同 snapshot + recorded command stream + versions + seed 得到同 Event/final state
```

## 79. 边界没有失控

```text
[ ] 没有 DB
[ ] 没有 AOI
[ ] 没有联盟/跨服
[ ] 没有世界地图行军
[ ] 没有账号级登录、持久化会话或跨进程故障恢复体系
[ ] 没有完整 Buff 框架
[ ] 没有 Skill Editor / DSL
[ ] 没有 Recast/Detour
[ ] 没有为了“商业级”创建未使用的接口森林
```

# 第二十三部分：面试复盘

## 80. 为什么不是一 Battle 一个 BattleWorker Service？

课程面对的是大量 Battle 的典型游戏 Server 场景。固定数量 BattleWorker 作为 shard，每个 Worker 的 Lua State 管理多场 Battle，可以避免 Battle 数量直接等于 Service/Lua State 数量。

本课使用：

```text
battle_id % worker_count + 1
```

获得稳定 ownership。

这不是说“一 Battle 一 Service 永远错误”，而是当前业务规模模型下固定 shard 更接近实际。

## 81. BattleWorker #1 是不是固定跑在 OS Thread #1？

不是。

Service 是消息/状态 owner；OS Worker Thread 是 Skynet scheduler 的执行资源。

所以多个 Service 仍可能从不同 OS Thread 同时进入同一个 Native Module。

## 82. 为什么 BattleWorker 一个 heartbeat 管多场 Battle？

减少每 Battle 独立 Timer/协程，保持一个 Shard 的推进入口清晰；同一 heartbeat 内 Core no-yield，避免 Battle mutable state 在半 Tick 被其他消息观察。

## 83. `skynet.call` 为什么危险的不是“慢”，而是 yield？

慢只是性能问题。

yield 会改变并发语义：同 Service 其他消息可能被调度，调用前保存的业务前提可能失效。

所以 Battle Core 禁止外部 call。

## 84. 为什么不用 `skynet.queue` 把所有 Battle 代码锁起来？

因为更好的边界是：

```text
核心不 yield
外部 I/O 在核心外
```

queue 适合确实需要跨 yield 原子串行的局部状态，不应该替代清晰 owner 设计。

## 85. 为什么 Haste 不需要重新 A*？

Haste 改变每 Tick distance budget，不改变可通行规则。

Path 解决“走哪里”，速度解决“走多快”。

## 86. 为什么 FireWall 不用一个 `skynet.timeout`？

FireWall 是 Battle 逻辑对象，持续时间和 pulse 必须跟随 logical tick，才能同时支持在线 fixed tick 和自动快速 simulate。

## 87. 表现型弹丸与逻辑弹丸的本质区别是什么？

不是“有没有特效”。

区别在于：

> 弹道过程是否会改变 Server 最终结果。

若轨迹不会改变命中对象，Server 只需确定 launch/impact/result；若中途单位碰撞/阻挡会改变命中，就必须 Server 权威推进逻辑 Projectile。

## 88. Event 和 Snapshot 为什么都需要？

Event 适合增量过程和 Replay；Snapshot 适合当前状态、初始加入和 Event gap 校正。

只用 Snapshot 会丢过程；只用 Event 会让落后/加入客户端必须从开局重放所有事件。

## 89. 为什么 Air Grid 不直接使用 Ground Walkable？

Ground Walkable 表示地面单位能否站/走；FlyingEnemy 可以越过普通地面障碍。

Air 的不可进入规则是 NoFly，两者业务语义不同。

## 90. 为什么不现在抽 `INavigationBackend`？

Ground Grid 和 Air Grid 是两个运动规则，不是 Grid/Detour 两个可互换地面 Backend。

真正的第二种 Ground Navigation Backend 要到可选 Recast/Detour 专题出现后，再从两个真实实现抽稳定接口。

# 第二十四部分：本课最终执行链

## 91. 在线模式

```text
Unity StartInteractiveBattle
        |
        v
FlyWow Gateway
        |
        v
Gateway Proxy
        |
        v
cluster.send(request + gateway_epoch + connection_id + command_id + request_id)
        |
        v
battle_dispatch
        |
        +-- cluster.send(response record) --> Gateway Proxy -> Gateway 独立 send_data 消息
        |
        v
BattleMgr
  allocate battle_id
  worker = id % count + 1
        |
        v
BattleWorker Shard
  new NavigationContext
  battle_core.create
  save BattleRuntime
        |
        +------------------------------+
        |                              |
        | PlayerCommand                | heartbeat 50ms
        v                              v
  enqueue apply_tick             battle_core.step
                                       |
                     +-----------------+--------------------+
                     |                 |                    |
                     v                 v                    v
                  Ground Nav         Air Nav          Skill Runtime
                     |                 |             /    |      \
                     |                 |       Projectile Area   Buff
                     |                 |                    Effect
                     +-----------------+--------------------+
                                       |
                                       v
                              ordered BattleEvent
                              periodic Snapshot
                                       |
                                       v
                               bounded event ring
                                       |
Unity SyncBattle <---------------------+
        |
        v
Client interpolation / effects only
```

## 92. 自动模式

```text
same initial snapshot
+ recorded PlayerCommand stream(apply_tick)
        |
        v
same BattleWorker Shard
        |
        v
battle_core.create
        |
        v
while !finished:
    step()
        |
        v
same Ground/Air Nav
same Skill/Projectile/FireWall/Buff
same Event order
        |
        v
full Event Log
        |
        v
Unity Replay / Regression
```

第三课最重要的证明不是“画面能打起来”，而是：

> 在线人工输入和自动快速模拟真正共用同一个确定性 Battle Core。

---

# 第二十五部分：对象、生命周期和释放顺序

## 93. 一场在线 Battle 从创建到销毁

```text
1. BattleMgr 分配 battle_id
2. battle_id % worker_count -> 固定 Worker
3. Worker new_context(map_id/map_version)
4. battle_core.create(snapshot, context, "online")
5. Context place Ground Units
6. 创建 Ground/Air Unit Runtime
7. Worker 保存 BattleRuntime
8. heartbeat 持续 step
9. command 只 enqueue
10. step 消费 command / AI / movement / skill / projectile / area / buff
11. Worker drain Event -> ring buffer
12. 周期 build Snapshot
13. BattleEnd
14. 保留短暂最终 sync 状态
15. stop/回收时 context:close
16. 删除 BattleRuntime
17. Lua 不再引用的 Path/projectile/buff table 被 GC
18. immutable GridMap/AirMap 仍留在 Registry 供下一场使用
```

### 93.1 Battle 结束后为什么 Context 必须显式 close

NavigationContext 包含：

```text
A* scratch
DynamicOccupancy
map refs
```

这些可能比 Lua 的几个小 table 大得多。

所以：

```text
显式 close = 正常生命周期
__gc = 异常兜底
```

不要等 Lua GC “哪天有空”才释放大块 Native Battle state。

### 93.2 多 BattleWorker 的真实内存关系再画一次

```text
Battle Process address space
|
+-- C++ MapRegistry
|     +-- shared_ptr<const GridMap 1001/v2>
+-- C++ AgentProfileRegistry
|     +-- immutable Profiles, loaded once at process startup
|
+-- C++ AirMapRegistry
|     +-- shared_ptr<const AirMap 1001/v2>
|
+-- BattleWorker Service #1 / Lua State #1
|     +-- battles[70004] -> Context A -> shared static maps + private scratch/occupancy
|     +-- battles[70008] -> Context B -> shared static maps + private scratch/occupancy
|
+-- BattleWorker Service #2 / Lua State #2
|     +-- battles[70001] -> Context C -> shared static maps + private scratch/occupancy
|     +-- battles[70005] -> Context D -> shared static maps + private scratch/occupancy
|
+-- Skynet OS worker thread pool
      +-- 负责调度上面的 Service coroutine
```

你需要能直接说出：

```text
共享的是 immutable static asset 和只读 AgentProfile；
隔离的是每场 Battle mutable Context/Core State；
Lua State 隔离并不让 process-global C++ singleton 自动变成每 Service 一份；
BattleWorker Shard 数也不是 OS thread 数。
```

这是第三课多 Worker 最核心的 Skynet + Native ownership 结论。

---

## 94. 一次 Player Cast 的完整函数链

```text
Unity
-> SubmitBattleCommand
-> FlyWow decode
-> gateway_proxy
-> cluster.send(request record)
-> battle_dispatch
-> cluster.send(response record)，以 D039 字段关联有限返回路由
-> BattleMgr.submit_command
-> worker_for(battle_id)
-> skynet.call(BattleWorker)
-> battle_core.enqueue_player_command
-> accepted apply_tick=N

heartbeat
-> battle_core.step
-> take_commands_for_tick
-> validate caster/skill/target
-> skill_runtime.cast
-> cooldown commit
-> Instant / Projectile / AreaEffect / Buff
-> Damage/Death
-> emit BattleEvent
-> Worker drain_events
-> SyncBattle
-> Unity presentation
```

能够脱离代码把这条链讲完整，第三课的 Skynet + Battle 主线才算真正掌握。

# 第二十六部分：实施时 Codex 的工作规则

## 95. 不允许一次性生成第三课全部源码

仍然按照：

```text
当前真实行为
-> 当前必须新增的最小概念
-> 实现
-> build
-> run
-> debug
-> test
-> next
```

例如 AirMap 还没通过 Native Test 前，不要提前生成 FireWall Unity 特效。

## 96. 每个文件开始前必须回答

```text
为什么现在需要这个文件
谁马上调用它
它只负责什么
它明确不负责什么
owner 是谁
哪些函数会 yield
哪些对象不能跨 Service/Lua State
完成后能观察到什么
怎样故意破坏验证
```

## 97. 第三课推荐提交顺序

```text
feat: shard battles across fixed worker services
feat: keep interactive battle state in workers
feat: add player command queue and online snapshots
feat: add air no-fly navigation asset
feat: add flying enemy navigation and ai
feat: add authoritative skill runtime
feat: add server projectile simulation
feat: add firewall area effect
feat: add minimal movement buffs
feat: add interactive battle protocol
feat: add unity interactive battle client
test: complete lesson three battle regression
perf: benchmark multi-battle worker runtime
```

提交信息只是推荐，不要求为了课程阶段机械拆 commit；每个 commit 应该保持可构建、可解释。

### 97.1 推荐 Git 提交粒度

第三课文档很长，但实际实现时不要一个 commit 塞全部内容。推荐按可独立验证的行为提交：

```text
1. feat: add stable battle worker sharding
2. feat: keep multiple online battles per worker
3. feat: add bounded player command queue
4. feat: add amap asset pipeline and reader
5. feat: add air grid pathfinding
6. feat: add ground and flying ai intents
7. feat: add minimal skill runtime
8. feat: add firewall and minimal buffs
9. feat: add battle event snapshot sync
10. feat: add interactive battle protocol
11. feat: add unity interactive battle validation
12. test: add lesson3 determinism and concurrency coverage
```

每个提交前只跑与当前模块相关的 focused tests；到协议/联调阶段再跑完整构建。这样 Codex 或人工 review 能看清每一步为什么存在，也更容易定位是哪一步引入 Regression。

---


## 98. 最终 `git diff --check`

完成全部第三课实现后：

```bash
git diff --check
```

无输出并返回 0。

然后分别确认：

```text
Native tests
Lua/Skynet tests
双进程 integration
Unity Edit/Play validation
Determinism regression
Concurrency stress
Benchmark
```

最终报告必须区分：

```text
静态检查
编译
单元测试
集成运行
人工 Unity 验收
尚未验证项
```

不能把“代码看起来对”写成“已运行通过”。

---

### 98.1 最终文档级自审计

除了 `git diff --check`，落实教程前后都要人工搜索这些危险模式：

```bash
# 项目自有 Lua 不应新增稳定 vararg 接口。
grep -R "function .*\.\.\." -n server/service server/lualib || true

# Battle Core 不应 require skynet。
grep -n "require .*skynet" server/lualib/battle/battle_core.lua || true

# Core/Skill/Buff/AI 不应出现墙钟 Timer/RPC/Socket/DB。
grep -R -nE "skynet\.(call|send|sleep|timeout)|socket\.|os\.time|DB|mysql" \
  server/lualib/battle || true

# 运行时不应读取 Unity Assets/Library 路径。
grep -R -nE "Assets/|Library/|[A-Za-z]:\\\\" server || true

# 不应提前引入可选 Lesson 4 Backend/Recast。
grep -R -nE "INavigationBackend|Detour|Recast|PolyRef" \
  server/service server/lualib server/third_party/skynet-flywow/navigation/native/grid_map || true
```

这些 grep 只能帮助发现可疑文本，不替代 build/test。最终报告要明确区分：

```text
静态检查通过
Native 编译通过
Native Test 通过
Lua/Skynet integration 通过
双进程 Gateway integration 通过
Unity EditMode/PlayMode 通过
人工场景验收通过
尚未验证的部署能力
```

不要把“文档写了”或“grep 没结果”描述成运行验证完成。

# 99. 第三课结束时你应该真正掌握什么

不是背 API，而是能基于这套工程回答：

```text
为什么固定数量 BattleWorker 管理多场 Battle？
为什么用 battle_id % worker_count 做稳定 owner？
为什么 BattleWorker Service 不是 OS Thread？
为什么 skynet.call 会让同 Service 出现协程交错？
为什么 Battle Core no-yield？
什么时候 skynet.queue 有用？
为什么 Timer 只驱动 heartbeat，技能时间只认 logic tick？
为什么多个 Service 调 Native Module 时 GridMap 可以共享而 scratch 不能共享？
为什么 Ground/Air 导航不能混用 Walkable/NoFly？
为什么 Air Unit 的 movement_layer 与 Skill target_layer 必须分开？
为什么 Flying Dragon 能同时攻击 Ground/Air，而 Ground-only Slash 不能攻击 Air？
为什么 AI 目标筛选和 SkillRuntime 都要各做一次 TargetMask 校验？
为什么加速减速不必重跑 A*？
为什么 FireWall 是 AreaEffect 而不是 Timer？
为什么表现型与逻辑型 Projectile 的 Server 成本不同？
为什么所有 Damage/Death 应该走统一入口？
为什么 Event 和 Snapshot 必须同时存在？
为什么在线和自动 Battle 应该共用一个 Core？
```

做到这里，本课程前三课已经完成这条纵向主线：

```text
Unity Authoring
-> Server Navigation Asset
-> Native Ground/Air Navigation
-> Skynet BattleWorker Shard
-> Player / AI
-> Skill / Projectile / AreaEffect / Buff
-> Server Authoritative Battle
-> Event / Snapshot
-> Unity Interactive Presentation / Replay
```

接下来再学习 DB、AOI、世界地图、行军、联盟、跨服、持久化恢复等内容时，应该作为独立的 **Skynet 商业游戏 Server 工程专题**，而不是继续把第三课无限扩张。

Polygon NavMesh / Recast / Detour 仍然是独立可选高级导航专题，不属于第三课前置条件。
