# FlyWow Gateway 本机 Benchmark 中止报告

日期：2026-10-03（Asia/Shanghai）。状态：按用户指令停止，4096验收与8192探索未完成。

## 结论

本次只完成32连接TCP试运行和256连接TCP的一个30秒负载段。不能据此宣称支持4096或8192连接，也不能给出正式容量或内存泄漏结论。WebSocket、多连接验收、长期运行均未完成。

停止原因是现有 Proxy 合同回归失败。发现错误后曾继续执行框架测试，随后按用户“有错误就停下来，不要继续测试”的指令终止。已只读确认本次 runner 与测试 Skynet 均无遗留；停止后未启动测试。

## 回归失败

运行现有 server/tests/gateway_proxy_test.lua 时返回非零：
```text
./service/gateway/gateway_proxy.lua:156: unknown gateway proxy command: gateway_dispatch
tests/gateway_proxy_test.lua:71
```

旧测试仍发送 gateway_dispatch、使用 request_id 和 route_token。WSL 当前 Gateway 已使用 send_data 消息合同，Envelope仅包含 protocol_version、command、body。当前 Proxy 不接受旧命令，因此测试在入口失败。此结果表明测试与实现合同不一致；尚未验证更新后的 Proxy 正确性，不能据此判定当前 Proxy 全部业务行为正确，也不能将错误归类为压测响应失败。未修改旧测试或 Proxy。

## 测试环境与方法

- 编辑和运行环境：WSL2 Linux 6.18.33.2，Intel Core i5-10400F，12逻辑CPU，WSL可见约7.7GiB内存。
- 主仓库 HEAD：5d13e04aac145214283d999a701c6a699ca0e536。
- FlyWow HEAD：967d939a006606b57eec7066b85d0b4464aa11ab。
- descriptor SHA256：585a2a267dffd767a6b273978e0c2d95bc9336b9192fcab8e91de1ae221d1a93。
- Skynet worker：4；服务和客户端同机loopback，共享CPU。
- 测试实例max_clients=8192，总帧速率上限30000/秒，pending握手上限128；不改生产配置。
- TCP读期限与WS空闲期限仅在测试中覆盖为360000 tick，避免低活跃连接在档位测量中按生产超时策略关闭。
- 完整真实密码握手、Envelope/Protobuf编解码和本地测试Handler；Handler回显map_id测试标记，不执行地图查询或Battle。
- 当前协议不含request_id，每连接最多一个在途请求，通过响应map_id验证标记。
- 固定计划发送时间；同时测RTT与从计划发送时刻计算的延迟，统计客户端迟发。
- 延迟直方图步长0.1ms，分位数报告桶上界；超2秒归末桶，max保留实际值。
- 启动前预热基线，业务测量前5秒预热；握手按32连接一批建立。小规模RSS增量含固定分配与分配器影响，不能视作纯连接对象大小。

## 已完成的负载段

| TCP连接 | 测量秒数 | 目标/成功QPS | RTT p50/p95/p99 ms | 计划发送延迟p99 ms | 错误 | Server CPU（单核100%口径） | 测量结束RSS MiB |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 32 | 5 | 32 / 32 | 0.5 / 1.6 / 1.7 | 2.9 | 0 | 3.0% | 23.73 |
| 32 | 5 | 64 / 64 | 0.4 / 1.6 / 1.7 | 3.7 | 0 | 4.2% | 23.86 |
| 32 | 5 | 2000 / 2000 | 0.4 / 0.5 / 0.5 | 1.6 | 0 | 19.4% | 23.86 |
| 256 | 30 | 256 / 256 | 0.4 / 0.5 / 1.5 | 2.3 | 0 | 5.47% | 25.48 |

32连接的完成段共10480个响应，256连接完成段7680个响应；此表不包含预热请求或被中断的负载段。完成段未出现响应内容校验失败，不能推断未测档位行为。

## 内存与释放

| TCP连接 | 无客户端基线RSS KiB | 握手后RSS KiB | 表观增量/连接 KiB | FD基线/连接后 |
| --- | --- | --- | --- | --- |
| 32 | 20272 | 23920 | 114.0 | 8 / 40 |
| 256 | 20336 | 25264 | 19.25 | 8 / 264 |

32连接关闭并等待6秒后，Gateway stats显示clients=0，FD回到8，RSS保持24432KiB。资源释放证据覆盖连接计数与FD；RSS保留可能来自GC或分配器缓存，未做多轮周转及长期采样，因此既不能认定泄漏，也不能排除泄漏。

256连接在后续测量期间被用户中止，未产生完整released记录，不报告其连接释放RSS数据。该runner finally关闭连接并终止自己创建的Skynet，随后确认无遗留测试进程。

## 验证状态

- Python benchmark语法编译完成。
- 32连接试运行完成，256连接仅一个负载段完成。
- FlyWow握手回归运行3项：2项通过、1项跳过；不将跳过项写为通过。
- Proxy合同回归失败；未修复、未重跑。
- 未验证：1024/2048/4096/8192连接、WS多连接、跨进程Proxy链路、真实QueryCell/Battle、多轮周转、过载恢复、2小时soak。

## 产物与后续门槛

WSL新增测试文件：
- server/tests/gateway_connection_benchmark.py
- server/service/tests/gateway_benchmark.lua
- server/config/skynet_gateway_benchmark.lua

原始产物：
- server/logs/gateway_benchmark/tcp_pilot.jsonl
- server/logs/gateway_benchmark/tcp_main_tcp.jsonl
- server/logs/gateway_benchmark/environment.json
- server/logs/gateway_benchmark/server_tcp_32_pilot.log
- server/logs/gateway_benchmark/server_tcp_256_main_tcp.log

所有修改在WSL完成，未改Windows工作区，未commit或push。

恢复前应先对齐Proxy回归与当前消息/协议合同，验证其成功、失败和资源边界。后续必须遵守遇错停止，不允许回归失败后继续容量测试。本报告保留现场，不替代最终4096/8192验收报告。

## 后续纠正（2026-10-03）

只读检查历史日志确认旧benchmark夹具未处理gateway_disconnect，断开时产生断言堆栈。表中errors=0仅为客户端响应校验统计，不能表示Service无错误。旧结果不得作为benchmark通过或容量验收证据。夹具已更新，但未重跑benchmark。测试接口更新与验证状态见[Gateway测试接口对齐记录](Gateway_测试接口对齐记录_2026-10-03.md)。
