#!/usr/bin/env bash
# 职责：以独立构建目录编译并运行 grid_map_core 的第一课单元测试。
# 边界：Server Native Build/Test；不下载依赖，不构建 Skynet 或 Lua Binding。
# 输入/输出：native/grid_map 源码 -> build/grid_map 下的构建产物和 CTest 结果。
# 运行时机：修改 BMAP 读取、坐标换算、查询或 MapRegistry 后执行。
# 不负责：不生成 BMAP，不启动 Skynet，不修改源码或测试数据。

set -euo pipefail

# 从脚本自身位置推导工程根目录，避免依赖调用者当前目录和工程目录名。
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$SERVER_ROOT/build/grid_map"

cmake -S "$SCRIPT_DIR" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Debug
cmake --build "$BUILD_DIR" -j"$(nproc)"
ctest --test-dir "$BUILD_DIR" --output-on-failure
