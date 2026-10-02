# FlyWow Gateway 本机 Benchmark 报告

日期：2026-10-03（北京时间）。所有修改、运行和报告均在 WSL 工作区完成，未提交或推送 Git。

## 结论

建议将 **4096 连接作为默认容量调整的候选值**，8192 作为进一步验证档位。本次 TCP、WebSocket 均成功建立 8192 个真实连接；4096 连接、8192 请求/秒的三轮复测全部完成且响应校验零错误。生产配置仍为 1024，本次没有修改生产默认值。

4096 连接、8192 请求/秒时，TCP RTT p99 为 5.4–5.5 ms，WebSocket 为 7.3–8.1 ms。包含客户端计划发送迟延的 p99 分别为 16.7–17.3 ms、17.2–19.3 ms。4096 连接、4096 请求/秒的五分钟持续运行中，进程 RSS 约为 TCP 48–49 MiB、WebSocket 62–63 MiB。

8192 连接、16384 请求/秒时出现明显积压：TCP RTT p99 521.9 ms，WebSocket 553.6 ms；计划发送到响应完成的 p99 分别为 1920.5 ms、≥2000 ms。客户端已接近占满一个 CPU 核，因此这些点不能作为网关服务端极限吞吐量。

## 环境与边界

| 项目 | 实际环境 |
|---|---|
| CPU | Intel i5-10400F 2.90 GHz，6 核 / 12 逻辑处理器 |
| 系统 | Ubuntu / WSL2，Linux 6.18.33.2 |
| 内存 | WSL 可见约 7.7 GiB；环境快照时可用约 5.9 GiB，Swap 使用为 0 |
| 运行库 | Python 3.14.4、cryptography 46.0.5、Lua 5.4.7、OpenSSL 3.5.5 |
| 编译器 | GCC 15.2.0；使用现有 Skynet 二进制，未升级或重编译 |
| Skynet / worker | 固定 v1.8.0 基线，4 worker |
| 文件描述符限制 | soft NOFILE 10240 |
| 主仓库提交 | 5d13e04aac145214283d999a701c6a699ca0e536 |
| FlyWow 提交 | 967d939a006606b57eec7066b85d0b4464aa11ab |
| 协议描述 SHA256 | 585a2a267dffd767a6b273978e0c2d95bc9336b9192fcab8e91de1ae221d1a93 |

测试经过真实 FlyWow Gateway、TCP/WebSocket、P256/HKDF/HMAC 握手及 protobuf 编解码，业务端使用本地 Echo Handler。QueryCell 的 map_id 用作测试消息标记，每个连接最多一个请求在途，并校验 version、command、map_id、result。业务 Envelope 约 12–13 字节，没有测大包或真实导航查询计算。

客户端和服务端在同一台机器运行，未绑核，保留已有其他 Skynet 进程。RSS 为网关所在 Skynet 进程内存，客户端单独记录；不包含完整内核 Socket 内存。CPU 100% 表示一个逻辑核，不能与整机总 CPU 百分比直接比较。

测试专用配置 max_clients=8192、每连接 200 请求/秒、总计 30000 请求/秒、pending=128，关闭 Lua 调试器。生产配置仍为 max_clients=1024、总计 10000 请求/秒。测试结果不能直接代替生产配置验证。

## 方法与统计口径

