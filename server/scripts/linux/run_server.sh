#!/usr/bin/env bash
# 职责：统一管理 Battle Navigation Server 的依赖准备、构建、后台启动、状态和安全停止。
# 边界：仓库级 Runtime/Build Launcher；只操作当前 server/ 下已知 build/run/log 目录和固定依赖脚本。
# 输入/输出：源码、固定版本依赖、shared/ 已发布资产 -> 可运行 Skynet 进程及 logs/run 状态文件。
# 生命周期：控制脚本本身短生命周期；后台 Server PID 写入 run/server.pid。
# 不负责：不生成 Unity BMAP、不读取另一台开发机目录、不静默替换版本不匹配的 third_party 源码、不修改系统防火墙。
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SERVER_ROOT/.." && pwd)"
SHARED_ROOT="$REPO_ROOT/shared"
RUN_DIR="$SERVER_ROOT/run"
LOG_DIR="$SERVER_ROOT/logs"
PID_FILE="$RUN_DIR/server.pid"
LOCK_FILE="$RUN_DIR/serverctl.lock"
SKYNET_BIN="$SERVER_ROOT/third_party/skynet/skynet"
SKYNET_CONFIG="$SERVER_ROOT/config/skynet.lua"
MAP_FILE="$SHARED_ROOT/navigation/battle_1001/battle_1001.bmap"
DESCRIPTOR_FILE="$SHARED_ROOT/protocol/generated/server/navigation_query.pb"
PROTO_SOURCE="$SHARED_ROOT/protocol/navigation_query.proto"
source "$SHARED_ROOT/protocol/VERSIONS.env"

BUILD_TYPE="${BUILD_TYPE:-RelWithDebInfo}"
STARTUP_TIMEOUT_SEC="${STARTUP_TIMEOUT_SEC:-15}"
STOP_TIMEOUT_SEC="${STOP_TIMEOUT_SEC:-20}"

ACTION="start"
FOREGROUND=0
REBUILD=0
FORCE_STOP=0

usage() {
    cat <<'USAGE'
Usage:
  ./scripts/linux/run_server.sh [start] [--rebuild] [--foreground]
  ./scripts/linux/run_server.sh foreground [--rebuild]
  ./scripts/linux/run_server.sh stop [--force]
  ./scripts/linux/run_server.sh restart [--rebuild] [--foreground]
  ./scripts/linux/run_server.sh status
  ./scripts/linux/run_server.sh doctor
  ./scripts/linux/run_server.sh prepare
  ./scripts/linux/run_server.sh build
  ./scripts/linux/run_server.sh rebuild

Actions:
  start       自动检查/修复项目依赖和缺失构建产物，后台启动并等待 NAV_SERVER_READY。
  foreground  与 start 相同，但以前台方式 exec Skynet，适合 gdb/LuaPanda/直接看日志。
  stop        校验 PID 确实属于本仓库 Skynet 后发送 SIGTERM，并等待退出。
  restart     stop + start；可与 --rebuild 组合。
  status      显示 PID、运行状态和当前日志。
doctor      只检查系统工具、固定依赖、构建产物和已发布共享资产，不修改文件。
  prepare     修复/补齐固定版本项目依赖和生成物，并做增量 Native 构建。
  build       prepare 后运行 Native 单元测试。
  rebuild     清理本项目 build 目录并完整重编 Skynet/pb/descriptor/Native，再运行测试。

Options:
  --rebuild      start/restart/foreground 前执行完整 rebuild。
  --foreground   start/restart 使用前台模式。
  --force        stop 超时后才允许 SIGKILL；默认不会自动 kill -9。

Environment:
  BUILD_TYPE=RelWithDebInfo|Debug|Release
  STARTUP_TIMEOUT_SEC=15
  STOP_TIMEOUT_SEC=20
USAGE
}

log() {
    printf '[serverctl] %s\n' "$*"
}

fail() {
    printf '[serverctl] ERROR: %s\n' "$*" >&2
    exit 1
}

parse_args() {
    if [[ $# -gt 0 && "$1" != --* ]]; then
        ACTION="$1"
        shift
    fi
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --rebuild) REBUILD=1 ;;
            --foreground) FOREGROUND=1 ;;
            --force) FORCE_STOP=1 ;;
            -h|--help) usage; exit 0 ;;
            *) fail "unknown argument: $1" ;;
        esac
        shift
    done
    case "$ACTION" in
        start|foreground|stop|restart|status|doctor|prepare|build|rebuild) ;;
        *) usage >&2; fail "unknown action: $ACTION" ;;
    esac
    if [[ "$ACTION" == "foreground" ]]; then
        FOREGROUND=1
    fi
}

