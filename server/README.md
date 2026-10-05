# Battle Navigation Server

这里是课程的 WSL/Linux Server 工程。仓库根目录下的三个主要边界为：

```text
unity/BattleNavigation/   Unity Authoring 与后续客户端表现
server/                   C++、Lua、Skynet、协议与 Server 测试
shared/                   Unity、Server 与离线工具共同消费的版本化合同和发布资产
docs/                     课程正文、格式合同与架构说明
```

`third_party/`、`build/` 和 Native 二进制不提交。协议源、固定版本、Server descriptor 与已发布 BMAP 位于仓库根目录 `shared/`，必须作为同一个 Git 提交的一部分更新。Server 不读取 Unity 的实时 Bake 目录。

Server 内部目录按运行身份划分：

```text
service/   由 newservice/uniqueservice 启动的 Service 入口
lualib/    Service Lua State 内通过 require 加载的普通模块
protocol/  Server 侧协议生成/验证脚本；协议唯一源位于仓库 shared/protocol/
config/    Skynet 进程配置与只读业务配置
native/    C++ Runtime 与 Lua C Binding
run/       PID/控制锁等本机运行状态，不提交 Git
logs/      后台运行日志，不提交 Git
```

## 统一启动入口

平时不需要手工按顺序执行 bootstrap/build 脚本。`run_server.sh` 会检查固定版本项目依赖和仓库已发布生成物，并做增量 Native 构建：

```bash
cd server
./scripts/linux/run_server.sh start
./scripts/linux/run_server.sh status
./scripts/linux/run_server.sh stop
```

常用维护命令：

```bash
./scripts/linux/run_server.sh doctor
./scripts/linux/run_server.sh prepare
./scripts/linux/run_server.sh build
./scripts/linux/run_server.sh rebuild
./scripts/linux/run_server.sh start --rebuild
./scripts/linux/run_server.sh restart
./scripts/linux/run_server.sh foreground
./scripts/linux/stop_server.sh
```

约定：

- `start` 默认后台运行，PID 写入 `run/server.pid`，当前日志由 `logs/server.log` 软链接指向；
- `foreground` 适合 gdb/LuaPanda/直接观察日志；
- `prepare` 自动补齐仓库固定的 Skynet/protoc/lua-protobuf 依赖和本机构建产物；共享协议与地图缺失时明确失败，不能在部署端临时生成另一版本；
- `build` 与 `rebuild` 会执行项目 Lua 可变参数策略检查；项目自有稳定接口和业务调用必须使用具名参数；
- 系统级编译工具缺失时只给出明确安装命令，不在启动脚本里静默执行 `sudo apt`；
- `rebuild` 只清理 `server/build/*` 和 Skynet 编译产物，不删除 `shared/`、源码或 third_party 固定源码；
- `stop` 先验证 PID 的 `/proc/<pid>/exe` 确实指向本仓库 Skynet，再发送 SIGTERM；默认不会直接 `kill -9`；
- 只有显式执行 `stop --force`，且 SIGTERM 超时后，才允许 SIGKILL。

只运行 Lua 策略检查：

```bash
./scripts/linux/check_lua_varargs.sh
```

检查范围是 `service/`、`lualib/`、`protocol/`、`config/`、`tests/` 下的项目自有 `.lua`。它不扫描 `third_party/`；失败时会输出违规文件和行号。

当前课程固定 Skynet v1.8.0。该版本没有应用层 SIGTERM drain hook；第一课 Query/Gateway 没有持久化可变业务状态，因此 SIGTERM 用作当前阶段的安全进程停止手段。后续进入有持久化、在线 Battle 或跨服务事务的商业项目时，应在 Server 内增加 drain/shutdown 协议，再由进程管理器做最后兜底。

## Gateway framing

第一课 Navigation Gateway 通过 server/third_party/skynet-flywow Git submodule 提供：

```text
FlyWow Gateway Service
+ Skynet http.websocket（WebSocket transport）
+ 生成 registry、Envelope 和统一 handler dispatch
```

FlyWow TCP framing 固定为 uint16 Big Endian length + payload；因此单个 Envelope 最大 65535 bytes。

Unity 验证通过的 BMAP 与 manifest 发布到仓库根目录 `shared/navigation/battle_1001/`。Unity Bake 只改变当前工作区；提交、推送并由 Server 机器拉取相同提交后，Server 才会看到新版本。`BMapReader` 仍会在加载阶段校验格式和 CRC。

首次获取仓库或切换到新的主仓库提交后，先在仓库根目录执行 git submodule update --init --recursive；这样 server/third_party/skynet-flywow 会处于主仓库固定的 FlyWow 提交。FlyWow 开发也通过更新该 submodule 的固定提交完成。

## 第一课最终准备与调试

第一课最终验收不再手工串联构建命令。先拉取同时包含 `shared/navigation` 与 `shared/protocol` 的课程提交，停止当前 Server，再执行：

```bash
BUILD_TYPE=Debug ./scripts/lessons/prepare_lesson_01.sh
```

需要清理本机构建产物后完整验证时：

```bash
BUILD_TYPE=Debug ./scripts/lessons/prepare_lesson_01.sh --rebuild
```

LuaPanda 是 debug-only 工具链。安装/验证本地调试依赖：

