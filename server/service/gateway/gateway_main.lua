-- 职责：组装 Lesson 2 Gateway Process，把 FlyWow 接入层绑定到远程 Battle Proxy。
-- 边界：Server Runtime Composition Root；拥有子 Service 启动顺序与 handle 注入。
-- 输入/输出：Lesson 2 配置 -> 已监听 Gateway 和 READY 日志。
-- 生命周期：启动时创建子 Service；本入口完成接线后退出。
-- 不负责：不保存连接、不解析协议、不加载地图、不执行 Battle 业务。
local skynet = require "skynet"
local gateway_lesson_config = require "config.gateway_lesson_02"

--- 检查子 Service 的操作结果；启动失败会记录诊断并终止当前 Skynet Runtime。
---@param operation_result FlyWowResult<any> 子 Service 通过 Lua RPC 返回的结果 record。
---@param operation_name string 当前失败操作的名称，供启动日志定位。
---@return any|nil 成功时返回 value；失败时调用 skynet.abort 终止进程。
local function require_success(operation_result, operation_name)
    if type(operation_result) ~= "table" or operation_result.ok ~= true then
        local error_code = type(operation_result) == "table" and operation_result.code or "INVALID_RESULT"
        local error_message = type(operation_result) == "table" and operation_result.message or "missing FlyWowResult"
        skynet.error("GATEWAY_PROCESS_START_FAILED ", operation_name, " code=", error_code,
            " message=", error_message)
        skynet.abort()
        return nil
    end
    return operation_result
end

skynet.start(function()
    -- Proxy 先确认远程 Battle ready，Gateway 随后才会绑定客户端端口。
    local proxy_service = skynet.newservice("gateway/gateway_proxy")
    local proxy_start = skynet.call(proxy_service, "lua", "start", gateway_lesson_config)
    if not require_success(proxy_start, "start gateway proxy") then return end

    local gateway_service = skynet.newservice("flywow_gateway")
    local binding_result = skynet.call(
        proxy_service,
        "lua",
        "bind_gateway",
        { gateway_service = gateway_service }
    )
    if not require_success(binding_result, "bind Gateway Service") then return end

    -- FlyWow Gateway 使用复制后的配置，额外注入已注册的业务 handler 名。
    local gateway_options = {}
    for key, value in pairs(gateway_lesson_config) do
        gateway_options[key] = value
    end
    gateway_options.handler_service = ".gateway_proxy"

    local gateway_result = skynet.call(gateway_service, "lua", "start", gateway_options)
    local started_gateway = require_success(gateway_result, "start FlyWow Gateway")
    if not started_gateway then return end
    local gateway = started_gateway.value

    local shutdown_coordinator = skynet.newservice("gateway/shutdown_coordinator")
    local configure_result = skynet.call(
        shutdown_coordinator,
        "lua",
        "configure",
        {
            gateway_service = gateway_service,
            proxy_service = proxy_service,
        }
    )
    if not require_success(configure_result, "configure shutdown coordinator") then return end

    if not skynet.call(shutdown_coordinator, "lua", "ready") then
        skynet.error("GATEWAY_PROCESS_START_FAILED shutdown coordinator is not ready")
        skynet.abort()
        return
    end

    skynet.error(
        "LESSON2_GATEWAY_PROCESS_READY gateway=",
        skynet.address(gateway_service),
        " listen=",
        gateway.address,
        ":",
        gateway.port,
        " transport=",
        gateway.transport,
        " remote=",
        gateway_lesson_config.cluster.remote_node,
        " shutdown=",
        skynet.address(shutdown_coordinator)
    )
    skynet.exit()
end)
