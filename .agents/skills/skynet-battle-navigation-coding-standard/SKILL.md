---
name: skynet-battle-navigation-coding-standard
description: 实现或评审本仓库源码、脚本、协议、配置、测试及教程可复制代码时，检查代码合同、ownership、资源边界与验证。
---

# 编码规范

本 Skill 只处理代码及可复制代码的质量。课程门禁、编辑权限和架构边界由 `AGENTS.md` 与当前任务的 Spec/Decision 决定。按当前改动的风险应用以下规则，不为无关文件补模板注释。

## 合同与注释

- 项目自有源码、脚本、协议、配置和构建文件在文件头用简短中文说明职责、所属运行边界、主要输入输出与不负责的事；职责变化时更新。代码标识符和稳定技术名词保留英文。
- 公开 API、跨模块入口、包含业务判断或隐含状态变化的函数，说明参数的业务意义与单位、返回/错误、ownership，以及可能的 I/O、分配、锁、yield 和共享状态变化。简单访问器不要求逐项注释。
- 在变量定义处注释不能仅从名称和类型看出的业务含义，尤其是来源、单位、owner/生命周期、默认值的原因、哨兵值和状态变化。显而易见的短期循环计数器或仅在几行内使用的临时值不写重复注释；禁止用注释复述变量名或类型。
- 同一逻辑组的变量声明按列对齐变量名、赋值符和行尾注释；Lua 多行具名 table 按列对齐字段名和赋值符。只对齐同一组连续声明，不跨空行或无关逻辑维持空格。
- 在不能从名称和代码直接看出的地方解释 WHY 与不变量，尤其是坐标/取整、二进制格式、fd/buffer 生命周期、Skynet yield 后身份重验、路径/动态占位、资源上限和过载行为。复杂换算可用一个短输入/输出例子；避免逐行翻译代码。
- 公式或紧凑换算进入源码注释时，先说明变量、单位、原点/边界和直接关系，再说明整理或变形的原因；关键常数（例如半格偏移、字节偏移、取整方向）必须写出 WHY，并给一个可复算的短例子。不能只留下最终公式，让读者自行猜测公式如何从业务含义得到。
- 修改公开合同或持久数据格式时，同步受影响的调用方、示例、版本/兼容说明和测试。
- 整理或重构已有代码时保留仍然有效的原注释与解释；只修正与新合同冲突的部分，不以“精简”为由整段删除。
- 值与标记必须解释业务语义：枚举值、状态值、命令字符、位标记、数字等级和缩写的注释，必须说明每个值代表什么以及会触发什么行为；禁止只罗列符号或数字。内部编码应封装在具有业务语义的常量或函数后，调用处不得直接拼接或解释协议字符、魔法数字和位标记。

## 命名规则

- C++ 类型（class、struct、enum、type alias）使用 PascalCase；自由函数和成员函数使用 lowerCamelCase；命名空间、局部变量、参数和普通变量使用 snake_case；类私有成员使用 snake_case_；具有固定程序期值的常量及枚举项使用 kPascalCase；宏使用带项目名前缀的 UPPER_SNAKE_CASE；C++ 源文件使用小写 snake_case。
- Lua 脚本中的函数、局部变量、参数、模块字段和普通 record 字段使用 snake_case；常量使用 UPPER_SNAKE_CASE；LuaDoc 类型名使用 PascalCase。Lua 对外模块入口、Service 名和文件名沿用项目既有的 flywow_<module> 等合同。
- Lua 可见的公开字段和函数名使用 snake_case。Native C++ 的内部函数名遵守 C++ 规则；注册到 Lua 时显式映射到 Lua 名称，不强求跨语言内部标识符拼写一致。
- luaopen_* 等 C ABI 符号遵守 Lua 加载合同，不改写大小写规则。稳定协议字段、配置键或历史公开合同按其格式约定，不为统一代码风格而擅自重命名。
- 新代码统一按以上规则编写；修改旧代码时只整理当前任务涉及的标识符，并同步受影响的调用点，不借规则进行全仓批量改名。

变量示例：

```cpp
std::uint32_t map_id      = 0; // 请求指定的地图 ID；0 由上层合同判为无效。
std::uint32_t map_version = 0; // 与 map_id 配对的不可变地图版本。
```

```lua
local state =
{
    map_id      = map_id,
    map_version = map_version,
}
```

## IDE 可读的注释

