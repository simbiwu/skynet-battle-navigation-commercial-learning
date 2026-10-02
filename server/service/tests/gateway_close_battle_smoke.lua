-- 职责：验证独立业务进程通过项目 Proxy 主动关闭客户端连接。
-- 边界：Integration Test Service；使用真实 Cluster 和 FlyWow endpoint，不接触 fd。
-- 输入/输出：编号600请求 -> gateway_close；其他请求 -> 合法 QueryCellResponse。
-- 生命周期：由集成 runner 独占启动与终止，不进入正常 Battle 启动树。
-- 不负责：不查询地图、不执行业务结算，不替代账号鉴权或生产控制接口。
local skynet = require "skynet"
local cluster = require "skynet.cluster"
local endpoint = require "gateway.endpoint"
local process = require "config.battle"

-- 注册测试 Cluster 业务入口；节点信息归项目，FlyWow 不选择本地/远程发送方式。
skynet.start(function()
    cluster.reload({ [process.cluster.gateway_node] = process.cluster.gateway_address })
    cluster.open(process.cluster.local_listen, process.cluster.max_clients)
    cluster.register(process.cluster.service_name, skynet.self())
    -- 固定签名处理 ready 和请求；项目注入 send/close，业务只调用 reply/close。
    skynet.dispatch("lua", function(session, source, command, payload)
        if command == "ready" then skynet.retpack(true); return end
        assert(command == "gateway_dispatch" and session == 0)
        local context = endpoint.new({
            request = payload,
            -- 返回函数把响应发回课程 Proxy；token 仅由项目适配器处理。
            send = function(message)
                cluster.send(process.cluster.gateway_node, "@" .. process.cluster.gateway_proxy_service,
                             "battle_result", payload.route_token, { ok = true, response = message.response })
                return true
            end,
            -- 关闭函数原样转发网络身份，成功不表示客户端已收到关闭帧。
            close = function(message)
                cluster.send(process.cluster.gateway_node, "@" .. process.cluster.gateway_proxy_service,
                             "gateway_close", message)
                return true
            end,
        })
        if payload.request_id == 600 then assert(context:close())
        else assert(context:reply({ result = 1 })) end
    end)
    skynet.error("GATEWAY_CLOSE_BATTLE_SMOKE_READY")
end)
