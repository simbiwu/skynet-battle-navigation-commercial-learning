#!/usr/bin/env bash
# 职责：Server 唯一总入口，只解析课程选择/通用构建命令并将参数原样转交，不管理 PID、日志、READY 或服务停止。
# 用法：run_server.sh lesson1|lesson2 <动作> [课程选项]；第三课必须写 lesson3 state-sync|frame-sync <动作>。
# 兼容：无课程限定的 prepare|build|rebuild 仅转发给通用构建脚本，不会启动或停止任何服务。
# 参数：课程入口之后的参数保持原有边界传递；未知课程、缺失第三课方案或缺失动作均报错。
# 路径：课程脚本位置相对本文件推导；可从任意当前目录调用。
# 环境变量：本入口不读取课程运行配置；BUILD_TYPE 等由被调用脚本读取。
# 进程/日志：exec 替换当前 Shell，所有 PID、日志、READY 和优雅停止行为归对应课程脚本。
# 课程隔离：lesson3 state-sync 与 frame-sync 使用不同子入口、配置、日志及 PID 目录。
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
usage(){
 cat <<'USAGE'
用法：
  ./scripts/linux/run_server.sh lesson1 <prepare|build|rebuild|start|stop|restart|status|doctor>
  ./scripts/linux/run_server.sh lesson2 <prepare|build|rebuild|start|stop|restart|status|doctor> [--gateway|--battle]
  ./scripts/linux/run_server.sh lesson3 state-sync <prepare|build|rebuild|test|benchmark|start|stop|restart|status|doctor> [--gateway|--battle]
  ./scripts/linux/run_server.sh lesson3 frame-sync <prepare|build|start|stop|restart|status|doctor> [--gateway|--battle]
  ./scripts/linux/run_server.sh <prepare|build|rebuild>

课程选择必须显式；第三课必须再选择 state-sync 或 frame-sync。
第三课帧同步 Gateway 支持后台 start，随后可用 debug_console 连接其配置端口。
不带课程选择的 prepare/build/rebuild 只执行通用依赖构建，不触碰运行进程。
USAGE
}
[[ $# -gt 0 ]] || { usage >&2; exit 2; }
case "$1" in
 -h|--help) usage; exit 0 ;;
 prepare|build|rebuild) exec "$SERVER_ROOT/scripts/linux/build_server.sh" "$@" ;;
 lesson1) shift; exec "$SERVER_ROOT/scripts/lessons/lesson1_run_server.sh" "$@" ;;
 lesson2) shift; exec "$SERVER_ROOT/scripts/lessons/lesson2_run_server.sh" "$@" ;;
 lesson3)
   shift
   [[ $# -gt 0 ]] || { usage >&2; echo '缺少第三课方案：state-sync 或 frame-sync' >&2; exit 2; }
   variant="$1"; shift
   case "$variant" in state-sync|frame-sync) exec "$SERVER_ROOT/scripts/lessons/lesson3_run_server.sh" "$variant" "$@" ;; *) usage >&2; echo "未知第三课方案：$variant" >&2; exit 2 ;; esac ;;
 *) usage >&2; echo "未知课程或动作：$1" >&2; exit 2 ;;
esac