- C++ 公开类型和 API 使用 Doxygen 兼容的 /// 注释及 @param、@return、@note 等标准标签，使 clangd、Visual Studio 等 IDE 能在悬浮提示中显示合同。中文说明写清语义、失败与 ownership；不要求额外引入 Doxygen 文档生成器。
- C++ 实现内部使用普通 // 或块注释解释局部 WHY、栈变化和资源边界；这些注释贴近对应操作，不用 @param 等 API 标签，也不重复公开声明中的合同。
- Lua 源码使用 Lua Language Server 可识别的 LuaDoc/EmmyLua 标准标签；注释与结构化类型只维护一份，避免 IDE 看不到的自定义标签及重复普通注释。
- 注释要适配 IDE 的源码解析：标签写在其所描述的声明之前，避免把 API 合同只写在调用点、Markdown 或无法识别的自定义格式中。

## Lua C API 内部注释

- Binding 封装内部使用 Lua C API 时，必须用中文注释讲清非显然的栈行为与资源生命周期；调用方 API 虽隐藏 C API，不能因此省略封装内部说明。
- 对关键操作组给出栈变化示意，例如 [S, table] -> [S, table, value]，说明进入/离开时的栈高度、哪个值被压入/消耗/保留，以及错误和提前返回如何恢复。S 表示操作开始前已有的栈内容。
- 解释绝对索引固定的原因、负索引在压栈后的变化、rawget 与会触发元方法的访问区别、lua_next 每轮保留的 key 与移除的 value。
- 涉及 luaL_ref/luaL_unref 时说明 Lua 引用由谁持有、何时释放，以及对象析构为何不会误删仍在 Lua 栈或其它引用中的结果。
- 涉及 closure/upvalue、metatable、full userdata、placement-new、__gc 时说明内部 upvalue 与业务 upvalue 的边界、对象构造状态、析构次数和内存释放责任。
- 涉及可能通过 longjmp 离开 C 函数的 Lua 错误 API 时说明 C++ 对象析构风险及调用边界；Binding 参数错误路径使用普通返回值时说明结果如何交给 Lua。
- 在集中实现处完整讲清一项机制，调用处只注释其特定输入或业务约束；不逐行翻译每个 API，也不在每个调用点重复同一套栈教程。

## C++ Lua Binding 错误合同

- 公开 Binding API 的可预期失败统一返回 `nil, { code = ..., message = ... }`；参数类型、范围、对象类型/生命周期及领域操作失败都遵循同一合同，不使用 `luaL_error` 或 `luaL_check*` 将 API 错误转换为 Lua 异常。模块加载阶段的 Lua ABI 校验属于加载前置条件，不是调用方 API 错误。
- 参数读取 helper 应返回成功状态并写入输出值；C 入口发现失败后返回两个 Lua 值。错误构造集中使用 `push_error`，Native 领域错误沿用稳定错误码并转换为相同 record。
- Lua 调用方必须检查第一个返回值；失败时按稳定 `code` 处理或传播错误，不能把 `nil` 当作可用结果继续执行。Binding 测试应验证错误以返回值交付，而不是依赖 `pcall` 捕获参数异常。

## 可读性硬规则

- 一个函数内存在两个或以上逻辑阶段时，阶段之间必须使用空行分隔，并在非显然处用短注释说明阶段目的；不得把参数校验、资源创建、核心处理和结果转换连续堆成一个无分段代码块。
- 一个函数连续超过 20 行且包含两个或以上可独立命名的动作时，必须拆成语义明确的私有函数；仅有简单线性赋值或同一循环主体时可保留，但仍须按阶段空行分组。
- 空行用于表达逻辑边界，不得为了“看起来整齐”在每行之间插入空行；连续代码块应服务于同一不变量或同一资源生命周期。
- 代码评审发现长函数无法快速看出输入、状态变化、核心算法和输出边界时，视为可读性未完成，即使编译和测试通过也不能标记完成。


### LuaDoc 与编辑器可读性

- Lua 源码中的文件职责、函数合同、字段合同和 Service 消息合同统一使用 LuaDoc：说明行使用 `---`，结构化类型使用标准 `---@param`、`---@return`、`---@class`、`---@field`、`---@alias` 标签；不要为同一合同同时维护普通 `--` 注释和 LuaDoc。
- 跨 Service 的 request/result record、配置 record 和异步响应上下文必须有可被 Lua Language Server 识别的类型定义；字段说明同时写清来源、owner、生命周期、nil 语义和是否跨进程/网络边界。
- `skynet.call`、`skynet.send`、`skynet.dispatch` 等动态 API 的稳定调用必须标注 Service handle、command、payload、返回值和 yield 边界；框架 API 提示使用独立 `---@meta` stub，不把 stub 当作运行时代码。
- LuaDoc 描述负责让编辑器和人理解同一份合同；不要使用编辑器不认识的自定义标签表达唯一的类型语义。WHY、ownership、I/O、yield、失败和不变量写在同一 LuaDoc 块的中文说明中。
- 动态 command 字符串必须有 `---@alias` 或明确的消息 record；不能只依赖字符串字面量和运行时 `assert` 让读者反推调用合同。

