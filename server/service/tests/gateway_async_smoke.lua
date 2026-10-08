--- 职责：真实TCP/WS中验证send_data、乱序响应、广播、编码失败和close。
--- 边界：Integration Test Service；以协议已有map_id作为测试标记，不增加协议字段。
--- 生命周期：runner独占启动回收；Gateway_disconnect仅作连接生命周期通知，无业务回复。
local skynet = require "skynet"
skynet.start(function()
    skynet.name(".gw_async_smoke", skynet.self())
    skynet.dispatch("lua", function(_session, source, command, message)
        if command == "gateway_disconnect" then return end
        assert(command == "send_data", "gateway data command is required")
        assert(type(message) == "table" and type(message.data) == "table")
        local marker = message.data.map_id
        if marker == 1 then skynet.sleep(50) end
        if marker == 600 then
            skynet.send(source, "lua", "close",
            {
                gateway_epoch = message.gateway_epoch, connection_id = message.connection_id,
            })
            return
        end
        local response = { result = marker == 5 and 7 or 1, map_id = marker }
        if marker == 3 then response.result = {} end
        skynet.send(source, "lua", "send_data",
        {
            gateway_epoch = message.gateway_epoch, connection_id = message.connection_id,
            command_id = message.command_id, data = response,
            request_id = message.request_id,
        })
        if marker == 4 then
            skynet.send(source, "lua", "send_data",
            {
                gateway_epoch = message.gateway_epoch, connection_id = 0,
                command_id = message.command_id, data = { result = 1, map_id = 400 },
                request_id = 0,
            })
        elseif marker == 601 then
            skynet.send(source, "lua", "close",
            {
                gateway_epoch = message.gateway_epoch, connection_id = message.connection_id,
            })
        end
    end)
    for index, transport in ipairs({ "tcp", "websocket" }) do
        local gateway = skynet.newservice("flywow_gateway")
        skynet.call(gateway, "lua", "start",
        {
            handler_service = ".gw_async_smoke", transport = transport, port = 19020 + index,
            read_timeout_ticks = 100, idle_timeout_ticks = 200,
            max_clients = 8, write_warning_close_kb = 64,
            max_pending_handshakes = 2, handshake_timeout_ticks = 100,
        })
    end
    skynet.error("GATEWAY_ASYNC_SMOKE_READY")
end)
