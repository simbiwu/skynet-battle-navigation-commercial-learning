#!/usr/bin/env bash
# 职责：使用项目自带 Lua 和固定 pb.so 验证 Server descriptor。
# 边界：Protocol Build Check；不依赖系统 lua 命令，不启动 Skynet。
# 输入/输出：navigation_query.pb -> PROTO_DESCRIPTOR_OK 或非零退出码。
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
LUA="$ROOT/third_party/skynet/3rd/lua/lua"
RUNTIME="$ROOT/third_party/lua-protobuf-runtime"
DESCRIPTOR="$REPO_ROOT/shared/protocol/generated/server/navigation_query.pb"

test -x "$LUA"
test -s "$RUNTIME/pb.so"
test -s "$DESCRIPTOR"

LUA_PATH="$RUNTIME/?.lua;;" \
LUA_CPATH="$RUNTIME/?.so;;" \
    "$LUA" "$ROOT/protocol/check_descriptor.lua" "$DESCRIPTOR"
