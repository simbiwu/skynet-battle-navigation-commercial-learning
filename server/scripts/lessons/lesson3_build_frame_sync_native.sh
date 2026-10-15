#!/usr/bin/env bash
# 职责：配置并构建帧同步宿主的 Native Core、Lua Binding 与原生测试程序。
# 调用：cd server 后执行 ./scripts/lessons/lesson3_build_frame_sync_native.sh；也可从任意目录调用绝对路径。
# 常规构建不需要设置环境变量；下面列出的变量都是可选覆盖项，不是脚本位置参数。
# 临时覆盖示例：FRAME_SYNC_BUILD_TYPE=Debug ./scripts/lessons/lesson3_build_frame_sync_native.sh
# 该写法只向这次脚本调用传值；也可先 export FRAME_SYNC_BUILD_TYPE=Debug 再运行脚本。
# 环境变量：
#   FRAME_SYNC_CMAKE：CMake 可执行文件，默认 cmake。
#   FRAME_SYNC_SOURCE_DIR：CMake -S 源码目录，默认 native/frame_sync。
#   FRAME_SYNC_BUILD_DIR：CMake -B 构建目录，默认 build/frame_sync。
#   FRAME_SYNC_BUILD_TYPE：-DCMAKE_BUILD_TYPE 值，默认 Release。
#   FRAME_SYNC_LUA：-DLESSON_FRAME_LUA 值，只接受 ON/OFF，默认 ON。
#   FRAME_SYNC_BUILD_JOBS：--parallel 并行任务数，只接受正整数，默认 4。
#   两个目录变量为相对路径时，均相对 server/ 根目录解析。
# 输入/输出：frame_sync CMakeLists 与 FlyWow/Skynet 源码 -> build/frame_sync 下的 Native 产物。
# 副作用：创建或更新构建目录；不运行 CTest，也不启动 Skynet。
# 不负责：不替代 run_server.sh build 的 Skynet、协议和 FlyWow 构建准备。

# -e：任一命令失败就停止，避免配置或编译失败后仍继续报告成功。
# -u：读取未设置的变量时立即失败，帮助发现变量名拼写错误。
# pipefail：如果后续命令使用管道，管道中任一命令失败都会使整条管道失败。
set -euo pipefail

# 由脚本自身的位置定位目录，不依赖调用者当前所在目录。
# SCRIPT_DIR 是 server/scripts/lessons；向上两级得到 server/ 根目录。
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
SERVER_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

# 调用者可通过 FRAME_SYNC_* 环境变量覆盖默认值；${NAME:-default} 表示变量未设置或为空时采用 default。
# 左侧变量是脚本内部使用的名称；下面取出的值会在末尾转换成 CMake 参数。
# FRAME_SYNC_CMAKE 选择 CMake 可执行文件，默认从 PATH 中查找 cmake。
CMAKE_BIN="${FRAME_SYNC_CMAKE:-cmake}"
# 这两个目录值分别传给 CMake 的 -S（源码目录）和 -B（构建目录）；相对路径以 server/ 为基准。
SOURCE_DIR="${FRAME_SYNC_SOURCE_DIR:-native/frame_sync}"
BUILD_DIR="${FRAME_SYNC_BUILD_DIR:-build/frame_sync}"
# 构建类型传给 -DCMAKE_BUILD_TYPE；默认 Release。
BUILD_TYPE="${FRAME_SYNC_BUILD_TYPE:-Release}"
# Lua Binding 默认启用，传给 CMake 选项 LESSON_FRAME_LUA；设为 OFF 可关闭。
LUA_ENABLED="${FRAME_SYNC_LUA:-ON}"
# 并行编译数传给 --parallel；默认同时编译 4 个任务。
BUILD_JOBS="${FRAME_SYNC_BUILD_JOBS:-4}"

# 所有脚本主动发现的输入错误都通过这里报告到标准错误，并以失败码 1 退出。
fail() {
    printf '[frame-sync-build] ERROR: %s\n' "$*" >&2
    exit 1
}

# 在配置和编译前确认 CMake 可执行；既支持 PATH 中的命令名，也支持可执行文件路径。
command -v "$CMAKE_BIN" >/dev/null 2>&1 ||
    fail "找不到 CMake 可执行文件：$CMAKE_BIN"

# 将 Lua 开关限制为 CMake 通常使用的 ON/OFF，避免把其它拼写传入配置。
case "$LUA_ENABLED" in
    ON|OFF) ;;
    *) fail "FRAME_SYNC_LUA 只能是 ON 或 OFF：$LUA_ENABLED" ;;
esac

# --parallel 需要正整数；提前拒绝 0、负数和非数字值。
[[ "$BUILD_JOBS" =~ ^[1-9][0-9]*$ ]] ||
    fail "FRAME_SYNC_BUILD_JOBS 必须是正整数：$BUILD_JOBS"

# 后续源码目录、构建目录若写成相对路径，都从 server/ 根目录解释。
cd "$SERVER_ROOT"
# 提前检查源码入口，避免 CMake 配置时才因路径错误失败。
[[ -f "$SOURCE_DIR/CMakeLists.txt" ]] ||
    fail "找不到 CMakeLists.txt：$SOURCE_DIR/CMakeLists.txt"

# 显示本次最终采用的参数，便于确认默认值或环境变量覆盖是否生效。
printf '[frame-sync-build] source=%s build=%s type=%s lua=%s jobs=%s\n' \
    "$SOURCE_DIR" "$BUILD_DIR" "$BUILD_TYPE" "$LUA_ENABLED" "$BUILD_JOBS"

# 配置阶段：-S 指向 CMake 源码目录，-B 指向生成构建文件的目录。
# -D 将脚本变量传入 CMake：构建类型对应 CMAKE_BUILD_TYPE，Lua 开关对应 LESSON_FRAME_LUA。
"$CMAKE_BIN" -S "$SOURCE_DIR" -B "$BUILD_DIR" \
    "-DCMAKE_BUILD_TYPE=$BUILD_TYPE" \
    "-DLESSON_FRAME_LUA=$LUA_ENABLED"

# 编译阶段：使用上一步同一个构建目录；--parallel 的值来自 FRAME_SYNC_BUILD_JOBS。
# 这里只生成编译产物，不运行 CTest。
"$CMAKE_BIN" --build "$BUILD_DIR" --parallel "$BUILD_JOBS"

# set -e 保证只有配置与编译均成功才会执行到这里并报告 BUILD_OK。
printf '[frame-sync-build] BUILD_OK\n'
