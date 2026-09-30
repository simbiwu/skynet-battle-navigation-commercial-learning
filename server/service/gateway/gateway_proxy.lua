-- 职责：把 FlyWow Gateway 的已解码请求转发到独立 Battle Process。
-- 边界：Server Runtime Adapter Service；拥有远程节点配置和 RPC 错误转换，不拥有 fd、frame 或地图状态。
-- 输入/输出：Gateway request record -> cluster.call result record。
-- 生命周期：Gateway Process 启动时初始化一次；每个请求在当前 Service 协程中执行一次远程调用。
-- 不负责：不解析 TCP/WebSocket、不编码 Protobuf、不注册业务 command、不缓存跨请求状态。

local cluster = require "skynet.cluster"
local skynet = require "skynet"
local process = require "config.process_gateway"
local luapanda_debug = require "shared.debug.luapanda_debug"

local MAX_PENDING = 64          -- 同时等待 Battle 回推的请求数上限。
local REPLY_TIMEOUT_TICKS = 1000 -- 1/100 秒为一个 Skynet tick；等待最多 10 秒。
local TIMER_INTERVAL_TICKS = 10 -- 每 100 ms 扫描有限等待表。
local pending = {}              -- token -> 当前请求协程与结果，由本 Service 独占。
local pending_count = 0         -- 当前等待 Battle 的请求数量。
local next_token = 0            -- 本 Service 生命周期内单调递增的关联序号。
local route_epoch = nil         -- 进程内唯一前缀，隔离 Service 重启前的迟到回包。

local timeout_loop -- start() 在初始化后启动的超时扫描协程。

local state = {
    started = false, -- 只允许当前 Adapter Service 初始化一次。
}

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
    skynet.fork(timeout_loop)
    return {
        remote_node = process.cluster.remote_node,
        remote_address = process.cluster.remote_address,
    }
end

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

-- 等待表中已有 token 时只接纳第一份 Battle 回包；未知或迟到回包会被丢弃。
-- token/result：内部关联值和 Battle record；返回 boolean；不执行 I/O 或 yield。
local function receive_battle_result(token, result)
    local request = pending[token]
    if request == nil or request.result ~= nil then
        skynet.error("GATEWAY_PROXY_LATE_RESULT token=", tostring(token))
        return false
    end
    request.result = validate_battle_result(result)
    skynet.wakeup(request.thread)
    return true
end

-- 清理已超时请求并唤醒原 Gateway handler；未知/已完成项不产生副作用。
-- now：Skynet 32-bit tick；遍历至多 MAX_PENDING 条记录，正确处理计数回绕。
local function expire_pending(now)
    for token, request in pairs(pending) do
        local elapsed = (now - request.started_at) % 0x100000000
        if request.result == nil and elapsed >= REPLY_TIMEOUT_TICKS then
            request.result = {
                ok = false,
                error = {
                    code = "REMOTE_TIMEOUT",
                    message = "battle response timed out",
                },
            }
            skynet.wakeup(request.thread)
        end
    end
end

-- 扫描超时等待项；每轮最多访问 MAX_PENDING 项，不按请求数创建无界 timer coroutine。
-- 无参数和返回；Service 停止前长驻，执行 sleep/yield。
timeout_loop = function()
    while state.started do
        skynet.sleep(TIMER_INTERVAL_TICKS)
        expire_pending(skynet.now())
    end
end

-- 用 cluster.send 单向转发，再等待 Battle 通过反向 cluster.send 回推关联结果。
-- payload：Gateway 已解码 request record；返回 Battle result record；可能 yield。
-- 失败：并发超限、cluster.send 抛错、等待超时或 Battle 回包违反结构合同。
local function dispatch_remote(payload)
    assert(state.started, "gateway proxy is not started")
    assert(type(payload) == "table", "gateway payload must be a table")
    if pending_count >= MAX_PENDING then
        return {
            ok = false,
            error = { code = "BUSY", message = "gateway battle request limit reached" },
        }
    end

    local thread = coroutine.running()
    assert(thread ~= nil, "gateway dispatch requires a Service coroutine")
    local token = new_route_token()
    local request = { thread = thread, started_at = skynet.now(), result = nil }
    pending[token] = request
    pending_count = pending_count + 1

    local forwarded = {}
    for key, value in pairs(payload) do
        forwarded[key] = value
    end
    forwarded.route_token = token

    local sent_ok, send_error = pcall(
        cluster.send,
        process.cluster.remote_node,
        "@" .. process.cluster.remote_service,
        "gateway_dispatch",
        forwarded
    )
    if not sent_ok then
        pending[token] = nil
        pending_count = pending_count - 1
        return {
            ok = false,
            error = { code = "REMOTE_UNAVAILABLE", message = tostring(send_error) },
        }
    end

    -- cluster.send 不 yield；先检查结果再 wait，避免回包先于 waiter 注册的竞态。
    if request.result == nil then
        skynet.wait(thread)
    end
    pending[token] = nil
    pending_count = pending_count - 1
    return request.result or {
        ok = false,
        error = { code = "REMOTE_TIMEOUT", message = "battle response timed out" },
    }
end

-- 安装固定 Lua dispatch 签名；session/source 是 Skynet 元数据，command/payload 是本地调用者传入。
-- 参数：Skynet lua 消息的固定四个槽位；payload 是 Gateway 已解码 request record。
-- 返回值：本地 handler 等待 reverse result 后 retpack；Cluster 请求使用 send 且不占用远程 session。
skynet.start(function()
    luapanda_debug.start(8818)
    skynet.dispatch("lua", function(_session, _source, command, payload, result)
        if command == "start" then
            skynet.retpack(start())
            return
        end
        if command == "gateway_dispatch" then
            skynet.retpack(dispatch_remote(payload))
            return
        end
        if command == "battle_result" then
            receive_battle_result(payload, result)
            return
        end
        error("unknown gateway_proxy command: " .. tostring(command))
    end)
end)
