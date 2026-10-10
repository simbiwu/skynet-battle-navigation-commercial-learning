# 第三课：帧同步版——从玩家输入到可预测、可恢复的实时战斗

本课从**完成第二课后的仓库**开始。按本文逐节创建文件、修改 Gateway、生成协议、构建 Native、启动双进程，再接入 Unity；不需要旧第三课代码，也不运行旧第三课启动脚本。状态同步版是另一套独立课程，本文件不实现它。

本文交付的是实操步骤和完整源码。当前工作区的 Server/FlyWow 不会因为文档编写而提前安装这些改动，**Gateway 修改也由你在第 3 节亲自完成并审计**。作者验证使用隔离目录，具体已验证与尚未验证项目见最后一节。

## 0. 最终效果与学习顺序

### 0.1 本课玩法

- 玩家控制地面单位 `1001`：WASD 移动，J 近战，K 表现弹丸，L 逻辑火球。
- Server 控制地面敌人 `2002` 和飞行敌人 `2001`，自动寻找最近的活敌人并接近、施法。AI 不依赖墙钟、浮点物理或客户端 Transform。
- 飞行敌人会水平飞行和升降。`2000mm` 只是出生高度；不是运行时固定高度。AI 根据目标当前位置、水平距离与地表穿透限制调整高度：远距追击时抬高，接近时下俯；不是沿固定高度层移动。
- 消灭全部敌方单位结束；双方同帧死亡判平局。没有组队、掉落、奖励或结算界面。180 秒仍未结束判平局，避免一场 Battle 无限持有输入日志。

地面玩家/地面敌人受 BMAP 通行与地表规则限制；飞行敌人不使用地面 A*、walkable 或 clearance 作为空中阻挡。当前资产是 2.5D 地表 Grid：飞行只验证 XZ 地图边界、单位不得穿过地表，以及规则定义的 `10000mm` 世界高度上界。飞行高度在这个范围内变化，不是固定层。真正的立体建筑/天花板/禁飞体积需要对应空域资产；不能把地表 Grid 包装成已经支持三维空间碰撞的 NavMesh。

### 0.2 你会真正实现什么

|阶段|当前问题|可观察产物|
|---|---|---|
|1|第二课一次性模拟不接收在线输入|冻结新玩法、输入与固定帧合同|
|2|两端各自算战斗容易分歧|同一 C++17 Core、Checkpoint、确定性测试|
|3|Gateway 拒绝目标连接的主动消息|你亲自修改的定向 push 合同与审计测试|
|4|网络 DTO 与模拟状态不能混为一层|唯一 Proto 的兼容扩展与生成 Registry|
|5|实时 Battle 要跨消息保持生命周期|Runtime、Worker、Dispatch、双进程入口|
|6|先验证 Server 真链路，再调表现|真实握手/推帧/重连/输入回放集成测试|
|7|Unity 不能在 Update 阻塞读网络|有界长期连接、主线程双模拟实例|
|8|玩家不能等一次 RTT 才看到动作|本地预测、输入确认、恢复重演、表现收敛|
|9|结束后要证明输入能还原逻辑|分页日志、输入回放、逐帧状态 hash|
|10|本机正常网络不是性能结论|跨平台 Golden、失败审计、网络与容量验证|

### 0.3 当前基线与编辑位置

固定 Skynet v1.8.0、自带 Lua 5.4.7、C++17、团结引擎 1.10.0（Unity 2022.3 LTS）、AI Navigation 1.1.7、protoc 36.2。FlyWow 使用当前固定 submodule，不静默升级。

**WSL 操作**指主工作区 `/home/simbi/workspace/skynet-battle-navigation-commercial-learning`。Server、FlyWow、协议源、文档在这里修改。**Windows 操作**指 Unity 工作区 `G:simbidevskynet-battle-navigation-commercial-learning`。Unity C#、Scene、插件设置在 Windows 操作。非 Unity 文件通过工作区 Git 流程交付；不要用另一份目录覆盖未提交修改。本文中的 Git 同步步骤由你按实际提交与审核节奏执行，作者不代替你提交或推送。

先在 WSL 仓库根目录执行只读检查：

```bash
cd /home/simbi/workspace/skynet-battle-navigation-commercial-learning
git status --short
git -C server/third_party/skynet-flywow status --short
git submodule status
test -x server/third_party/skynet/skynet
test -x server/third_party/skynet/3rd/lua/lua
test -x server/third_party/protoc-36.2/bin/protoc
test -f shared/navigation/battle_1001/battle_1001.bmap
test -f shared/navigation/battle_1001/battle_1001.manifest.json
```

若已有同名 `frame_sync` 文件，先审阅其内容；不要无条件覆盖你的学习修改。本课新建 `config/frame_sync.lua`，不会要求覆盖已有 `config/battle.lua`。第二课 Gateway/Battle 入口继续独立使用原端口；新版本客户端 TCP 端口为 `19021`，Cluster 为 `2537/2538`。

## 1. 同步合同：确认输入帧，双方按相同规则推进

### 1.1 一帧到底同步什么

先把核心问题说清楚：帧同步里的“一帧”，不是一张画面，也不是一条网络消息；它是战斗模拟共同使用的一个编号时间步。本课规定一个逻辑帧代表 50ms 的战斗时间。Server 每推进一次逻辑，帧号加一；Unity 的预测模拟也按同样的步长推进。

如果战斗初始状态记为第 0 帧，那么推进一次得到第 1 帧，推进 20 次代表逻辑战斗时间前进了 1 秒。这里的 20 次是模拟步数；电脑实际花了多久、Unity 这一秒渲染了多少张画面，是另外两件事。

|概念|它回答的问题|本课例子|
|---|---|---|
|逻辑帧|战斗规则推进到了第几步？|第 41 帧|
|逻辑时间|按帧率换算，战斗内经过了多久？|20 帧约为 1 秒|
|Server 调度时间|Worker 什么时候有机会执行下一步？|Timer 到期后处理消息并推进|
|Unity 渲染帧|屏幕什么时候画下一张画面？|可能一秒画 60 张，也可能掉帧|
|网络消息|客户端和 Server 什么时候交换数据？|一条消息可以带多条输入或多条帧记录|

因此，Unity 一秒渲染 60 张图，不代表 Battle 必须推进 60 帧；网络延迟 100ms，也不代表这 100ms 内的输入可以随意改写过去的逻辑帧。**帧号是战斗时间线的序号，不能拿 Unity 的 Update 次数或消息到达顺序替代。**

#### 两个方向分别传什么

帧同步的正常战斗流量以“输入”为中心：

~~~mermaid
flowchart LR
  A[Unity 采集玩家意图] --> B[FrameCommand：目标帧 + 移动方向 + 技能意图]
  B --> C[Server 检查帧窗口与截止时间]
  C --> D[确定该帧正式采用的玩家输入]
  D --> E[Server Core 推进这一帧并计算 AI、移动、技能、伤害]
  E --> F[FrameRecord：正式输入 + 是否收到 + 本帧状态 hash]
  F --> G[Unity 确认正式帧，并校正预测模拟]
~~~

**客户端到 Server：提交某个逻辑帧的操作意图。**本课输入包含目标帧号、水平移动方向和技能编号。比如“第 41 帧向右移动并按下 L”。它表达的是玩家希望做什么，不是“把角色坐标改到这里”，也不包含 HP、命中结果或敌人位置。

**Server 到客户端：说明某帧最终采用了什么输入，并提供分歧检查信息。**本课的 FrameRecord 带有被采用的玩家输入、supplied 标记和该帧结束时的状态 hash。正常推进时每帧生成正式记录；协议把记录放在响应消息里。记录本身不附带每个单位的完整坐标、HP 和弹丸状态。

- input：这一帧正式采用的玩家输入。它可能是客户端按时送达的输入，也可能是缺输入规则生成的输入。
- supplied=true：Server 在截止时间前收到了并采用了玩家输入。
- supplied=false：截止时没有可采用的玩家输入，Server 按补缺规则生成该帧输入。它仍然是正式输入，不能等迟到消息来了再重写历史。
- hash：Server 模拟完这一帧后，对规范化逻辑状态计算的短 hash。它帮助客户端和回放工具发现“同样输入是否算出了不同状态”；它不是坐标快照，不能单独修复分歧，也不是防作弊凭据。

这里最容易混淆的是：**Server 回给客户端的不是“第 41 帧所有单位的新状态”，而是“第 41 帧采用的输入记录，以及用于比较模拟结果的 hash”。**客户端需要用相同规则自己推进单位、技能、弹丸和 AI。正常帧同步不会每 50ms 下发完整战斗状态。加入战斗和恢复分歧时可以发送 Checkpoint（可恢复的完整逻辑状态），那是加入/恢复流程，不是每帧同步的常规内容。

#### 为什么两端都运行模拟

只传输入能减少持续传输完整状态，但前提是两端能从相同起点、按相同规则推进。可以把一次模拟理解为：

~~~text
当前逻辑状态 + 这一帧正式采用的玩家输入
    -> 同一套战斗规则推进一步
    -> 新逻辑状态 + 该帧事件/状态 hash
~~~

Server 必须运行这套 Core，才能决定正式战斗结果、拒绝过期或冲突输入，并独立计算 AI、移动、技能、命中、HP 和胜负。客户端也运行同一套 Core，以便及时响应操作并复现正式帧。双方都持有模拟状态，但权威责任不同：**Server 的状态和结果是正式依据；客户端的模拟用于快速反馈，收到确认后必须服从 Server 采用的输入和检查结果。**

本课中，Server 控制的地面敌人与飞行敌人不会逐帧把“敌人移动命令”发给客户端。双方 Core 都根据该帧开始时的状态、固定 AI 规则和相同地图资产与兼容的客户端、Server程序版本，派生敌人的目标、移动和施法。因此敌方 AI 结果也能从输入记录重演。地图ID、地图版本和地图资产hash用于确认双方加载了相同地图。战斗规则随客户端与Server程序版本发布，不通过源码字节hash协商；版本兼容由发行包和匹配服务的程序版本合同负责。

#### 用第 41 帧走一遍

假设客户端和 Server 都已确认到第 40 帧，玩家按下“向右”：

1. Unity 把意图编号为目标第 41 帧，并放进待发送输入队列。
2. 为了不让玩家等待网络往返，Unity 可以先用这条意图推进本地预测模拟。屏幕显示预测位置，但这还不是 Server 的正式确认。
3. Server 到达第 41 帧的输入截止点。如果输入按时到达，就采用向右输入并标为 supplied=true；如果没有收到，就按补缺规则确定第 41 帧输入并标为 supplied=false。
4. Server 用正式输入和相同 Core 推进第 41 帧，同时派生敌方 AI、技能与伤害，最后生成该帧的 FrameRecord。
5. Unity 收到记录后，用记录里的正式输入推进“已确认模拟”，并比较 hash。如果预测输入正好被采用且 hash 相同，就继续确认；如果 Server 采用了补缺输入或 hash 不同，Unity 从最近的已确认状态恢复，再重演之后还未确认的本地输入。
6. 渲染画面跟随预测模拟，并向确认后的正式结果平滑收敛。Transform 只负责显示位置，不能反过来改写逻辑 Core 的坐标。

客户端内部可以先理解成两个逻辑副本：

- **Confirmed（已确认）**：按 Server 已正式发布的帧记录推进，表示目前能证明与权威时间线一致到哪里。
- **Predicted（预测中）**：从 Confirmed 出发，再应用尚未确认的本地输入，供画面快速响应。它可以领先，但不能把自己的结果当成正式胜负或 HP。

例如 Confirmed 到第 40 帧，Predicted 已经先算到第 43 帧。此时收到第 41 帧记录，Unity 先用正式记录确认第 41 帧，再从这个状态重演本地仍待确认的第 42、43 帧。**回滚不是把画面瞬间倒带给玩家看，而是在逻辑副本中恢复状态并重算；随后渲染层再平滑处理位置差异。**下一节解释为什么需要预测，后文再实现输入窗口、Checkpoint、重演和表现收敛。

#### 记住这条边界

~~~text
每帧常规同步：输入意图 -> Server 选定正式输入并推进 -> 输入记录 + hash
加入/恢复：必要时额外发送完整 Checkpoint
客户端不能提交：权威坐标、HP、命中、死亡、敌方 AI 结果
~~~

本课选用 TCP 传输消息。TCP 会影响数据何时到达，但不会替 Battle 决定帧号、输入截止、补缺、迟到处理或权威结果。下一节先看客户端为什么要预测；1.3 再逐项定义按时、缺失、重复、迟到和超窗输入的处理。

### 1.2 为什么仍然有本地预测

若 RTT=100ms，先提交输入、等 Server 回来再启动移动，手感会直接承担这个 RTT。本课 Unity 在下一次本地固定步就使用按键意图推进预测 Core；施法按键在当前渲染帧先显示可撤销黄闪。Server 结果到达后，confirmed Core 用正式输入推进并核对 hash，predicted Core 从 confirmed Checkpoint 恢复，再重演还未确认的意图。

例如 confirmed=40、predicted=43：Server 正式采用第 41 帧的补缺输入而没有采用本地预测的右移。confirmed 执行 Server 的 41；predicted 恢复 confirmed 的 41，依次重演仍保留的 42、43。正式 HP、死亡与结束读取 confirmed；渲染位置可以读取 predicted，并做短时间收敛。Transform 不写回 Core。

初始预测提前两帧，Server 创建后给两个 Tick 的准备时间。提前量是明确的调度参数，不是用 `Time.deltaTime` 推断正式帧号。最多允许比确认帧前进 8 帧；网络停顿超过窗口时停止继续猜测，并通过恢复入口获取新的正式状态。

本课固定使用 2 tick 作为输入提前量基准；每 tick 为 50ms，因此样例提前量为 100ms。这个选择参考 Unity Netcode for Entities 的默认 `TargetCommandSlack`（2 ticks）：客户端把模拟时间保持在 Server 前方，让输入有时间到达。两套实现细节不同，所以这是可复用的起始值，不是适用于所有游戏和网络的通用保证。Photon Quantum 的 Server 缺输入等待容忍值、输入延迟偏移和回滚窗口分别是不同参数，不能把它们当成同一个“提前量”。

