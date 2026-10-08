--- 职责：在 Gateway 与 Battle 进程之间转发已解码的业务数据。
--- 边界：Server Runtime Adapter；只保存 Gateway Service handle 和 Cluster 配置。
--- 输入/输出：send_data 请求/响应数据，close 连接控制；不保存业务请求状态。
--- 不负责：不解析协议、不编码 Protobuf、不等待业务结果、不判断业务超时或成功失败。

local cluster = require "skynet.cluster"
local skynet = require "skynet"
local process = require "config.gateway"
local luapanda_debug = require "shared.debug.luapanda_debug"

local state =
{
    gateway_service = nil,
    started = false,
    shutting_down = false,
}

--- 校验统一 send_data 合同；只检查传输路由字段，不解释业务 payload。
--- data 由 Gateway 或可信 Battle 生成；不执行 I/O、yield 或状态缓存。
---@class GatewayDataMessage
---@field gateway_epoch string 当前 Gateway 实例身份；Gateway 与可信 Battle 创建，跨进程传输。
---@field connection_id integer Gateway 逻辑连接；0 表示主动广播，否则必须配非零 request_id。
---@field command_id integer 已登记 Protobuf CommandId；跨进程传输。
---@field request_id integer uint64 的 Lua 整数位模式；非零关联请求，0 表示主动消息。
---@field data table 已解码 Request 或 Response；不含 fd，由当前消息协程持有。
---@param data GatewayDataMessage Gateway 已解码请求或 Battle 响应；只读借用。
---@return nil 非法字段抛错；不 I/O、不 yield、不缓存状态。
local function validate_data(data)
    assert(type(data) == "table", "gateway data is required")
    assert(type(data.gateway_epoch) == "string" and
        #data.gateway_epoch > 0 and #data.gateway_epoch <= 128,
        "gateway_epoch is required")
    assert(math.type(data.connection_id) == "integer" and
        data.connection_id >= 0,
        "connection_id must be non-negative")
    assert(math.type(data.command_id) == "integer" and
        data.command_id > 0,
        "command_id must be positive")
    assert(math.type(data.request_id) == "integer" and
        ((data.connection_id == 0 and data.request_id == 0) or
         (data.connection_id > 0 and data.request_id ~= 0)),
        "request_id must match connection_id")
    assert(type(data.data) == "table", "gateway data payload is required")
end

--- 把 Gateway 的已解码数据异步转发到 Battle；失败只记录传输错误。
--- data 由本函数借用，不复制、不修改、不等待 Battle 结果。
local function forward_to_battle(data)
    local ok, err = pcall(
        cluster.send,
        process.cluster.remote_node,
        "@" .. process.cluster.remote_service,
        "send_data",
        data
    )
    if not ok then
        skynet.error("GATEWAY_SEND_DATA_TO_BATTLE_FAILED ", tostring(err))
    end
    return ok
end

--- 把 Battle 的发送数据异步投递给本地 Gateway；不保存业务状态。
--- data 的目标 connection_id 可以是具体连接，也可以是 0 广播。
local function forward_to_gateway(data)
    validate_data(data)
    return skynet.send(
        state.gateway_service,
        "lua",
        "send_data",
        data
    ) ~= nil
end

--- 建立 Cluster 监听并等待 Battle ready；只初始化传输路径。
--- 返回远程节点信息；可能 yield，不创建业务请求表。
local function start()
    assert(not state.started, "gateway proxy can only start once")

    cluster.reload(
        {
            [process.cluster.remote_node] = process.cluster.remote_address,
        }
    )
    cluster.open(process.cluster.local_listen, process.cluster.max_clients)
    cluster.register(process.cluster.proxy_service, skynet.self())

    local ready_ok, ready_result = pcall(
        cluster.call,
        process.cluster.remote_node,
        "@" .. process.cluster.remote_service,
        "ready"
    )
    assert(
        ready_ok and ready_result == true,
        "battle process is not ready: " .. tostring(ready_result)
    )

    state.started = true
    skynet.name(".gateway_proxy", skynet.self())

    return
    {
        remote_node = process.cluster.remote_node,
        remote_address = process.cluster.remote_address,
    }
end

--- 注入当前 Gateway Service handle；Proxy 只保存这个传输目标。
--- options 由 composition root 提供；重复绑定或非法 handle 直接失败。
local function bind_gateway(options)
    assert(state.started and state.gateway_service == nil,
        "gateway proxy binding is invalid")
    assert(
        type(options) == "table" and
        math.type(options.gateway_service) == "integer" and
        options.gateway_service > 0,
        "gateway_service is required"
    )

    state.gateway_service = options.gateway_service
    return true
end

--- 停止 Proxy 接收新转发；Gateway Coordinator 随后让本 Service 退出。
--- 返回 true；不执行业务 I/O，不保存连接状态。
local function shutdown()
    state.shutting_down = true
    state.started = false
    return true
end

--- 将 Battle 的 close 控制消息转发给 Gateway；不判断业务结果。
--- connection_id 必须指向具体连接，广播关闭不在本接口内定义。
local function close_gateway(data)
    assert(state.started and state.gateway_service ~= nil,
        "gateway proxy is not ready")
    assert(type(data) == "table", "gateway close data is required")
    assert(type(data.gateway_epoch) == "string" and
        #data.gateway_epoch > 0 and #data.gateway_epoch <= 128,
        "gateway_epoch is required")
    assert(math.type(data.connection_id) == "integer" and
        data.connection_id > 0,
        "connection_id must be positive for close")

    return skynet.send(
        state.gateway_service,
        "lua",
        "close",
        data
    ) ~= nil
end

skynet.start(function()
    luapanda_debug.start(8818)

    skynet.dispatch("lua", function(_session, source, command, data)
        if command == "start" then
            skynet.retpack(start())
            return
        elseif command == "bind_gateway" then
            skynet.retpack(bind_gateway(data))
            return
        elseif command == "shutdown" then
            skynet.retpack(shutdown())
            skynet.exit()
            return
        elseif command == "send_data" then
            assert(state.started and state.gateway_service ~= nil,
                "gateway proxy is not ready")
            validate_data(data)

            if source == state.gateway_service then
                forward_to_battle(data)
            else
                forward_to_gateway(data)
            end
            return
        elseif command == "gateway_disconnect" then
            --- Gateway 已释放连接资源；本 Proxy 不保存连接或待回应请求。
            --- 消费本地可信通知即可，不能把它当成未知业务命令抛错。
            assert(source == state.gateway_service, "untrusted disconnect source")
            return
        elseif command == "close" then
            close_gateway(data)
            return
        end
        error("unknown gateway proxy command: " .. tostring(command))
    end)
end)
