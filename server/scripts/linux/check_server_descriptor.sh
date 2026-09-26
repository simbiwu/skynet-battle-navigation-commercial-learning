#!/usr/bin/env bash
# 职责：使用项目自带 Lua 和固定 pb.so 验证 Server descriptor。
# 边界：Protocol Build Check；不依赖系统 lua 命令，不启动 Skynet。
# 输入/输出：navigation_query.pb -> PROTO_DESCRIPTOR_OK 或非零退出码。
# 生命周期：协议生成后或 Server 启动前执行；只读验证，不修改 descriptor。
# 不负责：不编译 protoc、不加载地图、不启动 Skynet Service。
set -euo pipefail

# ROOT 是 server 根目录；REPO_ROOT 用来访问跨端共享协议发布物。
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
LUA="$ROOT/third_party/skynet/3rd/lua/lua"
RUNTIME="$ROOT/third_party/lua-protobuf-runtime"
DESCRIPTOR="$REPO_ROOT/shared/protocol/generated/server/navigation_query.pb"

# 固定使用 Skynet 自带 Lua 和本项目编译的 pb.so，避免系统 Lua ABI 偶然通过。
test -x "$LUA"
test -s "$RUNTIME/pb.so"
test -s "$DESCRIPTOR"

# LUA_PATH/C。本次只临时覆盖子进程环境，不污染调用 Shell。
LUA_PATH="$RUNTIME/?.lua;;" \
LUA_CPATH="$RUNTIME/?.so;;" \
    "$LUA" "$ROOT/protocol/check_descriptor.lua" "$DESCRIPTOR"
