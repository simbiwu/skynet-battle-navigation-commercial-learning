--- 职责：本机 benchmark 的有界响应夹具，回显请求 map_id 标记。
--- 边界：测试 Service；不加载地图或执行 Battle，Gateway 保留真实编解码与握手。
--- 生命周期：仅由 runner 启动并回收；统计每5秒采样，不记录逐请求日志。
local skynet = require "skynet.manager"
local gateway
local active_connections = {}
local request_count = 0
local response_count = 0
skynet.start(function()
    skynet.name(".gw_benchmark", skynet.self())
    skynet.dispatch("lua", function(_session, source, command, message)
        if command == "gateway_disconnect" then
            active_connections[message.connection_id] = nil
            return
        end
        assert(command == "send_data")
        active_connections[message.connection_id] = true
        request_count = request_count + 1
        if message.data.map_id == 0xFFFFFFFE then
            --- 只在所有自然测量与周转结束后由runner调用；强制GC不计入吞吐或正常释放指标。
            skynet.send(source, "lua", "close",
            {
                gateway_epoch = message.gateway_epoch, connection_id = message.connection_id,
            })
            skynet.sleep(20)
            local active_count = 0
            for _ in pairs(active_connections) do
                active_count = active_count + 1
            end
            assert(active_count == 0, "GC diagnostic requires all benchmark clients to disconnect")
            local before = skynet.call(gateway, "debug", "MEM")
            skynet.send(gateway, "debug", "GC")
            skynet.sleep(50)
            local after = skynet.call(gateway, "debug", "MEM")
            skynet.error(string.format("BENCH_GC_DIAGNOSTIC handler_connections=%d before_lua_kib=%.1f after_lua_kib=%.1f",
                active_count, before, after))
            return
        end
        response_count = response_count + 1
        skynet.send(source, "lua", "send_data",
        {
            gateway_epoch = message.gateway_epoch,
            connection_id = message.connection_id,
            command_id = message.command_id,

            data = { result = 1, map_id = message.data.map_id },
        })
    end)
    gateway = skynet.newservice("flywow_gateway")
    local start_result = skynet.call(gateway, "lua", "start",
    {
        handler_service = ".gw_benchmark",
        transport = skynet.getenv("bench_transport") or "tcp",
        port = 19131,
        max_clients = 8192,
        max_pending_handshakes = 128,
        read_timeout_ticks = 360000,
        idle_timeout_ticks = 360000,
        max_requests_per_second = 200,
        max_total_requests_per_second = 30000,
    })
    assert(start_result.ok, start_result.message)
    skynet.error("GATEWAY_BENCHMARK_READY")
    skynet.fork(function()
        while true do
            skynet.sleep(500)
            local active_count = 0
            for _ in pairs(active_connections) do
                active_count = active_count + 1
            end
            local lua_kib = skynet.call(gateway, "debug", "MEM")
            local handler_kib = collectgarbage("count")
            skynet.error(string.format("BENCH_STATS handler_connections=%d requests=%d responses=%d lua_kib=%.1f handler_kib=%.1f",
                active_count, request_count, response_count, lua_kib, handler_kib))
            request_count = 0
            response_count = 0
        end
    end)
end)
