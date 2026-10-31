#!/usr/bin/env bash
# 第一行 shebang 告诉系统用 Bash 解释本文件；也可显式运行 bash 加脚本路径。
# 调用：可从任意当前工作目录启动；脚本按自身路径定位工程目录。外部相对路径参数按调用时目录解析，建议传绝对路径。
# 示例：bash /absolute/path/to/checkout/server/scripts/linux/bootstrap_luapanda.sh [按本文件头部说明填写参数]
# 职责：为 Skynet bundled Lua 5.4 构建 Lesson 1 LuaPanda 调试依赖。
# 边界：Debug Tool Bootstrap；所有文件只写入 server/third_party，正常 Server 不依赖它。
# 输入/输出：固定 LuaPanda commit + LuaSocket tag -> LuaPanda.lua + 本地 LuaSocket runtime。
# 不负责：不启动 Server、不改系统 Lua、不 sudo 安装、不进入生产依赖链。
# 生命周期：供 debug_luapanda.sh 和 run_server.sh debug 准备本地调试产物；产物与 Skynet bundled Lua 5.4 ABI 绑定。
set -euo pipefail
# Bash 语法速读：只解释本脚本实际使用的 Bash 写法；流程注释说明每一步为什么执行。
#   set -euo pipefail：-e 遇到未处理的失败通常退出，但条件判断、&& 和 || 等位置有例外，关键失败仍应显式检查；-u 遇到未设置变量时报错（提供默认值展开时除外）；pipefail 让管道任一步失败都能向外报告。
#   双引号中的 "$NAME" 把变量值作为一个完整参数；路径含空格时不会拆成多个参数。
#   $(命令)运行命令并用标准输出替换当前位置；命令在子 Shell 中运行，里面的 cd 不改变主脚本目录。
#   [[ 条件 ]]执行 Bash 条件判断；-f检查普通文件，-x检查可执行文件，-s检查非空文件，-e检查存在的路径，-n检查非空字符串。
#   name() { ...; }定义函数；调用函数名即可执行函数体。
#   local 声明函数内部临时变量；函数返回后恢复调用者同名变量的值。
#   for/while ... do ... done 重复执行循环体；列表或条件决定循环何时结束。
#   >把输出写入并覆盖文件；2>&1把标准错误接到标准输出当前去向。
#   trap 登记退出或信号时执行的清理动作；单引号使变量在事件发生时再展开。
# -e：任意未处理的失败立即退出，避免错误结果继续传给下一阶段。
# -u：读取未定义变量时立即失败，尽早发现环境变量或变量名错误。
# pipefail：管道中任一命令失败都会让整条管道失败，避免只检查到最后一条命令。

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# source：在当前 Shell 进程加载固定版本配置，使后续变量和校验使用同一份清单。
source "$SERVER_ROOT/debug/luapanda/VERSIONS.env"

SKYNET_ROOT="$SERVER_ROOT/third_party/skynet"
SKYNET_LUA_HEADERS="$SKYNET_ROOT/3rd/lua"
SKYNET_LUA="$SKYNET_ROOT/3rd/lua/lua"
LUAPANDA_DIR="$SERVER_ROOT/third_party/luapanda"
LUASOCKET_SRC="$SERVER_ROOT/third_party/luasocket"
LUASOCKET_RUNTIME="$SERVER_ROOT/third_party/luasocket-runtime"