## 实现边界

- Service handle、资产、随机源和外部连接显式传递；不靠全局服务名、当前目录或开发机绝对路径隐藏依赖。
- 可能 yield 的函数明确标注；跨 yield 不保留未经重验的业务对象、fd 身份或借用 buffer。Native 可变查询状态按调用或 Battle 隔离，或显式同步。
- 队列、frame、client、request、retry、timer、cache 和 payload 有明确上限及拒绝/降级行为。错误以稳定结果返回，不靠日志文本或沉默默认值表达状态。
- 稳定 Lua 业务 API 使用具名参数/record。仅在真正转发未知签名的基础设施中使用 `...`；跨异步/yield 边界前固定参数个数、nil 语义与 ownership，并测试。不要从 Service dispatch 原样转发 `...` 给业务函数。
- Shell/PowerShell 与构建脚本说明工作目录、环境变量和进程生命周期等非显然边界。下载固定版本并校验；FlyWow 等已确定为 submodule 的依赖遵循其现有机制。涉及 FlyWow 抽取读 `docs/FLYWOW_EXTRACTION_POLICY.md`；涉及热更须验证版本、状态迁移、失败回滚和对象生命周期。

## 教程与验证

- 教程中的完整可复制代码按真实源码标准编写；步骤标明新建、完整替换、局部修改或只读，并能从上一步的真实基线继续。教学结构另见 `docs/CODEX_TEACHING_GUIDE.md`。
- 按影响范围编译、运行聚焦测试，并在适用时验证失败路径、资源释放、确定性、并发与 yield/ownership。报告区分静态检查、编译、单元测试、集成运行及未验证项；未运行的验证不写成“通过”。

## Lua 外部入口与 Native 产物命名

FlyWow 模块的 Lua 外部入口使用 `flywow_<module>.lua`，业务侧通过 `require "flywow_<module>"` 加载；对应的 C++ Lua Binding 使用 `flywow_<module>_native.so` 和 `luaopen_flywow_<module>_native`。Wrapper 与 Native 必须使用不同模块名，避免 Lua 搜索路径优先命中 Wrapper 后递归加载自身。

FlyWow 最终 Lua Native `.so` 统一放在 FlyWow 子模块的 `build/native/`，CMake 中间文件放在 `build/cmake/<module>/`。首次出现跨模块或跨语言的 `require` 时，必须说明源文件、构建脚本、可复制命令、生成物位置、运行时路径配置以及 Wrapper 到 Native 的加载链路。

## FlyWow Runtime 路径与构建入口

- Server 固定从 server/third_party/skynet-flywow submodule 使用 FlyWow；Lua/C 搜索路径在各自 Skynet process config 中以相对路径直接列出，路径基准明确为 Server 工作目录。
- 不为可由相对路径表达的目录增加 FLYWOW_ROOT、FLYWOW_PATHS_CONFIG 等 Runtime 环境变量，不新增 module_paths.py 或生成式 Lua 搜索路径配置。
- Gateway、Battle 等 OS 进程只配置自己实际使用的模块；Gateway service/lualib 不进入 Battle 搜索路径。
- FlyWow Native 统一由 submodule/scripts/build_flywow.sh 构建；宿主公开入口为 server/scripts/linux/run_server.sh build。中间文件位于 FlyWow build/cmake/<module>/，最终 .so 统一位于 FlyWow build/native/。
- 新增 Native 模块时接入统一构建入口；只有出现独立调用者和独立生命周期后，才考虑增加公开 Shell 入口。

## Shell 脚本规范

Server 脚本按公开入口、宿主辅助和课程专用分层，文件名统一使用“动作_对象.sh”。新脚本应使用 `run_server.sh`、`prepare_lesson_01.sh`、`run_lesson_02_processes.sh` 等明确名称，禁止新增无对象的 `build.sh`、`make.sh`、`run.sh`、`test.sh` 和 `prepare.sh`。

每个 `.sh` 文件头必须说明职责、边界、调用者、调用时机、参数、输入、产物、副作用和失败行为，并给出完整调用示例。课程脚本放在 `server/scripts/lessons/`，FlyWow 模块构建必须通过 submodule 的公开脚本调用。
