-- 职责：为第三课的独立状态同步/帧同步进程提供一次性优雅关闭入口。
-- 边界：只协调同一 OS Process 内显式注入的 Service handle；不保存业务状态。
-- 输入：configure 注入 profile、role、Cluster endpoint 和目标 Service handles。
-- 输出：shutdown 返回 FlyWowResult；成功后延迟终止当前进程。
-- 生命周期：由课程 Battle/Gateway 组合根启动；关闭流程超时由运行脚本信号兜底。
local cluster = require "skynet.cluster"
local skynet = require "skynet.manager"
local flywow_result = require "flywow_result"

local module_state =
{
    configured    = false, -- 远端关闭授权和 Cluster 名称注册均完成后置位。
    shutting_down = false, -- 首次关闭命令进入后置位，避免重复释放相同 Service。
    profile       = nil,   -- 组合根选定的 state_sync 或 frame_sync 运行方案。
    role          = nil,   -- 当前进程承担的 battle 或 gateway 角色。
    endpoint      = nil,   -- shutdownctl 用于定位当前协调器的 Cluster 名称。
    dispatcher    = nil,   -- Battle 角色下由组合根注入的 Dispatcher handle。
    gateway       = nil,   -- Gateway 角色下由组合根注入的 FlyWow Gateway handle。
    proxy         = nil,   -- Gateway 角色下由组合根注入的进程内转发 Proxy handle。
    shutdown_result = nil, -- 完整关闭尝试的最终结果；重复 RPC 不会把失败改报成功。
}

--- 把跨 Service shutdown RPC 结果转换为本 Coordinator 的稳定结果。
---@param call_ok boolean pcall 是否成功完成 Skynet RPC。
---@param call_result any 远端的 FlyWowResult 或历史 Battle API 的 boolean。
---@param operation_name string 正在执行的远端操作，写入错误诊断。
---@return FlyWowResult<nil> 远端确认成功时返回 success；RPC 抛错或返回失败时返回错误。
local function normalize_remote_result(call_ok, call_result, operation_name)
    if not call_ok then
        return flywow_result.failure("LESSON3_REMOTE_CALL_FAILED", tostring(call_result), { operation = operation_name })
    end
    if type(call_result) == "table" and call_result.ok == true then
        return flywow_result.success()
    end
    if call_result == true then
        return flywow_result.success()
    end

    local code = type(call_result) == "table" and call_result.code or "REMOTE_OPERATION_FAILED"
    local message = type(call_result) == "table" and call_result.message or "remote Service did not confirm success"
    return flywow_result.failure(
        "LESSON3_REMOTE_OPERATION_FAILED",
        operation_name .. ": " .. tostring(message),
        { operation = operation_name, remote_code = code }
    )
end

--- 注册关闭入口并授权目标 Service 接受当前 Coordinator 的 shutdown。
---@param shutdown_configuration table composition root 提供的 profile/role/endpoint 和相关 Service handles。
---@return FlyWowResult<nil> 输入或远端授权失败时返回错误；配置成功返回 success。
local function configure(shutdown_configuration)
    if module_state.configured then
        return flywow_result.failure("LESSON3_SHUTDOWN_ALREADY_CONFIGURED", "shutdown is already configured")
    end
    if type(shutdown_configuration) ~= "table" then
        return flywow_result.failure("LESSON3_SHUTDOWN_CONFIG_INVALID", "shutdown configuration must be a table")
    end
    if shutdown_configuration.profile ~= "state_sync" and shutdown_configuration.profile ~= "frame_sync" then
        return flywow_result.failure("LESSON3_SHUTDOWN_PROFILE_INVALID", "profile must be state_sync or frame_sync")
    end
    if shutdown_configuration.role ~= "battle" and shutdown_configuration.role ~= "gateway" then
        return flywow_result.failure("LESSON3_SHUTDOWN_ROLE_INVALID", "role must be battle or gateway")
    end
    if type(shutdown_configuration.endpoint) ~= "string" or shutdown_configuration.endpoint == "" then
        return flywow_result.failure("LESSON3_SHUTDOWN_ENDPOINT_INVALID", "endpoint must be a non-empty name")
    end

    if shutdown_configuration.role == "battle" then
        if type(shutdown_configuration.dispatcher) ~= "number" or math.type(shutdown_configuration.dispatcher) ~= "integer" or shutdown_configuration.dispatcher <= 0 then
            return flywow_result.failure("LESSON3_DISPATCHER_HANDLE_INVALID", "battle dispatcher handle is invalid")
        end
        local call_ok, call_result = pcall(
            skynet.call,
            shutdown_configuration.dispatcher,
            "lua",
            "configure_shutdown",
            skynet.self()
        )
        local authorization = normalize_remote_result(call_ok, call_result, "authorize battle dispatcher shutdown")
        if not authorization.ok then
            return authorization
        end
        module_state.dispatcher = shutdown_configuration.dispatcher
    else
        if type(shutdown_configuration.gateway) ~= "number" or math.type(shutdown_configuration.gateway) ~= "integer" or shutdown_configuration.gateway <= 0 or
            type(shutdown_configuration.proxy) ~= "number" or math.type(shutdown_configuration.proxy) ~= "integer" or shutdown_configuration.proxy <= 0 then
            return flywow_result.failure("LESSON3_GATEWAY_HANDLES_INVALID", "gateway and proxy handles are invalid")
        end
        local call_ok, call_result = pcall(
            skynet.call,
            shutdown_configuration.proxy,
            "lua",
            "set_shutdown_coordinator",
            skynet.self()
        )
        local authorization = normalize_remote_result(call_ok, call_result, "authorize Gateway proxy shutdown")
        if not authorization.ok then
            return authorization
        end
        module_state.gateway = shutdown_configuration.gateway
        module_state.proxy = shutdown_configuration.proxy
    end

    module_state.profile = shutdown_configuration.profile
    module_state.role = shutdown_configuration.role
    module_state.endpoint = shutdown_configuration.endpoint
    cluster.register(module_state.endpoint, skynet.self())
    module_state.configured = true
    return flywow_result.success()
