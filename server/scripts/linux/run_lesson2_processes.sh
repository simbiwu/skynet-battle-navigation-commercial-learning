#!/usr/bin/env bash
# 职责：启动、停止、查看和诊断 Lesson 2 的 Gateway/Battle 双 Skynet 进程。
# 边界：Server Runtime Deployment/Test；只管理本课程的两个进程和 PID/log。
# 输入/输出：动作 -> 两个 Skynet 进程、run/lesson2/*.pid、logs/lesson2/*.log。
# 生命周期：脚本短命；两个 Skynet 进程分别拥有 Service、cluster 和业务状态。
# 不负责：不构建 Native、不生成协议、不复制 FlyWow、不替代生产编排器。
set -euo pipefail
# -e：任一步失败立即退出，避免只启动一个进程却报告成功。
# -u：未定义变量立即失败，尽早发现变量名和配置错误。
# pipefail：管道任一命令失败都会向控制器传播。

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
SERVER_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
SKYNET_BIN="$SERVER_ROOT/third_party/skynet/skynet"
RUN_DIR="$SERVER_ROOT/run/lesson2"
LOG_DIR="$SERVER_ROOT/logs/lesson2"
GATEWAY_PID_FILE="$RUN_DIR/gateway.pid"
BATTLE_PID_FILE="$RUN_DIR/battle.pid"
GATEWAY_LOG="$LOG_DIR/gateway.log"
BATTLE_LOG="$LOG_DIR/battle.log"
STARTUP_TIMEOUT_SEC=20
FORCE_STOP=0
ACTION="start"
FLYWOW_ROOT="$(printenv FLYWOW_ROOT || true)"

# 输出一条带脚本前缀的普通日志；参数是要显示的完整消息，返回状态始终为 0。
log() { printf '[lesson2-processes] %s\n' "$*"; }
# 输出错误并结束脚本；参数是面向操作者的失败原因，退出状态固定为 1。
fail() { printf '[lesson2-processes] ERROR: %s\n' "$*" >&2; exit 1; }

# 解析动作；未知参数在任何进程启动前失败。
parse_args() {
    if [[ $# -gt 0 && "$1" != --* ]]; then ACTION="$1"; shift; fi
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) FORCE_STOP=1 ;;
            -h|--help) usage; exit 0 ;;
            *) fail "unknown argument: $1" ;;
        esac
        shift
    done
    case "$ACTION" in
        start|stop|restart|status|doctor) ;;
        *) usage >&2; fail "unknown action: $ACTION" ;;
    esac
}

# 显示动作和覆盖项；不改变运行状态。
usage() {
    cat <<'USAGE'
Usage:
  ./scripts/linux/run_lesson2_processes.sh start
  ./scripts/linux/run_lesson2_processes.sh stop [--force]
  ./scripts/linux/run_lesson2_processes.sh restart
  ./scripts/linux/run_lesson2_processes.sh status
  ./scripts/linux/run_lesson2_processes.sh doctor

Environment:
  FLYWOW_ROOT=/path/to/skynet-flywow
USAGE
}

# submodule 是正常来源，sibling 只用于开发覆盖；返回已验证的框架根目录。
find_flywow_root() {
    local candidate
    if [[ -n "$FLYWOW_ROOT" ]]; then
        candidate="$FLYWOW_ROOT"
    else
        for candidate in "$SERVER_ROOT/third_party/skynet-flywow" "$SERVER_ROOT/../../skynet-flywow"; do
            if [[ -f "$candidate/service/flywow_gateway.lua" ]]; then
                FLYWOW_ROOT="$(cd -- "$candidate" && pwd)"
                export FLYWOW_ROOT
                return 0
            fi
        done
        return 1
    fi
    [[ -f "$candidate/service/flywow_gateway.lua" ]] || return 1
    FLYWOW_ROOT="$(cd -- "$candidate" && pwd)"
    export FLYWOW_ROOT
}

# 检查二进制、配置、框架和生成 registry；不启动进程。
doctor() {
    [[ -x "$SKYNET_BIN" ]] || fail "Skynet binary missing; run run_server.sh build"
    [[ -f "$SERVER_ROOT/config/skynet_gateway.lua" && -f "$SERVER_ROOT/config/skynet_battle.lua" ]] || fail "process configs missing"
    [[ -f "$SERVER_ROOT/service/gateway_main.lua" && -f "$SERVER_ROOT/service/battle_main.lua" && -f "$SERVER_ROOT/service/gateway_proxy.lua" ]] || fail "process services missing"
    # 双进程 READY 依赖真正的 Battle 分发入口与已实现的 Manager/Worker。
    [[ -f "$SERVER_ROOT/service/battle_dispatch.lua" &&
       -f "$SERVER_ROOT/service/battle/battle_mgr.lua" &&
       -f "$SERVER_ROOT/service/battle/battle_worker.lua" ]] ||
        fail "battle dispatch or worker services missing"
    find_flywow_root || fail "FlyWow submodule missing; run git submodule update --init --recursive"
    [[ -s "$SERVER_ROOT/lualib/protocol/navigation_registry.lua" ]] || fail "registry missing; run run_server.sh build"
    log "DOCTOR_OK flywow=$FLYWOW_ROOT"
}

# 创建 PID 与日志目录并限制新文件权限；无参数、失败由 set -e 传播，不清理旧日志。
ensure_dirs() { umask 027; mkdir -p "$RUN_DIR" "$LOG_DIR"; }

