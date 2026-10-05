# PART 4：Server 启动与服务装配

本节从真实命令开始，沿当前 WSL 源码一直读到 Battle 和 Gateway 可以接收请求为止。每段都说明调用者、被调用者、参数、返回值、等待点、ownership、日志和失败传播。

~~~
./scripts/linux/run_server.sh start
    ↓
run_lesson_02_processes.sh
    ↓
Battle OS Process
    ↓ start = battle/battle_main
    ↓ Query → Manager/Worker → Dispatch
    ↓ Cluster 注册 battle_dispatch
    ↓
Gateway OS Process
    ↓ Proxy 连接 Battle
    ↓ FlyWow Gateway 绑定 19011
~~~

本节只讲启动和服务装配。BMAP 字节如何由 Native 解码放到 PART 5，Lua C API 栈放到 PART 6；但本节会把它们的入口和生命周期接好。

## 1. 先建立 Skynet 的运行模型

当前有两个独立 OS Process：

~~~
server/config/battle_process.lua   → Battle Process
server/config/gateway_process.lua  → Gateway Process
~~~

一个 OS Process 内可以有多个 Skynet Service：

~~~
Battle Process
├── battle_main
├── navigation_query
├── battle_mgr
├── battle_worker × N
└── battle_dispatch

Gateway Process
├── gateway_main
├── gateway_proxy
└── flywow_gateway
~~~

这几个概念要分开：

| 概念 | 当前例子 | 作用 |
|---|---|---|
| OS Process | Battle、Gateway | PID、端口、Lua State 集合和进程生命周期 |
| Service | navigation_query、battle_mgr | 消息队列、Service 状态、独立 Lua State |
| 普通 Lua 模块 | query_logic、battle_core | 被当前 Service require，没有独立消息队列 |
| Service handle | query_service、mgr | 给消息系统使用的 Service 地址 |

调用 require 不会创建 Service；调用 newservice 才会创建新的 Service。一个 Service 也不是一个新的 Linux 进程。

例如：

~~~lua
local query_service = skynet.newservice("battle/navigation_query")
~~~

query_service 是一个数值地址，不是 Query 的 Lua table、地图对象或 Native 指针。battle_main 只能通过这个地址发消息，不能直接调用 Query 的局部函数。

## 2. 从启动脚本进入 Skynet

### 2.1 run_server.sh 的职责

入口文件：

~~~
server/scripts/linux/run_server.sh
~~~

它负责确定 SERVER_ROOT，准备 Skynet、Native、协议产物和 BMAP，然后进入：

~~~bash
cd "$SERVER_ROOT"
~~~

所以这些相对路径都以 server 为基准：

~~~
../shared/navigation/battle_1001/battle_1001.bmap
./build/lua_battle_nav/?.so
./service/?.lua
~~~

不是以脚本所在目录、Unity 工程目录或 Windows 当前目录为基准。

prepare_runtime 最后输出 PREPARE_OK，表示文件和构建产物已准备，不表示 Query 已经执行 load_map，也不表示端口已监听。

### 2.2 run_lesson_02_processes.sh 的实际启动顺序

入口文件：

~~~
server/scripts/lessons/run_lesson_02_processes.sh
~~~

start_all 的顺序是：

~~~bash
start_one battle battle_process.lua ...
wait_ready battle ... LESSON2_BATTLE_PROCESS_READY
start_one gateway gateway_process.lua ...
wait_ready gateway ... LESSON2_GATEWAY_PROCESS_READY
~~~

start_one 的核心实现：

~~~bash
(
    cd "$SERVER_ROOT"
    exec "$SKYNET_BIN" "$SERVER_ROOT/config/$config"
) >"$log_file" 2>&1 &
pid="$!"
printf '%s\n' "$pid" > "$pid_file"
~~~

逐步理解：

~~~text
( ... )              在子 Shell 中执行
cd                    统一相对路径基准
exec skynet config   用 Skynet 替换子 Shell 进程
> log 2>&1            收集标准输出和错误输出
&                     后台运行，让控制脚本继续等待
$!                    保存后台进程 PID
PID 文件             供 status、stop、wait_ready 使用
~~~

wait_ready 同时检查 PID、进程命令行、进程存活和 READY 日志。因此：

~~~text
进程存在 ≠ Service 就绪
端口打开 ≠ Battle 依赖完整
READY 出现 = READY 之前的代码已经执行成功
~~~

## 3. Skynet 怎样找到入口 Lua

文件：

