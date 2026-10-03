#!/usr/bin/env bash
# 职责：保留课程构建命令，将构建与测试转交唯一 FlyWow Navigation 源码。
# 边界：宿主 Build Adapter；不维护算法副本、不下载框架、不启动 Server。
set -euo pipefail
SERVER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
FLYWOW_ROOT="${FLYWOW_ROOT:-$SERVER_ROOT/third_party/skynet-flywow}"
exec "$FLYWOW_ROOT/navigation/scripts/build.sh" "$SERVER_ROOT/third_party/skynet" "$SERVER_ROOT/build/flywow_navigation"
