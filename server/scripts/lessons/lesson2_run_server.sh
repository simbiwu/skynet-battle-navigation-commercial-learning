#!/usr/bin/env bash
# 第一行 shebang 告诉系统用 Bash 解释本文件；也可显式运行 bash 加脚本路径。
# 调用：可从任意当前工作目录启动；脚本按自身路径定位工程目录。外部相对路径参数按调用时目录解析，建议传绝对路径。
# 示例：bash /absolute/path/to/checkout/server/scripts/lessons/lesson2_run_server.sh [按本文件头部说明填写参数]
# 职责：Lesson 2 的课程入口；复用共享进程管理器的 READY、Cluster 优雅关闭与停止超时合同。
# 用法：lesson2_run_server.sh prepare|build|rebuild|start|stop|restart|status|doctor [--gateway|--battle]。
# 参数：生命周期选项原样传给 run_lesson_02_processes.sh；默认同时操作 Gateway 和 Battle。
# 路径：工作目录与依赖路径由下游脚本按自身位置定位；第二课 PID/log 位于 run/lesson2 和 logs/lesson2。
# 环境变量：BUILD_TYPE 传给通用构建脚本；LESSON2_STARTUP_TIMEOUT_SEC 由现有控制器使用。
# 进程：配置固定为 gateway_process.lua 与 battle_process.lua，不会启动第三课服务。
# 日志与停止：完全沿用已有课程控制器，不在此脚本实现第二套生命周期逻辑。
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
# BASH_SOURCE[0] 是当前脚本路径；从它反推脚本目录和 server/，不看启动时的 cwd。
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(cd -- "$HERE/../.." && pwd)"

# 没有动作时用 help；有动作时保存进 ACTION，并把剩余位置参数留给下游。
# $1 是脚本后的第一个参数；${1:-help} 在参数缺省或为空时取 help。例：不带参数显示帮助，传 start 则 ACTION=start。
ACTION="${1:-help}"
if [[ $# -gt 0 ]]; then
    shift
fi

# case 按动作分派；exec 直接交接控制权，调用者收到下游命令的退出状态。
case "$ACTION" in
    -h|--help|help)
        echo "用法：lesson2_run_server.sh prepare|build|rebuild|start|stop|restart|status|doctor [--gateway|--battle]"
        exit 0
        ;;
    prepare)
        exec "$SERVER/scripts/linux/build_server.sh" prepare
        ;;
    build)
        exec "$SERVER/scripts/linux/build_server.sh" build
        ;;
    rebuild)
        # 重建前停止 Gateway 和 Battle 两个目标，避免旧进程继续使用被替换的 Native。
        "$HERE/run_lesson_02_processes.sh" stop --gateway --battle
        exec "$SERVER/scripts/linux/build_server.sh" rebuild
        ;;
    start|stop|restart|status|doctor)
        exec "$HERE/run_lesson_02_processes.sh" "$ACTION" "$@"
        ;;
    *)
        echo "未知 Lesson 2 动作：$ACTION" >&2
        exit 2
        ;;
esac
