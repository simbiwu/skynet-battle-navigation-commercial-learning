-- 职责：使用 socketdriver + netpack 事件模型监听 TCP、完成分帧/协议校验，并转发 QueryCell。
-- 边界：Skynet Gateway Service；直接拥有 listen/client fd 和 PTYPE_SOCKET 事件分发。
-- 输入/输出：2-byte Big Endian netpack frame(Envelope protobuf) <-> QueryCell response frame。
-- 生命周期：main 创建一次并注入 Query Service；连接状态只属于本 Service 的 Lua State。
-- 不负责：不加载 BMAP、不直接调用 Native、不保存 Battle 状态、不自行实现 A*。
local skynet = require "skynet"
local socketdriver = require "skynet.socketdriver"
local netpack = require "skynet.netpack"
local config = require "config.game"
local codec = require "protocol.navigation_codec"
local luapanda_debug = require "debug.luapanda_debug"

local query_service       -- main 注入；start 成功后只读。
local listen_fd           -- 当前监听 fd；nil 表示未监听或已停止。
local listen_context      -- start 等待 init/error 的一次性握手状态；保存 fd、等待协程和异步结果。
local queue               -- netpack 不透明 userdata；持有半包/完整包，首次分配或扩容后句柄可能被替换。
local stopping = false
local client_count = 0
local connections = {}    -- fd -> connection object；object identity 用于防止 fd 复用误写。

-- netpack queue 中保存的是 C 分配的消息块；Service 被 GC 时兜底释放尚未 pop 的包。
local queue_guard = setmetatable({}, {
    __gc = function()
        if queue ~= nil then
            netpack.clear(queue)
            queue = nil
        end
    end,
})

-- 仅用于保持 queue_guard 存活到 Service Lua State 结束。
assert(queue_guard)

-- 从 connections 移除当前连接，只执行一次 client_count 递减。
-- close_mode="close" 走主动正常关闭；"shutdown" 用于 socket error；"none" 表示底层已报告 CLOSE。
local function detach_connection(fd, reason, close_mode)
    local conn = connections[fd]
    if conn == nil then
        return nil
    end

    connections[fd] = nil
    conn.closed = true
    client_count = client_count - 1
    skynet.error("NAV_TCP_CLOSE fd=", fd,
                 " address=", conn.address or "?",
                 " reason=", reason or "unknown",
                 " clients=", client_count)

    if close_mode == "shutdown" then
        socketdriver.shutdown(fd)
    elseif close_mode == "close" then
        socketdriver.close(fd)
    end
    return conn
end

-- 关闭协议异常连接。调用方已经把 netpack C message 转成 Lua string，因此这里没有悬挂 msg ownership。
local function protocol_close(fd, reason)
    skynet.error("NAV_TCP_PROTOCOL_CLOSE fd=", fd, " reason=", reason)
    detach_connection(fd, reason, "close")
end

-- 发送一个响应 Envelope。netpack.pack 返回由 socketdriver.send 接管的 C buffer + size。
-- conn 必须仍是 connections[fd] 的同一个对象；这个检查防止旧请求协程在 fd 被复用后误写新连接。
local function send_response(conn, request_id, response)
    if connections[conn.fd] ~= conn or conn.closed then
        return false
    end

    local body = codec.encode_query_response(response)
    local envelope = codec.encode_envelope(
        config.query_cell_command,
        request_id,
        body,
        config.protocol_version)

    if #envelope == 0 or #envelope > config.max_frame_bytes then
        protocol_close(conn.fd, "response frame too large")
        return false
    end

    if not socketdriver.send(conn.fd, netpack.pack(envelope)) then
        detach_connection(conn.fd, "socket send failed", "shutdown")
        return false
    end
    return true
end

-- 处理一个已经由 netpack 完整切出的 payload。
-- netpack.tostring 会复制成 Lua string 并释放 msg 指针；必须在任何 yield/return 之前调用。
-- skynet.call 会 yield，因此 call 返回后必须重新验证 connections[fd] 仍指向同一 conn。
local function dispatch_packet(fd, msg, sz)
    local payload = netpack.tostring(msg, sz)
    local conn = connections[fd]
    if conn == nil or conn.closed or stopping then
        return
    end

    if #payload == 0 or #payload > config.max_frame_bytes then
        protocol_close(fd, "invalid frame size")
        return
    end
    if conn.inflight >= config.max_inflight_per_connection then
        protocol_close(fd, "too many in-flight requests")
        return
    end

    local envelope_ok, envelope = pcall(codec.decode_envelope, payload)
    if not envelope_ok then
        protocol_close(fd, "malformed envelope")
        return
    end
    if envelope.protocol_version ~= config.protocol_version then
        protocol_close(fd, "protocol version mismatch")
        return
    end
    if envelope.command ~= config.query_cell_command then
        protocol_close(fd, "unknown command")
        return
    end

    local request_ok, request = pcall(codec.decode_query_request, envelope.body)
    if not request_ok then
        protocol_close(fd, "malformed QueryCellRequest")
        return
    end

    conn.inflight = conn.inflight + 1
    local call_ok, response = pcall(
        skynet.call,
        query_service,
        "lua",
        "query_cell",
        request)
    conn.inflight = conn.inflight - 1

    -- call 期间本 Service 仍会处理 close/error/其他 socket 消息；fd 也可能随后被复用。
    if connections[fd] ~= conn or conn.closed then
        return
    end
    if not call_ok then
        skynet.error("NAV_QUERY_CALL_FAILED fd=", fd, " error=", response)
        protocol_close(fd, "query service call failed")
        return
    end

    send_response(conn, envelope.request_id, response)
