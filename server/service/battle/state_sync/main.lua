--- 状态同步进程组装；启动期固定导航配置与发布资产，随后不热替换。
local skynet = require("skynet")
local cluster = require("skynet.cluster")
local navigation_api = require("flywow_navigation")
local state_sync_config = require("config.state_sync")
local state_sync_asset_config = require("config.state_sync_asset")
skynet.start(function()
    local profiles, err = navigation_api.load_navigation_profiles(state_sync_config.navigation_profiles)
    assert(profiles, err and err.code)
    local map, map_error = navigation_api.load_map(state_sync_config.map_path)
    assert(map, map_error and map_error.code)
    assert(
        map.map_id == state_sync_asset_config.map_id
            and map.map_version == state_sync_asset_config.map_version
            and map.content_sha256 == state_sync_asset_config.map_hash,
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
        [state_sync_config.gateway_node] = state_sync_config.gateway_address,
        [state_sync_config.battle_node] = state_sync_config.battle_address,
    })
    cluster.open(state_sync_config.battle_node, 64)
    cluster.register("state_dispatch", dispatch)
    local shutdown_coordinator = skynet.newservice("admin/lesson3_shutdown_coordinator")
    assert(skynet.call(shutdown_coordinator, "lua", "configure", {
        profile = "state_sync",
        role = "battle",
        endpoint = "state_battle_shutdown",
        dispatcher = dispatch,
    }))
    assert(skynet.call(shutdown_coordinator, "lua", "ready"))
    skynet.error("STATE_BATTLE_READY")
    skynet.exit()
end)
