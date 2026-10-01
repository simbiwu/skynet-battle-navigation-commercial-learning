# FlyWow 异步 Gateway 阅读与接入

本说明对应 D039。Gateway 按连接顺序读取和投递，请求结果通过另一条消息返回；A 的业务处理时间不阻塞 Gateway 读取 B。协议版本仍为3，现有 `.proto` 不增加 Cluster、路由或处理模式字段。

## 按代码执行顺序阅读

| 顺序 | 文件与函数 | 观察点 |
| --- | --- | --- |
| 1 | `server/config/gateway.lua` | 协议产物、连接/帧上限、读超时、写缓冲和入站速率 |
| 2 | `server/service/gateway/gateway_main.lua` | 先启动 Proxy，再把 handle 注入 Gateway；启动 ready 可以 call |
| 3 | FlyWow `service/flywow_gateway.lua`：`start`、`accept_client` | 加载 registry/codec，监听；TCP/WS 接管连接，每连接一个读任务 |
| 4 | 同文件：`run_tcp`、`read_exact` | 读满2字节长度头，校验长度，再读满 payload；读取 Socket 时可能 yield |
| 5 | 同文件：`dispatch_payload` | 校验版本和请求编号，按 registry 解码；本地 send 后继续读下一帧 |
| 6 | `server/service/gateway/gateway_proxy.lua`：`dispatch_remote` | 创建项目 token 与有界返回上下文，cluster.send 后立即返回 |
| 7 | `server/service/battle/battle_dispatch.lua`：`forward_result`、`dispatch_gateway` | 调 Query 或 BattleMgr，业务处理可以 yield；完成后反向 cluster.send |
| 8 | Proxy：`receive_battle_result`、`reply_entry` | 删除 token 路由，形成业务 response，context:reply 单向投递 Gateway |
| 9 | FlyWow：`deliver_response` | 核对 handler 来源、实例与连接；按 command 编码，一次完整消息写入 |
| 10 | FlyWow：`detach`、`timeout_loop`；Proxy：`disconnected`、`expire_pending` | 网络读超时与项目返回路由过期分属两层，均不等待业务协程 |

WebSocket 由 pinned Skynet 的 `http.websocket` 完成 Upgrade、mask、fragment 和 binary 消息拼接，再进入同一个 `dispatch_payload`。WS 握手前就计入连接上限；拒绝尚未 socket.start 的 accepted fd 使用 `socket.close_fd`，已经接管的连接使用 transport 关闭路径。

## 完整请求与响应

```text
客户端 A
  -> Gateway 定长读帧、解码
  -> skynet.send(Proxy, gateway_dispatch, payload)
  -> Gateway 继续读取 B

Proxy
  -> 保存 token 对应的返回上下文，最多64项
  -> cluster.send(Battle Dispatch, gateway_dispatch, forwarded)
  -> 立即返回，不 wait、不 wakeup、不 retpack

Battle Dispatch
  -> Query / BattleMgr / Worker
  -> 业务完成
  -> cluster.send(Proxy, battle_result, token, result)

Proxy
  -> 删除 token 路由
  -> context:reply(response)
  -> skynet.send(Gateway, gateway_response, response_record)

Gateway
  -> 核对来源、gateway_epoch、connection_id
  -> command_id 查 registry.response_type
  -> 编码 response body 与 Envelope，原样带回 request_id
  -> TCP 长度帧 / WS binary message
  -> 客户端按 request_id 关联
```

Gateway 保存连接表、codec/registry 和网络统计，不保存 token、请求等待协程或业务结果。返回地址随消息传递；`.proto` 定义如何编码，当前连接表定义发给哪个有效连接。结果可以 B 先于 A 返回，业务顺序仍由 Battle 决定。

## 业务接入

FlyWow 的 `flywow.gateway.endpoint` 只提供薄的响应上下文，不接管现有 dispatch，不创建业务协程，不包含 Cluster。业务代码先用 request 与明确的 Gateway handle 构造 context，处理后调用 `context:reply(response)`。默认本地 send；项目也可注入返回函数。上下文不保留 request body，每个 context 最多回复一次。

