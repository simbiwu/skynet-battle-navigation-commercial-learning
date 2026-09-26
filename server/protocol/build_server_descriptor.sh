#!/usr/bin/env bash
# 职责：把仓库共享的 navigation_query.proto 编译成 Server 使用的 descriptor set。
# 边界：离线 Build Script；只更新 shared/protocol 下可提交的协议生成物，不启动 Skynet。
# 输入/输出：shared/protocol/navigation_query.proto -> descriptor 和稳定 SHA-256 文件。
# 生命周期：协议源变更后由开发者显式执行；生成物随同协议源提交并由各部署端拉取。
# 不负责：不生成 Unity C#、不启动 Server、不从另一台机器复制运行时文件。
set -euo pipefail

SERVER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SERVER_ROOT/.." && pwd)"
PROTO_ROOT="$REPO_ROOT/shared/protocol"
source "$PROTO_ROOT/VERSIONS.env"
PROTOC="${PROTOC:-$SERVER_ROOT/third_party/protoc-$PROTOC_VERSION/bin/protoc}"
OUT="$PROTO_ROOT/generated/server"
mkdir -p "$OUT"

test -x "$PROTOC"
"$PROTOC" --version
rm -f "$OUT/navigation_query.pb"
"$PROTOC" \
  --descriptor_set_out="$OUT/navigation_query.pb" \
  --include_imports \
  -I "$PROTO_ROOT" \
  "$PROTO_ROOT/navigation_query.proto"

test -s "$OUT/navigation_query.pb"
# 校验清单只记录文件名，避免把开发机绝对路径写入可提交资产。
(cd "$OUT" && sha256sum navigation_query.pb > navigation_query.pb.sha256)
sha256sum "$PROTO_ROOT/navigation_query.proto" | awk '{print $1}' > "$OUT/navigation_query.source.sha256"
echo "SERVER_DESCRIPTOR_OK $OUT/navigation_query.pb"
