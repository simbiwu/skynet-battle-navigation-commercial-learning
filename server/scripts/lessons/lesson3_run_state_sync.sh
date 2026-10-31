#!/usr/bin/env bash
# 第一行 shebang 告诉系统用 Bash 解释本文件；也可显式运行 bash 加脚本路径。
# 调用：可从任意当前工作目录启动；脚本按自身路径定位工程目录。外部相对路径参数按调用时目录解析，建议传绝对路径。
# 示例：bash /absolute/path/to/checkout/server/scripts/lessons/lesson3_run_state_sync.sh [按本文件头部说明填写参数]
# 状态同步构建与测试辅助入口：prepare/build/test/benchmark；服务生命周期由 lesson3_run_server.sh state-sync 管理。
# battle/gateway 兼容子命令转发到课程入口，避免绕开 PID、READY、日志和停止合同。
# 任一命令失败就停止；未定义变量也立即报错，避免误用错误目录或配置。
set -euo pipefail
# Bash 语法速读：只解释本脚本实际使用的 Bash 写法；流程注释说明每一步为什么执行。
#   set -euo pipefail：-e 遇到未处理的失败通常退出，但条件判断、&& 和 || 等位置有例外，关键失败仍应显式检查；-u 遇到未设置变量时报错（提供默认值展开时除外）；pipefail 让管道任一步失败都能向外报告。
#   双引号中的 "$NAME" 把变量值作为一个完整参数；路径含空格时不会拆成多个参数。
#   $(命令)运行命令并用标准输出替换当前位置；命令在子 Shell 中运行，里面的 cd 不改变主脚本目录。
#   NAME:-默认值展开：变量未设置或为空字符串时使用默认值。
#   $#表示参数个数，$1/$2依次表示传入的第一个/第二个参数。
#   case ... in 按输入匹配分支；分支以 ) 开始、;;结束，*)是兜底分支。
#   单竖线 | 把左侧标准输出交给右侧；它不同于条件运算符 ||。
#   exec 用目标命令替换当前 Shell；外层不再执行后续语句，退出状态由目标命令决定。
# 以脚本位置为基准定位 Server 根目录，所以从仓库任意目录调用都有效。
SERVER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$SERVER_ROOT"
# 每个子命令只负责一种明确的课程操作；不传参数时显示帮助。
# ${1:-help} 在没有第一个参数或参数为空时展开为 help；例如传 build 就匹配 build 分支，不传参数进入帮助分支。
case "${1:-help}" in
    prepare)
        # 生成状态同步示例配置/资产，再检查 Server 所需协议描述文件。
        python3 scripts/lessons/prepare_state_sync.py
        bash scripts/linux/check_server_descriptor.sh lesson_03_state_sync
        ;;
    build)
        # 复用 Server 的通用依赖和 FlyWow 构建链，再构建状态同步 Native 预测库。
        bash scripts/linux/run_server.sh build
        python3 scripts/lessons/prepare_state_sync.py
        cmake -S native/state_sync -B build/state_sync -DCMAKE_BUILD_TYPE=Release
        cmake --build build/state_sync --parallel 4
        # 运行此 CMake 工程注册的测试；失败时输出完整失败信息并返回非零。
        ctest --test-dir build/state_sync --output-on-failure
        ;;
    test)
        # 显式加载 Skynet 配套 jemalloc，确保测试 Lua 使用与 Skynet 一致的分配器。
        # 前两项验证 Lua 侧逻辑；Python 集成测试负责启动并清理它自己创建的进程。
        LD_PRELOAD="$SERVER_ROOT/third_party/skynet/3rd/jemalloc/lib/libjemalloc.so" \
            third_party/skynet/3rd/lua/lua tests/state_sync_test.lua "$SERVER_ROOT"
        LD_PRELOAD="$SERVER_ROOT/third_party/skynet/3rd/jemalloc/lib/libjemalloc.so" \
            third_party/skynet/3rd/lua/lua tests/state_worker_test.lua "$SERVER_ROOT"
        python3 tests/state_sync_integration.py
        ;;
    benchmark)
        # 单独运行性能采样，不把 Benchmark 混入正确性测试门禁。
        LD_PRELOAD="$SERVER_ROOT/third_party/skynet/3rd/jemalloc/lib/libjemalloc.so" \
            third_party/skynet/3rd/lua/lua tests/state_sync_benchmark.lua "$SERVER_ROOT"
        ;;
    battle|gateway)
        # 兼容命令只转发；真实进程管理集中在 state-sync profile。
        exec scripts/lessons/lesson3_run_server.sh state-sync start "--$1"
        ;;
    *)
        printf '%s\n' '用法：bash /path/to/server/scripts/lessons/lesson3_run_state_sync.sh prepare|build|test|benchmark|battle|gateway'
        exit 2
        ;;
esac