~~~
server/config/battle_process.lua
~~~

关键配置：

~~~lua
thread = 4
harbor = 0
start = "battle/battle_main"
bootstrap = "snlua bootstrap"
luaservice = "./service/?.lua;..."
lua_path = "./lualib/?.lua;..."
lua_cpath = "./build/lua_battle_nav/?.so;..."
~~~

启动过程：

~~~text
Skynet 可执行文件读取 battle_process.lua
    ↓
读取 start = battle/battle_main
    ↓
通过 luaservice 找到 service/battle/battle_main.lua
    ↓
Bootstrap 创建入口 Service
    ↓
battle_main 调用 skynet.start 注册启动回调
~~~

三种路径不要混淆：

~~~text
luaservice：newservice 要启动的 Service Lua 文件
lua_path：require 加载的普通 Lua 模块
lua_cpath：require 加载的动态库，例如 battle_nav.so
~~~

如果 luaservice 错，newservice 找不到目标 Service；如果 lua_path 错，query_logic 等普通模块加载失败；如果 lua_cpath 错，require battle_nav 失败。它们不是同一类问题。

## 4. skynet.start：当前 Service 的启动回调

进入：

~~~
server/service/battle/battle_main.lua
~~~

真实外层：

~~~lua
skynet.start(function()
    local query_service = skynet.newservice("battle/navigation_query")
    ...
end)
~~~

它表示：

~~~text
Skynet 创建入口 Service
    ↓
加载 battle_main.lua
    ↓
注册 skynet.start 回调
    ↓
Skynet 执行回调
    ↓
回调内部开始装配 Query、Manager、Dispatch
~~~

这个回调仍属于 battle_main Service，不会新建 OS Process。

装配结束后：

~~~lua
skynet.exit()
~~~

退出的是 battle_main 入口 Service。已经创建的 Query、Manager、Worker、Dispatch 和 Cluster 监听继续存在；它不是关闭整个 Battle OS Process。

## 5. newservice 和 handle

### 5.1 创建 Query

~~~lua
local query_service = skynet.newservice("battle/navigation_query")
~~~

执行前：

~~~text
Battle Process
└── battle_main
~~~

执行后：

~~~text
Battle Process
├── battle_main
└── navigation_query
~~~

调用结果是：

~~~text
query_service = Query Service 的数值 handle
~~~

这个 handle 只能用于投递消息。调用者不获得 Query 的 Lua State，也不获得 Query 内部的 config 或地图对象。

### 5.2 newservice 与 uniqueservice

Skynet 常见创建方式：

~~~text
newservice      每调用一次创建一个实例
uniqueservice   按名字保证某类 Service 只有一个实例
~~~

当前 Query、Manager、Worker、Dispatch 都由 battle_main 显式 newservice 创建，并由创建者保存 handle。当前代码没有用 uniqueservice 隐藏 Battle 依赖，这让 ownership 和启动顺序都能在 battle_main 中看到。

## 6. dispatch：Service 如何接收消息

Query 文件：

~~~
server/service/battle/navigation_query.lua
~~~

真实消息处理器：

~~~lua
skynet.dispatch("lua", function(_session, _source, command, payload)
    if command == "ready" then
        skynet.retpack(true)
        return
    end

    assert(command == "query_cell",
        "navigation_query only accepts query_cell")
    assert(type(payload) == "table",
        "query payload is required")

    local response = query_logic.query(
        assert(payload.request, "query request is required")
    )
    skynet.retpack(response)
end)
~~~

lua 是协议类型，不是业务命令。回调参数：

| 参数 | 含义 |
|---|---|
| _session | 本次请求的响应关联编号 |
| _source | 发送方 Service handle |
| command | 业务命令，如 ready、query_cell |
| payload | 调用方传来的 Lua 数据 |

当 battle_main 执行：

~~~lua
skynet.call(query_service, "lua", "ready")
~~~

Query 收到的核心内容是：

~~~text
协议类型 = lua
command  = ready
payload  = nil
source   = battle_main 的 handle
session  = Skynet 分配的请求编号
~~~

## 7. skynet.call 的完整往返

### 7.1 真实调用

~~~lua
assert(skynet.call(query_service, "lua", "ready"))
~~~

这不是一个普通函数调用，而是：

~~~text
battle_main 协程执行 call
    ↓
Skynet 建立 session
    ↓
消息进入 Query 的消息队列
    ↓
battle_main 当前协程 yield
    ↓