end

local SOCKET = {}

-- netpack.filter 在一条 socket message 中得到一个完整包时直接派发到这里。
function SOCKET.data(fd, msg, sz)
    dispatch_packet(fd, msg, sz)
end

-- 一条 socket message 里可能形成多个完整包；netpack.pop 把当前包的 buffer ownership 交给处理协程。
-- queue 是整个 Gateway、跨所有 fd 共享的接入层队列；不能让一个连接的 skynet.call 阻塞其他连接。
-- fork 只登记一个续接协程，不会立刻并行执行。当前包一旦 yield，续接协程会读取最新全局 queue 继续 drain。
local function dispatch_queue()
    local fd, msg, sz = netpack.pop(queue)
    if fd == nil then
        return
    end

    -- 先安排 continuation，再处理可能 yield 的当前包；若当前包不 yield，下面的 for 会直接批量排空。
    skynet.fork(dispatch_queue)
    dispatch_packet(fd, msg, sz)

    -- 泛型 for 会保存进入循环时的 queue 引用。若循环体 yield 期间发生扩容，旧 queue 已被 C 模块
    -- 迁移并重置为空；续接协程使用新的全局 queue，因此不会重复 pop 或遗漏迁移后的包。
    for next_fd, next_msg, next_sz in netpack.pop, queue do
        dispatch_packet(next_fd, next_msg, next_sz)
    end
end

function SOCKET.more()
    dispatch_queue()
end

-- ACCEPT 事件。accepted fd 尚未 start；先建立 connection owner，再允许 socketdriver 投递 DATA。
function SOCKET.open(fd, address)
    if stopping then
        socketdriver.close(fd)
        return
    end
    if client_count >= config.max_clients then
        skynet.error("NAV_TCP_REJECT fd=", fd, " reason=max_clients address=", address)
        socketdriver.close(fd)
        return
    end

    local conn = {
        fd = fd,
        address = address,
        inflight = 0,
        closed = false,
    }
    connections[fd] = conn
    client_count = client_count + 1

    if config.tcp_nodelay then
        socketdriver.nodelay(fd)
    end
    socketdriver.start(fd)
    skynet.error("NAV_TCP_ACCEPT fd=", fd,
                 " address=", address,
                 " clients=", client_count)
end

-- CLOSE 事件到达时 netpack.filter 已清理该 fd 尚未完成的半包。
function SOCKET.close(fd)
    if fd == listen_fd then
        listen_fd = nil
        return
    end
    detach_connection(fd, "peer closed", "none")
end

-- ERROR 在 listen 启动阶段写入失败结果并唤醒 start 协程，否则 main 会永久等在 skynet.call(start)。
-- wakeup 不保存“提前通知”；这里能成功是因为本事件只能在 start 协程执行 wait 并 yield 后被当前 Service dispatch。
function SOCKET.error(fd, message)
    if listen_context ~= nil and fd == listen_context.fd then
        listen_context.error = message or "listen socket error"
        local co = listen_context.co
        listen_context.co = nil
        if co ~= nil then
            skynet.wakeup(co)
        end
        return
    end
    if fd == listen_fd then
        skynet.error("NAV_TCP_LISTEN_ERROR fd=", fd, " error=", message)
        listen_fd = nil
        return
    end
    detach_connection(fd, message or "socket error", "shutdown")
end

-- size 是 Skynet socket 层报告的待发送缓冲区 KB 数。
-- 慢客户端持续积压到阈值时主动断开，避免一个连接长期吃掉发送内存。
function SOCKET.warning(fd, size)
    skynet.error("NAV_TCP_WRITE_WARNING fd=", fd, " pending_kb=", size)
    if size >= config.write_warning_close_kb then
        detach_connection(fd, "write buffer overflow", "shutdown")
    end
end

-- socketdriver.listen 的异步成功结果通过 CONNECT/init 到达；记录实际绑定地址/端口并唤醒 start。
-- 同一个 Service Context 不会并行执行两条 Lua 协程，因此本函数不会抢在 start 建立 listen_context 之前重入。
function SOCKET.init(fd, address, port)
    if listen_context == nil or fd ~= listen_context.fd then
        return
    end
    listen_context.address = address
    listen_context.port = port
    local co = listen_context.co
    listen_context.co = nil
    if co ~= nil then
        skynet.wakeup(co)
    end
