#!/usr/bin/env bash
# 第一行 shebang 告诉系统用 Bash 解释本文件；也可显式运行 bash 加脚本路径。
# 调用：可从任意当前工作目录启动；脚本按自身路径定位工程目录。外部相对路径参数按调用时目录解析，建议传绝对路径。
# 示例：bash /absolute/path/to/checkout/server/scripts/lessons/manage_lesson_processes.sh [按本文件头部说明填写参数]
# 职责：统一管理各课 PID、日志、READY、状态与停止；第二课及第三课使用 Cluster shutdownctl 做业务收尾。
# 课程：lesson1、lesson2、lesson3-state-sync、lesson3-frame-sync 各自使用隔离配置、READY 标记和 PID/log 路径。
# 调用：由 lessonN_run_server.sh 转发 start|stop|restart|status|doctor [--gateway|--battle]。
# 路径：PID 与重定向诊断日志位于 server/run/<profile>/、server/logs/<profile>/；业务日志仍由 FlyWow Logger 按配置写到 logs/<role>/。
# 环境变量：LESSON_STARTUP_TIMEOUT_SEC 默认20；LESSON_STOP_TIMEOUT_SEC 默认0表示本进程业务收尾和退出均无限等待，正数才启用超时回退。
# 进程：只操作 PID 文件中命令行包含本 profile 配置的 Skynet；start Battle 优先，stop Gateway 优先。
# 关闭：Lesson 2/3 先调用进程内协调器；默认无限等待，正数超时到达后仅向所选业务进程发 SIGTERM，随后仍等待退出。Lesson 1 无协调器，直接 SIGTERM 后等待退出。
# 兼容：run_lesson_02_processes.sh 仅把旧调用转发到本管理器，不再实现第二份进程逻辑。
set -euo pipefail
# Bash 语法速读：只解释本脚本实际使用的 Bash 写法；流程注释说明每一步为什么执行。
#   set -euo pipefail：-e 遇到未处理的失败通常退出，但条件判断、&& 和 || 等位置有例外，关键失败仍应显式检查；-u 遇到未设置变量时报错（提供默认值展开时除外）；pipefail 让管道任一步失败都能向外报告。
#   双引号中的 "$NAME" 把变量值作为一个完整参数；路径含空格时不会拆成多个参数。
#   $(命令)运行命令并用标准输出替换当前位置；命令在子 Shell 中运行，里面的 cd 不改变主脚本目录。
#   NAME:-默认值展开：变量未设置或为空字符串时使用默认值。
#   NAME:?错误说明展开：必需变量未设置或为空时显示说明并以非零状态失败。
#   间接展开：先把变量的值当作另一个变量名，再读取那个变量的值。
#   "$@"逐个保留所有位置参数；双引号防止参数中的空格被拆开。
#   $#表示参数个数，$1/$2依次表示传入的第一个/第二个参数。
#   shift 丢弃第一个位置参数，其余参数向前移动一位。
#   [[ 条件 ]]执行 Bash 条件判断；-f检查普通文件，-d检查目录，-x检查可执行文件，-s检查非空文件，-e检查存在的路径，-n检查非空字符串。
#   case ... in 按输入匹配分支；分支以 ) 开始、;;结束，*)是兜底分支。
#   name() { ...; }定义函数；调用函数名即可执行函数体。
#   local 声明函数内部临时变量；函数返回后恢复调用者同名变量的值。
#   for/while ... do ... done 重复执行循环体；列表或条件决定循环何时结束。
#   name=(...)创建 Bash 数组；数组的 @ 展开逐项传参并保留每个元素边界。
#   单竖线 | 把左侧标准输出交给右侧；它不同于条件运算符 ||。
#   >把输出写入并覆盖文件；2>&1把标准错误接到标准输出当前去向。
#   命令末尾的 & 在后台启动进程；$!取得最近后台进程 PID，wait 等待它并收取退出码。
#   exec 用目标命令替换当前 Shell；外层不再执行后续语句，退出状态由目标命令决定。
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
SKYNET="$SERVER_ROOT/third_party/skynet/skynet"
# ${变量:?错误说明} 要求变量已设置且非空；缺失时 Bash 显示错误并停止，避免管理错误课程的进程。课程入口会设置 LESSON_PROCESS_PROFILE。
PROFILE="${LESSON_PROCESS_PROFILE:?必须由课程入口设置 LESSON_PROCESS_PROFILE}"
# ${变量:-默认值} 在未设置或空值时使用默认值；例如未设置启动超时则 START_TIMEOUT=20 秒。
START_TIMEOUT="${LESSON_STARTUP_TIMEOUT_SEC:-20}"
# 未设置停止超时时 STOP_TIMEOUT=0，表示不启用超时回退；例如 LESSON_STOP_TIMEOUT_SEC=30 时采用 30 秒。
STOP_TIMEOUT="${LESSON_STOP_TIMEOUT_SEC:-0}"
DO_GATEWAY=0
DO_BATTLE=0
# $1 是动作参数；省略时用 help。例：start 会进入启动分支，不传参数显示帮助。
ACTION="${1:-help}"
if [[ $# -gt 0 ]]; then shift; fi
# profile 选择不同课程配置；ROLES、CONFIG_*, MARKER_*、LOGGER_* 共同描述该配置要管理的进程。
# Bash 的 name=(...) 创建数组，ROLES=(battle gateway) 表示两个可独立启动/停止的角色。
case "$PROFILE" in
 lesson1)
   RUN_KEY=lesson1; ROLES=(server); CONFIG_server=skynet.lua; MARKER_server=NAV_SERVER_READY; LOGGER_server=server ;;
 lesson2)
   RUN_KEY=lesson2; ROLES=(battle gateway)
   CONFIG_battle=battle_process.lua; MARKER_battle=LESSON2_BATTLE_PROCESS_READY; LOGGER_battle=battle
   CONFIG_gateway=gateway_process.lua; MARKER_gateway=LESSON2_GATEWAY_PROCESS_READY; LOGGER_gateway=gateway ;;
 lesson3-state-sync)
   RUN_KEY=lesson3_state_sync; ROLES=(battle gateway)
   CONFIG_battle=state_battle_process.lua; MARKER_battle=STATE_BATTLE_READY; LOGGER_battle=state_battle
   CONFIG_gateway=state_gateway_process.lua; MARKER_gateway=STATE_GATEWAY_READY; LOGGER_gateway=state_gateway ;;
 lesson3-frame-sync)
   RUN_KEY=lesson3_frame_sync; ROLES=(battle gateway)
   CONFIG_battle=frame_battle_process.lua; MARKER_battle=FRAME_BATTLE_READY; LOGGER_battle=frame_battle
   CONFIG_gateway=frame_gateway_process.lua; MARKER_gateway=FRAME_GATEWAY_READY; LOGGER_gateway=frame_gateway ;;
 *) printf '[lesson-process] ERROR: 未知课程配置：%s\n' "$PROFILE" >&2; exit 2 ;;
