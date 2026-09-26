## 31. 第一课最终回顾、调试与验收

到这里，第一课不再继续增加新概念。本节只做一件事：把前面已经完成的 Unity 地图生产、BMAP、C++ Native、Lua Binding、Skynet Service、`socketdriver + netpack` Gateway、Protobuf 和 Unity 查询重新串成一条能够亲手执行、逐层断点、故意破坏并最终验收的完整链路。

如果只做到“代码都在”“Server 能启动”，第一课还没有真正结束。最终要能证明以下四件事：

```text
1. Unity 导出的地图资产可重复生产，并且 Server 加载的是同一份 map/version。
2. 一个真实 QueryCell 请求可以从 Unity TCP 进入 Gateway，跨 Service 到 Query，再进入 C++ GridMap。
3. Gateway / Query / Native 三个边界都可以被调试器准确停住，并能说明 ownership、Lua State 和 yield 边界。
4. 正常输入和错误输入都得到可解释结果，Server 不靠“偶然跑通”通过验收。
```

本节最终执行链：

```text
Unity Battle_1001 Scene
        |
        | Bake / Sampling / Validation / Export
        v
battle_1001.bmap + manifest
        |
        | lesson1_prepare.sh
        v
Server maps/
        |
        +-> pinned Skynet / protoc / lua-protobuf
        +-> descriptor
        +-> grid_map tests
        +-> battle_nav.so
        +-> doctor
        |
        v
Skynet Process
  |
  +-> navigation_gateway Service
  |     socketdriver + PTYPE_SOCKET + netpack
  |     Envelope decode
  |     skynet.call(query_service)       <- yield boundary
  |
  +-> navigation_query Service
        query_logic.query                <- no-yield
        battle_nav.query_cell            <- Lua/C boundary
              |
              v
        MapRegistry -> GridMap
        WorldToGrid -> QueryWorld
              |
              v
        QueryCellResponse
              |
              v
        Gateway -> netpack.pack -> Unity
```

调试器分工：

```text
LuaPanda Gateway target   看 Gateway Lua State
LuaPanda Query target     看 Query Service Lua State
gdb                       看 battle_nav.so / GridMap C++
Unity Query Window        产生真实外部请求并观察最终响应
```

这里最重要的一条认识是：`skynet.call()` 不是普通 Lua 函数调用。Gateway 和 Query 是两个独立 Service，也就是两个独立 Lua State。LuaPanda 在 Gateway 里不能单步“穿过” `skynet.call()` 直接进入 Query；要分别调试两个 Lua State，再通过 `request_id`、fd、请求字段和日志把两边串起来。进入 `battle_nav.so` 后，LuaPanda 也不能继续跟 C++，此时切换到 gdb。

### 31.1 先回顾第一课到底完成了什么

第一课最终形成两条数据链，它们不能混成一套协议。

离线资产链：

```text
Unity Scene
-> NavMesh Authoring
-> Grid Sampling
-> BMAP Export
-> BMapReader
-> immutable GridMap
-> MapRegistry
```

运行时查询链：

```text
Unity WorldPosition
-> uint16 Big Endian netpack frame
-> Protobuf Envelope / QueryCellRequest
-> Navigation Gateway Service
-> Navigation Query Service
-> query_logic
-> battle_nav.so
-> GridMap::WorldToGrid / QueryWorld
-> QueryCellResponse
-> Unity
```

两条链的长期职责分别是：

```text
BMAP
  保存静态导航资产。
  有 map_id / map_version / header / payload / CRC。
  由 Unity 离线生成，Server 启动阶段加载。

Protobuf
  保存运行期消息。
  有 protocol_version / command / request_id / body。
  由网络收发，不替代地图资产。
```

第一课还形成了几个重要的 ownership 结论：

```text
GridMap
  加载后 immutable，可被多个 Service / OS Thread 并发读取。

MapRegistry
  管理已加载静态地图，不保存每次查询临时状态。

navigation_gateway
  拥有 listen/client fd、connections、netpack queue。

navigation_query
  拥有 Query Service 自己的 Lua State 和 query_logic。

query_logic
  只是 navigation_query Lua State 内的普通 require 模块，不是 Service。

battle_nav.so
  做 Lua table <-> Native 类型转换，不拥有业务生命周期。
```

如果现在还会把 `require()` 当成创建 Service，或者认为 `skynet.call()` 和普通 Lua 函数调用没有本质差异，应先回看第 26～27 节再继续验收。

