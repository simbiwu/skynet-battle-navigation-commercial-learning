#!/usr/bin/env bash
# 安全停止入口：复用 run_server.sh 的 PID 身份校验、SIGTERM 等待和可选 --force 逻辑。
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/run_server.sh" stop "$@"
