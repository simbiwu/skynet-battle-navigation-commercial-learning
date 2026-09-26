#!/usr/bin/env bash
# Apply Lesson 1 final recap/debug/acceptance update after extracting at repository root.
set -euo pipefail

ROOT="${1:-$(pwd)}"
ROOT="$(cd -- "$ROOT" && pwd)"
cd "$ROOT"

[[ -f AGENTS.md && -d server && -d docs ]] || {
    echo "UPDATE_ROOT_INVALID: run this from skynet-battle-navigation-commercial-learning repository root" >&2
    exit 1
}

python3 tools/apply_lesson1_31_update.py "$ROOT"

chmod +x \
  server/scripts/linux/lesson1_prepare.sh \
  server/scripts/linux/bootstrap_luapanda.sh \
  server/scripts/linux/debug_luapanda.sh

bash -n server/scripts/linux/lesson1_prepare.sh
bash -n server/scripts/linux/bootstrap_luapanda.sh
bash -n server/scripts/linux/debug_luapanda.sh

# Static guards for the optional debugger integration.
grep -q 'luapanda_debug.start("gateway")' server/service/navigation_gateway.lua
grep -q 'luapanda_debug.start("query")' server/service/navigation_query.lua
grep -q 'LUA_PANDA_ENABLE' server/lualib/debug/luapanda_debug.lua
grep -q '^## 31\. 第一课最终回顾、调试与验收' docs/Skynet_BattleNavigation第一课_从Unity地图到Skynet查询_实操.md
! grep -q '^## 32\.' docs/Skynet_BattleNavigation第一课_从Unity地图到Skynet查询_实操.md

if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git diff --check
    echo
    git diff --stat
fi

echo "UPDATE_APPLIED_OK"
echo "Next: cd server && BUILD_TYPE=Debug ./scripts/linux/lesson1_prepare.sh --reuse-map"
