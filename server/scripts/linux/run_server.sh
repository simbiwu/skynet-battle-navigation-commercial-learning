#!/usr/bin/env bash
# 职责：统一管理 Battle Navigation Server 的依赖准备、构建、启动、LuaPanda 调试和单进程启停。
# 边界：仓库级 Runtime/Build Launcher；只操作当前 server/ 下已知 build/run/log 目录和固定依赖脚本。
# 输入/输出：源码、固定版本依赖、shared/ 已发布资产 -> 可运行 Skynet 进程及 logs/run 状态文件。
# 生命周期：控制脚本短生命周期；单进程 PID 写入 run/server.pid，debug 由双进程脚本管理。
# 不负责：不生成 Unity BMAP、不实现 FlyWow 协议生成器、不读取另一台开发机目录、不静默替换版本不匹配的 third_party 源码、不修改系统防火墙。
#
# 入口合同：
#   start/restart/debug/stop 默认作用于 Gateway 和 Battle 两个 Lesson 2 进程；
#   传入 --gateway 或 --battle 后，只作用于显式选择的进程。进程顺序、READY 等待、
#   PID 文件和日志由 run_lesson2_processes.sh 统一管理。
#   debug 会先准备固定依赖和 LuaPanda，再启动选定进程；--gdb 只允许选择一个进程，
#   因为一个交互式 GDB 不能同时控制两个独立的 Skynet OS 进程。
#   所有相对路径都相对 SERVER_ROOT（本脚本所在 server/scripts/linux 的上上级目录）。
set -euo pipefail
# -e：任意未处理的失败立即退出，避免错误结果继续传给下一阶段。
# -u：读取未定义变量时立即失败，尽早发现环境变量或变量名错误。
# pipefail：管道中任一命令失败都会让整条管道失败，避免只检查到最后一条命令。

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
# GATEWAY_REGISTRY_OUTPUT 允许不同协议 bundle 使用不同生成文件；默认输出到运行时 Lua module 目录。
REGISTRY_OUTPUT="${GATEWAY_REGISTRY_OUTPUT:-$SERVER_ROOT/lualib/gateway/protocol/navigation_registry.lua}"
# source：在当前 Shell 进程加载固定版本配置，使后续变量和校验使用同一份清单。
source "$SHARED_ROOT/protocol/VERSIONS.env"

BUILD_TYPE="${BUILD_TYPE:-RelWithDebInfo}"
STARTUP_TIMEOUT_SEC="${STARTUP_TIMEOUT_SEC:-15}"
STOP_TIMEOUT_SEC="${STOP_TIMEOUT_SEC:-20}"
# FlyWow固定使用仓库内third_party/skynet-flywow；不依赖外部环境变量。
FLYWOW_ROOT="$SERVER_ROOT/third_party/skynet-flywow"

ACTION="start"
FOREGROUND=0
REBUILD=0
FORCE_STOP=0
DEBUG_GDB=0
# 进程选择：不指定时由 start/debug/restart/stop 默认处理 Gateway 和 Battle。
PROCESS_GATEWAY=0
PROCESS_BATTLE=0

