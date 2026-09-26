#!/usr/bin/env bash
# 职责：提供一个短命令入口，复用 run_server.sh 的安全停止实现。
# 边界：Server Runtime Control；不自行读取 PID、不直接 kill 任意进程。
# 输入/输出：--force 可选参数 -> SIGTERM 等待结果或明确失败。
# 生命周期：一次命令调用；所有状态由 run_server.sh 统一管理。
# 不负责：不重新构建、不启动 Server、不绕过 PID 身份校验。
set -euo pipefail
# SCRIPT_DIR 保证即使从仓库任意目录调用也能定位主控制器。
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# exec 保留 run_server.sh 的退出码和信号语义，避免包装脚本吞掉失败。
exec "$SCRIPT_DIR/run_server.sh" stop "$@"
