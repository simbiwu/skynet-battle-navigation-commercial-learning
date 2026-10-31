#!/usr/bin/env bash
# 第一行 shebang 告诉系统用 Bash 解释本文件；也可显式运行 bash 加脚本路径。
# 调用：可从任意当前工作目录启动；脚本按自身路径定位工程目录。外部相对路径参数按调用时目录解析，建议传绝对路径。
# 示例：bash /absolute/path/to/checkout/server/scripts/linux/run_frame_server.sh [按本文件头部说明填写参数]
# 第三课帧同步 Linux 发布包的运行入口。
#
# 职责：
#   为已解压的发布包提供统一的 start、stop、restart、status 和 doctor 命令。
#   这里只负责选择第三课帧同步运行配置，并把实际工作交给项目已有的
#   manage_lesson_processes.sh；后台启动、READY 等待、PID 校验和 graceful shutdown
#   都由这个统一管理器负责，发布包不再复制另一套进程管理实现。
#
# 目录约定：
#   本脚本在发布包中安装为 server/run_server.sh，因此脚本所在目录就是 Server 根目录。
#   Skynet、运行配置、统一进程管理器、PID 文件和诊断日志都按该根目录定位，
#   所以调用者可以从任意当前目录执行本脚本。
#
# 用法：
#   ./server/run_server.sh start|stop|restart|status|doctor [--gateway|--battle]
#   ./server/run_server.sh help
#
# 生命周期：
#   start 先启动 Battle 并等待 FRAME_BATTLE_READY，再启动 Gateway 并等待 READY。
#   stop 通过 shutdownctl 先优雅停止 Gateway，再停止 Battle。
#   restart 先执行完整 stop，再按 start 顺序重新启动。
#   status 只读取本发布包的 PID 文件并校验进程命令行，不按进程名称查杀。
#
# 环境变量：
#   LESSON_STARTUP_TIMEOUT_SEC 透传给统一进程管理器；默认 20 秒。
#   LESSON_STOP_TIMEOUT_SEC    透传给统一进程管理器；默认 0，表示等待业务关闭完成。
#   这两个变量仅用于调整启动 READY 等待和显式停止超时，不改变端口或业务配置。
#
# 发布边界：
#   发布包已经在构建机完成 Skynet/Native/协议/地图准备；这里不提供 build 或 prepare。
#   需要变更配置时，修改 server/config/frame_sync.lua 并重新制作发布包。
set -euo pipefail

# Bash 语法速读：只解释本脚本实际使用的 Bash 写法；流程注释说明每一步为什么执行。
#   set -euo pipefail：-e 遇到未处理的失败通常退出，但条件判断、&& 和 || 等位置有例外，关键失败仍应显式检查；-u 遇到未设置变量时报错（提供默认值展开时除外）；pipefail 让管道任一步失败都能向外报告。
#   双引号中的 "$NAME" 把变量值作为一个完整参数；路径含空格时不会拆成多个参数。
#   $(命令)运行命令并用标准输出替换当前位置；命令在子 Shell 中运行，里面的 cd 不改变主脚本目录。
#   NAME:-默认值展开：变量未设置或为空字符串时使用默认值。
#   "$@"逐个保留所有位置参数；双引号防止参数中的空格被拆开。
#   $#表示参数个数，$1/$2依次表示传入的第一个/第二个参数。
#   [[ 条件 ]]执行 Bash 条件判断；-f检查普通文件，-x检查可执行文件。
#   case ... in 按输入匹配分支；分支以 ) 开始、;;结束，*)是兜底分支。
#   单竖线 | 把左侧标准输出交给右侧；它不同于条件运算符 ||。
#   >把输出写入并覆盖文件；2>&1把标准错误接到标准输出当前去向。
#   exec 用目标命令替换当前 Shell；外层不再执行后续语句，退出状态由目标命令决定。
#   export 把变量加入子进程环境；普通赋值默认只在当前 Shell 中可见。
# 由脚本绝对路径反推 Server 根目录，确保命令不依赖调用者当前目录。
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER_ROOT="$SCRIPT_DIR"

# 只允许运行期操作，避免发布包误调用源码工作区才具备的构建、测试或资产准备流程。
# $1 是生命周期动作；缺省或空值采用 help。例：传 start 启动服务，不传参数打印用法。
ACTION="${1:-help}"
case "$ACTION" in
    start|stop|restart|status|doctor|help|-h|--help)
        ;;
    *)
        printf '用法：%s start|stop|restart|status|doctor [--gateway|--battle]\n' "$0" >&2
        printf '未知动作：%s\n' "$ACTION" >&2
        exit 2
        ;;
esac

# 确认发布包布局完整后才转发；这些文件由打包白名单逐项纳入。
MANAGER="$SERVER_ROOT/scripts/lessons/manage_lesson_processes.sh"
if [[ ! -f "$MANAGER" ]]; then
    printf '缺少统一进程管理器：%s\n' "$MANAGER" >&2
    exit 1
fi
if [[ ! -x "$SERVER_ROOT/third_party/skynet/skynet" ]]; then
    printf 'Skynet 不存在或不可执行：%s\n' "$SERVER_ROOT/third_party/skynet/skynet" >&2
    exit 1
fi

# 使用现有统一管理器，profile 明确选择第三课帧同步配置，避免误操作状态同步进程。
export LESSON_PROCESS_PROFILE="lesson3-frame-sync"
exec bash "$MANAGER" "$@"
