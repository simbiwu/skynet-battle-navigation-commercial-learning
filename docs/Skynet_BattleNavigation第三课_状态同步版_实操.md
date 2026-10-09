# Skynet Battle Navigation 第三课：状态同步版实操

本文定义第三课状态同步版的目标蓝图和施工顺序。它从第二课完成后的代码与资产基线开始，不依赖旧第三课实操文档中的在线 Battle、快照/Event 或技能实现。旧文档只用于提取仍适用的 Server 权威、导航、AI、技能、状态复制和验证知识点。

本课以成熟商业实时战斗的核心网络模型为目标。战斗内容保持简单，技术边界不做玩具化裁剪。

## 1. 学习目标和最终可见结果

```text
Unity 玩家意图
-> Battle 命令序号/确认与 Server fixed tick
-> Server 权威移动、AI、技能和伤害
-> 关键 Event 及时发布 + 周期状态 Snapshot
-> Unity 本地预测、远端插值、权威校正
-> 断线恢复后从 Server 当前状态继续
```

完成后，学习者应能解释并验证：

- Server 如何拥有正式 Battle 状态并拒绝伪造结果；
- 命令与状态更新的传输语义为何不同；
- Event 和 Snapshot 各自解决什么问题；
- 玩家立即操作反馈如何与 Server 校正配合；
- 远端状态如何平滑呈现，丢包或状态缺口如何恢复；
- Battle、Skill、导航 Context、连接与恢复凭据的 owner 和生命周期。

## 2. 玩法蓝图

单个玩家控制一个地面角色，对抗两名同类型 Server AI 敌人。无组队、匹配、成长、奖励和战后结算。地图复用第二课发布的地面 Grid 资产。

Unity 提供方向移动和少量技能按键；另提供自动演示输入源，按最近可攻击目标追击，并从当前可用技能中按 Battle 持有的可复现随机源选择。该随机源及其状态由 Server 拥有，自动输入只负责产生意图，正式位置、寻路、技能、命中、伤害、HP 和死亡仍由 Server 决定。

敌方 AI 按固定逻辑 Tick 选择最近存活对手，平距时用稳定 `unit_id` 打破平局；在攻击范围内攻击，超出范围则寻路接近。AI 技能只从当前合法且冷却完成的技能中选择。胜负：玩家 HP 归零为失败，所有敌人 HP 归零为胜利；同一 Tick 双方全灭判平局。结束后冻结最终状态，不执行结算。

## 3. 状态同步蓝图

### 3.1 Battle 权威和固定 Tick

Battle Process/BattleWorker 拥有 `BattleRuntime`，其中包含 Battle 状态、单位状态、导航 Context、命令接收水位、事件序号、快照基线与恢复凭据。网络处理在 Service Adapter；纯 Battle Step 不读 socket/DB/墙钟、不 yield。

Server 以固定逻辑 Tick 推进模拟，墙钟只驱动 update loop，不进入战斗规则。初始基线沿用第二课已验证的 50ms 逻辑 Tick；Unity 渲染频率独立。正式体验预算由端到端延迟和压力验证确认，不能把 Tick 值当成所有商业游戏的通用标准。

### 3.2 命令、事件和快照是三种不同合同

```text
MoveCommand / CastSkillCommand
  Client -> Server：表达意图，带 battle_id、command_seq、协议/配置版本和参数；可附本地 tick 作为诊断或预测关联字段，但它不参与权威排序和战斗规则

BattleEvent
  Server -> Client：表达已发生的语义结果，例如施法接受、命中、伤害、受伤、死亡

BattleSnapshot / Delta
  Server -> Client：表达某一 Server Tick 的正式状态，用于持续显示、校正和恢复
```

移动输入可以合并为最新方向/目的地状态；离散施法命令按序号确认、去重和过期拒绝。Server 返回 `accepted_seq` 与实际 `apply_tick`，不能把数据报到达、传输层确认或 TCP 控制消息响应误当成 Battle 已接受。

