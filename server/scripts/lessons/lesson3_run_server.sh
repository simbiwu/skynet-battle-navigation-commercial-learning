#!/usr/bin/env bash
# 第一行 shebang 告诉系统用 Bash 解释本文件；也可显式运行 bash 加脚本路径。
# 调用：可从任意当前工作目录启动；脚本按自身路径定位工程目录。外部相对路径参数按调用时目录解析，建议传绝对路径。
# 示例：bash /absolute/path/to/checkout/server/scripts/lessons/lesson3_run_server.sh [按本文件头部说明填写参数]
# 职责：Lesson 3 课程分派入口；必须明确选择 state-sync 或 frame-sync，防止误用另一套配置和进程。
# 用法：lesson3_run_server.sh state-sync|frame-sync <动作> [--gateway|--battle]。
# 动作：两种方案均提供 prepare|build|start|stop|restart|status|doctor；状态同步另提供 test|benchmark。
# 参数：课程方案名是必需的第一个参数；动作及角色选项原样转发给对应脚本。
# 路径：状态同步使用 state_*_process.lua 与 state_sync 专属 PID/log；帧同步使用 frame_*_process.lua 与 frame_sync 专属 PID/log。
# 环境变量：BUILD_TYPE、LESSON_STARTUP_TIMEOUT_SEC、LESSON_STOP_TIMEOUT_SEC 由所调用子脚本读取。
# 日志/生命周期：通过统一管理器处理 READY、PID 和诊断日志；stop 先走第三课 shutdownctl drain/资源释放，超时再回退 SIGTERM。
set -euo pipefail
# Bash 语法速读：只解释本脚本实际使用的 Bash 写法；流程注释说明每一步为什么执行。
#   set -euo pipefail：-e 遇到未处理的失败通常退出，但条件判断、&& 和 || 等位置有例外，关键失败仍应显式检查；-u 遇到未设置变量时报错（提供默认值展开时除外）；pipefail 让管道任一步失败都能向外报告。
#   双引号中的 "$NAME" 把变量值作为一个完整参数；路径含空格时不会拆成多个参数。
#   $(命令)运行命令并用标准输出替换当前位置；命令在子 Shell 中运行，里面的 cd 不改变主脚本目录。
#   NAME:-默认值展开：变量未设置或为空字符串时使用默认值。
#   "$@"逐个保留所有位置参数；双引号防止参数中的空格被拆开。
#   $#表示参数个数，$1/$2依次表示传入的第一个/第二个参数。
#   shift 丢弃第一个位置参数，其余参数向前移动一位。
#   [[ 条件 ]]执行 Bash 条件判断；具体比较符见对应条件。
#   case ... in 按输入匹配分支；分支以 ) 开始、;;结束，*)是兜底分支。
#   单竖线 | 把左侧标准输出交给右侧；它不同于条件运算符 ||。
#   >把输出写入并覆盖文件；2>&1把标准错误接到标准输出当前去向。
#   exec 用目标命令替换当前 Shell；外层不再执行后续语句，退出状态由目标命令决定。
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(cd -- "$HERE/../.." && pwd)"
# $1 是第一个位置参数；${1:-} 缺省时为空。shift 删除已读参数，让后续 $1 成为动作；例如 state-sync start 解析为 COURSE=state-sync、ACTION=start。
COURSE="${1:-}"; [[ $# -gt 0 ]] && shift || true
# 读取动作参数；没有动作时使用 help。移除动作后，剩余参数（如 --gateway）留给下游脚本。
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
