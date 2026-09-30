# Lesson 03 Spec：可交互的 Server 权威战斗

本文件只规定第三课目标和验收边界。当前不得据此提前生成 Lesson 2 或 Lesson 3 实操正文；学习者明确提出后才编写，并先核对 Lesson 1/2 的真实完成状态。

## 最终可见场景

```text
Player       地面单位；人工输入，Server 权威执行
GroundEnemy  地面单位；Server AI 控制
FlyingEnemy  空中单位；Server AI 控制
```

Unity 必须完整显示三者的移动、施法、弹丸、受伤、HP 和死亡。模型、动画和特效允许使用基础几何体，不能省略真实 Client/Server 执行链。

## 权威边界

Unity 只发送意图：

```text
MoveCommand
CastSkillCommand
```

Server 决定：

```text
权威位置和路径
技能是否合法
冷却、距离和目标类型
命中、伤害、HP 和死亡
弹丸轨迹影响结果时的碰撞
```

Client 不得提交权威位置、命中、伤害或死亡结果。

## Gateway / Battle 通信与责任边界

第二课已经实现 Gateway Proxy 与 Battle Dispatch 之间的双向异步 `cluster.send` 转发：Gateway 把请求透明发送到 Battle，Battle 通过独立回推入口返回关联结果。本课沿用该边界，Gateway 仍只拥有连接、通用 framing/协议接入和连接级资源限制；不根据玩家 ID 决定玩家属于哪个 Battle/BattleWorker，也不拥有玩家归属、Battle 路由、命令顺序、去重、业务重试或战斗状态。

Battle 侧是玩家归属、Battle/Worker 路由、指令接受与可靠性策略、战斗状态的权威 owner。第三课将第二课的请求-响应底座用于在线命令流，并由 Battle 生成快照/Event 响应；Gateway 只按传输会话标识投递，不决定事件业务含义。Battle 负责定义命令 ID/序号、重复与过期命令、确认、丢失检测和重连后的恢复语义。Gateway 只保存维持客户端连接和回送结果所需的传输会话信息；不得把 fd 或可复用的临时连接号当成 Battle 身份。

`cluster.send` 是单向传输，不自带送达确认或业务重试。第二课已用 route token 和有限超时把两个单向 send 组合为客户端可关联的结果响应，但这不提供自动重试或端到端业务可靠性。第三课复用该边界并为在线命令定义序号、重复/过期处理、确认和重连恢复；在线命令仍不能让 Gateway 同步等待整段模拟。Skynet Cluster/Harbor 的机制细节见独立参考文档 [Skynet Cluster 与 Harbor](../docs/SKYNET_CLUSTER_AND_HARBOR.md)；本 Spec 只规定第三课新增的在线战斗行为和可靠性目标。

## 按进程组织 Skynet Lua 代码目录

第三课按进程分组 Service 入口和进程专属普通 Lua 模块，便于读者看出部署与 ownership 边界。Gateway 与 Battle 的代码不混放；两个进程真正共用的少量模块才放在共享目录：

```text
service/gateway/   Gateway 进程入口及其接入/转发 Service
service/battle/    Battle 进程入口、battle_dispatch、BattleMgr/Worker
                   以及由 Battle composition root 启动的 navigation_query
lualib/gateway/    Gateway 进程专属、由其中 Service require 的普通 Lua 模块
lualib/battle/     Battle 进程专属、由其中 Service require 的普通 Lua 模块
lualib/shared/     确实被两个进程复用且不依赖任一进程状态的普通 Lua 模块
```

`navigation_query` 由 `battle_main` 启动并归 Battle Process 管理，因此 Lesson 3 按进程整理时，它的 Service 入口放在 `service/battle/`；供它调用的 Battle 专属 Lua 模块放在 `lualib/battle/`。可复用的导航算法仍按实际模块边界放在 Battle 模块或 Native 库中，不因为“可能复用”就默认挪入共享目录。

