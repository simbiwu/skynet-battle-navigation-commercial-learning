--- 职责：组装第一课单进程 Query/Gateway，并承担两者间的本地异步数据转发。
--- 边界：宿主 Bootstrap/Adapter Service；不解析网络、不实现地图查询或战斗规则。
--- 输入/输出：Gateway 已解码 send_data -> QueryCell 调用 -> Gateway send_data。
--- 生命周期：保存显式 Service handles，随进程存活；查询 call 可能 yield。
--- 不负责：不持有 fd、动态占位或业务等待表，不让 Query 依赖 Gateway。
local skynet = require "skynet"
local registry = require "gateway.protocol.navigation_registry"
local query_service = nil
local gateway_service = nil

--- 接收可信本地 Gateway 的通知；数据 record 在本次调用内持有。
--- query_cell 调用会 yield；返回后仍回送原连接身份，迟到消息由 Gateway 拒绝。
---@param source integer 实际发送 Service；必须等于已注入 Gateway handle。
---@param command string send_data 或 gateway_disconnect；不接受其它控制命令。
---@param payload table 已解码 record；本函数只读，不跨请求缓存。
local function dispatch(source, command, payload)
    assert(source == gateway_service, "untrusted local gateway source")
    if command == "gateway_disconnect" then
        --- Gateway 已清理连接，本 Adapter 没有连接状态需要释放。
        return
    end
    assert(command == "send_data", "unknown local gateway command")
    assert(type(payload) == "table" and
        payload.command_id == registry.command_ids.QUERY_CELL,
        "local navigation adapter only accepts QueryCell")

    local response = skynet.call(query_service, "lua", "query_cell",
    {
        request = payload.data,
    })
    --- 直接传递 Proto Response record，不能额外包装成 {ok,response}。
    skynet.send(gateway_service, "lua", "send_data",
    {
        gateway_epoch = payload.gateway_epoch,
        connection_id = payload.connection_id,
        command_id    = payload.command_id,
        request_id    = payload.request_id,
        data          = response,
    })
end

--- 先创建 Query、注册 Adapter，再启动监听；避免 Gateway 就绪时尚无查询依赖。
skynet.start(function()
    skynet.name(".nav_handler", skynet.self())
    query_service = skynet.newservice("battle/navigation_query")
    assert(skynet.call(query_service, "lua", "ready"))
    skynet.dispatch("lua", function(_session, source, command, payload)
        dispatch(source, command, payload)
    end)
    gateway_service = skynet.newservice("flywow_gateway")
    assert(skynet.call(gateway_service, "lua", "start",
    {
        handler_service = ".nav_handler",
    }))
    skynet.error("NAV_SERVER_READY query=", skynet.address(query_service),
        " gateway=", skynet.address(gateway_service))
end)
