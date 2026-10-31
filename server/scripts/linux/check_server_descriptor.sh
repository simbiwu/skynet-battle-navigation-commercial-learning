#!/usr/bin/env bash
# 第一行 shebang 告诉系统用 Bash 解释本文件；也可显式运行 bash 加脚本路径。
# 调用：可从任意当前工作目录启动；脚本按自身路径定位工程目录。外部相对路径参数按调用时目录解析，建议传绝对路径。
# 示例：bash /absolute/path/to/checkout/server/scripts/linux/check_server_descriptor.sh [按本文件头部说明填写参数]
# 职责：用仓库自带 Lua protobuf Runtime 检查一个课程的独立 descriptor。
# 边界：只读离线检查；不编译协议、不生成 Registry、不启动 Skynet。
# 输入：lesson_01、lesson_02、lesson_03_frame_sync 或 lesson_03_state_sync。
# 输出：目标 descriptor 的公共 Envelope、本课程消息存在且其它课程类型缺席的结果。
# 调用示例：bash /path/to/repo/server/scripts/linux/check_server_descriptor.sh lesson_03_frame_sync
# 生命周期：对应 build_protocol_<课程>.sh 生成 descriptor 后执行。
# 修改指引：新增课程时同步更新下方 PROFILE 白名单和 server/protocol/check_descriptor.lua 合同表。
# -e/-u/pipefail：缺文件、变量拼错或 Lua 断言失败时非零退出。
set -euo pipefail

# Bash 语法速读：只解释本脚本实际使用的 Bash 写法；流程注释说明每一步为什么执行。
#   set -euo pipefail：-e 遇到未处理的失败通常退出，但条件判断、&& 和 || 等位置有例外，关键失败仍应显式检查；-u 遇到未设置变量时报错（提供默认值展开时除外）；pipefail 让管道任一步失败都能向外报告。
#   双引号中的 "$NAME" 把变量值作为一个完整参数；路径含空格时不会拆成多个参数。
#   $(命令)运行命令并用标准输出替换当前位置；命令在子 Shell 中运行，里面的 cd 不改变主脚本目录。
#   NAME:-默认值展开：变量未设置或为空字符串时使用默认值。
#   $#表示参数个数，$1/$2依次表示传入的第一个/第二个参数。
#   case ... in 按输入匹配分支；分支以 ) 开始、;;结束，*)是兜底分支。
#   单竖线 | 把左侧标准输出交给右侧；它不同于条件运算符 ||。
#   >把输出写入并覆盖文件；2>&1把标准错误接到标准输出当前去向。
# 从脚本位置求 Server 与仓库根目录，因此调用者当前目录不影响路径解析。
SERVER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_ROOT="$(cd "$SERVER_ROOT/.." && pwd)"
LUA="$SERVER_ROOT/third_party/skynet/3rd/lua/lua"
PROTOBUF_RUNTIME="$SERVER_ROOT/third_party/lua-protobuf-runtime"
# $1 是要检查的课程协议目标；缺省或空值采用 lesson_02。例：不带参数检查 lesson_02，传 lesson_03_frame_sync 则检查帧同步协议。
PROFILE="${1:-lesson_02}"

# 白名单同时限制输出路径与 Lua 检查使用的 profile 名，拒绝任意文件参数。
case "$PROFILE" in
    lesson_01|lesson_02|lesson_03_frame_sync|lesson_03_state_sync) ;;
    *) echo "未知协议目标：$PROFILE" >&2; exit 2 ;;
esac
DESCRIPTOR="$REPO_ROOT/shared/protocol/generated/server/$PROFILE.pb"

# 固定使用 Skynet 配套 Lua ABI 和项目 pb.so，不让系统 Lua 偶然通过检查。
test -x "$LUA"
test -s "$PROTOBUF_RUNTIME/pb.so"
test -s "$DESCRIPTOR"

# 将当前仓库 Runtime 加入 Lua 搜索路径；检查 Lua 进程不启动任何 Skynet Service。
LUA_PATH="$PROTOBUF_RUNTIME/?.lua;;" \
LUA_CPATH="$PROTOBUF_RUNTIME/?.so;;" \
    "$LUA" "$SERVER_ROOT/protocol/check_descriptor.lua" "$DESCRIPTOR" "$PROFILE"