- 连接数：256、1024、2048、4096、8192。每档分批建立连接，握手并发 32；握手时间不是最大连接风暴能力。
- 每档预热 5 秒；正式负载为 2000、连接数、连接数×2 请求/秒（去重排序），各持续 30 秒。
- 4096 档每种传输增加 5 分钟持续运行，以及三次连接全部建立、运行 10 秒、全部关闭、等待 6 秒的循环。
- 4096 档另起进程做 R2、R3 两轮复测，负载各为 2000、8192 请求/秒；R3 再做三次循环。因此每种传输共六次循环，分属两个独立运行实例。
- RTT 从实际发送计时至完整响应校验结束；scheduled latency 从计划发送时刻计时，包含客户端排队和调度迟延。后者更能反映固定到达速率下的拥堵。
- 实际 QPS 按成功响应数 /（计划窗口 + 收尾时间）计算。早期 TCP 原始记录使用计划窗口分母，本报告统一重新计算；正式 WebSocket 和复测记录已使用修正口径。
- 延迟直方图步长 0.1 ms，上限 2000 ms；溢出桶显示为 ≥2000 ms，不将 2000.1 当作精确分位数。最大值独立记录。
- RSS 每秒采样，峰值为采样峰值，可能漏掉短时峰值。Lua MEM 每五秒记录。测量阶段保留自然 GC；强制 GC 仅在全部测量结束后用于诊断。

## 主测试结果

所有表格延迟单位为 ms，QPS 为实际完成速率；每个负载段均零错误。

| 连接数 | 目标 QPS | TCP 实际 QPS | WS 实际 QPS | TCP RTT p99 | WS RTT p99 | TCP 计划延迟 p99 | WS 计划延迟 p99 |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 256 | 256 | 256.00 | 256.00 | 1.5 | 1.6 | 2.5 | 2.7 |
| 256 | 512 | 512.00 | 512.00 | 0.5 | 0.5 | 1.6 | 1.6 |
| 256 | 2000 | 1999.90 | 1999.97 | 0.7 | 0.7 | 1.7 | 1.8 |
| 1024 | 1024 | 1023.97 | 1023.97 | 0.4 | 0.5 | 1.6 | 1.6 |
| 1024 | 2000 | 1999.93 | 1999.93 | 0.5 | 0.6 | 1.7 | 1.7 |
| 1024 | 2048 | 2047.93 | 2047.93 | 0.5 | 0.6 | 1.6 | 1.7 |
| 2048 | 2000 | 1999.90 | 1999.90 | 0.9 | 1 | 2.8 | 3.5 |
| 2048 | 2048 | 2047.86 | 2047.86 | 0.9 | 1 | 2.9 | 3.7 |
| 2048 | 4096 | 4095.73 | 4095.86 | 1.4 | 1.7 | 3.4 | 4.2 |
| 4096 | 2000 | 1999.73 | 1999.80 | 1.9 | 2.2 | 9.9 | 11.8 |
| 4096 | 4096 | 4095.59 | 4095.59 | 2.9 | 3.9 | 11.8 | 13 |
| 4096 | 8192 | 8191.18 | 8191.18 | 5.5 | 8.1 | 17.3 | 19.3 |
| 8192 | 2000 | 1999.57 | 1999.63 | 3.6 | 4.5 | 27.9 | 32.2 |
| 8192 | 8192 | 8190.09 | 8186.27 | 17.7 | 21 | 57.8 | 57.8 |
| 8192 | 16384 | 15549.02 | 14617.70 | 521.9 | 553.6 | 1920.5 | ≥2000 |

8192 / 16384 档 TCP 收尾约 1.611 秒，WS 约 3.625 秒；WS 计划延迟最大 3987.849 ms。虽然全部响应最终完成，不能视为满足 16384 QPS 的稳态延迟要求。4096 连接每秒一次响应与每秒两次响应也应分别定义延迟预算，在线连接数不等于吞吐量。

## 4096 三轮复测

每项以 R1 / R2 / R3 顺序列出。

| 传输 | 目标 QPS | RTT p99（ms） | 计划延迟 p99（ms） |
|---|---:|---|---|
| tcp | 2000 | 1.9 / 1.6 / 1.7 | 9.9 / 9.6 / 9.5 |
| tcp | 8192 | 5.5 / 5.4 / 5.5 | 17.3 / 16.7 / 16.8 |
| ws | 2000 | 2.2 / 1.8 / 2 | 11.8 / 10.7 / 11.4 |
| ws | 8192 | 8.1 / 7.7 / 7.3 | 19.3 / 17.3 / 17.2 |

