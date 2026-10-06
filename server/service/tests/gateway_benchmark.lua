--- 职责：本机 benchmark 的有界响应夹具，回显请求 map_id 标记。
--- 边界：测试 Service；不加载地图或执行 Battle，Gateway 保留真实编解码与握手。
--- 生命周期：仅由 runner 启动并回收；统计每5秒采样，不记录逐请求日志。
local skynet = require "skynet"
local gateway
skynet.start(function()
    skynet.dispatch("lua", function(_session, source, command, message)
        if command == "gateway_disconnect" then
            return
        end
        assert(command == "send_data")
        if message.data.map_id == 0xFFFFFFFE then
            --- 只在所有自然测量与周转结束后由runner调用；强制GC不计入吞吐或正常释放指标。
            skynet.send(source, "lua", "close",
            {
                gateway_epoch = message.gateway_epoch, connection_id = message.connection_id,
            })
            skynet.sleep(20)
            local stats = skynet.call(gateway, "lua", "stats")
            assert(stats.clients == 0, "GC diagnostic requires no clients")
            local before = skynet.call(gateway, "debug", "MEM")
            skynet.send(gateway, "debug", "GC")
            skynet.sleep(50)
            local after = skynet.call(gateway, "debug", "MEM")
            skynet.error(string.format("BENCH_GC_DIAGNOSTIC clients=%d before_lua_kib=%.1f after_lua_kib=%.1f",
                stats.clients, before, after))
            return
        end
        skynet.send(source, "lua", "send_data",
        {
            gateway_epoch = message.gateway_epoch,
            connection_id = message.connection_id,
            command_id = message.command_id,
            request_id = message.request_id,
            data = { result = 1, map_id = message.data.map_id },
        })
    end)
    gateway = skynet.newservice("flywow_gateway")
    skynet.call(gateway, "lua", "start",
    {
        handler_service = skynet.self(),
        transport = skynet.getenv("bench_transport") or "tcp",
        port = 19131,
        max_clients = 8192,
        max_pending_handshakes = 128,
        read_timeout_ticks = 360000,
        idle_timeout_ticks = 360000,
        max_requests_per_second = 200,
        max_total_requests_per_second = 30000,
    })
    skynet.error("GATEWAY_BENCHMARK_READY")
    skynet.fork(function()
        while true do
            skynet.sleep(500)
            local stats = skynet.call(gateway, "lua", "stats")
            local lua_kib = skynet.call(gateway, "debug", "MEM")
            local handler_kib = collectgarbage("count")
            skynet.error(string.format("BENCH_STATS clients=%d sent=%d dropped=%d lua_kib=%.1f handler_kib=%.1f",
                stats.clients, stats.responses_sent, stats.responses_dropped, lua_kib, handler_kib))
        end
    end)
end)
