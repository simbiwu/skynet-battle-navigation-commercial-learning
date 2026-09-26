#!/usr/bin/env bash
# 职责：下载课程固定版本的 protoc 和 lua-protobuf 源码。
# 边界：Server Build Bootstrap；不编译模块，不生成业务 descriptor。
# 输入/输出：shared/protocol/VERSIONS.env -> third_party 下的固定版本工具源码/二进制。
# 失败约定：已有目录版本不符时明确失败，不删除或静默升级用户文件。
# 生命周期：Server 首次构建或切换课程依赖版本时执行；成功后由 build/descriptor 脚本消费。
# 不负责：不生成 Unity C#、不编译 pb.so、不启动 Server。
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
source "$REPO_ROOT/shared/protocol/VERSIONS.env"

PROTOC_DIR="$ROOT/third_party/protoc-$PROTOC_VERSION"
LUA_PROTOBUF_DIR="$ROOT/third_party/lua-protobuf"

# curl 只负责下载；python3 解压 protoc zip，tar 解压 lua-protobuf 源码快照。
command -v curl >/dev/null
command -v python3 >/dev/null
command -v tar >/dev/null
mkdir -p "$ROOT/third_party"

if [[ ! -x "$PROTOC_DIR/bin/protoc" ]]; then
    if [[ -e "$PROTOC_DIR" ]]; then
        echo "PROTOC_DIR_INVALID path=$PROTOC_DIR" >&2
        exit 1
    fi
    # 临时归档文件避免半下载内容出现在 third_party；失败由 set -e 传播。
    archive="$(mktemp --suffix=.zip)"
    trap 'rm -f "$archive"' EXIT
    # protoc 是固定版本二进制包，URL 中的版本来自 shared/protocol/VERSIONS.env。
    curl -fL --retry 4 --retry-delay 2 \
        -o "$archive" \
        "https://github.com/protocolbuffers/protobuf/releases/download/v$PROTOC_VERSION/protoc-$PROTOC_VERSION-linux-x86_64.zip"
    mkdir -p "$PROTOC_DIR"
    # zipfile 由 Python 标准库解压，避免依赖系统 unzip 的行为差异。
    python3 -m zipfile -e "$archive" "$PROTOC_DIR"
    chmod +x "$PROTOC_DIR/bin/protoc"
fi

# 版本检查必须调用刚准备的二进制，不能只相信目录名。
actual_protoc="$($PROTOC_DIR/bin/protoc --version)"
if [[ "$actual_protoc" != "libprotoc $PROTOC_VERSION" ]]; then
    echo "PROTOC_VERSION_MISMATCH expected=$PROTOC_VERSION actual=$actual_protoc" >&2
    exit 1
fi

if [[ ! -f "$LUA_PROTOBUF_DIR/.pinned-commit" ]]; then
    if [[ -e "$LUA_PROTOBUF_DIR" ]]; then
        echo "LUA_PROTOBUF_DIR_INVALID path=$LUA_PROTOBUF_DIR" >&2
        exit 1
    fi
    # lua-protobuf 只需要源码快照，所以使用 codeload tar.gz，不保留 Git 元数据。
    archive="$(mktemp --suffix=.tar.gz)"
    temp_dir="$(mktemp -d)"
    trap 'rm -f "$archive"; rm -rf "$temp_dir"' EXIT
    curl -fL --retry 4 --retry-delay 2 \
        -o "$archive" \
        "https://codeload.github.com/starwing/lua-protobuf/tar.gz/$LUA_PROTOBUF_COMMIT"
    # GitHub 压缩包包含一层仓库目录；去掉这一层后目录结构与构建脚本约定一致。
    tar -xzf "$archive" --strip-components=1 -C "$temp_dir"
    printf '%s\n' "$LUA_PROTOBUF_COMMIT" > "$temp_dir/.pinned-commit"
    mv "$temp_dir" "$LUA_PROTOBUF_DIR"
fi

actual_commit="$(cat "$LUA_PROTOBUF_DIR/.pinned-commit")"
if [[ "$actual_commit" != "$LUA_PROTOBUF_COMMIT" ]]; then
    echo "LUA_PROTOBUF_VERSION_MISMATCH expected=$LUA_PROTOBUF_COMMIT actual=$actual_commit" >&2
    exit 1
fi

echo "PROTOC_SOURCE_OK version=$PROTOC_VERSION path=$PROTOC_DIR"
echo "LUA_PROTOBUF_SOURCE_OK commit=$actual_commit path=$LUA_PROTOBUF_DIR"