## 内存与资源回收

主测试每档使用新进程。增量为完成握手后 RSS 减去该实例启动基线，再除以连接数；包括分摊的初始化开销，不能直接作为每连接固定成本。峰值覆盖该档正式负载。

| 传输 | 连接数 | 握手后 RSS（MiB） | 负载采样峰值（MiB） | 握手增量 / 连接（KiB） |
|---|---:|---:|---:|---:|
| tcp | 256 | 24.46 | 25.84 | 18.75 |
| tcp | 1024 | 28.67 | 33.17 | 8.719 |
| tcp | 2048 | 34.16 | 43.04 | 7.156 |
| tcp | 4096 | 45.50 | 62.33 | 6.422 |
| tcp | 8192 | 67.46 | 96.98 | 5.945 |
| ws | 256 | 25.80 | 27.43 | 23.25 |
| ws | 1024 | 32.39 | 38.90 | 12.688 |
| ws | 2048 | 41.64 | 53.52 | 10.859 |
| ws | 4096 | 57.61 | 86.61 | 9.461 |
| ws | 8192 | 95.26 | 146.06 | 9.43 |

所有正式关闭记录均为 clients=0、FD=8、dropped=0；连接期间 FD 为连接数+8。连接计数和 FD 回到基线，RSS 不保证立即回到启动值。

### 五分钟持续运行

每种传输成功响应 1,228,800 次，分为五个一分钟记录，全部零错误。

| 传输 | 每分钟末 RSS 范围（MiB） | RTT p99 范围（ms） | 计划延迟 p99 范围（ms） |
|---|---:|---:|---:|
| tcp | 48.09–48.54 | 1.80–1.90 | 2.80–3.00 |
| ws | 61.54–62.42 | 2.20–2.30 | 3.50–3.80 |

### 连接循环

| 传输 / 实例 | 三次关闭后的 RSS（MiB） | 三次 RTT p99（ms） | 三次计划延迟 p99（ms） |
|---|---|---|---|
| tcp / verified | 57.21 / 55.64 / 62.14 | 4.1 / 4.8 / 4.8 | 19.7 / 21.4 / 23.7 |
| tcp / 4096_r3 | 57.46 / 56.03 / 61.91 | 3.5 / 4.7 / 4.5 | 14.5 / 20.4 / 22.9 |
| ws / verified | 72.12 / 70.69 / 77.14 | 4 / 6.2 / 5.7 | 15.9 / 22.9 / 26.3 |
| ws / 4096_r3 | 72.08 / 71.56 / 78.00 | 4.1 / 5.9 / 5.7 | 16 / 25.5 / 25.2 |

### 测量结束后的强制 GC 诊断

| 实例 | Lua MEM 前→后（KiB） | RSS 前→后（MiB） |
|---|---|---|
| ws_ws_verified | 61400.5 → 5198.1 | 103.07 → 95.03 |
| tcp_tcp_4096_r2 | 21335.2 → 2509.8 | 48.77 → 48.05 |
| tcp_tcp_4096_r3 | 34318.9 → 4333.8 | 61.91 → 61.32 |
| ws_ws_4096_r2 | 31943.2 → 2638.1 | 63.00 → 60.90 |
| ws_ws_4096_r3 | 41150.4 → 4430.5 | 78.00 → 75.65 |

大部分 Lua 内存可被回收，但 RSS 仍有分配器保留，经历连接循环后的 Lua 残留也高于无循环实例。这些结果不足以证明长期无泄漏，应继续做数小时循环并观察 GC 后存活对象、内存趋势；不建议将周期性强制 GC 当作当前结论的生产修复。

## 验证与未覆盖项

