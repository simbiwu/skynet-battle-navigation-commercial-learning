#!/usr/bin/env bash
# 第一行 shebang 告诉系统用 Bash 解释本文件；也可显式运行 bash 加脚本路径。
# 调用：可从任意当前工作目录启动；脚本按自身路径定位工程目录。外部相对路径参数按调用时目录解析，建议传绝对路径。
# 示例：bash /absolute/path/to/checkout/server/scripts/linux/build_server.sh [按本文件头部说明填写参数]
# 职责：执行与具体课程服务进程无关的 Server Runtime 准备、增量构建和完整重建。
# 调用：bash /path/to/server/scripts/linux/build_server.sh prepare|build|rebuild；总入口 run_server.sh 仅转发通用构建命令。
# 参数：一个动作；不接受课程生命周期参数。-h/--help 只显示帮助。
# 路径：脚本自动定位 server/、仓库 shared/；相对路径均以 server/ 为基准。
# 环境变量：BUILD_TYPE 可选，传给 FlyWow CMake，默认 RelWithDebInfo。
# 输入：固定版本 Skynet、FlyWow、Lua protobuf 源码及正式 shared/navigation/battle_1001/battle_1001.bmap。
# 输出：更新 Skynet、pb.so、FlyWow Native 构建产物；build 还运行 Lua 可变参数检查。
# 进程：不启动、停止或查询课程进程，不创建 PID 文件或重定向课程日志。
# rebuild：清理可再生产物后重建，不触碰源码、课程配置、日志和运行地图。
set -euo pipefail
# Bash 语法速读：只解释本脚本实际使用的 Bash 写法；流程注释说明每一步为什么执行。
#   set -euo pipefail：-e 遇到未处理的失败通常退出，但条件判断、&& 和 || 等位置有例外，关键失败仍应显式检查；-u 遇到未设置变量时报错（提供默认值展开时除外）；pipefail 让管道任一步失败都能向外报告。
#   双引号中的 "$NAME" 把变量值作为一个完整参数；路径含空格时不会拆成多个参数。
#   $(命令)运行命令并用标准输出替换当前位置；命令在子 Shell 中运行，里面的 cd 不改变主脚本目录。
#   NAME:-默认值展开：变量未设置或为空字符串时使用默认值。
#   $#表示参数个数，$1/$2依次表示传入的第一个/第二个参数。
#   [[ 条件 ]]执行 Bash 条件判断；-f检查普通文件，-x检查可执行文件，-s检查非空文件。
#   case ... in 按输入匹配分支；分支以 ) 开始、;;结束，*)是兜底分支。
#   name() { ...; }定义函数；调用函数名即可执行函数体。
#   单竖线 | 把左侧标准输出交给右侧；它不同于条件运算符 ||。
#   >把输出写入并覆盖文件；2>&1把标准错误接到标准输出当前去向。
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd -- "$SERVER_ROOT/.." && pwd)"
FLYWOW_DIR="$SERVER_ROOT/third_party/skynet-flywow"
SKYNET_ROOT="$SERVER_ROOT/third_party/skynet"
SKYNET_BIN="$SKYNET_ROOT/skynet"
MAP_FILE="$REPO_ROOT/shared/navigation/battle_1001/battle_1001.bmap"
# BUILD_TYPE 未设置或为空时使用 RelWithDebInfo；例如 BUILD_TYPE=Debug bash ... 会让本次构建使用 Debug。
BUILD_TYPE="${BUILD_TYPE:-RelWithDebInfo}"
# usage 只显示帮助，不读取依赖也不改变文件；单引号 here-document 保留文字中的 $ 符号。
usage() {
    cat <<'USAGE'
用法：bash /path/to/server/scripts/linux/build_server.sh prepare|build|rebuild
  prepare  准备固定版本依赖并检查正式地图。
  build    prepare 后执行增量构建和 Lua 可变参数检查。
  rebuild  清理可再生产物后完整构建。
环境变量：BUILD_TYPE 可选，默认 RelWithDebInfo。
服务生命周期请使用 bash /path/to/server/scripts/linux/run_server.sh lessonN ...。
USAGE
}
# fail/log 是统一输出入口：fail 发错误到标准错误并以 1 退出，log 输出阶段标记。
fail() { printf '[server-build] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[server-build] %s\n' "$*"; }

# prepare_runtime 按依赖顺序准备 Skynet、Lua protobuf、FlyWow，再确认地图已发布。
# 这些调用都使用脚本目录推导出的绝对路径，因此不受启动目录影响。
prepare_runtime() {
    "$SCRIPT_DIR/bootstrap_skynet.sh"

    if [[ ! -x "$SKYNET_BIN" ]]; then
        "$SCRIPT_DIR/build_skynet.sh"
    fi

    if [[ ! -s "$SERVER_ROOT/third_party/lua-protobuf-runtime/pb.so" ]]; then
        "$SCRIPT_DIR/build_lua_protobuf.sh"
    fi

    BUILD_TYPE="$BUILD_TYPE" bash "$FLYWOW_DIR/scripts/build_flywow.sh" "$SKYNET_ROOT"
    [[ -s "$MAP_FILE" ]] || fail "缺少正式地图资产：$MAP_FILE"
    log PREPARE_OK
}

# build 在 prepare 完成后执行静态检查；任一命令失败都会由严格模式停止。
run_build() {
    prepare_runtime
    "$SCRIPT_DIR/check_lua_varargs.sh"
    log BUILD_OK
}

# rebuild 只清理可再生成的构建目录和 Skynet 中间产物，不删除源码或正式资产。
run_rebuild() {
    rm -rf "$FLYWOW_DIR/build" "$SERVER_ROOT/build/native"

    if [[ -f "$SKYNET_ROOT/Makefile" ]]; then
        # make clean 的输出不用于验收；已有源码目录时尽力清理，随后仍执行正式重建。
        make -C "$SKYNET_ROOT" clean >/dev/null 2>&1 || true
    fi

    "$SCRIPT_DIR/build_skynet.sh"
    "$SCRIPT_DIR/build_lua_protobuf.sh"
    run_build
    log REBUILD_OK
}

# $# 是收到的位置参数数量；本入口只接受一个构建动作，帮助选项单独处理。
if [[ $# -ne 1 ]]; then
    usage >&2
    exit 2
fi

# case 按第一个参数分派；ACTION 保存通过白名单验证的动作名。
case "$1" in
    -h|--help)
        usage
        exit 0
        ;;
    prepare|build|rebuild)
        ACTION="$1"
        ;;
    *)
        usage >&2
        fail "未知构建动作：$1"
        ;;
esac

# 构建脚本内部采用 server/ 为相对路径基准；先切到该目录，再执行动作。
cd "$SERVER_ROOT"
case "$ACTION" in
    prepare) prepare_runtime ;;
    build) run_build ;;
    rebuild) run_rebuild ;;
esac
