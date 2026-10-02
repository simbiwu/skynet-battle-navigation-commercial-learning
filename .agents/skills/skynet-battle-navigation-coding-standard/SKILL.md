---
name: skynet-battle-navigation-coding-standard
description: 实现或评审本仓库源码、脚本、协议、配置、测试及教程可复制代码时，检查代码合同、ownership、资源边界与验证。
---

# 编码规范

本 Skill 只处理代码及可复制代码的质量。课程门禁、编辑权限和架构边界由 `AGENTS.md` 与当前任务的 Spec/Decision 决定。按当前改动的风险应用以下规则，不为无关文件补模板注释。

## 合同与注释

- 项目自有源码、脚本、协议、配置和构建文件在文件头用简短中文说明职责、所属运行边界、主要输入输出与不负责的事；职责变化时更新。代码标识符和稳定技术名词保留英文。
- 公开 API、跨模块入口、包含业务判断或隐含状态变化的函数，说明参数的业务意义与单位、返回/错误、ownership，以及可能的 I/O、分配、锁、yield 和共享状态变化。简单访问器和显然的局部变量不要求逐项注释。
- 在不能从名称和代码直接看出的地方解释 WHY 与不变量，尤其是坐标/取整、二进制格式、fd/buffer 生命周期、Skynet yield 后身份重验、路径/动态占位、资源上限和过载行为。复杂换算可用一个短输入/输出例子；避免逐行翻译代码。
- 修改公开合同或持久数据格式时，同步受影响的调用方、示例、版本/兼容说明和测试。

### LuaDoc 与编辑器可读性

- Lua 源码中的文件职责、函数合同、字段合同和 Service 消息合同统一使用 LuaDoc：说明行使用 `---`，结构化类型使用标准 `---`、`---`、`---`、`---`、`---` 标签；不要为同一合同同时维护普通 `--` 注释和 LuaDoc。
- 跨 Service 的 request/result record、配置 record 和异步响应上下文必须有可被 Lua Language Server 识别的类型定义；字段说明同时写清来源、owner、生命周期、nil 语义和是否跨进程/网络边界。
- `skynet.call`、`skynet.send`、`skynet.dispatch` 等动态 API 的稳定调用必须标注 Service handle、command、payload、返回值和 yield 边界；框架 API 提示使用独立 `---` stub，不把 stub 当作运行时代码。
- LuaDoc 描述负责让编辑器和人理解同一份合同；不要使用编辑器不认识的自定义标签表达唯一的类型语义。WHY、ownership、I/O、yield、失败和不变量写在同一 LuaDoc 块的中文说明中。
- 动态 command 字符串必须有 `---` 或明确的消息 record；不能只依赖字符串字面量和运行时 `assert` 让读者反推调用合同。

## 实现边界

- Service handle、资产、随机源和外部连接显式传递；不靠全局服务名、当前目录或开发机绝对路径隐藏依赖。
- 可能 yield 的函数明确标注；跨 yield 不保留未经重验的业务对象、fd 身份或借用 buffer。Native 可变查询状态按调用或 Battle 隔离，或显式同步。
- 队列、frame、client、request、retry、timer、cache 和 payload 有明确上限及拒绝/降级行为。错误以稳定结果返回，不靠日志文本或沉默默认值表达状态。
- 稳定 Lua 业务 API 使用具名参数/record。仅在真正转发未知签名的基础设施中使用 `...`；跨异步/yield 边界前固定参数个数、nil 语义与 ownership，并测试。不要从 Service dispatch 原样转发 `...` 给业务函数。
- Shell/PowerShell 与构建脚本说明工作目录、环境变量和进程生命周期等非显然边界。下载固定版本并校验；FlyWow 等已确定为 submodule 的依赖遵循其现有机制。涉及 FlyWow 抽取读 `docs/FLYWOW_EXTRACTION_POLICY.md`；涉及热更须验证版本、状态迁移、失败回滚和对象生命周期。

## 教程与验证

- 教程中的完整可复制代码按真实源码标准编写；步骤标明新建、完整替换、局部修改或只读，并能从上一步的真实基线继续。教学结构另见 `docs/CODEX_TEACHING_GUIDE.md`。
- 按影响范围编译、运行聚焦测试，并在适用时验证失败路径、资源释放、确定性、并发与 yield/ownership。报告区分静态检查、编译、单元测试、集成运行及未验证项；未运行的验证不写成“通过”。
