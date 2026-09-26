#!/usr/bin/env python3
"""Apply the Gateway/run_server documentation deltas to the current repository.

The updater edits only sections affected by the socketdriver+netpack and server-control change.
It deliberately leaves the rest of Lesson 1/Lesson 2 untouched so repository-local course edits survive.
"""
from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()

LESSON1 = ROOT / "docs/Skynet_BattleNavigation第一课_从Unity地图到Skynet查询_实操.md"
LESSON2 = ROOT / "docs/Skynet_BattleNavigation第二课_从Grid寻路到Skynet自动战斗_实操.md"
DECISIONS = ROOT / "docs/ENGINEERING_DECISIONS.md"
TEST_STRATEGY = ROOT / "docs/TEST_STRATEGY.md"
LESSON1_SPEC = ROOT / "codex/LESSON_01_SPEC.md"
CODEX_START = ROOT / "codex/CODEX_START_HERE.md"
GATEWAY = ROOT / "server/service/navigation_gateway.lua"
GAME_CONFIG = ROOT / "server/config/game.lua"
RUN_SERVER = ROOT / "server/scripts/linux/run_server.sh"
STOP_SERVER = ROOT / "server/scripts/linux/stop_server.sh"
CHECK_LUA_VARARGS = ROOT / "server/scripts/linux/check_lua_varargs.sh"

BASELINE_SHA1 = {
    LESSON1: "4590311e31057c67ff52988bed7783660218ddf0",
    LESSON2: "981264cb52ec102900e5e4d99dec7711e1f56fd7",
    DECISIONS: "8776713263d95e56ea7c8c782ca50cea389b8d61",
    TEST_STRATEGY: "4662a1343da5ab40e86fb0168d1d3487447b921a",
    LESSON1_SPEC: "5f4014882c3a6bebe485ce81121337a18516755f",
    CODEX_START: "391f2e5988a38e34c611868a09886834a3aa0361",
}


def git_blob_sha1(path: Path) -> str:
    data = path.read_bytes()
    header = f"blob {len(data)}\0".encode("ascii")
    return hashlib.sha1(header + data).hexdigest()


def load(path: Path) -> str:
    if not path.is_file():
        raise RuntimeError(f"required file missing: {path.relative_to(ROOT)}")
    expected = BASELINE_SHA1.get(path)
    if expected:
        actual = git_blob_sha1(path)
        if actual != expected:
            print(
                f"[docs-update] NOTE baseline changed for {path.relative_to(ROOT)}: "
                f"expected={expected} actual={actual}; heading/anchor based update will preserve unrelated content",
                file=sys.stderr,
            )
    return path.read_text(encoding="utf-8")


def write_if_changed(path: Path, text: str) -> None:
    old = path.read_text(encoding="utf-8")
    if old == text:
        print(f"[docs-update] unchanged {path.relative_to(ROOT)}")
        return
    path.write_text(text, encoding="utf-8")
    print(f"[docs-update] updated   {path.relative_to(ROOT)}")


def replace_heading_range(text: str, start_pattern: str, end_pattern: str, replacement: str, label: str) -> str:
    pattern = re.compile(rf"(?ms)^{start_pattern}.*?(?=^{end_pattern})")
    out, count = pattern.subn(replacement.rstrip() + "\n\n", text, count=1)
    if count != 1:
        raise RuntimeError(f"cannot uniquely replace section: {label} (matches={count})")
    return out


def replace_once(text: str, old: str, new: str, label: str, *, allow_already: bool = True) -> str:
    if old in text:
        if text.count(old) != 1:
            raise RuntimeError(f"anchor is not unique: {label}")
        return text.replace(old, new, 1)
    if allow_already and new in text:
        return text
    raise RuntimeError(f"anchor not found: {label}")


def fenced(path: Path, language: str) -> str:
    return f"```{language}\n{path.read_text(encoding='utf-8').rstrip()}\n```"


