#!/usr/bin/env bash
# 职责：把 navigation_query.proto 编译成 Server 使用的 descriptor set。
# 边界：离线 Build Script；输出构建资产，不启动 Skynet。
# 输入/输出：protocol/navigation_query.proto -> descriptor 和 SHA-256 文件。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/protocol/VERSIONS.env"
PROTOC="${PROTOC:-$ROOT/third_party/protoc-$PROTOC_VERSION/bin/protoc}"
OUT="$ROOT/protocol/generated/server"
mkdir -p "$OUT"

test -x "$PROTOC"
"$PROTOC" --version
rm -f "$OUT/navigation_query.pb"
"$PROTOC" \
  --descriptor_set_out="$OUT/navigation_query.pb" \
  --include_imports \
  -I "$ROOT/protocol" \
  "$ROOT/protocol/navigation_query.proto"

test -s "$OUT/navigation_query.pb"
sha256sum "$OUT/navigation_query.pb" > "$OUT/navigation_query.pb.sha256"
echo "SERVER_DESCRIPTOR_OK $OUT/navigation_query.pb"