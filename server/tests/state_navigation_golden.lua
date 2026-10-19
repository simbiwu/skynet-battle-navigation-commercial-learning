--- 本地预测Golden来源为真正的Server Runtime；不以Native自身输出作为期望。
local root = assert(arg[1])
package.path = root
    .. "/?.lua;"
    .. root
    .. "/lualib/?.lua;"
    .. root
    .. "/third_party/skynet-flywow/navigation/lualib/?.lua;"
    .. package.path
package.cpath = root .. "/third_party/skynet-flywow/build/native/?.so;" .. package.cpath
local navigation_api = require("flywow_navigation")
assert(navigation_api.load_navigation_profiles(require("config.navigation_profiles")))
assert(navigation_api.load_map(root .. "/../shared/navigation/battle_1001/battle_1001.bmap"))
local state_sync_runtime = require("battle.state_sync.runtime")
local s = assert(state_sync_runtime.create(1))
for seq = 1, 180 do
    local x = seq <= 60 and 1 or seq <= 120 and 0 or -1
    local z = seq <= 60 and 0 or seq <= 120 and 1 or -1
    assert(state_sync_runtime.accept_inputs(s, { { input_seq = seq, x = x, z = z } }) == "OK")
    state_sync_runtime.step(s)
    local p = s.units[1].position
    print(seq, x, z, p.x_mm, p.y_mm, p.z_mm)
end
state_sync_runtime.close(s)
