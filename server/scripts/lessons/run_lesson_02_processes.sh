#!/usr/bin/env bash
# 职责：兼容旧版 Lesson 2 控制器路径，并把调用转交给共享课程进程管理器。
# 用法：run_lesson_02_processes.sh start|stop|restart|status|doctor [--gateway|--battle]。
# 参数：所有位置参数与选项原样传递；动作与选择范围由共享管理器校验。
# 路径：共享管理器据本脚本位置定位 server/，使用 lesson2 配置、run/lesson2 PID 和 logs/lesson2 诊断日志。
# 环境变量：LESSON2_STARTUP_TIMEOUT_SEC 兼容旧环境变量，并映射到共享管理器的启动超时；通用停止超时可用 LESSON_STOP_TIMEOUT_SEC 覆盖。
# 进程与日志：本兼容层不创建 PID、不启动 Skynet、不读取日志；第二课 Cluster shutdownctl 与超时 SIGTERM由共享管理器完成。
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${LESSON2_STARTUP_TIMEOUT_SEC:-}" && -z "${LESSON_STARTUP_TIMEOUT_SEC:-}" ]]; then
    export LESSON_STARTUP_TIMEOUT_SEC="$LESSON2_STARTUP_TIMEOUT_SEC"
fi
LESSON_PROCESS_PROFILE=lesson2 exec "$SCRIPT_DIR/manage_lesson_processes.sh" "$@"