def update_lesson1() -> None:
    text = load(LESSON1)
    config_code = fenced(GAME_CONFIG, "lua")
    gateway_code = fenced(GATEWAY, "lua")
    run_code = fenced(RUN_SERVER, "bash")
    stop_code = fenced(STOP_SERVER, "bash")
    lua_vararg_check_code = fenced(CHECK_LUA_VARARGS, "bash")

    text = replace_once(
        text,
        "  -> TCP + Protobuf\n",
        "  -> socketdriver + netpack + Protobuf\n",
        "lesson1 top execution chain",
    )
    text = replace_once(
        text,
        "/build/\n/logs/\n/tmp/\n",
        "/build/\n/logs/\n/run/\n/tmp/\n",
        "lesson1 server gitignore run directory",
    )
    text = replace_once(
        text,
        "现在需要两个真正独立的运行单元：Query Service 拥有静态地图查询入口，Gateway Service 拥有监听端口和连接协程。它们由 `skynet.newservice()` 创建，各自拥有 Service Context、消息队列和 Lua State。",
        "现在需要两个真正独立的运行单元：Query Service 拥有静态地图查询入口；Gateway Service 直接拥有监听 fd、连接状态和 `PTYPE_SOCKET` 事件分发。它们由 `skynet.newservice()` 创建，各自拥有 Service Context、消息队列和 Lua State。",
        "lesson1 service intro",
    )
    text = replace_once(
        text,
        "业务计算、协议编解码和长度帧只是 Service 内部使用的普通 Lua 模块，放进 `lualib/` 并通过 `require` 加载。`require` 不创建 Service，不产生新 Lua State，也不建立消息边界。",
        "业务计算和 Protobuf 编解码仍是 Service 内部的普通 Lua 模块，放进 `lualib/` 并通过 `require` 加载。TCP 分帧不再自己维护字符串 buffer，而由 Skynet v1.8.0 的 `skynet.netpack` 在 Gateway 的 socket protocol filter 中完成。`require` 不创建 Service，不产生新 Lua State，也不建立消息边界。",
        "lesson1 service library intro",
    )
    text = replace_once(
        text,
        "  network/\n    length_frame.lua\n  protocol/\n",
        "  protocol/\n",
        "lesson1 service directory list",
    )

    section_262 = f'''### 26.2 配置

Gateway 改成 `socketdriver + netpack` 后，配置除了监听地址和协议版本，还需要明确连接容量、单连接并发请求上限以及慢连接写缓冲保护。`netpack` 使用 16 位包长，因此应用 payload 上限不能再写成 64 KiB；精确上限是 `65535` bytes。

操作：完整替换 Server 业务配置。

完整替换已有文件：`config/game.lua`

{config_code}

这里的 `max_clients` 和 `max_inflight_per_connection` 解决的是两个不同问题：前者限制同时存在的 TCP 连接数，后者限制一个连接在 Gateway `skynet.call(Query Service)` yield 期间能够堆积多少未完成请求。二者都属于接入层保护，不进入 Query/Navigate 业务。

端口继续默认绑定 `127.0.0.1`。需要局域网联调时显式改成 `0.0.0.0`，并同时确认宿主机/WSL 防火墙；不要为了“连得上”把正式配置默认暴露到所有网卡。'''
    text = replace_heading_range(text, r"### 26\.2 [^\n]*", r"### 26\.3 ", section_262, "Lesson1 26.2")

    section_27 = f'''## 27. TCP framing：`socketdriver + netpack` 的事件驱动 Gateway

现在处理第一课网络链路中最接近真实 Skynet Server 的一层。旧实现用 `skynet.socket` 给每个连接启动一个 `client_loop`，然后反复 `socket.read(fd)`，自己维护字符串 buffer、半包和粘包。这个写法可以工作，也适合普通 Lua 网络程序入门，但它把 Skynet 底层已经提供的 socket event 与 `netpack` 分帧能力重新做了一遍。

这一版直接使用 Skynet v1.8.0 自带的底层组合：

```text
socket thread
   -> PTYPE_SOCKET message
   -> navigation_gateway.lua
      -> netpack.filter(queue, msg, sz)
         ├─ init      listen 完成
         ├─ open      accept 新连接
         ├─ data      一个完整 frame
         ├─ more      一次得到多个完整 frame
         ├─ close     对端关闭
         ├─ error     socket 错误
         └─ warning   写缓冲持续积压
      -> decode Protobuf Envelope
      -> skynet.call(Query Service)      [yield]
      -> encode response
      -> netpack.pack
      -> socketdriver.send
```

#### 本节的商业级工程边界

第一课只承载低频 `QueryCell`，但 Gateway 仍然是正式接入层，不能用“教学 Demo”省略错误边界。本节要求 Gateway 独占 fd、connections 和 netpack queue；frame/version/command/body 先校验；连接数、帧长、单连接 in-flight 和写缓冲有界；C message 在 yield 前释放；`skynet.call` 返回后验证 connection identity；Query Service handle 显式注入；Gateway 不加载 BMAP，也不执行 Native 查询。

当前阶段不宣称它已经可以直接暴露到生产公网。TLS、账号鉴权、按玩家限流、空闲超时、指标平台、多实例负载均衡和应用层 drain 是真实部署仍需补齐的能力。功能可以按课程范围延后，ownership、资源上限、错误和演进边界不能用 Demo 捷径替代。

这里最重要的变化不是 API 名字，而是 ownership 模型：Gateway 不再为每个 fd 建一个“读循环 owner”。连接状态保存在 Gateway Service 的 `connections[fd]` 中，底层 socket 事件不断投递到同一个 Service；每条请求自己的消息协程可以在 `skynet.call` 处 yield。

### 27.1 为什么 framing 必须从 4-byte 改成 2-byte

Skynet v1.8.0 的 `skynet.netpack` 不是通用可配置 parser。它在 C 层固定读取：

```text
2-byte unsigned length, Big Endian
length bytes payload
```

包长字段是 `uint16`，因此：

```text
HeaderSize       = 2 bytes
MaxPayload       = 65535 bytes
Wire payload     = Protobuf Envelope bytes
```

如果仍保留旧的 4-byte header，就不能让 `netpack.filter` 正确完成半包/粘包处理；前两个 `0x00` 很可能会被解释成长度 0。真正采用 `netpack` 就必须同步修改客户端 framing。Protobuf Schema、Envelope、command、request_id、WorldPosition 都不变，变化只发生在 TCP 消息边界。

### 27.2 `socketdriver` 与 `skynet.socket` 的关系

`skynet.socket` 本身也是在 `socketdriver` 上封装 coroutine/read 语义。第一课现在直接下一层：

```text
skynet.socket
  适合：read/readline 风格、一个协程顺序消费连接数据

socketdriver + PTYPE_SOCKET
  适合：Gateway/接入层直接处理 accept/data/close/error/warning 事件
```

这不是说业务 Service 都应该使用底层 API。只有 Gateway 这种需要控制连接生命周期、背压、包队列和跨 Service dispatch 的接入层，才值得直接接触 `socketdriver`。

### 27.3 `netpack` 的内存 ownership

`netpack.filter` 可能把完整包放进 C 分配的 queue。`netpack.pop(queue)` 返回：

```text
fd, lightuserdata msg, size
```

`msg` 不是 Lua string。当前 Gateway 第一件事调用：

```lua
local payload = netpack.tostring(msg, sz)
```

它会复制出 Lua string，并释放原来的 C message block。因此不要在 `netpack.tostring` 前 `skynet.call`、`skynet.sleep` 或把 `msg` 保存到 table 里长期使用。Service 退出时，尚未 pop 的 queue 还要通过 `netpack.clear(queue)` 释放。

发送方向相反：

```lua
socketdriver.send(fd, netpack.pack(envelope))
```

`netpack.pack` 分配带 2-byte header 的发送 buffer，`socketdriver.send` 接管它。业务代码不再自己拼接 header string。

### 27.4 yield 以后为什么必须再次确认连接身份

收到请求后会发生：

```text
fd=17 request A
-> decode
-> skynet.call(Query Service)   [yield]

此时 Gateway 仍可能收到：
fd=17 close
-> connection[17] 删除

稍后 OS/Skynet 可能让另一个连接重新使用 fd=17
-> connection[17] = new connection

request A 的 skynet.call 返回
```

如果旧协程只保存整数 `17`，此时直接 `socketdriver.send(17, ...)` 就可能把旧用户的响应写给新连接。

所以实现保存的是 connection table 对象，并在 call 返回以后检查：

```lua
if connections[fd] ~= conn or conn.closed then
    return
end
```

这属于 Gateway 连接生命周期问题，不是 Query Service 的业务锁。

### 27.5 为什么限制单连接 in-flight

事件驱动以后，一个连接可以在前一个 `skynet.call` 尚未返回时继续送入后续完整 frame。如果完全不限制，恶意或异常客户端可以让一个 fd 同时挂起大量请求协程。

第一课固定：

```text
max_inflight_per_connection = 32
```

超过上限直接关闭连接。这里没有实现复杂排队和流控，因为第一课只是低频 QueryCell 验收链；真正游戏 Gateway 可以根据协议语义选择串行请求、每玩家 Agent、限流队列或 back-pressure。

### 27.6 第一次理解 `skynet.register_protocol`

Gateway 即将直接接收 `PTYPE_SOCKET`。`skynet.register_protocol` 在当前 Service 的 Lua State 中登记消息类型、解包规则和处理入口；它不是向 OS 注册 Socket，也不是给 Service 注册全局名字。下面的写法本身就是一次显式函数调用，省略圆括号只是 Lua 对单个 table 参数的语法糖：

```lua
skynet.register_protocol {{
    name = "socket",
    id = skynet.PTYPE_SOCKET,
    unpack = function(msg, sz)
        return netpack.filter(queue, msg, sz)
    end,
    dispatch = function(_session, _source, updated_queue, event, arg1, arg2, arg3)
        -- 根据 event 显式映射到 SOCKET.init/open/data/more/close/error/warning。
    end,
}}
```

接收方向使用固定合同：

```text
dispatch 的参数
= session
+ source
+ unpack(msg, sz) 的全部返回值
```

当前 `netpack.filter` 返回更新后的 queue、event 和该 event 的参数，因此 dispatch 的第三、第四个参数分别是 `updated_queue`、`event`。后续返回值由固定的 `arg1/arg2/arg3` 接收，再通过显式 event 分支调用对应 `SOCKET` 函数。`_session`、`_source` 仍然会收到值；下划线前缀只表示当前函数有意不使用它们。

项目自有 Lua 代码不传播 `...`。框架适配层也使用固定槽位，具体事件再由明确函数签名收敛：

```lua
function SOCKET.open(fd, address) end
function SOCKET.data(fd, msg, sz) end
function SOCKET.error(fd, message) end
function SOCKET.warning(fd, pending_kb) end
```

对需要接收消息的协议，逻辑上必须同时存在 `unpack` 和 `dispatch`，但不一定都在 `register_protocol` 中编写：

| 场景 | `unpack` | `dispatch` |
|---|---|---|
| 内置 `"lua"` 协议 | Skynet 已注册 | Service 调用 `skynet.dispatch("lua", handler)` |
| 自定义接收协议 | 当前协议适配层提供 | 当前 Service 提供 |
| 本节 `PTYPE_SOCKET` | 包装 `netpack.filter` | Gateway 事件分发函数 |

`pack` 属于相反的发送方向：`Lua 参数 -> pack -> Skynet message`。当前 Gateway 使用 `socketdriver.send(fd, netpack.pack(payload))`，所以没有为 `"socket"` 协议提供 `pack`。

这里必须显式注册，是因为 Gateway 直接用 `socketdriver + netpack` 接管 `PTYPE_SOCKET`；高层 `skynet.socket` 与这套模型不能在同一个 Gateway 中重复注册或混用。IDE 无法完整推导 C 模块的可变返回值时，以固定 Skynet v1.8.0 的 `lualib/skynet.lua`、`service/gate.lua` 和 `lualib-src/lua-netpack.c` 为准。框架合同只在接入层理解一次，再通过命名函数、注解、断言和测试向业务层收敛。

### 27.7 替换 Gateway

#### 学习导航

```text
必须精读：PTYPE_SOCKET 注册、netpack.filter/pop/tostring、open/data/more/close/error/warning
必须理解：msg ownership、fd 复用保护、skynet.call yield、inflight 限制、慢连接写缓冲保护
可以略读：日志字段拼接和启动参数 assert
输入：socketdriver 事件 + 完整 netpack payload
输出：QueryCell response 的 netpack frame
失败：非法 Envelope/版本/命令/body、Query Service call 失败、连接过载、写缓冲过大
不负责：BMAP、Native 查询实现、A*、Battle 动态状态
```

操作：删除旧的手写 framing 工具，并完整替换 Gateway。

```text
删除：server/lualib/network/length_frame.lua
完整替换：server/service/navigation_gateway.lua
```

{gateway_code}

### 27.8 这版 Gateway 的事件与 yield 边界

```text
SOCKET.open/error/close/warning
  只更新本 Gateway 的连接状态

SOCKET.data / SOCKET.more
  netpack 已经给出完整 Envelope bytes
  -> decode
  -> inflight++
  -> skynet.call(query_service, ...)      可 yield
  -> inflight--
  -> 再确认 connections[fd] == conn
  -> send response
```

#### `updated_queue` 是可能被替换的状态对象

`netpack.filter(queue, msg, sz)` 的第一个返回值不是“一个新的空队列”，而是处理完本次 Socket 消息后的最新 queue userdata。这个 C 对象同时保存：

```text
尚未收完整的包
已经完整、等待 netpack.pop 的包
环形队列容量、head/tail
按 fd 保存的半包状态
```

初始 `queue` 可以为 `nil`。第一次需要保存半包或多个完整包时，`netpack` 才创建 userdata；环形队列容量不足时，它还可能创建更大的 userdata并迁移状态。因此它更接近下面的 C++ 接口：

```cpp
queue = FilterAndMaybeReallocate(queue, socket_message);
```

而不是一个永远固定的整数 fd。每次 dispatch 都必须先写回：

```lua
dispatch = function(_session, _source, updated_queue, event, arg1, arg2, arg3)
    queue = updated_queue
    -- 写回之后再根据 event 处理 data/more/open 等事件。
end
```

可能出现的结果如下：

| 输入情况 | `updated_queue` | `event` |
|---|---|---|
| 一个完整包且无需内部状态 | 可能仍为 `nil` | `data` |
| 只收到半包 | userdata，保存半包 | `nil` |
| 一次形成多个完整包 | userdata，保存待 pop 包 | `more` |
| 已有 queue 且未扩容 | 通常是同一个 userdata | 取决于 Socket 事件 |
| 容量不足 | 新 userdata，状态已迁移 | 通常与 `more` 路径相关 |

`queue = updated_queue` 只是更新 Lua 引用，不会清空队列。扩容时，C 模块把尚未消费的完整包和半包状态迁移到新对象，再把旧对象重置为空；业务代码不能比较 userdata 地址、序列化 queue、跨 Service 传递它，或把旧引用缓存到一次 yield 之后。

已经由 `netpack.pop` 取出的 `msg` 不再属于 queue。`dispatch_packet` 必须在任何 yield 前调用 `netpack.tostring(msg, sz)`，把它转换成 Lua string 并释放 C buffer。这样即使随后 queue 扩容，当前请求的 payload 也不受影响。

#### 为什么 `dispatch_queue` 要先 fork continuation

`netpack` queue 属于整个 Gateway，里面可能同时存在多个 fd 的完整包。如果当前包在 `skynet.call(query_service, ...)` 处 yield，而没有其他协程继续 drain，一个慢客户端请求就会阻塞 queue 中其他客户端已经完整的包：

```text
queue 中已有：fd1/A、fd2/B、fd3/C

不 fork：
  pop A -> A 等 Query Service
  B、C 留在 queue，直到 A 恢复
```

当前代码先安排一条续接协程，再处理当前包：

```lua
skynet.fork(dispatch_queue)
dispatch_packet(fd, msg, sz)
```

`skynet.fork` 只把新协程加入当前 Service 的待运行队列，不会立刻与当前协程并行。若 A 在 `skynet.call` 处 yield，续接协程才获得机会，从最新的全局 queue 继续取 B：

```text
协程 A：pop A -> fork 续接 B -> 处理 A -> yield
协程 B：pop B -> fork 续接 C -> 处理 B -> yield
协程 C：pop C -> fork 空续接 -> 处理 C
```

如果当前包在协议校验阶段就返回、完全没有 yield，后面的 `for` 循环会由当前协程直接批量排空，避免无条件为每个包创建协程。提前 fork 的续接协程稍后看到空 queue 就直接结束。

泛型 `for` 会保存进入循环时的 queue 引用。若循环体 yield 期间发生扩容，旧 queue 已被迁移并重置为空；旧循环恢复后会结束，续接协程则通过模块变量读取新 queue。所有操作仍在同一个 Service 中串行执行，不会同时 pop，也不会重复释放 buffer。

#### Gateway 并发接入与业务有序执行分层处理

取消 fork 会把整个 Gateway 变成跨所有连接的全局串行队列，并不能正确表达“同一玩家或同一战斗的命令有序”。商业项目按状态 Owner 保证业务顺序：

```text
Gateway
  校验 frame / session / command_seq
  -> PlayerAgent(player_id)
       同一玩家命令按 Owner 规则执行
  -> BattleWorker(battle_id)
       收集 PlayerCommand，按 fixed tick 和确定性顺序 simulate
```

第一课 `QueryCell` 是只读请求，多个连接可以并发等待，响应用 `request_id` 匹配，不依赖完成顺序。以后出现移动、施法、背包或奖励等有状态命令时，应路由到唯一 Player/Battle Owner；Owner 的核心状态修改保持 no-yield，便能自然做到 A 完成后再执行 B。

只有某个 Owner 内的完整事务确实必须跨 yield 保持互斥时，才考虑为该 Owner 使用 `require "skynet.queue"` 提供的协程互斥器、状态机或提交前版本复核。不能在整个 Gateway 外层套一个全局互斥器，否则一个玩家的数据库或远程调用会阻塞所有连接。断线重连、重试和跨 Gateway 场景还需要 `command_seq`、目标 tick 与去重规则，不能只依赖 TCP 字节到达顺序。

#### Service 串行执行不等于一条协程运行到底

Skynet 对每个 Service Context 保证消息回调串行执行：同一个 Service 不会同时由两个 Worker Thread 执行两条消息回调。Lua Service 只有一个 Lua State，所以任意瞬间也只有一条 Lua 协程在执行指令。这条保证适用于所有由 Skynet 调度的 Service；不同 Service 仍可在不同 OS Thread 上并行运行，C 模块自行创建的线程也不受这个保证保护。

同一个 Lua Service 可以同时保存多条尚未结束的消息协程。一条协程 yield 后，Service 可以处理下一条消息；因此不会发生两条 Lua 指令在 CPU 上同时修改 table，却会发生 yield 前后状态已经被另一条消息改变的逻辑并发：

```text
请求协程 A：读取 connections[fd] -> skynet.call 后 yield
Socket 协程 B：处理 close，删除 connections[fd]
请求协程 A：恢复，必须重新验证 connections[fd] == conn
```

固定版本实现可在以下位置核对：

```text
third_party/skynet/lualib/skynet.lua
  raw_dispatch_message：每条请求创建 Lua 协程
  suspend：协程 yield 后把控制权交还调度器
  dispatch_wakeup：恢复已经登记等待的协程
```

#### `wakeup` 不是可提前累积的信号

`skynet.wait(token)` 会先把当前协程登记到 `sleep_session[token]`，再 yield。`skynet.wakeup(token)` 只有在登记已经存在时才把 token 放入唤醒队列；如果先 wakeup、后 wait，第一次 wakeup 返回 `nil`，也不会保存一份“唤醒额度”：

```lua
local token = {{}}
local accepted = skynet.wakeup(token) -- nil：当前没有协程等待这个 token。
skynet.wait(token)                    -- 仍然挂起，需要之后再有一次 wakeup。
```

因此，业务完成状态不能只存在于一次 wakeup 通知中。通知可能先到时，要用“状态 + wait/wakeup”表达：

```lua
local completed = false -- 业务结果是否已经产生；属于当前 Service Lua State。
local waiter = nil      -- 当前等待结果的协程；没有等待者时为 nil。
local result = nil      -- 已完成结果；生命周期由当前 Service 管理。

-- 保存业务结果；value 由调用方移交给当前 Service，不执行 I/O，不 yield。
local function complete(value)
    result = value
    completed = true
    if waiter ~= nil then
        skynet.wakeup(waiter)
    end
end

-- 等待并返回已保存结果；可能在 skynet.wait 处 yield，没有超时分支。
local function wait_result()
    while not completed do
        waiter = coroutine.running()
        skynet.wait(waiter)
    end
    waiter = nil
    return result
end
```

这里检查 `completed` 到执行 `skynet.wait` 之间没有其他 yield 点；同一个 Service 的完成回调不能插入执行。进入 `skynet.wait` 后，框架又会先登记 token 再 yield，所以“完成先发生”和“等待先发生”两种顺序都不会丢结果。生产代码还应根据业务增加超时、取消和多等待者规则。

#### 当前监听握手为什么不会丢失 `init`

`socketdriver.listen(host, port, backlog)` 同步返回的是 Skynet Socket ID。无法创建 ID 会立即返回无效值；真正的异步 bind/listen 成功通过 `event == "init"` 返回，异步失败通过 `event == "error"` 返回。

Socket Thread 可能很快把 `init` 投递进 Gateway 消息队列，但它不能重入正在执行的 `start_gateway`：

```text
start_gateway 当前协程
  socketdriver.listen
  -> 建立 listen_context
  -> skynet.wait 先登记 token
  -> yield

Gateway 才开始处理队列中的 init/error
  -> SOCKET.init/error 写入结果
  -> skynet.wakeup(start 协程)
```

所以从 `socketdriver.listen` 返回到 `skynet.wait` 登记完成之间是一段明确的 no-yield 区域。不能在中间加入 `skynet.call`、`skynet.sleep` 或其他可能 yield 的函数，否则 `init` 可能在 `listen_context` 建立前被处理并忽略。等待成功结果后才执行 `socketdriver.start(listen_fd)`，让监听 Socket 开始上报新客户端的 `open` 事件。

`Query Service` 内的 `query_logic.query()` 仍然不 yield；第二课 BattleWorker 的核心 `battle_core.simulate()` 仍然 no-yield。这次网络改造不会把 socket event 或 Gateway 状态带进导航/战斗核心。

### 27.9 验证点

启动后至少观察：

```text
NAV_TCP_READY ... framing=netpack-u16be max_frame=65535
NAV_TCP_ACCEPT fd=... address=... clients=...
NAV_TCP_CLOSE fd=... reason=...
```

再做三个网络行为测试：

```text
一个完整 frame 分多次 send       -> 只得到一次业务请求
两个 frame 合并成一次 send       -> 得到两个独立请求
旧 4-byte header 客户端连接      -> 不得被当成合法 Envelope 继续执行业务
```

半包/粘包的状态现在由 `netpack` C 模块管理，不再通过 Lua 字符串 `buffer = buffer .. chunk` 反复复制。'''
    text = replace_heading_range(text, r"## 27\.[^\n]*", r"## 28\.", section_27, "Lesson1 27")

    section_28_launcher = f'''构建入口还需要阻止项目自有 Lua 重新引入匿名可变参数。这个检查会被本节的 `build` 和 `rebuild` 直接调用；完成后，违规位置会在启动 Server 前以文件名和行号报告，正常结果是 `LUA_VARARG_POLICY_OK`。

本文件解决的问题：把“稳定接口使用具名参数”从 Code Review 约定变成可重复执行的静态检查。

本节必须掌握的概念：检查范围只包含 `server/service`、`lualib`、`protocol`、`config`、`tests` 下的项目自有 `.lua`，不修改 Skynet 等第三方源码。

必须精读的函数：`collect_project_lua_files` 决定所有权边界，`main` 决定失败条件。

可以略读的内容：Bash 的数组、`mapfile` 和输出格式。

输入、输出和失败条件：输入是项目自有 Lua 源码；零匹配输出 `LUA_VARARG_POLICY_OK`；发现 `...` 时输出位置并以非零状态退出。确有通用基础设施例外时，必须在同一行标记 `VARARG_ALLOWED` 并写清 WHY；当前课程没有例外。

运行验证：在 `server/` 下执行 `./scripts/linux/check_lua_varargs.sh`。

理解自测：为什么检查器不扫描 `third_party/skynet`？为什么不能把“避免 `...`”直接等同于“必然减少分配”？

新建文件：`server/scripts/linux/check_lua_varargs.sh`

{lua_vararg_check_code}

操作：完整替换 Server 启动脚本，并新增安全停止入口。第一课从这里开始不再要求手工先执行一串 bootstrap/build 命令；统一由 `run_server.sh` 做可重复的依赖准备、增量构建、后台启动和 PID 管理。

完整替换：`server/scripts/linux/run_server.sh`

{run_code}

新增：`server/scripts/linux/stop_server.sh`

{stop_code}

第一次使用：

```bash
cd "$(git rev-parse --show-toplevel)/server"
chmod +x scripts/linux/check_lua_varargs.sh scripts/linux/run_server.sh scripts/linux/stop_server.sh
./scripts/linux/check_lua_varargs.sh
./scripts/linux/run_server.sh doctor || true
./scripts/linux/run_server.sh start
./scripts/linux/run_server.sh status
```

`start` 会完成：

```text
检查基础系统工具
-> 缺失时给出明确 apt 安装命令，不偷偷 sudo
-> 检查/补齐 pinned Skynet v1.8.0 源码
-> 检查/补齐 pinned protoc + lua-protobuf
-> 按需编译 Skynet / pb.so / descriptor
-> 增量配置并编译 battle_nav.so
-> build/rebuild 时检查项目 Lua 不使用匿名可变参数
-> 校验 battle_1001.bmap 已由 Unity 发布
-> nohup 后台启动
-> 写 run/server.pid
-> 写 logs/server-时间.log
-> 等待 NAV_SERVER_READY
```

完整重新编译：

```bash
./scripts/linux/run_server.sh rebuild
# 或重编后直接启动
./scripts/linux/run_server.sh start --rebuild
```

`rebuild` 只允许清理当前工程的 `server/build/*`，并执行 Skynet `make clean` 后重编；不会删除 `maps/`、Unity 导出的 BMAP、Git 源码或 third_party pinned 源码。

前台调试：

```bash
./scripts/linux/run_server.sh foreground
```

安全停止：

```bash
./scripts/linux/run_server.sh stop
# 等价短入口
./scripts/linux/stop_server.sh
```

停止脚本先从 `run/server.pid` 读取 PID，再检查 `/proc/<pid>/exe` 是否确实指向**当前仓库**的 Skynet 可执行文件，同时检查 cmdline 是否使用当前 `config/skynet.lua`。身份不匹配就拒绝发送信号，避免 stale PID 误杀其他进程。

默认只发送 `SIGTERM` 并等待 `STOP_TIMEOUT_SEC`，不会自动 `kill -9`。只有人工明确执行：

```bash
./scripts/linux/run_server.sh stop --force
```

并且 TERM 已超时，才允许 SIGKILL。

需要明确一个阶段边界：Skynet v1.8.0 本体只为 `SIGHUP` 注册日志处理，没有给业务提供 SIGTERM drain hook。第一课 Query/Gateway 没有 DB 写回、在线 Battle 或事务状态，所以当前 TERM 可以安全结束这个课程进程；以后进入真实持久化/在线战斗项目，必须再增加应用层 drain/shutdown 协议，不能把这一课的进程级停止当成最终商业停服流程。

后台启动成功后：

```bash
./scripts/linux/run_server.sh status
tail -f logs/server.log
```

预期日志仍保持依赖顺序：

```text
PROTO_DESCRIPTOR_OK
NAV_QUERY_READY ... map=1001 version=1
NAV_TCP_READY 127.0.0.1:19001 ... framing=netpack-u16be max_frame=65535
NAV_SERVER_READY query=:... gateway=:...
```

日志证明 Query Service 先加载地图、Gateway 完成 socketdriver listen/init 后再 READY，最后 main 才报告整个查询链可用。'''

    # Keep section 28 main/config explanation, replace only its old launcher subsection through Lesson 29.
    marker = "操作：新建 Server 启动脚本，并粘贴下面的完整内容。"
    idx = text.find(marker)
    end = text.find("## 29. Unity C# Protobuf 客户端", idx)
    if idx < 0 or end < 0:
        # idempotent/new wording path
        marker = "操作：完整替换 Server 启动脚本，并新增安全停止入口。"
        idx = text.find(marker)
        end = text.find("## 29. Unity C# Protobuf 客户端", idx)
    if idx < 0 or end < 0:
        raise RuntimeError("cannot locate Lesson1 launcher subsection")
    text = text[:idx] + section_28_launcher.rstrip() + "\n\n" + text[end:]

    section_292_293 = r'''### 29.2 TCP framing

TCP 仍然只是有序 byte stream，不保留消息边界。现在 Server 由 `skynet.netpack` 负责 framing，所以 Unity 必须使用同一线协议：

```text
2-byte unsigned payload length, Big Endian
payload = Protobuf Envelope
max payload = 65535 bytes
```

BMAP 继续是 Little Endian 离线资产；TCP frame 是 Big Endian 运行时协议。两个端序属于不同合同。

#### LengthFrame 学习导航

```text
必须精读：HeaderSize=2、MaxFrameBytes=65535、Pack 的两个 header byte、TryRead 的半包/粘包处理
必须理解：65536 无法编码进 netpack uint16 header，不能靠“加大 max_frame”绕过
可以略读：Buffer.BlockCopy 语法
输入：一个 Envelope payload 或连接累计 buffer
输出：完整 2-byte frame，或拆出的一个 payload + 剩余 buffer
失败：payload 超过 65535；数据不足返回 false
不负责：Protobuf 解析、Socket 生命周期、业务命令
```

操作：把第一课 Unity framing 示例完整替换成下面版本。

完整替换：`unity/BattleNavigation/Assets/Scripts/Protocol/LengthFrame.cs`

```csharp
// 职责：实现与 Skynet netpack 一致的 2-byte Big Endian TCP 长度帧。
// 边界：Client Runtime Transport；payload 对本文件是不透明 Protobuf bytes。
// 输入/输出：payload 或累计 buffer -> frame，或一个 payload + 剩余 bytes。
// 不负责：不连接 Socket、不解析业务消息、不执行地图查询。
using System;

namespace BattleNavigation.Protocol
{
    /// <summary>与 Skynet netpack 一致的 uint16 Big Endian framing。</summary>
    public static class LengthFrame
    {
        public const int HeaderSize = 2;
        public const int MaxFrameBytes = ushort.MaxValue;

        /// <param name="payload">一个完整 Envelope 的序列化字节。</param>
        public static byte[] Pack(byte[] payload)
        {
            if (payload == null) throw new ArgumentNullException(nameof(payload));
            if (payload.Length > MaxFrameBytes)
                throw new ArgumentOutOfRangeException(nameof(payload));

            var output = new byte[HeaderSize + payload.Length];
            output[0] = (byte)((payload.Length >> 8) & 0xff);
            output[1] = (byte)(payload.Length & 0xff);
            Buffer.BlockCopy(payload, 0, output, HeaderSize, payload.Length);
            return output;
        }

        /// <param name="buffer">连接当前累计的未消费接收字节；成功后移除一个 frame。</param>
        /// <param name="payload">成功时返回一个完整 payload；数据不足时为 null。</param>
        public static bool TryRead(ref byte[] buffer, out byte[] payload)
        {
            payload = null;
            if (buffer == null || buffer.Length < HeaderSize) return false;

            var length = (buffer[0] << 8) | buffer[1];
            if (buffer.Length < HeaderSize + length) return false;

            payload = new byte[length];
            Buffer.BlockCopy(buffer, HeaderSize, payload, 0, length);

            var remaining = buffer.Length - HeaderSize - length;
            var next = new byte[remaining];
            Buffer.BlockCopy(buffer, HeaderSize + length, next, 0, remaining);
            buffer = next;
            return true;
        }
    }
}
```

### 29.3 ServerQueryClient

`ServerQueryClient` 的业务三层合同没有变化：

```text
QueryCellRequest
-> Envelope(protocol_version / command / request_id)
-> LengthFrame(uint16 BE)
-> NetworkStream
```

同步短连接仍只用于 Editor 调试。需要修改的是读写 frame 的 header 长度。

完整替换：`unity/BattleNavigation/Assets/Scripts/Protocol/ServerQueryClient.cs`

```csharp
// 职责：供 Unity Editor 调试时同步发送一次 QueryCell 并校验对应响应。
// 边界：Client Runtime/Editor Debug；同步阻塞实现禁止放入每帧 Update。
// 输入/输出：Server 地址、地图身份和 WorldPosition(mm) -> QueryCellResponse。
// 生命周期：实例拥有一个 TcpClient/NetworkStream，由 Dispose 关闭。
// 不负责：不做连接池、自动重试、高频查询或战斗模拟。
using System;
using System.IO;
using System.Net.Sockets;
using Battle.Navigation.V1;
using Google.Protobuf;
using BattleNavigation.Protocol;

namespace BattleNavigation.Client
{
    public sealed class ServerQueryClient : IDisposable
    {
        private const uint ProtocolVersion = 1;
        private const uint QueryCellCommand = 1001;
        private static ulong nextRequestId = 1;
        private readonly TcpClient client;
        private readonly NetworkStream stream;

        public ServerQueryClient(string host, int port)
        {
            client = new TcpClient();
            client.Connect(host, port);
            stream = client.GetStream();
            stream.ReadTimeout = 3000;
            stream.WriteTimeout = 3000;
        }

        public QueryCellResponse Query(uint mapId, uint mapVersion, long xMm, long yMm, long zMm)
        {
            var request = new QueryCellRequest {
                MapId = mapId,
                MapVersion = mapVersion,
                Position = new WorldPosition { XMm = xMm, YMm = yMm, ZMm = zMm },
            };
            var envelope = new Envelope {
                ProtocolVersion = ProtocolVersion,
                Command = QueryCellCommand,
                RequestId = nextRequestId++,
                Body = ByteString.CopyFrom(request.ToByteArray()),
            };

            var frame = LengthFrame.Pack(envelope.ToByteArray());
            stream.Write(frame, 0, frame.Length);

            var responseEnvelope = Envelope.Parser.ParseFrom(ReadFrame());
            if (responseEnvelope.ProtocolVersion != ProtocolVersion)
                throw new InvalidDataException("protocol version mismatch");
            if (responseEnvelope.RequestId != envelope.RequestId)
                throw new InvalidDataException("request id mismatch");
            return QueryCellResponse.Parser.ParseFrom(responseEnvelope.Body);
        }

        private byte[] ReadFrame()
        {
            var header = ReadExact(LengthFrame.HeaderSize);
            var length = (header[0] << 8) | header[1];
            if (length <= 0 || length > LengthFrame.MaxFrameBytes)
                throw new InvalidDataException("invalid frame length");
            return ReadExact(length);
        }

        private byte[] ReadExact(int count)
        {
            var result = new byte[count];
            var offset = 0;
            while (offset < count)
            {
                var read = stream.Read(result, offset, count - offset);
                if (read == 0) throw new EndOfStreamException();
                offset += read;
            }
            return result;
        }

        public void Dispose()
        {
            stream?.Dispose();
            client?.Close();
        }
    }
}
```

客户端仍然用 `ReadExact`，因为 `netpack` 只存在于 Skynet Server；Unity 的 `NetworkStream.Read` 同样可能短读。`request_id` 继续承担请求/响应关联，因此 Gateway 在多个请求跨 Service 并发完成时不依赖“返回顺序一定等于发送顺序”。'''
    text = replace_heading_range(text, r"### 29\.2 [^\n]*", r"### 29\.4 ", section_292_293, "Lesson1 29.2-29.3")

    section_30 = r'''### 30.1 C# framing tests

这组测试锁定 Unity 与 `skynet.netpack` 完全一致的 2-byte Big Endian framing：

```text
BigEndianRoundTrip：header 为 00 04，payload 完整消费
PartialFrameWaits：2-byte Header + 部分 Payload 时必须等待
MaxPayloadAccepted：65535 可以编码
TooLargeRejected：65536 必须在客户端发送前拒绝
```

完整替换测试示例：

```csharp
using NUnit.Framework;
using BattleNavigation.Protocol;

public sealed class LengthFrameTests
{
    [Test]
    public void BigEndianRoundTrip()
    {
        var input = new byte[] { 0x01, 0x02, 0x80, 0xff };
        var frame = LengthFrame.Pack(input);
        Assert.That(frame[0], Is.EqualTo(0));
        Assert.That(frame[1], Is.EqualTo(4));

        var buffer = frame;
        Assert.That(LengthFrame.TryRead(ref buffer, out var output), Is.True);
        Assert.That(output, Is.EqualTo(input));
        Assert.That(buffer.Length, Is.EqualTo(0));
    }

    [Test]
    public void PartialFrameWaits()
    {
        var frame = LengthFrame.Pack(new byte[] { 1, 2, 3 });
        var partial = new byte[3]; // 2-byte header + 1 payload byte
        System.Array.Copy(frame, partial, partial.Length);
        Assert.That(LengthFrame.TryRead(ref partial, out _), Is.False);
    }

    [Test]
    public void MaxPayloadAccepted()
    {
        var frame = LengthFrame.Pack(new byte[ushort.MaxValue]);
        Assert.That(frame.Length, Is.EqualTo(ushort.MaxValue + LengthFrame.HeaderSize));
        Assert.That(frame[0], Is.EqualTo(0xff));
        Assert.That(frame[1], Is.EqualTo(0xff));
    }

    [Test]
    public void TooLargeRejected()
    {
        Assert.Throws<System.ArgumentOutOfRangeException>(
            () => LengthFrame.Pack(new byte[ushort.MaxValue + 1]));
    }
}
```

### 30.2 Server protocol negative / event cases

真实 TCP Client 与 Gateway 至少覆盖：

```text
1.  2-byte length=0，连接关闭，不能进入 Query Service；
2.  旧 4-byte header 客户端连接，不能被误判成合法 Envelope；
3.  protocol_version=999，不执行地图查询；
4.  command=9999，不执行地图查询；
5.  Envelope body 不是 QueryCellRequest，Gateway 不崩溃；
6.  两个 netpack frame 一次 write，得到两个独立 request_id 响应；
7.  一个 frame 分 3 次 write，仍只形成一个业务请求；
8.  response.request_id 必须等于对应 request.request_id；
9.  map_version 不匹配只能得到 MAP_VERSION_MISMATCH；
10. 世界坐标越界只能得到 OUT_OF_BOUNDS；
11. 单连接并发请求超过 max_inflight_per_connection 时连接被保护性关闭；
12. close/error 在 skynet.call yield 期间发生时，旧协程不能向后来复用的同号 fd 写响应。
```

`65536` 及以上 payload 不再属于“收到后检查”的场景：2-byte uint16 header 根本无法表达它，发送端必须在 framing 层拒绝。Server 的 `netpack.pack` 也会拒绝 `>= 0x10000` 的 payload。'''
    text = replace_heading_range(text, r"### 30\.1 [^\n]*", r"## 31\.", section_30, "Lesson1 30")

    section_313 = r'''### 31.3 启动和联调

```bash
cd "$(git rev-parse --show-toplevel)/server"
./scripts/linux/run_server.sh start
./scripts/linux/run_server.sh status
tail -f logs/server.log
```

Unity 打开 `Tools/Battle Navigation/Server Query`，输入 `127.0.0.1`、`19001`、`1001`、`1`，再输入场景世界坐标。然后查询 `x_mm=999999999`，预期结果是 `OUT_OF_BOUNDS`，而不是崩溃或卡住。

验证结束安全停止：

```bash
./scripts/linux/stop_server.sh
# 或
./scripts/linux/run_server.sh stop
```

需要观察前台事件分发或打 LuaPanda/gdb 断点时：

```bash
./scripts/linux/run_server.sh foreground
```'''
    text = replace_heading_range(text, r"### 31\.3 [^\n]*", r"## 32\.", section_313, "Lesson1 31.3")

    text = replace_once(
        text,
        "检查客户端是否完整读取 4 字节 header，Server 是否处理半包/粘包，`socket.read` 返回值是否符合当前 Skynet 版本。异常连接必须关闭。",
        "检查客户端是否按 2-byte Big Endian 读取 netpack header；Server 日志是否出现 `NAV_TCP_PROTOCOL_CLOSE`、`NAV_TCP_WRITE_WARNING` 或连接上限保护。半包/粘包由 `netpack.filter` 管理，不再排查 `socket.read` 返回块大小。",
        "Lesson1 TCP troubleshooting",
    )
    text = replace_once(
        text,
        "[ ] TCP 使用 4 字节大端长度，最大 64 KiB。",
        "[ ] Gateway 使用 `socketdriver + PTYPE_SOCKET + netpack`，TCP 为 2-byte Big Endian uint16 长度，最大 payload 65535 bytes。",
        "Lesson1 acceptance framing",
    )

    # Guard against the old gateway teaching accidentally remaining in the updated lesson.
    old_forbidden = [
        "每个 accepted fd 必须先执行 `socket.start(fd)`，随后才能 `socket.read(fd)`",
        "TCP 使用 4 字节大端长度，最大 64 KiB",
        "frame 添加 TCP 4-byte Big Endian 长度头",
    ]
    for phrase in old_forbidden:
        if phrase in text:
            raise RuntimeError(f"old Gateway wording still present in Lesson1: {phrase}")

    write_if_changed(LESSON1, text)


