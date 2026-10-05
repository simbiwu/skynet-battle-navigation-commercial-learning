#!/usr/bin/env bash
# 职责：Server 唯一运行入口，统一准备依赖、启动/停止 Gateway 与 Battle、执行 LuaPanda/GDB 调试。
# 边界：只负责流程编排和进程选择；具体构建由 scripts/linux 下已有脚本完成。
# 输入：start/debug/stop/restart/prepare/build/rebuild/doctor + --gateway/--battle 等选项。
# 输出：Gateway/Battle 进程、server/run/lesson2 PID、server/logs/lesson2 日志和明确退出码。
# 路径：所有相对路径都相对 Server 根目录，即本脚本所在目录的上上级。
# 默认：start、debug、restart、stop 未指定进程时同时作用于 Gateway 和 Battle。
# 选择：--gateway 只选择 Gateway，--battle 只选择 Battle；两者同时传入表示选择全部。
# 调试：debug 启用 LuaPanda；debug --gdb 只允许选择一个进程，由 GDB 控制该进程。
# 不负责：不实现编译器、协议生成器、Native 业务逻辑或 Skynet Service。
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
SERVER_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd -- "$SERVER_ROOT/.." && pwd)"
SHARED_ROOT="$REPO_ROOT/shared"
# FlyWow 固定随 Server submodule 使用；Runtime 相对路径直接写在 process config 中。
FLYWOW_DIR="$SERVER_ROOT/third_party/skynet-flywow"
FLYWOW_BUILD_DIR="$FLYWOW_DIR/build"
SKYNET_BIN="$SERVER_ROOT/third_party/skynet/skynet"
REGISTRY="$SERVER_ROOT/lualib/gateway/protocol/navigation_registry.lua"
PROTO="$SHARED_ROOT/protocol/navigation_query.proto"
DESCRIPTOR="$SHARED_ROOT/protocol/generated/server/navigation_query.pb"
MAP_FILE="$SHARED_ROOT/navigation/battle_1001/battle_1001.bmap"
BUILD_TYPE="$(printenv BUILD_TYPE || printf RelWithDebInfo)"
LUA_PANDA_HOST="$(printenv LUA_PANDA_HOST || printf 127.0.0.1)"
ACTION=start
PROCESS_GATEWAY=0
PROCESS_BATTLE=0
FORCE_STOP=0
REBUILD=0
DEBUG_GDB=0
log() {
    printf '[serverctl] %s\n' "$*"
}

