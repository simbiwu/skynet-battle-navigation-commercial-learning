# Gateway / Server Launcher 更新说明

基线仓库：`simbiwu/skynet-battle-navigation-commercial-learning`

基线分支：`main`

生成时读取到的最新提交：

```text
2a2124a2fcf4c32b22831d52e430785da3a7d058
```

本更新只处理两件事：

1. 第一课 Navigation Gateway 从 `skynet.socket + socket.read()` 连接协程模型改成 `socketdriver + netpack + PTYPE_SOCKET` 事件驱动模型；
2. 把 `run_server.sh` 升级为统一的依赖准备、构建、后台启动、PID 管理、状态、重启和安全停止入口。

第二课以仓库当前版本为准，只同步受上述改动影响的网络/yield/运行配置说明；A*、NavigationContext、DynamicOccupancy、BattleWorker、AI、Replay 等核心内容不重写。

## 一、实际源码修改

### 1. `server/service/navigation_gateway.lua` — 完整替换

旧实现：

```text
skynet.socket
-> socket.listen/socket.start
-> 每连接 client_loop coroutine
-> socket.read
-> Lua string buffer
-> 自写 length_frame.unpack
```

新实现：

```text
skynet.socketdriver
+ skynet.netpack
+ skynet.PTYPE_SOCKET
-> init/open/data/more/close/error/warning
-> netpack.filter / netpack.pop
-> 完整 Envelope payload
-> skynet.call(Query Service)
-> netpack.pack + socketdriver.send
```

新增的工程保护：

- `max_clients`；
- 单连接 `max_inflight_per_connection`；
- `warning` 写缓冲阈值保护；
- malformed Envelope / version / command / body 关闭连接；
- `skynet.call` yield 后重新确认 `connections[fd] == conn`，避免 fd 关闭并复用后旧协程误写新连接；
- Query Service call 异常被 Gateway 收敛，不让一个坏请求直接打死整个 Gateway；
- `netpack.tostring` / `netpack.clear` 的 C message ownership 明确。

### 2. `server/config/game.lua` — 完整替换

新增：

```text
backlog = 128
tcp_nodelay = true
max_clients = 1024
max_inflight_per_connection = 32
write_warning_close_kb = 1024
```

framing 上限调整：

```text
旧：4-byte uint32 Big Endian，max 64 KiB
新：2-byte uint16 Big Endian（Skynet netpack 固定格式），max 65535 bytes
```

Protobuf Schema、Envelope、command、request_id、WorldPosition 没有改变。

### 3. `server/lualib/network/length_frame.lua` — 删除

原因：`netpack` 已经在 C 层完成半包/粘包和 framing queue。继续保留业务自写 framing 会产生两套协议实现。

因为 ZIP 覆盖本身不能删除旧文件，`APPLY_UPDATE.sh` 会自动删除它，不需要人工处理。

## 二、Server 启动/构建/停止修改

### 4. `server/scripts/linux/run_server.sh` — 完整替换

支持：

```bash
./scripts/linux/run_server.sh start
./scripts/linux/run_server.sh start --rebuild
./scripts/linux/run_server.sh foreground
./scripts/linux/run_server.sh stop
./scripts/linux/run_server.sh stop --force
./scripts/linux/run_server.sh restart
./scripts/linux/run_server.sh restart --rebuild
./scripts/linux/run_server.sh status
./scripts/linux/run_server.sh doctor
./scripts/linux/run_server.sh prepare
./scripts/linux/run_server.sh build
./scripts/linux/run_server.sh rebuild
```

主要行为：

- 从脚本自身路径解析 `server/`，不依赖当前 shell 工作目录；
- 使用 `flock` 避免 start/stop/rebuild 并发操作；
- 自动检查固定版本 Skynet/protoc/lua-protobuf 项目依赖；
- 缺失项目依赖时调用仓库现有 bootstrap 脚本补齐；
- 不静默 `sudo apt`，系统编译工具缺失时给出明确安装命令；
- 缺失时编译 Skynet、pb.so、descriptor、battle_nav.so；
- 普通 start 使用 CMake 增量构建；
- `rebuild` 清理 `server/build/grid_map` / `server/build/lua_battle_nav`，并对 Skynet 执行 `make clean` 后完整重编；
- rebuild 不删除 `maps/`、源码或 pinned third_party 源码；
- start 默认 `nohup` 后台运行；
- PID 写入 `server/run/server.pid`；
- 每次启动产生 `server/logs/server-YYYYmmdd-HHMMSS.log`；
- `server/logs/server.log` 指向当前日志；
- 启动后等待 `NAV_SERVER_READY`，超时会回收失败进程并打印最近日志；
- status 显示 PID、运行时长和命令行；
- stop 不相信 PID 文件本身，会校验 `/proc/<pid>/exe` 和 cmdline 确实属于本仓库 Skynet；
- 默认 stop 只发 `SIGTERM` 并等待；
- 只有显式 `stop --force` 且 TERM 超时后才发 SIGKILL。

### 5. `server/scripts/linux/stop_server.sh` — 新增

短入口：

```bash
./scripts/linux/stop_server.sh
```

内部复用 `run_server.sh stop`，不会出现两套停止逻辑。

### 6. `server/.gitignore` — 修改

新增：

```text
/run/
```

PID 和控制锁不提交 Git。

### 7. `server/README.md` — 完整替换

增加统一运行命令、后台日志/PID、build/rebuild/stop 规则和 netpack framing 说明。

## 三、第一课教程修改

