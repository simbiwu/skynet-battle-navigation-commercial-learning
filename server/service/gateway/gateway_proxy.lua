--- 职责：在 Gateway 与 Battle 进程之间转发已解码的业务数据。
--- 边界：Server Runtime Adapter；只保存 Gateway Service handle 和 Cluster 配置。
--- 输入/输出：send_data 请求/响应数据，close 连接控制；不保存业务请求状态。
--- 不负责：不解析协议、不编码 Protobuf、不等待业务结果、不判断业务超时或成功失败。

local cluster = require "skynet.cluster"
local skynet = require "skynet.manager"
local flywow_result = require "flywow_result"
local luapanda_debug = require "shared.debug.luapanda_debug"

local module_state =
{
    process_config = nil, -- 启动时注入的 Cluster 配置；Proxy 生命周期内固定。
    gateway_service_handle = nil, -- 组合根绑定的 Gateway Service；仅用于本地投递。
    is_started = false, -- Cluster 监听和远端 ready 检查都成功后置为 true。
}

--- 校验统一 send_data 合同；只检查传输路由字段，不解释业务 payload。
--- data 由 Gateway 或可信 Battle 生成；不执行 I/O、yield 或状态缓存。
---@class GatewayDataMessage
---@field gateway_epoch string 当前 Gateway 实例身份；Gateway 与可信 Battle 创建，跨进程传输。
---@field connection_id integer Gateway 逻辑连接；0 表示本 Gateway 实例广播。
---@field command_id integer 已登记 Protobuf CommandId；跨进程传输。
---@field data table 已解码 Request 或 Response；不含 fd，由当前消息协程持有。
---@param data GatewayDataMessage Gateway 或可信 Battle 创建的数据 record；本函数只校验传输路由字段。
---@return FlyWowResult<nil> 字段符合 send_data 合同时返回 success，否则返回具体字段错误。
local function validate_data(data)
    if type(data) ~= "table" then
        return flywow_result.failure("GATEWAY_DATA_INVALID", "gateway data must be a table")
    end
    if type(data.gateway_epoch) ~= "string" or #data.gateway_epoch == 0 or #data.gateway_epoch > 128 then
        return flywow_result.failure("GATEWAY_EPOCH_INVALID", "gateway_epoch must contain 1 to 128 bytes")
    end
    if type(data.connection_id) ~= "number" or math.type(data.connection_id) ~= "integer" or data.connection_id < 0 then
        return flywow_result.failure("GATEWAY_CONNECTION_ID_INVALID", "connection_id must be a non-negative integer")
    end
    if type(data.command_id) ~= "number" or math.type(data.command_id) ~= "integer" or data.command_id <= 0 then
        return flywow_result.failure("GATEWAY_COMMAND_ID_INVALID", "command_id must be a positive integer")
    end
    if type(data.data) ~= "table" then
        return flywow_result.failure("GATEWAY_PAYLOAD_INVALID", "gateway data payload must be a table")
    end

    return flywow_result.success()
end

--- 把 Gateway 的已解码数据异步转发到 Battle；Cluster 错误会记录并交给同步调用方。
---@param data GatewayDataMessage 当前 Gateway 请求；只读借用，不复制、不修改、不等待 Battle 结果。
---@return boolean Cluster 接受转发返回 true；Cluster API 抛错时返回 false。
local function forward_to_battle(data)
    local ok, err = pcall( -- Cluster 异步投递是否完成及传输异常诊断。
        cluster.send,
        module_state.process_config.cluster.remote_node,
        "@" .. module_state.process_config.cluster.remote_service,
        "send_data",
        data
    )
    if not ok then
        skynet.error("GATEWAY_SEND_DATA_TO_BATTLE_FAILED ", tostring(err))
    end
    return ok
end

--- 把 Battle 的发送数据异步投递给本地 Gateway；不保存业务状态。
---@param data GatewayDataMessage Battle 响应或 Push；connection_id 可为具体连接或 0 广播。
---@return FlyWowResult<nil> 成功表示 Skynet 已接收投递；字段无效或目标 Service 不可投递时返回错误。
local function forward_to_gateway(data)
    local validation = validate_data(data) -- Battle 消息在 Gateway 投递边界的路由字段校验结果。
    if not validation.ok then
        return validation
    end
    local sent = skynet.send(
        module_state.gateway_service_handle,
        "lua",
        "send_data",
        data
    ) ~= nil -- 本地 Skynet 投递是否被接受；不代表客户端已收到。
    if not sent then
        return flywow_result.failure("GATEWAY_DELIVERY_FAILED", "Skynet rejected local Gateway delivery")
    end
    return flywow_result.success()
end

