#!/usr/bin/env bash
# 职责：下载并准备课程固定版本的 Skynet 源码快照。
# 边界：Server Build Bootstrap；只写入 server/third_party/skynet，不编译、不启动进程。
# 输入/输出：Skynet 固定 tag -> 带 .pinned-tag 标记的源码目录。
# 生命周期：首次准备依赖时执行；目录存在且标记匹配时只做校验。
# 不负责：不保留 Git 历史、不升级系统工具、不修改 Unity 或 shared 发布资产。
set -euo pipefail

# 统一把当前脚本定位到 server 根目录，避免调用者从任意工作目录运行时路径漂移。
SERVER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_DIR="$SERVER_ROOT/third_party/skynet"
EXPECTED_TAG="v1.8.0"
# Skynet 的 Makefile 会直接构建这个子模块；源码快照必须同时包含它。
JEMALLOC_COMMIT="54eaed1d8b56b1aa528be3bdd1877e59c56fa90c"

# 输出 bootstrap 进度；stdout 可被 CI 收集为构建证据。
log() { printf '[skynet-bootstrap] %s\n' "$*"; }

# 输出可操作错误并终止；不删除已有的非托管目录，避免覆盖用户源码。
fail() { printf '[skynet-bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }

# 下载并解压一个固定 tag。codeload 只提供源码快照，不包含 Git 历史或远程配置。
download_snapshot() {
    local archive jemalloc_archive temp_dir
    archive="$(mktemp --suffix=.tar.gz)"
    jemalloc_archive="$(mktemp --suffix=.tar.gz)"
    temp_dir="$(mktemp -d)"
    # 无论 curl、tar 还是移动失败，临时文件都不应留在系统临时目录。
    trap 'rm -f "$archive" "$jemalloc_archive"; rm -rf "$temp_dir"' RETURN

    log "downloading Skynet tag=$EXPECTED_TAG"
    # -f：HTTP 错误返回失败；-L：跟随 GitHub 重定向；retry：临时网络错误自动重试。
    curl -fL --retry 4 --retry-delay 2 \
        -o "$archive" \
        "https://codeload.github.com/cloudwu/skynet/tar.gz/refs/tags/$EXPECTED_TAG"
    # GitHub 压缩包外层目录名不稳定，去掉一层后把内容放入固定目标目录。
    tar -xzf "$archive" --strip-components=1 -C "$temp_dir"
    test -f "$temp_dir/Makefile" || fail "Skynet snapshot has no Makefile"

    # Skynet Git 仓库把 jemalloc 作为 submodule；GitHub 源码归档不会自动包含 gitlink 内容。
    # 因此同样用 curl 下载固定 commit 的 jemalloc 快照，保证 curl 方式仍能完整编译 Skynet。
    log "downloading jemalloc commit=$JEMALLOC_COMMIT"
    curl -fL --retry 4 --retry-delay 2 \
        -o "$jemalloc_archive" \
        "https://codeload.github.com/jemalloc/jemalloc/tar.gz/$JEMALLOC_COMMIT"
    mkdir -p "$temp_dir/3rd/jemalloc"
    tar -xzf "$jemalloc_archive" --strip-components=1 -C "$temp_dir/3rd/jemalloc"
    test -x "$temp_dir/3rd/jemalloc/autogen.sh" || fail "jemalloc snapshot is incomplete"
    printf '%s\n' "$EXPECTED_TAG" > "$temp_dir/.pinned-tag"

    # 只有完整快照通过基本检查后才移动到正式目录，避免半成品被后续构建使用。
    mkdir -p "$(dirname "$SOURCE_DIR")"
    mv "$temp_dir" "$SOURCE_DIR"
    trap - RETURN
    rm -f "$archive"
}

# 校验当前目录是否由本脚本准备，并且版本标记与课程锁定值一致。
verify_snapshot() {
    local actual_tag
    [[ -f "$SOURCE_DIR/.pinned-tag" ]] || fail "Skynet pin marker missing: $SOURCE_DIR/.pinned-tag"
    actual_tag="$(cat "$SOURCE_DIR/.pinned-tag")"
    [[ "$actual_tag" == "$EXPECTED_TAG" ]] || \
        fail "SKYNET_VERSION_MISMATCH expected=$EXPECTED_TAG actual=$actual_tag"
    [[ -f "$SOURCE_DIR/Makefile" ]] || fail "Skynet source incomplete: $SOURCE_DIR"
    log "SKYNET_SOURCE_OK tag=$actual_tag path=$SOURCE_DIR"
}

# 目录不存在时下载；存在时拒绝接管无标记目录，再统一执行版本校验。
if [[ ! -e "$SOURCE_DIR" ]]; then
    download_snapshot
elif [[ ! -f "$SOURCE_DIR/.pinned-tag" ]]; then
    fail "SKYNET_SOURCE_INVALID unmanaged directory: $SOURCE_DIR"
fi

verify_snapshot