def update_lesson2() -> None:
    text = load(LESSON2)
    text = replace_once(
        text,
        "`BattleMgr` 调 Worker 本来就会 yield。网络 Gateway 等输入也会 yield。",
        "`BattleMgr` 调 Worker 本来就会 yield。第一课的 Navigation Gateway 现在由 `socketdriver + netpack` 直接接收 `PTYPE_SOCKET` 事件，在完整请求进入 `skynet.call(Query Service)` 时同样允许 yield；这类接入层并发不会改变 Battle 核心的 no-yield 规则。",
        "Lesson2 Gateway yield boundary",
    )
    text = replace_once(
        text,
        "注意 Worker 的服务名取决于当前 Skynet `luaservice` 搜索路径。当前 Git 仓库没有提交第一课实际 Skynet config，因此运行前要用本机第一课已经验证的 `luaservice/lua_path/cpath` 配置确认路径，不要为了匹配文档新造 `lesson2_server` 之类阶段性入口。",
        "注意 Worker 的服务名取决于当前 Skynet `luaservice` 搜索路径。仓库已经提交第一课的 `server/config/skynet.lua`，其 `./service/?.lua` 与 `./lualib/?.lua` 可以继续解析第二课的 `battle/...` 子路径；第二课直接沿用这份进程配置，不为匹配课程阶段另造 `lesson2_server` 入口。",
        "Lesson2 stale skynet config note",
    )
    write_if_changed(LESSON2, text)


