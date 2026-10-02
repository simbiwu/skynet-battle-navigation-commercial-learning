-- 职责：启动真实 TCP/WS Gateway 异步集成测试进程。
-- 边界：Test Bootstrap；复用正常 Gateway 的 pinned 依赖与路径配置。
-- 输入/输出：仓库内固定FlyWow路径 -> Gateway异步烟雾测试进程。
-- 生命周期：由测试 runner 独占启动/终止；不作为生产配置。
-- 不负责：不生成协议、不调整 Skynet/Protobuf 版本。
include "gateway.lua"
start = "tests/gateway_async_smoke"
