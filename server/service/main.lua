--- 职责：组装第一课单进程 Query/Gateway，并承担两者间的本地异步数据转发。
--- 边界：宿主 Bootstrap/Adapter Service；不解析网络、不实现地图查询或战斗规则。
--- 输入/输出：Gateway 已解码 send_data -> QueryCell 调用 -> Gateway send_data。
--- 生命周期：保存显式 Service handles，随进程存活；查询 call 可能 yield。
--- 不负责：不持有 fd、动态占位或业务等待表，不让 Query 依赖 Gateway。
local skynet = require "skynet.manager"
local flywow_result = require "flywow_result"
local protocol_registry = require "gateway.protocol.protocol_registry_lesson_01"
local gateway_startup_config = require "config.gateway_lesson_01"

local module_state =
{
    query_service_handle   = nil, -- 主进程唯一的导航查询 Service handle，启动时注入。
    gateway_service_handle = nil, -- 本地 Gateway Service handle，启动完成后供 Adapter 转发。
}

--- 转发可信 Gateway 的 QueryCell 请求，并把原连接身份带回响应。
---@param source integer 实际发送 Service；必须等于已注入 Gateway handle。
---@param command string Gateway 的 send_data 或 gateway_disconnect 命令。
---@param payload table|nil Gateway 解码后的 record；本函数只读取并转发，不跨请求保存。
---@return FlyWowResult<nil> 转发成功返回 success；来源、命令、消息或 Query RPC 无效时返回稳定错误。
local function dispatch(source, command, payload)
    if source ~= module_state.gateway_service_handle then
        return flywow_result.failure("NAV_GATEWAY_SOURCE_INVALID", "untrusted local Gateway source")
    end
    if command == "gateway_disconnect" then
        return flywow_result.success()
    end
    if command ~= "send_data" then
        return flywow_result.failure("NAV_GATEWAY_COMMAND_INVALID", "unknown local Gateway command")
    end
    if type(payload) ~= "table" or payload.command_id ~= protocol_registry.command_ids.QUERY_CELL or
        type(payload.data) ~= "table" then
        return flywow_result.failure("NAV_GATEWAY_REQUEST_INVALID", "only a decoded QueryCell request is accepted")
    end

    -- Query Service 的本地 RPC 可能因 Service 退出而抛错；将失败转换为 Adapter 结果。
    local query_ok, response = pcall(
        skynet.call,
        module_state.query_service_handle,
        "lua",
        "query_cell",
        {
            request = payload.data,
        }
    )
    if not query_ok then
        return flywow_result.failure("NAV_QUERY_CALL_FAILED", tostring(response))
    end

    -- 返回的 response 是业务 Proto record；不要外包成 FlyWowResult 以免改变协议字段。
    local delivery_accepted = skynet.send(
        module_state.gateway_service_handle,
        "lua",
        "send_data",
        {
            gateway_epoch = payload.gateway_epoch,
            connection_id = payload.connection_id,
            command_id    = payload.command_id,
            request_id    = payload.request_id,
            data          = response,
        }
    )
    if delivery_accepted == nil then
        return flywow_result.failure("NAV_GATEWAY_RESPONSE_DELIVERY_FAILED", "Skynet rejected Gateway response")
    end
    return flywow_result.success()
end

--- 先启动 Query 并确认 ready，再启动 FlyWow Gateway，避免端口早于查询依赖就绪。
skynet.start(function()
    skynet.name(".nav_handler", skynet.self())
    module_state.query_service_handle = skynet.newservice("battle/navigation_query")
    if skynet.call(module_state.query_service_handle, "lua", "ready") ~= true then
        skynet.error("NAV_SERVER_START_FAILED Query Service is not ready")
        skynet.abort()
        return
    end

    skynet.dispatch("lua", function(session, source, command, payload)
        local dispatch_result = dispatch(source, command, payload) -- 当前 Gateway 通知的转发结果。
        if session ~= 0 then
            skynet.retpack(dispatch_result)
        elseif not dispatch_result.ok then
            skynet.error("NAV_GATEWAY_DISPATCH_FAILED ", dispatch_result.code, " ", dispatch_result.message)
        end
    end)

    module_state.gateway_service_handle = skynet.newservice("flywow_gateway")
    local gateway_start_config = {}
    for key, value in pairs(gateway_startup_config) do
        gateway_start_config[key] = value
    end
    gateway_start_config.handler_service = ".nav_handler"

    local start_result = skynet.call(
        module_state.gateway_service_handle,
        "lua",
        "start",
        gateway_start_config
    )
    if type(start_result) ~= "table" or not start_result.ok then
        local error_code = type(start_result) == "table" and start_result.code or "INVALID_RESULT"
        local error_message = type(start_result) == "table" and start_result.message or "missing FlyWowResult"
        skynet.error("NAV_SERVER_START_FAILED Gateway code=", error_code, " message=", error_message)
        skynet.abort()
        return
    end

    skynet.error(
        "NAV_SERVER_READY query=",
        skynet.address(module_state.query_service_handle),
        " gateway=",
        skynet.address(module_state.gateway_service_handle)
    )
end)
