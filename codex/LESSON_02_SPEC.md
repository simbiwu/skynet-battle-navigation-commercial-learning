# Lesson 02 Spec

Gateway 接入新增框架内置握手：客户端 SDK 与 Gateway 完成密钥交换和随机挑战后才投递业务消息。宿主无需登录、会话表或 Watchdog；状态机独立成模块，见 `docs/FLYWOW_GATEWAY_HANDSHAKE.md`。连接协议需要双端同步升级，业务 Envelope 版本3与第二课异步合同保持现状。

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

第二课完成 Gateway 与 Battle 两个独立 Skynet Process 之间的双向异步转发。Gateway 只负责连接、通用 framing/协议编解码和透明转发；它按连接串行读取并用本地 `skynet.send` 投递给 Proxy，立即继续读取下一帧。Proxy 用 `cluster.send` 转发已解码请求，Battle 处理完成后另用 `cluster.send` 将有界结果回推给 Gateway Proxy。Proxy 的 route token 只关联返回上下文，不保存或唤醒请求协程；收到结果后用本地 `skynet.send` 投递 `gateway_response`。Gateway 根据响应携带的实例、连接、命令和请求编号编码写回，不保存业务请求等待表。详见 D039。

```text
Client -> Gateway -> Gateway Proxy -> cluster.send -> Battle Dispatch -> Query / BattleMgr
Client <- Gateway <- Gateway Proxy <- cluster.send <- Battle Dispatch <- Query / BattleMgr
```

Gateway 不选择玩家所属 Battle/Worker、不维护战斗状态，也不解释 Battle Event。第二课 `RunAutoBattle` 的客户端仍收到单个关联响应，但 Gateway 与 Battle 之间不使用等待式 `cluster.call`：请求用 send 转发，结果用带 route token 的反向 send 回推。Proxy 路由表、保留时限和 Battle 并发均有上限；超时后迟到回包会被丢弃。响应可以乱序，客户端按 `request_id` 匹配；当前 Unity 短连接每次只发送一个请求，继续兼容，不宣称它已支持单连接并发请求。第三课复用此传输边界实现在线命令流；命令归属、顺序、去重、确认和恢复仍由 Battle 负责，不能倒置为 Gateway 业务逻辑。

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
