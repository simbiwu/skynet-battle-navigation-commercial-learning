--- 职责：帧同步Battle进程组合根；先预热发布资产，再启动Worker/Cluster。
--- 边界：仅Battle OS进程启动；Native MapRegistry在本进程内全局共享immutable BMAP。
--- 输入/输出：进程配置和发布资产 -> @frame_dispatch对外Cluster入口。
--- 不负责：Gateway监听、玩家认证、持久化重启恢复。
local skynet  = require "skynet"
local cluster = require "skynet.cluster"
local native  = require "lesson_frame_native"
local conf    = require "config.frame_sync"
local asset   = require "config.frame_sync_asset"

skynet.start(function()
    assert(native.preload(conf.map_path, conf.airnav_path, conf.unit_profiles, conf.navigation_profiles, conf.skills), "FRAME_ASSET_PRELOAD_FAILED")
    local dispatch = skynet.newservice("battle/frame_sync/dispatch")
    assert(skynet.call(dispatch, "lua", "ready"))
    cluster.reload({ [conf.gateway_node] = conf.gateway_address,
                     [conf.battle_node] = conf.battle_address })
    cluster.open(conf.battle_node, 64) -- 参数是Node名称，不是host:port。
    cluster.register("frame_dispatch", dispatch)
    skynet.error("FRAME_BATTLE_READY node=", conf.battle_node, " map=", asset.map_id)
    skynet.exit()
end)
