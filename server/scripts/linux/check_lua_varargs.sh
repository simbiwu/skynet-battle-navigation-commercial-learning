#!/usr/bin/env bash
# 第一行 shebang 告诉系统用 Bash 解释本文件；也可显式运行 bash 加脚本路径。
# 调用：可从任意当前工作目录启动；脚本按自身路径定位工程目录。外部相对路径参数按调用时目录解析，建议传绝对路径。
# 示例：bash /absolute/path/to/checkout/server/scripts/linux/check_lua_varargs.sh [按本文件头部说明填写参数]
# 职责：阻止项目自有 Lua 源码把可变参数用作稳定接口或继续向业务层传播。
# 边界：Build/Test 静态策略检查；只扫描当前 server 的自有 Lua 源码，不扫描 third_party/generated。
# 输入/输出：service/、lualib/、config/、tests/ 下的 .lua -> LUA_VARARG_POLICY_OK 或违规位置。
# 生命周期：由 run_server.sh build/rebuild 调用，也可由开发者单独执行；不修改任何文件。
# 不负责：不解析第三方 Lua、不替代 Lua 语法检查，也不对性能作无基准结论。
set -euo pipefail
# Bash 语法速读：只解释本脚本实际使用的 Bash 写法；流程注释说明每一步为什么执行。
#   set -euo pipefail：-e 遇到未处理的失败通常退出，但条件判断、&& 和 || 等位置有例外，关键失败仍应显式检查；-u 遇到未设置变量时报错（提供默认值展开时除外）；pipefail 让管道任一步失败都能向外报告。
#   双引号中的 "$NAME" 把变量值作为一个完整参数；路径含空格时不会拆成多个参数。
#   $(命令)运行命令并用标准输出替换当前位置；命令在子 Shell 中运行，里面的 cd 不改变主脚本目录。
#   "$@"逐个保留所有位置参数；双引号防止参数中的空格被拆开。
#   [[ 条件 ]]执行 Bash 条件判断；-d检查目录，-n检查非空字符串。
#   name() { ...; }定义函数；调用函数名即可执行函数体。
#   local 声明函数内部临时变量；函数返回后恢复调用者同名变量的值。
#   for/while ... do ... done 重复执行循环体；列表或条件决定循环何时结束。
#   name=(...)创建 Bash 数组；数组的 @ 展开逐项传参并保留每个元素边界。
#   单竖线 | 把左侧标准输出交给右侧；它不同于条件运算符 ||。
#   >把输出写入并覆盖文件；2>&1把标准错误接到标准输出当前去向。
#   mapfile 把标准输入按行读进数组；本脚本的来源由 < <(命令)进程替换提供。
#   < <(命令)是进程替换：命令输出像临时输入文件一样供左侧命令读取，不改变当前 Shell 的目录。
# -e：任意未处理的失败立即退出，避免错误结果继续传给下一阶段。
# -u：读取未定义变量时立即失败，尽早发现环境变量或变量名错误。
# pipefail：管道中任一命令失败都会让整条管道失败，避免只检查到最后一条命令。

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
    # 只扫描项目 Lua；third_party 是供应商代码，不在本项目规则检查范围内。
    # < <(函数) 是进程替换：函数输出作为 mapfile 的输入；mapfile -t 按行存进 files 数组并去掉行尾换行。
    mapfile -t files < <(collect_project_lua_files)

    if ((${#files[@]} == 0)); then
        printf '[lua-vararg] LUA_VARARG_POLICY_OK files=0\n'
        return 0
    fi

    # grep 找不到匹配项时返回码 1；|| true 把“零违规”转换成空输出继续判定。
    # 有违规时保留文件名和行号，后续错误分支会把它们打印出来。
    violations="$(grep -nH -- '\.\.\.' "${files[@]}" | grep -v 'VARARG_ALLOWED' || true)"
    if [[ -n "$violations" ]]; then
        printf '[lua-vararg] ERROR: project Lua varargs are forbidden by AGENTS.md\n' >&2
        printf '%s\n' "$violations" >&2
        return 1
    fi

    printf '[lua-vararg] LUA_VARARG_POLICY_OK files=%d\n' "${#files[@]}"
}

main "$@"
