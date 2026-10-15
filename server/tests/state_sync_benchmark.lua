--- 固定真实BMAP、3单位、60Hz Core的同机采样；不包含Unity播放或网络耗时。
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
local core = require("battle.state_sync.runtime")
for _, count in ipairs({ 1, 16, 32 }) do
    local states, times = {}, {}
    for id = 1, count do
        states[id] = assert(core.create(id))
    end
    for tick = 1, 120 do
        local before = os.clock()
        local budget = { remaining = 4 }
        for _, state in ipairs(states) do
            assert(core.accept_inputs(state, { { input_seq = tick, x = 0, z = 0 } }) == "OK")
            core.step(state, budget)
        end
        times[#times + 1] = (os.clock() - before) * 1000
    end
    table.sort(times)
    local function percentile(p)
        return times[math.ceil(#times * p)]
    end
    print(
        string.format(
            "STATE_BENCH battles=%d units=%d ticks=120 p50_ms=%.3f p95_ms=%.3f p99_ms=%.3f max_ms=%.3f memory_lua_kb=%.1f",
            count,
            count * 3,
            percentile(0.50),
            percentile(0.95),
            percentile(0.99),
            times[#times],
            collectgarbage("count")
        )
    )
    for _, state in ipairs(states) do
        core.close(state)
    end
    collectgarbage("collect")
end
