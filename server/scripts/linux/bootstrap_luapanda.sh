#!/usr/bin/env bash
# 职责：为 Skynet bundled Lua 5.4 构建 Lesson 1 LuaPanda 调试依赖。
# 边界：Debug Tool Bootstrap；所有文件只写入 server/third_party，正常 Server 不依赖它。
# 输入/输出：固定 LuaPanda commit + LuaSocket tag -> LuaPanda.lua + 本地 LuaSocket runtime。
# 不负责：不启动 Server、不改系统 Lua、不 sudo 安装、不进入生产依赖链。
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
source "$SERVER_ROOT/debug/luapanda/VERSIONS.env"

SKYNET_ROOT="$SERVER_ROOT/third_party/skynet"
SKYNET_LUA_HEADERS="$SKYNET_ROOT/3rd/lua"
SKYNET_LUA="$SKYNET_ROOT/3rd/lua/lua"
LUAPANDA_DIR="$SERVER_ROOT/third_party/luapanda"
LUASOCKET_SRC="$SERVER_ROOT/third_party/luasocket"
LUASOCKET_RUNTIME="$SERVER_ROOT/third_party/luasocket-runtime"

log() { printf '[luapanda-bootstrap] %s\n' "$*"; }
fail() { printf '[luapanda-bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }

for tool in curl tar make cc install mktemp find; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing system tool: $tool"
done

mkdir -p "$SERVER_ROOT/third_party"

if [[ ! -f "$SKYNET_LUA_HEADERS/lua.h" ]]; then
    log "Skynet source missing; bootstrap pinned Skynet first"
    "$SCRIPT_DIR/bootstrap_skynet.sh"
fi
if [[ ! -x "$SKYNET_LUA" ]]; then
    log "Skynet bundled Lua executable missing; building Skynet"
    "$SCRIPT_DIR/build_skynet.sh"
fi

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
    curl -fL --retry 4 --retry-delay 2 \
        "https://codeload.github.com/lunarmodules/luasocket/tar.gz/refs/tags/$LUASOCKET_TAG" \
        -o "$archive"
    mkdir -p "$LUASOCKET_SRC"
    tar -xzf "$archive" --strip-components=1 -C "$LUASOCKET_SRC"
    printf '%s\n' "$LUASOCKET_TAG" > "$LUASOCKET_SRC/.pinned-tag"
)

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

    rm -rf -- "$LUASOCKET_RUNTIME"
    mv "$staging" "$LUASOCKET_RUNTIME"
}

verify_runtime() {
    local lua_path lua_cpath
    lua_path="$LUASOCKET_RUNTIME/share/lua/5.4/?.lua;$LUASOCKET_RUNTIME/share/lua/5.4/?/init.lua;$LUAPANDA_DIR/?.lua;;"
    lua_cpath="$LUASOCKET_RUNTIME/lib/lua/5.4/?.so;$LUASOCKET_RUNTIME/lib/lua/5.4/?/core.so;;"

    LUA_PATH="$lua_path" LUA_CPATH="$lua_cpath" \
        "$SKYNET_LUA" -e '
            local core = assert(require("socket.core"))
            local tcp = assert(core.tcp())
            tcp:close()
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