Snapshot 采用有明确基线的增量状态复制；首包、重连、基线失效或增量缺口时发送完整状态。Event 有单调 `event_seq` 和逻辑 Tick；事件积压时客户端请求从保留窗口补拉，超出窗口则切到完整 Snapshot。重要战斗语义不能只靠不可靠的瞬时特效消息承载。移动意图和常态 Delta Snapshot 使用 FlyWow 管理的数据报通道；快照采用最新序号优先，丢失的中间快照不重发，客户端发现 Delta 基线缺口后请求完整 Snapshot。离散施法请求按命令序号在数据报上重复发送直到 Battle 应用层确认，重复请求幂等。重要 Event 由 `event_seq`/确认水位检测缺口并从 Battle 保留窗口补发；完整状态和历史补取走 FlyWow 现有 TCP/WebSocket 控制通道。

建议初始调度值：Server 20Hz fixed Tick，状态 Snapshot 10Hz，重要 Event 在结算后尽快发布；Unity 以插值缓冲显示远端单位。它们是本课可复现的起点，需通过网络条件和性能验证调整，不是商业游戏统一标准。

### 3.3 快速响应

本地玩家移动在 Unity 立即预测，不等 Server 往返后才开始；每个预测状态对应本地命令序号/逻辑 Tick。Server Snapshot 到达后，客户端确认已接受输入并从权威状态重放尚未确认的本地输入，使本地状态收敛。远端单位从已收状态历史插值，短暂缺少下一份状态时才在有界窗口内外推；过窗后停止外推并请求校正。

施法按键立即显示预备动作和本地表现；技能接受/拒绝、正式命中和伤害由 Server Event/状态确认。客户端预测不能提交正式 HP。当前技能采用目标型或逻辑弹丸，不做依赖客户端时钟的权威 Hitscan；若未来加入高精度即时命中，再单独定义 Server 历史状态回看和公平性规则。

## 4. 技能、导航和 AI

### 4.1 基础通用 Skill Runtime

技能定义与运行时分开：

```text
SkillDefinition：版本化静态参数，skill_id、target mask、range、cooldown、执行模型、效果参数
SkillRuntime：本场 Battle 内的冷却、施法状态、在途逻辑弹丸
CastSkillCommand：仅描述 caster/skill/target 或目标位置，不带命中/伤害结果
```

本课实现三个代表模型，不扩成技能海：

```text
Slash       瞬发近战；Server 验证目标/距离后立即结算
Fireball    表现型弹丸；Server 固定发射/影响时点与伤害对象，Unity 插值轨迹，不做碰撞
FrostBolt   逻辑型弹丸；Server 每 Tick 推进、检查碰撞并决定命中/伤害
```

统一验证技能存在、施法者存活、目标合法、目标类型、范围和冷却。以 `Ground/Air` 位掩码表达目标规则，但本课实例只使用 Ground；完整 Air Grid/NoFly 不纳入本课，避免把另一个导航专题塞进状态同步主线。技能不依赖 Unity Transform、表现事件或具体 Grid 类型；区域/持续 Buff 不实现。

### 4.2 导航与 AI

Server 继续使用第二课的 immutable GridMap、Battle-local NavigationContext、A*、Path 和 DynamicOccupancy。Player 的移动请求是意图；Server 重新校验目标并计算正式路径，客户端可以预测路线表现但不能把路线写回 Server。AI 只选择目标并产生移动/施法意图，正式移动和技能统一走 Battle 规则，不复制另一套结算逻辑。

## 5. 网络可靠性、重连与生命周期

FlyWow TCP/WebSocket 通道承载握手、Battle 建立、恢复和完整状态/历史补取；常态 Battle 数据使用 FlyWow 管理的数据报通道，避免高频更新被 TCP 重传阻塞。当前 Gateway 若无数据报公开合同，本课在 FlyWow 子模块按抽取规范补齐会话绑定和有界报文转发；不在宿主课程仓库复制 framing 或另造传输层。Gateway 只做接入与透明投递，不解释 Battle 语义。Battle 负责玩家到 Battle/Worker 的归属、命令序号/确认/重复处理、事件缺口恢复、断线后的归属恢复和 Battle 状态。

