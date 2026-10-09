-- 职责：Battle 运行配置；供 Battle Service 通过 require config.battle 读取。
-- 边界：Server Runtime；保存地图、Profile、Cluster 和 Battle 运行参数。
-- 使用：Profile ID 连续递增、只增不删不重排；修改配置后显式向 Native Registry 发布完整表。
-- 不负责：不设置 start、luaservice、lua_path 等 Skynet 进程启动参数。
return {
    worker_count = 4,             -- 固定 BattleWorker Service 数；不是 OS Thread 数。
    tick_ms = 50,                 -- Battle 逻辑 Tick，必须是 10ms 的整数倍。
    heartbeat_cs = 5,             -- Skynet timeout 单位 1/100 秒；5 = 50ms。
    max_battles_per_worker = 128, -- 教学验收上限；超限明确 BUSY。
    max_commands_per_battle = 64, -- 单场尚未执行命令队列上限。
    max_events_buffered = 1024,   -- 在线增量同步 ring buffer 上限。
    max_events_per_sync = 128,    -- 一次 SyncBattle 最多返回事件数。
    snapshot_interval_ticks = 20, -- 20 * 50ms = 1 秒生成一次周期 Snapshot。
    max_catchup_ticks = 4,        -- heartbeat 落后时单次最多补 4 Tick，避免无限追赶。
    finished_retention_cs = 3000, -- 已结束在线 Battle 保留 30 秒供最终 Sync；只影响生命周期。
    max_finished_retained = 128,  -- 每 Worker 最多保留多少个已结束结果，防止缓存无界增长。
    debug_console_port = 8001,    -- 仅开发环境；0 表示不启动。

    -- 启动时一次加载全部 BMAP；每个 map_id 在 Native Registry 中只保留当前地图。
    maps = require "config.maps",
    -- 通用 UnitProfile 由进程入口发布到 sharedata；Navigation 不读取其字段。
    unit_profiles = require "config.unit_profiles",
    -- 导航专用通行参数由进程入口加载到 Native 当前 Registry。
    navigation_profiles = require "config.navigation_profiles",

    cluster = {
        local_listen = 2528,                                 -- Battle Cluster 监听端口；Gateway 连接此端口。
        service_name = "battle_dispatch",                    -- Gateway 发起请求的 Cluster Service 名。
        gateway_node = "gateway",                            -- Gateway Cluster 节点名；Battle 回推使用。
        gateway_address = "127.0.0.1:2527",                 -- Gateway Cluster 地址；格式为 host:port。
        gateway_proxy_service = "gateway_proxy",             -- Gateway 接收 Battle 结果的 Service 名。
        max_clients = 64,                                    -- Battle Cluster 连接上限。
    },
}
