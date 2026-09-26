#!/usr/bin/env bash
# 职责：验证仓库已发布的 Lesson 1 共享资产，并完成 Server 构建与最终验收。
# 边界：Lesson orchestration；读取 shared/，复用 run_server.sh，不访问 Unity 工作目录。
# 输入/输出：Git 更新得到的 BMAP、manifest、协议生成物和 Server 源码 -> 构建、测试与 doctor 证据。
# 生命周期：每次切换课程提交或准备首次运行时执行；脚本本身短生命周期。
# 不负责：不触发 Unity Bake、不跨机器复制文件、不启动长驻 Server、不绕过 BMapReader 校验。
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SERVER_ROOT/.." && pwd)"
RUN_CTL="$SCRIPT_DIR/run_server.sh"
SHARED_MAP_DIR="$REPO_ROOT/shared/navigation/battle_1001"
BMAP_FILE="$SHARED_MAP_DIR/battle_1001.bmap"
MANIFEST_FILE="$SHARED_MAP_DIR/battle_1001.manifest.json"
REBUILD=0
EXPECTED_MAP_ID=1001
EXPECTED_MAP_VERSION=1
EXPECTED_CELL_SIZE_MM=500

# 输出命令帮助；无参数、无副作用，始终成功。
usage() {
    cat <<'USAGE'
Usage:
  BUILD_TYPE=Debug ./scripts/linux/lesson1_prepare.sh [--rebuild]

Options:
  --rebuild  调用 run_server.sh rebuild；默认调用 build 做增量构建与测试。

Prerequisite:
  先通过 Git 拉取包含 shared/navigation 与 shared/protocol 的同一课程提交。
USAGE
}

# 输出带统一前缀的验收信息。
log() { printf '[lesson1-prepare] %s\n' "$*"; }

# 输出明确错误并以非零状态结束。
fail() { printf '[lesson1-prepare] ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
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

# 构建会更新当前工作区的 Native 产物；运行中的进程可能仍映射旧产物，因此先明确停止。
status_output="$($RUN_CTL status 2>&1 || true)"
if grep -q "RUNNING pid=" <<<"$status_output"; then
    printf '%s\n' "$status_output" >&2
    fail "stop the running Server before Lesson 1 prepare/build"
fi

# 验证发布清单中的业务身份，避免仅凭文件名加载错误地图版本。
validate_published_map() {
    [[ -s "$BMAP_FILE" ]] || fail "published BMAP missing: $BMAP_FILE"
    [[ -s "$MANIFEST_FILE" ]] || fail "published manifest missing: $MANIFEST_FILE"
    command -v python3 >/dev/null 2>&1 || fail "python3 is required to validate manifest"

    python3 - "$MANIFEST_FILE" "$EXPECTED_MAP_ID" "$EXPECTED_MAP_VERSION" "$EXPECTED_CELL_SIZE_MM" <<'PY'
import json
import sys

path = sys.argv[1]
expected = {
    "map_id": int(sys.argv[2]),
    "map_version": int(sys.argv[3]),
    "cell_size_mm": int(sys.argv[4]),
}
with open(path, "r", encoding="utf-8-sig") as stream:
    manifest = json.load(stream)
for key, expected_value in expected.items():
    actual_value = manifest.get(key)
    if actual_value != expected_value:
        raise SystemExit(
            f"MANIFEST_MISMATCH {key}: expected={expected_value} actual={actual_value}"
        )
print(
    "SHARED_NAVIGATION_OK "
    f"map={manifest['map_id']} version={manifest['map_version']} "
    f"grid={manifest.get('width')}x{manifest.get('height')} "
    f"cell_mm={manifest['cell_size_mm']} payload_crc32={manifest.get('payload_crc32')}"
)
PY
}

validate_published_map

if ((REBUILD)); then
    "$RUN_CTL" rebuild
else
    "$RUN_CTL" build
fi

"$RUN_CTL" doctor

log "BMAP_SHA256 $(sha256sum "$BMAP_FILE" | awk '{print $1}')"
log "MANIFEST_SHA256 $(sha256sum "$MANIFEST_FILE" | awk '{print $1}')"
log "LESSON1_SERVER_PREPARE_OK"
