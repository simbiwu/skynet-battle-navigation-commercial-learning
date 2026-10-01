-- 职责：在真实 Skynet 中提供延迟响应测试 handler，并启动 TCP/WS Gateway。
-- 边界：Integration Test Service；只使用 FlyWow 公开 API，不接触网络 fd。
-- 输入/输出：QueryCell 请求编号 -> 可控制延迟的合法响应；19021/19022 为专用测试端口。
-- 生命周期：测试 runner 独占进程，退出时由 runner 回收；不在正常 Server 启动树使用。
-- 不负责：不加载地图、不模拟 Battle、不把此 handler 用于生产。
local skynet = require "skynet"
local endpoint = require "flywow.gateway.endpoint"

-- 注册测试处理并启动两个独立 Gateway；管理调用可能 yield。
skynet.start(function()
    -- 接收异步请求；A 睡眠时 B 可运行，编号3返回编码错误，编号4推送，编号5模拟业务失败。
    -- source 是实际 Gateway handle；context 不保存 fd；sleep 会 yield，回复不等待客户端。
    skynet.dispatch("lua", function(session, source, command, payload)
        if command == "gateway_disconnect" then return end
        assert(command == "gateway_dispatch" and session == 0)
        local context = endpoint.new({ gateway_service = source, request = payload })
        if payload.request_id == 1 then skynet.sleep(50) end
        if payload.request_id == 600 then
            assert(context:close())
            return
        end
        if payload.request_id == 601 then
            assert(context:reply({ result = 1 }))
            assert(context:close())
            return
        end
        if payload.request_id == 3 then
            context:reply({ result = "not_an_enum" })
            return
        end
        context:reply({ result = payload.request_id == 5 and 7 or 1, map_id = payload.request.map_id })
        if payload.request_id == 4 then
            local push = {}
            for key, value in pairs(payload) do push[key] = value end
            push.request_id = 0
            endpoint.new({ gateway_service = source, request = push }):reply({ result = 1 })
        end
    end)
    for index, transport in ipairs({ "tcp", "websocket" }) do
        local gateway = skynet.newservice("flywow_gateway")
        skynet.call(gateway, "lua", "start", {
            handler_service = skynet.self(), transport = transport, port = 19020 + index,
            read_timeout_ticks = 100, idle_timeout_ticks = 200, max_clients = 8,
            write_warning_close_kb = 64, max_pending_handshakes = 2, handshake_timeout_ticks = 100,
        })
    end
    skynet.error("GATEWAY_ASYNC_SMOKE_READY")
end)
