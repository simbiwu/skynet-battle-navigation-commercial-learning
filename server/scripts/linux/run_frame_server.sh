#!/usr/bin/env bash
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

# 由脚本绝对路径反推 Server 根目录，确保命令不依赖调用者当前目录。
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER_ROOT="$SCRIPT_DIR"

# 只允许运行期操作，避免发布包误调用源码工作区才具备的构建、测试或资产准备流程。
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