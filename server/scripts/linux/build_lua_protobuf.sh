#!/usr/bin/env bash
# 职责：针对项目自带 Lua 5.4 ABI 编译固定版本的 lua-protobuf pb.so。
# 边界：Server Native Build；不安装系统 Lua，不写入 /usr/local。
# 输入/输出：lua-protobuf pb.c + Skynet Lua headers -> lua-protobuf-runtime/pb.so。
# 失败约定：源码、Lua Header 或编译失败时立即退出。
# 生命周期：Skynet bundled Lua 编译完成后执行；输出只属于当前 server 工作区。
# 不负责：不使用系统 Lua ABI、不安装到 /usr/local、不生成协议 descriptor。
set -euo pipefail
# -e：任意未处理的失败立即退出，避免错误结果继续传给下一阶段。
# -u：读取未定义变量时立即失败，尽早发现环境变量或变量名错误。
# pipefail：管道中任一命令失败都会让整条管道失败，避免只检查到最后一条命令。

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
# 输出目录是 Server 自己的第三方运行时边界，先创建后再安装编译产物。
mkdir -p "$OUTPUT"

# 生成 position-independent shared object，供 Lua require 加载为 pb.so。
# 以位置无关代码生成 Lua 可加载共享库，并使用当前 Lua 头文件保持 ABI 一致。
cc -O2 -shared -fPIC -Wall -Wextra \
    -I "$LUA_HEADERS" \
    "$SOURCE/pb.c" \
    -o "$OUTPUT/pb.so"
cp "$SOURCE/protoc.lua" "$OUTPUT/protoc.lua"
test -s "$OUTPUT/pb.so"

echo "LUA_PROTOBUF_BUILD_OK $OUTPUT/pb.so"
