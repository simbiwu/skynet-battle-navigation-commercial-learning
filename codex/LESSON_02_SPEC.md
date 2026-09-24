# Lesson 02 Spec

本文件只规定第二课目标和验收边界。当前不要生成或扩写第二课实操正文；学习者完成第一课并明确提出后再编写。

主文档：

```text
docs/LESSON_02_PRACTICAL.md
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

`BattleWorker` 必须把核心模拟与墙钟时间、网络和 Unity 播放分开，为第三课同时支持两种驱动方式：

```text
在线：分段接收命令，按 fixed tick 推进并输出 Event/Snapshot
自动：输入准备完成后快速 simulate 到结束，输出完整 Event Log
```

## 完成

```text
[ ] Grid A*
[ ] binary heap
[ ] generation stamp
[ ] AgentProfile
[ ] clearance
[ ] slope
[ ] area
[ ] Path userdata
[ ] NavigationContext
[ ] dynamic occupancy
[ ] attack position
[ ] smoothing
[ ] BattleWorker
[ ] no-yield simulate
[ ] deterministic event
[ ] simple ground target/move/attack AI
[ ] Unity replay
[ ] benchmark
[ ] concurrency stress
[ ] ALL_TESTS_OK
```
