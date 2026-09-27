-- 职责：把 FlyWow Gateway 的已解码请求转发到独立 Battle Process。
-- 边界：Server Runtime Adapter Service；拥有远程节点配置和 RPC 错误转换，不拥有 fd、frame 或地图状态。
-- 输入/输出：Gateway request record -> cluster.call result record。
-- 生命周期：Gateway Process 启动时初始化一次；每个请求在当前 Service 协程中执行一次远程调用。
-- 不负责：不解析 TCP/WebSocket、不编码 Protobuf、不注册业务 command、不缓存跨请求状态。

local cluster = require "skynet.cluster"
local skynet = require "skynet"
local process = require "config.process_gateway"

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
    local ready_ok, ready_or_error = pcall(
        cluster.call,
        process.cluster.remote_node,
        "@" .. process.cluster.remote_service,
        "ready"
    )
    assert(ready_ok and ready_or_error == true,
           "battle process is not ready: " .. tostring(ready_or_error))
    state.started = true
    return {
        remote_node = process.cluster.remote_node,
        remote_address = process.cluster.remote_address,
    }
end

-- 将一个已解码请求转为远程 Battle dispatch，并把网络不可用转换为稳定错误 record。
-- 参数 payload：FlyWow handler contract 的 request record；调用者拥有 table，本函数不保存借用引用。
-- 返回值：成功时包含 response record；远程失败时包含 error record；调用可能 yield。
-- 失败条件：payload 非 table、远程节点断开、返回 record 不符合合同。
local function dispatch_remote(payload)
    assert(state.started, "gateway proxy is not started")
    assert(type(payload) == "table", "gateway payload must be a table")
    local call_ok, result = pcall(
        cluster.call,
        process.cluster.remote_node,
        "@" .. process.cluster.remote_service,
        "gateway_dispatch",
        payload
    )
    if not call_ok then
        return {
            ok = false,
            error = { code = "REMOTE_UNAVAILABLE", message = tostring(result) },
        }
    end
    if type(result) ~= "table" or (result.ok ~= true and result.ok ~= false) then
        return {
            ok = false,
            error = { code = "REMOTE_BAD_RESULT", message = "battle returned an invalid result record" },
        }
    end
    return result
end

-- 安装固定 Lua dispatch 签名；session/source 是 Skynet 元数据，command/payload 是本地调用者传入。
-- 参数：Skynet lua 消息的固定四个槽位；payload 是 Gateway 已解码 request record。
-- 返回值：通过 skynet.retpack 返回 handler result；远程调用可能 yield，响应前不保存旧引用。
skynet.start(function()
    skynet.dispatch("lua", function(_session, _source, command, payload)
        if command == "start" then
            skynet.retpack(start())
            return
        end
        if command == "gateway_dispatch" then
            skynet.retpack(dispatch_remote(payload))
            return
        end
        error("unknown gateway_proxy command: " .. tostring(command))
    end)
end)
