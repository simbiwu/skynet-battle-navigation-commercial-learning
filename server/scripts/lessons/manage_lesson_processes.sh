#!/usr/bin/env bash
# 职责：统一管理各课 PID、日志、READY、状态与停止；第二课及第三课使用 Cluster shutdownctl 做业务收尾。
# 课程：lesson1、lesson2、lesson3-state-sync、lesson3-frame-sync 各自使用隔离配置、READY 标记和 PID/log 路径。
# 调用：由 lessonN_run_server.sh 转发 start|stop|restart|status|doctor [--gateway|--battle]。
# 路径：PID 与重定向诊断日志位于 server/run/<profile>/、server/logs/<profile>/；业务日志仍由 FlyWow Logger 按配置写到 logs/<role>/。
# 环境变量：LESSON_STARTUP_TIMEOUT_SEC 默认20；LESSON_STOP_TIMEOUT_SEC 默认0表示本进程业务收尾和退出均无限等待，正数才启用超时回退。
# 进程：只操作 PID 文件中命令行包含本 profile 配置的 Skynet；start Battle 优先，stop Gateway 优先。
# 关闭：Lesson 2/3 先调用进程内协调器；默认无限等待，正数超时到达后仅向所选业务进程发 SIGTERM，随后仍等待退出。Lesson 1 无协调器，直接 SIGTERM 后等待退出。
# 兼容：run_lesson_02_processes.sh 仅把旧调用转发到本管理器，不再实现第二份进程逻辑。
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
SKYNET="$SERVER_ROOT/third_party/skynet/skynet"
PROFILE="${LESSON_PROCESS_PROFILE:?必须由课程入口设置 LESSON_PROCESS_PROFILE}"
START_TIMEOUT="${LESSON_STARTUP_TIMEOUT_SEC:-20}"
STOP_TIMEOUT="${LESSON_STOP_TIMEOUT_SEC:-0}"
DO_GATEWAY=0
DO_BATTLE=0
ACTION="${1:-help}"
if [[ $# -gt 0 ]]; then shift; fi
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
config_of(){ local key="CONFIG_$1"; printf '%s' "${!key}"; }
marker_of(){ local key="MARKER_$1"; printf '%s' "${!key}"; }
logger_of(){ local key="LOGGER_$1"; printf '%s' "${!key}"; }
read_pid(){
 local role="$1" f p conf
 f="$(pid_file "$role")"; [[ -s "$f" ]] || return 1
 p="$(tr -d '[:space:]' < "$f")"; [[ "$p" =~ ^[0-9]+$ ]] || fail "非法 PID 文件：$f"
 kill -0 "$p" 2>/dev/null || return 1
 conf="$(config_of "$role")"
 ps -p "$p" -o args= | grep -F -- "$conf" >/dev/null || fail "PID $p 不属于配置 $conf"
 printf '%s\n' "$p"
}
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

doctor(){
 [[ -x "$SKYNET" ]] || fail "Skynet 不可执行：$SKYNET；先运行 Server build"
 for role in "${ROLES[@]}"; do [[ -f "$SERVER_ROOT/config/$(config_of "$role")" ]] || fail "配置缺失：$(config_of "$role")"; done
 if [[ "$PROFILE" == lesson2 ]]; then
   for path in service/gateway/gateway_main.lua service/battle/battle_main.lua service/gateway/gateway_proxy.lua service/battle/battle_dispatch.lua service/battle/battle_mgr.lua service/battle/battle_worker.lua config/shutdownctl_process.lua service/admin/shutdownctl.lua lualib/gateway/protocol/protocol_registry_lesson_02.lua; do
     [[ -s "$SERVER_ROOT/$path" ]] || fail "第二课运行依赖缺失：$path"
   done
 fi
 log "DOCTOR_OK configs=${ROLES[*]}"
}
select_roles(){
 if [[ "$PROFILE" == lesson1 ]]; then DO_BATTLE=1; return; fi
 if ((DO_GATEWAY==0 && DO_BATTLE==0)); then DO_GATEWAY=1; DO_BATTLE=1; fi
}
case "$ACTION" in
 -h|--help|help) usage; exit 0 ;;
esac
# 只有实际管理动作才创建本机运行状态与诊断日志目录；help 不产生文件系统副作用。
mkdir -p "$RUN_DIR" "$CAPTURE_DIR"
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
