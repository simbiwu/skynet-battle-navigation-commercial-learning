# FlyWow 可选空中导航实施结果

日期：2026-10-13。状态：基础链路实现并完成本次相关验证；变更保留在 WSL 主工作区，未执行 Git 操作。

## 交付与边界

唯一源：`/home/simbi/workspace/skynet-battle-navigation-commercial-learning`，FlyWow 修改限定 `server/third_party/skynet-flywow` 子模块。宿主 Windows Unity 工程及正式导航资产未改；没有修改独立 FlyWow 工作区，没有提交、推送、更新 submodule 指针或运行 Git 状态命令。

完成 Unity 显式开关/专用 Collider LayerMask -> 保守多区间 AIRN V1 导出 -> 完整配对/Manifest/包身份/原子发布 -> Native 显式可选加载 -> 固定高度八邻接寻路 -> Context 私有动态 AABB -> 连续 move/sweep -> Path 部分推进。BMAP V1 字节及旧无空中文件入口兼容，新增六个操作全部复用现有模块/Registry/Context/Path/构建产物。

API 为 `set_air_obstacle`、`remove_air_obstacle`、`find_air_path`、`move_air`、`advance_air_path`、`sweep_air`，Lua 都使用具名 request。LuaDoc、Native IDE 注释、`navigation/CONTRACT.md` 和独立 `navigation/examples/air_navigation.lua` 已同步。例子覆盖加载、对象创建、绕行、推进、调用者指定升降、只读扫掠与释放，并在真实固定 Lua ABI 下运行。

本次没有接入 Frame Core、Battle、技能/弹丸业务，没有修改第三课实操教程。固定高度规划不自动搜索升降；连续 sweep/move 可改变 Y。几何正确性按整格闭高度区间/轴对齐盒体合同成立，不承诺旋转网格精确通道或同时多对象协同避让。

## 已说明并处理的合同冲突

1. 宿主 BMAP 文档曾写“独立 NoFly/Air Grid”，FlyWow README 曾写“不提供飞行”。按用户明确实施方案修正为同一 Navigation 内可选 AIRN 资产组件；BMAP 不加字段/保留位。宿主追加 D044，FlyWow 追加 D011，没有改写课程实操。
2. 实际 Lua `new_context` 原先在创建时要求 ground Profile，纯空中请求显式传体积而无需 ground 配置。已说明后移除无关创建前置条件；地面操作自身仍读取当前 Profile，未配置返回 INVALID_AGENT，真实 Lua 测试锁定此失败语义。没有新增空中配置表。

## 真实验证

|类别|执行结果与证据|
|---|---|
|统一构建|`bash scripts/build_flywow.sh ../skynet navigation`，RelWithDebInfo 成功；现有 Lua Binding 自测 1/1，Navigation CTest 3/3|
|Native|ground/BMAP 回归、AIRN golden/hash/格式/长度/配对失败、Registry 原子替换/旧完整快照、薄障碍/角点/全 int64 Y、动态同 XZ 不同高度/排除自身、矩形与奇数尺寸、移动原子性、Path 类型/高度/游标/实际步长、部分阻挡及预算部分提交、范围精确圆边界及目标靠边范围语义均通过|
|资源/失败|4096 对象、256 单对象关联、262144 总关联的真实容量边界；分配失败逐点注入保留旧状态；展开/touched/路点/桶/tests 边界及硬 65536 密集候选耗尽均通过，没有假成功|
|独立几何 oracle|3000 条确定随机连续段，全量扫描独立整数 slab 对照生产 DDA，覆盖负坐标、多体积、多方向、垂直/格线段、薄动态盒、首命中与有理数时间，全部通过|
|隔离/确定性|重复查询一致、Context 动态隔离、空桶证明只在当次固定高度查询内复用、两线程共享只读图各 100 次查询通过|
|真实 Lua + Python|固定 Skynet 修改版 Lua 5.4.7 + 实际 `.so`，Python unittest 9/9，无 skipped；含完整空中调用链、独立例子、nil/error、关闭/GC、旧快照、资产门禁损坏与包 hash|
|Unity Editor|团结引擎 1.10.0（2022.3.62t12），隔离派生工程实跑 EditMode 14/14，0 failed/0 skipped；包括旧 BMAP、Unity/Native 共用 golden、取整/闭边界/LayerMask/区间合并/错误 hash/发布身份/幂等/失败清理|
|Sanitizer|Debug 核心 AddressSanitizer + UndefinedBehaviorSanitizer + leak detection，CTest 3/3，通过；未屏蔽 sanitizer 错误|
|静态门禁|FlyWow `scripts/quality/check_repository.py` 成功；新增 C++ clang-format dry-run/Werror 成功；46 个相关路径的修改文本 UTF-8/LF 检查通过|

