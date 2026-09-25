-- 职责：监听 TCP、处理长度帧和 Protobuf，并把合法 QueryCell 转发给 Query Service。
-- 边界：Skynet Gateway Service；拥有 listen fd 和每连接 client coroutine。
-- 输入/输出：TCP bytes -> QueryCell request -> TCP response bytes。
-- 生命周期：由 main 创建；start 消息只允许执行一次，连接 fd 在退出路径关闭。
-- 不负责：不加载 BMAP、不直接调用 Native、不保存战斗状态。
local skynet = require "skynet"
local socket = require "skynet.socket"
local config = require "config.game"
local frame = require "network.length_frame"
local codec = require "protocol.navigation_codec"

local query_service -- main 注入的 Query Service 地址；start 成功后只读。
local listen_fd     -- Gateway 持有的监听 fd；Service 退出时由 Skynet 回收。

-- 编码响应并写入 fd；request_id 来自当前请求，fd 仍由 client_loop 独占。
local function send_response(fd, request_id, response)
    local body = codec.encode_query_response(response)
    local envelope = codec.encode_envelope(
        config.query_cell_command, request_id, body, config.protocol_version)
    socket.write(fd, frame.pack(envelope, config.max_frame_bytes))
end

-- 独占一个已 accept 的 fd，处理半包/粘包和多请求连接。
-- socket.read 与 skynet.call 会 yield；yield 前不保留可被其他协程修改的业务状态。
local function client_loop(fd)
    assert(socket.start(fd), "cannot start accepted socket")
    local buffer = "" -- 当前连接尚未消费的 bytes，只归本协程所有。

    while true do
        local chunk = socket.read(fd)
        if not chunk then
            break
        end
        buffer = buffer .. chunk

        while true do
            local payload, rest = frame.unpack(buffer, config.max_frame_bytes)
            if payload == false then
                skynet.error("NAV_TCP_BAD_FRAME fd=", fd, " error=", rest)
                socket.close(fd)
                return
            end
            if payload == nil then
                buffer = rest
                break
            end
            buffer = rest

            local envelope_ok, envelope = pcall(codec.decode_envelope, payload)
            if not envelope_ok or
               envelope.protocol_version ~= config.protocol_version or
               envelope.command ~= config.query_cell_command then
                socket.close(fd)
                return
            end

            local request_ok, request = pcall(codec.decode_query_request, envelope.body)
            if not request_ok then
                socket.close(fd)
                return
            end

            -- 这里是 Gateway 与 Query 两个 Service 的明确边界；call 会 yield。
            local response = skynet.call(query_service, "lua", "query_cell", request)
            send_response(fd, envelope.request_id, response)
        end
    end

    socket.close(fd)
end

-- 启动监听并保存 Query Service 地址；由 main 通过 skynet.call 调用一次。
-- query_address 必须是有效 Service handle；成功返回 true，失败直接抛错。
local function start(query_address)
    assert(query_service == nil, "navigation gateway already started")
    query_service = assert(query_address, "query service address is required")
    codec.load_descriptor("protocol/generated/server/navigation_query.pb")

    listen_fd = assert(socket.listen(config.host, config.port))
    assert(socket.start(listen_fd, function(fd, address)
        skynet.error("NAV_TCP_ACCEPT fd=", fd, " address=", address)
        skynet.fork(client_loop, fd)
    end))
    skynet.error("NAV_TCP_READY ", config.host, ":", config.port,
                 " query=", skynet.address(query_service))
    return true
end

-- 先安装 dispatch，再等待 main 注入依赖；Service 之间只传地址和请求副本。
skynet.start(function()
    skynet.dispatch("lua", function(_, _, command, ...)
        if command == "start" then
            skynet.retpack(start(...))
            return
        end
        error("unknown navigation_gateway command: " .. tostring(command))
    end)
end)