ensure_runtime_dirs() {
    umask 027
    mkdir -p "$RUN_DIR" "$LOG_DIR"
}

require_system_tools() {
    local missing=()
    local tool
    for tool in git curl python3 tar make cmake cc c++ sha256sum nproc flock ps grep sed find; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
        fi
    done
    if ((${#missing[@]} != 0)); then
        printf '[serverctl] missing system tools:' >&2
        printf ' %s' "${missing[@]}" >&2
        printf '\n' >&2
        printf '[serverctl] Ubuntu/WSL baseline: sudo apt-get update && sudo apt-get install -y build-essential cmake git curl python3 tar unzip util-linux\n' >&2
        return 1
    fi
}

file_newer_than() {
    local target="$1"
    shift
    [[ -e "$target" ]] || return 0
    local source
    for source in "$@"; do
        if [[ -e "$source" ]] && find "$source" -type f -newer "$target" -print -quit 2>/dev/null | grep -q .; then
            return 0
        fi
    done
    return 1
}

pid_from_file() {
    [[ -f "$PID_FILE" ]] || return 1
    local pid
    pid="$(tr -d '[:space:]' < "$PID_FILE")"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s\n' "$pid"
}

pid_matches_this_server() {
    local pid="$1"
    kill -0 "$pid" 2>/dev/null || return 1
    [[ -r "/proc/$pid/exe" ]] || return 1

    local running_exe expected_exe cmdline
    running_exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
    expected_exe="$(readlink -f "$SKYNET_BIN" 2>/dev/null || true)"
    [[ -n "$running_exe" && -n "$expected_exe" && "$running_exe" == "$expected_exe" ]] || return 1

    cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    [[ "$cmdline" == *"config/skynet.lua"* || "$cmdline" == *"$SKYNET_CONFIG"* ]]
}

current_pid() {
    local pid
    if ! pid="$(pid_from_file)"; then
        return 1
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$PID_FILE"
        return 1
    fi
    if ! pid_matches_this_server "$pid"; then
        printf '[serverctl] PID_MISMATCH pid=%s: live process is not this repository Skynet\n' "$pid" >&2
        return 2
    fi
    printf '%s\n' "$pid"
}

ensure_not_running() {
    local pid rc
    if pid="$(current_pid)"; then
        fail "server is already running: pid=$pid"
    else
        rc=$?
        if ((rc == 2)); then
            fail "refusing to overwrite a PID file owned by another live process"
        fi
    fi
}

bootstrap_project_dependencies() {
    require_system_tools || fail "system dependency check failed"
    cd "$SERVER_ROOT"

    if [[ ! -d third_party/skynet/.git ]]; then
        log "Skynet source missing; bootstrapping pinned v1.8.0"
        ./scripts/linux/bootstrap_skynet.sh
    else
        ./scripts/linux/bootstrap_skynet.sh >/dev/null
    fi

    if [[ ! -x third_party/protoc-$PROTOC_VERSION/bin/protoc || ! -f third_party/lua-protobuf/.pinned-commit ]]; then
        log "protocol toolchain missing; bootstrapping pinned versions"
        ./scripts/linux/bootstrap_protocol_tools.sh
    else
        ./scripts/linux/bootstrap_protocol_tools.sh >/dev/null
    fi
}

build_skynet_if_needed() {
    cd "$SERVER_ROOT"
    if [[ ! -x "$SKYNET_BIN" ]] || \
       file_newer_than "$SKYNET_BIN" \
           "$SERVER_ROOT/third_party/skynet/skynet-src" \
           "$SERVER_ROOT/third_party/skynet/service" \
           "$SERVER_ROOT/third_party/skynet/lualib" \
           "$SERVER_ROOT/third_party/skynet/lualib-src"; then
        log "building Skynet"
        ./scripts/linux/build_skynet.sh
    fi
}

build_lua_protobuf_if_needed() {
    local target="$SERVER_ROOT/third_party/lua-protobuf-runtime/pb.so"
    if [[ ! -s "$target" ]] || file_newer_than "$target" "$SERVER_ROOT/third_party/lua-protobuf"; then
        log "building lua-protobuf runtime"
        "$SERVER_ROOT/scripts/linux/build_lua_protobuf.sh"
    fi
}

verify_descriptor_asset() {
    local target="$DESCRIPTOR_FILE"
    local source_checksum_file="$(dirname "$target")/navigation_query.source.sha256"
    local expected_source_checksum actual_source_checksum
    [[ -s "$target" ]] || fail "published server descriptor missing: $target"
    [[ -s "$source_checksum_file" ]] || fail "published protocol source checksum missing: $source_checksum_file"
    expected_source_checksum="$(tr -d '[:space:]' < "$source_checksum_file")"
    actual_source_checksum="$(sha256sum "$PROTO_SOURCE" | awk '{print $1}')"
    [[ "$actual_source_checksum" == "$expected_source_checksum" ]] || \
        fail "published descriptor does not match protocol source; regenerate and commit both from a protocol development workspace"
    "$SERVER_ROOT/scripts/linux/check_server_descriptor.sh" >/dev/null
    if [[ -s "$target.sha256" ]]; then
        (cd "$(dirname "$target")" && sha256sum -c "$(basename "$target.sha256")" >/dev/null)
    else
        fail "published descriptor checksum missing: $target.sha256"
    fi
}

build_native_incremental() {
    log "configuring/building Native module ($BUILD_TYPE)"
    cmake \
        -S "$SERVER_ROOT/native/lua_battle_nav" \
        -B "$SERVER_ROOT/build/lua_battle_nav" \
        -DCMAKE_BUILD_TYPE="$BUILD_TYPE"
    cmake --build "$SERVER_ROOT/build/lua_battle_nav" -j"$(nproc)"
    [[ -s "$SERVER_ROOT/build/lua_battle_nav/battle_nav.so" ]] || \
        fail "battle_nav.so was not generated"
}

prepare_runtime() {
    bootstrap_project_dependencies
    build_skynet_if_needed
    build_lua_protobuf_if_needed
    verify_descriptor_asset
    build_native_incremental
}

run_native_tests() {
    log "running Native tests"
    "$SERVER_ROOT/native/grid_map/make_test.sh"
}

# 在构建入口统一执行项目 Lua 编码策略，避免仅靠 Code Review 发现动态签名回归。
run_lua_policy_checks() {
    log "checking project Lua vararg policy"
    "$SERVER_ROOT/scripts/linux/check_lua_varargs.sh"
}

safe_remove_build_dir() {
    local path="$1"
    case "$path" in
        "$SERVER_ROOT/build"/*) rm -rf -- "$path" ;;
        *) fail "refusing unsafe build cleanup path: $path" ;;
    esac
}

rebuild_all() {
    ensure_not_running
    bootstrap_project_dependencies
    log "full rebuild: cleaning project build directories only"
    safe_remove_build_dir "$SERVER_ROOT/build/grid_map"
    safe_remove_build_dir "$SERVER_ROOT/build/lua_battle_nav"

    if [[ -f "$SERVER_ROOT/third_party/skynet/Makefile" ]]; then
        make -C "$SERVER_ROOT/third_party/skynet" clean >/dev/null 2>&1 || true
    fi
    "$SERVER_ROOT/scripts/linux/build_skynet.sh"
    "$SERVER_ROOT/scripts/linux/build_lua_protobuf.sh"
    verify_descriptor_asset
    run_lua_policy_checks
    run_native_tests
    build_native_incremental
    log "REBUILD_OK"
}

check_runtime_assets() {
    [[ -x "$SKYNET_BIN" ]] || fail "Skynet binary missing: $SKYNET_BIN"
    [[ -s "$SERVER_ROOT/build/lua_battle_nav/battle_nav.so" ]] || fail "battle_nav.so missing"
    [[ -s "$SERVER_ROOT/third_party/lua-protobuf-runtime/pb.so" ]] || fail "pb.so missing"
    [[ -s "$DESCRIPTOR_FILE" ]] || fail "published server descriptor missing: $DESCRIPTOR_FILE"
    [[ -s "$MAP_FILE" ]] || fail "published BMAP missing: $MAP_FILE; pull the matching repository release first"
}

doctor() {
    local failed=0
    require_system_tools || failed=1

    [[ -d "$SERVER_ROOT/third_party/skynet/.git" ]] || { log "MISSING skynet source"; failed=1; }
    [[ -x "$SKYNET_BIN" ]] || { log "MISSING skynet binary"; failed=1; }
    [[ -x "$SERVER_ROOT/third_party/protoc-$PROTOC_VERSION/bin/protoc" ]] || { log "MISSING protoc"; failed=1; }
    [[ -s "$SERVER_ROOT/third_party/lua-protobuf-runtime/pb.so" ]] || { log "MISSING pb.so"; failed=1; }
    [[ -s "$DESCRIPTOR_FILE" ]] || { log "MISSING published descriptor: $DESCRIPTOR_FILE"; failed=1; }
    [[ -s "$SERVER_ROOT/build/lua_battle_nav/battle_nav.so" ]] || { log "MISSING battle_nav.so"; failed=1; }
    [[ -s "$MAP_FILE" ]] || { log "MISSING battle_1001.bmap"; failed=1; }

    if ((failed)); then
        log "DOCTOR_FAILED: run './scripts/linux/run_server.sh prepare'; if shared assets are missing, pull the matching repository release"
        return 1
    fi
    log "DOCTOR_OK"
}

start_background() {
    ensure_not_running
    check_runtime_assets
    cd "$SERVER_ROOT"

    local stamp log_file pid deadline
    stamp="$(date '+%Y%m%d-%H%M%S')"
    log_file="$LOG_DIR/server-$stamp.log"
    ln -sfn "$(basename "$log_file")" "$LOG_DIR/server.log"

    log "starting in background; log=$log_file"
    nohup "$SKYNET_BIN" "config/skynet.lua" >>"$log_file" 2>&1 </dev/null 9>&- &
    pid=$!
    printf '%s\n' "$pid" > "$PID_FILE.tmp"
    mv -f "$PID_FILE.tmp" "$PID_FILE"

    deadline=$((SECONDS + STARTUP_TIMEOUT_SEC))
    while ((SECONDS < deadline)); do
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$PID_FILE"
            tail -n 80 "$log_file" >&2 || true
            fail "server exited during startup"
        fi
        if grep -q "NAV_SERVER_READY" "$log_file" 2>/dev/null; then
            log "START_OK pid=$pid log=$log_file"
            return 0
        fi
        sleep 0.2
    done

    log "startup readiness timeout; terminating pid=$pid"
    kill -TERM "$pid" 2>/dev/null || true
    local cleanup_deadline=$((SECONDS + 5))
    while kill -0 "$pid" 2>/dev/null && ((SECONDS < cleanup_deadline)); do
        sleep 0.2
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
    tail -n 80 "$log_file" >&2 || true
    fail "NAV_SERVER_READY not observed within ${STARTUP_TIMEOUT_SEC}s"
}

start_foreground() {
    ensure_not_running
    check_runtime_assets
    cd "$SERVER_ROOT"
    log "starting in foreground; Ctrl+C/SIGTERM ends the current Lesson-1 process"
    flock -u 9 || true
    exec 9>&-
    exec "$SKYNET_BIN" "config/skynet.lua"
}

stop_server() {
    local pid deadline rc
    if pid="$(current_pid)"; then
        :
    else
        rc=$?
        if ((rc == 1)); then
            log "STOP_OK server is not running"
            return 0
        fi
        fail "PID file points to another live process; refusing to send a signal"
    fi

    log "sending SIGTERM to pid=$pid"
    kill -TERM "$pid"
    deadline=$((SECONDS + STOP_TIMEOUT_SEC))
    while ((SECONDS < deadline)); do
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$PID_FILE"
            log "STOP_OK pid=$pid"
            return 0
        fi
        sleep 0.2
    done

    if ((FORCE_STOP)); then
        log "SIGTERM timeout; --force allows SIGKILL pid=$pid"
        kill -KILL "$pid" 2>/dev/null || true
        sleep 0.2
        rm -f "$PID_FILE"
        log "STOP_FORCED pid=$pid"
        return 0
    fi

    fail "pid=$pid did not exit within ${STOP_TIMEOUT_SEC}s; inspect logs, then use 'stop --force' only if necessary"
}

status_server() {
    local pid rc
    if pid="$(current_pid)"; then
        local log_target=""
        if [[ -L "$LOG_DIR/server.log" ]]; then
            log_target="$(readlink "$LOG_DIR/server.log")"
        fi
        log "RUNNING pid=$pid log=${log_target:-unknown}"
        ps -p "$pid" -o pid=,etime=,stat=,cmd=
    else
        rc=$?
        if ((rc == 1)); then
            log "STOPPED"
        else
            fail "PID file points to another live process; status is unsafe/ambiguous"
        fi
    fi
}

main() {
    parse_args "$@"
    ensure_runtime_dirs

    exec 9>"$LOCK_FILE"
    flock -x 9

    case "$ACTION" in
        doctor)
            doctor
            ;;
        prepare)
            prepare_runtime
            log "PREPARE_OK"
            ;;
        build)
            prepare_runtime
            run_lua_policy_checks
            run_native_tests
            log "BUILD_OK"
            ;;
        rebuild)
            rebuild_all
            ;;
        status)
            status_server
            ;;
        stop)
            stop_server
            ;;
        start|foreground)
            if ((REBUILD)); then
                rebuild_all
            else
                prepare_runtime
            fi
            if ((FOREGROUND)); then
                start_foreground
            else
                start_background
            fi
            ;;
        restart)
            stop_server
            if ((REBUILD)); then
                rebuild_all
            else
                prepare_runtime
            fi
            if ((FOREGROUND)); then
                start_foreground
            else
                start_background
            fi
            ;;
    esac
}

main "$@"