---

### 31.2 用一个总脚本完成 Server 构建与资产导入

前面的章节为了教学，把依赖、descriptor、CMake、测试、BMAP 导入拆开执行。进入最终验收后，不应该再靠人工记住十几条命令的顺序。脚本还会先确认 Server 没有处于运行状态，避免一边运行旧的 `battle_nav.so`，一边覆盖新的构建产物造成验收混淆。

本仓库新增：

```text
server/scripts/linux/lesson1_prepare.sh
```

它是第一课的 orchestration 入口。它不会复制 `run_server.sh` 的底层构建逻辑，而是把已经存在的商业化脚本组合成一次可重复的最终准备流程：

```text
Unity Export
-> 检查 BMAP / manifest
-> 校验 manifest map_id / map_version / cell_size
-> 原子复制到 server/maps
-> run_server.sh build 或 rebuild
     -> pinned dependency bootstrap
     -> Skynet build
     -> lua-protobuf runtime
     -> descriptor build/check
     -> project Lua vararg policy check
     -> battle_nav.so
     -> Native tests
-> run_server.sh doctor
-> 输出 BMAP / manifest SHA256
-> LESSON1_SERVER_PREPARE_OK
```

#### 第一次运行：从 Unity 导入资产

先在 Unity 完成：

```text
Tools -> Battle Navigation -> Validate Current Battle Scene
Tools -> Battle Navigation -> Export BMAP
```

确认输出目录存在：

```text
BuildArtifacts/Navigation/
  battle_1001.bmap
  battle_1001.manifest.json
```

WSL：

```bash
cd "$(git rev-parse --show-toplevel)/server"

BUILD_TYPE=Debug \
./scripts/linux/lesson1_prepare.sh \
  --unity-output "$(git rev-parse --show-toplevel)/unity/BattleNavigation/BuildArtifacts/Navigation"
```

这里建议第一课最终验收使用 `BUILD_TYPE=Debug`。原因不是 Debug 构建更接近生产，而是后面的 gdb 需要完整符号。性能基线再单独使用 Release/RelWithDebInfo，不要拿 Debug 数据做性能结论。

预期末尾看到：

```text
...
DOCTOR_OK
[lesson1-prepare] BMAP_SHA256 <sha256>
[lesson1-prepare] MANIFEST_SHA256 <sha256>
[lesson1-prepare] LESSON1_SERVER_PREPARE_OK
```

脚本会先读取 manifest，要求当前课程资产满足：

```text
map_id       = 1001
map_version  = 1
cell_size_mm = 500
```

如果 Unity 误导出了别的地图版本，脚本会在覆盖 `server/maps` 前失败。

#### 后续重复验收：复用已经导入的地图

```bash
cd "$(git rev-parse --show-toplevel)/server"
BUILD_TYPE=Debug ./scripts/linux/lesson1_prepare.sh --reuse-map
```

#### 需要从零检查构建链

```bash
BUILD_TYPE=Debug \
./scripts/linux/lesson1_prepare.sh \
  --unity-output "$(git rev-parse --show-toplevel)/unity/BattleNavigation/BuildArtifacts/Navigation" \
  --rebuild
```

`--rebuild` 最终调用已有的：

```text
run_server.sh rebuild
```

它只清理项目自己的 build 产物和 Skynet 编译产物，不删除：

```text
maps/
源码
Unity 导出物
固定 third_party 源码
```

#### 为什么仍然保留底层小脚本

最终使用者平时执行：

```text
lesson1_prepare.sh
```

排错时仍然可以单独执行：

```text
bootstrap_skynet.sh
bootstrap_protocol_tools.sh
build_skynet.sh
build_lua_protobuf.sh
build_server_descriptor.sh
check_server_descriptor.sh
native/grid_map/make_test.sh
run_server.sh doctor
```

这和商业工程常见做法一致：

```text
顶层 orchestration
  负责正确顺序和日常入口

底层 script
  负责单一职责和局部故障定位
```

不要为了“一键运行”把所有 curl、make、cmake、测试、资产复制重新写进一个巨大的脚本，否则以后一个步骤变化会产生两套构建逻辑。

---

### 31.3 启动、状态、日志和安全停止验收

准备完成后，先不用调试器，跑一次纯运行验收。

```bash
cd "$(git rev-parse --show-toplevel)/server"
./scripts/linux/run_server.sh start
./scripts/linux/run_server.sh status
```

