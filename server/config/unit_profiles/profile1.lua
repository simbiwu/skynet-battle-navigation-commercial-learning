-- 职责：定义稳定 Unit 类型 ID=1 的通用基础配置。
-- 边界：Battle 进程级共享业务配置；由启动入口发布到 sharedata。
-- 输入/输出：无输入 -> 一份 UnitProfile record。
-- 生命周期：启动时发布；业务通过 sharedata 读取，不被 Navigation 复制或缓存。
-- 不负责：不包含导航专用参数，不保存单位运行时速度、位置或 Battle 状态。
return {
    unit_id = 1,
    combat = {
        attack_range_mm = 900, -- 双方中心 XZ 距离上限；导航半径不参与攻击判定。
    },
}