fail() {
    printf '[serverctl] ERROR: %s\n' "$*" >&2
    exit 1
}
usage() {
    cat <<'USAGE'
用法：
  ./scripts/linux/run_server.sh start [--gateway] [--battle] [--rebuild]
  ./scripts/linux/run_server.sh debug [--gateway] [--battle] [--gdb]
  ./scripts/linux/run_server.sh stop [--gateway] [--battle] [--force]
  ./scripts/linux/run_server.sh restart [--gateway] [--battle] [--rebuild]
  ./scripts/linux/run_server.sh prepare | build | rebuild | doctor | status
USAGE
}
# 先把命令行转换成动作和角色选择，后续函数只处理已验证的内部状态。
parse_args() {
    if [[ $# -gt 0 && "$1" != --* ]]; then ACTION="$1"; shift; fi
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --start) ACTION=start ;;
            --debug) ACTION=debug ;;
            --stop) ACTION=stop ;;
            --restart) ACTION=restart ;;
            --prepare) ACTION=prepare ;;
            --build) ACTION=build ;;
            --rebuild) REBUILD=1 ;;
            --gateway) PROCESS_GATEWAY=1 ;;
            --battle) PROCESS_BATTLE=1 ;;
            --gdb) DEBUG_GDB=1 ;;
            --force) FORCE_STOP=1 ;;
            -h|--help) usage; exit 0 ;;
            *) usage >&2; fail "未知参数：$1" ;;
        esac
        shift
    done
    case "$ACTION" in
        start|debug|stop|restart|prepare|build|rebuild|doctor|status)
            ;;
        *)
            fail "未知动作：$ACTION"
            ;;
    esac
    if [[ "$ACTION" == start || "$ACTION" == debug ||
        "$ACTION" == stop || "$ACTION" == restart ]]; then
        if ((PROCESS_GATEWAY == 0 && PROCESS_BATTLE == 0)); then
            PROCESS_GATEWAY=1
            PROCESS_BATTLE=1
        fi
    fi

    if ((DEBUG_GDB && ACTION != debug)); then
        fail "--gdb 只能用于 debug"
    fi

    if ((DEBUG_GDB && PROCESS_GATEWAY && PROCESS_BATTLE)); then
        fail "--gdb 只能选择一个进程"
    fi
}
# 所有启动/构建入口共用同一条准备链，保证协议、Native、路径和 descriptor 不会各自漂移。
prepare_runtime() {
    "$SCRIPT_DIR/bootstrap_skynet.sh"
    "$SCRIPT_DIR/bootstrap_protocol_tools.sh"
    if [[ ! -x "$SKYNET_BIN" ]]; then "$SCRIPT_DIR/build_skynet.sh"; fi
    if [[ ! -s "$SERVER_ROOT/third_party/lua-protobuf-runtime/pb.so" ]]; then "$SCRIPT_DIR/build_lua_protobuf.sh"; fi
    # proto 是唯一源；registry 是 Gateway 启动时读取的路由索引，生成而不是手写，避免编号漂移。
    # 生成协议运行时产物。
    mkdir -p "$(dirname "$REGISTRY")"
    python3 "$FLYWOW_DIR/gateway/tools/generate_gateway_registry.py"         --proto "$PROTO"         --output "$REGISTRY"
    # 构建 FlyWow Native 模块并校验 descriptor。
    # FlyWow 的公开构建入口一次构建所需 Native 模块，统一写入 submodule/build/native。
    BUILD_TYPE="$BUILD_TYPE" bash "$FLYWOW_DIR/scripts/build_flywow.sh" \
        "$SERVER_ROOT/third_party/skynet"
    # Lua/C 搜索路径已在 process config 明确列出，不生成或注入额外配置文件。
    "$SCRIPT_DIR/check_server_descriptor.sh"
    # 收尾：确认所有启动所需产物存在。
    [[ -s "$REGISTRY" && -s "$DESCRIPTOR" && -s "$MAP_FILE" ]] ||
        fail "共享运行资产不完整"
    log "PREPARE_OK"
}
# build 只做可复现准备和检查，不启动长期运行的 Skynet 进程。
run_build() {
    prepare_runtime
    "$SCRIPT_DIR/check_lua_varargs.sh"
    # FlyWow 构建入口已完成 Native 编译和各模块 CTest。
    log "BUILD_OK"
}
# rebuild 先清理可再生状态，再重新编译，适合切换 ABI/依赖版本后的完整验证。
run_rebuild() {
    # 状态修改：停止现有课程进程并清理构建输出。
    "$SCRIPT_DIR/../lessons/run_lesson_02_processes.sh" stop --gateway --battle --force || true
    rm -rf "$FLYWOW_BUILD_DIR" "$SERVER_ROOT/build/native"
    if [[ -f "$SERVER_ROOT/third_party/skynet/Makefile" ]]; then make -C "$SERVER_ROOT/third_party/skynet" clean >/dev/null 2>&1 || true; fi
    "$SCRIPT_DIR/build_skynet.sh"
    "$SCRIPT_DIR/build_lua_protobuf.sh"
    run_build
    log "REBUILD_OK"
}
# 进程生命周期交给课程控制器；本层只把已解析的角色选择转换成明确参数。
run_selected_start() {
    if ((PROCESS_GATEWAY && PROCESS_BATTLE)); then
        "$SCRIPT_DIR/../lessons/run_lesson_02_processes.sh" start --gateway --battle
    elif ((PROCESS_GATEWAY)); then
        "$SCRIPT_DIR/../lessons/run_lesson_02_processes.sh" start --gateway
    else
        "$SCRIPT_DIR/../lessons/run_lesson_02_processes.sh" start --battle
    fi
}
# 停止同样经过统一控制器，确保优雅 shutdown 和 --force 兜底行为一致。
run_selected_stop() {
    if ((PROCESS_GATEWAY && PROCESS_BATTLE)); then
        if ((FORCE_STOP)); then "$SCRIPT_DIR/../lessons/run_lesson_02_processes.sh" stop --gateway --battle --force; else "$SCRIPT_DIR/../lessons/run_lesson_02_processes.sh" stop --gateway --battle; fi
    elif ((PROCESS_GATEWAY)); then
        if ((FORCE_STOP)); then "$SCRIPT_DIR/../lessons/run_lesson_02_processes.sh" stop --gateway --force; else "$SCRIPT_DIR/../lessons/run_lesson_02_processes.sh" stop --gateway; fi
    else
        if ((FORCE_STOP)); then "$SCRIPT_DIR/../lessons/run_lesson_02_processes.sh" stop --battle --force; else "$SCRIPT_DIR/../lessons/run_lesson_02_processes.sh" stop --battle; fi
    fi
}
run_selected_status() {
    if ((PROCESS_GATEWAY && PROCESS_BATTLE)); then
        "$SCRIPT_DIR/../lessons/run_lesson_02_processes.sh" status --gateway --battle
    elif ((PROCESS_GATEWAY)); then
        "$SCRIPT_DIR/../lessons/run_lesson_02_processes.sh" status --gateway
    else
        "$SCRIPT_DIR/../lessons/run_lesson_02_processes.sh" status --battle
    fi
}
# 调试入口仍复用生产准备链，只额外注入 LuaPanda 或 GDB，避免调试环境偷偷使用另一套资产。
run_debug() {
    prepare_runtime
    "$SCRIPT_DIR/bootstrap_luapanda.sh"
    export LUA_PANDA_ENABLE=1 LUA_PANDA_HOST
    # 断点可能暂停超过普通启动的 20 秒；调试启动无限等待 READY。
    export LESSON2_STARTUP_TIMEOUT_SEC=0
    if ((DEBUG_GDB)); then
        command -v gdb >/dev/null 2>&1 || fail "未安装 gdb"
        local config
        if ((PROCESS_GATEWAY)); then config="$SERVER_ROOT/config/gateway_process.lua"; else config="$SERVER_ROOT/config/battle_process.lua"; fi
        cd "$SERVER_ROOT"
        exec gdb -x "$SERVER_ROOT/debug/gdb/lesson1.gdb" --args "$SKYNET_BIN" "$config"
    fi
    run_selected_start
    if ((PROCESS_GATEWAY)); then grep -Fq LUA_PANDA_READY "$SERVER_ROOT/logs/gateway/$(date +%F).log" || fail "Gateway LuaPanda 未就绪"; fi
    if ((PROCESS_BATTLE)); then grep -Fq LUA_PANDA_READY "$SERVER_ROOT/logs/battle/$(date +%F).log" || fail "Battle LuaPanda 未就绪"; fi
    log "DEBUG_READY LuaPanda"
}
main() {
    parse_args "$@"
    cd "$SERVER_ROOT"
    case "$ACTION" in
        prepare) prepare_runtime ;;
        build) run_build ;;
        rebuild) run_rebuild ;;
        doctor) "$SCRIPT_DIR/../lessons/run_lesson_02_processes.sh" doctor ;;
        status) run_selected_status ;;
        stop) run_selected_stop ;;
        debug) run_debug ;;
        start|restart)
            if [[ "$ACTION" == restart ]]; then run_selected_stop; fi
            if ((REBUILD)); then run_rebuild; else prepare_runtime; fi
            run_selected_start
            ;;
    esac
}
main "$@"
