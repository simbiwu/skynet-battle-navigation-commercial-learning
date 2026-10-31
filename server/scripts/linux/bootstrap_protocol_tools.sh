#!/usr/bin/env bash
# 第一行 shebang 告诉系统用 Bash 解释本文件；也可显式运行 bash 加脚本路径。
# 调用：可从任意当前工作目录启动；脚本按自身路径定位工程目录。外部相对路径参数按调用时目录解析，建议传绝对路径。
# 示例：bash /absolute/path/to/checkout/server/scripts/linux/bootstrap_protocol_tools.sh [按本文件头部说明填写参数]
# 职责：下载课程固定版本的 protoc 和 lua-protobuf 源码。
# 边界：Server Build Bootstrap；不编译模块，不生成业务 descriptor。
# 输入/输出：shared/protocol/VERSIONS.env -> third_party 下的固定版本工具源码/二进制。
# 失败约定：已有目录版本不符时明确失败，不删除或静默升级用户文件。
# 生命周期：Server 首次构建或切换课程依赖版本时执行；成功后由 build/descriptor 脚本消费。
# 不负责：不生成 Unity C#、不编译 pb.so、不启动 Server。
set -euo pipefail
# Bash 语法速读：只解释本脚本实际使用的 Bash 写法；流程注释说明每一步为什么执行。
#   set -euo pipefail：-e 遇到未处理的失败通常退出，但条件判断、&& 和 || 等位置有例外，关键失败仍应显式检查；-u 遇到未设置变量时报错（提供默认值展开时除外）；pipefail 让管道任一步失败都能向外报告。
#   双引号中的 "$NAME" 把变量值作为一个完整参数；路径含空格时不会拆成多个参数。
#   $(命令)运行命令并用标准输出替换当前位置；命令在子 Shell 中运行，里面的 cd 不改变主脚本目录。
#   [[ 条件 ]]执行 Bash 条件判断；-f检查普通文件，-x检查可执行文件，-e检查存在的路径。
#   >把输出写入并覆盖文件；2>&1把标准错误接到标准输出当前去向。
#   trap 登记退出或信号时执行的清理动作；单引号使变量在事件发生时再展开。
# -e：任意未处理的失败立即退出，避免错误结果继续传给下一阶段。
# -u：读取未定义变量时立即失败，尽早发现环境变量或变量名错误。
# pipefail：管道中任一命令失败都会让整条管道失败，避免只检查到最后一条命令。

# ROOT 固定为 Server 根目录，因此从任意当前工作目录调用时安装位置都一致。
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# REPO_ROOT 用于读取仓库根目录的共享协议版本清单。
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
# source：在当前 Shell 进程加载固定版本配置，使后续变量和校验使用同一份清单。
source "$REPO_ROOT/shared/protocol/VERSIONS.env"

# protoc 按版本隔离安装，避免不同课程版本共用或覆盖同一目录。
PROTOC_DIR="$ROOT/third_party/protoc-$PROTOC_VERSION"
# lua-protobuf 使用固定提交的源码快照目录，供后续构建脚本读取。
LUA_PROTOBUF_DIR="$ROOT/third_party/lua-protobuf"

# 这些工具分别负责联网下载、解压 protoc zip 和解压源码 tar.gz；缺少任一项时立即失败。
command -v curl >/dev/null
command -v python3 >/dev/null
command -v tar >/dev/null
# third_party 是本脚本管理的安装根目录；只创建目录，不清理已有用户内容。
mkdir -p "$ROOT/third_party"

if [[ ! -x "$PROTOC_DIR/bin/protoc" ]]; then
    if [[ -e "$PROTOC_DIR" ]]; then
        echo "PROTOC_DIR_INVALID path=$PROTOC_DIR" >&2
        exit 1
    fi
    # 将下载放到系统临时目录，避免下载中断留下不完整归档污染 third_party。
    archive="$(mktemp --suffix=.zip)"
    # 本阶段下载或解压失败时清理 protoc 归档；set -e 会触发退出清理。
    trap 'rm -f "$archive"' EXIT
    # URL 中的版本来自共享清单；curl 失败时退出，最多重试 4 次、每次间隔 2 秒。
    curl -fL --retry 4 --retry-delay 2 \
        -o "$archive" \
        "https://github.com/protocolbuffers/protobuf/releases/download/v$PROTOC_VERSION/protoc-$PROTOC_VERSION-linux-x86_64.zip"
    # 目标不存在时才创建版本目录；上面的检查禁止覆盖已有但不完整的目录。
    mkdir -p "$PROTOC_DIR"
    # 使用 Python 标准库解压 zip，减少对系统 unzip 工具及其选项的依赖。
    python3 -m zipfile -e "$archive" "$PROTOC_DIR"
    # 确保归档解出的 protoc 可执行，后续直接调用它核对真实版本。
    chmod +x "$PROTOC_DIR/bin/protoc"
fi

# 读取已安装二进制报告的版本，不能只凭目录名认定工具版本正确。
actual_protoc="$($PROTOC_DIR/bin/protoc --version)"
if [[ "$actual_protoc" != "libprotoc $PROTOC_VERSION" ]]; then
    echo "PROTOC_VERSION_MISMATCH expected=$PROTOC_VERSION actual=$actual_protoc" >&2
    exit 1
fi

# 标记文件记录源码快照对应的 Git 提交；没有标记时只允许安装到全新目录。
if [[ ! -f "$LUA_PROTOBUF_DIR/.pinned-commit" ]]; then
    if [[ -e "$LUA_PROTOBUF_DIR" ]]; then
        echo "LUA_PROTOBUF_DIR_INVALID path=$LUA_PROTOBUF_DIR" >&2
        exit 1
    fi
    # 只消费 lua-protobuf 源码，因此下载固定提交的快照，不保留 Git 元数据。
    # archive 保存下载压缩包；temp_dir 暂存解压结果，验证前不暴露为最终目录。
    archive="$(mktemp --suffix=.tar.gz)"
    temp_dir="$(mktemp -d)"
    # 退出时清理该阶段的压缩包与未安装的暂存目录。
    trap 'rm -f "$archive"; rm -rf "$temp_dir"' EXIT
    curl -fL --retry 4 --retry-delay 2 \
        -o "$archive" \
        "https://codeload.github.com/starwing/lua-protobuf/tar.gz/$LUA_PROTOBUF_COMMIT"
    # 解压时去掉 GitHub 压缩包的一层仓库目录，使源码直接位于暂存根目录。
    tar -xzf "$archive" --strip-components=1 -C "$temp_dir"
    # 记录源码来源提交，后续运行据此拒绝使用不同版本的缓存目录。
    printf '%s\n' "$LUA_PROTOBUF_COMMIT" > "$temp_dir/.pinned-commit"
    # 解压和标记完成后再移入目标路径，避免留下可被误用的半成品目录。
    mv "$temp_dir" "$LUA_PROTOBUF_DIR"
fi

# 读取安装标记并与共享清单比较，发现版本漂移时明确失败。
actual_commit="$(cat "$LUA_PROTOBUF_DIR/.pinned-commit")"
if [[ "$actual_commit" != "$LUA_PROTOBUF_COMMIT" ]]; then
    echo "LUA_PROTOBUF_VERSION_MISMATCH expected=$LUA_PROTOBUF_COMMIT actual=$actual_commit" >&2
    exit 1
fi

echo "PROTOC_SOURCE_OK version=$PROTOC_VERSION path=$PROTOC_DIR"
echo "LUA_PROTOBUF_SOURCE_OK commit=$actual_commit path=$LUA_PROTOBUF_DIR"