# 打印所有动作和参数；不读取状态、不修改文件。
usage() {
    cat <<'USAGE'
Usage:
  ./scripts/linux/run_server.sh start [--gateway] [--battle] [--rebuild]
  ./scripts/linux/run_server.sh foreground [--rebuild]
  ./scripts/linux/run_server.sh debug [--gateway] [--battle] [--gdb]
  ./scripts/linux/run_server.sh stop [--gateway] [--battle] [--force]
  ./scripts/linux/run_server.sh restart [--gateway] [--battle] [--rebuild]
  ./scripts/linux/run_server.sh status
  ./scripts/linux/run_server.sh doctor
  ./scripts/linux/run_server.sh prepare
  ./scripts/linux/run_server.sh build
  ./scripts/linux/run_server.sh rebuild

Actions:
  start       默认启动 Gateway 和 Battle；指定进程参数时只启动所选进程。
  foreground  与 start 相同，但以前台方式 exec Skynet，适合 gdb/LuaPanda/直接看日志。
  debug       默认启用 LuaPanda 并启动 Gateway/Battle；可用 --gdb 调试单个选定进程。
  stop        默认停止 Gateway 和 Battle；指定进程参数时只停止所选进程。
  restart     按进程选择执行 stop + start；可与 --rebuild 组合。
  status      显示 PID、运行状态和当前日志。
doctor      只检查系统工具、固定依赖、构建产物和已发布共享资产，不修改文件。
  prepare     修复/补齐固定版本项目依赖和生成物，并做增量 Native 构建。
  build       prepare 后运行 Native 单元测试。
  rebuild     清理本项目 build 目录并完整重编 Skynet/pb/descriptor/Native，再运行测试。

Options:
  --rebuild      start/restart/foreground 前执行完整 rebuild。
  --foreground   start/restart 使用前台模式。
  --force        stop 超时后才允许 SIGKILL；默认不会自动 kill -9。
  --gateway      选择 Gateway 进程；未指定 Gateway/Battle 时默认两者都选。
  --battle       选择 Battle 进程；未指定 Gateway/Battle 时默认两者都选。
  --gdb          debug 时对唯一选定进程使用 GDB；不能同时选择两个进程。

Environment:
  BUILD_TYPE=RelWithDebInfo|Debug|Release
  STARTUP_TIMEOUT_SEC=15
  STOP_TIMEOUT_SEC=20
  GATEWAY_REGISTRY_OUTPUT=/path/to/server/lualib/gateway/protocol/navigation_registry.lua
USAGE
}

# 统一输出带 serverctl 前缀的状态行，便于日志和教程验收匹配。
log() {
    printf '[serverctl] %s\n' "$*"
}

# 输出错误并终止当前控制命令；不会自动停止一个身份不明的进程。
fail() {
    printf '[serverctl] ERROR: %s\n' "$*" >&2
    exit 1
}

# 解析动作、重建、前台和强制停止选项；非法输入在任何副作用前失败。
parse_args() {
    if [[ $# -gt 0 && "$1" != --* ]]; then
        ACTION="$1"
        shift
    fi
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --start) ACTION=start ;;
            --debug) ACTION=debug ;;
            --stop) ACTION=stop ;;
            --restart) ACTION=restart ;;
            --rebuild) REBUILD=1 ;;
            --foreground) FOREGROUND=1 ;;
            --force) FORCE_STOP=1 ;;
            --gateway) PROCESS_GATEWAY=1 ;;
            --battle) PROCESS_BATTLE=1 ;;
            --gdb) DEBUG_GDB=1 ;;
            -h|--help) usage; exit 0 ;;
            *) fail "unknown argument: $1" ;;
        esac
        shift
    done
    case "$ACTION" in
        start|foreground|debug|stop|restart|status|doctor|prepare|build|rebuild) ;;
        *) usage >&2; fail "unknown action: $ACTION" ;;
    esac
    if [[ "$ACTION" == "foreground" ]]; then
        FOREGROUND=1
    fi
    if [[ "$ACTION" == "debug" && "$DEBUG_GDB" == "1" &&
          "$PROCESS_GATEWAY" == "1" && "$PROCESS_BATTLE" == "1" ]]; then
        usage >&2
        fail "--gdb 只能与一个进程选择参数一起使用"
    fi
    if [[ "$ACTION" == "start" || "$ACTION" == "debug" || "$ACTION" == "restart" ||
          "$ACTION" == "stop" ]]; then
        if [[ "$PROCESS_GATEWAY" == "0" && "$PROCESS_BATTLE" == "0" ]]; then
            PROCESS_GATEWAY=1
            PROCESS_BATTLE=1
        fi
    fi
}

# 创建本机运行目录和日志目录；这些状态不属于 Git 发布资产。
ensure_runtime_dirs() {
    umask 027
    mkdir -p "$RUN_DIR" "$LOG_DIR"
}

# 检查构建/运行流程所需的系统命令，返回缺失工具而不是静默安装系统包。
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

# 判断一个目标是否早于给定源码树，用于决定是否需要增量重建。
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

# 从 PID 文件读取一个格式合法的正整数；不代表该 PID 一定属于本项目。
pid_from_file() {
    [[ -f "$PID_FILE" ]] || return 1
    local pid
    pid="$(tr -d '[:space:]' < "$PID_FILE")"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s\n' "$pid"
}

# 同时比对可执行文件和命令行，防止 stale PID 文件误操作其他 Skynet 进程。
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

# 返回当前项目 Server 的 PID；发现过期或身份不符时返回失败码。
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

# 构建/重建前拒绝覆盖仍在运行的本项目进程。
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

