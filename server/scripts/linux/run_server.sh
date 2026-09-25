#!/usr/bin/env bash
# 职责：从仓库内固定配置以前台方式启动 Battle Navigation Skynet 进程。
# 边界：Server Runtime Launcher；不构建源码、不下载依赖、不生成地图资产。
# 输入/输出：已构建 Native/Skynet 和已发布 BMAP -> 当前终端中的 Server 进程。
# 生命周期：使用 exec 让 Skynet 接管当前进程和退出码。
# 不负责：不自动修复缺失依赖，不后台守护，不修改配置。

set -euo pipefail

SERVER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$SERVER_ROOT"

test -x third_party/skynet/skynet
test -f build/lua_battle_nav/battle_nav.so
test -f third_party/lua-protobuf-runtime/pb.so
test -f protocol/generated/server/navigation_query.pb
test -f maps/battle_1001.bmap

exec third_party/skynet/skynet config/skynet.lua