end

--- 按当前进程角色关闭其拥有的 Service，并在所有远端确认后刷新 Logger。
---@return FlyWowResult<nil> 未配置、远端失败或 Logger 刷新失败时返回错误。
local function shutdown()
    if not module_state.configured then
        return flywow_result.failure("LESSON3_SHUTDOWN_NOT_CONFIGURED", "shutdown is not configured")
    end
    if module_state.shutting_down then
        return module_state.shutdown_result or
            flywow_result.failure("LESSON3_SHUTDOWN_IN_PROGRESS", "shutdown is already in progress")
    end
    module_state.shutting_down = true

    local targets
    if module_state.role == "gateway" then
        -- Gateway 先停止监听和连接，再停止 Proxy，避免 Battle 停止后仍接收新请求。
        targets =
        {
            {
                service = module_state.gateway, -- Gateway Service handle，由组合根注入。
                command = "stop", -- 按 FlyWow Service 合同停止 listener 和连接。
                name = "stop FlyWow Gateway", -- 失败诊断使用的操作名称。
            },
            {
                service = module_state.proxy, -- 本进程转发 Proxy handle，由组合根注入。
                command = "shutdown", -- 撤销转发能力并退出 Proxy。
                name = "stop Gateway proxy", -- 失败诊断使用的操作名称。
            },
        }
    else
        -- Battle Dispatcher 负责释放其拥有的 Worker 和 Native Runtime。
        targets =
        {
            {
                service = module_state.dispatcher, -- Battle Dispatcher handle，由组合根注入。
                command = "shutdown", -- 让 Dispatcher 释放它拥有的 Worker。
                name = "stop Battle dispatcher", -- 失败诊断使用的操作名称。
            },
        }
    end

    local failure_count = 0 -- 未完成的 Service/Logger 清理步骤数；失败后仍继续剩余步骤。
    local first_failure = nil -- 第一条关闭诊断，限制错误 record 的大小。

    for index = 1, #targets do
        local target = targets[index] -- 当前需要关闭的进程内 Service。
        local call_ok, call_result = pcall(skynet.call, target.service, "lua", target.command)
        local operation_result = normalize_remote_result(call_ok, call_result, target.name)
        if not operation_result.ok then
            failure_count = failure_count + 1
            if first_failure == nil then
                first_failure = operation_result.message
            end
        end
    end

    skynet.error("LESSON3_SHUTDOWN_COMPLETE profile=", module_state.profile,
        " role=", module_state.role)
    local flush_ok, flush_result = pcall(require("flywow_logger").flush)
    if not flush_ok then
        failure_count = failure_count + 1
        if first_failure == nil then
            first_failure = "FlyWow Logger flush failed: " .. tostring(flush_result)
        end
    end
    if failure_count > 0 then
        module_state.shutdown_result = flywow_result.failure(
            "LESSON3_SHUTDOWN_FAILED",
            first_failure,
            { failure_count = failure_count, role = module_state.role }
        )
        return module_state.shutdown_result
    end
    module_state.shutdown_result = flywow_result.success()
    return module_state.shutdown_result
end

--- 远端关闭确认完成后延迟 abort，保证 shutdownctl 先收到 RPC 结果。
local function abort_later()
    skynet.fork(function()
        skynet.sleep(10)
        skynet.abort()
    end)
end

skynet.start(function()
    --- Service 合同：configure/shutdown 返回 FlyWowResult；ready 是表示配置完成的自然 boolean 查询。
    skynet.dispatch("lua", function(_, _, command, payload)
        if command == "configure" then
            skynet.retpack(configure(payload))
            return
        end
        if command == "ready" then
            skynet.retpack(module_state.configured)
            return
        end
        if command == "shutdown" then
            local shutdown_result = shutdown() -- 关闭流程的稳定结果，供 shutdownctl 判断。
            skynet.retpack(shutdown_result)
            if shutdown_result.ok then
                abort_later()
            end
            return
        end
        skynet.retpack(flywow_result.failure(
            "LESSON3_SHUTDOWN_COMMAND_UNKNOWN",
            "unknown lesson3 shutdown command: " .. tostring(command)
        ))
    end)
end)
