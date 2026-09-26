#!/usr/bin/env bash
# 职责：阻止项目自有 Lua 源码把可变参数用作稳定接口或继续向业务层传播。
# 边界：Build/Test 静态策略检查；只扫描当前 server 的自有 Lua 源码，不扫描 third_party/generated。
# 输入/输出：service/lualib/protocol/config/tests 下的 .lua -> LUA_VARARG_POLICY_OK 或违规位置。
# 生命周期：由 run_server.sh build/rebuild 调用，也可由开发者单独执行；不修改任何文件。
# 不负责：不解析第三方 Lua、不替代 Lua 语法检查，也不对性能作无基准结论。
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

# 返回项目自有 Lua 文件。目录不存在时跳过，便于课程按阶段逐步增加 tests/lualib。
# 输出是一行一个绝对路径；不执行 I/O 写入，不分配项目运行时资源。
collect_project_lua_files() {
    local relative_dir
    for relative_dir in service lualib protocol config tests; do
        if [[ -d "$SERVER_ROOT/$relative_dir" ]]; then
            find "$SERVER_ROOT/$relative_dir" -type f -name '*.lua' -print
        fi
    done
}

# 检查 Lua vararg token。确有通用转发器例外时，必须在同一行写 VARARG_ALLOWED 和 WHY；
# 当前课程没有例外，因此正常结果应为零匹配。
main() {
    local files=()
    local violations
    mapfile -t files < <(collect_project_lua_files)

    if ((${#files[@]} == 0)); then
        printf '[lua-vararg] LUA_VARARG_POLICY_OK files=0\n'
        return 0
    fi

    violations="$(grep -nH -- '\.\.\.' "${files[@]}" | grep -v 'VARARG_ALLOWED' || true)"
    if [[ -n "$violations" ]]; then
        printf '[lua-vararg] ERROR: project Lua varargs are forbidden by AGENTS.md\n' >&2
        printf '%s\n' "$violations" >&2
        return 1
    fi

    printf '[lua-vararg] LUA_VARARG_POLICY_OK files=%d\n' "${#files[@]}"
}

main "$@"
