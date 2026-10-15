#!/usr/bin/env bash
# 职责：Server 唯一运行入口，统一准备依赖、启动/停止 Gateway 与 Battle、执行 LuaPanda/GDB 调试。
# 边界：只负责流程编排和进程选择；具体构建由 scripts/linux 下已有脚本完成。
# 输入：start/debug/stop/restart/prepare/build/rebuild/doctor + --gateway/--battle 等选项。
# 输出：Gateway/Battle 进程、server/run/lesson2 PID、server/logs/lesson2 日志和明确退出码。
# 路径：所有相对路径都相对 Server 根目录，即本脚本所在目录的上上级。
# 默认：start、debug、restart、stop 未指定进程时同时作用于 Gateway 和 Battle。
# 选择：--gateway 只选择 Gateway，--battle 只选择 Battle；两者同时传入表示选择全部。
# 调试：debug 启用 LuaPanda；debug --gdb 只允许选择一个进程，由 GDB 控制该进程。
# Native 构建链：build -> run_build -> prepare_runtime -> FlyWow scripts/build_flywow.sh -> 各模块 CMakeLists。
# 调用示例：从 Server 根目录运行 ./scripts/linux/run_server.sh build；只构建单个模块时调用 FlyWow 构建脚本。
# 修改指引：源码清单在各模块 CMakeLists；统一 Native 输出目录在 FlyWow scripts/build_flywow.sh。
# 不负责：不实现编译器、协议生成器、Native 业务逻辑或 Skynet Service。
# -e：命令失败时停止，避免失败后仍继续启动服务或报告成功。
# -u：读取未设置的变量时失败；pipefail：管道任一环节失败都会传递为失败。
set -euo pipefail

# 下面是 Bash 变量；BUILD_TYPE 和 LUA_PANDA_HOST 可由调用环境覆盖，其余路径由脚本位置推导。
# SCRIPT_DIR 取本脚本所在目录，SERVER_ROOT 向上两级定位 Server 根目录，因此从任意 cwd 调用都可工作。
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
SERVER_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd -- "$SERVER_ROOT/.." && pwd)"
SHARED_ROOT="$REPO_ROOT/shared"
# FlyWow 固定随 Server submodule 使用；FLYWOW_BUILD_DIR 是 rebuild 清理的构建输出目录。
# 下列常量定位 Skynet 可执行文件、协议源/描述文件、Gateway 路由表和地图资产。
# Runtime 的 Lua/C 搜索路径直接写在各 process config 中，不由本脚本生成。
FLYWOW_DIR="$SERVER_ROOT/third_party/skynet-flywow"
FLYWOW_BUILD_DIR="$FLYWOW_DIR/build"
SKYNET_BIN="$SERVER_ROOT/third_party/skynet/skynet"
# 每课协议由 server/protocol/build_protocol_<course>.sh 独立构建；运行入口不扫描或生成协议。
MAP_FILE="$SHARED_ROOT/navigation/battle_1001/battle_1001.bmap"
# printenv 从进程环境读取可选覆盖项；未设置时分别回退到 RelWithDebInfo 和本机回环地址。
# BUILD_TYPE 会传给 FlyWow 构建脚本，LUA_PANDA_HOST 会在调试模式导出给 LuaPanda。
BUILD_TYPE="$(printenv BUILD_TYPE || printf RelWithDebInfo)"
LUA_PANDA_HOST="$(printenv LUA_PANDA_HOST || printf 127.0.0.1)"
# 命令行解析前的默认状态：默认 start；未指定进程时，生命周期动作会选择 Gateway 和 Battle。
ACTION=start
PROCESS_GATEWAY=0
PROCESS_BATTLE=0
FORCE_STOP=0
REBUILD=0
DEBUG_GDB=0
# 统一给正常进度加前缀，便于从构建和服务日志中识别控制器输出。
log() {
    printf '[serverctl] %s\n' "$*"
}