def update_decisions() -> None:
    text = load(DECISIONS)
    text = replace_once(text, "-> TCP length frame\n", "-> TCP netpack frame\n", "D029 chain")
    text = replace_once(
        text,
        "frame: uint32 big-endian length + Protobuf Envelope\nmax application payload: 64 KiB",
        "frame: uint16 big-endian length (Skynet netpack) + Protobuf Envelope\nmax application payload: 65535 bytes",
        "D029 framing contract",
    )
    text = replace_once(
        text,
        "service/navigation_gateway.lua     Gateway Service 入口\nlualib/navigation/query_logic.lua  Query 内部业务模块\nlualib/network/length_frame.lua    Gateway 内部 framing 工具\nlualib/protocol/navigation_codec.lua  Gateway 内部 codec",
        "service/navigation_gateway.lua     Gateway Service 入口；直接持有 socketdriver/netpack event loop\nlualib/navigation/query_logic.lua  Query 内部业务模块\nlualib/protocol/navigation_codec.lua  Gateway 内部 codec",
        "D031 directory contract",
    )
    write_if_changed(DECISIONS, text)


def update_test_strategy() -> None:
    text = load(TEST_STRATEGY)
    text = replace_once(
        text,
        "4-byte big-endian length frame\nprotocol version\nrequest id\nunknown command\nmalformed envelope/body\n64 KiB packet limit",
        "2-byte big-endian uint16 netpack frame\nsocketdriver open/data/more/close/error/warning event path\nprotocol version\nrequest id\nunknown command\nmalformed envelope/body\n65535-byte payload limit\nfd close/reuse while a request yields\nper-connection in-flight limit",
        "Test strategy Gateway contract",
    )
    write_if_changed(TEST_STRATEGY, text)


