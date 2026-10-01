-- 职责：验证真实课程 Proxy 的异步投递、路由容量、过期、断线、重复和错误转换。
-- 边界：Unit Test；替换 Cluster/Skynet 调度，不冒充双进程网络验证。
-- 输入/输出：Server 根目录 + FlyWow 根目录 -> PROXY_ASYNC_UNIT_OK 或断言失败。
-- 生命周期：短命 Lua 进程，替身只保留有限测试消息，不启动真实网络。
-- 不负责：不验证业务结算与 Protobuf 编码。
local root = assert(arg[1])
local fw = assert(arg[2])
package.path = root .. "/?.lua;" .. fw .. "/lualib/?.lua;" .. package.path
local now = 0xfffffff0
local local_sends, remote_sends = {}, {}
local dispatch, timer
local fail_send = false
local skynet, cluster = {}, {}

-- 记录本地发送；固定签名不透传 varargs。
function skynet.send(handle, protocol, command, record)
    local_sends[#local_sends + 1] = { handle = handle, command = command, record = record }
    return 0
end
-- 返回模拟的可回绕 tick。
function skynet.now() return now end
-- 返回独立 Proxy handle。
function skynet.self() return 77 end
-- 返回固定启动 tick，隔离 route epoch。
function skynet.hpc() return 123 end
-- 保留扫描协程，测试显式推进。
function skynet.fork(fn) timer = coroutine.create(fn) end
-- 在每轮扫描前挂起，测试控制时钟。
function skynet.sleep() coroutine.yield() end
-- 捕获 Service 分发函数。
function skynet.dispatch(protocol, fn) dispatch = fn end
-- 管理命令无需断言返回值。
function skynet.retpack() end
-- 初始化真实 Proxy 入口。
function skynet.start(fn) fn() end
-- 诊断不作为业务结果。
function skynet.error() end
-- 若 Proxy 又开始等待业务，本测试立即失败。
function skynet.wait() error("Proxy must not wait") end
-- 若 Proxy 仍唤醒请求协程，本测试立即失败。
function skynet.wakeup() error("Proxy must not wake request coroutines") end
-- 替身不修改真实 Cluster 节点。
function cluster.reload() end
-- 替身不监听真实端口。
function cluster.open() end
-- 不注册全局服务名。
function cluster.register() end
-- 只用于启动 ready；运行期不允许通过它等待业务。
function cluster.call(node, service, command)
    assert(command == "ready")
    return true
end
-- 记录单向跨进程投递；失败由测试显式注入。
function cluster.send(node, service, command, payload)
    if fail_send then error("injected send failure") end
    remote_sends[#remote_sends + 1] = payload
end
package.loaded["skynet"] = skynet
package.loaded["skynet.cluster"] = cluster
package.loaded["shared.debug.luapanda_debug"] = { start = function() end }
dofile(root .. "/service/gateway/gateway_proxy.lua")
dispatch(1, 9, "start")
dispatch(1, 9, "bind_gateway", { gateway_service = 99 })

-- 创建独立请求编号；返回纯路由和业务 record，不包含 fd。
local function request(id, connection)
    return { gateway_epoch = "epoch", connection_id = connection or 1,
             request_id = id, command_id = 1001, command = "QueryCell", request = {} }
end

dispatch(0, 99, "gateway_dispatch", request(1))
dispatch(0, 99, "gateway_dispatch", request(2))
assert(#remote_sends == 2 and #local_sends == 0)
dispatch(0, 8, "battle_result", remote_sends[2].route_token, { ok = true, response = { result = 1 } })
dispatch(0, 8, "battle_result", remote_sends[1].route_token, { ok = true, response = { result = 1 } })
assert(local_sends[1].record.request_id == 2 and local_sends[2].record.request_id == 1)
dispatch(0, 8, "battle_result", remote_sends[1].route_token, { ok = true, response = {} })
assert(#local_sends == 2, "duplicate result must be dropped")
dispatch(0, 99, "gateway_dispatch", request(3))
assert(coroutine.resume(timer))
now = 1010
assert(coroutine.resume(timer))
assert(#local_sends == 3 and local_sends[3].record.response.result == 7)
dispatch(0, 8, "battle_result", remote_sends[3].route_token, { ok = true, response = {} })
assert(#local_sends == 3, "late result must be dropped")
for id = 10, 73 do dispatch(0, 99, "gateway_dispatch", request(id)) end
local before = #remote_sends
dispatch(0, 99, "gateway_dispatch", request(74))
assert(#remote_sends == before and local_sends[#local_sends].record.response.result == 7)
dispatch(0, 99, "gateway_disconnect", { gateway_epoch = "epoch", connection_id = 1 })
dispatch(0, 99, "gateway_dispatch", request(75))
assert(#remote_sends == before + 1, "disconnect must release route capacity")
dispatch(0, 8, "battle_result", remote_sends[#remote_sends].route_token, "malformed")
assert(local_sends[#local_sends].record.response.result == 7)
fail_send = true
dispatch(0, 99, "gateway_dispatch", request(76))
assert(local_sends[#local_sends].record.request_id == 76)
fail_send = false
dispatch(0, 99, "gateway_dispatch", request(77))
assert(#remote_sends == before + 2, "send failure must release route capacity")
-- 独立关闭不依赖仍有效的请求 token；发给 composition root 注入的 Gateway。
dispatch(0, 8, "gateway_close", { gateway_epoch = "epoch", connection_id = 1 })
assert(local_sends[#local_sends].command == "gateway_close" and local_sends[#local_sends].handle == 99)
local before_close = #local_sends
dispatch(0, 8, "gateway_close", { gateway_epoch = "epoch", connection_id = "bad" })
assert(#local_sends == before_close)
print("PROXY_ASYNC_UNIT_OK")