```bash
./scripts/linux/bootstrap_luapanda.sh
```

VS Code 先启动 `server/debug/luapanda/launch.json.example` 中的 Gateway + Query 两个 target，然后：

```bash
./scripts/linux/debug_luapanda.sh
```

LuaPanda + gdb 同时跟踪：

```bash
./scripts/linux/debug_luapanda.sh --gdb
```

Gateway 使用 8818，Query 使用 8819。两个 Service 是两个独立 Lua State，因此必须是两个调试 target。正常 `run_server.sh start` 不设置 `LUA_PANDA_ENABLE`，不会加载 LuaPanda runtime。


完整断点顺序、故障排查和验收证据见第一课第 31 节。
## 第二课双进程运行入口

第二课保留 `run_server.sh` 的单进程入口作为本地调试路径，同时提供 Gateway 与 Map/Battle 分离的真实进程边界：

```text
Gateway Process : gateway/gateway_main -> gateway/gateway_proxy -> FlyWow Gateway :19011
Map/Battle     : battle/battle_main -> battle/navigation_query -> cluster :2528
Gateway cluster :2527
```

Gateway 只拥有客户端连接、framing 和 Protobuf 编解码；Map/Battle Process 只拥有地图查询和后续战斗 Service。两个进程通过 `skynet.cluster` 传递已解码 request/result record，`battle_dispatch` 是明确的跨启动树发现名。

```bash
cd ~/workspace/skynet-battle-navigation-commercial-learning/server
BUILD_TYPE=Debug ./scripts/linux/run_server.sh build
./scripts/lessons/run_lesson_02_processes.sh doctor
./scripts/lessons/run_lesson_02_processes.sh start
./scripts/lessons/run_lesson_02_processes.sh status
```

启动脚本先等待 Map/Battle Process 输出 `LESSON2_BATTLE_PROCESS_READY`，再启动 Gateway；Gateway 日志还应包含 `FLYWOW_GATEWAY_READY` 和 `LESSON2_GATEWAY_PROCESS_READY`。日志分别写入 `logs/lesson2/battle.log`、`logs/lesson2/gateway.log`。停止时使用：

```bash
./scripts/lessons/run_lesson_02_processes.sh stop
```

脚本的 `doctor` 只检查依赖、协议产物、registry 和 bootstrap 文件，不生成协议，也不修改 shared 发布资产。修改端口时同步更新 `config/gateway.lua`、`config/battle.lua` 和课程文档。


## 异步 Gateway 接入合同（D039）

FlyWow 读取完整帧并解码后，用本地 `skynet.send` 投递 `gateway_dispatch`，立即读下一帧。课程 Proxy 用 `cluster.send` 转发；Battle 处理后反向 send；Proxy 用薄的 `gateway.endpoint` 上下文发送 `gateway_response`。Gateway 依据响应携带的实例、连接、命令和请求编号编码并发送，不维护业务请求等待表。

Proxy 最多64条返回路由、保留10秒；没有 wait/wakeup/请求协程结果槽。超限、超时和远端错误映射成已有业务响应，健康连接继续读取。断线清理项目路由，迟到结果丢弃，不自动取消 Battle 操作。第一课直接 Query 接入使用相同 endpoint，Battle 内部的本地 Query call 合同继续保留。

当前 Unity GatewayEnvelopeClient 是单调用线程的短连接，一个请求对应一个响应，与异步 Server 兼容；它不是单连接多请求并发客户端。后续长连接客户端需要按 request_id 分发乱序响应，并接收编号0的已登记类型主动消息。

FlyWow 先提交并 Push，课程再固定已验证的 submodule 提交；正常运行无需覆盖。开发独立 FlyWow 工作区时显式指定框架：

```bash
使用固定子模块 server/third_party/skynet-flywow
./scripts/linux/run_server.sh build
./scripts/lessons/run_lesson_02_processes.sh doctor
python3 tests/gateway_async_integration.py
./third_party/skynet/3rd/lua/lua tests/gateway_proxy_test.lua "$PWD" "$PWD/third_party/skynet-flywow"
```

集成脚本使用专用19021/19022端口验证延迟/乱序、半包/WS fragment、推送、编码错误、业务失败、断线和网络限制；再使用19001、19011、2527、2528验证实际本地 Query 和双进程 Query/RunAutoBattle。已有进程占用端口时明确失败，不接管部署PID文件；finally只停止自己创建的进程。日志位于 `logs/gateway_async_tests/`。这不是商业容量或长时间 soak 验证。


业务主动关闭使用 endpoint context:close。独立业务进程通过项目注入的 close 函数 cluster.send gateway_close 到 Proxy，Proxy 发给 gateway_main 显式 bind_gateway 的本地 Gateway。关闭 record 包含原实例与连接编号，不依赖 token。Gateway 核对来源与身份、摘除并通知 Proxy，再关闭 Socket/WS；重复和迟到关闭不影响新连接。通知目前只到 Proxy，由它清理返回路由，不自动继续传给 Battle。

gateway_async_integration.py 还启动专用 gateway_close_battle_smoke 业务进程，覆盖真实跨 Cluster 主动关闭和关闭后新连接的正常往返，不需要在生产业务中增加测试 command 或客户端协议字段。