end

-- 停止接受新连接并关闭现有 client。它不直接 skynet.exit，便于未来由进程 Supervisor 统一编排退出。
local function stop_gateway()
    if stopping then
        return true
    end
    stopping = true

    if listen_fd ~= nil then
        socketdriver.close(listen_fd)
        listen_fd = nil
    end

    local fds = {}
    for fd in pairs(connections) do
        fds[#fds + 1] = fd
    end
    for _, fd in ipairs(fds) do
        detach_connection(fd, "gateway stopping", "close")
    end

    if queue ~= nil then
        netpack.clear(queue)
        queue = nil
    end
    skynet.error("NAV_TCP_STOPPED")
    return true
end

-- 启动监听并等待 socketdriver 的 init/error 事件确认 bind 结果。
-- query_address 是 main 注入的 Query Service handle；成功返回 true，失败抛错并使 main 的 skynet.call 失败。
-- 本函数执行 Socket I/O、修改 Service 私有启动状态，并在 skynet.wait 处 yield；不创建 OS Thread。
-- 从 listen 返回到 wait 登记 token 之间必须保持 no-yield，避免未来重构引入丢失通知窗口。
local function start_gateway(query_address)
    assert(query_service == nil, "navigation gateway already started")
    assert(config.max_frame_bytes > 0 and config.max_frame_bytes <= 0xffff,
           "netpack frame limit must fit uint16")
    assert(config.max_clients > 0, "max_clients must be positive")
    assert(config.max_inflight_per_connection > 0,
           "max_inflight_per_connection must be positive")

    query_service = assert(query_address, "query service address is required")
    -- descriptor 与协议源一起从 shared/ 发布，运行期不从 Unity 工作目录读取。
    codec.load_descriptor(config.protocol_descriptor)

    -- listen 只同步返回 Skynet Socket ID；bind/listen 的异步成功或失败分别由 init/error 报告。
    local fd = socketdriver.listen(config.host, config.port, config.backlog)
    assert(fd and fd >= 0, "cannot create navigation listen socket")

    -- 当前消息协程在调用 wait 前不会 yield。同一 Service 即使已经收到 init 消息，也只会先把它排队；
    -- skynet.wait 会先登记 sleep_session[token] 再 yield，之后 SOCKET.init/error 才可能执行并成功 wakeup。
    listen_fd = fd
    listen_context = {
        fd = fd,
        co = coroutine.running(),
    }

    skynet.wait(listen_context.co)

    -- 局部变量保留本次握手结果；清空共享上下文后，后续 error 将按运行期监听错误处理。
    local started = listen_context
    listen_context = nil
    if started.error ~= nil then
        listen_fd = nil
        error("navigation listen failed: " .. tostring(started.error))
    end

    -- 只有 bind/listen 已确认成功，才允许监听 Socket 开始上报新客户端的 open 事件。
    socketdriver.start(fd)
    skynet.error("NAV_TCP_READY ", started.address or config.host,
                 ":", started.port or config.port,
                 " query=", skynet.address(query_service),
                 " framing=netpack-u16be",
                 " max_frame=", config.max_frame_bytes)
    return true
end

-- 直接注册 PTYPE_SOCKET。netpack.filter 负责 TCP 半包/粘包，业务层只接触完整 Envelope payload。
skynet.register_protocol {
    name = "socket",
    id = skynet.PTYPE_SOCKET,
    unpack = function(msg, sz)
        return netpack.filter(queue, msg, sz)
    end,
    dispatch = function(_session, _source, updated_queue, event, arg1, arg2, arg3)
        -- filter 的第一个返回值是最新 userdata：可能仍是原对象，也可能因首次分配/扩容而替换。
        -- 必须先写回再处理 more；赋值不会清空数据，ownership 迁移已经由 netpack C 模块完成。
        queue = updated_queue
        if event == nil then
            return
        end
        if event == "init" then
            SOCKET.init(arg1, arg2, arg3)
        elseif event == "open" then
            SOCKET.open(arg1, arg2)
        elseif event == "data" then
            SOCKET.data(arg1, arg2, arg3)
        elseif event == "more" then
            SOCKET.more()
        elseif event == "close" then
            SOCKET.close(arg1)
        elseif event == "error" then
            SOCKET.error(arg1, arg2)
        elseif event == "warning" then
            SOCKET.warning(arg1, arg2)
        else
            error("unknown socket event: " .. tostring(event))
        end
    end,
}

skynet.start(function()
    -- Debug-only: normal start does nothing; LUA_PANDA_ENABLE=1 enables this Lua State target.
    luapanda_debug.start("gateway")

    skynet.dispatch("lua", function(_session, _source, command, argument)
        if command == "start" then
            skynet.retpack(start_gateway(argument))
            return
        end
        if command == "stop" then
            assert(argument == nil, "stop does not accept an argument")
            skynet.retpack(stop_gateway())
            return
        end
        error("unknown navigation_gateway command: " .. tostring(command))
    end)
end)