Lua 运行使用固定宿主 jemalloc 预加载，使独立解释器提供 Native 依赖的 `je_malloc` ABI；未替换生产 allocator 或系统 Lua。Native golden 与实际 Unity Writer 共享相同十六进制 fixtures，而非两个自造格式。

Unity 派生验证工程位于 Windows Codex artifact 目录，安装 WSL 源生成的内容标识 tgz；不复制为第二份可编辑源，不改宿主 manifest。实际结果 `airnav-validation/unity-results.xml` 和日志保留在 artifact 目录。

## Benchmark 环境和条件

CPU：Intel Core i5-10400F @ 2.90GHz；WSL Ubuntu/Linux；GCC 15.2.0；C++17；CMake RelWithDebInfo（核心 `-O2 -g -DNDEBUG`）。单线程顺序测量，500 mm 格，初始化/地图加载/障碍注册不计入热查询。空中每场景热身 10 次，然后连续 10000 次；地面各 10000 次，沿用原随机端点/15% 静态障碍算法。

空中原场景、墙长、障碍数量和请求不降低：open 80x60；detour 12x12 墙 6 格；long_detour 256x256 墙 230 格；wall_gap 12x12 墙 10 格；dense_dynamic 4096 对象；budget 512x512 明确调低 buckets=100 验证耗尽。首轮旧名字“unreachable”的 10 格墙实际留有可绕缺口，所以保留同条件重命名 wall_gap，另加覆盖全高 12 格墙作为真实 unreachable；未拿错误场景替换原压力。

默认/硬上限始终 expanded=4096、nodes=8192、buckets=8192、tests=65536、path_points=4096、objects=4096、object_links=256、links=262144。没有加大默认预算，没有跳过静态/动态候选，也没有按失败结果改成功条件。Benchmark 可执行程序对每场景 10000 次预期 OK/NO_PATH/QUERY_BUDGET_EXCEEDED 断言，不符合即非零失败。

### 优化依据

首轮相同原条件：短绕行/长绕行/10 格缺口均 10000 次 QUERY_BUDGET_EXCEEDED，桶计数达到 8192；4096 动态密集场景 10000 次 QUERY_BUDGET_EXCEEDED，tests 达到 65536。密集首轮 p50 8281 µs，long_detour 桶耗尽时 avg_expanded=5，无法交付合法路线。

修正的是算法/实现：DDA 子段只枚举实际水平包络；相邻格边一次连续包络避免重复桶；已关闭/已有不更差路线的邻居不再执行无用松弛验证；同 f 优先较大 g；单次固定高度查询复用已证明无高度候选的桶（缓存查找仍计 tests，真正重复空间桶访问仍计 buckets，动态更新/后续查询不复用）；平滑从最远点尝试、失败折半，避免逐点延长导致 O(n²) 连续扫掠。全部几何捷径仍完整 slab 验证，预算失败保留已验证路线，不返回未验证捷径。

最终原压力场景全部得到预期结果，长绕行不再依赖耗尽平滑预算返回原路线；实际 tests=13185。以下全部延迟单位为 µs；max 为本次单机样本最大值，不是 SLA。

|场景|地图|区间|动态对象|路径 mm|p50|p95|p99|max|展开|桶|tests|
|---|---|---|---|---|---|---|---|---|---|---|---|
|open|80x60|0|0|38500|9.6|9.7|25.2|74.9|0|78|238|
|detour|12x12|6|0|5447|39.9|42.4|63|445.2|31|105|554|
|long_detour|256x256|230|0|126562|1568.1|1692.3|1833.7|2353.6|1016|1677|13185|
|wall_gap|12x12|10|0|6159|64.9|76.3|106.2|312.6|44|142|789|
|unreachable|12x12|12|0|0|57.6|64.4|91.4|225|72|135|574|
|dense_dynamic|80x60|0|4096|38500|1052.1|1149.1|1263.1|2438.8|0|78|8430|
|budget|512x512|0|0|0|12|12.2|17|99.4|0|100|298|

