-- 职责：验证独立 Battle 进程通过 send_data/close 控制 Gateway 连接。
-- 边界：Integration Test Service；只使用 Cluster 和统一 Gateway 消息合同。
-- 输入/输出：测试请求 data -> send_data 响应或 close；不接触 fd。
-- 生命周期：由集成 runner 独占启动与终止，不进入正常 Battle 启动树。
-- 不负责：不查询地图、不执行业务结算，不替代账号鉴权或生产控制接口。

local skynet = require "skynet"
local cluster = require "skynet.cluster"
local process = require "config.battle"

skynet.start(function()
    cluster.reload({ [process.cluster.gateway_node] = process.cluster.gateway_address })
    cluster.open(process.cluster.local_listen, process.cluster.max_clients)
    cluster.register(process.cluster.service_name, skynet.self())

    skynet.dispatch("lua", function(_session, _source, command, message)
        if command == "ready" then
            skynet.retpack(true)
            return
        end

        assert(command == "send_data", "gateway data command is required")
        assert(type(message) == "table" and type(message.data) == "table",
            "gateway data message is required")

        local target = "@" .. process.cluster.gateway_proxy_service
        if message.data.map_id == 600 then
            cluster.send(
                process.cluster.gateway_node,
                target,
                "close",
                {
                    gateway_epoch = message.gateway_epoch,
                    connection_id = message.connection_id,
                }
            )
            return
        end

        cluster.send(
            process.cluster.gateway_node,
            target,
            "send_data",
            {
                gateway_epoch = message.gateway_epoch,
                connection_id = message.connection_id,
                request_id = message.request_id,
                command_id = message.command_id,
                data = { result = 1, map_id = message.data.map_id },
            }
        )
    end)

    skynet.error("GATEWAY_CLOSE_BATTLE_SMOKE_READY")
end)
