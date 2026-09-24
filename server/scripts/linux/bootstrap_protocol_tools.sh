#!/usr/bin/env bash
# 职责：下载课程固定版本的 protoc 和 lua-protobuf 源码。
# 边界：Server Build Bootstrap；不编译模块，不生成业务 descriptor。
# 输入/输出：protocol/VERSIONS.env -> third_party 下的固定版本工具源码/二进制。
# 失败约定：已有目录版本不符时明确失败，不删除或静默升级用户文件。
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/protocol/VERSIONS.env"

PROTOC_DIR="$ROOT/third_party/protoc-$PROTOC_VERSION"
LUA_PROTOBUF_DIR="$ROOT/third_party/lua-protobuf"

command -v curl >/dev/null
command -v python3 >/dev/null
command -v tar >/dev/null
mkdir -p "$ROOT/third_party"

if [[ ! -x "$PROTOC_DIR/bin/protoc" ]]; then
    if [[ -e "$PROTOC_DIR" ]]; then
        echo "PROTOC_DIR_INVALID path=$PROTOC_DIR" >&2
        exit 1
    fi
    archive="$(mktemp --suffix=.zip)"
    trap 'rm -f "$archive"' EXIT
    curl -fL --retry 4 --retry-delay 2 \
        -o "$archive" \
        "https://github.com/protocolbuffers/protobuf/releases/download/v$PROTOC_VERSION/protoc-$PROTOC_VERSION-linux-x86_64.zip"
    mkdir -p "$PROTOC_DIR"
    python3 -m zipfile -e "$archive" "$PROTOC_DIR"
    chmod +x "$PROTOC_DIR/bin/protoc"
fi

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
    archive="$(mktemp --suffix=.tar.gz)"
    temp_dir="$(mktemp -d)"
    trap 'rm -f "$archive"; rm -rf "$temp_dir"' EXIT
    curl -fL --retry 4 --retry-delay 2 \
        -o "$archive" \
        "https://codeload.github.com/starwing/lua-protobuf/tar.gz/$LUA_PROTOBUF_COMMIT"
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
