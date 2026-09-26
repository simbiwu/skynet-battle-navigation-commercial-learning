#!/usr/bin/env bash
# Apply the documentation/content-aware part of this overlay after extracting it at repository root.
set -euo pipefail

ROOT="${1:-$(pwd)}"
ROOT="$(cd -- "$ROOT" && pwd)"
cd "$ROOT"

[[ -f AGENTS.md && -d server && -d docs && -d codex ]] || {
    echo "UPDATE_ROOT_INVALID: run this from skynet-battle-navigation-commercial-learning repository root" >&2
    exit 1
}

python3 tools/apply_docs_update.py "$ROOT"
chmod +x server/scripts/linux/run_server.sh server/scripts/linux/stop_server.sh
bash -n server/scripts/linux/run_server.sh
bash -n server/scripts/linux/stop_server.sh

# Static consistency guards; these do not require third_party dependencies to be downloaded.
! grep -q 'require "skynet.socket"' server/service/navigation_gateway.lua
! grep -q 'socket.read' server/service/navigation_gateway.lua
! grep -q 'network.length_frame' server/service/navigation_gateway.lua
grep -q 'require "skynet.socketdriver"' server/service/navigation_gateway.lua
grep -q 'require "skynet.netpack"' server/service/navigation_gateway.lua
grep -q 'netpack.filter' server/service/navigation_gateway.lua
grep -q 'netpack.pack' server/service/navigation_gateway.lua

if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git diff --check
    echo
    git diff --stat
fi

echo "UPDATE_APPLIED_OK"
echo "Next: cd server && ./scripts/linux/run_server.sh doctor"
echo "Then: ./scripts/linux/run_server.sh start"
