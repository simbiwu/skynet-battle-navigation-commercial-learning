-- 职责：为第 14 节 Lua/Native Smoke 选择独立启动入口。
-- 边界：Server Runtime Bootstrap 配置；复用基础 Skynet 配置。
-- 输入/输出：已有 Skynet/FlyWow/Native 构建 -> 单次 Smoke Service。
-- 生命周期：Skynet 启动时读取一次；不拥有地图或 Context。
-- 不负责：不运行正式 Gateway，不复制搜索路径或地图业务配置。
include "skynet.lua"
start = "battle/navigation_smoke"