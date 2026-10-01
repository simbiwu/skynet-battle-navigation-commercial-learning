-- 职责：启动独立业务进程主动关闭连接的真实 Cluster 测试。
-- 边界：Test Bootstrap；复用 pinned Battle 路径，端口为课程测试2528。
-- 输入/输出：FLYWOW_ROOT -> tests/gateway_close_battle_smoke。
-- 生命周期：集成 runner 独占，finally 只停止自己的进程。
-- 不负责：不改变正常 Battle 配置、不增加客户端协议。
include "skynet_battle.lua"
start = "tests/gateway_close_battle_smoke"