业务主动断开使用 `context:close()`，默认异步发送 `gateway_close`，只携带 `gateway_epoch` 和 `connection_id`。Gateway 只接纳配置的 handler 发来的关闭请求；先摘除连接并发送一次 `gateway_disconnect`，再关闭 transport。重复、迟到、旧实例或未授权请求不影响新连接。关闭投递后当前 context 不再回复；先回复再关闭允许，但投递成功不代表客户端已收到最后一条响应。

跨进程关闭由项目注入 `options.close(message)`，通过 `cluster.send` 发给 Proxy。`gateway_main.lua` 在 Gateway 开始监听前调用 Proxy 的 `bind_gateway` 显式注入 Gateway handle；Proxy 将关闭消息透明转发到该 handle，不需要仍有效的 token。Proxy 当前服务一个 Gateway 实例，多实例由项目分别组装对应 Proxy。断线通知目前到 handler/Proxy，由 Proxy 清理返回路由，不自动继续转发给 Battle。

第一课 `navigation_query.lua` 的外部 Gateway 消息使用 endpoint 回复；它给 Battle Dispatch 提供的内部本地查询仍用 call/retpack。两种调用者通过 session=0/非零区分；不能把内部查询 call 理解成 Gateway 在等待业务。

编号0保留给已登记响应类型的主动消息；本次不交付任意独立推送类型。当前 Unity `GatewayEnvelopeClient` 是短连接、一个调用线程一次请求，继续兼容，但尚未支持单连接并发请求或主动消息消费。

## 失败与资源

- 协议损坏、未知命令、网络读超时、速率超限和持续写缓冲增长按网络策略关闭连接。
- 业务失败和响应编码失败不关闭健康连接，不阻止后续读取。
- Proxy 的容量、发送、结果结构和10秒路由过期错误映射为已有 QueryCell/RunAutoBattle 响应类型。
- 断线移除 Proxy 路由；重复、迟到或旧实例结果丢弃，不自动撤销已经接纳的业务。
- Gateway 实例身份与不复用的连接编号防止误投；fd 不传给 Battle。
- 入站速率限制不是对任意下游 Skynet mailbox 的硬容量保证；项目 handler 必须快速消费并限制业务在途和自建队列。

## 验证与工作区

Server 以 WSL 为编辑源，FlyWow 以独立仓库为开发源。提交顺序是 FlyWow 提交并 Push、WSL Server 固定 submodule 并提交 Push、Windows 拉取后提交文档 Push、WSL 最后拉取。开发可通过显式 `FLYWOW_ROOT` 使用独立工作区；正常运行使用课程固定的 submodule。旧同步 API 与新 handler 不能混用。

```bash
cd /path/to/course/server
export FLYWOW_ROOT=/path/to/updated-skynet-flywow
./scripts/linux/run_server.sh build
./scripts/linux/run_lesson2_processes.sh doctor
./third_party/skynet/3rd/lua/lua tests/gateway_proxy_test.lua "$PWD" "$FLYWOW_ROOT"
python3 tests/gateway_async_integration.py

cd "$FLYWOW_ROOT"
SKYNET_LUA=/path/to/course/server/third_party/skynet/3rd/lua/lua \
  python3 -m unittest discover -s tests -p 'test_*.py'
python3 scripts/ci/check_repository.py
```

2026-10-01 在本机固定 Skynet/Lua 基线上已验证：框架13项测试、课程 Proxy 合同测试、真实 TCP/WS 的 A 延迟/B 先返回、半包/fragment、推送、编码错误、业务失败、断线迟到回包、网络超限与未握手 WS 容量；实际第一课本地 Query、第二课双进程 Query/RunAutoBattle 和多连接查询也通过。课程 Debug 构建及2项 Native 回归通过。

主动关闭也已验证真实 TCP/WS 和独立业务进程经过 Cluster/Proxy 的路径；单元测试覆盖未授权来源、旧实例、重复关闭、发送失败重试和 fd 复用后的身份保护。测试日志位于 WSL `server/logs/gateway_async_tests/`。没有运行商业容量 Benchmark、长时间 soak 或 Unity 编辑器验证；聚焦测试不代表这些验证已经完成。
