-- 职责：接收 Gateway 进程级 shutdown 命令，先停止网络接入再关闭 Proxy。
-- 边界：Gateway OS Process 内的控制 Service；只持有本进程 Service handle。
-- 输入/输出：configure 注入 FlyWow Gateway/Proxy，shutdown 返回 FlyWowResult。
-- 不负责：不处理客户端业务、不直接解析 SIGTERM。
local cluster = require "skynet.cluster"
local skynet = require "skynet.manager"
local flywow_result = require "flywow_result"

local module_state =
{
    configured       = false, -- Cluster shutdown 名称注册完成后置位。
    shutting_down    = false, -- 首次关闭流程启动后置位，阻止重复释放 Service。
    shutdown_handles = nil,   -- composition root 注入的 Gateway/Proxy handles；本 Coordinator 独占。
    shutdown_result  = nil,   -- 完整关闭尝试的最终结果；重复 RPC 原样返回，不谎报失败已恢复。
}

--- 注入 Gateway 和 Proxy 的本地 handle，并注册 shutdownctl 发现名称。
---@param shutdown_handles table composition root 创建的 gateway_service 与 proxy_service handles。
---@return FlyWowResult<nil> 重复配置或 handle 无效返回错误；成功返回 success。
local function configure(shutdown_handles)
    if module_state.configured then
        return flywow_result.failure("GATEWAY_SHUTDOWN_ALREADY_CONFIGURED", "gateway shutdown already configured")
    end
    if type(shutdown_handles) ~= "table" or
        type(shutdown_handles.gateway_service) ~= "number" or math.type(shutdown_handles.gateway_service) ~= "integer" or shutdown_handles.gateway_service <= 0 or
        type(shutdown_handles.proxy_service) ~= "number" or math.type(shutdown_handles.proxy_service) ~= "integer" or shutdown_handles.proxy_service <= 0 then
        return flywow_result.failure("GATEWAY_SHUTDOWN_HANDLES_INVALID", "gateway shutdown handles are invalid")
    end

    module_state.shutdown_handles = shutdown_handles
    cluster.register("gateway_shutdown", skynet.self())
    module_state.configured = true
    return flywow_result.success()
end

--- 依次关闭 FlyWow Gateway 与 Proxy，刷新 Logger 后向 shutdownctl 确认。
---@return FlyWowResult<nil> 配置缺失、远端关闭或 Logger 刷新失败时返回错误。
local function shutdown()
    if not module_state.configured then
        return flywow_result.failure("GATEWAY_SHUTDOWN_NOT_CONFIGURED", "gateway shutdown is not configured")
    end
    if module_state.shutting_down then
        return module_state.shutdown_result or
            flywow_result.failure("GATEWAY_SHUTDOWN_IN_PROGRESS", "gateway shutdown is already in progress")
    end
    module_state.shutting_down = true

    local failure_count = 0 -- 收尾阶段失败的 Service/Logger 操作数；继续清理剩余资源。
    local first_failure = nil -- 第一条错误诊断；只保存一条，避免 shutdown 错误随连接规模增长。

    local gateway_call_ok, gateway_result = pcall( -- Gateway stop RPC 是否完成及其 FlyWowResult。
        skynet.call,
        module_state.shutdown_handles.gateway_service,
        "lua",
        "stop"
    )
    if not gateway_call_ok or type(gateway_result) ~= "table" or gateway_result.ok ~= true then
        failure_count = failure_count + 1
        local code = type(gateway_result) == "table" and gateway_result.code or "GATEWAY_STOP_RPC_FAILED" -- 远端稳定错误码或 RPC 失败占位码。
        local message = type(gateway_result) == "table" and gateway_result.message or tostring(gateway_result) -- 远端诊断或捕获的异常文本。
        first_failure = "Gateway stop failed (" .. tostring(code) .. "): " .. tostring(message)
    end

    local proxy_call_ok, proxy_result = pcall( -- Proxy shutdown RPC 是否完成及其 FlyWowResult。
        skynet.call,
        module_state.shutdown_handles.proxy_service,
        "lua",
        "shutdown"
    )
    if not proxy_call_ok or type(proxy_result) ~= "table" or proxy_result.ok ~= true then
        failure_count = failure_count + 1
        local code = type(proxy_result) == "table" and proxy_result.code or "GATEWAY_PROXY_STOP_RPC_FAILED" -- 远端稳定错误码或 RPC 失败占位码。
        local message = type(proxy_result) == "table" and proxy_result.message or tostring(proxy_result) -- 远端诊断或捕获的异常文本。
        if first_failure == nil then
            first_failure = "Gateway Proxy stop failed (" .. tostring(code) .. "): " .. tostring(message)
        end
    end

    skynet.error("GATEWAY_SHUTDOWN_COMPLETE")
    local flush_ok, flush_result = pcall(require("flywow_logger").flush)
    if not flush_ok then
        failure_count = failure_count + 1
        if first_failure == nil then
            first_failure = "FlyWow Logger flush failed: " .. tostring(flush_result)
        end
    end
    if failure_count > 0 then
        module_state.shutdown_result = flywow_result.failure(
            "GATEWAY_SHUTDOWN_FAILED",
            first_failure,
            { failure_count = failure_count }
        )
        return module_state.shutdown_result
    end
    module_state.shutdown_result = flywow_result.success()
    return module_state.shutdown_result
end

skynet.start(function()
    --- Service 合同：configure/shutdown 返回 FlyWowResult；ready 返回是否已完成配置的 boolean 查询。
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
            local shutdown_result = shutdown() -- 关闭结果交给 shutdownctl 判断。
            skynet.retpack(shutdown_result)
            if shutdown_result.ok then
                skynet.fork(function()
                    skynet.sleep(10)
                    skynet.abort()
                end)
            end
            return
        end
        skynet.retpack(flywow_result.failure(
            "GATEWAY_SHUTDOWN_COMMAND_UNKNOWN",
            "unknown gateway shutdown command: " .. tostring(command)
        ))
    end)
end)