文件：

```text
docs/Skynet_BattleNavigation第一课_从Unity地图到Skynet查询_实操.md
```

只改受本次需求影响的章节，其他 Unity/BMAP/GridMap/MapRegistry/Lua Binding 内容保持原样。

主要变化：

- 顶层执行链改为 `socketdriver + netpack + Protobuf`；
- 第 26 节更新 Gateway Service ownership 和目录身份；
- `config/game.lua` 教程代码与仓库源码同步；
- 第 27 节重写为 `PTYPE_SOCKET` 事件驱动 Gateway；
- 解释 `netpack.filter/pop/tostring/pack/clear` ownership；
- 解释 fd 复用与 yield 后 connection identity 二次确认；
- 解释为什么 framing 必须由 4-byte 改为 2-byte；
- 第 28 节使用新的商业化 `run_server.sh` / `stop_server.sh`；
- Unity `LengthFrame.cs` 教程改为 2-byte Big Endian；
- `ServerQueryClient.ReadFrame()` 改为读取 2-byte header；
- framing tests 改为 `65535 accepted / 65536 rejected`；
- Server negative cases增加 netpack 多包、拆包、in-flight、fd close/reuse；
- 联调命令改成 `start/status/tail/stop/foreground`；
- TCP 故障排查不再围绕 `socket.read`；
- 第一课验收清单同步到 socketdriver/netpack。

## 四、第二课同步修改

文件：

```text
docs/Skynet_BattleNavigation第二课_从Grid寻路到Skynet自动战斗_实操.md
```

只修改两处：

1. `BattleMgr -> BattleWorker` yield 边界说明中，明确第一课 Gateway 已是 `socketdriver + netpack` 事件模型；接入层 yield/并发不改变 `battle_core` no-yield。
2. 修正当前文档中“Git 仓库没有提交第一课实际 Skynet config”的过时描述。仓库现在已有 `server/config/skynet.lua`，第二课直接沿用现有 `luaservice/lua_path/cpath`。

明确未修改：

```text
AgentProfile
Path
NavigationContext
Grid A*
DynamicOccupancy
Path smoothing
Attack Position
BattleMgr / BattleWorker 架构
battle_core no-yield
Server AI
Replay
Determinism
第二课测试/benchmark 主体
```

## 五、工程合同同步

自动更新以下仓库文档：

```text
docs/ENGINEERING_DECISIONS.md
  D029: framing -> uint16 BE netpack，max=65535
  D031: Gateway 直接持有 socketdriver/netpack，不再有 length_frame.lua

docs/TEST_STRATEGY.md
  Gateway 测试增加 socket event、fd reuse、in-flight、65535 上限

codex/LESSON_01_SPEC.md
  Lesson 1 验收改为 socketdriver + PTYPE_SOCKET + netpack

codex/CODEX_START_HERE.md
  目录身份说明移除旧 lualib/network framing 工具
```

## 六、明确没有修改

本更新没有改：

```text
server/protocol/navigation_query.proto
server/lualib/protocol/navigation_codec.lua
server/lualib/navigation/query_logic.lua
server/service/navigation_query.lua
server/service/main.lua
server/config/skynet.lua
server/native/**
Unity 地图 Authoring/Exporter/BMAP 代码
第二课导航/战斗实现
Lesson 3 / Lesson 4
```

因此此次网络 framing 变化是 wire transport breaking change，但不是 Protobuf schema breaking change。

## 七、运行方式

把 ZIP **直接解压到仓库根目录并覆盖同名文件**，然后只需要执行一次：

```bash
./APPLY_UPDATE.sh
```

这个脚本负责：

- 精确更新第一/二课及工程合同的相关章节；
- 删除已经退休的 `server/lualib/network/length_frame.lua`；
- 修复脚本 executable bit；
- 执行 shell syntax guard；
- 检查 Gateway 已不再引用 `skynet.socket/socket.read/length_frame`；
- 执行 `git diff --check`。

然后：

```bash
cd server
./scripts/linux/run_server.sh doctor
./scripts/linux/run_server.sh start
./scripts/linux/run_server.sh status
```

停止：

```bash
./scripts/linux/stop_server.sh
```

## 八、需要人工确认的技术边界

### 1. 线协议发生了 framing breaking change

旧客户端：

```text
uint32 BE length + Envelope
```

新客户端：

```text
uint16 BE length + Envelope
```

两者不能混跑。所有真正连接该 Gateway 的客户端都必须同步到 netpack framing。

### 2. 当前 stop 是进程级安全停止，不是最终商业 drain

Skynet v1.8.0 本体没有业务 SIGTERM drain hook。当前第一课只有静态地图 Query，没有 DB 延迟写、在线 Battle、跨服事务，所以经过 PID 身份校验后 TERM 可以作为本阶段安全停止方式。

以后如果 Server 存在：

```text
玩家持久化
Battle 状态
订单/充值事务
跨服迁移
异步 DB 写回
```

应增加应用层：

```text
stop accepting
-> drain requests
-> flush/commit state
-> stop workers
-> process exit
```

再让 systemd/Kubernetes/进程管理器处理超时兜底。

### 3. `run_server.sh start` 是后台 daemon-style 启动，不是 crash supervisor

脚本负责启动、PID、日志和停止，但不会在进程 crash 后自动无限重启。真实生产部署建议把同一个 `foreground` 入口交给 systemd、容器编排或公司的进程监管系统；不要在业务 Shell 里再造一个无限 `while true restart`。
