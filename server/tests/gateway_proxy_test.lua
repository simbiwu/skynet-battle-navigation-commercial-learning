--- 职责：验证当前 Proxy 的双向 send_data、广播和 close，以及输入/启动失败边界。
--- 边界：Unit Test；加载真实 Proxy，替换 Skynet/Cluster，不冒充真实网络验证。
--- 输入/输出：Server 根目录 -> PROXY_SEND_DATA_UNIT_OK 或断言失败。
--- 生命周期：每场景重新加载入口；消息记录有界，不创建路由表或等待业务协程。
local root = assert(arg[1])
package.path = root .. "/?.lua;" .. package.path

--- 创建独立调度替身；只允许启动ready同步调用，数据平面不能等待或创建后台任务。
---@return table 由测试独占的消息记录与分发入口。
local function scenario()
    local test = { local_sends = {}, remote_sends = {}, errors = {}, returns = {} }
    local skynet, cluster = {}, {}
    local config =
    {
        cluster =
        {
            remote_node = "battle", remote_service = "battle_dispatch",
            remote_address = "127.0.0.1:2528", local_listen = 2527,
            max_clients = 64, proxy_service = "gateway_proxy",
        },
    }
    function skynet.self() return 77 end
    function skynet.name(name, handle) assert(name == ".gateway_proxy" and handle == 77) end
    function skynet.start(fn) fn() end
    function skynet.dispatch(protocol, fn)
        assert(protocol == "lua")
        test.dispatch = fn
    end
    function skynet.retpack(value) test.returns[#test.returns + 1] = value end
    function skynet.error(message, detail)
        test.errors[#test.errors + 1] = tostring(message) .. tostring(detail)
    end
    function skynet.send(handle, protocol, command, record)
        assert(protocol == "lua")
        if test.fail_local then return nil end
        test.local_sends[#test.local_sends + 1] =
        {
            handle = handle, command = command, record = record,
        }
        return 0
    end
    function skynet.wait() error("Proxy must not wait") end
    function skynet.wakeup() error("Proxy must not wake request coroutines") end
    function skynet.fork() error("Proxy must not create background tasks") end
    function cluster.reload(nodes)
        assert(nodes.battle == config.cluster.remote_address)
    end
    function cluster.open(port, limit)
        assert(port == 2527 and limit == 64)
    end
    function cluster.register(name, handle)
        assert(name == "gateway_proxy" and handle == 77)
    end
    function cluster.call(node, service, command)
        assert(node == "battle" and service == "@battle_dispatch" and command == "ready")
        if test.fail_ready then error("injected ready failure") end
        return not test.not_ready
    end
    function cluster.send(node, service, command, payload)
        assert(node == "battle" and service == "@battle_dispatch" and command == "send_data")
        if test.fail_remote then error("injected send failure") end
        test.remote_sends[#test.remote_sends + 1] = payload
    end
    package.loaded["skynet"] = skynet
    package.loaded["skynet.manager"] = skynet
    package.loaded["skynet.cluster"] = cluster
    package.loaded["config.gateway"] = config
    package.loaded["shared.debug.luapanda_debug"] = { start = function() end }
    dofile(root .. "/service/gateway/gateway_proxy.lua")
    return test
end

--- 确认非法输入抛错且不发生投递；异常由当前测试捕获，不继续当作成功。
local function rejects(test, source, command, record, expected)
    local local_before, remote_before = #test.local_sends, #test.remote_sends
    local ok, error_message = pcall(test.dispatch, 0, source, command, record)
    assert(not ok and tostring(error_message):find(expected, 1, true), tostring(error_message))
    assert(#test.local_sends == local_before and #test.remote_sends == remote_before)
end

--- 创建当前连接身份和业务record；Proxy透明借用，不包含fd或Socket对象。
local function message(connection)
    local connection_id = connection or 1
    return
    {
        gateway_epoch = "epoch", connection_id = connection_id,
        command_id = 1001, data = { map_id = 1001, map_version = 1 },
        request_id = connection_id == 0 and 0 or 42,
    }
end

local test = scenario()
rejects(test, 99, "send_data", message(), "not ready")
rejects(test, 8, "close", message(), "not ready")
rejects(test, 9, "bind_gateway", { gateway_service = 99 }, "binding is invalid")
test.dispatch(1, 9, "start")
assert(test.returns[1].remote_node == "battle")
assert(test.returns[1].remote_address == "127.0.0.1:2528")
rejects(test, 9, "start", nil, "only start once")
rejects(test, 9, "bind_gateway", { gateway_service = 0 }, "gateway_service")
test.dispatch(1, 9, "bind_gateway", { gateway_service = 99 })
assert(test.returns[2] == true)
rejects(test, 9, "bind_gateway", { gateway_service = 100 }, "binding is invalid")

local request = message()
test.dispatch(0, 99, "send_data", request)
assert(#test.remote_sends == 1 and #test.local_sends == 0)
assert(test.remote_sends[1] == request and request.data.map_id == 1001)
assert(request.route_token == nil and request.request_id == 42)

local response = message()
response.data = { result = 1 }
test.dispatch(0, 8, "send_data", response)
assert(test.local_sends[1].handle == 99 and test.local_sends[1].command == "send_data")
assert(test.local_sends[1].record == response)
local broadcast = message(0)
test.dispatch(0, 8, "send_data", broadcast)
assert(test.local_sends[2].record == broadcast)

--- 数据层不去重、不保存过期表；重复和旧epoch透明转发，连接身份核验归Gateway。
test.dispatch(0, 8, "send_data", response)
local old = message()
old.gateway_epoch = "old-epoch"
test.dispatch(0, 8, "send_data", old)
assert(#test.local_sends == 4 and test.local_sends[4].record == old)
for index = 1, 65 do test.dispatch(0, 99, "send_data", message(index)) end
assert(#test.remote_sends == 66, "Proxy must not retain the old 64-route limit")

for _, change in ipairs(
    {
        { "gateway_epoch", "" }, { "gateway_epoch", string.rep("x", 129) },
        { "gateway_epoch", 1 }, { "connection_id", -1 }, { "connection_id", 1.5 },
        { "command_id", 0 }, { "command_id", 1.5 },
        { "request_id", nil }, { "request_id", 0 }, { "request_id", 1.5 },
        { "data", "bad" },
    })
do
    local invalid = message()
    invalid[change[1]] = change[2]
    rejects(test, 99, "send_data", invalid, change[1] == "data" and "payload" or change[1])
    rejects(test, 8, "send_data", invalid, change[1] == "data" and "payload" or change[1])
end
rejects(test, 99, "send_data", nil, "data is required")

local close = { gateway_epoch = "epoch", connection_id = 1 }
test.dispatch(0, 8, "close", close)
assert(test.local_sends[#test.local_sends].handle == 99)
assert(test.local_sends[#test.local_sends].command == "close")
assert(test.local_sends[#test.local_sends].record == close)
rejects(test, 8, "close", { gateway_epoch = "epoch", connection_id = 0 }, "positive for close")
rejects(test, 8, "close", { gateway_epoch = "", connection_id = 1 }, "gateway_epoch")
rejects(test, 8, "close", { gateway_epoch = "epoch", connection_id = "bad" }, "positive for close")
rejects(test, 99, "gateway_dispatch", message(), "unknown gateway proxy command")
rejects(test, 8, "battle_result", message(), "unknown gateway proxy command")

test.fail_remote = true
local before = #test.remote_sends
test.dispatch(0, 99, "send_data", message())
assert(#test.remote_sends == before and #test.errors == 1)
assert(test.errors[1]:find("GATEWAY_SEND_DATA_TO_BATTLE_FAILED", 1, true))
test.fail_remote = false
test.dispatch(0, 99, "send_data", message())
assert(#test.remote_sends == before + 1)
test.fail_local = true
before = #test.local_sends
test.dispatch(0, 8, "send_data", response)
assert(#test.local_sends == before)
test.fail_local = false
test.dispatch(0, 8, "send_data", response)
assert(#test.local_sends == before + 1)

for _, flag in ipairs({ "fail_ready", "not_ready" }) do
    local failed = scenario()
    failed[flag] = true
    rejects(failed, 9, "start", nil, "battle process is not ready")
    rejects(failed, 99, "send_data", message(), "not ready")
end
print("PROXY_SEND_DATA_UNIT_OK")
