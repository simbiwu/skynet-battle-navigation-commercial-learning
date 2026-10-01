-- 职责：把 FlyWow Gateway 的已解码请求转发到独立 Battle Process。
-- 边界：Server Runtime Adapter Service；拥有远程节点配置和 异步路由与错误转换，不拥有 fd、frame 或地图状态。
-- 输入/输出：Gateway request record -> cluster.send；反向结果 -> gateway_response。
-- 生命周期：Gateway Process 启动时初始化一次；有界 token 表仅保存返回上下文，不保存等待协程。
-- 不负责：不解析 TCP/WebSocket、不编码 Protobuf、不注册业务 command、不等待业务结果。

local cluster = require "skynet.cluster"
local skynet = require "skynet"
local endpoint = require "flywow.gateway.endpoint"
local process = require "config.process_gateway"
local luapanda_debug = require "shared.debug.luapanda_debug"

local MAX_PENDING = 64          -- 同时保留 Battle 返回路由的请求数上限。
local REPLY_TIMEOUT_TICKS = 1000 -- 1/100 秒为一个 Skynet tick；路由最多保留 10 秒。
local TIMER_INTERVAL_TICKS = 10 -- 每 100 ms 扫描有限路由表。
local pending = {}              -- token -> 返回上下文与开始 tick，由本 Service 独占；无等待协程。
local pending_count = 0         -- 当前 Battle 返回路由数量。
local next_token = 0            -- 本 Service 生命周期内单调递增的关联序号。
local route_epoch = nil         -- 进程内唯一前缀，隔离 Service 重启前的迟到回包。

local state = {
    gateway_service = nil, -- gateway_main 注入唯一 Gateway handle；供独立关闭命令使用。
    started = false, -- 只允许当前 Adapter Service 初始化一次。
}

-- 校验 Battle 回推的结果形状；业务响应由 Battle 生成，Proxy 只检查通用包装合同。
-- result：Cluster 消息解码出的 table；返回原 record 或稳定错误 record；无 I/O、无 yield。
local function validate_battle_result(result)
    if type(result) ~= "table" then
        return {
            ok = false,
            error = {
                code = "REMOTE_BAD_RESULT",
                message = "battle returned an invalid result record",
            },
        }
    end
    if result.ok == true and type(result.response) == "table" then
        return result
    end
    local error_info = result.error
    if result.ok == false and type(error_info) == "table" and
        type(error_info.code) == "string" and #error_info.code > 0 and #error_info.code <= 64 and
        type(error_info.message) == "string" and #error_info.message <= 256 then
        return result
    end
    return {
        ok = false,
        error = {
            code = "REMOTE_BAD_RESULT",
            message = "battle returned an invalid result record",
        },
    }
end

-- 为一次转发创建不可由客户端选择的 token，供 Battle 的反向结果消息关联原请求。
-- 无参数；返回 string；序号耗尽时显式失败；不执行 I/O 或 yield。
local function new_route_token()
    assert(next_token < math.maxinteger, "gateway route token exhausted")
    next_token = next_token + 1
    return route_epoch .. ":" .. tostring(next_token)
end

-- 把通用失败映射为本项目已有响应类型；不修改客户端协议，不在 Gateway 中解释业务码。
-- payload 为原请求上下文；code/message 是有限诊断；返回新 response table，无 I/O/yield。
local function error_response(payload, code, message)
    if payload.command_id == 1001 then
        return { result = 7, message = code .. ": " .. message }
    end
    return { result = code == "BUSY" and 3 or 4, message = code .. ": " .. message }
end

-- 回复并释放单个项目路由项；context 是薄的本地回复对象，不是请求协程。
-- entry/result 归本 Proxy；返回发送状态，不 yield；失败不关闭客户端连接。
local function reply_entry(entry, result)
    result = validate_battle_result(result)
    local response = result.ok and result.response or
        error_response(entry.payload, result.error.code, result.error.message)
    return entry.context:reply(response)
end

-- 只接纳仍有效 token 的第一份结果；先删除路由，再异步投递给 Gateway。
-- token/result 来自 Battle；返回 boolean，不等待客户端，也不唤醒业务协程。
local function receive_battle_result(token, result)
    local entry = pending[token]
    if entry == nil then
        skynet.error("GATEWAY_PROXY_LATE_RESULT token=", tostring(token))
        return false
    end
    pending[token] = nil
    pending_count = pending_count - 1
    return reply_entry(entry, result)
end

-- 有界扫描路由过期，返回本项目的业务失败响应；不是 Gateway 网络读超时。
-- now 是 10 ms tick；最多 MAX_PENDING 项，无 I/O/yield，迟到回包随后丢弃。
local function expire_pending(now)
    for token, entry in pairs(pending) do
        if (now - entry.started_at) % 0x100000000 >= REPLY_TIMEOUT_TICKS then
            pending[token] = nil
            pending_count = pending_count - 1
            reply_entry(entry, { ok = false, error = { code = "REMOTE_TIMEOUT", message = "battle response timed out" } })
        end
    end
end

-- 扫描有界路由项；不按请求数创建 timer coroutine。
-- 无参数和返回；Service 停止前长驻，执行 sleep/yield。
local function timeout_loop()
    while state.started do
        skynet.sleep(TIMER_INTERVAL_TICKS)
        expire_pending(skynet.now())
    end
end