def update_lesson1_spec() -> None:
    text = load(LESSON1_SPEC)
    text = replace_once(
        text,
        "[ ] TCP length framing and malformed packet tests",
        "[ ] socketdriver + PTYPE_SOCKET + netpack event-driven Gateway\n[ ] uint16 Big Endian framing, half/sticky packet and malformed packet tests\n[ ] fd close/reuse and per-connection in-flight protection",
        "Lesson1 spec gateway acceptance",
    )
    write_if_changed(LESSON1_SPEC, text)


def update_codex_start() -> None:
    text = load(CODEX_START)
    text = replace_once(
        text,
        "service/navigation_gateway.lua  真正的 Gateway Service 入口\nlualib/navigation/              Query Service 内普通模块\nlualib/network/                 Gateway 内普通网络工具\nlualib/protocol/                运行期协议 codec",
        "service/navigation_gateway.lua  真正的 Gateway Service 入口；直接使用 socketdriver + netpack\nlualib/navigation/              Query Service 内普通模块\nlualib/protocol/                运行期 Protobuf codec",
        "CODEX start directory identity",
    )
    write_if_changed(CODEX_START, text)


def main() -> None:
    required = [LESSON1, LESSON2, DECISIONS, TEST_STRATEGY, LESSON1_SPEC, CODEX_START, GATEWAY, GAME_CONFIG, RUN_SERVER, STOP_SERVER, CHECK_LUA_VARARGS]
    for path in required:
        if not path.is_file():
            raise RuntimeError(f"required update input missing: {path.relative_to(ROOT)}")

    update_lesson1()
    update_lesson2()
    update_decisions()
    update_test_strategy()
    update_lesson1_spec()
    update_codex_start()

    legacy = ROOT / "server/lualib/network/length_frame.lua"
    if legacy.exists():
        legacy.unlink()
        print(f"[docs-update] removed   {legacy.relative_to(ROOT)} (retired by skynet.netpack)")

    print("[docs-update] DOCUMENT_UPDATE_OK")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"[docs-update] ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