# 日志函数让下载、编译和验证阶段在 CI/终端中可区分。
log() { printf '[luapanda-bootstrap] %s\n' "$*"; }
# 依赖或版本不满足时立即终止；调试器不可用时不能继续启动假调试环境。
fail() { printf '[luapanda-bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }

# 这些工具分别用于下载、解压、编译、安装文件、创建临时目录和定位源码文件。
for tool in curl tar make cc install mktemp find; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing system tool: $tool"
done

mkdir -p "$SERVER_ROOT/third_party"

# LuaSocket 的 C 模块必须使用实际宿主 Skynet Lua 的头文件和 ABI。
if [[ ! -f "$SKYNET_LUA_HEADERS/lua.h" ]]; then
# trap：注册退出清理动作，下载或构建失败时也释放临时文件。
    log "Skynet source missing; bootstrap pinned Skynet first"
    "$SCRIPT_DIR/bootstrap_skynet.sh"
fi
if [[ ! -x "$SKYNET_LUA" ]]; then
    log "Skynet bundled Lua executable missing; building Skynet"
    "$SCRIPT_DIR/build_skynet.sh"
fi

# 下载 LuaPanda Lua 源码文件；目录中的 pin marker 表示它由本脚本准备。
install_luapanda() (
    if [[ -f "$LUAPANDA_DIR/.pinned-commit" ]]; then
        local actual
        actual="$(cat "$LUAPANDA_DIR/.pinned-commit")"
        [[ "$actual" == "$LUAPANDA_COMMIT" ]] || \
            fail "LuaPanda version mismatch: expected=$LUAPANDA_COMMIT actual=$actual"
        [[ -s "$LUAPANDA_DIR/LuaPanda.lua" ]] || fail "LuaPanda.lua missing"
        return
    fi
    [[ ! -e "$LUAPANDA_DIR" ]] || fail "unmanaged LuaPanda directory exists: $LUAPANDA_DIR"

    local archive temp source_file
    archive="$(mktemp --suffix=.tar.gz)"
    temp="$(mktemp -d)"
    trap 'rm -f "$archive"; rm -rf "$temp"' EXIT

    log "downloading LuaPanda $LUAPANDA_VERSION ($LUAPANDA_COMMIT)"
    # 使用固定 commit 的源码快照；LuaPanda 是 debug-only 源码，不需要 Git 历史。
    curl -fL --retry 4 --retry-delay 2 \
        "https://codeload.github.com/Tencent/LuaPanda/tar.gz/$LUAPANDA_COMMIT" \
        -o "$archive"
    tar -xzf "$archive" -C "$temp"
    source_file="$(find "$temp" -path '*/Debugger/LuaPanda.lua' -type f -print -quit)"
    [[ -n "$source_file" ]] || fail "LuaPanda.lua not found in downloaded archive"

    mkdir -p "$LUAPANDA_DIR"
    install -m 0644 "$source_file" "$LUAPANDA_DIR/LuaPanda.lua"
    printf '%s\n' "$LUAPANDA_COMMIT" > "$LUAPANDA_DIR/.pinned-commit"
)

# 下载 LuaSocket 源码；它最终会针对 Skynet bundled Lua 5.4 编译成 .so。
install_luasocket_source() (
    if [[ -f "$LUASOCKET_SRC/.pinned-tag" ]]; then
        local actual
        actual="$(cat "$LUASOCKET_SRC/.pinned-tag")"
        [[ "$actual" == "$LUASOCKET_TAG" ]] || \
            fail "LuaSocket version mismatch: expected=$LUASOCKET_TAG actual=$actual"
        [[ -f "$LUASOCKET_SRC/src/makefile" ]] || fail "LuaSocket source incomplete"
        return
    fi
    [[ ! -e "$LUASOCKET_SRC" ]] || fail "unmanaged LuaSocket directory exists: $LUASOCKET_SRC"

    local archive temp
    archive="$(mktemp --suffix=.tar.gz)"
    temp="$(mktemp -d)"
    trap 'rm -f "$archive"; rm -rf "$temp"' EXIT

    log "downloading LuaSocket $LUASOCKET_VERSION"
    # tag 固定在 URL 中；--strip-components=1 去掉 GitHub 压缩包外层目录。
    curl -fL --retry 4 --retry-delay 2 \
        "https://codeload.github.com/lunarmodules/luasocket/tar.gz/refs/tags/$LUASOCKET_TAG" \
        -o "$archive"
    mkdir -p "$LUASOCKET_SRC"
    tar -xzf "$archive" --strip-components=1 -C "$LUASOCKET_SRC"
    printf '%s\n' "$LUASOCKET_TAG" > "$LUASOCKET_SRC/.pinned-tag"
)

# 编译并安装到临时 staging，再一次性替换 runtime，避免留下半套 .so/.lua 文件。
build_luasocket_runtime() {
    local staging="$SERVER_ROOT/third_party/.luasocket-runtime.tmp.$$"
    rm -rf -- "$staging"
    mkdir -p "$staging"

    log "building LuaSocket against Skynet bundled Lua 5.4 headers"
    make -C "$LUASOCKET_SRC" clean >/dev/null
    make -C "$LUASOCKET_SRC" linux \
        LUAV=5.4 \
        LUAINC_linux="$SKYNET_LUA_HEADERS"
    make -C "$LUASOCKET_SRC" install \
        LUAV=5.4 \
        LUAINC_linux="$SKYNET_LUA_HEADERS" \
        prefix="$staging" \
        CDIR="lib/lua/5.4" \
        LDIR="share/lua/5.4"

    # 这里删除的只是脚本拥有的 third_party/luasocket-runtime，不涉及源码和系统目录。
    rm -rf -- "$LUASOCKET_RUNTIME"
    mv "$staging" "$LUASOCKET_RUNTIME"
}

# 用同一个 bundled Lua 进程同时加载 socket.core 和 LuaPanda，验证 ABI 与搜索路径。
verify_runtime() {
    local lua_path lua_cpath
    lua_path="$LUASOCKET_RUNTIME/share/lua/5.4/?.lua;$LUASOCKET_RUNTIME/share/lua/5.4/?/init.lua;$LUAPANDA_DIR/?.lua;;"
    lua_cpath="$LUASOCKET_RUNTIME/lib/lua/5.4/?.so;$LUASOCKET_RUNTIME/lib/lua/5.4/?/core.so;;"

    LUA_PATH="$lua_path" LUA_CPATH="$lua_cpath" \
        "$SKYNET_LUA" -e '
            -- socket.core 成功加载才说明 C ABI、动态库路径和 LuaSocket 安装完整。
            local core = assert(require("socket.core"))
            local tcp = assert(core.tcp())
            tcp:close()
            -- LuaPanda 依赖 LuaSocket；两者都成功后才允许 debug_luapanda.sh 启动。
            local panda = assert(require("LuaPanda"))
            assert(type(panda.start) == "function")
            print("LUAPANDA_RUNTIME_OK")
        '
}

install_luapanda
install_luasocket_source
build_luasocket_runtime
verify_runtime

log "READY LuaPanda=$LUAPANDA_VERSION LuaSocket=$LUASOCKET_VERSION"
log "runtime=$LUASOCKET_RUNTIME"