创建 Battle 后下发短期恢复凭据；数据报端点通过 TCP 控制通道签发的一次性绑定挑战关联到该 Battle 会话，不能信任客户端自报的玩家或 Battle ID。无账号系统不等于把连接 ID 当玩家身份。重连请求同时提供 `battle_id`、恢复凭据和客户端最后确认的命令/Event/Snapshot 水位；Server 校验 Battle 仍存活后，在控制通道返回即时完整 Snapshot 和后续可用 Event，并重新绑定数据报端点。凭据无效、Battle 已结束或状态超出恢复期限时返回稳定错误。旧连接迟到响应不得投递给新连接。

BattleRuntime、命令队列、Event 保留窗口、并发 Battle 数、Snapshot 响应大小和保留期限都需要与本功能实际持有的资源对应；达到上限明确拒绝、返回 GAP/RESYNC 或关闭过期 Battle，不能静默丢弃已接受命令。

## 6. 从第二课基线开始施工

新在线逻辑放在独立的 `state_sync` 模块，不覆盖第二课批量确定性 Battle 验证入口。状态同步与帧同步不共用战斗模拟实现；只按稳定框架合同使用 Gateway、地图资产、导航查询和协议生成流程。Battle/Skill 暂留课程宿主，完成验收后再依 FlyWow Policy 评估抽取。

### 阶段 A：BattleRuntime 和 Server Tick

在 `server/lualib/battle/state_sync/` 增加状态同步所需的 Battle 状态、技能、AI 和 Snapshot/Event 逻辑；在 `server/service/battle/state_sync/` 增加连接外的 Battle Service/Worker Adapter。Battle 创建时校验地图/技能版本并建独立 NavigationContext；结束、超时、停止和 Worker 异常路径显式释放 Context。

先由纯 Lua 驱动测试创建 Battle、推进一个 fixed Tick、完成一次导航移动和技能命中；每 Tick 记录严格有序的 `logic_tick` 和 `event_seq`。Skynet Timer 只安排 update loop，不放入 Core。

### 阶段 B：意图命令和权威技能

在 `shared/protocol/` 唯一 Proto 源中加入 StateSync 控制与数据报消息，并由既有构建流程生成代码。消息定义版本、序号、确认水位、Delta 基线、最大报文长度与 GAP/RESYNC 语义。FlyWow Gateway 的数据报端点只处理已绑定会话、报文边界和有界转发；Battle 接收端校验 Battle owner、command_seq、位置/技能范围和目标。重复请求返回原接受结果或明确重复语义，过期/越权输入拒绝。FlyWow 改动只放固定子模块，先依抽取政策形成独立测试和验证。

所有 Cast 经过一个 SkillRuntime 入口。规则阶段只改变 Battle 状态并产出结构化 Event；Unity Adapter 将事件映射成动作、弹丸和受伤表现。测试从 `CastSkillCommand` 进入完整链路，证明客户端无法指定 damage/hit/hp。

### 阶段 C：状态复制和 Unity 表现

Snapshot 有 Battle/map/skill 版本、`server_tick`、状态基线/序号和必要的单位位置、HP、技能状态。Delta 明确所依赖的基线，单个数据报不超过协商的传输上限。Event 按 `event_seq` 严格排序并由 Battle 确认水位补发。创建、重连和基线 Gap 通过 TCP/WebSocket 控制通道恢复完整 Snapshot；常态通过数据报发送 Delta Snapshot 与语义 Events。

Unity 主线程只处理表现状态。本地 Player 预测队列按服务器确认水位清理并校正；远端实体按 Snapshot Tick 插值。渲染坐标、动画和弹丸轨迹不参与服务器权威模拟。

### 阶段 D：真实接入、重连和压力边界

沿用第二课 Gateway Process/Battle Process 异步边界。请求由 Gateway 透明转发，Battle 返回时仍走关联回送，不在 Gateway 读包循环中等待整个 Tick/战斗。接入真实 Unity 客户端后验证丢包/延迟/抖动、Event 缺口、Snapshot 基线丢失、重连、重复和过期命令。

## 7. 建议文件结构与文件操作

```text
server/lualib/battle/state_sync/     [新建] Runtime、AI、Skill、Replication 纯业务模块
server/service/battle/state_sync/    [新建] Battle 创建/命令/同步/恢复入口
shared/protocol/                     [局部修改] 唯一 Proto 源和生成流程
unity/                               [局部修改] 输入、预测、插值、校正和表现 adapter
server/tests/state_sync/             [新建] 命令、技能、Snapshot/Event、重连测试
```

