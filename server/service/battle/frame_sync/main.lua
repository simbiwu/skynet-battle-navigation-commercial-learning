--- 职责：帧同步Battle进程组合根；先预热发布资产，再启动Worker/Cluster。
--- 边界：仅Battle OS进程启动；Native MapRegistry在本进程内全局共享immutable BMAP。
--- 输入/输出：进程配置和发布资产 -> @frame_dispatch对外Cluster入口。
--- 不负责：Gateway监听、玩家认证、持久化重启恢复。
local skynet  = require "skynet"
local cluster = require "skynet.cluster"
local frame_native  = require "lesson_frame_native"
local frame_sync_config    = require "config.frame_sync"
local frame_sync_asset_config   = require "config.frame_sync_asset"
local debug_console_port = tonumber(skynet.getenv("debug_console_port") or "0")

skynet.start(function()
    if debug_console_port > 0 then
        skynet.newservice("debug_console", debug_console_port)
    end
    
    assert(frame_native.preload(frame_sync_config.map_path, frame_sync_config.airnav_path, frame_sync_config.unit_profiles, frame_sync_config.navigation_profiles, frame_sync_config.skills), "FRAME_ASSET_PRELOAD_FAILED")
    local dispatch = skynet.newservice("battle/frame_sync/dispatch")
    assert(skynet.call(dispatch, "lua", "ready"))
    cluster.reload({ [frame_sync_config.gateway_node] = frame_sync_config.gateway_address,
                     [frame_sync_config.battle_node] = frame_sync_config.battle_address })
                     
    cluster.open(frame_sync_config.battle_node, 64) -- 参数是Node名称，不是host:port。
    cluster.register("frame_dispatch", dispatch)
    local shutdown_coordinator = skynet.newservice("admin/lesson3_shutdown_coordinator")
    assert(skynet.call(shutdown_coordinator, "lua", "configure", {
        profile = "frame_sync",
        role = "battle",
        endpoint = "frame_battle_shutdown",
        dispatcher = dispatch,
    }))
    assert(skynet.call(shutdown_coordinator, "lua", "ready"))

    skynet.error("FRAME_BATTLE_READY node=", frame_sync_config.battle_node, " map=", frame_sync_asset_config.map_id)
    skynet.exit()
end)
