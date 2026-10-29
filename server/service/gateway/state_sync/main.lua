--- 职责：State Gateway 进程启动入口；依赖 Ready 的 Battle 后才监听客户端。
--- 边界：网络接入；不加载 Battle Native 或地图。
--- 输入/输出：监听配置 -> FlyWow TCP/Protobuf 长连接服务。
local skynet = require "skynet"
local gateway_state_sync_config = require "config.gateway_state_sync"

--- 检查子 Service 操作结果；失败时记录具体错误并终止 Gateway Runtime。
---@param operation_result FlyWowResult<any> 子 Service 的 RPC 结果。
---@param operation_name string 启动操作名，用于日志诊断。
---@return any|nil 成功返回 value；失败时调用 skynet.abort。
local function require_success(operation_result, operation_name)
    if type(operation_result) ~= "table" or operation_result.ok ~= true then
        local error_code = type(operation_result) == "table" and operation_result.code or "INVALID_RESULT"
        local error_message = type(operation_result) == "table" and operation_result.message or "missing FlyWowResult"
        skynet.error("STATE_GATEWAY_START_FAILED ", operation_name, " code=", error_code,
            " message=", error_message)
        skynet.abort()
        return nil
    end
    return operation_result
end

skynet.start(function()
    local proxy = skynet.newservice("gateway/state_sync/proxy")
    if not require_success(skynet.call(proxy, "lua", "start"), "start state proxy") then return end

    local gateway = skynet.newservice("flywow_gateway")
    local binding_result = skynet.call(proxy, "lua", "bind", { gateway = gateway })
    if not require_success(binding_result, "bind state Gateway") then return end

    local gateway_options = {}
    for key, value in pairs(gateway_state_sync_config) do
        gateway_options[key] = value
    end
    gateway_options.handler_service = ".state_proxy"

    local gateway_result = skynet.call(gateway, "lua", "start", gateway_options)
    local started_gateway = require_success(gateway_result, "start FlyWow Gateway")
    if not started_gateway then return end
    local gateway_info = started_gateway.value

    local shutdown_coordinator = skynet.newservice("admin/lesson3_shutdown_coordinator")
    local configure_result = skynet.call(
        shutdown_coordinator,
        "lua",
        "configure",
        {
            profile = "state_sync",
            role = "gateway",
            endpoint = "state_gateway_shutdown",
            gateway = gateway,
            proxy = proxy,
        }
    )
    if not require_success(configure_result, "configure shutdown coordinator") then return end

    if not skynet.call(shutdown_coordinator, "lua", "ready") then
        skynet.error("STATE_GATEWAY_START_FAILED shutdown coordinator is not ready")
        skynet.abort()
        return
    end

    skynet.error("STATE_GATEWAY_READY port=", gateway_state_sync_config.port)
    skynet.exit()
end)