每场景状态计数：open/detour/long_detour/wall_gap/dense_dynamic 各 OK=10000；unreachable NO_PATH=10000；budget QUERY_BUDGET_EXCEEDED=10000。病态大体积多桶重复 4096 候选的硬 tests 耗尽另由 Native 正确性测试覆盖。

### 内存

下面是结构/capacity/容器节点的估算，不是 RSS；树节点颜色/对齐、allocator metadata、外壳、临时/Path 等不完整计入。Context 总成本还包括原 ground dense scratch；本次没有把它改成空中专用轻量 Context。

|场景|静态 bytes|原 ground payload bytes|air Context estimate bytes|
|---|---|---|---|
|open|38576|288000|33008|
|detour|1552|8640|458992|
|long_detour|531632|3932160|458992|
|wall_gap|1776|8640|458992|
|unreachable|1776|8640|458992|
|dense_dynamic|38576|288000|1032432|
|budget|2097328|15728640|640|

空中 empty-cell 缓存、节点/堆/索引有界 reserve，规模依赖预算而非整图；开放直达只创建有界空桶证明缓存，不创建全图 air scratch。

### 同机 ground 基线

原 ground 查询算法未改。静态分析确认 ground 查询不调用空中空间索引/扫掠，不初始化 AirState；此次热查询测量的 air 内存全部为 0。下面是现有 ground 实现的同机测量，没有把它冒充修改前二进制 A/B 的性能证明。

|width|height|queries|success|p50|p95|p99|max|avg visited|payload bytes|air bytes|
|---|---|---|---|---|---|---|---|---|---|---|
|80|60|10000|10000|109.7|485.5|746.4|1883.5|253.808|288000|0|
|256|256|10000|10000|1255.5|5460.9|7622.99|17162.9|2393.69|3932160|0|
|512|512|10000|10000|4505|23221.7|31398.7|63347.4|9160.25|15728640|0|

## 可复查文件与复现

WSL 子模块 `build/reports/`：

- `air_final_build.txt`：统一构建和 CTest。
- `air_python_lua_tests.txt`：实际 Lua/示例与 Python 九项测试。
- `air_sanitizer_final.txt`：最终 ASan/UBSan/泄漏检测。
- `air_repository_check.txt`：仓库门禁。
- `air_benchmark_final.txt`、`ground_benchmark_final.txt`：原始最终采样。
- `air_evidence_sha256.json`：最终核心源码/构建产物/测试与采样证据 hash，便于识别本次验证版本。

独立真实 ABI 验证在 FlyWow 根目录运行：

```sh
LD_PRELOAD=../skynet/3rd/jemalloc/lib/libjemalloc.so.2 \
SKYNET_LUA=../skynet/3rd/lua/lua NAVIGATION_NATIVE_DIR=build/native \
python3 -m unittest discover -s navigation/tests -p 'test_navigation*.py'
```

`LD_PRELOAD` 提供固定 Skynet allocator ABI，`SKYNET_LUA` 显式选择固定解释器，`NAVIGATION_NATIVE_DIR` 是生成 `.so` 的相对路径；均为验证输入，不新增 Runtime 路径配置。Benchmark 用统一入口构建后的两个现有可执行目标顺序运行，避免同时采样干扰。

## 未验证及后续边界

没有接入正式宿主 Battle/Frame Core/弹丸，不测宿主 Tick SLA、网络/多场 Battle 调度或正式地图玩法可达性。没有实际 MSVC/Windows C++ 宿主构建，没有运行 ThreadSanitizer；共享只读图并发用真实 Native 多线程测试，内存/溢出由 ASan/UBSan 检查。未更新宿主 Unity 安装依赖、正式资产或发布到外部环境；后续接入按工作区规则处理。本次不执行 Git 同步/提交/推送。
