#!/usr/bin/env bash
# 第一行 shebang 告诉系统用 Bash 解释本文件；也可显式运行 bash 加脚本路径。
# 调用：可从任意当前工作目录启动；脚本按自身路径定位工程目录。外部相对路径参数按调用时目录解析，建议传绝对路径。
# 示例：bash /absolute/path/to/checkout/server/scripts/linux/build_lua_protobuf.sh [按本文件头部说明填写参数]
# 职责：针对项目自带 Lua 5.4 ABI 编译固定版本的 lua-protobuf pb.so。
# 边界：Server Native Build；不安装系统 Lua，不写入 /usr/local。
# 输入/输出：lua-protobuf pb.c + Skynet Lua headers -> lua-protobuf-runtime/pb.so。
# 失败约定：源码、Lua Header 或编译失败时立即退出。
# 生命周期：Skynet bundled Lua 编译完成后执行；输出只属于当前 server 工作区。
# 不负责：不使用系统 Lua ABI、不安装到 /usr/local、不生成协议 descriptor。
set -euo pipefail
# Bash 语法速读：只解释本脚本实际使用的 Bash 写法；流程注释说明每一步为什么执行。
#   set -euo pipefail：-e 遇到未处理的失败通常退出，但条件判断、&& 和 || 等位置有例外，关键失败仍应显式检查；-u 遇到未设置变量时报错（提供默认值展开时除外）；pipefail 让管道任一步失败都能向外报告。
#   双引号中的 "$NAME" 把变量值作为一个完整参数；路径含空格时不会拆成多个参数。
#   $(命令)运行命令并用标准输出替换当前位置；命令在子 Shell 中运行，里面的 cd 不改变主脚本目录。
#   >把输出写入并覆盖文件；2>&1把标准错误接到标准输出当前去向。
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
