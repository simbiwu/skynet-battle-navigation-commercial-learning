#!/usr/bin/env bash
# 第一行 shebang 告诉系统用 Bash 解释本文件；也可显式运行 bash 加脚本路径。
# 调用：可从任意当前工作目录启动；脚本按自身路径定位工程目录。外部相对路径参数按调用时目录解析，建议传绝对路径。
# 示例：bash /absolute/path/to/checkout/server/scripts/linux/build_skynet.sh [按本文件头部说明填写参数]
# 职责：使用已固定的 Skynet 源码构建 skynet 可执行文件和 bundled Lua 运行时。
# 边界：Server Build；读取 third_party/skynet，写回该目录的本机构建产物。
# 输入/输出：Skynet Makefile -> third_party/skynet/skynet 与 3rd/lua/lua。
# 生命周期：bootstrap_skynet 成功后执行；可重复执行，不修改源码版本。
# 不负责：不下载依赖、不启动 Server、不使用系统 Lua 替代 Skynet bundled Lua。
set -euo pipefail
# Bash 语法速读：只解释本脚本实际使用的 Bash 写法；流程注释说明每一步为什么执行。
#   set -euo pipefail：-e 遇到未处理的失败通常退出，但条件判断、&& 和 || 等位置有例外，关键失败仍应显式检查；-u 遇到未设置变量时报错（提供默认值展开时除外）；pipefail 让管道任一步失败都能向外报告。
#   双引号中的 "$NAME" 把变量值作为一个完整参数；路径含空格时不会拆成多个参数。
#   $(命令)运行命令并用标准输出替换当前位置；命令在子 Shell 中运行，里面的 cd 不改变主脚本目录。
# -e：任意未处理的失败立即退出，避免错误结果继续传给下一阶段。
# -u：读取未定义变量时立即失败，尽早发现环境变量或变量名错误。
# pipefail：管道中任一命令失败都会让整条管道失败，避免只检查到最后一条命令。

# 以脚本位置推导 server 根目录，调用者无需先 cd 到固定目录。
SERVER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$SERVER_ROOT"

# Makefile 是源码完整性的最低检查；缺失时给出明确失败而不是让 make 输出难懂错误。
test -f third_party/skynet/Makefile
# linux 目标同时构建 Skynet 和它实际使用的 Lua 5.4 ABI。
# 只调用 Skynet 官方 Makefile 的 linux 目标；本脚本不复制或改写框架源码。
make -C third_party/skynet linux

# 这些文件是后续 Lua C 模块和 Server 启动的明确前置条件。
test -x third_party/skynet/skynet
test -f third_party/skynet/3rd/lua/lua.h
echo "SKYNET_BUILD_OK"
