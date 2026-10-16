#!/usr/bin/env bash
# 职责：Lesson 1 的唯一课程入口，转发准备、构建与单个 server Skynet 进程生命周期。
# 用法：lesson1_run_server.sh prepare|build|rebuild|start|stop|restart|status|doctor。
# 参数：动作参数由下游管理器校验；停止超时只会触发 SIGTERM。
# 路径：所有工作目录由脚本位置解析为 server/；PID 在 run/lesson1/server.pid，诊断日志在 logs/lesson1/server.log。
# 环境变量：BUILD_TYPE 传给通用构建脚本；LESSON_STARTUP_TIMEOUT_SEC/LESSON_STOP_TIMEOUT_SEC 覆盖进程超时。
# 行为：start 管理 config/skynet.lua 的单个 Skynet，等待 NAV_SERVER_READY；日志由配置写入 logs/server/。
# 进程管理：生命周期动作转发到 manage_lesson_processes.sh；不在本入口复制 PID/READY/停止逻辑。
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(cd -- "$HERE/../.." && pwd)"
ACTION="${1:-help}"; [[ $# -eq 0 ]] || shift
case "$ACTION" in
  -h|--help|help) echo "用法：lesson1_run_server.sh prepare|build|rebuild|start|stop|restart|status|doctor"; exit 0 ;;
  prepare) exec "$HERE/prepare_lesson_01.sh" "$@" ;;
  build) exec "$SERVER/scripts/linux/build_server.sh" build ;;
  rebuild)
    LESSON_PROCESS_PROFILE=lesson1 "$HERE/manage_lesson_processes.sh" stop
    exec "$SERVER/scripts/linux/build_server.sh" rebuild ;;
  start|stop|restart|status|doctor)
    LESSON_PROCESS_PROFILE=lesson1 exec "$HERE/manage_lesson_processes.sh" "$ACTION" "$@" ;;
  *) echo "未知 Lesson 1 动作：$ACTION" >&2; exit 2 ;;
esac
