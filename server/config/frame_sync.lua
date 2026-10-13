--- 职责：第三课帧同步Battle、网络与容量预算；Server进程启动时读取。
--- 边界：纯配置，不创建Service；不引用开发机绝对路径。
--- 不负责：规则源码hash、崩溃后持久化恢复、动态Worker迁移。
return
{
    map_path        = "../shared/navigation/battle_1001/battle_1001.bmap",
    airnav_path     = "", -- 空串表示当前发布包没有 AIRN；有配对资产时填写显式 Server 路径。
    client_airnav_asset = "", -- Unity StreamingAssets 下的配对 AIRN 相对路径；与 Server 同时启用。
    unit_profiles   = require "config.unit_profiles",
    navigation_profiles = require "config.navigation_profiles",
    skills = {
        { skill_id = 1, range_mm = 900, cooldown_ticks = 36, damage = 14, target_mask = 1, effect = 1 }, -- 冷却600ms。
        { skill_id = 2, range_mm = 9000, cooldown_ticks = 72, damage = 12, target_mask = 3, effect = 2 }, -- 冷却1200ms。
        { skill_id = 3, range_mm = 9000, cooldown_ticks = 72, damage = 20, target_mask = 3, effect = 3 }, -- 冷却1200ms。
    },
    manifest_path   = "../shared/navigation/battle_1001/battle_1001.manifest.json",
    workers         = 4,    -- 长期Worker Service数，不等于OS线程数。
    max_battles     = 128,  -- 每Worker实例上限；须根据真实负载测量。
    simulation_version = 2, -- 规则不兼容时递增；不维护源码Hash发布系统。
    seats           = 1,    -- 唯一玩家席位；敌人由确定性AI推进。
    tick_rate_hz    = 60,   -- Core固定逻辑频率；不以Skynet Timer间隔定义模拟步长。
    scheduler_poll_cs = 1, -- Skynet时间单位10ms；仅轮询截止，不代表逻辑Tick。
    input_lead      = 6,    -- 初始输入提前6帧（100ms）；按网络实测调整。
    future_window   = 24,    -- 每席位未来允许缓存最多24帧（400ms）。
    input_batch     = 8,    -- 单次输入消息最多8条。
    max_catchup     = 4,    -- 每次heartbeat最多补4帧，仍落后则OVERLOAD。
    max_frames      = 10800, -- 与Native kMaxFrames一致。
    replay_page     = 128,  -- 页面还须受65535字节编码大小约束。
    retention_cs    = 3000, -- 结束或无人在线后30秒释放。
    gateway_node    = "frame_gateway",
    gateway_address = "127.0.0.1:2537",
    battle_node     = "frame_battle",
    battle_address  = "127.0.0.1:2538",
    gateway_port    = 19021,
}
