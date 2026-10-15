--- 状态同步进程组装；启动期固定导航配置与发布资产，随后不热替换。
local skynet = require("skynet")
local cluster = require("skynet.cluster")
local nav = require("flywow_navigation")
local conf = require("config.state_sync")
local asset = require("config.state_sync_asset")
skynet.start(function()
    local profiles, err = nav.load_navigation_profiles(conf.navigation_profiles)
    assert(profiles, err and err.code)
    local map, map_error = nav.load_map(conf.map_path)
    assert(map, map_error and map_error.code)
    assert(
        map.map_id == asset.map_id
            and map.map_version == asset.map_version
            and map.content_sha256 == asset.map_hash,
        "STATE_MAP_IDENTITY"
    )
    -- 启动时验证当前样例出生点与配置，探测Context随即释放，不发布临时Battle。
    local core = require("battle.state_sync.runtime")
    local probe, probe_error = core.create(0)
    assert(probe, probe_error and probe_error.message)
    core.close(probe)
    local dispatch = skynet.newservice("battle/state_sync/dispatch")
    assert(skynet.call(dispatch, "lua", "ready"))
    cluster.reload({
        [conf.gateway_node] = conf.gateway_address,
        [conf.battle_node] = conf.battle_address,
    })
    cluster.open(conf.battle_node, 64)
    cluster.register("state_dispatch", dispatch)
    skynet.error("STATE_BATTLE_READY")
    skynet.exit()
end)
