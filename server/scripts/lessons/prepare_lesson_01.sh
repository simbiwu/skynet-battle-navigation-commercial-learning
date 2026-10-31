#!/usr/bin/env bash
# 第一行 shebang 告诉系统用 Bash 解释本文件；也可显式运行 bash 加脚本路径。
# 调用：可从任意当前工作目录启动；脚本按自身路径定位工程目录。外部相对路径参数按调用时目录解析，建议传绝对路径。
# 示例：bash /absolute/path/to/checkout/server/scripts/lessons/prepare_lesson_01.sh [按本文件头部说明填写参数]
# 职责：验证仓库已发布的 Lesson 1 共享资产，并完成 Server 构建与最终验收。
# 边界：Lesson orchestration；读取 shared/，复用 run_server.sh，不访问 Unity 工作目录。
# 输入/输出：Git 更新得到的 BMAP、manifest、协议生成物和 Server 源码 -> 构建、测试与 doctor 证据。
# 生命周期：每次切换课程提交或准备首次运行时执行；脚本本身短生命周期。
# 不负责：不触发 Unity Bake、不跨机器复制文件、不启动长驻 Server、不绕过 BMapReader 校验。
set -euo pipefail
# Bash 语法速读：只解释本脚本实际使用的 Bash 写法；流程注释说明每一步为什么执行。
#   set -euo pipefail：-e 遇到未处理的失败通常退出，但条件判断、&& 和 || 等位置有例外，关键失败仍应显式检查；-u 遇到未设置变量时报错（提供默认值展开时除外）；pipefail 让管道任一步失败都能向外报告。
#   双引号中的 "$NAME" 把变量值作为一个完整参数；路径含空格时不会拆成多个参数。
#   $(命令)运行命令并用标准输出替换当前位置；命令在子 Shell 中运行，里面的 cd 不改变主脚本目录。
#   $#表示参数个数，$1/$2依次表示传入的第一个/第二个参数。
#   shift 丢弃第一个位置参数，其余参数向前移动一位。
#   [[ 条件 ]]执行 Bash 条件判断；-s检查非空文件。
#   case ... in 按输入匹配分支；分支以 ) 开始、;;结束，*)是兜底分支。
#   name() { ...; }定义函数；调用函数名即可执行函数体。
#   for/while ... do ... done 重复执行循环体；列表或条件决定循环何时结束。
#   单竖线 | 把左侧标准输出交给右侧；它不同于条件运算符 ||。
#   >把输出写入并覆盖文件；2>&1把标准错误接到标准输出当前去向。
#   <<'名称'开启 here-document；下一行到独占名称行之间的文字会作为命令输入。
# -e：任意未处理的失败立即退出，避免错误结果继续传给下一阶段。
# -u：读取未定义变量时立即失败，尽早发现环境变量或变量名错误。
# pipefail：管道中任一命令失败都会让整条管道失败，避免只检查到最后一条命令。

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SERVER_ROOT/.." && pwd)"
RUN_CTL="$SCRIPT_DIR/lesson1_run_server.sh"
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
  BUILD_TYPE=Debug bash /path/to/server/scripts/lessons/prepare_lesson_01.sh [--rebuild]

Options:
  --rebuild  调用 Lesson 1 专属入口 rebuild；默认调用 build 做增量构建。

Prerequisite:
  先通过 Git 拉取包含 shared/navigation 与 shared/protocol 的同一课程提交。
USAGE
}

# 输出带统一前缀的验收信息。
log() { printf '[lesson1-prepare] %s\n' "$*"; }

# 输出明确错误并以非零状态结束。
fail() { printf '[lesson1-prepare] ERROR: %s\n' "$*" >&2; exit 1; }

# 参数只决定校验目标和是否重建；脚本不会把 Lesson 资产复制到 Server 运行目录。
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
    fail "先停止 Lesson 1 Server，再执行 prepare/build"
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

# 第一课只生成第一课 descriptor 与 Registry；不触碰其它课程协议。
bash "$SERVER_ROOT/protocol/build_protocol_lesson_01.sh"

if ((REBUILD)); then
    "$SERVER_ROOT/scripts/linux/build_server.sh" rebuild
else
    # 复用唯一构建入口，保证 Lesson 看到的协议、Native 和 descriptor 与真实 Server 一致。
    "$SERVER_ROOT/scripts/linux/build_server.sh" build
fi

"$RUN_CTL" doctor

log "BMAP_SHA256 $(sha256sum "$BMAP_FILE" | awk '{print $1}')"
log "MANIFEST_SHA256 $(sha256sum "$MANIFEST_FILE" | awk '{print $1}')"
log "LESSON1_SERVER_PREPARE_OK"
