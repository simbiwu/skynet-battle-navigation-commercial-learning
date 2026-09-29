-- 职责：为自动战斗验收选择 batch_runner，而不改正常 Gateway 的启动入口。
-- 边界：Server Runtime Bootstrap 配置；复用同目录的基础 Skynet 配置。
-- 输入/输出：基础配置和已构建的依赖 -> 单次 Battle 批量入口。
-- 生命周期：Skynet 进程启动时读取一次；不拥有 Battle/Map 状态。
-- 不负责：不加载 BMAP、不运行战斗核心、不创建第二套 Lua 搜索路径。
include "skynet.lua"
start = "battle/batch_runner"