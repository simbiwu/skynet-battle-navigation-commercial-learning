#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

source_dir="third_party/skynet"
expected_tag="v1.8.0"

mkdir -p third_party

if [[ ! -d "$source_dir/.git" ]]; then
    if [[ -e "$source_dir" ]]; then
        echo "SKYNET_SOURCE_INVALID path=$source_dir" >&2
        exit 1
    fi

    git clone \
        --branch "$expected_tag" \
        --depth 1 \
        https://github.com/cloudwu/skynet.git \
        "$source_dir"
fi

actual_tag="$(git -C "$source_dir" describe --tags --exact-match HEAD 2>/dev/null || true)"
if [[ "$actual_tag" != "$expected_tag" ]]; then
    echo "SKYNET_VERSION_MISMATCH expected=$expected_tag actual=$actual_tag" >&2
    exit 1
fi

echo "SKYNET_SOURCE_OK tag=$actual_tag commit=$(git -C "$source_dir" rev-parse HEAD)"