esac
RUN_DIR="$SERVER_ROOT/run/$RUN_KEY"
CAPTURE_DIR="$SERVER_ROOT/logs/$RUN_KEY"
# 下面的函数只读状态或管理子进程；pid_file/capture_file 返回路径文本供调用者保存。
usage() {
 cat <<USAGE
用法：lessonN_run_server.sh start|stop|restart|status|doctor [--gateway|--battle]
配置档：$PROFILE
不指定角色时操作该配置档的全部进程；Lesson 1 固定为单进程 server。
默认无限等待本进程的业务收尾完成；LESSON_STOP_TIMEOUT_SEC=20 可显式设置20秒上限。
超时到达时只发送 SIGTERM；信号后仍等待目标进程自行退出。
USAGE
}
log(){ printf '[%s] %s\n' "$PROFILE" "$*"; }
fail(){ log "ERROR: $*"; exit 1; }
[[ "$STOP_TIMEOUT" =~ ^[0-9]+$ ]] || fail "LESSON_STOP_TIMEOUT_SEC 必须是非负整数"
pid_file(){ printf '%s/%s.pid' "$RUN_DIR" "$1"; }
capture_file(){ printf '%s/%s.log' "$CAPTURE_DIR" "$1"; }
# config_of/marker_of/logger_of 按角色名拼出字段名；${!key} 间接读取该字段的值。
config_of(){ local key="CONFIG_$1"; printf '%s' "${!key}"; }
marker_of(){ local key="MARKER_$1"; printf '%s' "${!key}"; }
logger_of(){ local key="LOGGER_$1"; printf '%s' "${!key}"; }
# read_pid 把有效 PID 写到标准输出；文件不存在/进程已退出时返回 1，格式或归属错误则 fail。
# 调用方可用 p="$(read_pid role)" 捕获输出；命令替换中的局部变量不会改动主脚本变量。
read_pid(){
 local role="$1" f p conf
 f="$(pid_file "$role")"; [[ -s "$f" ]] || return 1
 p="$(tr -d '[:space:]' < "$f")"; [[ "$p" =~ ^[0-9]+$ ]] || fail "非法 PID 文件：$f"
 kill -0 "$p" 2>/dev/null || return 1
 conf="$(config_of "$role")"
 ps -p "$p" -o args= | grep -F -- "$conf" >/dev/null || fail "PID $p 不属于配置 $conf"
 printf '%s\n' "$p"
}
# start_role 启动一个 Skynet 角色，并创建 PID、输出捕获文件和本次启动日志 offset 记录。
# & 把 Skynet 放入后台，$! 立刻给出该进程 PID；Shell 本身继续运行 READY 检查。
start_role(){
 local role="$1" p f c logger day offset
 f="$(pid_file "$role")"; c="$(config_of "$role")"; logger="$(logger_of "$role")"
 if p="$(read_pid "$role")"; then fail "$role 已运行 pid=$p"; fi
 rm -f "$f"
 # 在启动前记录当日日志长度，READY 检查只接受本次启动新增的标记。
 day="$(date +%F)"; offset=0
 [[ -f "$SERVER_ROOT/logs/$logger/$day.log" ]] && offset="$(stat -c %s "$SERVER_ROOT/logs/$logger/$day.log")"
 printf '%s %s\n' "$day" "$offset" > "$f.log_offset"
 (cd "$SERVER_ROOT"; exec "$SKYNET" "$SERVER_ROOT/config/$c") >"$(capture_file "$role")" 2>&1 &
 p=$!; printf '%s\n' "$p" > "$f"
 log "STARTING role=$role pid=$p capture=$(capture_file "$role")"
}
# await_ready 从保存的日志偏移处查找本次启动的 READY 标记；旧日志中的同名标记不算成功。
# for ((...)) 是 Bash 整数循环；START_TIMEOUT=0 时条件允许循环持续等待，不设启动期限。
await_ready(){
 local role="$1" p f marker logger day offset i
 f="$(pid_file "$role")"; p="$(read_pid "$role")" || fail "$role 启动后立即退出"
 marker="$(marker_of "$role")"; logger="$(logger_of "$role")"
 read -r day offset < "$f.log_offset"
 for ((i=0; START_TIMEOUT==0 || i<START_TIMEOUT; i++)); do
   day_now="$(date +%F)"; [[ "$day_now" == "$day" ]] || offset=0
   if ! kill -0 "$p" 2>/dev/null; then fail "$role 在 READY 前退出；查看 $(capture_file "$role")"; fi
   if tail -c "+$((offset+1))" "$SERVER_ROOT/logs/$logger/$day_now.log" 2>/dev/null | grep -Fq "$marker"; then
     log "READY role=$role pid=$p"; return
   fi
   sleep 1
 done
 fail "$role READY 超时；查看 $(capture_file "$role")"
}
# 将课程 profile 映射为 shutdownctl 运行配置的枚举名。
# lesson1 是单进程课程，不接入 Cluster shutdownctl，返回非零供调用方回退信号关闭。
shutdown_profile_name(){
 case "$PROFILE" in
   lesson2) printf lesson2 ;;
   lesson3-state-sync) printf state_sync ;;
   lesson3-frame-sync) printf frame_sync ;;
   *) return 1 ;;
 esac
}