预期：

```text
[serverctl] START_OK pid=...
[serverctl] RUNNING pid=... log=server-....log
```

看当前日志：

```bash
tail -f logs/server.log
```

必须能看到：

```text
NAV_QUERY_READY ... map=1001 version=1
NAV_TCP_READY 127.0.0.1:19001 ... framing=netpack-u16be max_frame=65535
NAV_SERVER_READY query=:... gateway=:...
```

三个 READY 的意义不同：

```text
NAV_QUERY_READY
  BMAP 已通过 Native 加载，Query Service 已可处理业务查询。

NAV_TCP_READY
  Gateway listen socket 已完成 bind/start。

NAV_SERVER_READY
  main 已完成 Query/Gateway 接线，进程整体可以接受第一课请求。
```

如果只出现前两个而没有 `NAV_SERVER_READY`，不能把它当启动成功。

#### 用 Unity 发真实查询

打开：

```text
Tools -> Battle Navigation -> Server Query
```

输入：

```text
Host        127.0.0.1
Port        19001
Map Id      1001
Map Version 1
```

先查询一个已知 Ground 点，再查询：

```text
x_mm = 999999999
```

越界请求必须返回：

```text
OUT_OF_BOUNDS
```

不能：

```text
崩溃
卡死
被当成 walkable=false
修改 Server 地图状态
```

#### 安全停止

```bash
./scripts/linux/stop_server.sh
```

或：

```bash
./scripts/linux/run_server.sh stop
```

当前 `stop` 会：

```text
读取 run/server.pid
-> kill -0 检查存活
-> /proc/<pid>/exe 核对确实是当前仓库 Skynet
-> cmdline 核对 config/skynet.lua
-> SIGTERM
-> 等待退出
```

默认不会直接 `kill -9`。只有明确执行：

```bash
./scripts/linux/run_server.sh stop --force
```

并且 TERM 超时后才允许 SIGKILL。

第一课没有玩家持久化、DB 延迟写、在线 Battle 和跨服事务，因此这个进程级停止方式满足当前课程。以后进入真正在线商业 Server，要在应用层增加 drain/flush/shutdown 协议，不能把这一课的停止模型原样当成最终生产方案。

---

### 31.4 安装 LuaPanda 调试支持

#### 为什么 Skynet 不能只在 main.lua 接一次 LuaPanda

Skynet 中：

```text
navigation_gateway Service
  -> 自己的 Lua State

navigation_query Service
  -> 自己的 Lua State
```

`require("LuaPanda")` 只影响当前 Lua State。

如果只在 `main.lua` 启调试器：

```text
main Service 可以断
Gateway 断不到
Query 断不到
```

而 main 完成接线后本来就退出，因此这种接法没有实际价值。

本仓库这次增加一个 debug-only 模块：

```text
server/lualib/debug/luapanda_debug.lua
```

Gateway 和 Query 启动时都会调用：

```text
luapanda_debug.start("gateway")
luapanda_debug.start("query")
```

但只有设置：

```text
LUA_PANDA_ENABLE=1
```

才真正加载 LuaPanda 和 LuaSocket。普通：

```bash
./scripts/linux/run_server.sh start
```

不会启动调试器，也不要求机器存在 LuaPanda/LuaSocket debug 依赖。

#### 为什么还需要 LuaSocket

LuaPanda Debugger 需要一个 TCP 连接和 VS Code Adapter 通信。Skynet 自己的 `socketdriver` 是 Skynet runtime 网络层，并不是 LuaSocket 的 `socket.core` API。

调试依赖链是：

```text
LuaPanda.lua
-> require("socket.core")
-> LuaSocket
-> VS Code LuaPanda Adapter
```

因此不能拿业务 Gateway 的 `socketdriver` 假装成 LuaPanda 的 `socket.core`。

本仓库新增：

```text
server/scripts/linux/bootstrap_luapanda.sh
```

它固定：

```text
LuaPanda 3.3.1
commit e3ac3d3314f24cf939c36cac5b7dc1f2ed6ee129

LuaSocket 3.1.0
```

LuaSocket 会直接针对：

```text
third_party/skynet/3rd/lua
```

中的 Lua 5.4 Header 构建，安装到仓库本地：

```text
third_party/luasocket-runtime/
```

不会：

```text
sudo make install
覆盖系统 Lua
依赖 /usr/local 的另一个 Lua ABI
```

#### 执行安装

