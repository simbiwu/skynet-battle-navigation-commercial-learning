#!/usr/bin/env bash
# 状态同步构建与测试辅助入口：prepare/build/test/benchmark；服务生命周期由 lesson3_run_server.sh state-sync 管理。
# battle/gateway 兼容子命令转发到课程入口，避免绕开 PID、READY、日志和停止合同。
# 任一命令失败就停止；未定义变量也立即报错，避免误用错误目录或配置。
set -euo pipefail
# 以脚本位置为基准定位 Server 根目录，所以从仓库任意目录调用都有效。
SERVER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$SERVER_ROOT"
# 每个子命令只负责一种明确的课程操作；不传参数时显示帮助。
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
        printf '%s\n' '用法：bash scripts/lessons/lesson3_run_state_sync.sh prepare|build|test|benchmark|battle|gateway'
        exit 2
        ;;
esac
