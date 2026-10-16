#!/usr/bin/env bash
# 职责：执行与具体课程服务进程无关的 Server Runtime 准备、增量构建和完整重建。
# 调用：scripts/linux/build_server.sh prepare|build|rebuild；总入口 run_server.sh 仅转发通用构建命令。
# 参数：一个动作；不接受课程生命周期参数。-h/--help 只显示帮助。
# 路径：脚本自动定位 server/、仓库 shared/；相对路径均以 server/ 为基准。
# 环境变量：BUILD_TYPE 可选，传给 FlyWow CMake，默认 RelWithDebInfo。
# 输入：固定版本 Skynet、FlyWow、Lua protobuf 源码及正式 shared/navigation/battle_1001/battle_1001.bmap。
# 输出：更新 Skynet、pb.so、FlyWow Native 构建产物；build 还运行 Lua 可变参数检查。
# 进程：不启动、停止或查询课程进程，不创建 PID 文件或重定向课程日志。
# rebuild：清理可再生产物后重建，不触碰源码、课程配置、日志和运行地图。
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd -- "$SERVER_ROOT/.." && pwd)"
FLYWOW_DIR="$SERVER_ROOT/third_party/skynet-flywow"
SKYNET_ROOT="$SERVER_ROOT/third_party/skynet"
SKYNET_BIN="$SKYNET_ROOT/skynet"
MAP_FILE="$REPO_ROOT/shared/navigation/battle_1001/battle_1001.bmap"
BUILD_TYPE="${BUILD_TYPE:-RelWithDebInfo}"
usage() {
    cat <<'USAGE'
用法：./scripts/linux/build_server.sh prepare|build|rebuild
  prepare  准备固定版本依赖并检查正式地图。
  build    prepare 后执行增量构建和 Lua 可变参数检查。
  rebuild  清理可再生产物后完整构建。
环境变量：BUILD_TYPE 可选，默认 RelWithDebInfo。
服务生命周期请使用 ./scripts/linux/run_server.sh lessonN ...。
USAGE
}
fail() { printf '[server-build] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[server-build] %s\n' "$*"; }
prepare_runtime() {
    "$SCRIPT_DIR/bootstrap_skynet.sh"
    if [[ ! -x "$SKYNET_BIN" ]]; then "$SCRIPT_DIR/build_skynet.sh"; fi
    if [[ ! -s "$SERVER_ROOT/third_party/lua-protobuf-runtime/pb.so" ]]; then "$SCRIPT_DIR/build_lua_protobuf.sh"; fi
    BUILD_TYPE="$BUILD_TYPE" bash "$FLYWOW_DIR/scripts/build_flywow.sh" "$SKYNET_ROOT"
    [[ -s "$MAP_FILE" ]] || fail "缺少正式地图资产：$MAP_FILE"
    log PREPARE_OK
}
run_build() { prepare_runtime; "$SCRIPT_DIR/check_lua_varargs.sh"; log BUILD_OK; }
run_rebuild() {
    rm -rf "$FLYWOW_DIR/build" "$SERVER_ROOT/build/native"
    if [[ -f "$SKYNET_ROOT/Makefile" ]]; then make -C "$SKYNET_ROOT" clean >/dev/null 2>&1 || true; fi
    "$SCRIPT_DIR/build_skynet.sh"
    "$SCRIPT_DIR/build_lua_protobuf.sh"
    run_build
    log REBUILD_OK
}
if [[ $# -ne 1 ]]; then usage >&2; exit 2; fi
case "$1" in -h|--help) usage; exit 0 ;; prepare|build|rebuild) ACTION="$1" ;; *) usage >&2; fail "未知构建动作：$1" ;; esac
cd "$SERVER_ROOT"
case "$ACTION" in prepare) prepare_runtime ;; build) run_build ;; rebuild) run_rebuild ;; esac
