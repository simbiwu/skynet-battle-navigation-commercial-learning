#!/usr/bin/env bash
# 职责：配置并编译 Skynet 可加载的 battle_nav Native 模块。
# 边界：Server Native Build；复用仓库内 Skynet Lua 头文件和 grid_map_core。
# 输入/输出：当前目录 C++ 源码 -> server/build/lua_battle_nav/battle_nav.so。
# 生命周期：开发者修改 Lua Binding 或导航 Native 后手动运行；构建产物由本地工作区持有。
# 不负责：不下载依赖、不运行单元测试、不启动 Skynet、不加载 BMAP。

set -euo pipefail
# -e：配置或编译失败时立即停止，不让旧产物被误认为本次构建成功。
# -u：未定义变量立即报错；pipefail：管道任一环节失败都向上传播。

# 从脚本位置推导源码与产物目录，允许从任意当前目录调用本脚本。
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$SERVER_ROOT/build/lua_battle_nav"
BUILD_TYPE="${BUILD_TYPE:-RelWithDebInfo}"
case "$BUILD_TYPE" in
    RelWithDebInfo|Debug|Release) ;;
    *)
        printf "[battle-nav-build] unsupported BUILD_TYPE: %s\n" "$BUILD_TYPE" >&2
        exit 2
        ;;
esac

# CMake 将依赖图和 Skynet Lua ABI 检查集中在 CMakeLists.txt；此入口只负责重复执行配置与构建。
cmake -S "$SCRIPT_DIR" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE="$BUILD_TYPE"
cmake --build "$BUILD_DIR" -j"$(nproc)"

# 确认本次构建应提供的固定模块路径，避免后续 Smoke 静默加载不到 Native 模块。
if [[ ! -s "$BUILD_DIR/battle_nav.so" ]]; then
    printf "[battle-nav-build] expected module was not generated: %s\n" "$BUILD_DIR/battle_nav.so" >&2
    exit 1
fi

printf "[battle-nav-build] ready: %s\n" "$BUILD_DIR/battle_nav.so"
