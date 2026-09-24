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
