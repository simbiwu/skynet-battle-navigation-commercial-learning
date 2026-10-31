#!/usr/bin/env bash
# 第一行 shebang 告诉系统用 Bash 解释本文件；也可显式运行 bash 加脚本路径。
# 调用：可从任意当前工作目录启动；脚本按自身路径定位工程目录。外部相对路径参数按调用时目录解析，建议传绝对路径。
# 示例：bash /absolute/path/to/checkout/server/scripts/lessons/lesson3_build_state_sync_windows.sh [按本文件头部说明填写参数]
# 从WSL唯一Native源交叉构建Windows x64预测DLL；输出由调用方明确指定。
# 用法：bash /path/to/server/scripts/lessons/lesson3_build_state_sync_windows.sh <Unity Plugins/x86_64目录>。输出目录参数若为相对路径，以调用命令时的当前目录为基准。
# 依赖MinGW POSIX工具链；C++17，与Skynet/Lua ABI无关；不修改Windows Server源码。
# 任一工具或构建步骤失败时立即终止，不复制旧 DLL 冒充新结果。
set -euo pipefail
# Bash 语法速读：只解释本脚本实际使用的 Bash 写法；流程注释说明每一步为什么执行。
#   set -euo pipefail：-e 遇到未处理的失败通常退出，但条件判断、&& 和 || 等位置有例外，关键失败仍应显式检查；-u 遇到未设置变量时报错（提供默认值展开时除外）；pipefail 让管道任一步失败都能向外报告。
#   双引号中的 "$NAME" 把变量值作为一个完整参数；路径含空格时不会拆成多个参数。
#   $(命令)运行命令并用标准输出替换当前位置；命令在子 Shell 中运行，里面的 cd 不改变主脚本目录。
#   $#表示参数个数，$1/$2依次表示传入的第一个/第二个参数。
#   [[ 条件 ]]执行 Bash 条件判断；具体比较符见对应条件。
#   >把输出写入并覆盖文件；2>&1把标准错误接到标准输出当前去向。
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
