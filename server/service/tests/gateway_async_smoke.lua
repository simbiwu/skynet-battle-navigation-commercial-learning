-- 职责：在真实 Skynet 中验证统一 send_data 转发、主动下发和 close。
-- 边界：Integration Test Service；只使用 FlyWow 的 Service 消息合同，不接触 fd。
-- 输入/输出：测试请求 data -> send_data 响应、广播或 close；端口由测试配置提供。
-- 生命周期：测试 runner 独占启动并回收；不进入正常 Server 启动树。
-- 不负责：不加载地图、不模拟 Battle、不判断业务结果。

local skynet = require "skynet"

skynet.start(function()
    skynet.dispatch("lua", function(_session, source, command, message)
        assert(command == "send_data", "gateway data command is required")
        assert(type(message) == "table" and type(message.data) == "table",
            "gateway data message is required")

        local test_id = message.data.test_id
        if test_id == 1 then
            skynet.sleep(50)
        end

        if test_id == 600 then
            skynet.send(source, "lua", "close",
            {
                gateway_epoch = message.gateway_epoch,
                connection_id = message.connection_id,
            })
            return
        end

        skynet.send(source, "lua", "send_data",
        {
            gateway_epoch = message.gateway_epoch,
            connection_id = message.connection_id,
            command_id = message.command_id,
            data =
            {
                result = test_id == 5 and 7 or 1,
                map_id = message.data.map_id,
            },
        })

        if test_id == 4 then
            skynet.send(source, "lua", "send_data",
            {
                gateway_epoch = message.gateway_epoch,
                connection_id = 0,
                command_id = message.command_id,
                data = { result = 1 },
            })
        end
    end)

    for index, transport in ipairs({ "tcp", "websocket" }) do
        local gateway = skynet.newservice("flywow_gateway")
        skynet.call(gateway, "lua", "start",
        {
            handler_service = skynet.self(),
            transport = transport,
            port = 19020 + index,
            read_timeout_ticks = 100,
            idle_timeout_ticks = 200,
            max_clients = 8,
            write_warning_close_kb = 64,
            max_pending_handshakes = 2,
            handshake_timeout_ticks = 100,
        })
    end

    skynet.error("GATEWAY_ASYNC_SMOKE_READY")
end)