```bash
cd "$(git rev-parse --show-toplevel)/server"
./scripts/linux/bootstrap_luapanda.sh
```

预期：

```text
LUAPANDA_RUNTIME_OK
[luapanda-bootstrap] READY LuaPanda=3.3.1 LuaSocket=3.1.0
```

如果这里 `require("socket.core")` 失败，不要继续调试。先解决 LuaSocket ABI/路径问题。

---

### 31.5 配置 VS Code 的两个 LuaPanda Target

推荐从 WSL 仓库根目录打开 VS Code：

```bash
cd "$(git rev-parse --show-toplevel)"
code .
```

如果 VS Code 提示安装 WSL Remote/在 WSL 中重新打开，选择 WSL 工作区。这样 VS Code Adapter 与 Skynet 都在同一个 Linux/WSL 网络和路径环境中，路径映射最简单。

在 Extensions 中搜索：

```text
LuaPanda
```

安装后确认扩展名称为 LuaPanda。

仓库提供模板：

```text
server/debug/luapanda/launch.json.example
```

如果当前仓库还没有 `.vscode/launch.json`：

```bash
mkdir -p .vscode
cp server/debug/luapanda/launch.json.example .vscode/launch.json
```

如果已经有自己的 `launch.json`，不要整文件覆盖，只把模板里的两个 configuration 和 compound 合并进去。

模板里有两个目标：

```text
LuaPanda Lesson1 Gateway  -> port 8818
LuaPanda Lesson1 Query    -> port 8819
```

以及一个 compound：

```text
LuaPanda Lesson1 Gateway + Query
```

为什么必须两个 port：两个 Service 是两个 Lua State，各自有一套 LuaPanda debugger socket。让它们抢同一个 8818 会产生连接冲突。

模板显式使用：

```json
"useCHook": false
```

第一课 WSL/Linux + Lua 5.4 直接使用 Lua hook 即可。LuaPanda 的 C hook 是调试性能优化，不是功能正确性的前置条件；这里优先减少额外 C ABI 变量。

#### 第一次只验证连接

VS Code：

```text
Run and Debug
-> LuaPanda Lesson1 Gateway + Query
-> F5
```

先让两个 Adapter 进入等待状态，然后 WSL：

```bash
cd "$(git rev-parse --show-toplevel)/server"
./scripts/linux/debug_luapanda.sh
```

日志应出现：

```text
LUA_PANDA_CONNECT role=query ... port=8819
LUA_PANDA_READY role=query ... port=8819
LUA_PANDA_CONNECT role=gateway ... port=8818
LUA_PANDA_READY role=gateway ... port=8818
```

Service 创建顺序由调度决定，两个角色日志先后不需要写死；关键是两个都 READY。

如果断点不命中，可以先在 LuaPanda Debug Console 输入：

```text
LuaPanda.doctor()
```

重点检查：

```text
cwd
实际 source path
VS Code workspace root
文件大小写
connectionPort
```

---

### 31.6 用 LuaPanda 跟完整 Lua 核心流程

先设置下列断点。

#### Gateway target

文件：

```text
server/service/navigation_gateway.lua
```

建议断：

```text
SOCKET.open
  看 accepted fd / address / connections[fd]

dispatch_packet
  看 netpack 已经切好的 payload

codec.decode_envelope 之后
  看 protocol_version / command / request_id

skynet.call(query_service, "lua", "query_cell", request) 前
  看最终跨 Service 的 request table

skynet.call 返回后
  看 response，以及 connections[fd] 是否还是原 conn

send_response
  看 request_id 怎样原样带回
```

#### Query target

文件：

```text
server/service/navigation_query.lua
```

建议断在：

```lua
local response = query_logic.query(assert(payload, "query payload is required"))
```

继续进入：

```text
server/lualib/navigation/query_logic.lua
```

断在：

```text
M.query(request)

map/version 校验

pcall(battle_nav.query_cell, request.map_id, request.map_version, request.position)

Native 返回后的 value / err
```

#### 发一个真实请求

Unity Query Window 发：

```text
map=1001
version=1
position=(0,0,0) 或一个已验证 Golden Point
```

你应该先在 Gateway target 停住。

此时观察：

```text
fd
conn.address
conn.inflight
#payload
Envelope.protocol_version
Envelope.command
Envelope.request_id
request.map_id
request.map_version
request.position.x_mm/y_mm/z_mm
```

执行到：