# 读取 PID，并确认命令行仍指向本脚本使用的配置，避免误杀其它 Skynet。
read_owned_pid() {
    local file="$1"; local config="$2"; local pid
    [[ -s "$file" ]] || return 1
    pid="$(tr -d '[:space:]' < "$file")"
    [[ "$pid" =~ ^[0-9]+$ ]] || fail "invalid PID file: $file"
    kill -0 "$pid" 2>/dev/null || return 1
    ps -p "$pid" -o args= | grep -F -- "$config" >/dev/null || fail "PID $pid is not $config"
    printf '%s\n' "$pid"
}

# 启动一个角色；stdout/stderr 固定进入角色日志，调用方等待 READY。
start_one() {
    local role="$1"; local config="$2"; local pid_file="$3"; local log_file="$4"; local pid
    if pid="$(read_owned_pid "$pid_file" "$config")"; then fail "$role already running: pid=$pid"; fi
    rm -f "$pid_file"
    (
        cd "$SERVER_ROOT"
        if [[ "$role" == "gateway" ]]; then export FLYWOW_ROOT; fi
        exec "$SKYNET_BIN" "$SERVER_ROOT/config/$config"
    ) >"$log_file" 2>&1 &
    pid="$!"; printf '%s\n' "$pid" > "$pid_file"
    log "started role=$role pid=$pid log=$log_file"
    # 后台 shell 的 exec 可能尚未完成；留出一个调度机会，避免立刻读取到临时命令行。
    sleep 1
}

# 等待固定 READY 标记，进程提前退出或超时都失败。
wait_ready() {
    local role="$1"; local pid_file="$2"; local config="$3"; local log_file="$4"; local marker="$5"; local pid; local i
    if ! pid="$(read_owned_pid "$pid_file" "$config")"; then
        log "ERROR: $role exited before READY; see $log_file"
        return 1
    fi
    for ((i=0; i<STARTUP_TIMEOUT_SEC; i+=1)); do
        grep -Fq "$marker" "$log_file" && return 0
        if ! kill -0 "$pid" 2>/dev/null; then
            log "ERROR: $role stopped before READY; see $log_file"
            return 1
        fi
        sleep 1
    done
    log "ERROR: $role READY timeout; see $log_file"
    return 1
}

# 先 SIGTERM，超时只有显式 --force 才允许 SIGKILL。
stop_one() {
    local role="$1"; local config="$2"; local pid_file="$3"; local pid; local i
    if ! pid="$(read_owned_pid "$pid_file" "$config")"; then rm -f "$pid_file"; log "$role STOPPED"; return 0; fi
    kill -TERM "$pid"
    for ((i=0; i<20; i+=1)); do
        kill -0 "$pid" 2>/dev/null || { rm -f "$pid_file"; log "stopped role=$role pid=$pid"; return 0; }
        sleep 1
    done
    if ((FORCE_STOP)); then kill -KILL "$pid"; rm -f "$pid_file"; log "force-stopped role=$role pid=$pid"; else fail "$role did not stop; inspect logs before stop --force"; fi
}

# Battle 先 ready，Gateway Proxy 再做远程 ready 检查，最后开放业务端口。
start_all() {
    doctor; ensure_dirs
    start_one battle skynet_battle.lua "$BATTLE_PID_FILE" "$BATTLE_LOG"
    if ! wait_ready battle "$BATTLE_PID_FILE" skynet_battle.lua "$BATTLE_LOG" LESSON2_BATTLE_PROCESS_READY; then
        stop_one battle skynet_battle.lua "$BATTLE_PID_FILE"
        fail "battle process did not become ready"
    fi
    start_one gateway skynet_gateway.lua "$GATEWAY_PID_FILE" "$GATEWAY_LOG"
    if ! wait_ready gateway "$GATEWAY_PID_FILE" skynet_gateway.lua "$GATEWAY_LOG" LESSON2_GATEWAY_PROCESS_READY; then
        stop_one gateway skynet_gateway.lua "$GATEWAY_PID_FILE"
        stop_one battle skynet_battle.lua "$BATTLE_PID_FILE"
        fail "gateway process did not become ready"
    fi
    log "START_OK"
}

# 先停止 Gateway，防止新请求进入已关闭的 Battle Process。
stop_all() { stop_one gateway skynet_gateway.lua "$GATEWAY_PID_FILE"; stop_one battle skynet_battle.lua "$BATTLE_PID_FILE"; log "STOP_OK"; }

status_all() {
    local pid
    if pid="$(read_owned_pid "$BATTLE_PID_FILE" skynet_battle.lua)"; then log "battle RUNNING pid=$pid log=$BATTLE_LOG"; else log "battle STOPPED"; fi
    if pid="$(read_owned_pid "$GATEWAY_PID_FILE" skynet_gateway.lua)"; then log "gateway RUNNING pid=$pid log=$GATEWAY_LOG"; else log "gateway STOPPED"; fi
}

# 解析入口参数并执行一个完整动作；参数来自命令行，任何未知动作或失败都会以非零状态退出。
main() {
    parse_args "$@"
    case "$ACTION" in
        doctor) doctor ;;
        start) start_all ;;
        stop) stop_all ;;
        restart) stop_all; start_all ;;
        status) status_all ;;
    esac
}
main "$@"
