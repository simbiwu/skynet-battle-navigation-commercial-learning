#!/usr/bin/env bash
# 职责：Lesson 3 课程分派入口；必须明确选择 state-sync 或 frame-sync，防止误用另一套配置和进程。
# 用法：lesson3_run_server.sh state-sync|frame-sync <动作> [--gateway|--battle]。
# 动作：两种方案均提供 prepare|build|start|stop|restart|status|doctor；状态同步另提供 test|benchmark。
# 参数：课程方案名是必需的第一个参数；动作及角色选项原样转发给对应脚本。
# 路径：状态同步使用 state_*_process.lua 与 state_sync 专属 PID/log；帧同步使用 frame_*_process.lua 与 frame_sync 专属 PID/log。
# 环境变量：BUILD_TYPE、LESSON_STARTUP_TIMEOUT_SEC、LESSON_STOP_TIMEOUT_SEC 由所调用子脚本读取。
# 日志/生命周期：通过统一管理器处理 READY、PID 和诊断日志；stop 先走第三课 shutdownctl drain/资源释放，超时再回退 SIGTERM。
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(cd -- "$HERE/../.." && pwd)"
COURSE="${1:-}"; [[ $# -gt 0 ]] && shift || true
ACTION="${1:-help}"; [[ $# -eq 0 ]] || shift
case "$COURSE" in
  state-sync)
    case "$ACTION" in
      -h|--help|help) echo "用法：lesson3_run_server.sh state-sync prepare|build|test|benchmark|start|stop|restart|status|doctor [--gateway|--battle]"; exit 0 ;;
      prepare|build|test|benchmark) exec "$HERE/lesson3_run_state_sync.sh" "$ACTION" "$@" ;;
      rebuild)
        LESSON_PROCESS_PROFILE=lesson3-state-sync "$HERE/manage_lesson_processes.sh" stop
        "$SERVER/scripts/linux/build_server.sh" rebuild
        exec "$HERE/lesson3_run_state_sync.sh" build ;;
      start|stop|restart|status|doctor) LESSON_PROCESS_PROFILE=lesson3-state-sync exec "$HERE/manage_lesson_processes.sh" "$ACTION" "$@" ;;
      *) echo "未知第三课状态同步动作：$ACTION" >&2; exit 2 ;;
    esac ;;
  frame-sync)
    case "$ACTION" in
      -h|--help|help) echo "用法：lesson3_run_server.sh frame-sync prepare|build|rebuild|start|stop|restart|status|doctor [--gateway|--battle]"; exit 0 ;;
      prepare) exec "$SERVER/scripts/linux/build_server.sh" prepare ;;
      build|rebuild)
        if [[ "$ACTION" == rebuild ]]; then
          LESSON_PROCESS_PROFILE=lesson3-frame-sync "$HERE/manage_lesson_processes.sh" stop
          "$SERVER/scripts/linux/build_server.sh" rebuild
        else
          "$SERVER/scripts/linux/build_server.sh" build
        fi
        bash "$SERVER/protocol/build_protocol_lesson_03_frame_sync.sh"
        bash "$HERE/lesson3_build_frame_sync_native.sh"
        exit 0 ;;
      start|stop|restart|status|doctor) LESSON_PROCESS_PROFILE=lesson3-frame-sync exec "$HERE/manage_lesson_processes.sh" "$ACTION" "$@" ;;
      *) echo "未知第三课帧同步动作：$ACTION" >&2; exit 2 ;;
    esac ;;
  *) echo "必须明确选择 state-sync 或 frame-sync；收到：$COURSE" >&2; exit 2 ;;
esac
