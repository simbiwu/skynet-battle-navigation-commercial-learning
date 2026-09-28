---
name: skynet-battle-navigation-coding-standard
description: 实现或评审 Skynet Battle Navigation 课程的 C#、C++、Lua、Shell、PowerShell、Proto、CMake、配置、测试或可复制教程代码时，应用 P0 中文注释、API 合同、ownership 和验证规范。
---

# Skynet Battle Navigation 编码规范

本 Skill 是课程源码、构建/部署脚本、协议、配置、测试、教程中可复制完整代码和代码评审的发布门槛。它不改变根 `AGENTS.md` 规定的三课教学顺序、双工作区编辑源或 FlyWow 独立仓库边界。

源码注释、工程文档、教程说明和示例说明使用中文。代码标识符、协议字段、命令、日志键和稳定技术名词保留英文。

## 修改前

完整阅读根 `AGENTS.md` 和受影响课程/模块的合同，确认：

- 本概念是否已到规定课时，不提前铺未使用抽象；
- Authoring、Asset、Client Runtime、Server Runtime、Build、Test 的所属边界；
- Service、Lua State、native 对象、fd、buffer、GridMap、NavigationContext 和动态状态的 owner；
- I/O、内存分配、锁、Skynet call/send 和 yield 边界；
- 版本、哈希、坐标系、单位、资源上限和显式失败合同；
- 文档步骤与当前累计源码基线是否能直接衔接。

没有当前真实调用者和可测试合同时，不新建推测性 interface、Manager、Service、DTO 或目录树。

## P0 源码合同

每个源码、脚本、协议、配置和构建文件必须在文件头用中文说明：

```text
本文件解决的问题
所属边界
主要输入和输出
生命周期、所有权或运行时机
明确不负责的事情
```

每个函数、方法、构造函数和可执行/脚本入口前必须有中文合同注释。公开 API、跨模块入口和包含领域判断的私有函数还要说明：

- 解决的具体问题；
- 每个参数的业务意义、单位、坐标系、合法范围和 ownership；
- 返回状态、返回对象的 ownership 和失败方式；
- 是否执行 I/O、分配内存、加锁、yield 或修改共享状态；
- 适用时的前置条件、复杂度和调用时机。

每个字段、配置项和非显然局部变量要说明用途、单位/范围、owner、生命周期，以及是否跨越资产、存储或网络边界。紧凑 record 优先同行短注释；ownership、不变量和多步计算放在相邻上方。

函数内部在对应逻辑之前解释领域 WHY 和不变量，至少覆盖适用的：

- 坐标换算、取整方向、Cell/index 和 2.5D 限制；
- byte offset、length、endian、CRC 和协议版本；
- socket framing、半包/粘包、buffer ownership、fd 复用和 close race；
- Service ownership、消息参数来源、yield 后身份重验；
- A* 不变量、动态占位事实与业务规则、缓存 Path 失效；
- Unity 空间、Bake 输入、资产数据布局和 Server 权威边界；
- 有界 queue、frame、client、request、retry、timer 和 cache 的过载行为。

禁止只翻译语法的注释、容易失真的作者/日期/手工版本头，以及用大段模板文字掩盖关键合同。

## API 和实现规则

- 保持根 `AGENTS.md` 规定的单向依赖；基础模块不导入 Battle/SLG 业务 DTO，Gateway 不依赖地图。
- 配置、Service handle、地图资产、随机源和外部适配器显式注入，不用全局服务名、当前目录或开发机绝对路径隐藏必要依赖。
- 公开结果和失败必须显式、可版本化；不用日志文字、沉默默认值或进程退出表达未记录的多状态 API。
- 稳定 Lua API 使用命名参数或带注解的 request/result record；项目自有稳定接口不使用或转发 `...`。
- 可能 yield 的函数必须在合同中声明，不跨 yield 保存 borrowed buffer、fd 身份或未重验的业务对象。
- queue、frame、client、request、retry、timer 和 cache 必须有明确上限；达到上限时要定义拒绝、降级或背压行为，不能无限增长。
- 涉及 FlyWow 热更时，必须验证版本兼容、状态迁移、失败回滚和对象生命周期；清空 `package.loaded` 不能充当完整热更合同。
- 多个 Skynet Service 可在不同 OS Thread 调用 native module；process-global mutable scratch 必须禁止或有明确同步。
- 跨端协议、BMAP/manifest 和生成物使用单一版本化源、内容哈希和原子发布语义；运行时不读取 Unity 工程或临时 Bake 目录。
- 示例只使用当前步骤已引入的公开 API，不为缩短篇幅跳过 ownership、校验、错误处理或文件操作类型。

## 文档与源码同步

- 教程是独立发布文档，不写入当前聊天、开发机状态或只对某个工作区成立的措辞。
- 每个文件步骤标明新建、完整替换、局部修改或只读，并先说明当前问题、直接使用者和可观察结果。
- 文档中的累计代码必须能从前一节已完成源码直接修改得到；公开签名、文件头、注释、测试和调用例同步变更。
- 完整代码前提供学习导航；代码注释解释当前逻辑的 WHY，不代替正文建立概念。

## 验证门槛

声明完成前必须：

1. 构建受影响的 Unity/C#/Native/Lua/生成器 target。
2. 运行聚焦的成功、边界和失败路径测试。
3. 适用时验证资源上限、释放路径、确定性和 yield/ownership 行为。
4. 同步更新文件头、公开 API 示例、教程步骤、测试、版本/兼容说明。
5. 逐个检查变更函数和字段；缺少合同注释视为 P0 失败。
6. 最终报告区分静态检查、编译、单元测试、集成运行和尚未验证项，不把其中一种写成另一种。
