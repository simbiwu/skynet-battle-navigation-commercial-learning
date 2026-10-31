#!/usr/bin/env bash
# 第一行 shebang 告诉系统用 Bash 解释本文件；也可显式运行 bash 加脚本路径。
# 调用：可从任意当前工作目录启动；脚本按自身路径定位工程目录。外部相对路径参数按调用时目录解析，建议传绝对路径。
# 示例：bash /absolute/path/to/checkout/server/scripts/lessons/run_lesson_02_processes.sh [按本文件头部说明填写参数]
# 职责：兼容旧版 Lesson 2 控制器路径，并把调用转交给共享课程进程管理器。
# 用法：run_lesson_02_processes.sh start|stop|restart|status|doctor [--gateway|--battle]。
# 参数：所有位置参数与选项原样传递；动作与选择范围由共享管理器校验。
# 路径：共享管理器据本脚本位置定位 server/，使用 lesson2 配置、run/lesson2 PID 和 logs/lesson2 诊断日志。
# 环境变量：LESSON2_STARTUP_TIMEOUT_SEC 兼容旧环境变量，并映射到共享管理器的启动超时；通用停止超时可用 LESSON_STOP_TIMEOUT_SEC 覆盖。
# 进程与日志：本兼容层不创建 PID、不启动 Skynet、不读取日志；第二课 Cluster shutdownctl 与超时 SIGTERM由共享管理器完成。
set -euo pipefail
# Bash 语法速读：只解释本脚本实际使用的 Bash 写法；流程注释说明每一步为什么执行。
#   set -euo pipefail：-e 遇到未处理的失败通常退出，但条件判断、&& 和 || 等位置有例外，关键失败仍应显式检查；-u 遇到未设置变量时报错（提供默认值展开时除外）；pipefail 让管道任一步失败都能向外报告。
#   双引号中的 "$NAME" 把变量值作为一个完整参数；路径含空格时不会拆成多个参数。
#   $(命令)运行命令并用标准输出替换当前位置；命令在子 Shell 中运行，里面的 cd 不改变主脚本目录。
#   NAME:-默认值展开：变量未设置或为空字符串时使用默认值。
#   "$@"逐个保留所有位置参数；双引号防止参数中的空格被拆开。
#   [[ 条件 ]]执行 Bash 条件判断；-n检查非空字符串，-z检查空字符串。
#   exec 用目标命令替换当前 Shell；外层不再执行后续语句，退出状态由目标命令决定。
#   export 把变量加入子进程环境；普通赋值默认只在当前 Shell 中可见。
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# 兼容变量非空且通用变量为空时才映射；例如仅设置 LESSON2_STARTUP_TIMEOUT_SEC=45 会转成通用超时 45。
if [[ -n "${LESSON2_STARTUP_TIMEOUT_SEC:-}" && -z "${LESSON_STARTUP_TIMEOUT_SEC:-}" ]]; then
    export LESSON_STARTUP_TIMEOUT_SEC="$LESSON2_STARTUP_TIMEOUT_SEC"
fi
LESSON_PROCESS_PROFILE=lesson2 exec "$SCRIPT_DIR/manage_lesson_processes.sh" "$@"
