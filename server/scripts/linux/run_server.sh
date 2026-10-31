#!/usr/bin/env bash
# 第一行 shebang 告诉系统用 Bash 解释本文件；也可显式运行 bash 加脚本路径。
# 调用：可从任意当前工作目录启动；脚本按自身路径定位工程目录。外部相对路径参数按调用时目录解析，建议传绝对路径。
# 示例：bash /absolute/path/to/checkout/server/scripts/linux/run_server.sh [按本文件头部说明填写参数]
# 职责：Server 唯一总入口，只解析课程选择/通用构建命令并将参数原样转交，不管理 PID、日志、READY 或服务停止。
# 用法：run_server.sh lesson1|lesson2 <动作> [课程选项]；第三课必须写 lesson3 state-sync|frame-sync <动作>。
# 兼容：无课程限定的 prepare|build|rebuild 仅转发给通用构建脚本，不会启动或停止任何服务。
# 参数：课程入口之后的参数保持原有边界传递；未知课程、缺失第三课方案或缺失动作均报错。
# 路径：课程脚本位置相对本文件推导；可从任意当前目录调用。
# 环境变量：本入口不读取课程运行配置；BUILD_TYPE 等由被调用脚本读取。
# 进程/日志：exec 替换当前 Shell，所有 PID、日志、READY 和优雅停止行为归对应课程脚本。
# 课程隔离：lesson3 state-sync 与 frame-sync 使用不同子入口、配置、日志及 PID 目录。
set -euo pipefail
# Bash 语法速读：只解释本脚本实际使用的 Bash 写法；流程注释说明每一步为什么执行。
#   set -euo pipefail：-e 遇到未处理的失败通常退出，但条件判断、&& 和 || 等位置有例外，关键失败仍应显式检查；-u 遇到未设置变量时报错（提供默认值展开时除外）；pipefail 让管道任一步失败都能向外报告。
#   双引号中的 "$NAME" 把变量值作为一个完整参数；路径含空格时不会拆成多个参数。
#   $(命令)运行命令并用标准输出替换当前位置；命令在子 Shell 中运行，里面的 cd 不改变主脚本目录。
#   "$@"逐个保留所有位置参数；双引号防止参数中的空格被拆开。
#   $#表示参数个数，$1/$2依次表示传入的第一个/第二个参数。
#   shift 丢弃第一个位置参数，其余参数向前移动一位。
#   [[ 条件 ]]执行 Bash 条件判断；具体比较符见对应条件。
#   case ... in 按输入匹配分支；分支以 ) 开始、;;结束，*)是兜底分支。
#   name() { ...; }定义函数；调用函数名即可执行函数体。
#   单竖线 | 把左侧标准输出交给右侧；它不同于条件运算符 ||。
#   >把输出写入并覆盖文件；2>&1把标准错误接到标准输出当前去向。
#   exec 用目标命令替换当前 Shell；外层不再执行后续语句，退出状态由目标命令决定。
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# usage 打印可复制的参数格式；带引号的 here-document 不会把 $ACTION 等字样展开。
usage() {
 cat <<'USAGE'
用法：
  bash /path/to/server/scripts/linux/run_server.sh lesson1 <prepare|build|rebuild|start|stop|restart|status|doctor>
  bash /path/to/server/scripts/linux/run_server.sh lesson2 <prepare|build|rebuild|start|stop|restart|status|doctor> [--gateway|--battle]
  bash /path/to/server/scripts/linux/run_server.sh lesson3 state-sync <prepare|build|rebuild|test|benchmark|start|stop|restart|status|doctor> [--gateway|--battle]
  bash /path/to/server/scripts/linux/run_server.sh lesson3 frame-sync <prepare|build|start|stop|restart|status|doctor> [--gateway|--battle]
  bash /path/to/server/scripts/linux/run_server.sh <prepare|build|rebuild>

课程选择必须显式；第三课必须再选择 state-sync 或 frame-sync。
第三课帧同步 Gateway 支持后台 start，随后可用 debug_console 连接其配置端口。
不带课程选择的 prepare/build/rebuild 只执行通用依赖构建，不触碰运行进程。
USAGE
}
# $# 是调用者给的参数数量；没有参数时先显示帮助并用 2 表示命令格式错误。
[[ $# -gt 0 ]] || { usage >&2; exit 2; }

# case 只负责选择目标脚本；shift 移除已经识别的课程名，剩余参数保持原顺序转发。
case "$1" in
    -h|--help)
        usage
        exit 0
        ;;
    prepare|build|rebuild)
        # 通用构建动作不带课程生命周期，完整参数交给唯一构建脚本校验。
        exec "$SERVER_ROOT/scripts/linux/build_server.sh" "$@"
        ;;
    lesson1)
        shift
        exec "$SERVER_ROOT/scripts/lessons/lesson1_run_server.sh" "$@"
        ;;
    lesson2)
        shift
        exec "$SERVER_ROOT/scripts/lessons/lesson2_run_server.sh" "$@"
        ;;
    lesson3)
        shift
        # shift 后必须仍有方案名；缺失时在访问 $1 前返回，避免 set -u 报变量错误。
        [[ $# -gt 0 ]] || {
            usage >&2
            echo '缺少第三课方案：state-sync 或 frame-sync' >&2
            exit 2
        }

        variant="$1"
        shift
        case "$variant" in
            state-sync|frame-sync)
                exec "$SERVER_ROOT/scripts/lessons/lesson3_run_server.sh" "$variant" "$@"
                ;;
            *)
                usage >&2
                echo "未知第三课方案：$variant" >&2
                exit 2
                ;;
        esac
        ;;
    *)
        usage >&2
        echo "未知课程或动作：$1" >&2
        exit 2
        ;;
esac
