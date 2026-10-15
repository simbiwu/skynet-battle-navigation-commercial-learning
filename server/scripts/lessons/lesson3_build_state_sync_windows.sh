#!/usr/bin/env bash
# 从WSL唯一Native源交叉构建Windows x64预测DLL；输出由调用方明确指定。
# 用法：bash scripts/lessons/lesson3_build_state_sync_windows.sh <Unity Plugins/x86_64目录>
# 依赖MinGW POSIX工具链；C++17，与Skynet/Lua ABI无关；不修改Windows Server源码。
# 任一工具或构建步骤失败时立即终止，不复制旧 DLL 冒充新结果。
set -euo pipefail
# 从脚本位置定位 Server 源码根目录，与调用者当前目录无关。
SERVER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# 必须由调用者明确传入 Unity 插件输出目录，避免把 DLL 写入猜测的路径。
[[ $# == 1 ]] || { printf '%s\n' '需要明确的Unity插件输出目录'; exit 2; }
# 先确认交叉编译器存在；CMake 配置会同时使用配套的 C++ 与 C 编译器。
command -v x86_64-w64-mingw32-g++ >/dev/null
# -S 指 Native 源码，-B 指独立的 Windows 构建缓存目录；SYSTEM_NAME 选择 Windows 目标。
cmake -S "$SERVER_ROOT/native/state_sync" -B "$SERVER_ROOT/build/state_sync_windows" \
    -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_CXX_COMPILER=x86_64-w64-mingw32-g++ -DCMAKE_C_COMPILER=x86_64-w64-mingw32-gcc \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_SHARED_LINKER_FLAGS=-static
# 只构建预测库目标；并行度固定为 4，避免该课程脚本占满开发机资源。
cmake --build "$SERVER_ROOT/build/state_sync_windows" --target state_navigation --parallel 4
# 创建调用者指定的插件目录，并把本次构建产物复制为 Unity 固定加载名。
mkdir -p "$1"
cp "$SERVER_ROOT/build/state_sync_windows/libstate_navigation.dll" "$1/state_navigation.dll"
printf '%s\n' 'STATE_WINDOWS_NATIVE_BUILT'
