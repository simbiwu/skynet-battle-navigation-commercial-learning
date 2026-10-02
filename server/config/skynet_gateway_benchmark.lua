--- 职责：启动本机多连接压测，复用固定依赖并关闭调试。
--- 边界：仅测试启动配置；不修改生产配置或协议。
include "gateway_process.lua"
start = "tests/gateway_benchmark"
luapanda = false
