--- 真实Core/Native加可控Skynet调度：验证Worker身份、容量、恢复重试、终态和超时释放。
local root = assert(arg[1])
package.path = root
    .. "/?.lua;"
    .. root
    .. "/lualib/?.lua;"
    .. root
    .. "/third_party/skynet-flywow/navigation/lualib/?.lua;"
    .. package.path
package.cpath = root .. "/third_party/skynet-flywow/build/native/?.so;" .. package.cpath
local nav = require("flywow_navigation")
assert(nav.load_navigation_profiles(require("config.navigation_profiles")))
assert(nav.load_map(root .. "/../shared/navigation/battle_1001/battle_1001.bmap"))
local conf = require("config.state_sync")
conf.max_battles = 2
conf.retention_cs = 3
conf.max_ticks = 90 -- 此独立测试缩短寿命，不改真实配置文件。
local core = require("battle.state_sync.runtime")
local actual_create = core.create
local owned = {}
core.create = function(id)
    local value, err = actual_create(id)
    owned[id] = value
    return value, err
end
local e = { now = 0, sends = {} }
local skynet = {}
function skynet.now()
    return e.now
end
function skynet.start(fn)
    fn()
end
function skynet.dispatch(_, fn)
    e.dispatch = fn
end
function skynet.retpack(value)
    e.result = value
end
function skynet.timeout(_, fn)
    e.heartbeat = fn
end
function skynet.send(handle, protocol, command, payload)
    assert(handle == 9 and protocol == "lua" and command == "state_push")
    e.sends[#e.sends + 1] = payload
end
function skynet.error() end
function skynet.exit() end
package.loaded["skynet"] = skynet
dofile(root .. "/service/battle/state_sync/worker.lua")
e.dispatch(1, 9, "configure", { dispatcher = 9 })
local original = { gateway_epoch = "epoch", connection_id = 1 }
local replacement = { gateway_epoch = "epoch", connection_id = 2 }
local function call(action, id, req, session)
    e.result = nil
    e.dispatch(
        1,
        9,
        "control",
        { action = action, battle_id = id, request = req, session = session or original }
    )
    return assert(e.result)
end
local initial = call("create", 1, { scenario_id = 1001, simulation_version = 1 })
assert(initial.code == "OK" and #initial.resume_token == 32)
local second = call("create", 2, { scenario_id = 1001, simulation_version = 1 })
assert(second.code == "OK")
assert(call("create", 3, { scenario_id = 1001, simulation_version = 1 }).code == "BUSY")
local function input(generation, session)
    return call(
        "inputs",
        1,
        {
            generation = generation,
            ack_snapshot_seq = 0,
            ack_event_seq = 0,
            inputs = { { input_seq = 1, x = 1, z = 0 } },
        },
        session
    )
end
assert(input(1).code == "OK")
e.now = 2
e.heartbeat()
assert(owned[1].consumed == 1)
local recovered = call("recover", 1, { resume_token = initial.resume_token }, replacement).state
assert(recovered.code == "OK" and recovered.generation == 2)
assert(
    recovered.resume_token == initial.resume_token,
    "lost recovery reply cannot invalidate sole credential"
)
assert(input(1).code == "NOT_FOUND")
local retried = call("recover", 1, { resume_token = initial.resume_token }, replacement).state
assert(retried.code == "OK" and retried.generation == 3)
assert(
    call("inputs", 1, { generation = 3, ack_snapshot_seq = 999, ack_event_seq = 0 }, replacement).code
        == "BAD_ACK"
)
assert(call("recover", 1, { resume_token = "invalid" }, replacement).state.code == "NOT_FOUND")
for n = 3, 154 do
    e.now = n
    e.heartbeat()
end
assert(owned[1].closed and owned[2].closed, "terminal Battle must release Context immediately")
local value, err = owned[1].context:cell_size_mm()
assert(value == nil and err.code == "CONTEXT_CLOSED")
assert(
    call("resync", 1, { generation = 3 }, replacement).code == "NOT_FOUND",
    "expired Battle must be removed"
)
-- 容量释放后可创建；大幅落后必须明确OVERLOAD，不变成可变dt模拟。
assert(call("create", 4, { scenario_id = 1001, simulation_version = 1 }).code == "OK")
e.now = 250
e.heartbeat()
assert(owned[4].closed)
assert(call("resync", 4, { generation = 1 }).code == "OVERLOAD")
print("STATE_WORKER_TEST_OK")