```lua
skynet.call(query_service, "lua", "query_cell", request)
```

这里不要期待按一次 Step Into 就跳进 `navigation_query.lua`。

真实发生的是：

```text
Gateway coroutine
-> pack Skynet message
-> yield
-> Query Service mailbox
-> 某个 Skynet worker thread dispatch Query Lua State
```

所以应：

```text
Gateway target Continue
-> 切换到 Query target
-> 等 navigation_query 断点命中
```

这一步如果亲手做通，Skynet 的 Service/Lua State/yield 边界会比只看概念图直观得多。

Query 中继续进入 `query_logic.query()`，确认业务参数已经脱离 Protobuf 对象，只剩普通 Lua table：

```text
Gateway 接入层结束 Protobuf
-> Query Service 处理业务 table
```

执行到：

```lua
battle_nav.query_cell(request.map_id, request.map_version, request.position)
```

LuaPanda 到这里已经完成职责。下一层是 C++。

---

### 31.7 用 gdb 跟进 battle_nav.so 和 GridMap

先确保第一课是 Debug 构建：

```bash
BUILD_TYPE=Debug ./scripts/linux/lesson1_prepare.sh --reuse-map --rebuild
```

仓库提供：

```text
server/debug/gdb/lesson1.gdb
```

预置断点：

```text
l_query_cell
battle_nav::GridMap::WorldToGrid
battle_nav::GridMap::QueryWorld
```

由于 `battle_nav.so` 是运行时由 Lua `require` 加载，gdb 启动时符号可能还不存在，所以配置：

```text
set breakpoint pending on
```

#### 只做 C++ 调试

```bash
cd "$(git rev-parse --show-toplevel)/server"

gdb -x debug/gdb/lesson1.gdb \
  --args third_party/skynet/skynet config/skynet.lua
```

进入 gdb 后：

```gdb
run
```

然后用 Unity 发 Query。

#### LuaPanda + gdb 同时跟踪

这是第一课最完整的一次调试演练。

1. VS Code 先启动：

```text
LuaPanda Lesson1 Gateway + Query
```

2. WSL：

```bash
cd "$(git rev-parse --show-toplevel)/server"
./scripts/linux/debug_luapanda.sh --gdb
```

3. gdb：

```gdb
run
```

4. Unity 发真实 QueryCell。

调试链会依次表现为：

```text
LuaPanda Gateway
  dispatch_packet
  -> skynet.call

LuaPanda Query
  navigation_query dispatch
  -> query_logic.query
  -> battle_nav.query_cell

GDB
  l_query_cell
  -> GridMap::WorldToGrid
  -> GridMap::QueryWorld

LuaPanda Query
  Native 返回
  -> response table

LuaPanda Gateway
  skynet.call 返回
  -> send_response

Unity
  QueryCellResponse
```

#### GDB 里重点看什么

在 `l_query_cell`：

```gdb
bt
info threads
```

确认当前是从 Lua C Binding 进入。

进入 `GridMap::WorldToGrid` 后：

```gdb
p world.x_mm
p world.y_mm
p world.z_mm
p metadata_.origin_x_mm
p metadata_.origin_z_mm
p metadata_.cell_size_mm
```

确认世界毫米坐标怎样换成 Grid。

进入 `GridMap::QueryWorld`：

```gdb
bt
next
```

观察：

```text
WorldToGrid
-> Contains
-> IndexOf
-> cells_[index]
```

如果查询负坐标，这是验证 floor contract 的最好位置。

当 gdb 命中 C++ breakpoint 时，整个 Skynet 进程会被 ptrace 暂停，LuaPanda 界面可能暂时没有响应，这是正常现象。继续 gdb 后，Lua State 才会继续运行。

---

### 31.8 做一次完整的端到端断点演练

这次不要跳步骤。

#### Step 1：确认 Server 资产与构建

```bash
cd "$(git rev-parse --show-toplevel)/server"
BUILD_TYPE=Debug ./scripts/linux/lesson1_prepare.sh --reuse-map
```

必须：

```text
LESSON1_SERVER_PREPARE_OK
```

#### Step 2：启动 LuaPanda 两个 target

VS Code：

```text
LuaPanda Lesson1 Gateway + Query
```

#### Step 3：以 LuaPanda + gdb 模式启动 Server

```bash
./scripts/linux/debug_luapanda.sh --gdb
```

GDB：

```gdb
run
```

#### Step 4：查询 Ground Golden Point

