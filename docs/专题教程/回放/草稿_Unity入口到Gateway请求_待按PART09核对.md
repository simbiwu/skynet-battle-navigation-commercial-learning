# PART 01：从 Unity 回放入口到 Gateway 请求

本节只追踪“请求是怎样离开 Unity 的”。读完后，你应该能回答三个问题：

1. `BattleReplayRequester.Start()` 为什么是协程，以及它把哪些工作放到后台线程？
2. `RunAutoBattle` 的业务请求如何变成一个带长度的 TCP 帧？
3. Gateway 为什么要在收到请求后立即转发，而不是在 Gateway 里执行战斗？

## 1. 这一段代码解决什么问题

场景进入 Play Mode 后，需要自动请求服务端执行 Battle_1001，并把服务端已经算好的事件交给播放器。Unity 这一侧只负责三件事：读取 Inspector 配置、发起一次请求、把响应转换成回放 DTO。

它不负责计算寻路、伤害或胜负。这样划分的目的，是让回放看到的结果来自 Server 的权威事件；客户端即使帧率变化，也不会重新算出另一套战斗结果。

本节涉及的入口和职责如下：

| 文件 | 作用 |
| --- | --- |
| `Assets/BattleNavigation/client/BattleReplayRequester.cs` | Unity 生命周期入口；请求完成后交给播放器 |
| `Assets/BattleNavigation/Scripts/Protocol/ServerBattleClient.cs` | 把 `scenario_id` 包装成 `RunAutoBattle` RPC |
| `Assets/BattleNavigation/Scripts/Protocol/GatewayEnvelopeClient.cs` | TCP、握手、长度帧和 Envelope |
| `shared/protocol/navigation_query.proto` | Unity、Gateway、Battle 共用的消息合同 |

## 2. `Start()` 的执行顺序

`Start()` 是 Unity 的生命周期方法，但返回值是 `IEnumerator`，所以 Unity 会把它当作协程运行。方法开始先检查 `replayPlayer` 和 `scenarioId`。这不是多余的防御：如果引用没有在 Scene 中绑定，继续发请求只会让错误在网络线程深处出现，调试时很难知道是场景配置问题。

随后复制 `host`、`port` 和 `scenarioId` 到局部变量，再创建 `Task.Run`：

```csharp
var pending = Task.Run(() =>
{
    using (var client = new ServerBattleClient(selectedHost, selectedPort))
        return client.Run(selectedScenario);
});
```

这里的关键是边界。`Task` 内部只做普通 .NET TCP/Protobuf 工作，不读取或修改 Unity 对象；协程本身只观察任务状态。Unity 的大多数对象只能在主线程访问，因此不能在 `Task.Run` 中调用 `replayPlayer.Play`、`Debug` 以外的场景对象操作，也不能直接改 Transform。

等待循环中的 `yield return null` 表示“把本帧剩余时间还给 Unity，下一帧再检查”，不会用一个同步 while 把主线程卡死。任务结束后，代码按取消、异常、业务拒绝、成功四类分支处理：

```text
Task 被取消       -> 记录取消并结束
Task 抛异常       -> 输出根异常并结束
Result != OK      -> 输出服务端业务拒绝并结束
Result == OK      -> 转换事件，调用 ReplayPlayer.Play
```

这里要区分“传输失败”和“业务失败”。例如 Gateway 不可达属于异常；`BAD_SCENARIO`、`BUSY`、`BATTLE_FAILED` 则是合法收到的 `RunAutoBattleResponse`，必须读取 `Result` 和 `Message`，不能把它们当成 Protobuf 解析错误。

## 3. `ServerBattleClient.Run()` 做了什么

`Run()` 只构造一个很小的请求：

```csharp
var request = new RunAutoBattleRequest { ScenarioId = scenarioId };
var envelope = gateway.RoundTrip(1002, request);
return RunAutoBattleResponse.Parser.ParseFrom(envelope.Body);
```

客户端只提交 `scenario_id=1001`，没有提交单位位置、HP 或路径。原因是 Battle_1001 的输入快照由服务端的 `battle.scenario_1001` 构造；如果客户端能上传这些状态，回放就可能绕过服务端的权威边界。

