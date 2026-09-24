#!/usr/bin/env bash
# 职责：针对项目自带 Lua 5.4 ABI 编译固定版本的 lua-protobuf pb.so。
# 边界：Server Native Build；不安装系统 Lua，不写入 /usr/local。
# 输入/输出：lua-protobuf pb.c + Skynet Lua headers -> lua-protobuf-runtime/pb.so。
# 失败约定：源码、Lua Header 或编译失败时立即退出。
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE="$ROOT/third_party/lua-protobuf"
LUA_HEADERS="$ROOT/third_party/skynet/3rd/lua"
OUTPUT="$ROOT/third_party/lua-protobuf-runtime"

test -f "$SOURCE/pb.c"
test -f "$SOURCE/protoc.lua"
test -f "$LUA_HEADERS/lua.h"
command -v cc >/dev/null
mkdir -p "$OUTPUT"

cc -O2 -shared -fPIC -Wall -Wextra \
    -I "$LUA_HEADERS" \
    "$SOURCE/pb.c" \
    -o "$OUTPUT/pb.so"
cp "$SOURCE/protoc.lua" "$OUTPUT/protoc.lua"
test -s "$OUTPUT/pb.so"

echo "LUA_PROTOBUF_BUILD_OK $OUTPUT/pb.so"
