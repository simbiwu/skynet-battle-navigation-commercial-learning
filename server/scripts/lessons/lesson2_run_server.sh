#!/usr/bin/env bash
# 职责：Lesson 2 的课程入口；复用共享进程管理器的 READY、Cluster 优雅关闭与停止超时合同。
# 用法：lesson2_run_server.sh prepare|build|rebuild|start|stop|restart|status|doctor [--gateway|--battle]。
# 参数：生命周期选项原样传给 run_lesson_02_processes.sh；默认同时操作 Gateway 和 Battle。
# 路径：工作目录与依赖路径由下游脚本按自身位置定位；第二课 PID/log 位于 run/lesson2 和 logs/lesson2。
# 环境变量：BUILD_TYPE 传给通用构建脚本；LESSON2_STARTUP_TIMEOUT_SEC 由现有控制器使用。
# 进程：配置固定为 gateway_process.lua 与 battle_process.lua，不会启动第三课服务。
# 日志与停止：完全沿用已有课程控制器，不在此脚本实现第二套生命周期逻辑。
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(cd -- "$HERE/../.." && pwd)"
ACTION="${1:-help}"; [[ $# -eq 0 ]] || shift
case "$ACTION" in
  -h|--help|help) echo "用法：lesson2_run_server.sh prepare|build|rebuild|start|stop|restart|status|doctor [--gateway|--battle]"; exit 0 ;;
  prepare) exec "$SERVER/scripts/linux/build_server.sh" prepare ;;
  build) exec "$SERVER/scripts/linux/build_server.sh" build ;;
  rebuild)
    "$HERE/run_lesson_02_processes.sh" stop --gateway --battle
    exec "$SERVER/scripts/linux/build_server.sh" rebuild ;;
  start|stop|restart|status|doctor) exec "$HERE/run_lesson_02_processes.sh" "$ACTION" "$@" ;;
  *) echo "未知 Lesson 2 动作：$ACTION" >&2; exit 2 ;;
esac
