#!/usr/bin/env bash
# 职责：第一课最终验收的一键 Server 准备入口。
# 边界：Lesson orchestration；复用 run_server.sh，不复制底层依赖/构建逻辑。
# 输入/输出：Unity BMAP 导出目录（可选）+ Server 源码 -> 已导入地图、构建产物、测试与 doctor 证据。
# 不负责：不启动长驻 Server、不修改 Unity Scene、不绕过 BMapReader 运行时校验。
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
RUN_CTL="$SCRIPT_DIR/run_server.sh"
UNITY_OUTPUT="${UNITY_NAV_OUTPUT:-}"
REBUILD=0
REUSE_MAP=0
EXPECTED_MAP_ID=1001
EXPECTED_MAP_VERSION=1
EXPECTED_CELL_SIZE_MM=500

usage() {
    cat <<'USAGE'
Usage:
  ./scripts/linux/lesson1_prepare.sh --unity-output <BuildArtifacts/Navigation> [--rebuild]
  UNITY_NAV_OUTPUT=<dir> ./scripts/linux/lesson1_prepare.sh [--rebuild]
  ./scripts/linux/lesson1_prepare.sh --reuse-map [--rebuild]

Options:
  --unity-output DIR  从 Unity Export 目录导入 battle_1001.bmap/.manifest.json。
  --reuse-map         不重新导入；使用 server/maps 中已经存在的 Battle_1001 资产。
  --rebuild           调用 run_server.sh rebuild；默认调用 build 做增量构建和测试。
USAGE
}

log() { printf '[lesson1-prepare] %s\n' "$*"; }
fail() { printf '[lesson1-prepare] ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --unity-output)
            [[ $# -ge 2 ]] || fail "--unity-output requires a directory"
            UNITY_OUTPUT="$2"
            shift 2
            ;;
        --reuse-map)
            REUSE_MAP=1
            shift
            ;;
        --rebuild)
            REBUILD=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            fail "unknown argument: $1"
            ;;
    esac
done

if ((REUSE_MAP)) && [[ -n "$UNITY_OUTPUT" ]]; then
    fail "--reuse-map and --unity-output cannot be used together"
fi

status_output="$($RUN_CTL status 2>&1 || true)"
if grep -q "RUNNING pid=" <<<"$status_output"; then
    printf '%s\n' "$status_output" >&2
    fail "stop the running Server before Lesson 1 prepare/build"
fi

import_map() (
    local src_bmap src_manifest maps_dir tmp_bmap tmp_manifest
    src_bmap="$UNITY_OUTPUT/battle_1001.bmap"
    src_manifest="$UNITY_OUTPUT/battle_1001.manifest.json"
    [[ -s "$src_bmap" ]] || fail "Unity BMAP missing: $src_bmap"
    [[ -s "$src_manifest" ]] || fail "Unity manifest missing: $src_manifest"
    command -v python3 >/dev/null 2>&1 || fail "python3 is required to validate manifest"

    python3 - "$src_manifest" "$EXPECTED_MAP_ID" "$EXPECTED_MAP_VERSION" "$EXPECTED_CELL_SIZE_MM" <<'PY'
import json, sys
path = sys.argv[1]
expected_id = int(sys.argv[2])
expected_version = int(sys.argv[3])
expected_cell = int(sys.argv[4])
with open(path, 'r', encoding='utf-8-sig') as f:
    m = json.load(f)
checks = {
    'map_id': expected_id,
    'map_version': expected_version,
    'cell_size_mm': expected_cell,
}
for key, expected in checks.items():
    actual = m.get(key)
    if actual != expected:
        raise SystemExit(f"MANIFEST_MISMATCH {key}: expected={expected} actual={actual}")
print(f"MANIFEST_OK map={m['map_id']} version={m['map_version']} grid={m.get('width')}x{m.get('height')} cell_mm={m['cell_size_mm']} payload_crc32={m.get('payload_crc32')}")
PY

    maps_dir="$SERVER_ROOT/maps"
    mkdir -p "$maps_dir"
    tmp_bmap="$maps_dir/.battle_1001.bmap.tmp.$$"
    tmp_manifest="$maps_dir/.battle_1001.manifest.json.tmp.$$"
    trap 'rm -f "$tmp_bmap" "$tmp_manifest"' EXIT

    install -m 0644 "$src_bmap" "$tmp_bmap"
    install -m 0644 "$src_manifest" "$tmp_manifest"
    mv -f "$tmp_bmap" "$maps_dir/battle_1001.bmap"
    mv -f "$tmp_manifest" "$maps_dir/battle_1001.manifest.json"
    log "MAP_IMPORTED source=$UNITY_OUTPUT"
)

if ((REUSE_MAP)); then
    [[ -s "$SERVER_ROOT/maps/battle_1001.bmap" ]] || fail "server map missing; cannot --reuse-map"
    [[ -s "$SERVER_ROOT/maps/battle_1001.manifest.json" ]] || fail "server manifest missing; cannot --reuse-map"
elif [[ -n "$UNITY_OUTPUT" ]]; then
    import_map
elif [[ -s "$SERVER_ROOT/maps/battle_1001.bmap" && -s "$SERVER_ROOT/maps/battle_1001.manifest.json" ]]; then
    log "UNITY_NAV_OUTPUT not supplied; reusing existing server/maps Battle_1001 assets"
else
    usage >&2
    fail "first run requires --unity-output DIR (or UNITY_NAV_OUTPUT)"
fi

if ((REBUILD)); then
    "$RUN_CTL" rebuild
else
    "$RUN_CTL" build
fi

"$RUN_CTL" doctor

log "BMAP_SHA256 $(sha256sum "$SERVER_ROOT/maps/battle_1001.bmap" | awk '{print $1}')"
log "MANIFEST_SHA256 $(sha256sum "$SERVER_ROOT/maps/battle_1001.manifest.json" | awk '{print $1}')"
log "LESSON1_SERVER_PREPARE_OK"
