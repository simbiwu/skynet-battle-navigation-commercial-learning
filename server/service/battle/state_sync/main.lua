--- 状态同步进程组装；启动期固定导航配置与发布资产，随后不热替换。
local skynet = require("skynet")
local cluster = require("skynet.cluster")
local navigation_api = require("flywow_navigation")
local state_sync_config = require("config.state_sync")
local state_sync_asset_config = require("config.state_sync_asset")
skynet.start(function()
    local profiles, err = navigation_api.load_navigation_profiles(state_sync_config.navigation_profiles)
    if not profiles then
        skynet.error("STATE_BATTLE_START_FAILED navigation profiles code=", tostring(err and err.code))
        skynet.abort()
        return
    end
    local map, map_error = navigation_api.load_map(state_sync_config.map_path)
    if not map then
        skynet.error("STATE_BATTLE_START_FAILED map load code=", tostring(map_error and map_error.code))
        skynet.abort()
        return
    end
    if map.map_id ~= state_sync_asset_config.map_id
        or map.map_version ~= state_sync_asset_config.map_version
        or map.content_sha256 ~= state_sync_asset_config.map_hash then
        skynet.error("STATE_BATTLE_START_FAILED map identity mismatch")
        skynet.abort()
        return
    end
    -- 启动时验证当前样例出生点与配置，探测Context随即释放，不发布临时Battle。
    local core = require("battle.state_sync.runtime")
    local probe, probe_error = core.create(0)
    if not probe then
        skynet.error("STATE_BATTLE_START_FAILED runtime probe: ", tostring(probe_error and probe_error.message))
        skynet.abort()
        return
    end
    core.close(probe)
    local dispatch = skynet.newservice("battle/state_sync/dispatch")
    if skynet.call(dispatch, "lua", "ready") ~= true then
        skynet.error("STATE_BATTLE_START_FAILED dispatcher is not ready")
        skynet.abort()
        return
    end
    cluster.reload({
        [state_sync_config.gateway_node] = state_sync_config.gateway_address,
        [state_sync_config.battle_node] = state_sync_config.battle_address,
    })
    cluster.open(state_sync_config.battle_node, 64)
    cluster.register("state_dispatch", dispatch)
    local shutdown_coordinator = skynet.newservice("admin/lesson3_shutdown_coordinator")
    local configure_result = skynet.call(shutdown_coordinator, "lua", "configure", {
        profile = "state_sync",
        role = "battle",
        endpoint = "state_battle_shutdown",
        dispatcher = dispatch,
    })
    if type(configure_result) ~= "table" or not configure_result.ok then
        skynet.error("STATE_BATTLE_START_FAILED shutdown coordinator configuration")
        skynet.abort()
        return
    end
    if skynet.call(shutdown_coordinator, "lua", "ready") ~= true then
        skynet.error("STATE_BATTLE_START_FAILED shutdown coordinator is not ready")
        skynet.abort()
        return
    end
    skynet.error("STATE_BATTLE_READY")
    skynet.exit()
end)