课程不要求测量每个玩家的单向延迟，也不要求按连接动态协商这个值。客户端仍立即本地预测以响应操作，Server 按目标帧截止时间确认正式输入。若输入超过截止时间，仍按本课的迟到规则处理；预测和提前量降低迟到概率，不会让迟到输入自动改写 Server 历史。客户端预测最多比确认帧前进 8 tick；这不是输入提前量，也不是 Server 等待缺失输入的时间。实际延迟与丢包验证用于确认这些边界和恢复行为，不用于推导一个能保证所有网络条件的数字。参考：[Unity Netcode for Entities 的 prediction/command slack](https://docs.unity.cn/Packages/com.unity.netcode%401.5/manual/intro-to-prediction.html)、[Photon Quantum 的独立输入与回滚参数](https://doc-api.photonengine.com/en/quantum/current/class_photon_1_1_deterministic_1_1_deterministic_session_config.html)。

### 1.3 缺输入、迟到与批量到达

每条输入都带目标帧号。Server 检查的是“这条输入对应的帧还能不能接受”，不是“消息现在才到，所以把它立即应用到当前帧”。输入先进入有限的未来窗口，等该帧截止时，Core 才把正式输入推进为一帧战斗结果。

|情况|正式规则|
|---|---|
|目标帧仍未截止，且位于当前帧之后 8 帧以内|接受并暂存；目标帧到来时再使用|
|目标帧截止时没有输入|生成正式补缺输入；方向最多沿用两帧，之后停止；技能永不沿用|
|消息到达时该帧截止时间已过|该条输入返回 LATE，不能改写历史；Timer 执行晚也不重新开放截止时间|
|目标帧大于当前帧+8|该条输入返回 INPUT_WINDOW|
|同一帧重复相同输入|该条结果为 OK，幂等，不增加第二份 pending|
|同一帧收到不同输入|该条结果为 CONFLICT；先接受的输入保持不变|
|一个请求里的输入条数为 0|请求级 EMPTY_INPUT 拒绝，不产生逐项结果|
|一个请求里的输入条数超过 8|整批以请求级 INPUT_BATCH_TOO_LARGE 拒绝，不接受其中任何一条|

#### 截止、定稿与“迟到输入是否还能生效”

本课采用**2 tick 固定输入提前量 + 截止后定稿**，Server 不回滚已执行帧。50ms 的逻辑帧下，2 tick 等于 100ms。它参考 Unity Netcode for Entities 的 2 tick `TargetCommandSlack` 默认值；这里只借用相近的输入提前概念，不声称两套合同完全相同，也不保证 100ms 足以覆盖每条公网路径。客户端采样后立即本地预测，同时把带目标帧号的命令提前发送；Server 在目标帧截止前收集并确认输入。

用 41、42、43 帧看两种结果：

- **41 帧输入在截止前到达**：Server 将它记为 `supplied=true`，随后依次执行 41、42、43。客户端收到正式记录后，对照 Server 输入；如有预测差异，从最近确认状态恢复并重演未确认帧。
- **41 帧输入在截止后才到达**：Server 已用补缺输入执行 41，随后可能已执行 42、43。该命令返回 `LATE` 并丢弃，不顺延到 42，也不触发 Server 重算 41–43。客户端收到 41 的正式记录后，用正式输入重演自己的预测历史；这只能校正客户端，不能让被拒绝的迟到意图改变 Server 结果。

因此，**本课里的回滚是客户端预测校正，不是 Server 权威模拟回滚**。`supplied=false` 的影响会传递到 42、43 的权威状态；客户端必须接受 Server 的输入记录和 hash。若输入频繁迟到，按本课既定的 LATE、预测窗口耗尽和恢复合同处理；本课不按单个玩家动态测量或调整提前量。生产系统若要改用其他固定配置，应作为独立产品决策，不能默认为每个连接自动调参。若产品要求已截止的 41 帧仍能改变正式战斗，就必须另行设计 Server 有界回滚：保存回滚窗口内完整逻辑状态和输入历史，对 41 的修正重演 41 至当前帧，并规定哪些事件/伤害/死亡等副作用在提交边界前不得对外不可逆发布。本课 Runtime 不保存这段 Server 历史，不能声称具备该能力；这也是另一套需要单独实现与验证的合同。

帧同步可以通过客户端预测降低本地操作反馈延迟，但它不能保证每个迟到输入都被权威 Server 接纳。若玩法需要公网环境下稳定的即时操作响应和 Server 校正，状态同步版采用的本地预测/权威状态校正是独立方案；不能把这两种模型的输入与结果合同混写。帧同步版适合在其确定性、输入提前量和回滚边界都明确的前提下教学和评估。

#### 批量只改变传输方式，不改变每条输入的目标帧

TCP 字节流可能因为网络调度、延迟和缓冲，让多条应用消息在短时间内连续到达。客户端也可以把多条不同帧的 FrameCommand 放进一个 FrameInputRequest，减少消息数量。无论哪一种情况，Server 都不能把它们当成“当前帧连续执行几次”；每条命令仍按自己的 frame 字段判断截止时间和未来窗口。

本课每个 FrameInputRequest 最多装 8 条命令。批次长度合法时，Server 按数组顺序逐条处理，允许部分接受。FramePushResponse 增加 input_results；其中每项包含目标 frame 和该项结果 code，顺序与请求中的输入一致。外层 code 表示整条请求是否可处理，不代表批内所有输入成功：

- 外层 code=OK：请求格式和批次大小合法；逐项结果看 input_results。
- 每项 code=OK：这条输入已进入 pending，或它是此前已接受输入的相同重传。这只表示输入被暂存，不代表该帧已经模拟或成为正式结果。
- 每项 code=LATE/INPUT_WINDOW/CONFLICT/BAD_INPUT/FINISHED：对应 frame 的这条输入被拒绝；其他输入仍按各自结果处理。
- 外层 code=EMPTY_INPUT：批次为空；不处理输入，input_results 为空。
- 外层 code=INPUT_BATCH_TOO_LARGE：批次超过 8 条；整批拒绝，input_results 为空。

举例：Server 当前帧为 100，一批输入依次是第 99、102、109 帧。第 99 帧已过时，第 102 帧仍在未来窗口，第 109 帧超过 100+8。响应外层 code 为 OK，逐项结果为：

~~~text
frame 99  -> LATE
frame 102 -> OK
frame 109 -> INPUT_WINDOW
~~~

只有第 102 帧被暂存。它到截止时是否成为本帧正式输入，要看随后服务器发出的 FrameRecord。FrameRecord 的 input 和 supplied 才是客户端确认正式时间线的依据；批次接收结果不是战斗结果。

#### 延迟、输入积压与模拟过载是三种不同情况

- **网络输入积压**：旧帧可能过期，新帧可能仍在窗口内；按上面的逐帧结果处理。积压不允许倒回模拟。
- **空输入请求**：返回 EMPTY_INPUT；它与超限批次是不同的请求错误。
- **单条请求过大**：整批 INPUT_BATCH_TOO_LARGE 拒绝；客户端应拆分后重试，不能原样无限重试。
- **Server Worker 模拟落后墙钟**：这是计算追赶问题，不是客户端输入批次。最多连续补 4 帧；每一帧仍单独执行和记录，不扩大 dt、不跳帧。超过追赶预算，本场显式 OVERLOAD 并停止。

一个 Worker 拥有多场 Battle，每场各自保存输入截止、当前帧与 Native 实例。它不能为了等某个连接而暂停其他 Battle，也不能把迟到输入塞进已经结束的帧。

### 1.4 传输选择

本版复用已经存在的 FlyWow TCP 长连接、应用握手与 Protobuf。TCP 保证字节流有序到达，不保证低延迟：丢包会导致队头阻塞，因而可能让旧帧输入在截止后成批到达。生产协议可以重复携带尚未确认的近期输入，以便获得逐帧接收结果；相同输入重传必须幂等，但这不能绕过 TCP 队头阻塞，也不能重开已经定稿的帧。TCP 底层把字节合并或拆分，不会改变 Gateway framing 后的应用消息边界；若多个 FrameInputRequest 连续到达，仍逐条按各自目标帧处理。若一个请求显式携带多条 FrameCommand，则按 1.3 的逐项结果合同处理。帧号、缺输入规则、窗口、确认与恢复仍由 Battle 定义，不能把 TCP 的可靠性当作业务确认。

本课不会另外创造一套 UDP 会话/加密/拥塞控制。商业产品能选择可靠流或成熟的数据报传输，取决于目标网络与玩法；帧同步并不由 TCP/UDP 决定。这里明确保留 TCP 的队头阻塞风险，最后给出实际延迟/丢包验证步骤，不宣称本机验收证明所有公网实时场景。

## 2. 先做可恢复的确定性模拟，不先堆网络文件

### 2.1 坐标与状态

长期单位位置是有符号 64 位毫米 `x/y/z`。`GridPos` 只出现在导航内部；Unity 显示才除以 `1000f`。地面高度来自 BMAP，空中单位的高度是可变逻辑事实。不能把物理 Rigidbody、NavMeshAgent、Transform 或动画回调用于正式移动与命中。

本课每帧固定顺序：校验玩家意图 → 帧号递增 → 从帧开始状态产生 AI → 按 ID 移动 → 校验/施法 → 推进弹丸 → 同帧统一伤害提交 → 死亡/结束。最后统一伤害避免处理 ID 小者时先杀死另一方、取消对方已经应当发生的同帧攻击。

整数移动预算：`3000mm/s × 50ms / 1000ms = 150mm`。双轴分别 `106mm`，三轴分别 `86mm`；这是编译进规则的量化近似，不在不同平台调用浮点 sqrt。地面/空中子步不超过 `cell_size/4`，X、Z、Y 顺序固定。地面校验通行、clearance 和地表高差；空中只验证其自己的空间边界。飞行 AI 在障碍地表变高时爬升；接近目标时会调整高度，客户端按同样规则派生，不接受玩家发来的敌人坐标。

地面 AI 使用 FlyWow 现有 `GridPathfinder::FindPathStatic`；每个 Engine 独占 `NavigationContext` scratch。当前不保存路线缓存，所以恢复当前逻辑状态后可重新查询；scratch 的查询代数/堆槽不是玩法状态，不能直接序列化其指针。查询成本按地图与单位数增长，最后要求单独测 CPU；不会用“只有几个单位”替代这个成本说明。

### 2.2 技能基础框架

|技能|效果类型|目标移动类型|正式伤害发生时刻|冷却|
|---|---|---|---|---|
|J 近战|Instant|地面|施放成功的当前帧|12帧=600ms|
|K 表现弹丸|VisualBolt|地面/空中|施放成功的当前帧；之后飞行仅表现|24帧=1200ms|
|L 逻辑火球|LogicalBolt|地面/空中|弹丸到达目标的逻辑帧|24帧=1200ms|

定义与运行态分开：Skill 定义保存范围、冷却、伤害、Effect 与目标类型掩码；Unit 只保存各技能 ready 帧；Bolt 保存实例 ID、施法者、目标、过期帧、位置和到达伤害。施放失败不消费冷却，不创建弹丸。逻辑弹丸满槽拒绝施法；表现弹丸满槽仅省略视觉飞行，正式伤害和冷却仍提交，避免表现资源决定战斗结果。Target 根据合法类型选择最近活敌人，等距按 ID；正式距离包含高度，不再只算 XZ。

表现弹丸和逻辑弹丸都可由渲染器画出来，但前者 `damage=0`，到达/消失不会再打一次伤害。逻辑弹丸速度采用三轴 Chebyshev 长度的整数归一，400mm/帧，最多存在60帧；目标死亡或到期即移除。两种魔法弹丸在本玩法中忽略地面障碍，不声称实现了射线遮挡。施法黄闪只是即时预备反馈，不等于命中。

Unit.ready、Bolt.next_id/到期/位置/伤害、Unit.move_mode 和高度全部在 Checkpoint 中；回滚必须恢复它们，不能只把单位位置拉回。范围/伤害是业务定义，不塞进 Gateway，也不让导航模块依赖技能。

### 2.3 规范化 Checkpoint

不能 `memcpy(State)`：vector 内存、指针、padding 和编译器布局不同。这里逐字段写小端格式版本1。

|布局|字节数|内容|
|---|---:|---|
|头|20|version/frame/winner/next_bolt/unit_count，各uint32|
|每单位|52|id/camp/move_mode；XYZ各int64；hp int32；ready[3]各uint32|
|弹丸数|4|uint32|
|每弹丸|44|id/caster/target/expires/damage各4字节；XYZ各int64|

最大 `20 + 64×52 + 4 + 128×44 = 8984 bytes`，ABI 缓冲预算为16384 bytes。restore 先读候选值、验证版本/数量/范围/排序/引用，再唯一发布；坏状态不能留下半个新世界。每步异常也恢复旧 State。FNV32 仅用于逐帧分歧诊断，不用于抗作弊、安全身份或资产完整性；地图内容身份由已发布地图的版本与 SHA256 校验。

### 2.4 新建 Native 文件

在 WSL 仓库中创建以下文件。Core 属于宿主玩法；FlyWow 提供导航和 Lua Binding 公共实现，不把本课技能写进 submodule，不复制导航源码。CMake 编译固定子模块中的原始 source；Windows 构建关闭 Lua Binding，保留同一 Core。

### server/native/frame_sync/frame_core.h

**操作：新建。** 把本场逻辑状态、单步输入和可恢复ABI固定下来。

学习导航：精读 State全部字段、step/save/restore以及handle的open/close配对。 可以略读固定声明与语言样板。输入、输出和失败语义见文件头及 API 注释；本节验证命令在该阶段末尾。阅读后应能解释这些状态的 owner、修改时机和释放位置。

```cpp
// 职责：定义帧同步整数模拟、可恢复状态与稳定 C ABI；属于宿主 Battle，不属于 FlyWow。
// 输入/输出：已发布只读地图与单帧玩家意图 -> 逻辑状态；不读取网络、墙钟或 Unity 表现状态。
// ownership：Engine 共享持有不可变 GridMap，并独占 NavigationContext 与 State；C handle 由调用方成对 open/close。
#pragma once

#include "grid_map.h"
#include "navigation_context.h"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace lesson_frame
{
constexpr std::size_t   kMaxUnits  = 64;   // 每场允许持有的单位总数；超限时拒绝初始化或恢复。
constexpr std::size_t   kMaxBolts  = 128;  // 每场在途逻辑弹丸上限；满槽时拒绝逻辑弹丸施法。
constexpr std::uint32_t kMaxFrames = 3600; // 50ms/tick 下为 180 秒；到期时以平局结束。
constexpr std::uint32_t kTickMs    = 50;   // 固定逻辑步长；渲染帧率不改变它。

/// 单帧玩家意图；方向分量取 -1、0、1，skill 使用下方固定业务编号。
struct Input
{
    std::int32_t x     = 0; // 世界 X 方向；-1/0/1 表示负向/不动/正向，不是坐标。
    std::int32_t z     = 0; // 世界 Z 方向；-1/0/1 表示负向/不动/正向，不是坐标。
    std::int32_t y     = 0; // 飞行高度意图：-1 下降、0 保持、1 上升；地面单位忽略。
    std::int32_t skill = 0; // 0 不施法；1 近战；2 表现弹丸；3 逻辑火球。
};

/// Battle 单位的权威逻辑状态；位置为带符号 64 位世界毫米。
struct Unit
{
    std::uint32_t id        = 0;   // Battle 内稳定且唯一的实例 ID；单位按 ID 排序推进。
    std::uint32_t camp      = 0;   // 阵营编号：1 为玩家方，2 为敌方。
    std::uint32_t move_mode = 1;   // 移动规则：1 受地表约束，2 可主动升降的空中单位。
    std::int64_t  x         = 0;   // 世界 X 坐标，单位 mm。
    std::int64_t  y         = 0;   // 世界高度，单位 mm；地面单位由地图采样确定。
    std::int64_t  z         = 0;   // 世界 Z 坐标，单位 mm。
    std::int32_t  hp        = 100; // 当前生命值；0 表示死亡。
    std::uint32_t ready[3]  = {};  // 技能 1/2/3 最早可再次施放的逻辑帧号。
};

/// 在途逻辑弹丸；其 ID、位置和到期时间都是可恢复的 Battle 状态。
struct Bolt
{
    std::uint32_t id      = 0; // 本场单调递增的弹丸实例 ID。
    std::uint32_t caster  = 0; // 发射单位 ID；必须引用现存 Unit。
    std::uint32_t target  = 0; // 目标单位 ID；必须引用现存 Unit。
    std::uint32_t expires = 0; // 到期逻辑帧；到期或目标死亡后移除。
    std::int32_t  damage  = 0; // 0 仅供表现；20 在到达目标时提交逻辑伤害。
    std::int64_t  x       = 0; // 世界 X 坐标，单位 mm。
    std::int64_t  y       = 0; // 世界高度，单位 mm。
    std::int64_t  z       = 0; // 世界 Z 坐标，单位 mm。
};

/// 完整可恢复逻辑状态；不包含指针、渲染对象、墙钟、随机全局状态或 Socket。
struct State
{
    std::uint32_t     frame     = 0; // 已完成的逻辑帧；初始 Checkpoint 为 0。
    std::uint32_t     winner    = 0; // 0 进行中；1/2 对应胜方阵营；3 表示平局。
    std::uint32_t     next_bolt = 1; // 下一个弹丸 ID；恢复后继续单调递增。
    std::vector<Unit> units;         // 按稳定 ID 严格升序；数量不超过 kMaxUnits。
    std::vector<Bolt> bolts;         // 按实例 ID 严格升序；数量不超过 kMaxBolts。
};

/// 单场无锁、无 yield 的模拟 Engine；调用方必须串行调用其可变方法。
class Engine
{
  public:
    /// 创建本场模拟并共享持有不可变地图；地图无效或出生点不可用时抛出异常。
    /// @param map 已验证的只读地图；Engine 与调用方共同持有其生命周期。
    explicit Engine(std::shared_ptr<const flywow_navigation::GridMap> map);

    /// 按课程玩法初始化单位；失败时保留调用前状态并抛出异常。
    void reset();

    /// 推进一个固定逻辑帧；非法输入、结束状态或导航失败时不提交半帧状态。
    /// @param input 当前帧玩家意图；方向分量为 -1/0/1，skill 为 0..3。
    void step(Input input);

    /// 生成显式小端的规范化状态副本，可用于 Checkpoint 与确定性比较。
    /// @return 调用方拥有的序列化字节串。
    std::string save() const;

    /// 验证完整候选状态后一次性替换当前状态。
    /// @param bytes 借用的规范化状态字节；函数返回后不保留其引用。
    /// @throws 状态格式、版本或业务约束不合法时抛出异常，旧状态保持不变。
    void restore(const std::string &bytes);

    /// 只读借用当前状态；引用在 Engine 下一次成功变更或析构前有效。
    const State &state() const noexcept
    {
        return state_;
    }

    /// 返回当前地图身份；不执行 I/O。
    std::uint32_t mapId() const noexcept
    {
        return map_->metadata().map_id;
    }
    std::uint32_t mapVersion() const noexcept
    {
        return map_->metadata().map_version;
    }

  private:
    std::shared_ptr<const flywow_navigation::GridMap> map_;
    flywow_navigation::NavigationContext
          context_; // 当前 Engine 独占 A* scratch；不属于可恢复 State。
    State state_;

    void  stepUnchecked(Input input);
    void  chaseAir(const Unit &unit, const Unit &other, Input &input) const;
    void  chaseGround(const Unit &unit, const Unit &other, Input &input);
    bool  sample(std::int64_t x, std::int64_t z, std::int64_t from_y, std::int64_t &y) const;
    void  move(Unit &unit, Input input);
    bool  sampleAir(std::int64_t x, std::int64_t z, std::int64_t desired_y, std::int64_t &y) const;
    Input ai(const Unit &unit);
    void  cast(Unit &unit, std::int32_t skill, std::vector<std::int32_t> &damage);
    void  projectiles(std::vector<std::int32_t> &damage);
    std::size_t target(const Unit &unit, std::uint32_t target_modes = 3) const;
    void        finish(const std::vector<std::int32_t> &damage);
};
} // namespace lesson_frame

#if defined(_WIN32)
#define SKYNET_BATTLE_NAV_FRAME_API __declspec(dllexport)
#else
#define SKYNET_BATTLE_NAV_FRAME_API __attribute__((visibility("default")))
#endif

extern "C"
{
    /// 加载已发布地图并创建独占 Engine；不保存调用方传入的路径指针。
    /// @param path UTF-8 BMAP 文件路径；必须以 NUL 结尾。
    /// @return 成功时返回调用方独占的 handle；失败时返回 nullptr。
    SKYNET_BATTLE_NAV_FRAME_API void *fs_open(const char *path);

    /// 释放由 fs_open 返回的 Engine handle；空指针可安全传入。
    /// @param handle fs_open 返回且尚未关闭的 handle；重复关闭非空 handle 属于调用方错误。
    SKYNET_BATTLE_NAV_FRAME_API void fs_close(void *handle);

    /// 校验意图并推进一帧；不成功时返回 0 且不提交半帧结果。
    /// @param handle 当前 Battle 独占的 Engine handle。
    /// @param x 世界 X 方向分量，取 -1、0、1。
    /// @param z 世界 Z 方向分量，取 -1、0、1。
    /// @param skill 0 不施法、1 近战、2 表现弹丸、3 逻辑火球。
    /// @return 成功返回 1；参数、状态或领域操作失败返回 0。
    SKYNET_BATTLE_NAV_FRAME_API int fs_step(void *handle, int x, int z, int skill);

    /// 将当前状态写入调用方缓冲；不会保存缓冲指针。
    /// @param handle 当前 Battle 独占的 Engine handle。
    /// @param out 调用方提供的输出缓冲区。
    /// @param capacity out 的字节容量；小于完整状态长度时失败。
    /// @return 成功返回写入字节数；失败返回 0。
    SKYNET_BATTLE_NAV_FRAME_API int fs_save(void *handle, unsigned char *out, int capacity);

    /// 验证候选 Checkpoint 后恢复 Engine；失败时保留旧状态。
    /// @param handle 当前 Battle 独占的 Engine handle。
    /// @param bytes 借用的规范化状态字节，仅在本次调用期间读取。
    /// @param count bytes 的有效字节数。
    /// @return 成功返回 1；无效 handle、长度或状态返回 0。
    SKYNET_BATTLE_NAV_FRAME_API int fs_restore(void *handle, const unsigned char *bytes, int count);

    /// 返回地图身份；空 handle 返回 0。该值不是运行时版本握手。
    /// @param handle 当前 Battle 的 Engine handle。
    SKYNET_BATTLE_NAV_FRAME_API std::uint32_t fs_map_version(void *handle);
    SKYNET_BATTLE_NAV_FRAME_API std::uint32_t fs_map_id(void *handle);
} // extern "C"
```

### server/native/frame_sync/frame_core.cpp

**操作：新建。** 让按键意图按固定阶段产生位置、技能和伤害；两端编译同一份实现。

学习导航：精读 move的子步与取整、冷却/弹丸所有权、同帧统一伤害、候选restore和异常原子提交。 可以略读固定声明与语言样板。输入、输出和失败语义见文件头及 API 注释；本节验证命令在该阶段末尾。阅读后应能解释这些状态的 owner、修改时机和释放位置。

```cpp
// 职责：实现帧同步纯整数规则、规范化状态和C ABI异常边界。
// 输入：Input与固定地图；输出：State；无网络、锁、Timer或随机全局状态。
#include "frame_core.h"
#include "bmap_reader.h"
#include "grid_pathfinder.h"
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <stdexcept>

namespace lesson_frame
{
namespace
{
// 静态技能定义不进入可变运行状态；Unit 只保存各技能下次可施放的帧号。
enum class SkillEffect
{
    kInstant,     // 当前帧直接提交伤害。
    kVisualBolt,  // 当前帧提交伤害；弹丸只负责表现，不再次结算。
    kLogicalBolt, // 弹丸到达目标时提交伤害。
};
struct Skill
{
    std::int64_t  range;        // 施法最大距离，单位 mm，按三轴距离判定。
    std::uint32_t cooldown;     // 冷却时长，单位逻辑帧。
    std::int32_t  damage;       // 正式伤害点数；只由 Engine 提交。
    SkillEffect   effect;       // 命中/弹丸的逻辑生效时机。
    std::uint32_t target_modes; // 可选目标移动类型位标记：1 地面、2 空中、3 两者。
};
// 数组下标对应 skill 编号减一；射程用 mm，冷却用固定逻辑帧。
constexpr Skill        kSkills[]      = {{900, 12, 14, SkillEffect::kInstant, 1},
                                         {9000, 24, 12, SkillEffect::kVisualBolt, 3},
                                         {9000, 24, 20, SkillEffect::kLogicalBolt, 3}};
// 每轴绝对坐标不超过 500,000,000mm，最大轴差为 1,000,000,000mm；
// 三轴平方和最多为 3e18，小于 int64 上限，保证 distance2 的乘加不溢出。
constexpr std::int64_t kPositionLimit = 500000000;
std::int32_t           sign(std::int64_t value)
{
    return (value > 0) - (value < 0);
}
// 先限制单轴，平方和在int64范围内；positions经过输入/restore边界验证。
std::int64_t distance2(const Unit &a, const Unit &b)
{
    const auto dx = a.x - b.x;
    const auto dz = a.z - b.z;
    const auto dy = a.y - b.y;
    return dx * dx + dy * dy + dz * dz;
}
void put(std::string &out, std::uint64_t value, unsigned count)
{
    for (unsigned i = 0; i < count; ++i)
        out.push_back(static_cast<char>((value >> (8 * i)) & 255));
}
std::uint64_t get(const std::string &in, std::size_t &offset, unsigned count)
{
    if (offset + count > in.size())
        throw std::runtime_error("STATE_TRUNCATED");
    std::uint64_t value = 0;
    for (unsigned i = 0; i < count; ++i)
        value |= static_cast<std::uint64_t>(static_cast<unsigned char>(in[offset++])) << (8 * i);
    return value;
}
std::int64_t signedValue(std::uint64_t bits)
{
    // 不依赖无符号大值转有符号的实现定义行为；显式还原二补数。
    return bits <= static_cast<std::uint64_t>(INT64_MAX)
               ? static_cast<std::int64_t>(bits)
               : -1 - static_cast<std::int64_t>(UINT64_MAX - bits);
}
void checkPosition(std::int64_t value)
{
    if (value < -kPositionLimit || value > kPositionLimit)
        throw std::runtime_error("POSITION_RANGE");
}

std::size_t readStateHeader(const std::string &bytes, std::size_t &offset, State &candidate)
{
    if (get(bytes, offset, 4) != 1)
        throw std::runtime_error("STATE_VERSION");
    candidate.frame     = static_cast<std::uint32_t>(get(bytes, offset, 4));
    candidate.winner    = static_cast<std::uint32_t>(get(bytes, offset, 4));
    candidate.next_bolt = static_cast<std::uint32_t>(get(bytes, offset, 4));
    const auto count    = get(bytes, offset, 4);
    if (count < 1 || count > kMaxUnits || candidate.frame > kMaxFrames || candidate.winner > 3 ||
        candidate.next_bolt == 0 || candidate.next_bolt > kMaxFrames * kMaxUnits + 1)
        throw std::runtime_error("STATE_RANGE");
    return static_cast<std::size_t>(count);
}
Unit readUnit(const std::string &bytes, std::size_t &offset, const State &candidate)
{
    Unit unit;
    unit.id        = static_cast<std::uint32_t>(get(bytes, offset, 4));
    unit.camp      = static_cast<std::uint32_t>(get(bytes, offset, 4));
    unit.move_mode = static_cast<std::uint32_t>(get(bytes, offset, 4));
    unit.x         = signedValue(get(bytes, offset, 8));
    unit.y         = signedValue(get(bytes, offset, 8));
    unit.z         = signedValue(get(bytes, offset, 8));
    const auto hp  = get(bytes, offset, 4);
    if (hp > 100)
        throw std::runtime_error("STATE_HP");
    unit.hp       = static_cast<std::int32_t>(hp);
    unit.ready[0] = static_cast<std::uint32_t>(get(bytes, offset, 4));
    unit.ready[1] = static_cast<std::uint32_t>(get(bytes, offset, 4));
    unit.ready[2] = static_cast<std::uint32_t>(get(bytes, offset, 4));
    checkPosition(unit.x);
    checkPosition(unit.y);
    checkPosition(unit.z);
    if (unit.ready[0] > candidate.frame + 24 || unit.ready[1] > candidate.frame + 24 ||
        unit.ready[2] > candidate.frame + 24 || (unit.move_mode != 1 && unit.move_mode != 2) ||
        unit.id == 0 || (unit.camp != 1 && unit.camp != 2) || unit.hp < 0 || unit.hp > 100 ||
        (!candidate.units.empty() && candidate.units.back().id >= unit.id))
        throw std::runtime_error("STATE_UNIT");
    return unit;
}
Bolt readBolt(const std::string &bytes, std::size_t &offset, const State &candidate)
{
    Bolt bolt;
    bolt.id      = static_cast<std::uint32_t>(get(bytes, offset, 4));
    bolt.caster  = static_cast<std::uint32_t>(get(bytes, offset, 4));
    bolt.target  = static_cast<std::uint32_t>(get(bytes, offset, 4));
    bolt.expires = static_cast<std::uint32_t>(get(bytes, offset, 4));
    bolt.damage  = static_cast<std::int32_t>(get(bytes, offset, 4));
    bolt.x       = signedValue(get(bytes, offset, 8));
    bolt.y       = signedValue(get(bytes, offset, 8));
    bolt.z       = signedValue(get(bytes, offset, 8));
    checkPosition(bolt.x);
    checkPosition(bolt.y);
    checkPosition(bolt.z);
    const auto exists = [&](std::uint32_t id)
    {
        return std::any_of(candidate.units.begin(), candidate.units.end(),
                           [&](const Unit &unit) { return unit.id == id; });
    };
    if ((bolt.damage != 0 && bolt.damage != 20) || !exists(bolt.caster) || !exists(bolt.target) ||
        bolt.expires <= candidate.frame || bolt.expires > candidate.frame + 60 || bolt.id == 0 ||
        bolt.id >= candidate.next_bolt ||
        (!candidate.bolts.empty() && candidate.bolts.back().id >= bolt.id))
        throw std::runtime_error("STATE_BOLT");
    return bolt;
}
} // namespace

Engine::Engine(std::shared_ptr<const flywow_navigation::GridMap> map)
    : map_(std::move(map)), context_(map_)
{
    if (!map_ || map_->metadata().cell_size_mm < 100)
        throw std::runtime_error("MAP_CELL_SIZE");
    reset();
}
bool Engine::sample(std::int64_t x, std::int64_t z, std::int64_t from_y, std::int64_t &y) const
{
    const auto result = map_->QueryWorld({x, from_y, z});
    if (!result.ok() || !result.value.IsWalkable())
        return false;
    const auto radius_cells =
        (200u + map_->metadata().cell_size_mm - 1) / map_->metadata().cell_size_mm;
    if (result.value.clearance_cells < radius_cells)
        return false;
    y = result.value.height_mm;
    return std::abs(y - from_y) <= 600;
}
bool Engine::sampleAir(std::int64_t x, std::int64_t z, std::int64_t desired_y,
                       std::int64_t &y) const
{
    const auto result = map_->QueryWorld({x, 0, z});
    if (!result.ok())
        return false;
    if (desired_y < static_cast<std::int64_t>(result.value.height_mm) + 200 || desired_y > 10000)
        return false;
    y = desired_y;
    return true; // 不读取IsWalkable/clearance；该地图尚无空域禁飞与天花板资产。
}
void Engine::reset()
{
    State candidate;
    candidate.units = {{1001, 1, 1, -11000, 0, 4000, 100, {}},
                       {2001, 2, 2, 11000, 2000, -4000, 100, {}},
                       {2002, 2, 1, 11000, 0, -4000, 100, {}}};
    for (auto &unit : candidate.units)
        if (!(unit.move_mode == 2 ? sampleAir(unit.x, unit.z, unit.y, unit.y)
                                  : sample(unit.x, unit.z, unit.y, unit.y)))
            throw std::runtime_error("SPAWN_BLOCKED");
    state_ = std::move(candidate);
}
std::size_t Engine::target(const Unit &unit, std::uint32_t target_modes) const
{
    std::size_t  best          = state_.units.size();
    std::int64_t best_distance = INT64_MAX;
    for (std::size_t i = 0; i < state_.units.size(); ++i)
    {
        const auto &other = state_.units[i];
        if (other.hp <= 0 || other.camp == unit.camp || (other.move_mode & target_modes) == 0)
            continue;
        const auto d = distance2(unit, other);
        if (d < best_distance)
        {
            best          = i;
            best_distance = d;
        }
    }
    return best; // ID排序保证等距时优先较小ID。
}
void Engine::chaseAir(const Unit &unit, const Unit &other, Input &input) const
{
    input.x               = sign(other.x - unit.x);
    input.z               = sign(other.z - unit.z);
    // 水平距离越大，追击高度越高；接近目标时下俯，目标移动后重新计算。
    const auto horizontal = std::max(std::abs(other.x - unit.x), std::abs(other.z - unit.z));
    const auto desired_y  = other.y + 400 + std::min<std::int64_t>(2400, horizontal / 2);
    input.y               = std::abs(desired_y - unit.y) >= 150 ? sign(desired_y - unit.y) : 0;
    std::int64_t probe_y  = unit.y;
    if (!sampleAir(unit.x + input.x * 150, unit.z + input.z * 150, unit.y, probe_y))
        input.y = 1;
    if (distance2(unit, other) <= 800 * 800)
        input.x = input.z = 0;
}
void Engine::chaseGround(const Unit &unit, const Unit &other, Input &input)
{
    auto profile               = flywow_navigation::MakeDefaultNavigationProfile(unit.id);
    profile.radius_mm          = 200;
    profile.max_step_mm        = 600;
    profile.max_slope_permille = 1500;
    const auto path            = flywow_navigation::GridPathfinder::FindPathStatic(
        context_, profile, {unit.x, unit.y, unit.z}, {other.x, other.y, other.z});
    // 路线不存入逻辑事实：相同当前State重新查询得到相同结果；不可达停住。
    if (path.ok() && path.value.count() > 1)
    {
        const auto &next = path.value.WorldPoint(1);
        input.x          = sign(next.x_mm - unit.x);
        input.z          = sign(next.z_mm - unit.z);
    }
}
Input Engine::ai(const Unit &unit)
{
    const auto index = target(unit);
    if (index == state_.units.size())
        return {};
    const auto &other = state_.units[index];
    Input       input;
    if (unit.move_mode == 2)
        chaseAir(unit, other, input);
    else if (distance2(unit, other) > 800 * 800)
        chaseGround(unit, other, input);
    input.skill = distance2(unit, other) <= 900 * 900 && other.move_mode == 1 ? 1 : 3;
    return input;
}
void Engine::move(Unit &unit, Input input)
{
    // 3000mm/s × 50ms / 1000 = 150mm；对角分量乘707/1000约为1/sqrt(2)。
    // 这里的106mm量化是玩法合同，两端使用同一代码；不使用平台sqrt。
    if (unit.move_mode == 1)
        input.y = 0;
    const int          axes   = (input.x != 0) + (input.z != 0) + (input.y != 0);
    const std::int64_t length = axes == 3 ? 86 : axes == 2 ? 106 : 150;
    const auto         dx     = input.x * length;
    const auto         dz     = input.z * length;
    const auto         dy     = input.y * length;
    // 最大子步不超过cell/4，防止跨越一个阻挡格；最多8步。
    const auto         stride = std::max<std::int64_t>(1, map_->metadata().cell_size_mm / 4);
    const auto         steps  = std::max<std::int64_t>(1, (length + stride - 1) / stride);
    for (std::int64_t n = 1; n <= steps; ++n)
    {
        const auto   sx = dx * n / steps - dx * (n - 1) / steps;
        const auto   sz = dz * n / steps - dz * (n - 1) / steps;
        const auto   sy = dy * n / steps - dy * (n - 1) / steps;
        std::int64_t y  = unit.y;
        // X后Z是固定的贴墙滑动顺序；不是由物理回调执行顺序决定。
        if (unit.move_mode == 2 ? sampleAir(unit.x + sx, unit.z, unit.y, y)
                                : sample(unit.x + sx, unit.z, unit.y, y))
        {
            unit.x += sx;
            unit.y = y;
        }
        if (unit.move_mode == 2 ? sampleAir(unit.x, unit.z + sz, unit.y, y)
                                : sample(unit.x, unit.z + sz, unit.y, y))
        {
            unit.z += sz;
            unit.y = y;
        }
        if (unit.move_mode == 2 && sampleAir(unit.x, unit.z, unit.y + sy, y))
            unit.y = y;
    }
}
void Engine::cast(Unit &unit, std::int32_t skill_id, std::vector<std::int32_t> &damage)
{
    if (skill_id == 0)
        return;
    const auto &def   = kSkills[skill_id - 1];
    const auto  index = target(unit, def.target_modes);
    if (index == state_.units.size() || state_.frame < unit.ready[skill_id - 1] ||
        distance2(unit, state_.units[index]) > def.range * def.range ||
        (def.target_modes & state_.units[index].move_mode) == 0)
        return;
    if (def.effect == SkillEffect::kLogicalBolt && state_.bolts.size() >= kMaxBolts)
        return;

    unit.ready[skill_id - 1] = state_.frame + def.cooldown;
    if (def.effect == SkillEffect::kInstant)
    {
        damage[index] += def.damage;
        return;
    }
    if (def.effect == SkillEffect::kVisualBolt)
        damage[index] += def.damage; // 表现飞行不会改变已经结算的伤害。
    if (state_.bolts.size() >= kMaxBolts)
        return; // 表现球满槽仅降级视觉，不撤回已提交的伤害与冷却。
    state_.bolts.push_back({state_.next_bolt++, unit.id, state_.units[index].id, state_.frame + 60,
                            def.effect == SkillEffect::kVisualBolt ? 0 : def.damage, unit.x, unit.y,
                            unit.z});
}
void Engine::projectiles(std::vector<std::int32_t> &damage)
{
    std::vector<Bolt> surviving;
    surviving.reserve(kMaxBolts);
    for (auto bolt : state_.bolts)
    {
        const auto it = std::find_if(state_.units.begin(), state_.units.end(), [&](const Unit &unit)
                                     { return unit.id == bolt.target && unit.hp > 0; });
        if (it == state_.units.end() || bolt.expires <= state_.frame)
            continue;
        const auto dx   = it->x - bolt.x;
        const auto dz   = it->z - bolt.z;
        const auto dy   = it->y - bolt.y;
        const auto span = std::max({std::abs(dx), std::abs(dy), std::abs(dz)});
        // 400mm/frame；以Chebyshev长度归一保证整数确定性，技能规则不是欧氏匀速。
        if (span <= 400)
        {
            damage[static_cast<std::size_t>(it - state_.units.begin())] += bolt.damage;
            continue;
        }
        bolt.x += dx * 400 / span;
        bolt.z += dz * 400 / span;
        bolt.y += dy * 400 / span;
        surviving.push_back(bolt);
    }
    state_.bolts.swap(surviving); // 保持原ID顺序；回滚后迭代顺序不改变。
}
void Engine::finish(const std::vector<std::int32_t> &damage)
{
    bool alive1 = false;
    bool alive2 = false;
    for (std::size_t i = 0; i < state_.units.size(); ++i)
    {
        auto &unit = state_.units[i];
        unit.hp    = std::max(0, unit.hp - damage[i]);
        alive1 |= unit.hp > 0 && unit.camp == 1;
        alive2 |= unit.hp > 0 && unit.camp == 2;
    }
    if (!alive1 || !alive2)
        state_.winner = alive1 ? 1 : alive2 ? 2 : 3;
    else if (state_.frame >= kMaxFrames)
        state_.winner = 3;
}
void Engine::step(Input input)
{
    // API原子提交：任何异常恢复旧逻辑状态；临时内存失败不留下半帧。
    State before = state_;
    try
    {
        stepUnchecked(input);
    }
    catch (...)
    {
        state_ = std::move(before);
        throw;
    }
}
void Engine::stepUnchecked(Input input)
{
    if (state_.winner != 0)
        throw std::runtime_error("BATTLE_FINISHED");
    if (input.x < -1 || input.x > 1 || input.z < -1 || input.z > 1 || input.y != 0 ||
        input.skill < 0 || input.skill > 3)
        throw std::runtime_error("BAD_INPUT");
    ++state_.frame;
    std::vector<Input> inputs;
    for (const auto &unit : state_.units)
        inputs.push_back(unit.id == 1001 ? input : ai(unit));
    for (std::size_t i = 0; i < state_.units.size(); ++i)
        if (state_.units[i].hp > 0)
            move(state_.units[i], inputs[i]);

    std::vector<std::int32_t> damage(state_.units.size(), 0);
    for (std::size_t i = 0; i < state_.units.size(); ++i)
        if (state_.units[i].hp > 0)
            cast(state_.units[i], inputs[i].skill, damage);
    projectiles(damage);
    finish(damage); // 同帧统一提交伤害；不会因先处理ID小者而取消对方同帧攻击。
}
std::string Engine::save() const
{
    std::string out;
    out.reserve(128 + state_.units.size() * 52 + state_.bolts.size() * 44);
    put(out, 1, 4);
    put(out, state_.frame, 4);
    put(out, state_.winner, 4);
    put(out, state_.next_bolt, 4);
    put(out, state_.units.size(), 4);
    for (const auto &unit : state_.units)
    {
        put(out, unit.id, 4);
        put(out, unit.camp, 4);
        put(out, unit.move_mode, 4);
        put(out, static_cast<std::uint64_t>(unit.x), 8);
        put(out, static_cast<std::uint64_t>(unit.y), 8);
        put(out, static_cast<std::uint64_t>(unit.z), 8);
        put(out, static_cast<std::uint32_t>(unit.hp), 4);
        put(out, unit.ready[0], 4);
        put(out, unit.ready[1], 4);
        put(out, unit.ready[2], 4);
    }
    put(out, state_.bolts.size(), 4);
    for (const auto &bolt : state_.bolts)
    {
        put(out, bolt.id, 4);
        put(out, bolt.caster, 4);
        put(out, bolt.target, 4);
        put(out, bolt.expires, 4);
        put(out, static_cast<std::uint32_t>(bolt.damage), 4);
        put(out, static_cast<std::uint64_t>(bolt.x), 8);
        put(out, static_cast<std::uint64_t>(bolt.y), 8);
        put(out, static_cast<std::uint64_t>(bolt.z), 8);
    }
    return out;
}
void Engine::restore(const std::string &bytes)
{
    std::size_t offset = 0;
    State       candidate;
    const auto  count = readStateHeader(bytes, offset, candidate);
    for (std::size_t i = 0; i < count; ++i)
        candidate.units.push_back(readUnit(bytes, offset, candidate));

    const auto bolts = get(bytes, offset, 4);
    if (bolts > kMaxBolts)
        throw std::runtime_error("STATE_BOLTS");
    for (std::size_t i = 0; i < bolts; ++i)
        candidate.bolts.push_back(readBolt(bytes, offset, candidate));
    if (offset != bytes.size())
        throw std::runtime_error("STATE_TRAILING");
    state_ = std::move(candidate); // 所有校验通过后唯一发布点。
}
} // namespace lesson_frame

extern "C" void *fs_open(const char *path)
{
    try
    {
        if (!path)
            return nullptr;
        const auto map = flywow_navigation::BMapReader::Read(path);
        return map.ok() ? new lesson_frame::Engine(map.value) : nullptr;
    }
    catch (...)
    {
        return nullptr;
    }
}
extern "C" void fs_close(void *handle)
{
    delete static_cast<lesson_frame::Engine *>(handle);
}
extern "C" int fs_step(void *handle, int x, int z, int skill)
{
    try
    {
        if (!handle)
            return 0;
        static_cast<lesson_frame::Engine *>(handle)->step({x, z, 0, skill});
        return 1;
    }
    catch (...)
    {
        return 0;
    }
}
extern "C" int fs_save(void *handle, unsigned char *out, int capacity)
{
    try
    {
        if (!handle || !out || capacity < 0)
            return 0;
        const auto bytes = static_cast<lesson_frame::Engine *>(handle)->save();
        if (bytes.size() > static_cast<std::size_t>(capacity))
            return 0;
        std::memcpy(out, bytes.data(), bytes.size());
        return static_cast<int>(bytes.size());
    }
    catch (...)
    {
        return 0;
    }
}
extern "C" int fs_restore(void *handle, const unsigned char *bytes, int count)
{
    try
    {
        if (!handle || !bytes || count < 0 || count > 16384)
            return 0;
        static_cast<lesson_frame::Engine *>(handle)->restore(
            std::string(reinterpret_cast<const char *>(bytes), count));
        return 1;
    }
    catch (...)
    {
        return 0;
    }
}

extern "C" std::uint32_t fs_map_version(void *handle)
{
    return handle ? static_cast<lesson_frame::Engine *>(handle)->mapVersion() : 0;
}
extern "C" std::uint32_t fs_map_id(void *handle)
{
    return handle ? static_cast<lesson_frame::Engine *>(handle)->mapId() : 0;
}
```

### server/native/frame_sync/frame_binding.cpp

**操作：新建。** 让一个Skynet Worker Lua State拥有Native模拟，关闭时明确释放。

学习导航：精读 借用userdata仅存活于回调；错误以nil/error返回；close与GC各自负责什么。 可以略读固定声明与语言样板。输入、输出和失败语义见文件头及 API 注释；本节验证命令在该阶段末尾。阅读后应能解释这些状态的 owner、修改时机和释放位置。

```cpp
// 职责：帧同步宿主Lua Binding；不持有Socket、Service handle或全局模拟对象。
// 每个userdata独占Engine；close幂等，GC兜底。调用同步不yield。
#include "frame_core.h"
#include "lua_binding.h"
#include "lua_table.h"
#include <memory>
using flywow_lua_binding::LuaBinding;
using flywow_lua_binding::LuaTable;
namespace
{
constexpr const char *kType = "lesson.frame.engine";
struct Owner
{
    void *handle = nullptr;
    ~Owner() noexcept
    {
        fs_close(handle);
    }
};
// 封装层固定栈/引用合同：参数读取不弹栈，returnValues压结果；临时LuaTable的
// registry引用在回调退出时unref，Lua栈中的返回值继续持有对象。无longjmp错误API。
int openEngine(lua_State *state)
{
    LuaBinding  lua(state);
    std::string path;
    if (!lua.readValue(1, path))
        return lua.pushError();
    Owner *owner = nullptr;
    if (!lua.newUserdata(kType, owner))
        return lua.pushError();
    owner->handle = fs_open(path.c_str());
    if (!owner->handle)
        return lua.pushError("MAP_LOAD", "cannot open battle map");
    return lua.returnValues(owner);
}
int stepEngine(lua_State *state)
{
    LuaBinding lua(state);
    Owner     *owner = nullptr;
    int        x = 0, z = 0, skill = 0;
    if (!lua.readUserdata(1, kType, owner) || !lua.readValue(2, x) || !lua.readValue(3, z) ||
        !lua.readValue(4, skill))
        return lua.pushError();
    if (!fs_step(owner->handle, x, z, skill))
        return lua.pushError("STEP_FAILED", "invalid input or finished state");
    return lua.returnValues(true);
}
int saveEngine(lua_State *state)
{
    LuaBinding lua(state);
    Owner     *owner = nullptr;
    if (!lua.readUserdata(1, kType, owner))
        return lua.pushError();
    unsigned char buffer[16384];
    const int     count = fs_save(owner->handle, buffer, sizeof(buffer));
    if (count == 0)
        return lua.pushError("STATE_SAVE", "closed engine or state overflow");
    return lua.returnValues(std::string(reinterpret_cast<char *>(buffer), count));
}
int restoreEngine(lua_State *state)
{
    LuaBinding  lua(state);
    Owner      *owner = nullptr;
    std::string bytes;
    if (!lua.readUserdata(1, kType, owner) || !lua.readValue(2, bytes))
        return lua.pushError();
    if (!fs_restore(owner->handle, reinterpret_cast<const unsigned char *>(bytes.data()),
                    static_cast<int>(bytes.size())))
        return lua.pushError("STATE_RESTORE", "invalid or incompatible checkpoint");
    return lua.returnValues(true);
}
int closeEngine(lua_State *state)
{
    LuaBinding lua(state);
    Owner     *owner = nullptr;
    if (!lua.readUserdata(1, kType, owner))
        return lua.pushError();
    fs_close(owner->handle);
    owner->handle = nullptr; // GC只析构Owner一次，不再释放旧指针。
    return lua.returnValues(true);
}
int identity(lua_State *state)
{
    LuaBinding lua(state);
    Owner     *owner = nullptr;
    if (!lua.readUserdata(1, kType, owner))
        return lua.pushError();
    if (!owner->handle)
        return lua.pushError("CLOSED", "engine is closed");
    return lua.returnValues(fs_map_id(owner->handle), fs_map_version(owner->handle));
}
} // namespace
extern "C" int luaopen_lesson_frame_native(lua_State *state)
{
    LuaBinding lua(state);
    LuaTable   meta;
    if (!lua.registerUserdata<Owner>(kType, meta))
        return lua.pushError();
    auto methods = lua.newTable();
    methods.setFunction("step", stepEngine);
    methods.setFunction("save", saveEngine);
    methods.setFunction("restore", restoreEngine);
    methods.setFunction("close", closeEngine);
    methods.setFunction("identity", identity);
    meta.writeValue("__index", methods);
    auto module = lua.newTable();
    module.setFunction("open", openEngine);
    return lua.returnValues(module);
}
```

### server/native/frame_sync/CMakeLists.txt

**操作：新建。** 把同一核心编译为Linux Lua模块与Windows Unity DLL，不下载或复制FlyWow源码。

学习导航：精读 C++17、固定 Lua ABI、真实子模块源码路径和 CMake 目标边界。可以略读固定声明与语言样板。输入、输出和失败语义见文件头及 API 注释；本节验证命令在该阶段末尾。阅读后应能解释这些状态的 owner、修改时机和释放位置。

```cmake
# 职责：构建宿主Frame Core、Lua Binding和Unity Native DLL；源码来自固定子模块。
# 输入：固定FlyWow/Skynet源码；输出：frame_core DLL/so、lesson_frame_native.so和Golden。
cmake_minimum_required(VERSION 3.16)
project(lesson_frame LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(FLYWOW "${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/skynet-flywow")
set(GRID "${FLYWOW}/navigation/native/grid_map")
add_library(frame_core SHARED
    frame_core.cpp
    "${GRID}/bmap_reader.cpp"
    "${GRID}/grid_map.cpp"
    "${GRID}/nav_result.cpp"
    "${GRID}/dynamic_occupancy.cpp"
    "${GRID}/navigation_context.cpp"
    "${GRID}/navigation_profile_registry.cpp"
    "${GRID}/grid_pathfinder.cpp"
)
target_include_directories(frame_core PUBLIC . "${GRID}")
if(MSVC)
    target_compile_options(frame_core PRIVATE /W4 /permissive- /EHsc /utf-8)
    set_target_properties(frame_core PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
else()
    target_compile_options(frame_core PRIVATE -Wall -Wextra -Wpedantic)
endif()
add_executable(frame_test frame_test.cpp)
target_link_libraries(frame_test PRIVATE frame_core)
if(MSVC)
    target_compile_options(frame_test PRIVATE /UNDEBUG /utf-8)
else()
    target_compile_options(frame_test PRIVATE -UNDEBUG)
endif()
option(LESSON_FRAME_LUA "构建固定Skynet Lua Binding" ON)
if(LESSON_FRAME_LUA)
    set(SKYNET_LUA_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/skynet/3rd/lua")
    add_subdirectory("${FLYWOW}/lua-binding" "${CMAKE_BINARY_DIR}/lua-binding" EXCLUDE_FROM_ALL)
    add_library(lesson_frame_native MODULE frame_binding.cpp)
    target_include_directories(lesson_frame_native PRIVATE
        "${SKYNET_LUA_DIR}"
        "${FLYWOW}/lua-binding"
    )
    target_link_libraries(lesson_frame_native PRIVATE frame_core flywow_lua_binding)
    set_target_properties(lesson_frame_native PROPERTIES PREFIX "" BUILD_RPATH "$ORIGIN")
endif()
enable_testing()
add_test(
    NAME frame_native
    COMMAND frame_test
        "${CMAKE_CURRENT_SOURCE_DIR}/../../../shared/navigation/battle_1001/battle_1001.bmap"
)
```

### server/native/frame_sync/frame_test.cpp

**操作：新建。** 在接网络之前锁住重复运行、回滚恢复、损坏状态和异常不提交的合同。

学习导航：精读 比较规范化bytes，而不是结构体padding；Golden输出可跨Windows/Linux逐行比较。 可以略读固定声明与语言样板。输入、输出和失败语义见文件头及 API 注释；本节验证命令在该阶段末尾。阅读后应能解释这些状态的 owner、修改时机和释放位置。

```cpp
// 职责：帧同步Native聚焦回归与跨平台Golden；不启动Server。
#include "bmap_reader.h"
#include "frame_core.h"
#include <cassert>
#include <chrono>
#include <iomanip>
#include <iostream>
std::uint32_t hashBytes(const std::string &bytes)
{
    std::uint32_t hash = 2166136261u;
    for (unsigned char byte : bytes)
        hash = (hash ^ byte) * 16777619u;
    return hash; // 模拟分歧诊断用FNV32，不是密码或资产完整性hash。
}
int main(int argc, char **argv)
{
    if (argc != 2)
        return 2;
    const auto map = flywow_navigation::BMapReader::Read(argv[1]);
    if (!map.ok())
        return 3;
    lesson_frame::Engine a(map.value), b(map.value);
    const auto           initial = a.save();
    assert(a.state().units[0].move_mode == 1 && a.state().units[1].move_mode == 2);
    const auto born_y = a.state().units[1].y;
    for (int i = 0; i < 12; ++i)
        a.step({});
    assert(a.state().units[1].y != born_y); // Server AI确实升降，不固定高度。
    a.restore(initial);
    for (int i = 0; i < 240 && a.state().winner == 0; ++i)
    {
        const lesson_frame::Input input{(i / 30) % 3 - 1, (i / 45) % 3 - 1, 0,
                                        i % 20 == 0   ? 2
                                        : i % 12 == 0 ? 1
                                                      : 0};
        const auto                before = a.save();
        a.step(input);
        b.step(input);
        assert(a.save() == b.save());
        b.restore(before);
        b.step(input);
        assert(a.save() == b.save());
        std::cout << "GOLDEN " << a.state().frame << " " << hashBytes(a.save()) << "\n";
    }
    const auto saved = a.save();
    try
    {
        a.restore(saved + "x");
        assert(false);
    }
    catch (...)
    {
    }
    assert(a.save() == saved);
    try
    {
        a.step({9, 0, 0});
        assert(false);
    }
    catch (...)
    {
    }
    assert(a.save() == saved);
    a.restore(initial);
    assert(a.save() == initial);
    std::cout << "FRAME_NATIVE_OK map=" << a.mapId() << ":" << a.mapVersion() << "\n";
}
```

### server/tests/frame_binding_test.lua

**操作：新建。** 验证真实userdata加载、返回错误和幂等关闭。

学习导航：精读 Lua State拥有两个独立Engine；非法调用不会借助pcall抛出参数错误。 可以略读固定声明与语言样板。输入、输出和失败语义见文件头及 API 注释；本节验证命令在该阶段末尾。阅读后应能解释这些状态的 owner、修改时机和释放位置。

```lua
--- 职责：真实Native Binding聚焦测试；须在server工作目录使用固定Lua运行。
package.cpath = "./build/frame_sync/?.so;" .. package.cpath
local native = require "lesson_frame_native"
local a = assert(native.open("../shared/navigation/battle_1001/battle_1001.bmap"))
local b = assert(native.open("../shared/navigation/battle_1001/battle_1001.bmap"))
assert(a:save() == b:save())
local before = assert(a:save())
local ok, err = a:step(9,0,0,0)
assert(ok == nil and type(err.code) == "string")
assert(a:save() == before)
assert(a:step(1,0,3,0))
assert(a:save() ~= b:save(), "separate userdata must own separate State")
assert(b:restore(a:save()))
assert(a:save() == b:save())
assert(a:close())
assert(a:close())
ok, err = a:save()
assert(ok == nil and type(err.code) == "string")
assert(b:close())
collectgarbage("collect")
print("FRAME_BINDING_OK")
```

### 2.5 第一次跨 Lua/C++ 边界怎样审计

`require "lesson_frame_native"` 查 `package.cpath`，加载 `server/build/frame_sync/lesson_frame_native.so`，Lua 自动调用 `luaopen_lesson_frame_native`。每个 Service 都有独立 Lua State/module cache；同一 OS 进程可以多次进入 open。每次 `native.open()` 创建独占 Engine userdata，不能把可变 Engine 当成共享全局对象。

Owner 存 Native handle：显式 close 把它设为 null；GC 只析构 userdata 里的 Owner 一次，所以不会重复释放旧 handle。Binding 读取参数失败使用返回值 `nil,error`，不依赖 Lua longjmp 穿过 C++ 局部析构。LuaTable/LuaBinding 的栈与 registry reference 机制由固定 FlyWow 的 `lua-binding/` 实现，调用方借用 userdata 至当前回调结束，不把其裸指针跨 yield 保留。

先仅构建新 Core，不启动 Server：

```bash
cd /home/simbi/workspace/skynet-battle-navigation-commercial-learning/server
cmake -S native/frame_sync -B build/frame_sync -DCMAKE_BUILD_TYPE=Release
cmake --build build/frame_sync --parallel 4
ctest --test-dir build/frame_sync --output-on-failure
./third_party/skynet/3rd/lua/lua tests/frame_binding_test.lua
```

预期 CTest `frame_native` 通过，Lua 输出 `FRAME_BINDING_OK`。`frame_test` 对两独立实例、restore后重演、坏Checkpoint保持旧状态、非法输入原子失败、飞行敌人高度变化做断言。它输出每帧 `GOLDEN frame hash`，后面与 Windows 比较；这里只证明当前 Linux 实例，不提前宣称跨平台确定性。

失败排查：`MAP_LOAD` 看相对工作目录与BMAP；`SPAWN_BLOCKED` 核对资产版本/出生点；`module not found` 核对 `.so` 名称、cpath 和构建路径；`undefined symbol lua_*` 必须使用Skynet固定Lua，不能随便换系统 Lua 5.3；DLL/so 不是可以跨OS复制使用的同一二进制。

## 3. 由你修复 Gateway 定向主动消息，并先审计

### 3.1 当前拒绝的具体含义

`connection_id>0` 指定一个已经建立的逻辑连接；`request_id=0` 表示主动消息，不属于某个客户端请求的响应。这两个字段并不矛盾。当前 `flywow_gateway.lua` 的 `deliver_data()` 把这个组合当成非法；因此业务虽然产生正式FramePush，却发不到特定玩家。

只允许 `connection_id=0/request_id=0` 的广播不能作为替代：广播会把某场战斗输入发给所有连接。也不能伪造一个旧非零request_id，把主动帧塞到控制请求的等待表。

### 3.2 局部修改 FlyWow Runtime

**操作：局部修改。WSL 子模块文件：**

`server/third_party/skynet-flywow/gateway/service/gateway/flywow_gateway.lua`

只在 `deliver_data(message)` 的参数拒绝条件中，删除这一条：

```lua
        (message.connection_id > 0 and message.request_id == 0) or
```

保留相邻的广播关联检查：

```lua
        (message.connection_id == 0 and message.request_id ~= 0) or
```

不要删除其它类型、整数、epoch、阶段、命令、编码和长度检查。后面的目标连接分支已经按 id 找连接并检查 ready；不需要改成广播循环。修改后的合同：

|connection_id|request_id|含义|
|---:|---:|---|
|>0|>0|该连接的关联响应|
|>0|0|该连接的主动推送|
|0|0|所有ready连接的主动广播|
|0|>0|非法，拒绝|

这是 FlyWow 接入合同的通用修复，代码仍不认识Battle。旧第二课 `server/service/gateway/gateway_proxy.lua` 自身还有“指定连接必须非零request_id”的验证；**本课使用独立 Frame Proxy**，其合同在第5节给出，所以不要求修改旧第二课Proxy，也不暗中依赖它突然支持主动帧。

### 3.3 完整替换审计测试

下面是完整测试文件，保留原关联响应、异步派发、旧epoch与广播用例，再新增两个连接的定向推送审计。握手替身 `ready` 由场景开关控制；它只验证 Gateway 对 ready 的处理，不冒充真实握手密码学测试。调试器替身避免单测引入宿主调试环境。

### server/third_party/skynet-flywow/gateway/tests/gateway_async_test.lua

**操作：完整替换（先比较你已有测试修改）。** 审计定向主动消息，同时保持原异步合同回归。

学习导航：精读 完整替换测试夹具；所有断言只代表替身单测，不替代真实网络测试。 可以略读固定声明与语言样板。输入、输出和失败语义见文件头及 API 注释；本节验证命令在该阶段末尾。阅读后应能解释这些状态的 owner、修改时机和释放位置。

```lua
-- 职责：以可控 Skynet/socket 替身验证 Gateway 异步合同与资源边界。
-- 边界：Test；加载真实 Gateway/endpoint 源码，替换 transport、registry 和 codec。
-- 输入/输出：FlyWow 根路径 -> 断言或 GATEWAY_ASYNC_UNIT_OK。
-- 生命周期：每场景重建 Lua State 模块状态；不启动网络，不冒充真实集成验证。
-- 不负责：不验证 Protobuf 字节或真实 Skynet 调度，它们由宿主集成测试覆盖。
local root = assert(arg[1])
package.preload["shared.debug.luapanda_debug"] = function()
    return
    {
        start = function() end,
    }
end
package.path = root .. "/gateway/lualib/?.lua;" .. package.path

-- 创建独立的可控场景；overrides 为配置覆盖，无 I/O；返回由测试拥有的控制对象。
local function scenario(overrides)
    local e =
    {
        now     = 0,
        sends   = {},
        forks   = {},
        streams = {},
        started = {},
        writes  = {},
        closed  = {},
    }
    local config =
    {
        host             = "127.0.0.1",
        port             = 19021,
        protocol_version = 3,
        descriptor_path  = "stub",
        registry_module  = "test.registry",
    }
    for k, v in pairs(overrides or {}) do config[k] = v end
    local skynet = {}
    -- 替身不允许数据平面出现同步 call；任何意外等待立即使测试失败。
    function skynet.call()
        error("Gateway must never call handler")
    end
    -- 固定签名记录本地异步消息；返回 session=0，符合 pinned Skynet send。
    function skynet.send(address, protocol, command, message)
        e.sends[#e.sends + 1] = { address, command, message }
        return 0
    end
    -- 注册但不抢先执行任务；测试自行控制协程推进，无 OS 线程。
    function skynet.fork(fn)
        e.forks[#e.forks + 1] = coroutine.create(fn)
    end
    -- 在测试调度器等待下一次扫描。
    function skynet.sleep()
        coroutine.yield("sleep")
    end
    -- 返回测试时钟 tick。
    function skynet.now()
        return e.now
    end
    -- 固定 Service handle。
    function skynet.self()
        return 99
    end
    -- 每场景由外部隔离状态，固定高精度 tick 足够验证不同 epoch 的拒绝。
    function skynet.hpc()
        return 12345
    end
    -- 忽略诊断日志；结果通过状态断言检查。
    function skynet.error()
    end
    -- 捕获管理调用返回 record。
    function skynet.retpack(result)
        e.result = result
    end
    -- 保存真实 Service 的分发回调。
    function skynet.dispatch(protocol, fn)
        e.dispatch = fn
    end
    -- 同步初始化入口，不执行真实调度。
    function skynet.start(fn)
        fn()
    end
    local socket = {}
    -- 固定监听 fd 和地址；无 I/O。
    function socket.listen(host, port)
        return 1, host, port
    end
    -- 监听回调保存供测试注入连接；客户端 start 不执行 I/O。
    function socket.start(fd, fn)
        e.started[fd] = true
        if fn then
            e.accept = fn
        end
    end
    -- 缓冲限制由真实集成验证；替身保持签名。
    function socket.limit()
    end
    -- 警告回调无需触发，真实集成另测写队列。
    function socket.warning(fd, callback)
        e.warning = callback
    end
    -- 精确读取已有字节，不足时挂起；模仿 Socket read 的等待条件。
    function socket.read(fd, size)
        local data = e.streams[fd] or ""
        if #data < size then
            coroutine.yield("read")
            return false, ""
        end
        e.streams[fd] = data:sub(size + 1)
        return data:sub(1, size)
    end
    -- 记录完整 TCP frame；写入失败场景通过标志注入。
    function socket.write(fd, bytes)
        if e.fail_write then
            return false
        end
        e.writes[#e.writes + 1] = { fd, bytes }
        return true
    end
    -- 记录关闭，不复用 fd。
    function socket.close(fd)
        e.closed[fd] = true
        e.started[fd] = nil
    end
    -- 接管前的 accepted fd 必须通过 close_fd 释放。
    function socket.close_fd(fd)
        assert(not e.started[fd], "close_fd is only valid before socket.start")
        e.closed[fd] = true
    end
    -- 与 pinned socket_pool ownership 保持一致。
    function socket.invalid(fd)
        return not e.started[fd]
    end
    local websocket = {}
    -- 接受握手后模拟收到一个 binary 消息，再挂起等待后续消息。
    function websocket.accept(fd, handler)
        e.ws = handler
        handler.handshake(fd, {}, "/")
        handler.message(fd, "1", "binary")
        coroutine.yield("ws")
        return true
    end
    -- 记录 WS 完整消息写入；不 yield。
    function websocket.write(fd, bytes)
        e.writes[#e.writes + 1] = { fd, bytes }
    end
    -- 记录 WS 关闭。
    function websocket.close(fd)
        e.closed[fd] = true
    end
    -- 返回握手前是否尚未建立 WS 对象。
    function websocket.is_close(id)
        return e.ws == nil or e.closed[id] == true
    end
    local registry = {}
    -- 提供只读测试索引。
    function registry.load() return
    {
        count = 1,
    }
    end
    -- 只登记 command=1001。
    function registry.find(index, command)
        if command == 1001 then return
        {
            id            = 1001,
            name          = "QueryCell",
            response_type = ".demo.QueryCellResponse",
        }
        end
    end
    local codec = {}
    -- payload 的数字只用于构造可重复的测试 request data。
    function codec.decode_envelope(payload)
        assert(payload ~= "bad", "malformed envelope")
        return
        {
            protocol_version = 3,
            command          = 1001,
            request_id       = assert(tonumber(payload)),
            body             = "",
        }
    end
    -- 请求 body 替身，与业务无关。
    function codec.decode_request()
        return { test_id = 1, map_id = 1001 }
    end
    -- 响应结果编码为文本，fail 注入编码异常。
    function codec.encode_response(definition, version, request_id, response)
        assert(not response.fail, "encode failure")
        return tostring(request_id)
    end
    package.loaded["skynet"] = skynet
    package.loaded["skynet.socket"] = socket
    package.loaded["http.websocket"] = websocket
    package.loaded["config.gateway"] = config
    package.loaded["test.registry"] = {}
    package.loaded["flywow.gateway.registry"] = registry
    package.loaded["flywow.gateway.codec"] =
    {
        new = function() return codec end,
    }
    package.loaded["flywow_gateway_crypto"] = {}
    package.loaded["flywow.gateway.handshake"] =
    {
        new = function()
            return
            {
                accept = function() return {} end,
                close = function() end,
                ready = function() return e.ready ~= false end,
                expired = function() return false end,
            }
        end,
    }
    dofile(root .. "/gateway/service/gateway/flywow_gateway.lua")
    e.dispatch(1, 8, "start",
    {
        handler_service = ".test_handler",
    }
    )
    return e
end

-- 推进一个替身协程到下一个等待点；异常以断言传播。
local function resume(co)
    local ok, err = coroutine.resume(co)
    assert(ok, err)
end

-- 将数字请求构造成真实 TCP 长度帧，返回调用方拥有的 string。
local function frame(id)
    local payload = tostring(id)
    return string.pack(">I2", #payload) .. payload
end

local e = scenario()
e.streams[10] = frame(1) .. frame(2)
e.accept(10, "peer")
resume(e.forks[2])

assert(#e.sends == 2)
assert(e.sends[1][1] == ".test_handler", "Gateway must send to the configured service name")
assert(e.sends[1][2] == "send_data")
assert(e.sends[1][3].connection_id == 1)
assert(e.sends[2][3].connection_id == 1)
assert(e.sends[1][3].request_id == 1 and e.sends[2][3].request_id == 2)
assert(#e.writes == 0, "Gateway must not write before handler sends data")

local message = e.sends[1][3]
local current_epoch = message.gateway_epoch
message.data = { result = 1 }
e.dispatch(0, 7, "send_data", message)
assert(e.writes[1][2] == frame(1))

message.gateway_epoch = "old"
e.dispatch(0, 7, "send_data", message)
assert(#e.writes == 1, "old Gateway epoch must be dropped")

message.gateway_epoch = current_epoch
message.data = { fail = true }
e.dispatch(0, 7, "send_data", message)
assert(#e.writes == 1, "encoding failure must not close healthy connection")
message.data = { result = 2 }
e.dispatch(0, 999, "send_data", message)
assert(#e.writes == 2, "Gateway does not validate the reply source identity")

local push =
{
    gateway_epoch = current_epoch,
    connection_id = 0,
    command_id = 1001,
    request_id = 0,
    data = { result = 3 },
}
e.dispatch(0, 7, "send_data", push)
assert(#e.writes == 3, "one active connection receives broadcast")

e.dispatch(0, 999, "close",
{
    gateway_epoch = current_epoch,
    connection_id = message.connection_id,
})
resume(e.forks[3])
assert(e.closed[10])

e = scenario()
e.streams[10] = frame(1)
e.accept(10, "peer")
resume(e.forks[2])
assert(e.sends[1][2] == "send_data")
e.dispatch(0, 999, "close", e.sends[1][3])
resume(e.forks[3])
assert(e.closed[10])


-- 两连接定向push审计；与旧用例独立，不修改旧用例的fork下标。
e = scenario()
e.streams[10] = frame(1)
e.streams[11] = frame(2)
e.accept(10, "peer-a")
resume(e.forks[2])
e.accept(11, "peer-b")
resume(e.forks[3])
local targeted =
{
    gateway_epoch = e.sends[1][3].gateway_epoch,
    connection_id = e.sends[1][3].connection_id,
    command_id    = 1001,
    request_id    = 0,
    data          = { result = 7 },
}
e.dispatch(0, 7, "send_data", targeted)
assert(#e.writes == 1 and e.writes[1][1] == 10, "target push must not broadcast")
assert(e.writes[1][2] == frame(0), "push preserves request_id zero")
local epoch = targeted.gateway_epoch
targeted.gateway_epoch = "old"
e.dispatch(0, 7, "send_data", targeted)
assert(#e.writes == 1, "old epoch push must be dropped")
targeted.gateway_epoch = epoch
e.ready = false
e.dispatch(0, 7, "send_data", targeted)
assert(#e.writes == 1, "not-ready push must be dropped")
e.ready = true
targeted.connection_id = 0
e.dispatch(0, 7, "send_data", targeted)
assert(#e.writes == 3, "broadcast still reaches both ready connections")
targeted.request_id = 1
e.dispatch(0, 7, "send_data", targeted)
assert(#e.writes == 3, "broadcast cannot pretend to be correlated response")
targeted.connection_id = 1
targeted.request_id = 0
e.dispatch(0, 7, "close", targeted)
resume(e.forks[4])
e.dispatch(0, 7, "send_data", targeted)
assert(#e.writes == 3, "closed target must not fall back to broadcast")
targeted.connection_id = 9999
e.dispatch(0, 7, "send_data", targeted)
assert(#e.writes == 3, "unknown target must be dropped")
print("GATEWAY_ASYNC_UNIT_OK")
```

### 3.4 先证明测试能抓住旧错误

先放入测试，**暂不删除旧拒绝条件**，从Server工作目录执行：

```bash
./third_party/skynet/3rd/lua/lua \
  third_party/skynet-flywow/gateway/tests/gateway_async_test.lua \
  third_party/skynet-flywow
```

预期在 `target push must not broadcast` 断言失败。再按3.2删除条件，重新执行，预期 `GATEWAY_ASYNC_UNIT_OK`。

审计时逐条回答：指定连接是否只写对应fd？出站request_id是否仍为0？旧epoch、未ready、已关闭、不存在的目标是否直接丢弃？未知目标是否错误退化为广播？非零request_id广播是否仍拒绝？已有请求响应是否仍通过？源码是否保留编码失败不误关健康连接的行为？

本测试没有新增回复来源身份认证。Gateway 当前信任宿主Service边界；新 Frame Proxy对断线来源与绑定Gateway handle做检查，Worker只接收其Dispatcher。Cluster应处于可信部署网络。这些来源边界与这次“允许指定连接request_id=0”修复是不同的审计项，不能看到消息可达就说所有身份校验通过。

暂不因为教程要求而自动commit/push。你审计通过并决定发布时，按WORKSPACE_WORKFLOW：FlyWow子模块先形成已验证提交并推送，主仓库再更新submodule指针，随后Windows同步。提交标题与正文用中文。本文后续步骤在你的当前已修改WSL工作树中也能验证，不要求提前发布一个未审计版本。

## 4. 兼容扩展唯一 Proto，不手写第二份命令表

现有 `QueryCell=1001`、`RunAutoBattle=1002` 与字段号不改变，Envelope仍protocol_version=3。新增命令的 `XxxRequest/XxxResponse` 由FlyWow生成器识别：FrameInput只有Request，FramePush只有Response；输入单向发送，FramePush使用request_id=0。

**操作：局部修改 `shared/protocol/navigation_query.proto` 的CommandId，添加：**

```proto
FRAME_JOIN    = 1101;
FRAME_INPUT   = 1102;
FRAME_PUSH    = 1103;
FRAME_RECOVER = 1104;
FRAME_LEAVE   = 1105;
FRAME_REPLAY  = 1106;
```

**操作：在同一个Proto文件末尾追加以下完整messages。** `.proto.inc`只是本文作者组织片段的名字，不是你要创建的第二份协议文件；不要新增运行时协议源。

```proto
// 职责：以下message追加到navigation_query.proto；CommandId另按正文局部修改。
message FrameCommand
{
    uint32 frame = 1; // 请求生效帧；必须位于Server当前帧之后的窗口内。
    sint32 x     = 2; // -1/0/1，X方向按键。
    sint32 z     = 3; // -1/0/1，Z方向按键。
    uint32 skill = 4; // 0无施法，1近战，2表现弹丸，3逻辑火球。
}
message FrameRecord
{
    FrameCommand input    = 1; // 该帧被权威采用的玩家输入；AI在确定性Core内派生。
    bool         supplied = 2; // true采用玩家输入；false采用明确的缺输入规则。
    fixed32      hash     = 3; // 本帧结束的规范化状态FNV32；用于诊断分歧。
}
message FrameJoinRequest
{
    uint32 scenario_id = 1;
}
message FrameJoinResponse
{
    string code         = 1; // OK/BUSY/BAD_SCENARIO/INTERNAL等稳定机器码。
    uint32 battle_id    = 2;
    bytes  resume_token = 3; // 32bytes操作系统随机凭据；不能写日志。
    uint32 generation   = 4; // 重连会话代数；阻止旧连接输入写新会话。
    uint32 map_id       = 5;
    uint32 map_version  = 6;
    string map_hash     = 7; // 已发布BMAP SHA256。
    reserved 8;              // 已发布字段号永久保留，避免旧客户端把字段误读为新语义。
    uint32 frame      = 9;
    bytes  checkpoint = 10; // 初始完整状态；正常帧只传FrameRecord。
}
message FrameInputRequest
{
    uint32                battle_id  = 1;
    uint32                generation = 2;
    repeated FrameCommand inputs     = 3; // 最多8条；一帧只允许一个不可变输入。
}
message FrameInputResult
{
    uint32 frame = 1; // 对应请求中的目标帧；用于定位批内结果。
    string code  = 2; // OK/BAD_INPUT/LATE/INPUT_WINDOW/CONFLICT/FINISHED。
}
message FramePushResponse
{
    uint32               battle_id  = 1;
    uint32               generation = 2;
    repeated FrameRecord records    = 3; // 按帧严格连续；一正常推送当前帧。
    string code   = 4; // 请求级：OK/EMPTY_INPUT/INPUT_BATCH_TOO_LARGE/OVERLOAD/INTERNAL。
    uint32 winner = 5; // 0进行中，1/2阵营胜利，3平局。
    repeated FrameInputResult input_results = 6; // 输入请求的逐项结果；顺序与inputs一致。
}
message FrameRecoverRequest
{
    uint32 battle_id    = 1;
    bytes  resume_token = 2;
}
message FrameRecoverResponse
{
    FrameJoinResponse state = 1;
}
message FrameLeaveRequest
{
    uint32 battle_id  = 1;
    uint32 generation = 2;
}
message FrameLeaveResponse
{
    string code = 1;
}
message FrameReplayRequest
{
    uint32 battle_id    = 1;
    bytes  resume_token = 2;
    uint32 offset       = 3;
}
message FrameReplayResponse
{
    string               code    = 1;
    repeated FrameRecord records = 2; // 分页最多256帧；不把整场日志塞进单个帧。
    uint32               total   = 3;
    FrameJoinResponse    initial = 4; // 第一页带身份/初始状态，不带恢复凭据。
}
message FrameReplay
{
    uint32               format_version = 1; // 目前1；加载时拒绝未知版本。
    FrameJoinResponse    initial        = 2;
    repeated FrameRecord records        = 3;
}
```

### 4.1 消息的业务意义

Join只选择已发布scenario_id，不携带位置、HP或Native状态。Server回传初始身份与Checkpoint。`battle_id` 是本进程不复用的战斗ID；`generation` 在恢复时递增，防止旧连接的合法旧消息写入新会话。`gateway_epoch/connection_id` 是Server内部传输身份，不是账号。

`resume_token` 是32bytes操作系统随机恢复凭据，当前没有账号登录，所以不把connection_id当作永久身份。凭据仅在控制响应中交给该客户端，恢复/回放时验证；不能写日志，也不放进保存的回放。P-256应用握手不等于登录，也不加密之后的业务数据；实际部署的链路保护与账号系统仍按各自接入层处理。

### 4.2 生成Server合同

WSL仓库根目录：

```bash
./server/protocol/build_server_descriptor.sh
python3 server/third_party/skynet-flywow/gateway/tools/generate_gateway_registry.py \
  --proto shared/protocol/navigation_query.proto \
  --output server/lualib/gateway/protocol/navigation_registry.lua
rg -n 'FRAME_|FrameInput|FramePush' server/lualib/gateway/protocol/navigation_registry.lua
```

预期descriptor非空、输出 `SERVER_DESCRIPTOR_OK`；Registry的FrameInput为request_type且response_type=nil，FramePush为request_type=nil且response_type。不要手工编辑生成物来“补推送支持”。

协议源按双工作区流程到Windows后，在Windows仓库根执行：

```powershell
./shared/protocol/build_unity_cs.ps1
```

该脚本将唯一Proto生成到现有 `Assets/BattleNavigation/Scripts/Protocol/NavigationQuery.cs`，保持已有Google.Protobuf引用。不要再把WSL生成的另一份同名C#放入Assets，否则相同类型重复定义。

失败排查：命令没有Request/Response是命名前缀不匹配；descriptor旧是没有重新生成/重启；Server与Unity使用不同map_hash是地图发布身份不一致；协议枚举编号不能因为重新排列就改变。

## 5. 实时Runtime与Worker：时间在调度层，规则在Core

### 5.1 状态ownership

|owner|持有内容|释放位置|
|---|---|---|
|Gateway|listen/client fd、握手、codec、写缓冲|连接关闭/进程停止|
|Frame Proxy|本地Gateway handle、固定Cluster目标|进程结束；不持有Battle等待表|
|Frame Dispatch|Worker handles、Battle ID分配|进程结束|
|Worker|Battle索引、会话/凭据/代数、截止时间|leave/保留期到期摘除|
|Runtime|pending输入、正式帧日志、Native Engine|Worker调用core.close|
|Engine|单位/冷却/飞行/弹丸逻辑State、私有导航scratch|userdata显式close，GC兜底|
|Unity Controller|confirmed/predicted Native、未确认输入、表现对象|OnDestroy|
|FrameConnection|Socket、读写线程、有界队列、控制等待|Dispose关闭Socket解除读阻塞|

Worker的 `M.step()` 不yield，正式状态修改是顺序事务。`skynet.call` 控制流程可能yield；入站route是pack/unpack后的值record，不借用Gateway连接对象。回复携带原epoch/id，Gateway再次核对连接有效性；不能把fd跨Cluster传给Worker。

### 5.2 先创建运行预算与资产验证

下面配置是新的独立配置，不覆盖现有battle.lua。容量是每Worker128场、4个Worker；这不是吞吐承诺，后面必须测当前地图、技能与部署机器。输入窗口8、每消息最多8输入、日志最多3600、回放页256、结束/断线保留30秒，都对应本功能确实持有的状态。

### server/config/frame_sync.lua

**操作：新建。** 为本版Worker给出实际持有状态的上限和固定时间合同，不覆盖第二课config.battle。

学习导航：精读 tick与deadline、每Worker容量、输入窗口、重连保留、日志上限。 可以略读固定声明与语言样板。输入、输出和失败语义见文件头及 API 注释；本节验证命令在该阶段末尾。阅读后应能解释这些状态的 owner、修改时机和释放位置。

```lua
--- 职责：帧同步版运行预算；Server进程启动时固定，配置变更需重启。
--- 输入输出：无输入->纯配置；不创建Service、不读取Unity工程。
return
{
    map_path         = "../shared/navigation/battle_1001/battle_1001.bmap",
    manifest_path    = "../shared/navigation/battle_1001/battle_1001.manifest.json",
    workers          = 4,     -- Service数；不表示线程绑定。
    max_battles      = 128,   -- 每Worker同时持有的Battle；结束结果也占预算。
    tick_cs          = 5,     -- 5×10ms=50ms；Native kTickMs必须同值。
    future_window    = 8,     -- 当前帧后最多8帧输入；超窗明确拒绝。
    max_catchup      = 4,     -- 一次心跳最多补4帧；仍落后则OVERLOAD，不跳帧。
    retention_cs     = 3000,  -- 结束/断线Battle保留30秒。
    max_frames       = 3600,  -- 180秒；对应Native时限和有界Replay日志。
    input_batch      = 8,
    replay_page      = 256,
    gateway_node     = "frame_gateway",
    gateway_address  = "127.0.0.1:2537",
    battle_node      = "frame_battle",
    battle_address   = "127.0.0.1:2538",
    gateway_port     = 19021,
}
```

### server/scripts/lessons/prepare_frame_sync.py

**操作：新建。** 在启动前验证已发布地图hash并生成资产身份配置。该文件只描述地图资产身份，不计算或绑定源代码hash。

学习导航：精读 路径从脚本推导，manifest与BMAP内容一致性，源码运行时不读Unity工程。 可以略读固定声明与语言样板。输入、输出和失败语义见文件头及 API 注释；本节验证命令在该阶段末尾。阅读后应能解释这些状态的 owner、修改时机和释放位置。

```python
# 职责：验证帧同步部署资产并生成静态身份配置；不启动Server，不操作Git。
# 调用：server工作目录 python3 scripts/lessons/prepare_frame_sync.py。
from pathlib import Path
import hashlib
import json
root = Path(__file__).resolve().parents[3]
asset = root / 'shared/navigation/battle_1001'
manifest = json.loads((asset/'battle_1001.manifest.json').read_text())
digest = hashlib.sha256((asset/'battle_1001.bmap').read_bytes()).hexdigest()
if digest != manifest['content_sha256']:
    raise SystemExit('MAP_HASH_MISMATCH')
target = root/'server/config/frame_sync_asset.lua'
content = (
    '--- 构建生成的已验证地图身份；不手改。\n'
    'return { map_id = %d, map_version = %d, map_hash = "%s" }\n'
) % (manifest['map_id'], manifest['map_version'], digest)
target.write_text(content, encoding='utf-8')
print('FRAME_ASSET_OK',digest)
```

WSL Server工作目录执行：

```bash
python3 scripts/lessons/prepare_frame_sync.py
```

预期 `FRAME_ASSET_OK`，生成 `config/frame_sync_asset.lua`。它保存已验证的map_id/version/hash，Runtime不读取Unity工程，也不读取开发机绝对路径。manifest文件的真实名称是 `battle_1001.manifest.json`；不是泛称 `manifest.json`。

### 5.3 Runtime：复制意图，记录实际采用输入

Runtime只管理本场的输入窗口与Core调用，不注册Service、不读网络、不以客户端时间推进。`pending`最多window条；一条输入被接受后不可改写。`records`保存实际被执行的补缺或玩家输入，不是发送方声称已执行的输入。Checkpoint只在加入/恢复/客户端重演时使用，Server不为每帧保留完整状态历史。

### server/lualib/battle/frame_sync/runtime.lua

**操作：新建。** 把输入窗口、缺输入规则和Replay归到一个Battle实例；先用纯Lua驱动验证。

学习导航：精读 Native owner、不可变帧输入、明确拒绝、帧状态hash、历史最大长度；不require Skynet。 可以略读固定声明与语言样板。输入、输出和失败语义见文件头及 API 注释；本节验证命令在该阶段末尾。阅读后应能解释这些状态的 owner、修改时机和释放位置。

```lua
--- 职责：一个帧同步Battle的no-yield运行时；输入->权威FrameRecord/Checkpoint。
--- Native Engine归本Runtime独占；调用方负责close；无Socket/墙钟/Skynet依赖。
local native = require "lesson_frame_native"
local M = {}

---@class FrameInput
---@field frame integer 目标Server帧；已经执行的帧不可修改。
---@field x integer X轴意图，取值-1/0/1；不代表正式位置。
---@field z integer Z轴意图，取值-1/0/1；不代表正式位置。
---@field y integer 本课固定为0，保留与Native输入record一致的字段。
---@field skill integer 技能编号；0表示本帧不施放。
---@class FrameRecord
---@field input FrameInput 本帧正式采用的输入；缺输入时由Server补齐。
---@field supplied boolean true表示截止前收到并采用玩家输入。
---@field hash integer 本帧规范化Native状态的非安全校验值。
---@class FrameRuntimeOptions
---@field map_path string 已验证地图资产路径；只在创建时读取。
---@field future_window integer 最多接受的未来帧距离。
---@field max_frames integer 单场可保留的Replay输入记录上限。
---@class FrameRuntimeError
---@field code string 稳定错误码，供Worker转换成传输合同。

---@class FrameRuntime
---@field engine userdata 独占Native模拟；close后不再调用。
---@field frame integer 已完成权威帧。
---@field winner integer 0未结束、1/2胜方、3平局。
---@field pending table<integer,FrameInput> 尚未执行输入；由该Runtime独占，最多future_window条。
---@field records FrameRecord[] 有界整场帧输入日志；不保留每帧完整状态。
---@field window integer 与配置future_window一致；用于拒绝过远的未来输入。
---@field max_frames integer records容量上限；达到后Battle停止追加并失败。
---@field missing integer 连续缺输入帧数；控制短时方向保持。
---@field last_x integer 最近正式输入方向X分量。
---@field last_z integer 最近正式输入方向Z分量。
---@field last_y integer 最近正式输入高度分量；本课恒为0。

--- 对规范化状态做32位FNV；不作安全校验，SHA256用于已发布地图资产身份；程序版本随发行包管理。
---@param bytes string 本次调用借用的Native状态。
---@return integer hash unsigned32。
function M.hash(bytes)
    local value = 2166136261
    for i = 1, #bytes do
        value = ((value ~ bytes:byte(i)) * 16777619) & 0xffffffff
    end
    return value
end

--- 读取固定小端状态头；不会把Lua字符串转成可写指针。
local function header(bytes)
    local version, frame, winner = string.unpack("<I4I4I4", bytes)
    assert(version == 1, "STATE_VERSION")
    return frame, winner
end

--- 建立独占Native模拟；启动资产I/O，失败以nil/error交给Worker。
---@param options FrameRuntimeOptions map路径与容量由Worker配置注入；不在Core读取环境变量。
---@return FrameRuntime|nil runtime, table|nil error
function M.create(options)
    local engine, err = native.open(options.map_path)
    if not engine then
        return nil, err
    end
    local initial, save_err = engine:save()
    if not initial then
        engine:close()
        return nil, save_err
    end
    return
    {
        engine        = engine,
        initial       = initial,
        frame         = 0,
        winner        = 0,
        pending       = {},
        records       = {},
        window        = options.future_window,
        max_frames    = options.max_frames,
        last_x        = 0,
        last_z        = 0,
        last_y        = 0,
        missing       = 0,
    }
end

--- 接受未来帧意图；重复相同输入幂等，不允许改写已接受输入。
--- 不yield、不修改正式位置；成功OK，失败稳定code。
---@param runtime FrameRuntime 当前Battle owner。
---@param input FrameInput 调用方借用的意图record；函数只复制标量字段。
---@return string code OK表示幂等接受；其他值是稳定拒绝原因。
function M.accept(runtime, input)
    local f = input.frame or 0
    local x, z, skill, y = input.x or 0, input.z or 0, input.skill or 0, input.y or 0
    if math.type(f) ~= "integer" or math.type(x) ~= "integer" or
        math.type(z) ~= "integer" or math.type(skill) ~= "integer" or
        math.type(y) ~= "integer" or y ~= 0 or x < -1 or x > 1 or
        z < -1 or z > 1 or skill < 0 or skill > 3 then
        return "BAD_INPUT"
    end
    if runtime.winner ~= 0 then
        return "FINISHED"
    end
    if f <= runtime.frame then
        return "LATE"
    end
    if f > runtime.frame + runtime.window then
        return "INPUT_WINDOW"
    end
    local previous = runtime.pending[f]
    if previous then
        same = previous.x == x and previous.z == z and previous.skill == skill and previous.y == y
        if same then
            return "OK"
        end
        return "CONFLICT"
    end

    runtime.pending[f] = { frame = f, x = x, z = z, skill = skill, y = y }
    return "OK"
end

--- 推进下一帧；缺输入最多保持方向两帧，技能永不沿用。
--- Native失败不返回半步结果；Worker结束该Battle并显式close。
---@param runtime FrameRuntime 当前Battle owner。
---@return table|nil record, table|nil error
function M.step(runtime)
    if runtime.winner ~= 0 then
        return nil, { code = "FINISHED" }
    end
    local frame = runtime.frame + 1
    local input = runtime.pending[frame]
    local supplied = input ~= nil
    if supplied then
        runtime.last_x, runtime.last_z, runtime.last_y = input.x, input.z, input.y
        runtime.missing = 0
    else
        -- 截止后该帧输入已固定；方向只短暂保持，技能不重放，避免迟到包改写历史。
        runtime.missing = runtime.missing + 1
        local hold = runtime.missing <= 2
        input = { frame = frame, x = hold and runtime.last_x or 0,
                  z = hold and runtime.last_z or 0, y = hold and runtime.last_y or 0, skill = 0 }
    end
    local ok, err = runtime.engine:step(input.x, input.z, input.skill)
    if not ok then
        return nil, err
    end

    local state, save_err = runtime.engine:save()
    if not state then
        return nil, save_err
    end
    runtime.frame, runtime.winner = header(state)
    runtime.pending[frame] = nil
    local record = { input = input, supplied = supplied, hash = M.hash(state) }
    assert(#runtime.records < runtime.max_frames, "FRAME_LOG_LIMIT")
    -- 只保存被正式执行的输入与摘要；完整状态通过Checkpoint按需生成。
    runtime.records[#runtime.records + 1] = record
    return record
end

--- close幂等释放Native；Worker摘除索引后调用，GC不作为主释放路径。
---@param runtime FrameRuntime owner。
function M.close(runtime)
    if runtime.engine then
        runtime.engine:close()
        runtime.engine = nil
    end
end
return M
```

### server/tests/frame_runtime_test.lua

**操作：新建。** 把输入窗口与缺输入规则独立于网络验证。

学习导航：精读 正式输入记录包含实际采用的补缺结果；不把发送记录冒充确认。 可以略读固定声明与语言样板。输入、输出和失败语义见文件头及 API 注释；本节验证命令在该阶段末尾。阅读后应能解释这些状态的 owner、修改时机和释放位置。

```lua
--- 职责：Frame Runtime无网络聚焦单测；Native替身只控制帧/winner。
package.path = "./?.lua;./lualib/?.lua;" .. package.path
local closed = false
package.preload.lesson_frame_native = function()
    return { open = function()
        local frame = 0
        return {
            step = function()
        frame = frame + 1
        return true
    end,
            save = function() return string.pack("<I4I4I4",1,frame,0) end,
            close = function()
        closed = true
        return true
    end,
        }
    end }
end
local core = require "battle.frame_sync.runtime"
local state = assert(core.create({map_path="stub",future_window=8,max_frames=3600}))
assert(core.accept(state,{frame=1,x=1,skill=3}) == "OK")
assert(core.accept(state,{frame=1,x=1,skill=3}) == "OK")
assert(core.accept(state,{frame=1,x=-1}) == "CONFLICT")
assert(core.accept(state,{frame=9}) == "INPUT_WINDOW")
assert(core.accept(state,{frame=2,x=1.5}) == "BAD_INPUT")
assert(core.accept(state,{frame=2,y=1}) == "BAD_INPUT", "ground player cannot inject flight")
local first = assert(core.step(state))
assert(first.supplied and first.input.skill == 3)
assert(core.accept(state,{frame=1}) == "LATE")
for i=1,3 do
    local record = assert(core.step(state))
    assert(not record.supplied and record.input.skill == 0)
    assert(record.input.x == (i<=2 and 1 or 0))
end
assert(#state.records == 4 and state.pending[1] == nil)
core.close(state)
core.close(state)
assert(closed)
print("FRAME_RUNTIME_OK")
```

```bash
./third_party/skynet/3rd/lua/lua tests/frame_runtime_test.lua
```

预期 `FRAME_RUNTIME_OK`。这个测试使用Native替身，只证明窗口/缺输入/关闭合同，不把它称作真实Native或网络集成。

### 5.4 Worker：每场独立截止与会话

创建时先读随机凭据，再创建Native，避免I/O失败后遗留Engine。每场到期执行最多4次；一次超预算不能影响其它场的正式帧号。Recover校验token后代数递增、替换传输会话、清除旧未来输入和方向，返回当前正式Checkpoint；不会让旧输入跨会话继续施法。

断线后保留30秒，仍按明确缺输入规则推进；结束也保留30秒供读取日志。leave直接标记移除。清除Battle时先摘索引再close，回放凭据到期后返回NOT_FOUND。这里没有把断线暂停所有AI或无限保留日志当成默认行为。

### server/service/battle/frame_sync/worker.lua

**操作：新建。** 把纯Runtime放入长驻Worker；一个心跳按稳定Battle ID推进多场战斗。

学习导航：精读 no-yield更新、deadline/catchup、会话generation、结束保留、Core异常关闭与恢复。 可以略读固定声明与语言样板。输入、输出和失败语义见文件头及 API 注释；本节验证命令在该阶段末尾。阅读后应能解释这些状态的 owner、修改时机和释放位置。

```lua
--- 职责：拥有有界Battle实例并调度fixed Tick；不持有fd/codec，不让Core yield。
--- 输入：Dispatch注入handle与配置、业务命令；输出：控制响应和frame_push消息。
local skynet = require "skynet"
local core = require "battle.frame_sync.runtime"
local native = require "lesson_frame_native"
local config = require "config.frame_sync"
local meta = require "config.frame_sync_asset" -- 本课构建工具验证并生成。
local battles, order = {}, {}
local dispatcher = nil -- composition root注入，唯一结果接收者。

---@class FrameSession
---@field gateway_epoch string Gateway实例身份；回推时原样携带。
---@field connection_id integer 已握手连接；不是玩家永久身份。
---@alias FrameWorkerCommand "configure"|"inputs"|"disconnect"|"create"|"recover"|"replay"|"leave"
---@class FrameInputBatch
---@field generation integer 请求所属会话代数；恢复后旧代数输入失效。
---@field inputs FrameInput[] 同一请求中按帧独立判定的意图列表。
---@class FrameWorkerRequest
---@field battle_id integer Dispatcher分配且不复用的Battle ID。
---@field session FrameSession 当前请求的传输身份；只含Gateway epoch/connection ID。
---@field request FrameInputBatch|table Proto解码后的业务body；不含fd或借用buffer。
---@class FrameBattle
---@field id integer Dispatcher分配的Battle ID；Worker内作为索引键。
---@field core FrameRuntime Worker独占的Battle模拟与Native Engine。
---@field token string 32字节恢复凭据；Battle生命周期内由本Worker持有。
---@field generation integer 重连代数；每次恢复递增以拒绝旧连接迟到消息。
---@field session FrameSession 当前有效传输身份。
---@field due integer 下一权威tick截止时刻，单位Skynet tick。
---@field failed boolean|nil 终止标记；失败Battle保留至retention到期。
---@field failure_code string|nil 稳定失败码；仅failed时存在。
---@field finished integer|nil 完成/失败时刻，单位Skynet tick。
---@field disconnected integer|nil 断线时刻，单位Skynet tick。
---@class FramePushData
---@field session FrameSession 推送目标连接，不包含Socket fd。
---@field data table FramePushResponse业务结果。

--- 使用操作系统熵生成32bytes凭据；I/O失败不退化为math.random。
---@return string 由操作系统熵生成的32字节恢复凭据；I/O失败抛TOKEN_IO。
local function token()
    local file = assert(io.open("/dev/urandom", "rb"))
    local value = file:read(32)
    file:close()
    assert(value and #value == 32, "TOKEN_IO")
    return value
end
--- 对恢复凭据做固定长度比较，避免提前退出的位置泄露。
---@param a string|nil Battle持有的凭据。
---@param b string|nil 客户端提交的凭据。
---@return boolean 固定长度逐字节比较结果。
local function token_equal(a, b)
    if type(a) ~= "string" or type(b) ~= "string" or #a ~= 32 or #b ~= 32 then
        return false
    end
    local diff = 0
    for i = 1, 32 do diff = diff | (a:byte(i) ~ b:byte(i)) end
    return diff == 0
end
--- 生成控制状态；仅加入/恢复会读取完整Native状态。
---@param battle FrameBattle 由当前Worker拥有的Battle。
---@param initial boolean true时生成不含恢复凭据的Replay起点Checkpoint。
---@return table 可序列化控制响应；Native状态复制为Lua string。
local function snapshot(battle, initial)
    local map_id, map_version = battle.core.engine:identity()
    return
    {
        code         = "OK",
        battle_id    = battle.id,
        resume_token = initial and "" or battle.token,
        generation   = battle.generation,
        map_id       = map_id,
        map_version  = map_version,
        map_hash     = meta.map_hash,
        frame        = initial and 0 or battle.core.frame,
        checkpoint   = initial and battle.core.initial or assert(battle.core.engine:save()),
    }
end
--- 推送目标连接；request_id=0表示无请求关联；不等待客户端收到。
---@param battle FrameBattle 目标Battle；仅向其当前session发送。
---@param records FrameRecord[] 已正式推进的权威帧记录。
---@param code string 稳定结果码；request_id=0的异步推送不等待客户端。
---@param input_results table|nil 本批各输入逐项接受/拒绝结果。
local function push(battle, records, code, input_results)
    skynet.send(dispatcher, "lua", "frame_push",
    {
        session = battle.session,
        data    = { battle_id = battle.id, generation = battle.generation,
                    records = records, code = code, winner = battle.core.winner,
                    input_results = input_results or {} },
    })
end
--- 检查当前连接和会话代数；旧连接迟到输入不可进入新会话。
---@param battle FrameBattle|nil Worker索引查得的实例。
---@param args FrameWorkerRequest 当前Dispatcher转发请求。
---@return boolean Battle、会话代数和连接身份均匹配时为true。
local function owns(battle, args)
    return battle and battle.generation == args.request.generation and
        battle.session.gateway_epoch == args.session.gateway_epoch and
        battle.session.connection_id == args.session.connection_id
end
--- 建立Runtime与索引；无yield，失败返回稳定错误，由上层记录诊断。
---@param args FrameWorkerRequest Dispatcher分配Battle ID并显式传入session。
---@return table Join结果；失败返回稳定code，创建失败前释放Native。
local function create(args)
    if #order >= config.max_battles then
        return { code = "BUSY" }
    end
    local credential = token() -- 先完成可能失败的I/O，避免创建Engine后泄漏。
    local runtime, err = core.create(config)
    if not runtime then
        return { code = err.code }
    end
    local map_id, map_version = runtime.engine:identity()
    if map_id ~= meta.map_id or map_version ~= meta.map_version then
        core.close(runtime)
        return { code = "ASSET_IDENTITY" }
    end
    local battle = { id = args.battle_id, core = runtime, token = credential, generation = 1,
                     session = args.session, due = skynet.now() + 10, disconnected = nil }
    battles[battle.id] = battle
    order[#order + 1] = battle.id
    table.sort(order)
    return snapshot(battle, false)
end
--- 恢复凭据归Battle所有；重连原子更换session并清掉旧代数未来输入。
---@param args FrameWorkerRequest 凭据和新连接身份来自Dispatcher入站请求。
---@return table Checkpoint和新generation；凭据无效时统一返回NOT_FOUND。
local function recover(args)
    local battle = battles[args.battle_id]
    if not battle or not token_equal(battle.token, args.request.resume_token) then
        return { code = "NOT_FOUND" }
    end
    if battle.failed then
        return { code = battle.failure_code }
    end
    battle.generation = battle.generation + 1
    battle.session = args.session
    battle.disconnected = nil
    battle.core.pending = {}
    battle.core.last_x, battle.core.last_z, battle.core.last_y = 0, 0, 0
    return snapshot(battle, false)
end
--- 输入只入有界未来窗口；拒绝通过FramePush明确通知，不把send当接受。
--- 截止以Worker处理时钟为准；Timer稍晚执行也不能给已到期帧重新开窗口。
---@param battle FrameBattle 当前Worker拥有的Battle。
---@param input FrameInput 未信任的玩家意图；Core再次验证整数范围和窗口。
---@return string 接受或拒绝code；不在此处修改正式状态。
local function admit(battle, input)
    local frame = input.frame or 0
    if math.type(frame) == "integer" and frame > battle.core.frame then
        local deadline = battle.due + (frame - battle.core.frame - 1) * config.tick_cs
        if skynet.now() >= deadline then
            return "LATE"
        end
    end
    return core.accept(battle.core, input)
end
---@param args FrameWorkerRequest 从Dispatcher通过skynet.send收到；无返回值，结果异步push。
local function inputs(args)
    local battle = battles[args.battle_id]
    if not owns(battle, args) then
        return
    end

    local batch = args.request.inputs or {}
    if #batch == 0 then
        push(battle, {}, "EMPTY_INPUT")
        return
    end
    if #batch > config.input_batch then
        push(battle, {}, "INPUT_BATCH_TOO_LARGE")
        return
    end

    -- 每条输入独立判定；外层OK表示请求可处理，不表示批内全部成功。
    local input_results = {}
    for _, input in ipairs(batch) do
        input_results[#input_results + 1] =
            { frame = input.frame or 0, code = admit(battle, input) }
    end

    push(battle, {}, "OK", input_results)
end
--- 一页Replay最多256帧；只有有效凭据才能读取，离线initial不包含凭据。
---@param args FrameWorkerRequest 包含battle_id、resume_token和分页offset。
---@return table 有界Replay页与可选初始Checkpoint；凭据不匹配不泄露Battle存在性。
local function replay(args)
    local battle = battles[args.battle_id]
    if not battle or not token_equal(battle.token, args.request.resume_token) then
        return { code = "NOT_FOUND" }
    end
    local offset = args.request.offset or 0
    if offset > #battle.core.records then
        return { code = "REPLAY_OFFSET" }
    end
    local records = {}
    for i = offset + 1, math.min(#battle.core.records, offset + config.replay_page) do
        records[#records + 1] = battle.core.records[i]
    end
    return { code = "OK", records = records, total = #battle.core.records,
             initial = offset == 0 and snapshot(battle, true) or nil }
end
--- 标记客户端离开；释放逻辑发生在唯一心跳，避免边遍历边删order。
---@param args FrameWorkerRequest 当前session的离开请求。
---@return table OK或NOT_FOUND；实际Native释放延迟至heartbeat安全遍历阶段。
local function leave(args)
    local battle = battles[args.battle_id]
    if not owns(battle, args) then
        return { code = "NOT_FOUND" }
    end
    battle.remove = true
    return { code = "OK" }
end
--- Core异常只终止这一场；下一场继续，Runtime资源在删除时close。
---@param battle FrameBattle 由Heartbeat顺序推进的Battle。
---@param now integer 当前Skynet tick；绝不由墙钟或客户端提供。
local function advance(battle, now)
    if battle.core.winner ~= 0 or battle.failed then
        return
    end
    local count = 0
    -- 有界追赶避免单个Worker被长时间占用；超限时结束本场，不跳过权威帧。
    while now >= battle.due and count < config.max_catchup do
        local ok, record, err = pcall(core.step, battle.core)
        if not ok or not record then
            battle.failed = true
            battle.failure_code = "INTERNAL"
            push(battle, {}, "INTERNAL")
            local failure = ok and err and err.code or record
            skynet.error("FRAME_CORE_FAILED id=", battle.id, " ", tostring(failure))
            break
        end
        battle.due = battle.due + config.tick_cs
        count = count + 1
        push(battle, { record }, "OK")
        if battle.core.winner ~= 0 then
            battle.finished = now
            break
        end
    end
    if not battle.finished and not battle.failed and now >= battle.due then
        battle.failed = true
        battle.failure_code = "OVERLOAD"
        push(battle, {}, "OVERLOAD") -- 绝不跳帧伪装实时跟上。
    end
    if battle.failed then
        battle.finished = now
    end
end
--- 一个Worker一个Timer；timeout回调无yield，order稳定；容量配置约束执行时间。
--- 唯一Battle Tick入口；同一Worker顺序推进并在本回调中回收过期资源。
local function heartbeat()
    local now, surviving = skynet.now(), {}
    for _, id in ipairs(order) do
        local battle = battles[id]
        advance(battle, now)
        local expiry = battle.finished or battle.disconnected
        if battle.remove or (expiry and now - expiry >= config.retention_cs) then
            core.close(battle.core)
            battles[id] = nil
        else surviving[#surviving + 1] = id end
    end
    order = surviving
    skynet.timeout(config.tick_cs, heartbeat)
end
--- 断线通知由Dispatch转发；只摘除匹配传输会话，不改新会话。
---@param session FrameSession 由Dispatcher转发的Gateway断线身份。
local function disconnect(session)
    for _, id in ipairs(order) do
        local battle = battles[id]
        if battle.session.gateway_epoch == session.gateway_epoch and
            battle.session.connection_id == session.connection_id then
            battle.disconnected = skynet.now()
            battle.core.pending = {}
            battle.core.last_x, battle.core.last_z, battle.core.last_y = 0, 0, 0
        end
    end
end
skynet.start(function()
    ---@param session integer Skynet call session；异步send可能为0。
    ---@param source integer 调用方Service handle；必须等于已配置Dispatcher。
    ---@param command FrameWorkerCommand 当前Service消息命令。
    ---@param args table 命令payload；字段合同见FrameWorkerRequest及对应类型。
    skynet.dispatch("lua", function(session, source, command, args)
        if command == "configure" then
            assert(dispatcher == nil)
            dispatcher = assert(args.dispatcher)
            skynet.timeout(config.tick_cs, heartbeat)
            skynet.retpack(true)
            return
        end
        assert(source == dispatcher, "untrusted Worker sender")
        if command == "inputs" then inputs(args)
        elseif command == "disconnect" then disconnect(args)
        elseif command == "create" then skynet.retpack(create(args))
        elseif command == "recover" then skynet.retpack(recover(args))
        elseif command == "replay" then skynet.retpack(replay(args))
        elseif command == "leave" then skynet.retpack(leave(args))
        else error("unknown Frame Worker command: " .. tostring(command)) end
    end)
end)
```

### 5.5 Dispatch与组合根

Dispatch启动固定数量Worker，把自身handle显式注入。`(battle_id-1)%workers+1` 是当前进程中的稳定分片；ID单调增加、不复用，也不在线重排Worker。控制Join/Recover/Replay/Leave使用call取得响应；输入与权威推帧用send。超时不会让Gateway停止读取其它帧。

`cluster.open` 参数是reload中配置的**节点名**，不是直接传 `127.0.0.1:2538`。后者会被当成节点名查找并报is down。`cluster.register` 的固定跨进程边界与本地Service handle注入是两件事。

### server/service/battle/frame_sync/dispatch.lua

**操作：新建。** 由Battle进程选择Worker并回推控制响应/权威帧；Gateway不拥有玩家归属。

学习导航：精读 稳定分片、显式Worker handles、send_data纯record边界、call yield后的回复身份。 可以略读固定声明与语言样板。输入、输出和失败语义见文件头及 API 注释；本节验证命令在该阶段末尾。阅读后应能解释这些状态的 owner、修改时机和释放位置。

```lua
--- 职责：帧同步Battle入口；拥有ID分配和Worker分片；不解析网络frame/Proto bytes。
--- 控制call可能yield；输入和frame_push用send，不等待客户端读包。
local skynet = require "skynet"
local cluster = require "skynet.cluster"
local config = require "config.frame_sync"
local ids = require("gateway.protocol.navigation_registry").command_ids
---@alias FrameDispatchCommand "ready"|"send_data"|"disconnect"|"frame_push"
---@class FrameDispatchRoute
---@field gateway_epoch string Gateway实例身份，由Proxy转发。
---@field connection_id integer 当前连接ID；不是玩家持久身份。
---@field command_id integer Registry中的稳定命令ID。
---@field request_id integer 请求序号；0只允许Server主动FramePush。
---@field data table 解码后的Proto body；不含Socket fd或网络buffer。
local workers, next_id = {}, 0

--- ID到Worker稳定映射；workers在进程存活期间固定，不允许在线重排。
---@param id integer Dispatcher分配的Battle ID。
---@return integer|nil 稳定Worker handle；非法ID返回nil。
local function worker(id)
    if math.type(id) ~= "integer" or id < 1 or id > 0x7fffffff then
        return nil
    end
    return workers[(id - 1) % #workers + 1]
end
--- 发回原传输会话；Gateway按epoch/id检查当前有效性，不保存fd。
---@param route table gateway_epoch/connection_id/command_id/request_id，由入站或Worker产生。
---@param response table 已验证响应body。
---@param route FrameDispatchRoute 入站请求或Worker推送的传输路由值。
---@param response table 已由Battle Worker生成的Proto body。
--- 通过cluster.send异步交给Gateway Proxy；本函数不yield、不保存fd。
local function reply(route, response)
    local ok, err = pcall(cluster.send, config.gateway_node, "@frame_proxy", "send_data",
    {
        gateway_epoch = route.gateway_epoch,
        connection_id = route.connection_id,
        command_id    = route.command_id,
        request_id    = route.request_id,
        data          = response,
    })
    if not ok then
        skynet.error("FRAME_REPLY_FAILED ", tostring(err))
    end
end
--- Join仅接受scenario_id；正式状态完全由Server构造。
---@param route FrameDispatchRoute Join/Recover/Replay/Leave控制请求。
---@return table 控制响应；skynet.call会yield，返回后只使用route值record。
local function control(route)
    local request = route.data
    local args =
    {
        battle_id = request.battle_id,
        request   = request,
        session   =
        {
            gateway_epoch = route.gateway_epoch,
            connection_id = route.connection_id,
        },
    }
    if route.command_id == ids.FRAME_JOIN then
        if request.scenario_id ~= 1001 then
            return { code = "BAD_SCENARIO" }
        end
        if next_id >= 0x7fffffff then
            return { code = "ID_EXHAUSTED" }
        end
        next_id = next_id + 1
        args.battle_id = next_id
        return skynet.call(worker(next_id), "lua", "create", args)
    end
    local target = worker(args.battle_id)
    if not target then
        return { code = "NOT_FOUND" }
    end
    if route.command_id == ids.FRAME_RECOVER then
        return { state = skynet.call(target, "lua", "recover", args) }
    elseif route.command_id == ids.FRAME_REPLAY then
        return skynet.call(target, "lua", "replay", args)
    elseif route.command_id == ids.FRAME_LEAVE then
        return skynet.call(target, "lua", "leave", args)
    end
    return { code = "BAD_COMMAND" }
end
--- 由Gateway Proxy转来的数据；控制yield只持有值record，不借用连接对象。
---@param route FrameDispatchRoute Gateway Proxy发送的已解码请求。
--- FRAME_INPUT经skynet.send异步投递；控制命令经skynet.call后回送原session。
local function incoming(route)
    assert(type(route) == "table" and type(route.data) == "table")
    assert(type(route.gateway_epoch) == "string")
    assert(route.connection_id > 0 and route.request_id ~= 0)
    if route.command_id == ids.FRAME_INPUT then
        local target = worker(route.data.battle_id)
        if target then
            skynet.send(target, "lua", "inputs", { battle_id = route.data.battle_id,
                request = route.data, session = { gateway_epoch = route.gateway_epoch,
                                                 connection_id = route.connection_id } })
        end
        return
    end
    local ok, result = pcall(control, route)
    if not ok then
        skynet.error("FRAME_CONTROL_FAILED ", tostring(result))
        if route.command_id == ids.FRAME_RECOVER then
            result = { state = { code = "INTERNAL" } }
        else
            result = { code = "INTERNAL" }
        end
    end
    reply(route, result)
end
skynet.start(function()
    for i = 1, config.workers do
        workers[i] = skynet.newservice("battle/frame_sync/worker")
        assert(skynet.call(workers[i], "lua", "configure", { dispatcher = skynet.self() }))
    end
        ---@param session integer Skynet session；ready响应使用retpack，其它消息走显式路由。
    ---@param source integer 调用方Service handle；frame_push必须属于已创建Worker。
    ---@param command FrameDispatchCommand Dispatcher入口命令。
    ---@param payload FrameDispatchRoute|FrameSession route或断线身份record，不含fd。
    skynet.dispatch("lua", function(_, source, command, payload)
        if command == "ready" then skynet.retpack(true)
        elseif command == "send_data" then incoming(payload)
        elseif command == "disconnect" then
            for _, handle in ipairs(workers) do
                skynet.send(handle, "lua", "disconnect", payload)
            end
        elseif command == "frame_push" then
            local trusted = false
            for _, handle in ipairs(workers) do trusted = trusted or source == handle end
            assert(trusted, "untrusted frame source")
            reply({ gateway_epoch = payload.session.gateway_epoch,
                    connection_id = payload.session.connection_id,
                    command_id = ids.FRAME_PUSH, request_id = 0 }, payload.data)
        else error("unknown Frame Dispatch command: " .. tostring(command)) end
    end)
end)
```

### server/service/battle/frame_sync/main.lua

**操作：新建。** 组装独立Battle进程入口，保持第二课入口可用。

学习导航：精读 cluster.register只对固定跨进程边界使用；子Service handles显式持有。 可以略读固定声明与语言样板。输入、输出和失败语义见文件头及 API 注释；本节验证命令在该阶段末尾。阅读后应能解释这些状态的 owner、修改时机和释放位置。

```lua
--- 职责：Frame Battle进程组合根；启动Dispatch并开放Cluster，失败终止启动。
local skynet = require "skynet"
local cluster = require "skynet.cluster"
local config = require "config.frame_sync"
skynet.start(function()
    local dispatch = skynet.newservice("battle/frame_sync/dispatch")
    assert(skynet.call(dispatch, "lua", "ready"))
    cluster.reload({ [config.gateway_node] = config.gateway_address,
                     [config.battle_node] = config.battle_address })
    cluster.open(config.battle_node, 64)
    cluster.register("frame_dispatch", dispatch)
    skynet.error("FRAME_BATTLE_READY address=", config.battle_address)
    skynet.exit()
end)
```

### server/service/gateway/frame_sync/proxy.lua

**操作：新建。** 接入第二课已建立的双向异步边界，只转发传输record。

学习导航：精读 Proxy持有Gateway handle，不持有Battle表；断线要送达Battle而非被吞掉。 可以略读固定声明与语言样板。输入、输出和失败语义见文件头及 API 注释；本节验证命令在该阶段末尾。阅读后应能解释这些状态的 owner、修改时机和释放位置。

```lua
--- 职责：帧同步Gateway/Battle异步转发；不解释FrameInput或模拟状态。
--- 输入输出：send_data record原样跨Cluster；disconnect携带实例与连接身份。
local skynet = require "skynet.manager"
local cluster = require "skynet.cluster"
local config = require "config.frame_sync"
local gateway = nil -- 组合根注入的本地Gateway handle。

---@class FrameGatewayData
---@field gateway_epoch string Gateway实例身份。
---@field connection_id integer 目标连接；0仅主动广播，帧同步使用具体连接。
---@field command_id integer 从唯一Proto生成的command。
---@field request_id integer 非0请求/响应，0主动消息。
---@field data table 已解码body；本Proxy不修改。

--- 尽力异步转发；Cluster失败由客户端控制超时/恢复收敛，不建立无限重试。
local function forward(command, payload)
    local ok, err = pcall(cluster.send, config.battle_node, "@frame_dispatch", command, payload)
    if not ok then
        skynet.error("FRAME_PROXY_SEND_FAILED ", tostring(err))
    end
end
skynet.start(function()
    skynet.dispatch("lua", function(_, source, command, payload)
        if command == "start" then
            cluster.reload({ [config.battle_node] = config.battle_address,
                             [config.gateway_node] = config.gateway_address })
            cluster.open(config.gateway_node, 64)
            cluster.register("frame_proxy", skynet.self())
            assert(cluster.call(config.battle_node, "@frame_dispatch", "ready"))
            skynet.name(".frame_proxy", skynet.self())
            skynet.retpack(true)
        elseif command == "bind" then
            assert(gateway == nil)
            gateway = assert(payload.gateway)
            skynet.retpack(true)
        elseif command == "send_data" then
            assert(gateway and type(payload.data) == "table")
            if source == gateway then forward("send_data", payload)
            else skynet.send(gateway, "lua", "send_data", payload) end
        elseif command == "gateway_disconnect" then
            assert(source == gateway)
            forward("disconnect", payload)
        else error("unknown Frame Proxy command: " .. tostring(command)) end
    end)
end)
```

### server/service/gateway/frame_sync/main.lua

**操作：新建。** 先完成跨进程ready再监听客户端；复用现有FlyWow握手、framing与codec。

学习导航：精读 handler_service当前合同是注册名称；覆盖项直接可见；Gateway不依赖地图。 可以略读固定声明与语言样板。输入、输出和失败语义见文件头及 API 注释；本节验证命令在该阶段末尾。阅读后应能解释这些状态的 owner、修改时机和释放位置。

```lua
--- 职责：帧同步Gateway进程组合根；只创建Proxy/Gateway并注入依赖。
local skynet = require "skynet"
local config = require "config.frame_sync"
skynet.start(function()
    local proxy = skynet.newservice("gateway/frame_sync/proxy")
    assert(skynet.call(proxy, "lua", "start"))
    local gateway = skynet.newservice("flywow_gateway")
    assert(skynet.call(proxy, "lua", "bind", { gateway = gateway }))
    assert(skynet.call(gateway, "lua", "start",
    {
        handler_service = ".frame_proxy",
        host            = "127.0.0.1",
        port            = config.gateway_port,
        transport       = "tcp",
        protocol_version = 3, -- 新增命令为兼容扩展，已有字段/枚举不重用。
    }))
    skynet.error("FRAME_GATEWAY_READY port=", config.gateway_port)
    skynet.exit()
end)
```

### server/config/frame_battle_process.lua

**操作：新建。** 独立进程配置消费新增Native产物，不覆盖第二课启动配置。

学习导航：精读 所有相对路径以server为当前目录；共享库通过ORIGIN寻找frame_core.so。 可以略读固定声明与语言样板。输入、输出和失败语义见文件头及 API 注释；本节验证命令在该阶段末尾。阅读后应能解释这些状态的 owner、修改时机和释放位置。

```lua
--- 职责：Frame Battle进程启动路径；不保存Battle动态状态。
-- 职责：Battle Skynet 进程启动配置；由 run_server.sh 直接传给 Skynet。
-- 边界：只设置进程级路径、日志和入口；业务参数仍由 config.battle 提供。
-- 相对路径：以下路径均以 Server 根目录为基准，因此启动前工作目录必须是 server/。
thread = 4
harbor = 0
logger = "./logs/battle" -- Skynet 把日志文件参数交给 FlyWow Logger；按天写入此目录。
logservice = "flywow_logger"
flywow_logger_level = "normal" -- normal 及以上级别入盘，debug 被忽略。
start = "battle/battle_main"
bootstrap = "snlua bootstrap"

luaservice = "./service/?.lua;./third_party/skynet/service/?.lua"
lualoader = "./third_party/skynet/lualib/loader.lua"
lua_path = "./?.lua;./lualib/?.lua;./lualib/?/init.lua;" ..
           "./third_party/skynet/lualib/?.lua;" ..
           "./third_party/skynet/lualib/?/init.lua;" ..
           "./third_party/skynet-flywow/navigation/lualib/?.lua;" ..
           "./third_party/skynet-flywow/logger/lualib/?.lua"
lua_cpath = "./luaclib/?.so;./third_party/lua-protobuf-runtime/?.so;" ..
            "./third_party/skynet/luaclib/?.so;" ..
            "./third_party/skynet-flywow/build/native/?.so"
cpath = "./third_party/skynet/cservice/?.so;" ..
        "./third_party/skynet-flywow/build/native/?.so"
preload = "./third_party/skynet-flywow/logger/lualib/flywow_logger_preload.lua"
start = "battle/frame_sync/main"
logger = "./logs/frame_battle"
lua_cpath = "./build/frame_sync/?.so;" .. lua_cpath
```

### server/config/frame_gateway_process.lua

**操作：新建。** Gateway启动时只消费接入模块和共享Proto生成物。

学习导航：精读 复用已验证路径，不让Gateway加载地图或Frame Native核心。 可以略读固定声明与语言样板。输入、输出和失败语义见文件头及 API 注释；本节验证命令在该阶段末尾。阅读后应能解释这些状态的 owner、修改时机和释放位置。

```lua
--- 职责：Frame Gateway进程启动配置；Gateway/Battle仍是独立OS进程。
-- 职责：Gateway Skynet 进程启动配置；由 run_server.sh 直接传给 Skynet。
-- 边界：只设置进程级路径、日志和入口；业务参数仍由 config.gateway 提供。
-- 相对路径：以下路径均以 Server 根目录为基准，因此启动前工作目录必须是 server/。
thread = 4
harbor = 0
logger = "./logs/gateway" -- Skynet 把日志文件参数交给 FlyWow Logger；按天写入此目录。
logservice = "flywow_logger"
flywow_logger_level = "normal" -- normal 及以上级别入盘，debug 被忽略。
start = "gateway/gateway_main"
bootstrap = "snlua bootstrap"

-- Service 文件分散在 Server、Skynet 和 FlyWow Gateway；Skynet 按顺序查找。
luaservice = "./service/?.lua;./third_party/skynet/service/?.lua;" ..
             "./third_party/skynet-flywow/gateway/service/?.lua;" ..
             "./third_party/skynet-flywow/gateway/service/gateway/?.lua"
lualoader = "./third_party/skynet/lualib/loader.lua"
lua_path = "./?.lua;./lualib/?.lua;./lualib/?/init.lua;" ..
           "./third_party/skynet/lualib/?.lua;" ..
           "./third_party/skynet/lualib/?/init.lua;" ..
           "./third_party/skynet-flywow/gateway/lualib/?.lua;" ..
           "./third_party/skynet-flywow/gateway/lualib/?/init.lua;" ..
           "./third_party/skynet-flywow/logger/lualib/?.lua"
lua_cpath = "./luaclib/?.so;./third_party/lua-protobuf-runtime/?.so;" ..
            "./third_party/skynet/luaclib/?.so;" ..
            "./third_party/skynet-flywow/build/native/?.so"
cpath = "./third_party/skynet/cservice/?.so;" ..
        "./third_party/skynet-flywow/build/native/?.so"

-- Logger 的 Lua 适配在每个 Lua State 启动时加载，skynet.error API 保持不变。
preload = "./third_party/skynet-flywow/logger/lualib/flywow_logger_preload.lua"
start = "gateway/frame_sync/main"
logger = "./logs/frame_gateway"
```

### 5.6 把新Native接入现有公开build入口

**操作：局部修改 `server/scripts/linux/run_server.sh`，完整替换其中 `run_build()` 函数：**

```bash
run_build() {
    prepare_runtime
    "$SCRIPT_DIR/check_lua_varargs.sh"
    cmake -S "$SERVER_ROOT/native/frame_sync" \
      -B "$SERVER_ROOT/build/frame_sync" -DCMAKE_BUILD_TYPE=Release
    cmake --build "$SERVER_ROOT/build/frame_sync" --parallel 4
    ctest --test-dir "$SERVER_ROOT/build/frame_sync" --output-on-failure
    python3 "$SERVER_ROOT/scripts/lessons/prepare_frame_sync.py"
    log "BUILD_OK"
}
```

FlyWow仍由prepare_runtime调用固定子模块的 `scripts/build_flywow.sh`，不新建第二个公共build脚本；本课只在宿主入口追加玩法Native和资产验证。新启动配置完整列出路径：Skynet配置求值环境没有dofile，不用 `dofile(base_config)` 隐藏依赖。

执行：

```bash
./scripts/linux/run_server.sh build
./third_party/skynet/3rd/lua/lua tests/frame_binding_test.lua
./third_party/skynet/3rd/lua/lua tests/frame_runtime_test.lua
```

预期各CTest和两Lua测试通过，最后build输出BUILD_OK。不要使用旧第三课的online启动命令；新进程入口如下。

## 6. 先运行真实双进程，再打开Unity

### 6.1 启动、停止与日志

WSL终端A，从server目录启动Battle：

```bash
./third_party/skynet/skynet config/frame_battle_process.lua
```

WSL终端B，从server目录启动Gateway：

```bash
./third_party/skynet/skynet config/frame_gateway_process.lua
```

日志分别写 `server/logs/frame_battle/日期.log`、`server/logs/frame_gateway/日期.log`。终端C检查：

```bash
rg -n 'FRAME_BATTLE_READY|FRAME_GATEWAY_READY|failed|error' logs/frame_battle logs/frame_gateway
ss -ltnp 'sport = :19021 or sport = :2537 or sport = :2538'
```

预期两个READY以及三个监听端口。主Service执行 `skynet.exit()` 仅退出组合根，不会关闭Worker/Gateway；停止这两场前台进程分别在对应终端Ctrl+C。不要用 `pkill skynet` 杀掉其它正在学习的进程。

### 6.2 新建真实链路测试

下面测试复用第二课已有 `server/tests/gateway_handshake_client.py`，以实际P-256握手进入Gateway，使用真实TCP/Proto/Cluster/Worker/Native。测试中的通用Protobuf wire解析只属于Test；Runtime仍由唯一Proto生成的descriptor/Registry实现。它无需另外安装Python Protobuf，但需要第二课已经安装的cryptography。

### server/tests/frame_sync_integration.py

**操作：新建。** 用真实握手、TCP、Gateway、Cluster、Worker与Native证明输入日志能够重演。

学习导航：精读 定向推送不串场、重连代数、错误凭据、连续帧hash与回放分页。 可以略读固定声明与语言样板。输入、输出和失败语义见文件头及 API 注释；本节验证命令在该阶段末尾。阅读后应能解释这些状态的 owner、修改时机和释放位置。

```python
# 职责：第三课真实双进程验收客户端；仅 Test 使用，不成为 Runtime 协议实现。
# 输入：已启动的 Frame Gateway 及相同编译产物；输出断言与 FRAME_INTEGRATION_OK。
# 这个轻量 wire reader 只减少测试环境依赖；字段编号仍以唯一 Proto 定义为准。
from pathlib import Path
import ctypes
import socket
import struct

from gateway_handshake_client import perform

ROOT = Path(__file__).resolve().parents[2]


def varint(value):
    """编码非负 Proto varint；调用方保证输入在协议允许范围内。"""
    result = bytearray()
    while value > 127:
        result.append((value & 0x7F) | 0x80)
        value >>= 7
    result.append(value)
    return bytes(result)


def number(field, value):
    """编码 wire type 0 的整数测试字段。"""
    return varint(field << 3) + varint(value)


def blob(field, value):
    """编码 wire type 2 的 bytes 测试字段。"""
    return varint((field << 3) | 2) + varint(len(value)) + value


def zigzag(value):
    """将本用例使用的有符号32位值映射为 Proto sint32。"""
    return (value << 1) ^ (value >> 31)


def fields(data):
    """解析本课消息使用的 wire types；拒绝未知类型和超长 varint。"""
    result = {}
    offset = 0

    def read_varint():
        nonlocal offset
        value = 0
        shift = 0
        while True:
            byte = data[offset]
            offset += 1
            value |= (byte & 0x7F) << shift
            if byte < 0x80:
                return value
            shift += 7
            assert shift <= 63, "varint exceeds 64 bits"

    while offset < len(data):
        tag = read_varint()
        field, wire = tag >> 3, tag & 7
        if wire == 0:
            value = read_varint()
        elif wire == 2:
            size = read_varint()
            value = data[offset : offset + size]
            assert len(value) == size, "truncated length-delimited field"
            offset += size
        elif wire == 5:
            value = struct.unpack_from("<I", data, offset)[0]
            offset += 4
        elif wire == 1:
            value = struct.unpack_from("<Q", data, offset)[0]
            offset += 8
        else:
            raise AssertionError(f"unsupported wire type: {wire}")
        result.setdefault(field, []).append(value)
    return result


def one(data, field, default=0):
    """读取本用例约定的第一个字段值；缺失时返回明确的测试默认值。"""
    return data.get(field, [default])[0]


class Client:
    """单连接测试客户端；socket 由实例拥有，close 负责释放。"""

    def __init__(self):
        self.sock = socket.create_connection(("127.0.0.1", 19021), timeout=3)
        self.sock.settimeout(3)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.seq = 0
        self.pushes = []  # request() 先读到的异步推送暂存于本连接。
        perform(self.send, self.receive)

    def exact(self, size):
        """TCP read 可短读；累积至指定字节数，否则让连接错误显式失败。"""
        data = b""
        while len(data) < size:
            part = self.sock.recv(size - len(data))
            assert part, "unexpected EOF"
            data += part
        return data

    def send(self, data):
        """用两字节大端长度前缀发送一个完整 Gateway frame。"""
        self.sock.sendall(struct.pack(">H", len(data)) + data)

    def receive(self):
        """读取完整长度前缀与 payload；exact 处理任意 TCP 分段。"""
        size = struct.unpack(">H", self.exact(2))[0]
        return self.exact(size)

    def send_request(self, command, body):
        """分配本连接递增 request_id 并发送；不等待 Server 处理。"""
        self.seq += 1
        envelope = number(1, 3) + number(2, command) + number(3, self.seq) + blob(4, body)
        self.send(envelope)
        return self.seq

    def request(self, command, body):
        """等待匹配响应，同时保留先到的无关联 FramePush。"""
        request_id = self.send_request(command, body)
        for _ in range(100):
            envelope = fields(self.receive())
            response = fields(one(envelope, 4, b""))
            if one(envelope, 3) == 0:
                assert one(envelope, 2) == 1103
                self.pushes.append(response)
                continue
            assert one(envelope, 3) == request_id
            assert one(envelope, 2) == command
            return response
        raise AssertionError("control starved")

    def push(self):
        """返回排队推送，或继续读到下一条 request_id=0 的推送。"""
        if self.pushes:
            return self.pushes.pop(0)
        envelope = fields(self.receive())
        assert one(envelope, 3) == 0 and one(envelope, 2) == 1103
        return fields(one(envelope, 4, b""))

    def close(self):
        """关闭本实例拥有的 socket；调用方在 finally 中执行。"""
        self.sock.close()


class Native:
    """独立 Native Replay 校验器；只重放 Server 已正式采用的记录。"""

    def __init__(self):
        library = ROOT / "server/build/frame_sync/libframe_core.so"
        self.lib = ctypes.CDLL(str(library))
        self.lib.fs_open.argtypes = [ctypes.c_char_p]
        self.lib.fs_open.restype = ctypes.c_void_p
        self.lib.fs_close.argtypes = [ctypes.c_void_p]
        self.lib.fs_step.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int]
        self.lib.fs_save.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int]
        self.lib.fs_restore.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int]
        map_path = ROOT / "shared/navigation/battle_1001/battle_1001.bmap"
        self.handle = self.lib.fs_open(str(map_path).encode())
        assert self.handle, "Native Engine creation failed"

    def restore(self, data):
        """从拥有的 bytes 恢复独立 Engine；不与 Server 共享可变状态。"""
        assert self.lib.fs_restore(self.handle, data, len(data)) == 1

    def save(self):
        """复制 Native 输出到 Python bytes，缓冲区由本方法拥有。"""
        output = ctypes.create_string_buffer(16384)
        size = self.lib.fs_save(self.handle, output, len(output))
        assert 0 < size <= len(output)
        return output.raw[:size]

    def step(self, record):
        """应用一条 Server 正式帧记录，并核对该帧状态摘要。"""
        command = fields(one(record, 1, b""))

        def signed(field):
            value = one(command, field)
            return (value >> 1) ^ -(value & 1)

        ok = self.lib.fs_step(self.handle, signed(2), signed(3), one(command, 4))
        assert ok == 1, "Native replay step failed"
        state = self.save()
        digest = 2166136261
        for byte in state:
            digest = ((digest ^ byte) * 16777619) & 0xFFFFFFFF
        assert digest == one(record, 3), "STATE_DIVERGENCE"

    def close(self):
        """释放本实例唯一拥有的 Native handle。"""
        self.lib.fs_close(self.handle)
        self.handle = None


def run():
    """验证双连接隔离、权威帧推送、重连及整段 Replay 确定性。"""
    first = second = reconnected = engine = None
    try:
        first = Client()
        joined = first.request(1101, number(1, 1001))
        assert one(joined, 1) == b"OK"

        second = Client()
        other_join = second.request(1101, number(1, 1001))
        assert one(other_join, 1) == b"OK"
        battle = one(joined, 2)
        generation = one(joined, 4)
        token = one(joined, 3)
        assert len(token) == 32 and battle != one(other_join, 2)

        engine = Native()
        engine.restore(one(joined, 10))
        frame = one(joined, 9)
        # 每次仅发送未来意图；Replay 只采用收到的权威 FramePush record。
        for _ in range(16):
            target = frame + 3
            command = number(1, target) + number(2, zigzag(1)) + number(4, 2)
            first.send_request(1102, number(1, battle) + number(2, generation) + blob(3, command))
            pushed = first.push()
            assert one(pushed, 1) == battle and one(pushed, 2) == generation
            assert one(pushed, 4) == b"OK"

            for raw_record in pushed.get(3, []):
                record = fields(raw_record)
                record_frame = one(fields(one(record, 1, b"")), 1)
                assert record_frame == frame + 1
                engine.step(record)
                frame = record_frame

            isolated_push = second.push()
            assert one(isolated_push, 1) == one(other_join, 2), "cross battle broadcast"
        assert frame >= 16

        first.close()
        first = None
        reconnected = Client()
        denied = reconnected.request(1104, number(1, battle) + blob(2, b"x" * 32))
        assert one(fields(one(denied, 1, b"")), 1) == b"NOT_FOUND"

        recovered = reconnected.request(1104, number(1, battle) + blob(2, token))
        current = fields(one(recovered, 1, b""))
        assert one(current, 1) == b"OK"
        assert one(current, 4) == generation + 1 and one(current, 9) >= frame
        engine.restore(one(current, 10))
        frame = one(current, 9)
        pushed = reconnected.push()
        assert one(pushed, 1) == battle and one(pushed, 2) == generation + 1
        for raw_record in pushed.get(3, []):
            engine.step(fields(raw_record))

        replay = reconnected.request(1106, number(1, battle) + blob(2, token) + number(3, 0))
        assert one(replay, 1) == b"OK" and one(replay, 3) > 0
        initial = fields(one(replay, 4, b""))
        assert one(initial, 3, b"") == b""
        engine.restore(one(initial, 10))
        expected = 0
        for raw_record in replay.get(2, []):
            record = fields(raw_record)
            expected += 1
            assert one(fields(one(record, 1, b"")), 1) == expected
            engine.step(record)
        assert expected == one(replay, 3)
        print("FRAME_INTEGRATION_OK frames=", expected, "generation=", one(current, 4))
    finally:
        # 各资源仅由本测试对象拥有；失败断言也必须关闭已创建实例。
        for resource in (first, second, reconnected, engine):
            if resource is not None:
                resource.close()


if __name__ == "__main__":
    run()
```

WSL终端C执行：

```bash
python3 tests/frame_sync_integration.py
```

预期 `FRAME_INTEGRATION_OK frames=... generation=2`；帧数可能因调度在17/18等相邻值，不把日志的墙钟调度差异当成模拟分歧。断言逐帧连续和hash，不依赖固定网络包到达时刻。

此测试覆盖两独立Battle定向推送、输入采用后的Native重演、错误凭据拒绝、断线恢复代数更新、Checkpoint恢复、第一页日志重演以及回放不包含凭据。它不是完整的容量压测，也不是Unity表现验收。

失败排查顺序：无监听先看启动日志；有监听握手失败看FlyWow握手模块和固定版本；Join超时看Registry和两端Cluster节点名；Join成功无push回第3节审计条件；STATE_DIVERGENCE先比地图资产hash与双方发布的程序版本，再比规范化字段，不通过强制覆盖客户端状态掩盖固定规则错误。

## 7. Windows构建同一Core，接入实际Unity客户端

### 7.1 Windows DLL

把已审核的WSL非Unity源码按Git流程同步到Windows工作区，确认相同submodule提交。Windows必须有C++17编译器与CMake；在相应Developer PowerShell中，仓库根执行：

```powershell
cmake -S server/native/frame_sync -B server/build/frame_sync_windows -A x64 -DLESSON_FRAME_LUA=OFF
cmake --build server/build/frame_sync_windows --config Release --parallel 4
ctest --test-dir server/build/frame_sync_windows -C Release --output-on-failure
New-Item -ItemType Directory -Force unity/BattleNavigation/Assets/BattleNavigation/Plugins/FrameSync | Out-Null
Copy-Item -LiteralPath server/build/frame_sync_windows/Release/frame_core.dll -Destination unity/BattleNavigation/Assets/BattleNavigation/Plugins/FrameSync/frame_core.dll
```

多配置生成器的Release产物在Release目录；使用单配置生成器时按CMake实际输出目录取DLL，不盲目假定路径。不要把Linux `.so` 改名成 `.dll`。Unity Plugin Inspector中禁用Any Platform，只启用Windows Editor/Standalone、CPU x86_64；这是本课Windows客户端的发布目标，不宣称已验证Android/iOS/WebGL。修改/重建DLL前退出Play并释放Native实例，必要时重启Editor解除DLL文件占用。

FlyWow握手继续使用前两课已部署的 `Assets/BattleNavigation/Plugins/FlyWow/FlyWow.Gateway.dll` 与BouncyCastle DLL，Google.Protobuf继续使用已有插件，不再复制SDK源码到Assets形成第二份类型。

### 7.2 Native桥：声明与规范化读取必须同源

下面三个文件在Windows Unity工程新建，放进现有 `Assets/BattleNavigation/client/`，属于已有BattleNavigation.Replay程序集，它已经引用生成Proto所在的BattleNavigation.Client程序集。不要另建一个缺引用的asmdef。

### unity/BattleNavigation/Assets/BattleNavigation/client/FrameNative.cs

**操作：新建。** Unity只通过稳定C ABI推进与恢复本地模拟；不把Transform写回Server。

学习导航：精读 Native handle的唯一owner、DLL位宽、规范化状态字段顺序、资源释放。 可以略读固定声明与语言样板。输入、输出和失败语义见文件头及 API 注释；本节验证命令在该阶段末尾。阅读后应能解释这些状态的 owner、修改时机和释放位置。

```csharp
// 职责：Unity帧同步Native调用及只读渲染状态解码；不负责Socket或Server权威。
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace BattleNavigation.FrameSync
{
    /// <summary>拥有单场客户端预测模拟的Native句柄；仅主线程访问，Dispose释放。</summary>
    public sealed class FrameNative : IDisposable
    {
        // C ABI只返回稳定整数成功标记；Native错误统一映射为下方托管异常。
        [DllImport("frame_core", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr fs_open([MarshalAs(UnmanagedType.LPUTF8Str)] string path);
        [DllImport("frame_core", CallingConvention = CallingConvention.Cdecl)]
        private static extern void fs_close(IntPtr handle);
        [DllImport("frame_core", CallingConvention = CallingConvention.Cdecl)]
        private static extern int fs_step(FrameHandle handle, int x, int z, int skill);
        [DllImport("frame_core", CallingConvention = CallingConvention.Cdecl)]
        private static extern int fs_save(FrameHandle handle, byte[] bytes, int capacity);
        [DllImport("frame_core", CallingConvention = CallingConvention.Cdecl)]
        private static extern int fs_restore(FrameHandle handle, byte[] bytes, int count);
        [DllImport("frame_core", CallingConvention = CallingConvention.Cdecl)]
        private static extern uint fs_map_version(FrameHandle handle);
        [DllImport("frame_core", CallingConvention = CallingConvention.Cdecl)]
        private static extern uint fs_map_id(FrameHandle handle);
        private sealed class FrameHandle : SafeHandleZeroOrMinusOneIsInvalid
        {
            public FrameHandle(IntPtr value) : base(true)
            {
                SetHandle(value);
            }
            protected override bool ReleaseHandle()
            {
                fs_close(handle);
                return true;
            }
        }
        private FrameHandle handle; // SafeHandle为P/Invoke借用自动保活；仍只在主线程使用。
        /// <summary>当前Native实例加载的地图ID；与MapVersion共同标识地图资产。</summary>
        public uint         MapId      => fs_map_id(handle);
        /// <summary>当前Native实例加载的地图版本。</summary>
        public uint         MapVersion => fs_map_version(handle);
        /// <summary>读取UTF-8资产路径并拥有独占Native；失败抛MAP_LOAD，调用方主线程Dispose。</summary>
        public FrameNative(string path)
        {
            handle = new FrameHandle(fs_open(path));
            if (handle.IsInvalid)
                throw new InvalidDataException("MAP_LOAD");
        }
        /// <summary>同步推进50ms；方向-1/0/1、技能0..3；无I/O，失败不改变旧State。</summary>
        public void Step(int x, int z, int skill)
        {
            if (fs_step(handle, x, z, skill) != 1)
                throw new InvalidOperationException("NATIVE_STEP");
        }
        /// <summary>分配并返回本实例规范化状态副本，最大16384bytes；调用方拥有数组。</summary>
        public byte[] Save()
        {
            var buffer = new byte[16384];
            int size   = fs_save(handle, buffer, buffer.Length);
            if (size <= 0)
                throw new InvalidOperationException("NATIVE_SAVE");
            Array.Resize(ref buffer, size);
            return buffer;
        }
        /// <summary>同步借用字节到调用返回；全部验证后替换State，失败保持旧State。</summary>
        public void Restore(byte[] bytes)
        {
            if (bytes == null || bytes.Length > 16384 ||
        fs_restore(handle, bytes, bytes.Length) != 1)
                throw new InvalidDataException("NATIVE_RESTORE");
        }
        public void Dispose()
        {
            handle?.Dispose(); // 幂等；SafeHandle critical finalizer兜底。
        }
        /// <summary>计算状态诊断hash；不用于安全验证或程序版本协商。</summary>
        /// <param name="bytes">由调用方拥有的规范化状态副本。</param>
        /// <returns>32位FNV状态摘要。</returns>
        public static uint Hash(byte[] bytes)
        {
            uint value = 2166136261;
            foreach (byte b in bytes)
                value = unchecked((value ^ b) * 16777619);
            return value;
        }
    }
    /// <summary>从Native规范化状态解码的单位只读表现数据，不是模拟状态owner。</summary>
    public sealed class FrameUnit
    {
        /// <summary>单位ID、阵营、移动模式和三个技能的剩余冷却帧。</summary>
        public uint Id, Camp, MoveMode, Ready1, Ready2, Ready3;
        /// <summary>逻辑坐标，单位为毫米；转换Unity单位只发生在表现边界。</summary>
        public long X, Y, Z;
        /// <summary>当前权威逻辑HP。</summary>
        public int  Hp;
    }
    /// <summary>从Native规范化状态解码的弹丸表现数据。</summary>
    public sealed class FrameBolt
    {
        /// <summary>由Server模拟分配的弹丸ID。</summary>
        public uint Id;
        /// <summary>逻辑坐标，单位为毫米。</summary>
        public long X, Y, Z;
    }
    /// <summary>单次状态解码创建的托管快照；不持有Native资源。</summary>
    public sealed class FrameState
    {
        /// <summary>快照帧号和结束结果；Winner为0表示战斗仍在进行。</summary>
        public uint     Frame, Winner;
        public readonly List<FrameUnit> Units = new List<FrameUnit>();
        public readonly List<FrameBolt> Bolts = new List<FrameBolt>();
        /// <summary>验证版本、数量上限和完整消费长度后解码小端状态副本。</summary>
        /// <param name="bytes">调用方拥有的Native状态副本，最大16384字节。</param>
        /// <returns>新分配且由调用方拥有的托管快照。</returns>
        /// <exception cref="InvalidDataException">格式、版本、容量或尾随字节无效。</exception>
        public static FrameState        Decode(byte[] bytes)
        {
            if (bytes == null || bytes.Length > 16384)
                throw new InvalidDataException("STATE_SIZE");
            // BinaryReader按小端读取固定布局；每个计数先限界，避免恶意快照放大分配。
            using (var reader = new BinaryReader(new MemoryStream(bytes, false)))
            {
                if (reader.ReadUInt32() != 1)
                    throw new InvalidDataException("STATE_VERSION");
                var state =
                    new FrameState { Frame = reader.ReadUInt32(), Winner = reader.ReadUInt32() };
                reader.ReadUInt32(); // next_bolt属于逻辑状态，表现不使用。
                uint units = reader.ReadUInt32();
                if (units > 64)
                    throw new InvalidDataException("UNIT_LIMIT");
                for (uint i = 0; i < units; i++)
                    state.Units.Add(new FrameUnit {
                        Id       = reader.ReadUInt32(),
                        Camp     = reader.ReadUInt32(),
                        MoveMode = reader.ReadUInt32(),
                        X        = reader.ReadInt64(),
                        Y        = reader.ReadInt64(),
                        Z        = reader.ReadInt64(),
                        Hp       = reader.ReadInt32(),
                        Ready1   = reader.ReadUInt32(),
                        Ready2   = reader.ReadUInt32(),
                        Ready3   = reader.ReadUInt32(),
                    });
                uint bolts = reader.ReadUInt32();
                if (bolts > 128)
                    throw new InvalidDataException("BOLT_LIMIT");
                for (uint i = 0; i < bolts; i++)
                {
                    uint id = reader.ReadUInt32();
                    reader.ReadUInt32();
                    reader.ReadUInt32();
                    reader.ReadUInt32();
                    reader.ReadInt32();
                    state.Bolts.Add(new FrameBolt { Id = id, X = reader.ReadInt64(),
                                                    Y = reader.ReadInt64(),
                        Z = reader.ReadInt64()
                    });
                }
                if (reader.BaseStream.Position != reader.BaseStream.Length)
                    throw new InvalidDataException("STATE_TRAILING");
                return state;
            }
        }
    }
}
```

### unity/BattleNavigation/Assets/BattleNavigation/client/FrameConnection.cs

**操作：新建。** 让实时连接同时持续收推帧和发输入；沿用FlyWow握手与两字节framing。

学习导航：精读 读写线程独占职责、有界队列、控制请求超时、Dispose解除阻塞、禁止后台线程读Unity对象。 可以略读固定声明与语言样板。输入、输出和失败语义见文件头及 API 注释；本节验证命令在该阶段末尾。阅读后应能解释这些状态的 owner、修改时机和释放位置。

```csharp
// 职责：单个实时TCP会话，复用FlyWow SDK握手与项目Envelope；不解释战斗模拟。
// 两后台线程只处理网络/Proto；Unity主线程从有界Push队列读取，调用方Dispose。
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
using Battle.Navigation.V1;
using Google.Protobuf;
using FlyWow.Gateway;
namespace BattleNavigation.FrameSync
{
    /// <summary>拥有一个TCP会话及其网络线程；后台线程只处理字节和Proto值。</summary>
    public sealed class FrameConnection : IDisposable
    {
        // gate保护waiting；Command用于拒绝request_id正确但命令不匹配的响应。
        private sealed class Waiting
        {
            public uint                           Command;
            public TaskCompletionSource<Envelope> Result =
                new TaskCompletionSource<Envelope>(
                    TaskCreationOptions.RunContinuationsAsynchronously);
        }
        private readonly TcpClient socket = new TcpClient();
        private NetworkStream      stream;
        // 入站调用生产、writer消费；128项满时关闭会话，防止内存无界增长。
        private readonly BlockingCollection<byte[]> outgoing = new BlockingCollection<byte[]>(128);
        // reader生产、Unity主线程消费；256项满时视为客户端过载并关闭。
        private readonly BlockingCollection<FramePushResponse> pushes =
            new BlockingCollection<FramePushResponse>(256);
        // 控制请求只在锁内增删/查找；响应超时后移除，迟到响应直接丢弃。
        private readonly Dictionary<ulong, Waiting> waiting = new Dictionary<ulong, Waiting>();
        private readonly object                     gate    = new object();
        private Thread                              reader, writer;
        private long                                nextRequest;
        private int                                 closed;
        private volatile string                     fault;
        /// <summary>会话终止原因；null表示当前没有观察到传输失败。</summary>
        public string                               Fault     => fault;
        /// <summary>待Unity主线程读取的推送数量，用于诊断有界队列积压。</summary>
        public int                                  PushDepth => pushes.Count;

        /// <summary>后台连接与握手；超时3秒；成功调用方拥有连接并Dispose，不访问Unity对象。</summary>
        public static async Task<FrameConnection> Connect(string host, int port)
        {
            var connection = new FrameConnection();
            try
            {
                await Task.Run(() => connection.Open(host, port));
                return connection;
            }
            catch
            {
                connection.Dispose();
                throw;
            }
        }
        /// <summary>执行连接、固定协议握手并启动专用读写线程；仅Connect调用。</summary>
        private void Open(string host, int port)
        {
            if (!socket.ConnectAsync(host, port).Wait(3000))
                throw new TimeoutException("CONNECT_TIMEOUT");
            socket.NoDelay      = true; // 小输入包不等待Nagle合并；TCP仍有队头阻塞。
            stream              = socket.GetStream();
            stream.ReadTimeout  = 3000;
            stream.WriteTimeout = 3000;
            using (var handshake = new HandshakeClient())
            {
                WriteFrame(handshake.Begin());
                WriteFrame(handshake.Respond(ReadFrame(99)));
                handshake.Complete(ReadFrame(33));
            }
            stream.ReadTimeout = 10000;
            reader             = new Thread(ReadLoop) { IsBackground = true, Name = "FrameRead" };
            writer             = new Thread(WriteLoop) { IsBackground = true, Name = "FrameWrite" };
            reader.Start();
            writer.Start();
        }
        // TCP不保留消息边界；Exact负责把短读累积成固定长度的自有数组。
        private byte[] Exact(int count)
        {
            var result = new byte[count];
            int offset = 0;
            while (offset < count)
            {
                int n = stream.Read(result, offset, count - offset);
                if (n == 0)
                    throw new EndOfStreamException("DISCONNECTED");
                offset += n;
            }
            return result;
        }
        private byte[] ReadFrame(int expected = 0)
        {
            var header = Exact(2);
            int size   = (header[0] << 8) | header[1];
            if (size < 1 || (expected != 0 && size != expected))
                throw new InvalidDataException("FRAME_LENGTH");
            return Exact(size);
        }
        private void WriteFrame(byte[] bytes)
        {
            if (bytes.Length < 1 || bytes.Length > 65535)
                throw new InvalidDataException("FRAME_SIZE");
            var frame = new byte[bytes.Length + 2];
            frame[0]  = (byte)(bytes.Length >> 8);
            frame[1]  = (byte)bytes.Length;
            Buffer.BlockCopy(bytes, 0, frame, 2, bytes.Length);
            stream.Write(frame, 0, frame.Length);
        }
        private ulong Enqueue(uint command, IMessage body)
        {
            if (Volatile.Read(ref closed) != 0)
                throw new IOException(fault ?? "CLOSED");
            ulong id = checked((ulong)Interlocked.Increment(ref nextRequest));
            EnqueueEnvelope(command, body, id);
            return id;
        }
        private void EnqueueEnvelope(uint command, IMessage body, ulong id)
        {
            var bytes = new Envelope { ProtocolVersion = 3, Command = command, RequestId = id,
                                       Body = ByteString.CopyFrom(body.ToByteArray()) }
                            .ToByteArray();
            if (!outgoing.TryAdd(bytes))
            {
                Fail("OUTGOING_LIMIT");
                throw new IOException("OUTGOING_LIMIT");
            }
        }
        /// <summary>单向输入加入最多128项出站队列；不等待确认，满队列显式关闭。</summary>
        public void SendInputs(FrameInputRequest body)
        {
            Enqueue((uint)CommandId.FrameInput, body);
        }
        /// <summary>控制请求最多8个，等待3秒；await期间只持有纯Proto对象，错误抛异常。</summary>
        public async Task<Envelope> Request(CommandId command, IMessage body)
        {
            var   item = new Waiting { Command = (uint)command };
            ulong id   = checked((ulong)Interlocked.Increment(ref nextRequest));
            lock (gate)
            {
                if (closed != 0)
                    throw new IOException(fault ?? "CLOSED");
                if (waiting.Count >= 8)
                    throw new IOException("CONTROL_LIMIT");
                waiting.Add(id, item);
            }
            try
            {
                EnqueueEnvelope((uint)command, body, id);
                if (await Task.WhenAny(item.Result.Task, Task.Delay(3000)) != item.Result.Task)
                    throw new TimeoutException("CONTROL_TIMEOUT");
                return await item.Result.Task;
            }
            finally
            {
                lock (gate) waiting.Remove(id);
            }
        }
        /// <summary>非阻塞取出一个推送；仅Unity主线程调用，不持有网络锁。</summary>
        public bool TryPush(out FramePushResponse push)
        {
            return pushes.TryTake(out push);
        }
        // Reader独占NetworkStream读取；按request_id分派响应，request_id=0进入有界推送队列。
        private void ReadLoop()
        {
            try
            {
                while (closed == 0)
                {
                    var envelope = Envelope.Parser.ParseFrom(ReadFrame());
                    if (envelope.ProtocolVersion != 3)
                        throw new InvalidDataException("PROTOCOL_VERSION");
                    if (envelope.RequestId == 0)
                    {
                        if (envelope.Command != (uint)CommandId.FramePush)
                            throw new InvalidDataException("PUSH_COMMAND");
                        if (!pushes.TryAdd(FramePushResponse.Parser.ParseFrom(envelope.Body)))
                            throw new IOException("PUSH_LIMIT");
                        continue;
                    }
                    Waiting item;
                    lock (gate) waiting.TryGetValue(envelope.RequestId, out item);
                    if (item == null)
                        continue; // 已超时结果丢弃，不污染新请求。
                    if (item.Command != envelope.Command)
                        throw new InvalidDataException("RESPONSE_COMMAND");
                    item.Result.TrySetResult(envelope);
                }
            }
            catch (Exception ex)
            {
                Fail(ex.Message);
            }
        }
        // Writer独占NetworkStream写入，保证多生产者发送仍按队列顺序串行化。
        private void WriteLoop()
        {
            try
            {
                foreach (var bytes in outgoing.GetConsumingEnumerable())
                    WriteFrame(bytes);
            }
            catch (Exception ex)
            {
                Fail(ex.Message);
            }
        }
        private void Fail(string code)
        {
            if (Interlocked.Exchange(ref closed, 1) != 0)
                return;
            fault = code;
            outgoing.CompleteAdding();
            socket.Close(); // 解除read/write等待；不使用Thread.Abort。
            lock (gate)
            {
                foreach (var item in waiting.Values)
                    item.Result.TrySetException(new IOException(code));
                waiting.Clear();
            }
        }
        /// <summary>幂等终止会话、关闭Socket并有限等待后台线程退出。</summary>
        public void Dispose()
        {
            Fail("CLOSED");
            if (reader != null && reader != Thread.CurrentThread)
                reader.Join(1000);
            if (writer != null && writer != Thread.CurrentThread)
                writer.Join(1000);
            // Collection可能仍被极少数退出路径借用，随此对象GC回收；Socket已同步关闭。
        }
    }
}
```

### unity/BattleNavigation/Assets/BattleNavigation/client/FrameBattleController.cs

**操作：新建。** 让实际按键在本地预测，并根据Server确认帧恢复重演；最终可在场景里观察。

学习导航：精读 confirmed/predicted双实例、只对确认状态核对hash、窗口与GAP、重连清旧代数、回放只读输入。 可以略读固定声明与语言样板。输入、输出和失败语义见文件头及 API 注释；本节验证命令在该阶段末尾。阅读后应能解释这些状态的 owner、修改时机和释放位置。

```csharp
// 职责：Unity输入、固定逻辑帧、预测/回滚、场景表现与回放接入；不是Server权威。
// Native实例和GameObject只由主线程使用；FrameConnection后台只传纯Proto值。
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Threading.Tasks;
using Battle.Navigation.V1;
using Google.Protobuf;
using UnityEngine;
namespace BattleNavigation.FrameSync
{
    /// <summary>在Unity主线程采样输入、预测/校正并渲染；Server仍是战斗权威。</summary>
    public sealed class FrameBattleController : MonoBehaviour
    {
        /// <summary>Frame Gateway主机和端口；只用于在线模式。</summary>
        public string             Host       = "127.0.0.1";
        public int                Port       = 19021;
        /// <summary>空串表示在线；非空时离线读取该Replay路径。</summary>
        public string             ReplayPath = "";
        private FrameConnection   connection;
        // confirmed只应用Server正式记录；predicted应用本地未来意图，两者不共享可变Native状态。
        private FrameNative       confirmed, predicted;
        private FrameJoinResponse session;
        // 未确认输入按目标帧排序；重连后由Install清除，拒绝输入也会从这里移除。
        private readonly SortedDictionary<uint, FrameCommand> pending =
            new SortedDictionary<uint, FrameCommand>();
        private readonly Dictionary<uint, GameObject> actors = new Dictionary<uint, GameObject>();
        private readonly Dictionary<uint, GameObject> bolts  = new Dictionary<uint, GameObject>();
        private FrameReplay                           replay;
        private int                                   replayIndex;
        private float                                 accumulated;
        private int                                   queuedSkill;
        private bool                                  ready, connecting, destroyed;
        private string                                status = "connecting";
        private uint                                  authorityFrame, predictedFrame, winner;
        private int                                   rollbackCount;
        private float                                 castPreviewUntil;
        private string                                MapPath =>
            Path.Combine(Application.streamingAssetsPath, "navigation/battle_1001.bmap");

        /// <summary>Unity启用入口；创建两个独立模拟，并选择在线连接或本地Replay。</summary>
        private async void Start()
        {
            try
            {
                confirmed = new FrameNative(MapPath);
                predicted = new FrameNative(MapPath);
                if (ReplayPath.Length > 0)
                {
                    if (new FileInfo(ReplayPath).Length > 1024 * 1024)
                        throw new InvalidDataException("REPLAY_LIMIT");
                    replay = FrameReplay.Parser.ParseFrom(File.ReadAllBytes(ReplayPath));
                    if (replay.FormatVersion != 1)
                        throw new InvalidDataException("REPLAY_VERSION");
                    if (replay.Records.Count < 1 || replay.Records.Count > 3600 ||
                        replay.Initial == null || replay.Initial.Frame != 0)
                        throw new InvalidDataException("REPLAY_RANGE");
                    Install(replay.Initial);
                    status = "offline replay";
                }
                else
                    await Connect(false);
            }
            catch (Exception ex)
            {
                StopWith(ex.Message);
            }
        }
        /// <summary>建立新会话或使用现有凭据恢复；await后重验对象是否已销毁。</summary>
        private async Task Connect(bool resume)
        {
            connecting = true;
            ready      = false;
            connection?.Dispose();
            var next = await FrameConnection.Connect(Host, Port);
            if (destroyed)
            {
                next.Dispose();
                return;
            }
            connection = next;
            FrameJoinResponse state;
            if (resume)
            {
                var       envelope =
                    await connection.Request(CommandId.FrameRecover, new FrameRecoverRequest {
                        BattleId   = session.BattleId,
                        ResumeToken = session.ResumeToken
                    });
                state = FrameRecoverResponse.Parser.ParseFrom(envelope.Body).State;
            }
            else
            {
                var envelope = await connection.Request(
                    CommandId.FrameJoin,
                    new FrameJoinRequest { ScenarioId = 1001 });
                state        = FrameJoinResponse.Parser.ParseFrom(envelope.Body);
            }
            if (destroyed)
            {
                next.Dispose();
                return;
            }
            Install(state);
            connecting = false;
        }
        /// <summary>验证地图身份与Checkpoint帧号，再原子替换confirmed/predicted起点。</summary>
        private void Install(FrameJoinResponse state)
        {
            if (state == null || state.Code != "OK")
                throw new IOException(state?.Code ?? "EMPTY_STATE");
            string mapHash;
            using (var sha = SHA256.Create()) mapHash =
                BitConverter.ToString(sha.ComputeHash(File.ReadAllBytes(MapPath)))
                    .Replace("-", "")
                    .ToLowerInvariant();
            if (mapHash != state.MapHash || confirmed.MapId != state.MapId ||
                confirmed.MapVersion != state.MapVersion)
                throw new InvalidDataException("ASSET_IDENTITY");
            confirmed.Restore(state.Checkpoint.ToByteArray());
            predicted.Restore(state.Checkpoint.ToByteArray());
            session  = state;
            var view = FrameState.Decode(confirmed.Save());
            if (view.Frame != state.Frame)
                throw new InvalidDataException("CHECKPOINT_FRAME");
            authorityFrame = predictedFrame = view.Frame;
            winner                          = view.Winner;
            pending.Clear();
            accumulated = 0;
            queuedSkill = 0;
            ready       = true;
            status      = "ready";
            if (replay == null && winner == 0)
                SeedLead();
        }
        // 默认2帧=100ms输入提前量；本地在未来帧先执行，Server按deadline采用。
        /// <summary>预先生成默认2个未来帧，使首次按键有本地响应时间。</summary>
        private void SeedLead()
        {
            for (int i = 0; i < 2; i++)
                Predict(new FrameCommand { Frame = predictedFrame + 1 });
        }
        /// <summary>在预测Native推进一帧并记录意图；不改变confirmed权威帧。</summary>
        private void Predict(FrameCommand input)
        {
            predicted.Step(input.X, input.Z, (int)input.Skill);
            predictedFrame       = input.Frame;
            pending[input.Frame] = input;
        }

        /// <summary>在主线程限额消费推送，避免网络积压单帧占满Unity更新。</summary>
        private void DrainFrames()
        {
            if (connection.Fault != null)
                throw new IOException(connection.Fault);
            int processed = 0;
            while (connection.TryPush(out var push))
            {
                if (++processed > 256)
                    throw new IOException("PUSH_BUDGET");
                Receive(push);
            }
        }
        /// <summary>采样一次性技能按键；预览可撤销，技能意图只随一个目标帧发送。</summary>
        private void CaptureSkill()
        {
            int skill = Input.GetKeyDown(KeyCode.L)   ? 3
                        : Input.GetKeyDown(KeyCode.K) ? 2
                        : Input.GetKeyDown(KeyCode.J) ? 1
                                                      : 0;
            if (skill == 0)
                return;
            queuedSkill      = skill;
            castPreviewUntil = Time.unscaledTime + .12f;
        }
        /// <summary>按50ms固定逻辑步推进；每次Update最多补算4步，超限显式停止。</summary>
        private void AdvanceLocalClock()
        {
            accumulated += Time.unscaledDeltaTime;
            int catchup = 0;
            while (accumulated >= .05f && winner == 0)
            {
                if (++catchup > 4)
                    throw new IOException("CLIENT_OVERLOAD");
                accumulated -= .05f;
                if (replay != null)
                    PlaybackStep();
                else
                    LocalStep();
            }
        }
        /// <summary>Unity主线程帧入口；依序收网络结果、采样输入、推进和渲染。</summary>
        private void Update()
        {
            if (!ready || connecting)
                return;
            try
            {
                if (replay == null)
                {
                    DrainFrames();
                    CaptureSkill();
                }
                AdvanceLocalClock();
                Render(FrameState.Decode(predicted.Save()));
            }
            catch (Exception ex)
            {
                StopWith(ex.Message);
            }
        }
        /// <summary>把当前按键作为下一预测帧意图并异步排队；满窗口时拒绝继续预测。</summary>
        private void LocalStep()
        {
            if (FrameState.Decode(predicted.Save()).Winner != 0)
                return; // 预测结束时等待权威确认。
            if (predictedFrame - authorityFrame >= 8 || pending.Count >= 64)
                throw new IOException("PREDICTION_WINDOW");
            int x       = (Input.GetKey(KeyCode.D) ? 1 : 0) - (Input.GetKey(KeyCode.A) ? 1 : 0);
            int z       = (Input.GetKey(KeyCode.W) ? 1 : 0) - (Input.GetKey(KeyCode.S) ? 1 : 0);
            var input   = new FrameCommand { Frame = predictedFrame + 1, X = x, Z = z,
                                           Skill = (uint)queuedSkill };
            queuedSkill = 0;
            Predict(input);
            connection.SendInputs(new FrameInputRequest { BattleId   = session.BattleId,
                                                          Generation = session.Generation,
                                                          Inputs     = { input } });
        }
        /// <summary>接收Server权威记录；验证连续帧和状态摘要后校正本地预测。</summary>
        private void Receive(FramePushResponse push)
        {
            if (push.BattleId != session.BattleId || push.Generation != session.Generation)
                return;
            if (push.Code != "OK")
            {
                status = push.Code;
                if (push.Code == "EMPTY_INPUT" || push.Code == "INPUT_BATCH_TOO_LARGE")
                    return;
                if (push.Code == "OVERLOAD" || push.Code == "INTERNAL")
                    throw new IOException(push.Code);
                throw new InvalidDataException("FRAME_PUSH_CODE");
            }

            // 逐项拒绝结果带有frame；移除本地被拒输入，之后从Confirmed重演。
            foreach (var result in push.InputResults)
            {
                if (result.Code == "OK")
                    continue;
                status = "INPUT_" + result.Code + "_FRAME_" + result.Frame;
                pending.Remove(result.Frame);
            }

            foreach (var record in push.Records)
            {
                if (record.Input.Frame <= authorityFrame)
                    continue;
                if (record.Input.Frame != authorityFrame + 1)
                    throw new InvalidDataException("FRAME_GAP");
                confirmed.Step(record.Input.X, record.Input.Z, (int)record.Input.Skill);
                if (FrameNative.Hash(confirmed.Save()) != record.Hash)
                    throw new InvalidDataException("STATE_DIVERGENCE");
                authorityFrame = record.Input.Frame;
                pending.Remove(authorityFrame);
            }
            Reconcile();
            winner = push.Winner;
        }
        /// <summary>以confirmed状态为新基线，重演未确认输入并统计预测状态变化。</summary>
        private void Reconcile()
        {
            var  before   = predicted.Save();
            uint oldFrame = predictedFrame;
            uint target   = Math.Max(predictedFrame, authorityFrame + 2);
            predicted.Restore(confirmed.Save());
            predictedFrame = authorityFrame;
            ReplayPending(target);
            if (oldFrame == predictedFrame &&
                FrameNative.Hash(before) != FrameNative.Hash(predicted.Save()))
                rollbackCount++;
        }
        /// <summary>按目标帧重演尚未确认输入；无输入的空帧使用中性意图。</summary>
        private void ReplayPending(uint target)
        {
            if (FrameState.Decode(predicted.Save()).Winner == 0)
            {
                for (uint frame = authorityFrame + 1; frame <= target; frame++)
                {
                    if (!pending.TryGetValue(frame, out var input))
                        input = new FrameCommand { Frame = frame };
                    predicted.Step(input.X, input.Z, (int)input.Skill);
                    predictedFrame = frame;
                    if (FrameState.Decode(predicted.Save()).Winner != 0)
                        break;
                }
            }
        }
        /// <summary>离线逐条应用正式Replay输入，并校验每帧状态摘要和帧连续性。</summary>
        private void PlaybackStep()
        {
            if (replayIndex >= replay.Records.Count)
                throw new InvalidDataException("REPLAY_INCOMPLETE");
            var record = replay.Records[replayIndex++];
            if (record.Input.Frame != predictedFrame + 1)
                throw new InvalidDataException("REPLAY_FRAME_GAP");
            predicted.Step(record.Input.X, record.Input.Z, (int)record.Input.Skill);
            if (FrameNative.Hash(predicted.Save()) != record.Hash)
                throw new InvalidDataException("REPLAY_DIVERGENCE");
            predictedFrame = authorityFrame = record.Input.Frame;
            winner                          = FrameState.Decode(predicted.Save()).Winner;
        }
        /// <summary>把逻辑毫米坐标转换为Unity米；只供表现层使用，不回写模拟。</summary>
        private static Vector3 World(long x, long y, long z)
        {
            return new Vector3(x / 1000f, y / 1000f, z / 1000f);
        }
        private readonly List<Material> ownedMaterials = new List<Material>();
        private bool                    savingReplay;
        /// <summary>销毁由本Controller创建的实例材质与GameObject。</summary>
        private void                    DestroyActor(GameObject actor)
        {
            var material = actor.GetComponent<Renderer>().sharedMaterial;
            ownedMaterials.Remove(material);
            Destroy(material);
            Destroy(actor);
        }
        /// <summary>按逻辑ID复用表现对象；材质由Controller创建并统一释放。</summary>
        private GameObject Actor(uint id, bool projectile)
        {
            var index = projectile ? bolts : actors;
            if (index.TryGetValue(id, out var existing))
                return existing;
            var primitive = projectile ? PrimitiveType.Sphere : PrimitiveType.Capsule;
            var actor     = GameObject.CreatePrimitive(primitive);
            actor.name = (projectile ? "Bolt_" : "Unit_") + id;
            Destroy(actor.GetComponent<Collider>()); // 表现不驱动Native碰撞。
            actor.transform.localScale = projectile ? Vector3.one * .25f : new Vector3(.4f, 1, .4f);
            ownedMaterials.Add(actor.GetComponent<Renderer>().material);
            index.Add(id, actor);
            return actor;
        }
        /// <summary>只把已解码快照投影到GameObject；不从Transform回写模拟状态。</summary>
        private void Render(FrameState state)
        {
            foreach (var unit in state.Units)
            {
                var actor = Actor(unit.Id, false);
                var official =
                    replay != null
                        ? unit
                        : FrameState.Decode(confirmed.Save()).Units.First(u => u.Id == unit.Id);
                actor.SetActive(official.Hp > 0);
                var goal = World(unit.X, unit.Y, unit.Z) + Vector3.up;
                // 差异较大直接贴权威预测点，小差异100ms内收敛；只改显示Transform。
                actor.transform.position =
                    Vector3.Distance(actor.transform.position, goal) > 2
                        ? goal
                        : Vector3.Lerp(actor.transform.position, goal,
                                       1 - Mathf.Exp(-Time.unscaledDeltaTime * 30));
                var color = unit.Camp == 1 ? Color.green : Color.red;
                if (unit.Id == 1001 && Time.unscaledTime < castPreviewUntil)
                    color = Color.yellow;
                actor.GetComponent<Renderer>().material.color = color;
            }
            var present = new HashSet<uint>();
            foreach (var bolt in state.Bolts)
            {
                present.Add(bolt.Id);
                var actor                = Actor(bolt.Id, true);
                actor.transform.position = World(bolt.X, bolt.Y, bolt.Z) + Vector3.up;
                actor.GetComponent<Renderer>().material.color = Color.cyan;
            }
            foreach (var id in bolts.Keys.ToArray())
                if (!present.Contains(id))
                {
                    DestroyActor(bolts[id]);
                    bolts.Remove(id);
                }
        }
        /// <summary>连接中断后尝试凭据恢复；失败进入停止状态，不伪造权威状态。</summary>
        private async void Recover()
        {
            if (connecting || session == null || replay != null)
                return;
            try
            {
                await Connect(true);
            }
            catch (Exception ex)
            {
                connecting = false;
                StopWith(ex.Message);
            }
        }
        /// <summary>保存初始Checkpoint和正式采用的输入记录；不保存被拒绝的本地意图。</summary>
        private async void SaveReplay()
        {
            if (savingReplay || destroyed || replay != null)
                return;
            savingReplay = true;
            try
            {
                if (winner == 0)
                    throw new IOException("REPLAY_REQUIRES_FINISHED");
                var  file   = new FrameReplay { FormatVersion = 1 };
                uint offset = 0, total;
                do
                {
                    var envelope = await connection.Request(
                    CommandId.FrameReplay,
                    new FrameReplayRequest
                    {
                        BattleId   = session.BattleId,
                        ResumeToken = session.ResumeToken,
                        Offset      = offset,
                    });
                    if (destroyed)
                        return;
                    var page = FrameReplayResponse.Parser.ParseFrom(envelope.Body);
                    if (page.Code != "OK")
                        throw new IOException(page.Code);
                    if (offset == 0)
                        file.Initial = page.Initial;
                    file.Records.Add(page.Records);
                    offset += (uint)page.Records.Count;
                    total = page.Total;
                    if (total > 3600 || (page.Records.Count == 0 && offset < total))
                        throw new InvalidDataException("REPLAY_PAGE");
                } while (offset < total);
                string path = Path.Combine(Application.persistentDataPath, "frame_last.pb");
                File.WriteAllBytes(path, file.ToByteArray());
                status = "saved " + path;
            }
            catch (Exception ex)
            {
                if (!destroyed)
                    status = ex.Message;
            }
            finally
            {
                savingReplay = false;
            }
        }
        /// <summary>停止当前会话并释放资源；code保留为可观察诊断原因。</summary>
        private void StopWith(string code)
        {
            ready      = false;
            connecting = false;
            status     = code;
            connection?.Dispose();
        }
        /// <summary>绘制连接、帧号、预测窗口和回滚计数等教学诊断信息。</summary>
        private void OnGUI()
        {
            GUILayout.BeginArea(new Rect(10, 10, 520, 250), GUI.skin.box);
            GUILayout.Label(
                $"FrameSync {status} server={authorityFrame} " +
                $"predicted={predictedFrame} rollback={rollbackCount} " +
                $"winner={winner}");
            GUILayout.Label(
                "WASD移动，J近战，K表现弹丸，L逻辑火球；黄闪是本地施法预备反馈，HP由权威帧确认");
            if (predicted != null)
            {
                var view = FrameState.Decode(replay != null ? predicted.Save() : confirmed.Save());
                foreach (var unit in view.Units)
                    GUILayout.Label(
                        $"unit={unit.Id} hp={unit.Hp} mode={unit.MoveMode} y={unit.Y}mm " +
                        $"skillReady={unit.Ready1}/{unit.Ready2}/{unit.Ready3}");
            }
            if (GUILayout.Button("重连 / 权威状态恢复"))
                Recover();
            if (GUILayout.Button("保存结束战斗输入回放"))
                SaveReplay();
            GUILayout.EndArea();
        }
        /// <summary>Unity销毁入口；阻止await续体安装新对象并释放所有拥有资源。</summary>
        private void OnDestroy()
        {
            destroyed = true;
            ready     = false;
            connection?.Dispose();
            confirmed?.Dispose();
            predicted?.Dispose();
            foreach (var actor in actors.Values)
                DestroyActor(actor);
            foreach (var bolt in bolts.Values)
                DestroyActor(bolt);
        }
    }
}
```

## 8. 接线与观察：每一步有具体证据

### 8.1 准备场景与发布资产

1. Unity打开已有 `Assets/BattleNavigation/Scenes/Battle_1001.unity`。执行Save As，保存为 `Battle_1001_FrameSync.unity`，保持静态地形、Camera、Light；不要再次运行地图重建/Bake菜单覆盖手工修改。
2. 在新场景中禁用第二课的 `BattleReplayRuntime` 或挂有旧Replay组件的运行对象，避免它同时生成另一批单位。原第二课场景保持独立可运行。
3. 新建空GameObject `FrameBattleRuntime`，Add Component `FrameBattleController`。Inspector设置Host=`127.0.0.1`、Port=`19021`、ReplayPath留空。
4. 保证 `Assets/StreamingAssets/navigation/battle_1001.bmap` 是第二课发布的同一BMAP。若尚无此文件，创建该目录并从Windows已发布 `shared/navigation/battle_1001/battle_1001.bmap`复制这个客户端消费文件。不是让Server读取Unity目录。
5. 先完成第4节Unity协议生成，让Editor编译；Console不能有重复Proto类型、找不到FramePush或DllNotFound。保存新场景。

如果Windows到WSL的localhost转发在你的WSL网络模式中不可用，Host填写可达WSL地址并调整Gateway监听地址；不要把Windows驱动器绝对路径写进Server Runtime。默认验收只监听127.0.0.1。

### 8.2 正常Play验收

保持第6节双进程运行，Unity进入Play。画面出现地面玩家和两个敌人；飞行敌人出生在高处，然后AI根据目标移动与升降，HUD显示其mode=2和变化的Y毫米值。地面敌人mode=1，按地面规则寻路。

按WASD：玩家应在本地固定步响应，不等网络控制响应。HUD server/predicted帧递增，predicted通常领先少量帧。靠近障碍时地面单位不穿过阻挡，飞行敌人可越过地面障碍但不能穿透地表。玩家没有升降按键。

按J/K/L：立即黄闪是可撤销预备反馈；J只能命中地面目标；K正式伤害发生在施放成功帧，球飞到目标不再扣一次；L正式伤害在逻辑球到达帧才发生。HP与死亡HUD来自confirmed，不使用黄闪或粒子碰撞作为命中证据。无合法目标/距离不足/冷却未结束时Server Core不消费冷却、不扣血。

GameObject Collider被移除，Unity物理不参与战斗。Unit Transform是predicted位置的表现收敛；Native State才是逻辑位置。飞行Y同样是Native整数坐标，不靠Animator抬高模型替代。

### 8.3 预测、回滚和表现

Controller保留两个Native实例：confirmed只执行Server正式帧，predicted执行未来本地意图。未确认输入表不是另一个全局共享Battle；恢复会清空它。每次正式输入到达，先严格验证连续帧和hash，再恢复/重演。正常重复帧可忽略；中间缺帧不能直接跳到最新帧。

表现对象以逻辑unit_id/bolt_id索引。回滚后不存在的Bolt被销毁，新Bolt重新创建；不会用一次性粒子回调重复结算伤害。Material由Controller明确拥有，销毁对象时释放；OnDestroy先关闭网络，再释放Native和表现对象。渲染Lerp只处理显示误差，不允许Lerp后的Transform影响下一步逻辑。

`rollbackCount`是同一预测帧重演后字节hash变化的观察计数；不是抗作弊指标，也不是所有权威确认次数。你还应同时观察正式frame、未来窗口和错误code，不能只盯一个数字判断同步正确。

### 8.4 断线和超窗恢复

关闭Gateway会使读线程或控制请求显式失败，Controller停止继续预测。Battle进程仍运行时，30秒内重启Gateway，点击“重连/权威状态恢复”：新连接重新握手，提交battle_id/token；Server generation递增，返回当前Checkpoint，客户端清掉旧未来输入，重新建立预测提前量。

若是纯客户端网络断线，也通过相同恢复按钮重新建立连接。超过保留期/错误token返回NOT_FOUND；不能悄悄新建另一个Battle冒充原场恢复。若Battle进程重启，内存Battle已不存在，本课没有数据库恢复，不假装resume_token能还原已经销毁的Server状态。

若发生FRAME_GAP、STATE_DIVERGENCE或PREDICTION_WINDOW，停止预测并通过同一入口请求正式恢复。反复分歧要审计源码/资产；恢复按钮不是修复确定性错误的方式。此实现让恢复显式可观察，不设置未说明的无限自动重试。

## 9. 输入回放：与旧第二课事件播放器独立

### 9.1 保存

战斗结束后30秒内点击“保存结束战斗输入回放”。客户端按256帧分页拉取日志，组装FrameReplay，写到 `Application.persistentDataPath/frame_last.pb`，HUD显示实际路径。第一页面携带初始Checkpoint及map/rules身份，但没有resume_token。单场不超过3600帧；保存是结束后的控制任务，不把每帧完整世界状态作为常规消息。

保存文件包含正式采用输入与逐帧hash，不包含客户端曾发送但被拒绝/迟到的意图。`supplied=false` 的补缺输入同样要保存，因为它也影响正式位置和技能。

### 9.2 离线播放

退出Play；Inspector将ReplayPath设置为刚保存文件的完整路径，再进入Play。无需连接Gateway，Controller验证格式版本、文件大小、地图hash和初始Checkpoint，再按50ms逐条执行输入并核对每帧hash。你看到的是重新模拟的状态，不是旧Event Log根据墙钟播放动画。

修改回放输入或hash应得到REPLAY_DIVERGENCE；删除中间帧应得到REPLAY_FRAME_GAP；更换BMAP应得到ASSET_IDENTITY。Replay必须使用与创建记录时兼容的客户端程序版本；程序版本由发布包管理，不从源码字节推导。

## 10. 审计、失败验证与性能记录

### 10.1 每层证据不能混用

|层|执行项|证明什么|
|---|---|---|
|Native|CTest与Golden|相同逻辑输入、恢复与结果字节|
|Binding|frame_binding_test.lua|加载、实例隔离、返回错误、关闭|
|Runtime|frame_runtime_test.lua|窗口、幂等/冲突、补缺、不重复技能|
|Gateway|gateway_async_test.lua|定向push与旧合同边界；是替身单测|
|网络|frame_sync_integration.py|真实握手/Cluster/Worker/回放hash|
|Unity|Play和离线回放|预测手感、主线程边界、表现与生命周期|
|跨OS|Windows与Linux同一Golden输入|当前发布目标整数规则一致性|
|负载/网络|实际配置下计时与故障注入|预算是否适合目标运行条件|

### 10.2 你在实操时还要执行的负向用例

|操作|预期|观察点|
|---|---|---|
|先跑新Gateway测试但保留旧条件|定向push断言失败|证明测试抓得到旧错误|
|恢复旧epoch或不存在目标id|不写任一客户端|Gateway unit断言|
|握手未完成推送|丢弃|ready开关单测；真实连接不得先拿业务消息|
|一批内发送已截止/窗口内/未来9帧输入|逐项返回LATE/OK/INPUT_WINDOW|仅窗口内输入进入pending；FrameRecord确认正式采用|
|批次为空|请求级EMPTY_INPUT|不处理输入，input_results为空|
|批次超过8条|请求级INPUT_BATCH_TOO_LARGE，整批拒绝|不接受任何批内输入|
|同一批重复同帧相同/不同输入|逐项OK/CONFLICT|首条有效输入保持不变|
|恢复后旧generation发输入|拒绝，不影响新会话|Worker owns判定|
|另一连接操作本场但不提供token|不能写本场意图|epoch/id/generation归属|
|满Worker容量后Join|BUSY|不创建额外Native实例|
|Native输入错误或坏Checkpoint|nil/error，旧状态不变|真实Binding断言|
|Worker迟滞超过4帧预算|OVERLOAD|不skip帧，不扩大dt|
|Client不读socket|Gateway现有写缓冲规则关闭慢连接|不能无限保留消息|
|结束/断线30秒后恢复或回放|NOT_FOUND|索引摘除、Native close|
|反复Play/Stop/恢复|线程与Native对象释放|不留多个连接/渲染对象|
|替换规则DLL或地图版本|ASSET_IDENTITY|进入模拟前拒绝|
|删/改回放中间输入|GAP/DIVERGENCE|不能悄悄跳过坏帧|

测试每条时只注入一个变量，记录真实命令、错误code和状态变化。上表是实操验收，不等于作者已经对全部情况做了发布压力测试。

### 10.3 跨平台Golden

WSL Server目录：

```bash
./build/frame_sync/frame_test ../shared/navigation/battle_1001/battle_1001.bmap > /tmp/frame_linux_golden.txt
```

Windows仓库根：

```powershell
$windowsGolden = & ./server/build/frame_sync_windows/Release/frame_test.exe ./shared/navigation/battle_1001/battle_1001.bmap
$linuxGolden = wsl.exe -d Ubuntu -- cat /tmp/frame_linux_golden.txt
$differences = Compare-Object $linuxGolden $windowsGolden -SyncWindow 0
if ($differences) { $differences; throw '跨平台Golden不一致' }
'FRAME_CROSS_PLATFORM_OK'
```

要求逐行相同的frame/hash，不只比较最后赢家。不一致时先确认客户端与Server使用兼容的发布版本，再比地图资产SHA、整型溢出/取整、导航tie-break和序列化字段。逐帧状态hash只用于定位模拟分歧，不充当程序版本身份。

### 10.4 性能与网络，不用样例规模代替预算

首先记录当前commit/submodule、编译器、Release/Debug、CPU、地图尺寸、单位/弹丸数与活跃Battle数。Native每帧序列化+hash成本按状态大小增长；AI A*成本受地图与单位数影响；Worker消息/CPU预算、Gateway写缓冲与客户端队列是不同层的边界。

对独立Native执行 `/usr/bin/time -v ./build/frame_sync/frame_test ...`只得到测试总成本，不是多人实时TPS。对真实Worker逐步增加独立连接与Battle，记录进程RSS、每Tick是否落后和OVERLOAD；达到配置上限必须BUSY，不通过提高所有上限掩盖失败。当前不提供已经验证的“每机支持多少万人”数字。

网络故障实验在你明确选定的测试接口执行Linux netem；不要给有其它任务的默认网络接口加全局丢包。先查 `ip route`与对应WSL本机通信接口，再在独立测试环境加延迟/抖动/丢包并移除规则。记录RTT、队头阻塞、迟到比例、预测窗口错误与恢复所需时间。对于50ms帧、提前2帧、最大8帧窗口，长时阻塞最终必须停止预测；不能无限猜测并将迟到输入写回旧历史。

真实运营前必须根据目标公网条件选择/验证传输、提前量与调度预算，Unity目标平台逐一跑确定性Golden。本文的运行核心、边界和失败机制可审计；本地测试不是所有网络/平台/容量的证明。

## 11. 原第三课知识点如何进入最终版

|原核心知识|本版实现|
|---|---|
|在线Battle生命周期|Worker持有场次、deadline、session、generation、retention|
|多Worker|固定分片、显式handles、每场独占Native|
|导航与动态状态边界|immutable BMAP；Engine私有scratch；地面与空中通行分开|
|AI|纯状态派生、最近目标、固定ID顺序、飞行升降|
|基础技能|Def/ready/Bolt分离，三种Effect，目标类型与高度距离|
|事件/状态观察|正式FrameRecord、hash、confirmed HUD与逻辑Bolt ID|
|Replay|初始Checkpoint+正式采用输入日志，重新模拟核对hash|
|断线恢复|凭据/会话代数、当前Checkpoint、清旧输入、保留期|
|客户端表现|可撤销即时反馈、预测位置、确认HP、回滚对象清理|

旧第三课Event Buffer、旧在线配置或旧Unity组件不是前置依赖。两版不为了共用模拟而增加复杂度；同一帧同步版本两端编译相同Core，是本版确定性合同的实现选择。

## 12. 本课完成检查

- [ ] 从第二课基线逐节创建文件，未依赖旧第三课业务实现。
- [ ] 你亲自完成并审计Gateway目标连接request_id=0修改，红/绿单测真实执行。
- [ ] 唯一Proto、descriptor、Lua Registry与Unity生成物一致。
- [ ] Native/Lua/真实双进程测试通过；报告失败路径与未验证项。
- [ ] 玩家地面操作快速响应；地面敌人寻路、飞行敌人水平移动与升降。
- [ ] 三种技能结算时刻可观察；高度影响正式距离/命中。
- [ ] 输入确认、预测、恢复重演、超窗停止、重连代数边界可解释。
- [ ] 结束输入回放不含凭据，逐帧hash一致。
- [ ] Windows/Linux Golden一致；Unity实际Play、网络故障与资源释放已执行。

### 作者验证记录

2026-10-10，代码在隔离目录编译/运行，未安装到当前Server/FlyWow源码。已执行Linux C++编译与Native CTest、Lua Binding/Runtime测试、Gateway替身单测、唯一Proto/Registry生成、真实双Skynet进程集成；Windows客户端使用现有Unity模块、Google.Protobuf和FlyWow SDK做C#编译。Windows Release Native CTest 通过；Windows/Linux Golden 238行逐行一致；Windows C#客户端连接真实Linux Gateway，连续30帧调用Windows Native核对Server hash通过。Gateway红/绿测试已真实验证旧条件使定向推送断言失败、隔离修复后通过。C# Native句柄使用SafeHandle，主路径Dispose，P/Invoke借用时自动保活。

Unity Editor完整Play/场景表现、长期压力测试、所有网络故障及其它目标平台尚未由这些测试替代。按本课步骤实操时仍须完成对应验收，不把“源码可编译”写成“Unity游戏已联调通过”。