Query dispatch 取出消息
    ↓
Query 处理 command = ready
    ↓
Query retpack(true)
    ↓
Skynet 按 session 找回等待者
    ↓
battle_main 从 call 继续
    ↓
assert(true)
~~~

这就是为什么 battle_main 会等 Query，而不是创建完 Query 就立即继续创建 Manager。

### 7.2 retpack 与 return 的区别

Query 使用：

~~~lua
skynet.retpack(true)
return
~~~

return 只结束当前 dispatch 回调；retpack 才把 true 放入当前消息的响应，并关联原来的 session。

所以：

~~~text
call 需要响应
dispatch 处理请求
retpack 产生响应
session 把响应交给正确的等待协程
~~~

只写 return true，不能替代 Skynet 的消息响应合同。

### 7.3 call 与 send

Manager 获取 Worker 结果：

~~~lua
return skynet.call(worker, "lua", "simulate", snapshot)
~~~

必须等待，所以用 call。

Proxy 回推 Gateway：

~~~lua
skynet.send(state.gateway_service, "lua", "send_data", data)
~~~

只投递，不等待业务确认，所以用 send。

| API | 调用方是否等待 | 是否需要 retpack | 当前用途 |
|---|---|---|---|
| skynet.call | 是，会 yield | 是 | ready、configure、simulate、query |
| skynet.send | 否 | 否 | 异步 send_data、close |

send 成功只说明消息已投递到目标 Service，不代表客户端已收到数据。

## 8. Query READY 的真实先决条件

### 8.1 Query 启动顺序

Query 的启动回调：

~~~lua
skynet.start(function()
    luapanda_debug.start(8819)
    query_logic.start(config)

    skynet.dispatch("lua", function(...)
        ...
    end)

    skynet.error("NAV_QUERY_READY", ...)
end)
~~~

顺序不可随便交换：

~~~text
启动调试支持
    ↓
query_logic.start
    ↓
安装 dispatch
    ↓
写 NAV_QUERY_READY
~~~

### 8.2 地图加载实现

文件：

~~~
server/lualib/battle/navigation/query_logic.lua
~~~

真实实现：

~~~lua
function M.start(options)
    assert(config == nil,
        "navigation query logic already started")
    config = assert(options)

    local loaded, err = battle_nav.load_map(config.map.bmap)
    assert(loaded,
        err and (err.code .. ": " .. err.message)
        or "load_map failed")

    assert(loaded.map_id == config.map.id,
        "BMAP map_id does not match config")
    assert(loaded.map_version == config.map.version,
        "BMAP map_version does not match config")
end
~~~

调用链：

~~~text
navigation_query.lua
    ↓ query_logic.start(config)
query_logic.lua
    ↓ battle_nav.load_map(path)
Lua Native Binding
    ↓ BMapReader / MapRegistry
返回 loaded 或 err
    ↓ map_id / map_version 校验
安装 dispatch
    ↓
Query READY
~~~

PART 5 会详细阅读 Native Binding 和 Reader。本节要记住：Query 的 ready 不是空心跳，它建立在 BMAP 读取、格式校验和地图身份校验成功之上。

### 8.3 两个 READY

~~~text
NAV_QUERY_READY
    Query 自己打印的观察日志

skynet.call(query_service, "lua", "ready") == true
    battle_main 获得的正式同步返回值
~~~

如果 load_map 抛错，Query 不会正常进入 ready 消息处理，battle_main 也无法通过 assert。

## 9. Manager 和 Worker 的装配

### 9.1 battle_main 创建 Manager

~~~lua
local mgr = skynet.newservice("battle/battle_mgr")
assert(skynet.call(mgr, "lua", "ready"))
~~~

这和 Query 使用同一个模式：

~~~text
newservice → 得到 handle
call ready → 等内部初始化完成
assert → 失败则停止装配
~~~

### 9.2 Manager 创建 Worker

文件：

~~~
server/service/battle/battle_mgr.lua
~~~

关键实现：

~~~lua
local workers = {}
local next_worker = 1