Unity Query Window 发一个已在 Scene Overlay 验证的可走点。

依次记录：

```text
Gateway:
  fd
  request_id
  command

Query:
  map_id/version
  position mm

Native:
  GridPos
  NavCell.height_mm
  NavCell.area_type
  NavCell.clearance_cells

Response:
  result
  grid_x/grid_z
  height/area/clearance
```

#### Step 5：查询静态障碍

目标是 `CenterBlock` 等已验证阻挡位置。

关注：

```text
网络路径完全正常
Protobuf 完全正常
Native 查询也成功完成
最终业务语义是 not walkable / 对应 result
```

不要把“不可走”误判成网络异常。

#### Step 6：查询越界点

```text
x_mm = 999999999
```

在 GDB 的 `WorldToGrid` / `QueryWorld` 看越界怎样转为显式错误，再回到 Lua/Protobuf。

#### Step 7：让请求完整返回 Unity

最终必须看到 request_id 匹配当前请求。

这证明：

```text
同一个请求
真正经过网络
真正跨了两个 Skynet Service
真正进入 C++
真正使用 BMAP 生成的 immutable GridMap
真正返回 Unity
```

---

### 31.9 失败用例也要作为验收内容

最终验收不能只有 happy path。

#### 协议错误

至少保留以下测试：

```text
protocol_version 错误
unknown command
malformed Envelope
malformed QueryCellRequest
frame 拆成多个 TCP write
多个 frame 合成一次 write
65535 bytes 边界
超出 netpack uint16 上限的客户端拒绝
request_id 必须原样匹配
```

Gateway 的核心观察点：

```text
netpack 负责半包/粘包
业务层只拿完整 payload
协议异常关闭连接
不会把 malformed bytes 交给 Native
```

#### fd 关闭/复用

当前 Gateway 在 `skynet.call` 后重新检查：

```lua
connections[fd] == conn
```

原因是：

```text
request 已发给 Query
-> Gateway coroutine yield
-> client 断开
-> fd 未来可能被系统复用
-> Query 返回
```

如果只看数字 fd，不看 connection object identity，旧请求可能把响应写给新连接。

这不是“课程为了复杂而加的保护”，而是事件驱动接入层真实需要考虑的生命周期问题。

#### 负世界坐标

再次人工算一次：

```text
origin_x_mm=-5000
origin_z_mm=10000
cell_size_mm=500
world_x_mm=-4999
world_z_mm=10501

GridX = floor(1 / 500)   = 0
GridZ = floor(501 / 500) = 1
```

更关键的是跨 origin 左侧：

```text
world_x_mm=-5001
relative=-1
floor(-1/500)=-1
```

C++ 普通向零截断除法不能直接替代 floor division。

#### 高度和 clearance

再次确认：

```text
height_mm
  静态地图表面高度。

clearance_cells
  静态地图空间条件。
```

它们都不是第二课动态单位状态。

第一课验收结束时，共享 `GridMap` 仍然完全 immutable。

---

### 31.10 最终需要保存哪些调试证据

建议保存一份简单的 Lesson 1 验收记录，不需要写成正式测试报告，但至少有下面这些证据。

```text
1. Unity Validator
   BATTLE_MAP_AUTHORING_OK

2. Unity Export
   battle_1001.bmap
   battle_1001.manifest.json

3. lesson1_prepare.sh
   LESSON1_SERVER_PREPARE_OK
   BMAP SHA256

4. Native tests
   grid_map_test passed

5. Server startup
   NAV_QUERY_READY
   NAV_TCP_READY
   NAV_SERVER_READY

6. LuaPanda Gateway breakpoint
   fd / request_id / command / request

7. LuaPanda Query breakpoint
   request table / response table

8. gdb Native breakpoint
   WorldPosition -> GridPos -> NavCell

9. Unity response
   Ground / Blocked / Slope / OOB

10. Safe stop
    STOP_OK
```

这十份证据共同回答“系统是否真的跑通”。任何单独一项都不够。

---

### 31.11 第一课最终验收清单

#### Unity / 资产

```text
[ ] Battle_1001 Scene 可以打开。
[ ] NavMesh Authoring 可以重新 Bake。
[ ] Validator 能检查 single-layer 2.5D 约束。
[ ] Exporter 能生成 BMAP + manifest。
[ ] manifest map_id/version/cell_size 正确。
[ ] BMAP Header/Payload CRC 能被 Server 拒错。
```

#### Native

