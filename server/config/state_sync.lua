--- 状态同步运行配置；导航与Unit配置继续使用已有唯一源。
--- 全部时间预算以60Hz Tick或Skynet厘秒注明，不读取客户端墙钟。
return {
    tick_rate_hz              = 60,
    snapshot_rate_hz          = 20,
    simulation_version        = 1,
    workers                   = 4,
    max_battles               = 32, -- 每Worker；容量需实测，不是上线承诺。
    max_ticks                 = 10800, -- 180秒后停止战斗。
    max_catchup               = 4,
    max_path_queries_per_poll = 4, -- 单Worker单次10ms轮询最多4次A*；预算不足延后AI重规划。
    retention_cs              = 3000, -- 断线/终态保留30秒。
    input_window              = 24,
    event_window              = 512,
    snapshot_window           = 64,
    replay_limit              = 10800, -- 每Tick至多一条记录；覆盖180秒完整战斗。
    replay_byte_budget        = 8 * 1024 * 1024, -- 编码保守上界；耗尽返回REPLAY_LIMIT。
    gateway_node              = "state_gateway",
    gateway_address           = "127.0.0.1:2547",
    battle_node               = "state_battle",
    battle_address            = "127.0.0.1:2548",
    gateway_port              = 19031,
    map_path                  = "../shared/navigation/battle_1001/battle_1001.bmap",
    manifest_path             = "../shared/navigation/battle_1001/battle_1001.manifest.json",
    unit_profiles             = require("config.unit_profiles"),
    navigation_profiles       = require("config.navigation_profiles"),
    skills                    = {
        { skill_id = 1, range_mm = 900, cooldown_ticks = 36, damage = 14, effect = "instant" },
        { skill_id = 2, range_mm = 9000, cooldown_ticks = 72, damage = 12, effect = "visual" },
        {
            skill_id                    = 3,
            range_mm                    = 9000,
            cooldown_ticks              = 72,
            damage                      = 20,
            effect                      = "projectile",
            projectile_speed_mm_per_sec = 6000,
            projectile_lifetime_ticks   = 180,
            projectile_radius_mm        = 50,
        },
    },
}