-- 建立本进程 cluster 监听，并等待 Battle Process 的显式 ready 合同。
-- 参数：无。返回值：{remote_node, remote_address}；失败抛出，可能 yield，不创建业务连接。
local function start()
    assert(not state.started, "gateway proxy can only start once")
    cluster.reload({
        [process.cluster.remote_node] = process.cluster.remote_address,
    })
    cluster.open(process.cluster.local_listen, process.cluster.max_clients)
    cluster.register(process.cluster.proxy_service, skynet.self())
    route_epoch = tostring(skynet.self()) .. ":" .. tostring(skynet.hpc())
    local ready_ok, ready_or_error = pcall(
        cluster.call,
        process.cluster.remote_node,
        "@" .. process.cluster.remote_service,
        "ready"
    )
    assert(ready_ok and ready_or_error == true,
           "battle process is not ready: " .. tostring(ready_or_error))
    state.started = true
    skynet.fork(timeout_loop)   --是为了在 Proxy 初始化完成后，启动一个后台协程定期检查请求超时。
    return {
        remote_node = process.cluster.remote_node,
        remote_address = process.cluster.remote_address,
    }
end

-- 接纳本地 Gateway 消息并单向转发；立即返回，不 wait、不 retpack。
-- source 为 Gateway handle，payload 为解码请求；最多 MAX_PENDING 返回上下文，无 fd/codec。
-- cluster.send 不 yield；发送失败或容量超限返回协议已有业务错误，连接继续读取。
local function dispatch_remote(source, payload)
    assert(state.started, "gateway proxy is not started")
    assert(source == state.gateway_service, "gateway dispatch source mismatch")
    local context = endpoint.new({ gateway_service = source, request = payload })
    local entry = { context = context, payload = { command_id = payload.command_id },
                    gateway_service = source, gateway_epoch = payload.gateway_epoch,
                    connection_id = payload.connection_id, started_at = skynet.now() }
    if pending_count >= MAX_PENDING then
        reply_entry(entry, { ok = false, error = { code = "BUSY", message = "battle request limit reached" } })
        return
    end
    local token = new_route_token()
    pending[token] = entry
    pending_count = pending_count + 1
    local forwarded = {}
    for key, value in pairs(payload) do forwarded[key] = value end
    forwarded.route_token = token
    local ok, err = pcall(cluster.send, process.cluster.remote_node,
                         "@" .. process.cluster.remote_service, "gateway_dispatch", forwarded)
    if not ok then
        pending[token] = nil
        pending_count = pending_count - 1
        reply_entry(entry, { ok = false, error = { code = "REMOTE_UNAVAILABLE", message = "battle send failed" } })
        skynet.error("GATEWAY_PROXY_SEND_FAILED ", tostring(err))
    end
end

-- 断线后移除对应 Gateway 实例的路由；不能取消 Battle 已接纳的业务操作。
-- source/payload 由 Gateway 投递，最多扫描 MAX_PENDING；不 yield、不向客户端回复。
local function disconnected(source, payload)
    for token, entry in pairs(pending) do
        if entry.gateway_service == source and entry.gateway_epoch == payload.gateway_epoch and
            entry.connection_id == payload.connection_id then
            pending[token] = nil
            pending_count = pending_count - 1
        end
    end
end

-- 注入本 Proxy 服务的唯一 Gateway；每个监听实例由 composition root 明确绑定一个 Proxy。
-- options.gateway_service 为本地正整数 handle；返回 true，不 yield，重复绑定或非法参数抛错。
local function bind_gateway(options)
    assert(state.started and state.gateway_service == nil, "gateway proxy binding is invalid")
    assert(type(options) == "table" and math.type(options.gateway_service) == "integer" and
           options.gateway_service > 0, "gateway_service is required")
    state.gateway_service = options.gateway_service
    return true
end

-- 将项目业务侧的关闭消息透明投递给已绑定 Gateway；不查询 token，不保存额外会话表。
-- payload 来自项目可信 Cluster 入口，包含原 gateway_epoch/connection_id；不携带 fd。
-- 返回是否投递；不 yield，参数错误拒绝，旧连接/重复关闭由 Gateway 判定。
local function close_gateway_connection(payload)
    if not state.gateway_service or type(payload) ~= "table" or
        type(payload.gateway_epoch) ~= "string" or #payload.gateway_epoch > 128 or
        math.type(payload.connection_id) ~= "integer" or payload.connection_id < 1 then
        return false
    end
    return skynet.send(state.gateway_service, "lua", "gateway_close", {
        gateway_epoch = payload.gateway_epoch,
        connection_id = payload.connection_id,
    }) ~= nil
end

-- 安装固定 Lua dispatch 签名；session/source 是 Skynet 元数据，command/payload 是本地调用者传入。
-- 参数：Skynet lua 消息的固定四个槽位；payload 是 Gateway 已解码 request record。
-- start/bind_gateway 通过 call 返回；gateway_close 单向转发；gateway_dispatch/disconnect/battle_result 都是单向 send，不等待结果。
skynet.start(function()
    luapanda_debug.start(8818)
    skynet.dispatch("lua", function(_session, source, command, payload, result)
        if command == "start" then
            skynet.retpack(start())
            return
        end
        if command == "bind_gateway" then
            skynet.retpack(bind_gateway(payload))
            return
        end
        if command == "gateway_close" then
            close_gateway_connection(payload)
            return
        end
        if command == "gateway_dispatch" then
            dispatch_remote(source, payload)
            return
        end
        if command == "gateway_disconnect" then
            disconnected(source, payload)
            return
        end
        if command == "battle_result" then
            receive_battle_result(payload, result)
            return
        end
        error("unknown gateway_proxy command: " .. tostring(command))
    end)
end)
