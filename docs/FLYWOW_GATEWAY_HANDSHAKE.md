# FlyWow Gateway 通用握手

## 范围与流程

Gateway和客户端SDK完成P-256密钥交换、32字节随机挑战、HKDF-SHA256和双向HMAC-SHA256证明，完成后进入ready。合法客户端指成功完成协议握手的客户端，不附带账号授权。无需登录、宿主会话表或Watchdog。业务Service继续使用D039异步收发。

不增加包头加密、CRC、逐包HMAC、账号或自动重连。Envelope和业务协议版本3不变；连接协议不兼容旧客户端，双端一起更新，不自动降级。

```text
接纳连接 -> CLIENT_HELLO -> SERVER_CHALLENGE -> CLIENT_PROOF -> SERVER_READY
                                                            |
                                                            v
                                                           ready
                                                            |
                       读业务帧 -> 解码 -> send handler
                       独立响应入口 -> 编码 -> 写客户端
```

Gateway拥有fd及连接；`flywow.gateway.handshake`拥有状态机、并发计数和期限；`flywow_gateway_crypto` Native userdata拥有敏感数据。握手模块不写Socket、不引用业务、不创建Service或协程。同步密码运算只在握手执行，不yield。

## 固定字节合同

| 类型 | 内容 | 长度 |
| --- | --- | ---: |
| 1 HELLO | 类型1B、握手版本1B、公钥65B | 67B |
| 2 CHALLENGE | 类型1B、握手版本1B、公钥65B、随机挑战32B | 99B |
| 3 CLIENT_PROOF | 类型1B、HMAC32B | 33B |
| 4 SERVER_READY | 类型1B、HMAC32B | 33B |

握手版本1；公钥为P-256非压缩`04 || X[32] || Y[32]`，X/Y大端。TCP继续使用uint16大端长度头；WS每条binary message是一条消息。transcript不含TCP长度头。握手类型不占业务command，不加入宿主.proto。

```text
Z = ECDH原始32字节结果
T = SHA256(HELLO完整消息 || CHALLENGE完整消息)
K = HKDF-SHA256(Z, salt=challenge[32], info=ASCII("flywow/handshake/v1") || T, length=32)
客户端证明 = HMAC-SHA256(K, ASCII("client-proof") || T)
服务端证明 = HMAC-SHA256(K, ASCII("server-ready") || T)
```

HKDF为Extract+Expand；不得把平台默认散列式ECDH结果当成Z。没有空字符、JSON、hex或base64转换。每次连接重新生成密钥。Gateway成功提交READY写入后才置ready；SDK验证服务端证明后才开放业务。握手共232字节，TCP包含长度头共240字节。

## 状态与资源

- Gateway：hello -> proof -> confirm -> ready；失败释放上下文。
- 未ready不投递或缓存业务包；出站业务入口也拒绝未ready连接。
- TCP先检查该阶段精确长度再读body；WS完整消息交给握手模块。
- 待握手计入max_clients；max_pending_handshakes默认min(128,max_clients)。
- handshake_timeout_ticks默认1000，即10秒，从连接登记开始，包含WS Upgrade；消息不刷新期限，复用扫描协程。
- 错误类型/版本/公钥/证明/顺序/写入失败关闭，不在同连接重试，不记录secret、证明或payload。
- 成功后释放临时私钥及派生密钥，只留ready标记；不需要登录会话或重连编号。
- Native擦除敏感数组；Unity托管私钥与Web Crypto内部内存由平台回收，不保证内部副本零残留。
- disconnect合同保持现状，包括握手失败连接；handler应允许从未收到请求的连接断开。

## 构建与接入

本次未授权commit/push。Server在WSL、框架在独立编辑源修改，固定submodule gitlink未更新；开发运行显式指定框架：

```bash
cd ~/workspace/skynet-battle-navigation-commercial-learning/server
./scripts/linux/run_server.sh prepare
./scripts/linux/run_server.sh doctor
```

需要OpenSSL 3的libcrypto开发文件、pkg-config、C++14编译器；发行版可能将开发文件统一放在OpenSSL开发包中。构建脚本查询pkg-config libcrypto，只链接密码算法库，不链接libssl、不启用SSL/TLS；运行部署需要匹配的libcrypto.so.3。框架使用pinned Skynet Lua头，输出server/luaclib/flywow_gateway_crypto.so；缺少绑定启动失败，不降级。当前验证OpenSSL 3.5.5；部署镜像固定实际包版本，现有Skynet/Lua/Unity不升级。