# 启动一次性 Admin Process，向指定角色或整组角色发送优雅关闭请求。
# STOP_STARTED_AT 是整次 stop 的唯一计时起点；shutdownctl 和进程退出共享同一个截止时间。
# 默认 STOP_TIMEOUT=0 时不设截止时间；显式正数超时后，调用者只对本次选中的目标 PID 发送 SIGTERM。
# Admin 控制器 PID 单独记录，便于超时后终止卡住的临时控制进程，不影响未选择的业务角色。
STOP_STARTED_AT=0
SHUTDOWNCTLPID=""
stop_timed_out(){
 ((STOP_TIMEOUT > 0 && SECONDS - STOP_STARTED_AT >= STOP_TIMEOUT))
}
# run_shutdownctl 用 sed 生成一次性 Admin 配置并启动 Skynet；返回 0=收到成功标记、2=控制器失败/异常退出、1=超时。
# 配置写入由 > 覆盖文件；随后通过后台进程日志等待确认，不让控制器占用业务角色 PID。
run_shutdownctl(){
 local profile_name="$1" target="$2"
 local f="$RUN_DIR/shutdownctl_${target}.lua"
 local out="$CAPTURE_DIR/shutdownctl_${target}.log"
 local marker="SHUTDOWNCTL_OK target=$target profile=$profile_name"
 SHUTDOWNCTLPID=""
 rm -f "$out"
 sed -e "s/^shutdown_profile = .*/shutdown_profile = \"$profile_name\"/" \
     -e "s/^shutdown_target = .*/shutdown_target = \"$target\"/" \
     "$SERVER_ROOT/config/shutdownctl_process.lua" > "$f"
 (cd "$SERVER_ROOT"; exec "$SKYNET" "$f") >"$out" 2>&1 &
 SHUTDOWNCTLPID=$!
 while :; do
   if grep -Fq "$marker" "$out"; then return 0; fi
   if grep -Fq "SHUTDOWNCTL_FAILED" "$out"; then
     log "shutdownctl 明确报告失败 profile=$profile_name target=$target；查看 $out"
     return 2
   fi
   if ! kill -0 "$SHUTDOWNCTLPID" 2>/dev/null; then
     log "shutdownctl 已退出但没有成功确认 profile=$profile_name target=$target；查看 $out"
     return 2
   fi
   if stop_timed_out; then
     log "整次 stop 已超过显式超时 ${STOP_TIMEOUT}s；查看 $out"
     return 1
   fi
   sleep 1
 done
}
# wait_for_pids 逐个检查传入的目标 PID；全部退出才返回 0，显式停止期限到达返回 1。
wait_for_pids(){
 local p any_running
 while :; do
   any_running=0
   for p in "$@"; do
     if [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; then any_running=1; fi
   done
   ((any_running)) || return 0
   stop_timed_out && return 1
   sleep 1
 done
}
# stop_roles 先收集仍运行的角色和 PID，再请求业务优雅关闭；需要回退时只向这批 PID 发送 SIGTERM。
# active_roles 与 active_pids 是并行数组：相同下标分别保存角色名和其 PID，顺序保持一致。
stop_roles(){
 local profile_name="" role p ctl_status=0 graceful_target=""
 local -a active_roles=() active_pids=()
 for role in "${roles[@]}"; do
   if p="$(read_pid "$role")"; then
     active_roles+=("$role"); active_pids+=("$p")
   else
     rm -f "$(pid_file "$role")"
     log "$role STOPPED"
   fi
 done
 (("${#active_roles[@]}" > 0)) || return 0
 STOP_STARTED_AT=$SECONDS
 if profile_name="$(shutdown_profile_name)"; then
   if (("${#active_roles[@]}" == 2)); then graceful_target=all
   else graceful_target="${active_roles[0]}"
   fi
   if run_shutdownctl "$profile_name" "$graceful_target"; then ctl_status=0
   else ctl_status=$?
   fi
   if ((ctl_status == 0)); then
     if wait_for_pids "${active_pids[@]}"; then
       for role in "${active_roles[@]}"; do rm -f "$(pid_file "$role")"; done
       log "GRACEFUL_STOPPED roles=${active_roles[*]} profile=$profile_name"
       return 0
     fi
     log "显式超时后仍有目标进程存活；将只对所选业务 PID 发送 SIGTERM"
   elif ((STOP_TIMEOUT == 0)); then
     fail "shutdownctl 未能确认关闭；默认无限等待策略下不发送信号，不影响其它角色。查看 $CAPTURE_DIR/shutdownctl_${graceful_target}.log"
   else
     while ! stop_timed_out; do sleep 1; done
     log "shutdownctl 未确认关闭且显式超时已到；将只对所选业务 PID 发送 SIGTERM"
   fi
 fi
 for p in "${active_pids[@]}"; do if kill -0 "$p" 2>/dev/null; then kill -TERM "$p"; fi; done
 if [[ -n "$SHUTDOWNCTLPID" ]] && kill -0 "$SHUTDOWNCTLPID" 2>/dev/null; then kill -TERM "$SHUTDOWNCTLPID"; fi
 log "已向所选进程发送 SIGTERM；等待其自行退出"
 for p in "${active_pids[@]}"; do while kill -0 "$p" 2>/dev/null; do sleep 1; done; done
 for role in "${active_roles[@]}"; do rm -f "$(pid_file "$role")"; log "STOPPED role=$role"; done
}

# doctor 只检查可启动所需的 Skynet、配置和课程文件，不启动或停止进程。
doctor(){
 [[ -x "$SKYNET" ]] || fail "Skynet 不可执行：$SKYNET；先运行 Server build"
 for role in "${ROLES[@]}"; do [[ -f "$SERVER_ROOT/config/$(config_of "$role")" ]] || fail "配置缺失：$(config_of "$role")"; done
 if [[ "$PROFILE" == lesson2 ]]; then
   for path in service/gateway/gateway_main.lua service/battle/battle_main.lua service/gateway/gateway_proxy.lua service/battle/battle_dispatch.lua service/battle/battle_mgr.lua service/battle/battle_worker.lua config/shutdownctl_process.lua service/admin/shutdownctl.lua lualib/gateway/protocol/protocol_registry_lesson_02.lua; do
     [[ -s "$SERVER_ROOT/$path" ]] || fail "第二课运行依赖缺失：$path"
   done
 fi
 if [[ "$PROFILE" == lesson3-frame-sync || "$PROFILE" == lesson3-state-sync ]]; then
   for path in config/shutdownctl_process.lua service/admin/shutdownctl.lua service/admin/lesson3_shutdown_coordinator.lua; do
     [[ -s "$SERVER_ROOT/$path" ]] || fail "第三课优雅关闭依赖缺失：$path"
   done
 fi
 log "DOCTOR_OK configs=${ROLES[*]}"
}
# 根据命令行选项决定 roles 数组；未选角色时默认同时选 Gateway 与 Battle。
select_roles(){
 if [[ "$PROFILE" == lesson1 ]]; then DO_BATTLE=1; return; fi
 if ((DO_GATEWAY==0 && DO_BATTLE==0)); then DO_GATEWAY=1; DO_BATTLE=1; fi
}
case "$ACTION" in
 -h|--help|help) usage; exit 0 ;;