六组正式运行均输出 complete：共 38 个正式负载段、10 个一分钟持续运行记录、12 个连接循环记录，响应校验零错误，正式 Service 日志错误扫描为零，测试启动的进程均清理完成。

接口对齐后的 Proxy 单元测试输出 PROXY_SEND_DATA_UNIT_OK，真实 Gateway TCP/WS smoke 通过。Proxy 回归已改用当前 send_data/close 合同；旧 gateway_dispatch 测试调用不代表当前接口。跨进程 Proxy/Cluster/Battle 集成尚未验证：已有进程占用 2528 端口，保留该进程。因此本报告不能推导真实 Battle、Cluster 转发或导航查询性能。

测量后整理了驱动函数和控制流，TCP、WS 各完成一次 32 连接 / 64 QPS 的交付检查，均 complete 且零错误；git diff --check 通过。整理后的版本没有重跑整套容量测试，正式测量源文件已单独保存，避免混淆版本。

本次未覆盖两小时长测、真实 Unity/IL2CPP 客户端、大包、慢接收端、连接风暴、公网，以及生产实际业务。五分钟稳定性不能替代长期稳定性。异常试跑未计入正式表格；修复测试工具后才重新生成有效样本。

## 复现与原始证据

在 WSL 仓库的 server 目录运行，使用未占用的 19131 端口；tag 使用新名字，避免覆盖原始证据。

```bash
cd /home/simbi/workspace/skynet-battle-navigation-commercial-learning/server
python3 tests/gateway_connection_benchmark.py --transport tcp --seconds 30 --soak 5 --churn 3 --gc-diagnostic --tag tcp_new
python3 tests/gateway_connection_benchmark.py --transport ws --seconds 30 --soak 5 --churn 3 --gc-diagnostic --tag ws_new
python3 tests/gateway_connection_benchmark.py --transport tcp --connections 4096 --rates 2000 8192 --seconds 30 --churn 3 --gc-diagnostic --tag tcp_repeat_new
python3 tests/gateway_connection_benchmark.py --transport ws --connections 4096 --rates 2000 8192 --seconds 30 --churn 3 --gc-diagnostic --tag ws_repeat_new
```

原始目录在 server/logs 下，受 Git ignore 管理，交付时应另行归档；本报告与测试源码可纳入版本管理，但本次没有提交。

- [tcp_tcp_verified.jsonl](../server/logs/gateway_benchmark/tcp_tcp_verified.jsonl)
- [ws_ws_verified.jsonl](../server/logs/gateway_benchmark/ws_ws_verified.jsonl)
- [tcp_tcp_4096_r2.jsonl](../server/logs/gateway_benchmark/tcp_tcp_4096_r2.jsonl)
- [tcp_tcp_4096_r3.jsonl](../server/logs/gateway_benchmark/tcp_tcp_4096_r3.jsonl)
- [ws_ws_4096_r2.jsonl](../server/logs/gateway_benchmark/ws_ws_4096_r2.jsonl)
- [ws_ws_4096_r3.jsonl](../server/logs/gateway_benchmark/ws_ws_4096_r3.jsonl)

- [原始 TCP 环境](../server/logs/gateway_benchmark/environment_verified.json)
- [WS 与复测环境 / 测量版本哈希](../server/logs/gateway_benchmark/environment_final.json)
- [交付版本环境与哈希](../server/logs/gateway_benchmark/environment_delivery.json)
- [正式测量驱动快照](../server/logs/gateway_benchmark/source_at_measurement/gateway_connection_benchmark.py)
- [Benchmark 驱动](../server/tests/gateway_connection_benchmark.py)
- [本地 Echo Service](../server/service/tests/gateway_benchmark.lua)
- [测试配置](../server/config/skynet_gateway_benchmark.lua)

建议下一步：明确生产每连接请求频率和尾延迟预算，在真实 Proxy/Battle 链路与独立压测客户端上复核 4096，再决定是否调整默认容量；8192 先保持专项验证档位。
