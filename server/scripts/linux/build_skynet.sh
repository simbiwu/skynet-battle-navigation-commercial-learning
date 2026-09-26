#!/usr/bin/env bash
# 职责：使用已固定的 Skynet 源码构建 skynet 可执行文件和 bundled Lua 运行时。
# 边界：Server Build；读取 third_party/skynet，写回该目录的本机构建产物。
# 输入/输出：Skynet Makefile -> third_party/skynet/skynet 与 3rd/lua/lua。
# 生命周期：bootstrap_skynet 成功后执行；可重复执行，不修改源码版本。
# 不负责：不下载依赖、不启动 Server、不使用系统 Lua 替代 Skynet bundled Lua。
set -euo pipefail

# 以脚本位置推导 server 根目录，调用者无需先 cd 到固定目录。
SERVER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$SERVER_ROOT"

# Makefile 是源码完整性的最低检查；缺失时给出明确失败而不是让 make 输出难懂错误。
test -f third_party/skynet/Makefile
# linux 目标同时构建 Skynet 和它实际使用的 Lua 5.4 ABI。
make -C third_party/skynet linux

# 这些文件是后续 Lua C 模块和 Server 启动的明确前置条件。
test -x third_party/skynet/skynet
test -f third_party/skynet/3rd/lua/lua.h
echo "SKYNET_BUILD_OK"
