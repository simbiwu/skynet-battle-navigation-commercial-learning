# FlyWow Logger 接入记录

Gateway 与 Battle 的进程配置直接设置 logservice、logger、flywow_logger_level 和 preload。log_path 使用 Skynet 原生 logger 字段，路径相对 Server 根目录，例如 ./logs/gateway 与 ./logs/battle；等级 normal 会过滤 debug。业务仍只调用 skynet.error。

唯一构建入口为 ./scripts/linux/run_server.sh build，它调用 FlyWow 子模块 scripts/build_flywow.sh，产物统一在 server/third_party/skynet-flywow/build/native/flywow_logger.so。Logger 是 Native Skynet Service，Skynet 通过 cpath 加载；preload 为每个 Lua Service 安装轻量 Lua 适配，因此不需要业务逐个 require。

日志按天写入 YYYY-MM-DD.log，同日重启追加，跨天自动切换；不会自动清理。日志显示具体时间、级别、Service 名/handle 和正文。stdout/stderr 文件仅保留启动与诊断信息。

shutdown_coordinator 在业务清理、最后日志之后等待 Logger flush，成功才报告关闭完成。普通日志定期刷新，error 立即刷新；flush 不等价于 fsync。磁盘阻塞仍占用 Skynet 工作线程，容量需按实际商业负载另行压测。

完整 Native SDK、限流、故障行为和独立测试见 server/third_party/skynet-flywow/docs/logger/README.md。宿主验证命令：

~~~bash
cd server
./scripts/linux/run_server.sh build
./scripts/linux/run_server.sh start
./scripts/linux/run_server.sh stop
python3 tests/gateway_async_integration.py --scope course
~~~