目录只是源码组织方式，不会自行创建 OS 进程或决定 Service 生命周期。`config/skynet_gateway.lua` 与 `config/skynet_battle.lua` 分别设置 `start = "gateway/gateway_main"`、`start = "battle/battle_main"`；对应 composition root 再通过 `skynet.newservice()` 组装同一进程内的子 Service。Skynet 的 `luaservice`/`lua_path` 将模块名映射到 `service/`、`lualib/` 下的文件。Lua 的 `require` 只在当前 Service 的 Lua State 中加载并缓存模块，不会跨进程共享 Lua 对象。文档出现路径迁移时，必须同步更新 `start`、Service 名称、模块 `require`、构建/启动脚本检查和后续代码步骤。

## 地面与空中导航

```text
GroundEnemy -> Lesson 2 Ground Grid / DynamicOccupancy
FlyingEnemy -> 二维 Air Grid / NoFly
worldY = groundHeight + flightHeight
```

FlyingEnemy 可以越过普通地面障碍，但必须绕开 NoFly，并受地图边界和配置的爬升/下降限制。本课不实现完整 3D Voxel Navigation，不表示桥上/桥下或同一 XZ 的多层空中空间。

## 技能模型

必须各有一个可运行案例：

```text
瞬发技能：Server 立即结算，Client 播放表现
表现型弹丸：Server 固定 launch/impact time 和结果，Client 插值轨迹
逻辑型弹丸：轨迹或碰撞影响结果，由 Server 权威计算
```

最小技能组合：

```text
Player：地面近战 + 对空火球
GroundEnemy：近战攻击
FlyingEnemy：空中火球
```

技能需要显式声明 Ground/Air 目标规则，不能靠客户端表现判断是否可命中。

## 同一个模拟内核，两种运行模式

核心合同：

```text
initial snapshot + commands + versions + seed
-> BattleWorker simulate no-yield
-> final state + ordered BattleEvent
```

在线人工验证：

```text
Client 分段发送命令
-> Server fixed tick 推进
-> 持续发送 Event
-> 周期 Snapshot 用于加入、重连和状态校正
```

在线链路中 Gateway 只负责客户端连接和透明转发；玩家到 Battle/Worker 的权威归属与命令可靠性由 Battle 侧处理。自动快速模拟请求仍可采用请求-响应，不得据此把实时命令改成由 Gateway 同步等待 Battle。

自动 SLG 战斗：

```text
输入准备完成
-> Server 不等待墙钟时间，快速模拟到结束
-> 返回完整 Event Log
-> Unity 按逻辑时间回放
```

两种模式必须复用同一个 BattleWorker、AI、导航和技能结算代码。网络收包、等待玩家输入和 Unity 播放不能进入核心 simulate。

## 完成条件

```text
[ ] Player MoveCommand / CastSkillCommand
[ ] fixed tick BattleWorker
[ ] GroundEnemy simple AI
[ ] FlyingEnemy simple AI
[ ] Air Grid / NoFly authoring and asset
[ ] fixed above-ground height
[ ] Ground/Air target mask
[ ] HP / cooldown / range / death
[ ] instant skill
[ ] presentation-only projectile
[ ] server-authoritative collision projectile
[ ] ordered BattleEvent
[ ] periodic BattleSnapshot
[ ] Unity interpolation and simple effects
[ ] online interactive run
[ ] batch full-battle simulation and Replay
[ ] same input/version/seed deterministic test
[ ] malformed/stale/duplicate command tests
[ ] AI, projectile and Air Grid regression tests
[ ] ALL_TESTS_OK
```

## 不属于第三课

```text
Recast / Detour
完整 3D 空中导航
复杂 Skill Editor
完整 Buff 系统
大地图行军、AOI、联盟和跨服
客户端权威命中
```

Recast/Detour 保留为 Lesson 4 可选高级专题，不是前三课战斗闭环的前置条件。

## 第三课完成后的 FlyWow 抽取提醒

本课验收完成后，按 `docs/ENGINEERING_DECISIONS.md` 的 D037 和 `docs/FLYWOW_EXTRACTION_POLICY.md` 评估并抽取已验证的 Unity Package、Server Map/Navigation、Battle 与通用技能能力。抽取是课程完成后的跨仓库工作，不另设第 3.5 课，也不改变本课完成条件或可选第四课范围。H5 2D 接入与完整 Buff 系统按真实需求和测试另行推进。
