#!/usr/bin/env bash
# 职责：针对项目自带 Lua 5.4 ABI 编译固定版本的 lua-protobuf pb.so。
# 边界：Server Native Build；不安装系统 Lua，不写入 /usr/local。
# 输入/输出：lua-protobuf pb.c + Skynet Lua headers -> lua-protobuf-runtime/pb.so。
# 失败约定：源码、Lua Header 或编译失败时立即退出。
# 生命周期：Skynet bundled Lua 编译完成后执行；输出只属于当前 server 工作区。
# 不负责：不使用系统 Lua ABI、不安装到 /usr/local、不生成协议 descriptor。
set -euo pipefail

# ROOT 是 server 根目录；所有输入输出都由它推导，避免依赖调用者当前目录。
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE="$ROOT/third_party/lua-protobuf"
LUA_HEADERS="$ROOT/third_party/skynet/3rd/lua"
OUTPUT="$ROOT/third_party/lua-protobuf-runtime"

# pb.c 必须与 Skynet 的 Lua 头文件使用同一个 Lua ABI 编译。
test -f "$SOURCE/pb.c"
test -f "$SOURCE/protoc.lua"
test -f "$LUA_HEADERS/lua.h"
command -v cc >/dev/null
mkdir -p "$OUTPUT"

# 生成 position-independent shared object，供 Lua require 加载为 pb.so。
cc -O2 -shared -fPIC -Wall -Wextra \
    -I "$LUA_HEADERS" \
    "$SOURCE/pb.c" \
    -o "$OUTPUT/pb.so"
cp "$SOURCE/protoc.lua" "$OUTPUT/protoc.lua"
test -s "$OUTPUT/pb.so"

echo "LUA_PROTOBUF_BUILD_OK $OUTPUT/pb.so"