skynet.start(function()
    luapanda_debug.start(8822)
    local count = tonumber(
        skynet.getenv("battle_worker_count")
    ) or 2
    assert(count >= 1)

    for _ = 1, count do
        workers[#workers + 1] =
            skynet.newservice("battle/battle_worker")
        skynet.call(
            workers[#workers],
            "lua",
            "debug_start",
            8822 + #workers
        )
    end

    skynet.dispatch("lua", function(_, _, command, payload)
        if command == "ready" then
            skynet.retpack(#workers > 0)
            return
        end
        if command == "simulate" then
            skynet.retpack(simulate(assert(payload)))
            return
        end
        error("unknown battle manager command: "
            .. tostring(command))
    end)
end)
~~~

Manager 的 ready 只表示 workers 数组至少有一个 Worker：

~~~text
Manager Service 已创建
    ↓ newservice Worker
    ↓ call Worker debug_start
    ↓ workers 数组非空
    ↓ dispatch ready
    ↓ ready 返回 true
~~~

它不表示某一场战斗已经创建，也不表示 battle_core 已经开始运行。

### 9.3 Worker 选择和返回

~~~lua
local function choose_worker()
    local worker = workers[next_worker]
    next_worker = next_worker % #workers + 1
    return worker
end

local function simulate(snapshot)
    local worker = choose_worker()
    return skynet.call(worker, "lua", "simulate", snapshot)
end
~~~

ownership：

~~~text
Manager 拥有 workers 数组和 next_worker
Worker 拥有自身 Service 状态
Worker 为一次模拟创建和关闭 NavigationContext
Dispatch 不直接持有 Worker 内部状态
~~~

## 10. Dispatch 的依赖注入

### 10.1 初始状态

文件：

~~~
server/service/battle/battle_dispatch.lua
~~~

初始状态：

~~~lua
local query_service = nil
local battle_mgr = nil
~~~

Dispatch 最后创建，是因为它是业务入口，必须等它依赖的 Query 和 Manager 先准备好。

### 10.2 configure 传的是什么

发送方：

~~~lua
assert(skynet.call(dispatcher, "lua", "configure", {
    query_service = query_service,
    battle_mgr = mgr,
}))
~~~

接收方：

~~~lua
local function configure(handles)
    assert(query_service == nil and battle_mgr == nil,
        "battle_dispatch already configured")
    assert(type(handles) == "table" and
        type(handles.query_service) == "number" and
        type(handles.battle_mgr) == "number",
        "invalid battle_dispatch handles")
    query_service = handles.query_service
    battle_mgr = handles.battle_mgr
    return true
end
~~~

传递的是两个 Service handle，不是：

~~~text
Query Lua table
Manager Lua table
地图指针
NavigationContext
Worker 数组副本
~~~

这就是依赖注入：battle_main 创建依赖，Dispatch 保存地址，之后通过消息使用依赖。

### 10.3 configure 之后才能 ready

~~~lua
if command == "configure" then
    skynet.retpack(configure(payload))
elseif command == "ready" then
    skynet.retpack(
        query_service ~= nil and battle_mgr ~= nil
    )
end
~~~

顺序是：

~~~text
创建 Dispatch
    ↓
configure 保存两个 handle
    ↓
ready 检查两个 handle
    ↓
Battle 才能注册远程入口
~~~

如果先 ready 后 configure，可能出现内部依赖为空但对外已宣布可用的状态。

## 11. Cluster：从本地 handle 到远程服务名

前面的 skynet.call 都是同一 OS Process 内的 Service 通信。现在进入跨进程 Cluster。

Battle 配置：

~~~lua
local_listen = 2528
service_name = "battle_dispatch"
gateway_node = "gateway"
gateway_address = "127.0.0.1:2527"
~~~

Battle 注册：

~~~lua
cluster.reload({
    [process.cluster.gateway_node] =
        process.cluster.gateway_address,
})
cluster.open(
    process.cluster.local_listen,
    process.cluster.max_clients
)
cluster.register(
    process.cluster.service_name,
    dispatcher
)
~~~

### 11.1 三个 Cluster 操作

~~~text
cluster.reload
    让当前进程知道远程节点名和地址

cluster.open
    打开当前进程的 Cluster 监听端口

cluster.register
    把远程服务名映射到本地 Service handle
~~~

cluster.register("battle_dispatch", dispatcher) 可以理解为：

~~~text
battle_dispatch
    ↓
dispatcher 的本地 handle
~~~

远程 Gateway 不需要知道 dispatcher 的数值地址，只需要节点 battle 和服务名 battle_dispatch。

### 11.2 cluster.call 和 skynet.call

~~~text
skynet.call
    当前 OS Process 内
    目标是数值 Service handle
    使用本地消息队列

cluster.call
    跨 OS Process
    目标是远程节点和注册服务名
    经过 Cluster 网络并等待远程响应
~~~

它们都可能 yield，但等待范围不同：skynet.call 等本地 Service，cluster.call 还可能等待网络和远程进程。

### 11.3 Battle READY

Cluster 注册后，battle_main 打印：

~~~lua
skynet.error(
    "LESSON2_BATTLE_PROCESS_READY node=",
    process.cluster.service_name,
    " query=", skynet.address(query_service),
    " manager=", skynet.address(mgr),
    " dispatch=", skynet.address(dispatcher)
)
skynet.exit()
~~~

这条日志前已经完成：

~~~text
Query load_map、身份校验和 ready
Manager Worker Pool 和 ready
Dispatch configure 和 ready
Battle cluster.open
Battle cluster.register
~~~

## 12. Gateway Proxy 如何连接 Battle

### 12.1 gateway_main 的真实装配

文件：

~~~
server/service/gateway/gateway_main.lua
~~~

~~~lua
local proxy_service =
    skynet.newservice("gateway/gateway_proxy")
assert(skynet.call(proxy_service, "lua", "start"))

local gateway_service =
    skynet.newservice("flywow_gateway")
assert(skynet.call(proxy_service, "lua", "bind_gateway", {
    gateway_service = gateway_service,
}))

local gateway = assert(skynet.call(gateway_service, "lua", "start", {
    handler_service = proxy_service,
    host = config.host,
    port = config.port,
    transport = config.transport,
}))
~~~

Proxy 先启动，FlyWow Gateway 后绑定，是因为客户端入口必须先有可用的 Battle 转发目标。

### 12.2 Proxy.start 的真实步骤

文件：

~~~
server/service/gateway/gateway_proxy.lua
~~~

~~~lua
cluster.reload({
    [process.cluster.remote_node] =
        process.cluster.remote_address,
})
cluster.open(
    process.cluster.local_listen,
    process.cluster.max_clients
)
cluster.register(
    process.cluster.proxy_service,
    skynet.self()
)

local ready_ok, ready_result = pcall(
    cluster.call,
    process.cluster.remote_node,
    "@" .. process.cluster.remote_service,
    "ready"
)
assert(ready_ok and ready_result == true,
    "battle process is not ready: "
    .. tostring(ready_result))
state.started = true
~~~

当前配置：

~~~text
remote_node    = battle
remote_service = battle_dispatch
local_listen   = 2527
~~~

执行过程：

~~~text
Gateway Proxy 打开 2527
    ↓ 注册 gateway_proxy
    ↓ cluster.call 到 battle
    ↓ 调用 @battle_dispatch 的 ready
    ↓ Battle 返回 true
    ↓ Proxy 设置 state.started = true
~~~

### 12.3 bind_gateway 的 ownership

~~~lua
local function bind_gateway(options)
    assert(state.started and state.gateway_service == nil,
        "gateway proxy binding is invalid")
    assert(
        type(options) == "table" and
        math.type(options.gateway_service) == "integer" and
        options.gateway_service > 0,
        "gateway_service is required"
    )
    state.gateway_service = options.gateway_service
    return true
end
~~~

Proxy 保存的是 FlyWow Gateway Service handle。它不是：

~~~text
connection_id
gateway_epoch
command_id
~~~

这些字段属于网络传输合同，handle 属于 Skynet Service 寻址。

### 12.4 最后绑定 19011

~~~lua
skynet.call(gateway_service, "lua", "start", {
    handler_service = proxy_service,
    host = config.host,
    port = config.port,
    transport = config.transport,
})
~~~

当前配置：

~~~text
host = 127.0.0.1
port = 19011
transport = tcp
~~~

所以 19011 可连接时，至少说明：

~~~text
Proxy 已打开 2527
Proxy 已确认 Battle ready
Proxy 已保存 Gateway handle
FlyWow Gateway 已执行 start
~~~

## 13. Gateway Proxy 如何判断消息方向

Proxy 的 dispatch 使用：

~~~lua
if source == state.gateway_service then
    forward_to_battle(data)
else
    forward_to_gateway(data)
end
~~~

source 是发送这条 Skynet 消息的 Service handle。

因此：

~~~text
source == 本地 FlyWow Gateway handle
    客户端入站数据
    forward_to_battle

source 不是本地 FlyWow Gateway handle
    Battle 回推数据
    forward_to_gateway
~~~

请求方向：

~~~text
Unity
    ↓ TCP 19011
FlyWow Gateway
    ↓ skynet.send
gateway_proxy
    ↓ cluster.send
battle_dispatch
~~~

回包方向：

~~~text
battle_dispatch
    ↓ cluster.send 到 gateway_proxy
gateway_proxy
    ↓ skynet.send 到 gateway_service
FlyWow Gateway
    ↓ TCP 19011
Unity
~~~

connection_id 不能替代 source：前者是客户端连接身份，后者是 Skynet Service 身份。

## 14. 三个端口

~~~text
2528  Battle Process 的 Cluster 监听
2527  Gateway Process 的 Cluster 监听
19011 Gateway 对 Unity Client 的业务监听
~~~

它们的关系：

~~~text
19011：Unity ↔ FlyWow Gateway
2527：Battle ↔ Gateway Proxy 的 Gateway 侧
2528：Gateway Proxy ↔ Battle 的 Battle 侧
~~~

## 15. 失败如何传播

### 15.1 BMAP 加载失败

~~~text
query_logic.start
    ↓ battle_nav.load_map 失败
    ↓ assert 抛错
Query 没有正常 ready
    ↓ battle_main call ready 失败
    ↓ battle_main assert 失败
    ↓ 不执行 cluster.register
    ↓ 没有 BATTLE_PROCESS_READY
    ↓ wait_ready 失败
~~~

### 15.2 Worker 创建失败

~~~text
battle_mgr newservice/debug_start 失败
    ↓ Manager 不返回 ready=true
    ↓ battle_main 停在 mgr ready
    ↓ 不继续配置 Dispatch
    ↓ 没有 BATTLE_PROCESS_READY
~~~

### 15.3 Gateway 连接 Battle 失败

~~~text
gateway_proxy.start
    ↓ cluster.call(battle, @battle_dispatch, ready) 失败
    ↓ proxy.start 失败
    ↓ gateway_main assert 失败
    ↓ FlyWow Gateway 不执行 start
    ↓ 不绑定 19011
~~~

## 16. 按日志和断点阅读

日志顺序：

~~~text
PREPARE_OK
NAV_QUERY_READY
LESSON2_BATTLE_PROCESS_READY
LESSON2_GATEWAY_PROCESS_READY
~~~

| 日志 | 证明 | 不证明 |
|---|---|---|
| PREPARE_OK | 构建产物、descriptor、registry、BMAP 文件存在 | Query 已 load_map |
| NAV_QUERY_READY | Query 加载地图、校验版本并安装 dispatch | Manager、Cluster、Gateway 完成 |
| BATTLE_PROCESS_READY | Query、Worker、Dispatch、Cluster 注册完成 | Unity 请求成功 |
| GATEWAY_PROCESS_READY | Proxy 已连接 Battle、Gateway 已绑定客户端入口 | 回放结果一定成功 |

建议断点：

~~~text
run_lesson_02_processes.sh: start_one / wait_ready
battle_main.lua: newservice / configure / cluster.register
navigation_query.lua: query_logic.start / dispatch
query_logic.lua: battle_nav.load_map
battle_mgr.lua: Worker 创建 / ready
battle_dispatch.lua: configure / ready
gateway_proxy.lua: cluster.call / bind_gateway / source 判断
gateway_main.lua: flywow_gateway start
~~~

## 17. 本节检查点

~~~text
run_server.sh start 后，哪个脚本真正拉起两个 Skynet 进程？
为什么相对路径必须从 server 根目录解析？
start = battle/battle_main 怎样找到入口 Service？
Service、OS Process、Lua State 和普通 require 有什么区别？
newservice 返回什么，调用者没有得到什么？
skynet.call 的消息往返经过哪些阶段？
dispatch 的 session、source、command、payload 分别是什么？
retpack 为什么不能简单替换成 return？
Query ready 返回前，BMAP 和 Native 完成了什么？
Manager ready 为什么要求 Worker Pool 已创建？
Dispatch configure 传的是哪些 handle？
cluster.open 和 cluster.register 分别解决什么问题？
cluster.call 与 skynet.call 的目标和等待边界有什么不同？
Gateway Proxy 为什么要先确认 Battle ready，再绑定 19011？
source 为什么能判断消息方向，connection_id 为什么不能替代它？
battle_main 的 skynet.exit 为什么不会杀死整个 Battle 进程？
每个 READY 日志出现后，下一步应该查什么？
~~~

下一节进入 PART 5：从 battle_nav.load_map 进入 Native，逐字段阅读 BMapReader、GridMap 和 MapRegistry，确认 BMAP 如何真正变成可共享的静态地图对象。