Unity在Windows构建SDK，课程只引用生成程序集，SDK源码只在框架维护：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File ./unity/BattleNavigation/build_gateway_sdk.ps1 -FrameworkRoot '\\wsl.localhost\Ubuntu\home\simbi\workspace\skynet-flywow'
```

Windows构建使用PowerShell 7与.NET SDK；上例仅为当前构建进程设置执行策略，便于从WSL UNC路径运行已审阅脚本。固定BouncyCastle.Cryptography 2.6.2，NuGet包SHA256由脚本校验。框架发布并更新Windows submodule后可省略FrameworkRoot。GatewayEnvelopeClient构造自动握手，业务不处理secret；仍是单调用线程同步短连接客户端。既有每次读取3秒期限，比框架总期限更严格。

H5使用框架clients/h5/handshake.mjs的connectGateway(url, { onmessage })；Promise完成后才send。需要Web Crypto安全上下文，例如HTTPS或localhost。example.mjs提供QueryCell示例；业务自己提供Protobuf生成物。

## 验收入口

```bash
# 在Server目录设置固定解释器与当前产物，再进入FlyWow目录。
export SKYNET_LUA="$PWD/third_party/skynet/3rd/lua/lua"
export SKYNET_LUACLIB="$PWD/luaclib"
cd "$PWD/third_party/skynet-flywow"
python3 -m unittest discover -s tests -p 'test_*.py'
python3 scripts/ci/check_repository.py
```

Server目录运行真实集成，验收依赖Python cryptography 46.0.5及Node 22：

```bash
python3 tests/gateway_async_integration.py --flywow-root "$PWD/third_party/skynet-flywow"
python3 tests/gateway_sdk_interop.py --flywow-root "$PWD/third_party/skynet-flywow"
```

Windows的Tools/GatewayHandshakeInterop.csproj编译真实客户端源码；.NET 10仅是验收宿主。SDK runner可通过--dotnet和--unity-runner接入该程序集。Node结果不代替浏览器验收，.NET结果不代替Unity发布验证。

## 阅读与审计

继续读Gateway的accept_client、run_tcp、dispatch_payload、deliver_response。process_handshake只是接入门槛；状态机和密码细节分别在handshake.lua和Native绑定中。业务主线继续异步投递和独立回包。

审计修正：Lua C ABI、Native失败导入释放、Lua分配longjmp的C++析构边界、Gateway窥视内部阶段、独立模块配置快照/具名参数、H5缺少Crypto时Socket创建顺序、示例假定Protobuf字段顺序。doctor使用固定Lua实际加载Native绑定。原有用户规范/格式修改保留。

已通过：Native/C#编译、16项框架测试、真实TCP/WS握手、旧证明拒绝、期限与容量释放、异步/主动关闭/本地/Cluster回归、Node SDK和真实C#客户端互通、H5 SDK失败与关闭竞态。真实浏览器已通过Web Crypto握手和QueryCell回包。团结引擎已导入程序集并重新编译客户端。

未验证：IL2CPP（本机没有构建支持）、移动平台发布、商业容量和长期soak。聚焦验收不能扩大成商业部署规模承诺。

## 浏览器与成本验收记录

浏览器复验夹具：

```bash
python3 tests/gateway_sdk_interop.py --flywow-root "$PWD/third_party/skynet-flywow" --serve-browser
# 打开 http://localhost:19023/example.html，看到H5_BROWSER_WEBCRYPTO_SKYNET_OK。
# Ctrl+C关闭夹具，finally回收本次启动的Skynet。
python3 tests/gateway_handshake_benchmark.py --flywow-root "$PWD/third_party/skynet-flywow"
```

2026-10-02本机WSL Ubuntu/OpenSSL 3.5.5/Python cryptography 46.0.5结果；每种transport 64次串行连接，时间包含Python客户端密钥计算、连接、握手、WS Upgrade和本机调度。

| transport | 中位数 | P95 | 最大值 | Server CPU增量 | RSS前/后 |
| --- | ---: | ---: | ---: | ---: | ---: |
| TCP | 0.636ms | 0.937ms | 4.421ms | 30ms | 20288/24192KiB |
| WS | 88.086ms | 95.978ms | 96.338ms | 250ms | 24192/24320KiB |

CPU由/proc以系统tick采样，精度有限；RSS包含Lua分配与平台初始化。WS结果包含transport延迟，不能直接当作密码计算耗时。本记录是有限串行样本，商业并发容量和长期soak仍未验证。