```text
[ ] BMapReader 显式读字段，不做 raw struct cast。
[ ] 长度、Magic、header_size、版本、CRC 都有校验。
[ ] WorldPosition -> GridPos 对负坐标使用 floor contract。
[ ] GridMap 加载后 immutable。
[ ] MapRegistry 可以按 map/version 获取地图。
[ ] 多 Service 并发读不依赖 global mutable scratch。
[ ] grid_map_test 通过。
```

#### Lua / Skynet

```text
[ ] service/ 与 lualib/ 的运行身份没有混用。
[ ] navigation_query 是独立 Service/Lua State。
[ ] navigation_gateway 是独立 Service/Lua State。
[ ] Gateway 使用 socketdriver + PTYPE_SOCKET + netpack。
[ ] 不再使用 skynet.socket + socket.read 循环。
[ ] netpack queue 的 message ownership 明确。
[ ] Gateway -> Query 使用显式 Service handle。
[ ] skynet.call 的 yield 边界能解释。
[ ] Query -> query_logic 是同 Lua State 普通函数调用。
[ ] Query 核心静态查询路径本身不 yield。
```

#### TCP / Protobuf

```text
[ ] framing 是 uint16 Big Endian + Envelope。
[ ] max payload 为 65535 bytes。
[ ] Envelope 有 protocol_version/command/request_id/body。
[ ] malformed frame/envelope/body 不进入 Native。
[ ] 半包/粘包由 netpack 正确处理。
[ ] fd close/reuse 不会发生旧响应误写新连接。
[ ] Unity 和 Server 使用同一份 .proto。
[ ] request_id 请求/响应一致。
```

#### 构建 / 运行

```text
[ ] lesson1_prepare.sh 能完成最终准备。
[ ] run_server.sh doctor 通过。
[ ] start/status/log/stop 正常。
[ ] PID identity 校验不会误杀其他进程。
[ ] rebuild 不会删除地图和源码。
```

#### 调试

```text
[ ] bootstrap_luapanda.sh 能验证 LuaSocket + LuaPanda runtime。
[ ] VS Code Gateway target 能命中断点。
[ ] VS Code Query target 能命中断点。
[ ] 能解释为什么 skynet.call 不能在一个 LuaPanda target 中直接 Step Into 另一个 Service。
[ ] gdb 能命中 l_query_cell。
[ ] gdb 能命中 GridMap::WorldToGrid / QueryWorld。
[ ] 能完成 Gateway -> Query -> C++ -> Response 的一次完整跟踪。
```

#### 课程边界

```text
[ ] 第一课没有 A*。
[ ] 没有 AgentProfile。
[ ] 没有 NavigationContext。
[ ] 没有 DynamicOccupancy。
[ ] 没有 BattleWorker。
[ ] 没有 INavigationBackend。
```

如果最后六项已经提前出现在第一课核心实现里，说明课程边界又被打乱了。

---

### 31.12 常见最终验收故障

#### LuaPanda Gateway 能连，Query 连不上

先看：

```bash
ss -lntp | grep -E '8818|8819'
```

再看 Server 日志有没有：

```text
LUA_PANDA_CONNECT role=query
```

确认 VS Code compound 的 Query port 是 `8819`，不要两个 target 都写 8818。

#### LuaPanda 已连接但断点不命中

在 Debug Console：

```text
LuaPanda.doctor()
```

优先检查：

```text
VS Code 是否打开仓库根目录
cwd 是否是 ${workspaceFolder}/server
autoPathMode 是否 true
文件路径大小写是否一致
```

不要先怀疑 Skynet 调度器。

#### `require("socket.core")` 失败

重新执行：

```bash
./scripts/linux/bootstrap_luapanda.sh
```

确认输出 `LUAPANDA_RUNTIME_OK`。

不要通过安装系统 `lua-socket` 随机解决，因为系统包可能针对另一套 Lua ABI。

#### GDB 说找不到 l_query_cell

先确认 Debug 构建：

```bash
file build/lua_battle_nav/battle_nav.so
```

GDB 中：

```gdb
set breakpoint pending on
break l_query_cell
run
```

`battle_nav.so` 是之后由 Lua `require` 动态加载的，启动前 unresolved 是正常现象。

#### Server 已启动但 Unity 连接失败

```bash
./scripts/linux/run_server.sh status
ss -lntp | grep 19001
tail -n 100 logs/server.log
```