--- 建立 Cluster 监听并等待 Battle ready；只初始化传输路径。
--- 可能 yield，不创建业务请求表。
---@class GatewayProxyClusterConfig
---@field remote_node string composition root 选择的 Battle Cluster 节点名。
---@field remote_address string Battle 的 host:port 地址；与 remote_node 配对加载。
---@field local_listen integer 本地 Proxy 接收 Cluster 连接的监听端口。
---@field max_clients integer 本地 Cluster 连接容量，不是 Gateway 客户端上限。
---@field proxy_service string 本地注册的 Gateway Proxy 名称。
---@field remote_service string 远端 Battle 接收 Gateway 数据的 Service 名称。
---@class GatewayProcessConfig
---@field cluster GatewayProxyClusterConfig composition root 注入的 Gateway/Battle Cluster 连接参数。
---@param process_config GatewayProcessConfig composition root 传入的 Cluster 配置；本函数保存该配置并建立远程连接。
---@return FlyWowResult<table> 成功 value 含 remote_node 和 remote_address；配置或 Battle ready 失败时返回错误。
local function start(process_config)
    if module_state.is_started or module_state.process_config ~= nil then
        return flywow_result.failure("GATEWAY_PROXY_ALREADY_STARTED", "gateway proxy can only start once")
    end
    if type(process_config) ~= "table" or type(process_config.cluster) ~= "table" then
        return flywow_result.failure("GATEWAY_PROXY_CONFIG_INVALID", "gateway proxy requires cluster config")
    end

    -- 建立本地 Cluster 监听和远端映射；这些 Cluster API 可能通过 RPC 报告配置错误。
    local cluster_setup_ok, cluster_setup_error = pcall(function() -- Cluster 配置是否完成及失败诊断。

        cluster.reload(
            {
                [process_config.cluster.remote_node] = process_config.cluster.remote_address,
            }
        )
        cluster.open(process_config.cluster.local_listen, process_config.cluster.max_clients)
        cluster.register(process_config.cluster.proxy_service, skynet.self())
    end)
    if not cluster_setup_ok then
        return flywow_result.failure("GATEWAY_PROXY_CLUSTER_SETUP_FAILED", tostring(cluster_setup_error))
    end
    module_state.process_config = process_config

    -- Battle 已完成 cluster setup 后查询 ready；断连异常转换为启动结果。
    local ready_ok, ready_result = pcall( -- Battle ready 查询是否完成及远端返回值。

        cluster.call,
        process_config.cluster.remote_node,
        "@" .. process_config.cluster.remote_service,
        "ready"
    )
    if not ready_ok or ready_result ~= true then
        module_state.process_config = nil
        local failure = ready_ok and "Battle process is not ready" or tostring(ready_result) -- 返回给 composition root 的启动诊断。
        return flywow_result.failure("GATEWAY_BATTLE_NOT_READY", failure)
    end

    module_state.is_started = true
    skynet.name(".gateway_proxy", skynet.self())
    return flywow_result.success(
        {
            remote_node = process_config.cluster.remote_node,
            remote_address = process_config.cluster.remote_address,
        }
    )
end

--- 注入当前 Gateway Service handle；Proxy 只保存这个传输目标。
---@param gateway_binding table composition root 提供的 gateway_service handle。
---@return FlyWowResult<nil> 绑定状态或 handle 无效时返回稳定错误；成功表示 Proxy 已持有 Gateway handle。
local function bind_gateway(gateway_binding)
    if not module_state.is_started or module_state.gateway_service_handle ~= nil then
        return flywow_result.failure("GATEWAY_PROXY_BIND_STATE_INVALID", "gateway proxy cannot accept this binding")
    end
    if type(gateway_binding) ~= "table" or
        type(gateway_binding.gateway_service) ~= "number" or math.type(gateway_binding.gateway_service) ~= "integer" or
        gateway_binding.gateway_service <= 0 then
        return flywow_result.failure("GATEWAY_SERVICE_HANDLE_INVALID", "gateway_service must be a valid handle")
    end

    module_state.gateway_service_handle = gateway_binding.gateway_service
    return flywow_result.success()
end

--- 停止 Proxy 接收新转发；Gateway Coordinator 随后让本 Service 退出。
---@return FlyWowResult<nil> 成功表示本 Proxy 不再接受转发；不执行业务 I/O，不保存连接状态。
local function shutdown()
    module_state.is_started = false
    return flywow_result.success()
end

