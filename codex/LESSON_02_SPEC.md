# Lesson 02 Spec

本文件规定第二课目标和验收边界；第二课实操正文位于下方主文档。勾选表示对应实现与课程说明已完成，不代表所有部署环境都无需再做集成验证。

主文档：

```text
docs/Skynet_BattleNavigation第二课_从Grid寻路到Skynet自动战斗_实操.md
```

## 概念必须按需求出现

顺序建议：

```text
FindPath need
-> A*
-> AgentProfile
-> Path
-> NavigationContext
-> Dynamic Occupancy
-> BattleWorker
-> Simple Ground AI
-> Replay
```

不要开篇先画一整套抽象类图。Lesson 2 只形成当前 Grid 导航所需的稳定调用面，不为可选 Detour 提前创建双 Backend。

## Gateway / Battle 跨进程请求与回包

第二课完成 Gateway 与 Battle 两个独立 Skynet Process 之间的双向异步转发。Gateway 只负责连接、通用 framing/协议编解码和透明转发；Proxy 用 `cluster.send` 转发已解码请求，Battle 处理完成后另用 `cluster.send` 将有界结果回推给 Gateway Proxy。Proxy 用不可由客户端指定的 route token 唤醒原请求协程，Gateway 再按原 `request_id` 编码并写回客户端。

```text
Client -> Gateway -> Gateway Proxy -> cluster.send -> Battle Dispatch -> Query / BattleMgr
Client <- Gateway <- Gateway Proxy <- cluster.send <- Battle Dispatch <- Query / BattleMgr
```

Gateway 不选择玩家所属 Battle/Worker、不维护战斗状态，也不解释 Battle Event。第二课 `RunAutoBattle` 的客户端仍收到单个关联响应，但 Gateway 与 Battle 之间不使用等待式 `cluster.call`：请求用 send 转发，结果用带 route token 的反向 send 回推。Proxy 等待表、超时和 Battle 并发均有上限；超时后迟到回包会被丢弃。第三课复用此传输边界实现在线命令流；命令归属、顺序、去重、确认和恢复仍由 Battle 负责，不能倒置为 Gateway 业务逻辑。

第二课沿用第一课已经验证的目录身份：`BattleWorker`、`BattleMgr`、批处理入口等由 `newservice()` 启动的文件放在 `service/`；`battle_core`、Replay Writer、AI 和其他被 `require` 的普通模块放在 `lualib/`。禁止把普通模块放进 `service/` 后再用文件名假装它是 Worker 或 Service。

`BattleWorker` 必须把核心模拟与墙钟时间、网络和 Unity 播放分开，为第三课同时支持两种驱动方式：

```text
在线：分段接收命令，按 fixed tick 推进并输出 Event/Snapshot
自动：输入准备完成后快速 simulate 到结束，输出完整 Event Log
```

## 完成

```text
[x] Grid A*
[x] binary heap
[x] generation stamp
[x] AgentProfile
[x] clearance
[x] slope
[x] area
[x] Path userdata
[x] NavigationContext
[x] dynamic occupancy
[x] attack position
[x] smoothing
[x] BattleWorker
[x] no-yield simulate
[x] deterministic event
[x] simple ground target/move/attack AI
[x] Unity replay
[x] benchmark
[x] concurrency stress
[x] ALL_TESTS_OK
```
