#!/usr/bin/env bash
# 职责：以 debug-only LuaPanda 环境启动 Lesson 1 Server；可选同时进入 gdb。
# 使用前：VS Code 中先启动 Gateway(8818)+Query(8819) 两个 LuaPanda target。
# 输入/输出：--gdb 和 LUA_PANDA_* 环境变量 -> 前台 Skynet 或 gdb 控制的 Skynet。
# 生命周期：仅用于本地 Debug；不会被普通 run_server.sh start 自动调用。
# 不负责：不实现 LuaPanda 协议、不替代 run_server.sh 的 PID 管理、不修改生产配置。
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
MODE="lua"

# 参数只决定是否把同一个 Server 进程交给 gdb；LuaPanda 依赖准备始终复用 bootstrap 脚本。
if [[ "${1:-}" == "--gdb" ]]; then
    MODE="gdb"
    shift
fi
[[ $# -eq 0 ]] || { echo "usage: $0 [--gdb]" >&2; exit 2; }

# LuaPanda 必须先针对 Skynet bundled Lua ABI 构建 LuaSocket，再启动 Service。
"$SCRIPT_DIR/bootstrap_luapanda.sh"

# export 让 main 创建的每个 Service Lua State 都能看到调试开关和对应端口。
export LUA_PANDA_ENABLE=1
export LUA_PANDA_HOST="${LUA_PANDA_HOST:-127.0.0.1}"
export LUA_PANDA_GATEWAY_PORT="${LUA_PANDA_GATEWAY_PORT:-8818}"
export LUA_PANDA_QUERY_PORT="${LUA_PANDA_QUERY_PORT:-8819}"

printf '[luapanda-debug] gateway=%s:%s query=%s:%s\n' \
    "$LUA_PANDA_HOST" "$LUA_PANDA_GATEWAY_PORT" \
    "$LUA_PANDA_HOST" "$LUA_PANDA_QUERY_PORT"

if [[ "$MODE" == "gdb" ]]; then
    # gdb 负责 C++ 断点；LuaPanda 仍由 Service 内的 debug.luapanda 模块连接 VS Code。
    command -v gdb >/dev/null 2>&1 || {
        echo "gdb is required: sudo apt-get install -y gdb" >&2
        exit 1
    }
    "$SCRIPT_DIR/run_server.sh" doctor
    cd "$SERVER_ROOT"
    exec gdb -x "$SERVER_ROOT/debug/gdb/lesson1.gdb" \
        --args "$SERVER_ROOT/third_party/skynet/skynet" config/skynet.lua
fi

exec "$SCRIPT_DIR/run_server.sh" foreground
