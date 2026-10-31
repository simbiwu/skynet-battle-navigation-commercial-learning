#!/usr/bin/env bash
# 第一行 shebang 告诉系统用 Bash 解释本文件；也可显式运行 bash 加脚本路径。
# 调用：可从任意当前工作目录启动；脚本按自身路径定位工程目录。外部相对路径参数按调用时目录解析，建议传绝对路径。
# 示例：bash /absolute/path/to/checkout/server/scripts/lessons/lesson1_run_server.sh [按本文件头部说明填写参数]
# 职责：Lesson 1 的唯一课程入口，转发准备、构建与单个 server Skynet 进程生命周期。
# 用法：lesson1_run_server.sh prepare|build|rebuild|start|stop|restart|status|doctor。
# 参数：动作参数由下游管理器校验；停止超时只会触发 SIGTERM。
# 路径：所有工作目录由脚本位置解析为 server/；PID 在 run/lesson1/server.pid，诊断日志在 logs/lesson1/server.log。
# 环境变量：BUILD_TYPE 传给通用构建脚本；LESSON_STARTUP_TIMEOUT_SEC/LESSON_STOP_TIMEOUT_SEC 覆盖进程超时。
# 行为：start 管理 config/skynet.lua 的单个 Skynet，等待 NAV_SERVER_READY；日志由配置写入 logs/server/。
# 进程管理：生命周期动作转发到 manage_lesson_processes.sh；不在本入口复制 PID/READY/停止逻辑。
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
# BASH_SOURCE[0] 是当前脚本文件的位置；dirname 取目录，再向上两级得到 server/。
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(cd -- "$HERE/../.." && pwd)"

# 参数默认值展开在没有第一个参数或它为空时选择 help；否则 ACTION 保存用户输入的动作。
ACTION="${1:-help}"

# $# 是参数个数。无参数时保留空参数列表；有动作时 shift 移除它，剩余选项交给下游。
if [[ $# -gt 0 ]]; then
    shift
fi

# case 按 ACTION 分派。exec 让目标脚本替换本 Shell，原始退出码直接返回调用者。
case "$ACTION" in
    -h|--help|help)
        echo "用法：lesson1_run_server.sh prepare|build|rebuild|start|stop|restart|status|doctor"
        exit 0
        ;;
    prepare)
        exec "$HERE/prepare_lesson_01.sh" "$@"
        ;;
    build)
        exec "$SERVER/scripts/linux/build_server.sh" build
        ;;
    rebuild)
        # 先停止 Lesson 1 进程，确保重建 Native 时没有旧进程继续使用旧映射。
        # NAME=value command 只为这一次进程设置 profile，不永久修改当前终端环境。
        LESSON_PROCESS_PROFILE=lesson1 "$HERE/manage_lesson_processes.sh" stop
        exec "$SERVER/scripts/linux/build_server.sh" rebuild
        ;;
    start|stop|restart|status|doctor)
        LESSON_PROCESS_PROFILE=lesson1 exec "$HERE/manage_lesson_processes.sh" "$ACTION" "$@"
        ;;
    *)
        echo "未知 Lesson 1 动作：$ACTION" >&2
        exit 2
        ;;
esac