--- 将 Battle 的 close 控制消息转发给 Gateway；不判断业务结果。
--- connection_id 必须指向具体连接，广播关闭不在本接口内定义。
---@class GatewayCloseMessage
---@field gateway_epoch string 目标 Gateway 实例身份；旧实例响应不能关闭新实例连接。
---@field connection_id integer 目标实例内的正数逻辑连接号；0 广播不允许用于 close。
---@param data GatewayCloseMessage Battle 生成的连接关闭 record；connection_id 必须指向具体连接。
---@return FlyWowResult<nil> 校验并投递成功返回 success；未就绪、字段无效或投递失败返回错误。
local function close_gateway(data)
    if not module_state.is_started or module_state.gateway_service_handle == nil then
        return flywow_result.failure("GATEWAY_PROXY_NOT_READY", "gateway proxy is not ready")
    end
    if type(data) ~= "table" or type(data.gateway_epoch) ~= "string" or
        #data.gateway_epoch == 0 or #data.gateway_epoch > 128 then
        return flywow_result.failure("GATEWAY_CLOSE_DATA_INVALID", "gateway close data is invalid")
    end
    if type(data.connection_id) ~= "number" or math.type(data.connection_id) ~= "integer" or data.connection_id <= 0 then
        return flywow_result.failure("GATEWAY_CONNECTION_ID_INVALID", "close requires a positive connection_id")
    end

    local sent = skynet.send(
        module_state.gateway_service_handle,
        "lua",
        "close",
        data
    ) ~= nil -- 本地投递状态；Gateway 后续可能因连接已关闭而忽略请求。
    if not sent then
        return flywow_result.failure("GATEWAY_CLOSE_DELIVERY_FAILED", "Skynet rejected close delivery")
    end
    return flywow_result.success()
end

skynet.start(function()
    luapanda_debug.start(8818)

    --- Service RPC 合同：配置命令返回 FlyWowResult；send_data/close 只在同步 call 时回传结果。
    ---@param session integer Skynet RPC session；0 表示异步 send，没有可回复的调用方。
    ---@param source integer 当前消息发送方的 Service handle，用于确认 Gateway 通知来源。
    ---@param command string 本 Proxy 支持的 start/bind_gateway/shutdown/send_data/close/disconnect 命令。
    ---@param data any 当前命令 payload；每条命令的字段合同在对应分支校验。
    skynet.dispatch("lua", function(session, source, command, data)
        if command == "start" then
            skynet.retpack(start(data))
            return
        elseif command == "bind_gateway" then
            skynet.retpack(bind_gateway(data))
            return
        elseif command == "shutdown" then
            local shutdown_result = shutdown() -- 关闭后续转发并保留给 RPC 调用方的结果。
            skynet.retpack(shutdown_result)
            if shutdown_result.ok then
                skynet.exit()
            end
            return
        elseif command == "send_data" then
            if not module_state.is_started or module_state.gateway_service_handle == nil then
                if session ~= 0 then
                    skynet.retpack(flywow_result.failure("GATEWAY_PROXY_NOT_READY", "gateway proxy is not ready"))
                else
                    skynet.error("GATEWAY_PROXY_NOT_READY")
                end
                return
            end

            local validation = validate_data(data) -- 当前消息的路由字段校验结果。
            if not validation.ok then
                if session ~= 0 then
                    skynet.retpack(validation)
                else
                    skynet.error("GATEWAY_PROXY_DATA_INVALID ", validation.code, " ", validation.message)
                end
                return
            end

            if source == module_state.gateway_service_handle then
                local forwarded = forward_to_battle(data) -- Gateway 入站请求的异步远端投递状态。
                if session ~= 0 then
                    if forwarded then
                        skynet.retpack(flywow_result.success())
                    else
                        skynet.retpack(flywow_result.failure(
                            "GATEWAY_BATTLE_DELIVERY_FAILED",
                            "Cluster rejected Battle delivery"
                        ))
                    end
                end
            else
                local delivery_result = forward_to_gateway(data) -- Battle 响应或 Push 的本地投递结果。
                if session ~= 0 then
                    skynet.retpack(delivery_result)
                elseif not delivery_result.ok then
                    skynet.error("GATEWAY_PROXY_DELIVERY_FAILED ", delivery_result.code)
                end
            end
            return
        elseif command == "gateway_disconnect" then
            if source ~= module_state.gateway_service_handle or module_state.gateway_service_handle == nil then
                if session ~= 0 then
                    skynet.retpack(flywow_result.failure("GATEWAY_DISCONNECT_SOURCE_INVALID", "untrusted disconnect source"))
                else
                    skynet.error("GATEWAY_DISCONNECT_SOURCE_INVALID")
                end
                return
            end
            return
        elseif command == "close" then
            local close_result = close_gateway(data) -- Battle 主动关闭连接的本地投递结果。
            if session ~= 0 then
                skynet.retpack(close_result)
            elseif not close_result.ok then
                skynet.error("GATEWAY_PROXY_CLOSE_FAILED ", close_result.code)
            end
            return
        end

        if session ~= 0 then
            skynet.retpack(flywow_result.failure(
                "GATEWAY_PROXY_COMMAND_UNKNOWN",
                "unknown gateway proxy command: " .. tostring(command),
                { command = tostring(command) }
            ))
        else
            skynet.error("GATEWAY_PROXY_COMMAND_UNKNOWN ", tostring(command))
        end
    end)
end)