esac
# 只有实际管理动作才创建本机运行状态与诊断日志目录；help 不产生文件系统副作用。
mkdir -p "$RUN_DIR" "$CAPTURE_DIR"
# 参数处理逐个读取 "$1"；每轮末尾 shift 消耗已处理选项，直到 $# 变为 0。
while [[ $# -gt 0 ]]; do
 case "$1" in --gateway) DO_GATEWAY=1 ;; --battle) DO_BATTLE=1 ;; *) usage >&2; fail "未知参数：$1" ;; esac
 shift
done
case "$ACTION" in start|stop|restart|status|doctor) ;; *) usage >&2; fail "未知动作：$ACTION" ;; esac
select_roles
if [[ "$ACTION" == doctor || "$ACTION" == start || "$ACTION" == restart ]]; then doctor; fi
if [[ "$PROFILE" == lesson1 ]]; then
 roles=(server)
else
 roles=()
 ((DO_BATTLE)) && roles+=(battle)
 ((DO_GATEWAY)) && roles+=(gateway)
fi
case "$ACTION" in
 doctor) ;;
 start)
   for role in "${roles[@]}"; do start_role "$role"; await_ready "$role"; done
   log START_OK ;;
 stop|restart)
   stop_roles
   log STOP_OK
   if [[ "$ACTION" == restart ]]; then for role in "${roles[@]}"; do start_role "$role"; await_ready "$role"; done; log START_OK; fi ;;
 status)
   for role in "${roles[@]}"; do if p="$(read_pid "$role")"; then log "$role RUNNING pid=$p capture=$(capture_file "$role")"; else log "$role STOPPED"; fi; done ;;
esac