每个核心文件开始前，实操步骤说明它解决的问题、owner、输入输出、失败合同和本步验证。FlyWow 代码只通过固定 submodule 的公开合同使用；不把宿主业务改进写回 FlyWow 子模块，不提交或推送任何仓库。

## 8. 回放与验证边界

状态同步版的在线战斗以 Server 权威事件流和带版本的状态快照作为观测与恢复数据；需要保存回放时，记录有序 BattleEvent，并按固定间隔保存权威 Snapshot 作为检查点，回放器消费这些记录，不重新运行帧同步模拟。Lesson 2 的离线批量模拟/Replay 继续保留为独立验证入口，不要求两种模式共用战斗核心。回放数据同样绑定协议、地图、技能配置版本和内容 hash。

## 9. 验收与失败路径

### 权威与命令

- Unity 只能提交 Move/Cast 意图；正式位置、路径、技能合法性、命中、伤害、HP 和死亡都由 Server 决定。
- 命令序号乱序、重复、过期、越权 Battle、坏坐标、坏版本、非法 Skill/Target 均有稳定拒绝行为。
- Battle Core 没有网络 I/O、DB、Skynet 调用、墙钟依赖或 yield。

### 同步与响应

- 本地移动在等待 Server 往返前开始显示；收到权威 Snapshot 后校正并清除已确认输入。
- 远端单位用 Snapshot 历史插值；丢包短时平滑，超过窗口后明确停止外推并请求完整状态。
- Event 按序消费；重复 Event 不重复触发逻辑或副作用；Event GAP 可补齐或切完整 Snapshot。
- 状态增量只能应用到声明的基线；缺基线不猜测合并。数据报重复、乱序、丢失和超长报文均有明确处理；控制通道和数据报会话断线、恢复及端点重绑定分别验证。

### 技能、断线和资源

- 三种技能执行案例覆盖合法/非法目标、超距、冷却、弹丸命中/过期、受伤、死亡和 Event 顺序。
- 逻辑弹丸 Server 决定碰撞；表现型弹丸不参与逻辑碰撞。
- 断线后凭短期凭据恢复到同一 Battle；旧连接响应不会污染新连接；结束 Battle 不可恢复。
- 所有实际队列、Event 窗口、Battle Runtime 和响应有容量/过载合同；失败会释放本场 NavigationContext。

### 性能验证

记录运行环境、Tick 率、Battle 数、单位数、命令率、Snapshot/Event 字节数和 Server CPU p50/p95/p99。分别观察固定 Tick 是否按时完成、Unity 插值滞后、预测校正距离和重连恢复时间。数字必须附条件，不宣称为脱离硬件与网络条件的商业标准。

## 10. 本课范围

包含：Server 权威状态同步、固定 Tick、AI、第二课导航接入、基础通用 Skill Runtime、Event/Snapshot 复制、客户端快速响应、远端插值、本地预测校正、序号/去重、断线恢复、真实 Gateway/Unity 联调和失败路径验证。

不包含：组队、匹配、账号/经济/奖励、大型单位阵容、完整 Buff、复杂技能编辑器、完整 3D/空中导航、Recast/Detour、P2P、帧同步输入日志或为了与帧同步共用而重写 Battle Core。

## 11. 本课与帧同步版的边界

状态同步以 Server 状态复制为主：Unity 发意图，Server 正式模拟并通过 Snapshot/Event 告知结果。帧同步版以逻辑帧输入为主：参与模拟的一端按权威帧输入重复推进确定性模拟。两份教程分别拥有玩法、模拟、网络数据流、恢复和测试；协议生成、FlyWow Gateway、地图资产等公共工程设施只按其已有稳定边界使用，不要求共享 Battle/Skill 实现。

## 12. 完成后的 FlyWow 评估

依 `docs/FLYWOW_EXTRACTION_POLICY.md`，课程先在宿主工程完成、运行和测试。State Sync Battle/Skill 不在课程中途抽取；完成后只评估已验证且确实业务无关的公开能力，不把抽取设为本课通关条件。地图/导航继续使用已固定的 FlyWow 模块，不复制框架源码。