# 参数、前置条件或启动检查失败时统一打印错误并以非零状态退出。
fail() {
    printf '[serverctl] ERROR: %s\n' "$*" >&2
    exit 1
}
# 帮助文本列出公开动作和常用选项；解析遇到 -h/--help 时直接打印并成功退出。
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
# 先读取动作和开关并校验；这里只更新 ACTION、PROCESS_*、REBUILD、DEBUG_GDB、FORCE_STOP，
# 不执行构建或启动等副作用，后续函数只接收已验证的内部状态。
parse_args() {
    # 第一个参数若不是 -- 开头，就作为动作名；shift 将它从待解析参数中移除。
    if [[ $# -gt 0 && "$1" != --* ]]; then ACTION="$1"; shift; fi
    while [[ $# -gt 0 ]]; do
        # 后续参数都是开关：选择动作、进程，或请求重建/强制停止/GDB。
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
    # 动作白名单在任何工作开始前校验，避免未知动作静默落入默认分支。
    case "$ACTION" in
        start|debug|stop|restart|prepare|build|rebuild|doctor|status)
            ;;
        *)
            fail "未知动作：$ACTION"
            ;;
    esac
    # 生命周期动作若没有 --gateway/--battle，默认同时选择 Gateway 和 Battle。
    if [[ "$ACTION" == start || "$ACTION" == debug ||
        "$ACTION" == stop || "$ACTION" == restart ]]; then
        if ((PROCESS_GATEWAY == 0 && PROCESS_BATTLE == 0)); then
            PROCESS_GATEWAY=1
            PROCESS_BATTLE=1
        fi
    fi

    # GDB 是 debug 专属选项，且一个 GDB 会话只能控制一个 Skynet 进程。
    if ((DEBUG_GDB && ACTION != debug)); then
        fail "--gdb 只能用于 debug"
    fi

    if ((DEBUG_GDB && PROCESS_GATEWAY && PROCESS_BATTLE)); then
        fail "--gdb 只能选择一个进程"
    fi
}
# start、debug、build 共用准备链：准备框架与 Native 依赖，检查地图运行资产；协议由课程构建脚本预先生成。
prepare_runtime() {
    # 准备固定版本的 Skynet 源码及构建前置条件；该准备脚本可重复运行。
    "$SCRIPT_DIR/bootstrap_skynet.sh"
    # 仅当 Skynet 可执行文件缺失或不可执行时才编译框架。
    if [[ ! -x "$SKYNET_BIN" ]]; then "$SCRIPT_DIR/build_skynet.sh"; fi
    # Lua protobuf Native 模块缺失或为空时才构建。
    if [[ ! -s "$SERVER_ROOT/third_party/lua-protobuf-runtime/pb.so" ]]; then "$SCRIPT_DIR/build_lua_protobuf.sh"; fi
    # 调用 FlyWow 的统一入口；省略模块参数表示构建全部模块。
    # 若要只构建 Navigation，可单独调用：bash third_party/skynet-flywow/scripts/build_flywow.sh third_party/skynet navigation。
    # 模块的 C++ 源文件清单由各模块 CMakeLists 维护，最终产物统一写入 submodule/build/native。
    # 通过 FlyWow 唯一公开构建入口编译全部模块；BUILD_TYPE 只传给这次子进程。
    BUILD_TYPE="$BUILD_TYPE" bash "$FLYWOW_DIR/scripts/build_flywow.sh" \
        "$SERVER_ROOT/third_party/skynet"
    # Lua/C 搜索路径已在 process config 明确列出，不生成或注入额外配置文件。
    # 帧同步进程还需要其正式地图；BMAP-only 配置由 Lesson 3 Spec 约束。
    [[ -s "$MAP_FILE" ]] || fail "共享运行资产不完整"
    log "PREPARE_OK"
}
# build 完成依赖准备、Native 编译/模块测试和 Lua 可变参数检查，但不启动长期运行的 Skynet 进程。
run_build() {
    prepare_runtime
    "$SCRIPT_DIR/check_lua_varargs.sh"
    # FlyWow 构建入口已完成 Native 编译和各模块 CTest。
    log "BUILD_OK"
}
# rebuild 清理可再生构建输出后完整重建；适用于依赖/ABI 变化后的验证，不删除源码或共享运行资产。
run_rebuild() {
    # 状态修改：停止现有课程进程并清理构建输出。
    # 尽力停止旧进程；首次构建时进程可能不存在，因此停止失败不阻断重建。
    "$SCRIPT_DIR/../lessons/run_lesson_02_processes.sh" stop --gateway --battle --force || true
    # 删除 FlyWow 与 Server 的 Native 构建产物，确保下一步根据当前源码重新生成。
    rm -rf "$FLYWOW_BUILD_DIR" "$SERVER_ROOT/build/native"
    # 若 Skynet Makefile 已存在则清理旧产物；清理失败不阻断后续的完整构建。
    if [[ -f "$SERVER_ROOT/third_party/skynet/Makefile" ]]; then make -C "$SERVER_ROOT/third_party/skynet" clean >/dev/null 2>&1 || true; fi
    "$SCRIPT_DIR/build_skynet.sh"
    "$SCRIPT_DIR/build_lua_protobuf.sh"
    run_build
    log "REBUILD_OK"
}
# 将已解析的进程选择传给课程进程控制器；本层不自行管理 PID 或进程生命周期。
run_selected_start() {
    if ((PROCESS_GATEWAY && PROCESS_BATTLE)); then
        "$SCRIPT_DIR/../lessons/run_lesson_02_processes.sh" start --gateway --battle
    elif ((PROCESS_GATEWAY)); then
        "$SCRIPT_DIR/../lessons/run_lesson_02_processes.sh" start --gateway
    else
        "$SCRIPT_DIR/../lessons/run_lesson_02_processes.sh" start --battle
    fi
}
# 停止也交给课程进程控制器；FORCE_STOP 决定是否启用超时后的强制终止兜底。
run_selected_stop() {
    if ((PROCESS_GATEWAY && PROCESS_BATTLE)); then
        if ((FORCE_STOP)); then "$SCRIPT_DIR/../lessons/run_lesson_02_processes.sh" stop --gateway --battle --force; else "$SCRIPT_DIR/../lessons/run_lesson_02_processes.sh" stop --gateway --battle; fi
    elif ((PROCESS_GATEWAY)); then
        if ((FORCE_STOP)); then "$SCRIPT_DIR/../lessons/run_lesson_02_processes.sh" stop --gateway --force; else "$SCRIPT_DIR/../lessons/run_lesson_02_processes.sh" stop --gateway; fi
    else
        if ((FORCE_STOP)); then "$SCRIPT_DIR/../lessons/run_lesson_02_processes.sh" stop --battle --force; else "$SCRIPT_DIR/../lessons/run_lesson_02_processes.sh" stop --battle; fi
    fi
}
# 把相同的 Gateway/Battle 选择传给状态查询入口。
run_selected_status() {
    if ((PROCESS_GATEWAY && PROCESS_BATTLE)); then
        "$SCRIPT_DIR/../lessons/run_lesson_02_processes.sh" status --gateway --battle
    elif ((PROCESS_GATEWAY)); then
        "$SCRIPT_DIR/../lessons/run_lesson_02_processes.sh" status --gateway
    else
        "$SCRIPT_DIR/../lessons/run_lesson_02_processes.sh" status --battle
    fi
}
# 调试复用正常准备链和运行资产，再选择 LuaPanda 或 GDB 控制单个 Skynet 进程。
run_debug() {
    prepare_runtime
    "$SCRIPT_DIR/bootstrap_luapanda.sh"
    # 开启 LuaPanda，并把上面读取的监听地址导出给后续启动的进程。
    export LUA_PANDA_ENABLE=1 LUA_PANDA_HOST
    # 断点可能暂停超过普通启动的 20 秒；调试启动无限等待 READY。
    export LESSON2_STARTUP_TIMEOUT_SEC=0
    if ((DEBUG_GDB)); then
        command -v gdb >/dev/null 2>&1 || fail "未安装 gdb"
        # 选择对应进程的 Skynet 配置；exec 让当前 Shell 进程直接替换为 GDB。
        local config
        if ((PROCESS_GATEWAY)); then config="$SERVER_ROOT/config/gateway_process.lua"; else config="$SERVER_ROOT/config/battle_process.lua"; fi
        cd "$SERVER_ROOT"
        exec gdb -x "$SERVER_ROOT/debug/gdb/lesson1.gdb" --args "$SKYNET_BIN" "$config"
    fi
    # 非 GDB 调试由进程控制器启动目标进程，随后检查日志中的 LuaPanda 就绪标记。
    run_selected_start
    if ((PROCESS_GATEWAY)); then grep -Fq LUA_PANDA_READY "$SERVER_ROOT/logs/gateway/$(date +%F).log" || fail "Gateway LuaPanda 未就绪"; fi
    if ((PROCESS_BATTLE)); then grep -Fq LUA_PANDA_READY "$SERVER_ROOT/logs/battle/$(date +%F).log" || fail "Battle LuaPanda 未就绪"; fi
    log "DEBUG_READY LuaPanda"
}
# 唯一动作分发入口：先解析参数，再切换到 Server 根目录，最后调用对应流程。
main() {
    parse_args "$@"
    cd "$SERVER_ROOT"
    # 将已验证的动作路由到准备、构建、调试、生命周期或状态查询流程。
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
# "$@" 保留调用者传入的每个参数边界，交给 main 统一解析。
main "$@"