# 准备 Skynet、protoc/lua-protobuf 和本地构建依赖；不生成另一份共享协议合同。
bootstrap_project_dependencies() {
    require_system_tools || fail "system dependency check failed"
    cd "$SERVER_ROOT"

    if [[ ! -f third_party/skynet/.pinned-tag ]]; then
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

# 按源码时间戳决定是否构建 Skynet 可执行文件。
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

# 构建 Lua C protobuf runtime；它必须匹配 Skynet bundled Lua ABI。
build_lua_protobuf_if_needed() {
    local target="$SERVER_ROOT/third_party/lua-protobuf-runtime/pb.so"
    if [[ ! -s "$target" ]] || file_newer_than "$target" "$SERVER_ROOT/third_party/lua-protobuf"; then
        log "building lua-protobuf runtime"
        "$SERVER_ROOT/scripts/linux/build_lua_protobuf.sh"
    fi
}

# 查找独立的 Skynet-FlyWow 框架；只返回包含协议生成器的目录，不复制框架源码到业务仓库。
# 查找顺序：仅使用仓库内 third_party/skynet-flywow Git submodule。
find_flywow_root() {
    [[ -f "$FLYWOW_ROOT/scripts/generate_gateway_registry.py" &&
       -f "$FLYWOW_ROOT/service/gateway/flywow_gateway.lua" ]]
}

# 由 FlyWow 框架生成 registry；业务仓库只提供 proto 和输出位置。
# 运行时不解析 .proto；生成器只原子替换完整输出，失败时 prepare 立即终止。
build_gateway_registry() {
    find_flywow_root || fail "Skynet-FlyWow framework not found; use server/third_party/skynet-flywow"
    [[ -f "$FLYWOW_ROOT/lualib/gateway/endpoint.lua" ]] || fail "FlyWow async Gateway API missing; use a verified async submodule revision from server/third_party/skynet-flywow"
    log "generating FlyWow Gateway protocol registry via $FLYWOW_ROOT"
    python3 "$FLYWOW_ROOT/scripts/generate_gateway_registry.py" \
        --proto "$PROTO_SOURCE" \
        --output "$REGISTRY_OUTPUT"
    [[ -s "$REGISTRY_OUTPUT" ]] || \
        fail "FlyWow Gateway registry was not generated: $REGISTRY_OUTPUT"
}

# 校验已提交 descriptor、源协议哈希和 descriptor 哈希，不在 Server 启动时临时生成协议。
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

# 复用 Native 专用入口构建 battle_nav.so，避免 Server prepare 与开发者手动构建走两套命令。
build_native_incremental() {
    log "configuring/building Native module ($BUILD_TYPE)"
    BUILD_TYPE="$BUILD_TYPE" "$SERVER_ROOT/native/lua_battle_nav/make.sh"
}

# 执行一次完整依赖和 Native 准备，供 start/prepare/build 复用。
prepare_runtime() {
    bootstrap_project_dependencies
    build_skynet_if_needed
    build_lua_protobuf_if_needed
    build_gateway_registry
    if [[ -f "$FLYWOW_ROOT/scripts/build_gateway_crypto.sh" ]]; then
        bash "$FLYWOW_ROOT/scripts/build_gateway_crypto.sh" "$SERVER_ROOT/third_party/skynet"
    fi
    verify_descriptor_asset
    build_native_incremental
}

# 执行 GridMap 原生单元测试；失败时由 set -e 传播给控制命令。
run_native_tests() {
    log "running Native tests"
    "$SERVER_ROOT/native/grid_map/make_test.sh"
}

# 在构建入口统一执行项目 Lua 编码策略，避免仅靠 Code Review 发现动态签名回归。
run_lua_policy_checks() {
    log "checking project Lua vararg policy"
    "$SERVER_ROOT/scripts/linux/check_lua_varargs.sh"
}

# 只允许删除 server/build 下的已知目录，防止路径计算错误扩大删除范围。
safe_remove_build_dir() {
    local path="$1"
    case "$path" in
        "$SERVER_ROOT/build"/*) rm -rf -- "$path" ;;
        *) fail "refusing unsafe build cleanup path: $path" ;;
    esac
}

# 停止校验通过后清理并完整重建 Skynet、Lua protobuf、Native 和测试产物。
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

# start 前检查所有运行时文件；只检查共享发布资产，不读取 Unity 工程。
check_runtime_assets() {
    [[ -x "$SKYNET_BIN" ]] || fail "Skynet binary missing: $SKYNET_BIN"
    [[ -s "$SERVER_ROOT/build/lua_battle_nav/battle_nav.so" ]] || fail "battle_nav.so missing"
    [[ -s "$SERVER_ROOT/third_party/lua-protobuf-runtime/pb.so" ]] || fail "pb.so missing"
    [[ -s "$DESCRIPTOR_FILE" ]] || fail "published server descriptor missing: $DESCRIPTOR_FILE"
    [[ -s "$REGISTRY_OUTPUT" ]] || fail "Gateway registry missing; run server/scripts/linux/run_server.sh build"
    [[ -s "$MAP_FILE" ]] || fail "published BMAP missing: $MAP_FILE; pull the matching repository release first"
}

# 只读诊断本机依赖、构建物、descriptor 和 BMAP 是否齐全。
doctor() {
    local failed=0
    require_system_tools || failed=1

    [[ -f "$SERVER_ROOT/third_party/skynet/.pinned-tag" &&
       -f "$SERVER_ROOT/third_party/skynet/Makefile" ]] || { log "MISSING pinned skynet source"; failed=1; }
    [[ -x "$SKYNET_BIN" ]] || { log "MISSING skynet binary"; failed=1; }
    [[ -x "$SERVER_ROOT/third_party/protoc-$PROTOC_VERSION/bin/protoc" ]] || { log "MISSING protoc"; failed=1; }
    [[ -s "$SERVER_ROOT/third_party/lua-protobuf-runtime/pb.so" ]] || { log "MISSING pb.so"; failed=1; }
    if ! find_flywow_root; then
        log "MISSING Skynet-FlyWow framework; use the repository FlyWow path"
        failed=1
    fi
    if [[ -f "${FLYWOW_ROOT:-}/scripts/build_gateway_crypto.sh" ]]; then
        # 用固定Lua实际加载，发现ABI/OpenSSL依赖问题；不启动Service或生成密钥。
        if ! LUA_CPATH="$SERVER_ROOT/third_party/skynet-flywow/luaclib/?.so" "$SERVER_ROOT/third_party/skynet/3rd/lua/lua" \
            -e 'assert(type(require("flywow_gateway_crypto").new) == "function")'; then
            log "INVALID flywow_gateway_crypto.so: build or runtime dependency missing"
            failed=1
        fi
    fi
    [[ -s "$DESCRIPTOR_FILE" ]] || { log "MISSING published descriptor: $DESCRIPTOR_FILE"; failed=1; }
    [[ -s "$SERVER_ROOT/build/lua_battle_nav/battle_nav.so" ]] || { log "MISSING battle_nav.so"; failed=1; }
    [[ -s "$MAP_FILE" ]] || { log "MISSING battle_1001.bmap"; failed=1; }

    if ((failed)); then
        log "DOCTOR_FAILED: run './scripts/linux/run_server.sh prepare'; if shared assets are missing, pull the matching repository release"
        return 1
    fi
    log "DOCTOR_OK"
}

# 后台启动 Skynet，记录 PID，并等待应用层 NAV_SERVER_READY。
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

# 前台 exec Skynet，保留调试器和信号的直接控制权。
start_foreground() {
    ensure_not_running
    check_runtime_assets
    cd "$SERVER_ROOT"
    log "starting in foreground; Ctrl+C/SIGTERM ends the current Lesson-1 process"
    flock -u 9 || true
    # exec 9>&-：关闭继承的锁文件描述符，不让 Skynet 持有控制锁。
    exec 9>&-
    # exec Skynet：前台模式由 Skynet 接收信号并直接返回最终退出码。
    exec "$SKYNET_BIN" "config/skynet.lua"
}

# 停止 debug 动作启动的 Lesson 2 Gateway/Battle 双进程；无 PID 时安全返回。
stop_lesson2_processes() {
    if ((PROCESS_GATEWAY)) && ((PROCESS_BATTLE)); then
        if ((FORCE_STOP)); then "$SCRIPT_DIR/run_lesson2_processes.sh" stop --gateway --battle --force; else "$SCRIPT_DIR/run_lesson2_processes.sh" stop --gateway --battle; fi
    elif ((PROCESS_GATEWAY)); then
        if ((FORCE_STOP)); then "$SCRIPT_DIR/run_lesson2_processes.sh" stop --gateway --force; else "$SCRIPT_DIR/run_lesson2_processes.sh" stop --gateway; fi
    else
        if ((FORCE_STOP)); then "$SCRIPT_DIR/run_lesson2_processes.sh" stop --battle --force; else "$SCRIPT_DIR/run_lesson2_processes.sh" stop --battle; fi
    fi
}

# 先验证 PID 身份，再发送 SIGTERM；只有 --force 且超时后才允许 SIGKILL。
stop_server() {
    stop_lesson2_processes
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

# 输出当前 PID、运行状态和最近日志文件，不启动或停止进程。
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

# 启动选定的 Lesson 2 进程；子脚本负责顺序、READY 和 PID 管理。
start_selected_processes() {
    if ((PROCESS_GATEWAY)) && ((PROCESS_BATTLE)); then
        "$SCRIPT_DIR/run_lesson2_processes.sh" start --gateway --battle
    elif ((PROCESS_GATEWAY)); then
        "$SCRIPT_DIR/run_lesson2_processes.sh" start --gateway
    else
        "$SCRIPT_DIR/run_lesson2_processes.sh" start --battle
    fi
}

# 根据动作调用唯一的生命周期入口，并在结束时返回准确退出码。
# debug 准备固定版本调试依赖，并让两个 Skynet 进程继承 LuaPanda 环境变量。
start_debug() {
    ensure_not_running
    prepare_runtime
    check_runtime_assets
    if [[ ! -s "$SERVER_ROOT/third_party/luapanda/LuaPanda.lua" ||
          ! -f "$SERVER_ROOT/third_party/luapanda/.pinned-commit" ||
          ! -f "$SERVER_ROOT/third_party/luasocket/.pinned-tag" ||
          ! -s "$SERVER_ROOT/third_party/luasocket-runtime/lib/lua/5.4/socket/core.so" ]]; then
        "$SCRIPT_DIR/bootstrap_luapanda.sh"
    fi
    export LUA_PANDA_ENABLE=1
    export LUA_PANDA_HOST="${LUA_PANDA_HOST:-127.0.0.1}"
    if ((DEBUG_GDB)); then
        command -v gdb >/dev/null 2>&1 || fail "debug --gdb requires gdb"
        local gdb_config
        if ((PROCESS_GATEWAY)); then
            gdb_config="$SERVER_ROOT/config/gateway.lua"
        else
            gdb_config="$SERVER_ROOT/config/battle.lua"
        fi
        log "starting selected process under GDB: $gdb_config"
        cd "$SERVER_ROOT"
        flock -u 9 || true
        exec 9>&-
        exec gdb -x "$SERVER_ROOT/debug/gdb/lesson1.gdb" --args "$SKYNET_BIN" "$gdb_config"
    fi
    log "starting selected Lesson 2 processes with LuaPanda; start VS Code debugger first"
    flock -u 9
    exec 9>&-
    LUA_PANDA_ENABLE=1 LUA_PANDA_HOST="$LUA_PANDA_HOST" start_selected_processes
    if ((PROCESS_BATTLE)); then
        grep -Fq "LUA_PANDA_READY" "$SERVER_ROOT/logs/lesson2/battle.log" ||             fail "LuaPanda did not become ready for Battle; inspect $SERVER_ROOT/logs/lesson2/battle.log"
    fi
    if ((PROCESS_GATEWAY)); then
        grep -Fq "LUA_PANDA_READY" "$SERVER_ROOT/logs/lesson2/gateway.log" ||             fail "LuaPanda did not become ready for Gateway; inspect $SERVER_ROOT/logs/lesson2/gateway.log"
    fi
    log "DEBUG_READY LuaPanda"
}

# 根据动作调用唯一的生命周期入口，并返回准确退出码。
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
        debug)
            start_debug
            ;;
        stop)
            stop_server
            ;;
        start)
            if ((REBUILD)); then rebuild_all; else prepare_runtime; fi
            start_selected_processes
        ;;
        foreground)
            if ((REBUILD)); then rebuild_all; else prepare_runtime; fi
            start_foreground
        ;;
        restart)
            stop_server
            if ((REBUILD)); then rebuild_all; else prepare_runtime; fi
            start_selected_processes
        ;;
    esac
}

main "$@"
