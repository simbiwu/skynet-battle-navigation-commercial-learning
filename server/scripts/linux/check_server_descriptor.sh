#!/usr/bin/env bash
# 职责：用仓库自带 Lua protobuf Runtime 检查一个课程的独立 descriptor。
# 边界：只读离线检查；不编译协议、不生成 Registry、不启动 Skynet。
# 输入：lesson_01、lesson_02、lesson_03_frame_sync 或 lesson_03_state_sync。
# 输出：目标 descriptor 的公共 Envelope、本课程消息存在且其它课程类型缺席的结果。
# 调用：bash server/scripts/linux/check_server_descriptor.sh lesson_03_frame_sync
# 生命周期：对应 build_protocol_<课程>.sh 生成 descriptor 后执行。
# 修改指引：新增课程时同步更新下方 PROFILE 白名单和 server/protocol/check_descriptor.lua 合同表。
# -e/-u/pipefail：缺文件、变量拼错或 Lua 断言失败时非零退出。
set -euo pipefail

# 从脚本位置求 Server 与仓库根目录，因此调用者当前目录不影响路径解析。
SERVER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_ROOT="$(cd "$SERVER_ROOT/.." && pwd)"
LUA="$SERVER_ROOT/third_party/skynet/3rd/lua/lua"
PROTOBUF_RUNTIME="$SERVER_ROOT/third_party/lua-protobuf-runtime"
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
