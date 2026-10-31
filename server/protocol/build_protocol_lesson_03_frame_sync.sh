#!/usr/bin/env bash
# 第一行 shebang 告诉系统用 Bash 解释本文件；也可显式运行 bash 加脚本路径。
# 调用：可从任意当前工作目录启动；脚本按自身路径定位工程目录。外部相对路径参数按调用时目录解析，建议传绝对路径。
# 示例：bash /absolute/path/to/checkout/server/protocol/build_protocol_lesson_03_frame_sync.sh [按本文件头部说明填写参数]
# 职责：只构建 lesson_03_frame_sync 的 Server 协议文件和 Gateway Registry。
# 边界：离线构建入口；不启动 Skynet，不构建 Native，不生成 Unity C#。
# 输入：wire_header.proto、本课程唯一业务 schema、VERSIONS.env 锁定的 protoc、
#       FlyWow gateway/tools/generate_gateway_registry.py。
# 输出：generated/server/lesson_03_frame_sync.pb 与 SHA-256 sidecar、
#       server/lualib/gateway/protocol/protocol_registry_lesson_03_frame_sync.lua。
# 调用示例：bash /path/to/repo/server/protocol/build_protocol_lesson_03_frame_sync.sh；脚本路径使用绝对路径时可从任意目录启动。
# 生命周期：修改本课程协议后显式执行；运行时只读取生成物，run_server 不生成协议。
# 失败语义：任一依赖、版本或生成步骤失败立即非零退出；先删本目标旧文件，
#       防止本轮失败后把陈旧 descriptor/registry 当作成功结果。
# 维护说明：路径只由脚本位置推导；目录布局变化时只需调整下方目录常量。
set -euo pipefail
# Bash 语法速读：只解释本脚本实际使用的 Bash 写法；流程注释说明每一步为什么执行。
#   set -euo pipefail：-e 遇到未处理的失败通常退出，但条件判断、&& 和 || 等位置有例外，关键失败仍应显式检查；-u 遇到未设置变量时报错（提供默认值展开时除外）；pipefail 让管道任一步失败都能向外报告。
#   双引号中的 "$NAME" 把变量值作为一个完整参数；路径含空格时不会拆成多个参数。
#   $(命令)运行命令并用标准输出替换当前位置；命令在子 Shell 中运行，里面的 cd 不改变主脚本目录。
#   NAME:-默认值展开：变量未设置或为空字符串时使用默认值。
#   [[ 条件 ]]执行 Bash 条件判断；-f检查普通文件，-x检查可执行文件，-s检查非空文件。
#   单竖线 | 把左侧标准输出交给右侧；它不同于条件运算符 ||。
#   >把输出写入并覆盖文件；2>&1把标准错误接到标准输出当前去向。
# -e：命令失败即停止；-u：未设置变量即报错；pipefail：管道任一阶段失败都传递退出码。

# 通过脚本位置求仓库根目录，使从仓库根、server/ 或其它 cwd 调用结果相同。
SERVER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd -- "$SERVER_ROOT/.." && pwd)"
PROTO_ROOT="$REPO_ROOT/shared/protocol"
HEADER="$PROTO_ROOT/wire_header.proto"
SCHEMA="$PROTO_ROOT/lesson_03/frame_sync.proto"
OUTPUT_DIR="$PROTO_ROOT/generated/server"
DESCRIPTOR="$OUTPUT_DIR/lesson_03_frame_sync.pb"
REGISTRY="$SERVER_ROOT/lualib/gateway/protocol/protocol_registry_lesson_03_frame_sync.lua"

# protoc 固定版本从版本清单读取；PROTOC 可替换安装路径，但不能绕过版本核对。
source "$PROTO_ROOT/VERSIONS.env"
# ${变量:-默认值} 在变量未设置或为空时取默认值；临时传 PROTOC=/opt/protoc 会改用该程序，否则使用锁定版本路径。
PROTOC="${PROTOC:-$SERVER_ROOT/third_party/protoc-$PROTOC_VERSION/bin/protoc}"
EXPECTED_PROTOC="libprotoc $PROTOC_VERSION"
# 例如本次命令前写 PYTHON=python3.12 时使用该解释器；未设置或为空时回退到 python3。
PYTHON="${PYTHON:-python3}"
GENERATOR="$SERVER_ROOT/third_party/skynet-flywow/gateway/tools/generate_gateway_registry.py"

# 在修改旧产物前验证所有输入存在，避免路径错误导致部分清理。
test -x "$PROTOC" || { echo "protoc 不存在或不可执行：$PROTOC" >&2; exit 1; }
test -s "$HEADER" || { echo "共享 Envelope schema 缺失：$HEADER" >&2; exit 1; }
test -s "$SCHEMA" || { echo "本课程业务 schema 缺失：$SCHEMA" >&2; exit 1; }
test -s "$GENERATOR" || { echo "FlyWow registry 生成器缺失：$GENERATOR" >&2; exit 1; }
command -v "$PYTHON" >/dev/null || { echo "Python 不可用：$PYTHON" >&2; exit 1; }
ACTUAL_PROTOC="$("$PROTOC" --version)"
[[ "$ACTUAL_PROTOC" == "$EXPECTED_PROTOC" ]] || {
    echo "protoc 版本不匹配：期望 $EXPECTED_PROTOC，实际 $ACTUAL_PROTOC" >&2
    exit 1
}

# 为 descriptor 与 registry 建立目标目录。删除范围严格限定为当前课程的四个生成物。
mkdir -p "$OUTPUT_DIR" "$(dirname "$REGISTRY")"
rm -f "$DESCRIPTOR" "$DESCRIPTOR.sha256" "$OUTPUT_DIR/lesson_03_frame_sync.source.sha256" "$REGISTRY"

# --include_imports 将共享 Envelope 类型包含进课程自己的 FileDescriptorSet；
# 每个课程生成独立文件，因此运行时不需要加载其它课程的任何类型。
"$PROTOC" --descriptor_set_out="$DESCRIPTOR" --include_imports \
    -I "$PROTO_ROOT" "$HEADER" "$SCHEMA"
test -s "$DESCRIPTOR"

# 二进制 hash 校验发布 descriptor；source hash 稳定聚合本课程的两个源文件。
(cd "$OUTPUT_DIR" && sha256sum "lesson_03_frame_sync.pb" > "lesson_03_frame_sync.pb.sha256")
source_hash="$(cd "$PROTO_ROOT" && sha256sum wire_header.proto "lesson_03/frame_sync.proto" | sha256sum | awk '{print $1}')"
printf '%s\n' "$source_hash" > "$OUTPUT_DIR/lesson_03_frame_sync.source.sha256"

# Registry 只解析本课程 CommandId 和消息；Envelope 的全名显式指向共用信封。
# 生成工作属于协议构建入口，不属于 Server 启动器或课程运行时。
"$PYTHON" "$GENERATOR" --proto "$SCHEMA" \
    --envelope-type ".battle.transport.v1.Envelope" \
    --output "$REGISTRY"
test -s "$REGISTRY"
printf 'PROTOCOL_BUILD_OK course=lesson_03_frame_sync descriptor=%s registry=%s\n' "$DESCRIPTOR" "$REGISTRY"