必须先确认 `NAV_TCP_READY`，再排 Unity。

#### 所有坐标都 OOB

按顺序对照：

```text
Unity manifest origin_mm
BMAP header origin
Server map_id/version
Query Window 单位是否为 mm
GridMap::WorldToGrid 中 world/origin/cell_size
```

不要用“给 origin 加一格”修现象。

---

### 31.13 性能基线和课后练习

第一课的性能练习仍然保留，但必须在功能验收之后做。

#### Native Query 基线

使用 Release/RelWithDebInfo：

```text
固定机器
固定地图
固定查询集合
10000 次 GridMap::QueryWorld
记录 total / avg / p50 / p95 / p99
```

#### TCP Query 基线

再做：

```text
1000 次 TCP QueryCell
```

Native 与 TCP 结果不能混成一个“寻路性能”数字。

它们测的是：

```text
Native
  坐标换算 + Grid 查询

TCP
  socket + netpack + Protobuf + Service call + Native + response
```

课后可以做：

```text
1. Unity Query Window 一次查询九宫格并可视化。
2. 修改 BMAP payload 一个 byte，验证 CRC 拒绝。
3. Envelope 增加未知字段，验证 protobuf forward compatibility。
4. 人工制造 protocol version mismatch / unknown command。
5. 并发多个短连接，观察 Gateway connection/inflight 行为。
```

---

### 31.14 第一课面试复盘

最终不要背文件名，按“问题 -> 约束 -> 设计 -> 执行链 -> 证据 -> 限制”讲。

五分钟版本：

```text
问题：
Unity 3D Scene 不能直接成为 Skynet Server 的权威导航数据。

约束：
Server 权威；单层 2.5D；地图资产版本化；多 Service 可并发读；
运行消息需要稳定协议；Gateway 和 Native 都必须可观测和可失败。

设计：
Unity NavMesh 只做 Authoring；采样输出 BMAP；
Server 用 BMapReader 加载为 immutable GridMap；
MapRegistry 管理静态地图；Lua Binding 保持薄；
运行时用 Protobuf Envelope；Gateway 使用 socketdriver + netpack；
Query Service 和 Gateway 各有独立 Lua State。

执行链：
Scene -> BMAP -> GridMap -> Lua Binding -> Query Service
-> Gateway -> Unity。
真实网络方向则是 Unity -> Gateway -> Query -> Native -> Unity。

证据：
Validator、CRC corruption、Native tests、READY 日志、
LuaPanda 两个 Service 断点、gdb Native 断点、真实 Unity Query。

限制：
当前只有 single-layer 2.5D 静态查询；没有寻路、动态单位和 Battle。
```

面试官继续追问时，要能回答：

```text
为什么 BMAP 不直接用 Protobuf？
为什么 GridMap immutable？
为什么 MapRegistry 不代理每次高频查询？
为什么 Gateway 和 Query 分两个 Service？
为什么 skynet.call 会 yield？
为什么一个 LuaPanda 连接不能直接调两个 Service Lua State？
为什么 netpack framing 是 uint16 Big Endian？
fd 复用为什么需要 connection identity？
为什么 Native Binding 不保存业务状态？
负世界坐标怎样映射 Grid？
当前架构为什么还不需要 NavigationContext？
```

回答质量自检：

```text
能不能说出真实代码路径？
能不能说出谁拥有状态？
能不能说出哪里会 yield？
能不能说出失败后怎样返回？
能不能指出对应测试/断点/日志证据？
能不能说出方案当前不支持什么？
```

只说“我们用了 Skynet/Protobuf/CRC/immutable”不够。主程面试关注的是为什么、边界和证据。

---

### 31.15 第一课结束，进入第二课

第一课最后停在：

```text
给一个 WorldPosition
-> Server 能权威回答这个 Cell 的静态导航属性
```

此时仍然没有：

```text
A 到 B 的路径
不同体型单位的通行约束
动态单位占位
战斗内查询 scratch
Server AI
自动战斗
Replay
```

第二课的新需求才是：

> 一个单位位于世界位置 A，需要在一场独立 Battle 中绕过地图和其他单位移动到世界位置 B。

从这个需求开始，才依次引入：

```text
AgentProfile
Path
NavigationContext
Grid A*
DynamicOccupancy
BattleWorker
Server AI
Unity Replay
```

当本节的最终 checklist、LuaPanda/GDB 跟踪和端到端 Query 都完成后，第一课才算真正验收通过。