`1002` 是 `RunAutoBattle` 的 command id；`1001` 是 `QueryCell`。两个业务都共用同一个 `Envelope`，但 `command` 决定 `body` 应按哪一种 Protobuf 类型解释。调试时如果 command 和 body 类型错配，最先检查的就是这个数字以及协议生成文件是否来自同一份 `.proto`。

## 4. Envelope 和 TCP 长度帧

`GatewayEnvelopeClient.RoundTrip` 先分配进程内递增的 `request_id`，再创建：

```text
Envelope {
    protocol_version = 3
    command          = 1002
    request_id       = 本次请求的 ID
    body             = RunAutoBattleRequest 的 Protobuf bytes
}
```

这层 Envelope 解决的是“这是什么协议、要调用什么、响应属于哪次请求”。它不保存战斗状态，也不保存 TCP 连接身份。

Envelope 序列化后还要经过 `LengthFrame.Pack`。长度帧的作用是给 TCP 字节流划出消息边界：TCP 只保证字节顺序，不保证一次 `Read` 就返回一个完整消息。接收端先读固定大小的长度头，再循环读取指定字节数；`ReadExact` 遇到短读会继续读，遇到 EOF 才报错。这个循环是处理 TCP 的必要条件，不能用一次 `Read` 代替。

## 5. 握手为什么先于业务 Envelope

构造 `GatewayEnvelopeClient` 时，先建立短连接，然后使用 FlyWow SDK 的 `HandshakeClient` 完成三段握手。握手帧仍然使用长度帧，但它们不是业务 Envelope；代码用固定的 99 字节和 33 字节校验当前阶段的协议长度。

这样做把连接级协商和业务请求分开：握手失败时不会进入 `RunAutoBattle`，业务层也不需要重复处理密钥、挑战或连接身份。连接构造失败会释放 `TcpClient`，而正常使用结束由 `using` 调用 `Dispose` 关闭流和 Socket。

## 6. Gateway 收到请求后的第一跳

Gateway Process 启动时会创建 `gateway_proxy`，再启动 FlyWow Gateway，并把 Gateway Service handle 显式绑定给 Proxy。客户端连接到 `127.0.0.1:19011` 后，网络层负责解出 Envelope 和 Protobuf，Gateway Proxy 只接收已经解码的业务 record。

Proxy 的 `dispatch_remote` 做四件事：

1. 检查当前 Gateway Service 是否已经绑定，防止未完成启动就收请求。
2. 为本次请求创建 route token，并在 `pending[token]` 保存回包上下文。
3. 把 token 加入转发 record，通过 `cluster.send` 发到 Battle Process 的 `battle_dispatch`。
4. 立即返回，让 Gateway 继续处理其他连接；结果回来时再用 token 找回原始回包上下文。

这里使用 `cluster.send` 而不是等待 Battle 返回，是因为 Battle 计算可能 yield，Gateway 不应该被一场战斗占住。`pending` 是 Proxy 自己拥有的有限表，超过 `MAX_PENDING=64` 立即返回 `BUSY`；超过约 10 秒则返回 `REMOTE_TIMEOUT`。断线时也会按 `gateway_epoch + connection_id` 清理对应路由，避免旧连接的迟到结果写回新连接。

## 7. 本节的调试断点和观察点

第一次调试时建议按以下顺序观察：

1. Unity Console 是否出现 `RunAutoBattle request was canceled`、连接异常或 `RunAutoBattle rejected`。
2. Unity 断点：`BattleReplayRequester.Start` 中 `pending.Result` 之后，确认 `response.Result` 和 `response.Events.Count`。
3. `GatewayEnvelopeClient.RoundTrip` 中确认 `command=1002`、`request_id` 递增，并在 `ReadFrame` 检查长度是否合法。
4. Gateway 日志中确认 Proxy 已 READY；若出现 `REMOTE_UNAVAILABLE`，检查 Battle cluster 地址和 `battle_dispatch` 是否 READY。
5. Gateway 的 `pending` 只记录路由上下文，不记录战斗单位状态；看到这里仍在做战斗计算，说明职责边界被破坏了。

下一节将继续进入 Battle Process：Gateway 转发的 record 如何被 `battle_dispatch` 识别，`scenario_1001` 如何构造服务端快照，以及 BattleMgr 如何产生有序 Event。

