---
name: skynet-battle-navigation-coding-standard
description: 实现或评审 Skynet Battle Navigation 的 C#、C++、Lua、Shell、PowerShell、Proto、CMake、配置、测试或可复制教程代码时，应用 P0 中文注释、API 合同、ownership、资源上限和验证规范。
---

# Skynet Battle Navigation 编码规范

本 Skill 是源码、构建/部署脚本、协议、配置、测试和教程中可复制完整代码的发布门槛。

它只负责**代码质量与实现合同**。Lesson 顺序、工作区、FlyWow 抽取和教学规则分别由以下文件负责：

```text
AGENTS.md
codex/LESSON_xx_SPEC.md
docs/WORKSPACE_WORKFLOW.md
docs/FLYWOW_EXTRACTION_POLICY.md
docs/CODEX_TEACHING_GUIDE.md
```

源码注释、工程文档、教程说明使用中文；代码标识符、协议字段、命令、日志 key 和稳定技术名词保留英文。

## 1. 修改前

读取 `AGENTS.md` 和当前任务直接相关的合同，不要求为了普通代码修改遍历全部 `docs/` / `codex/`。

确认：

- 当前概念是否已到对应 Lesson；
- Authoring / Asset / Client Runtime / Server Runtime / Build / Test 边界；
- Service、Lua State、native object、fd、buffer、GridMap、NavigationContext、动态状态 owner；
- I/O、分配、锁、Skynet call/send、yield 边界；
- 版本、hash、坐标系、单位、资源上限和显式失败合同；
- 现有调用方与测试。

没有真实调用者和可测试合同时，不新建推测性 interface、Manager、Service、DTO 或目录树。

## 2. 文件头合同

每个项目自有源码、脚本、协议、配置和构建文件必须在文件头用中文说明：

```text
本文件解决的问题
所属边界
主要输入和输出
生命周期、ownership 或运行时机
明确不负责的事情
```

不写容易失真的作者、日期、手工版本号，也不逐句翻译代码。

文件职责或边界变化时同步更新文件头。

## 3. 函数合同

每个函数、方法、构造函数和可执行/脚本入口前必须说明职责。

公开 API、跨模块入口和包含领域判断的私有函数还要写清：

- 每个参数的业务意义、单位、坐标系、范围和 ownership；
- 返回状态、返回对象 ownership；
- 显式失败条件、错误码或异常；
- 是否 I/O、分配内存、加锁、yield、修改共享状态；
- 适用时的前置条件、复杂度和调用时机。

简单无参数、无失败分支的薄访问器可用一行，不允许完全无说明，也不允许模板注释淹没关键合同。

## 4. 字段、变量和关键 WHY

每个非显然字段、配置项和局部变量说明：

```text
用途
单位/范围
owner / 生命周期
是否跨资产、存储或网络边界
```

函数内部在对应逻辑前解释领域 WHY 和不变量，至少覆盖适用的：

- 坐标换算、取整、Cell/index、2.5D 限制；
- byte offset、length、endian、CRC、协议版本；
- framing、半包/粘包、buffer ownership、fd 复用和 close race；
- Service ownership、消息参数来源、yield 后身份重验；
- A* 不变量、动态占位事实与业务规则、Path 失效；
- Unity 空间、Bake 输入、资产布局和 Server 权威边界；
- queue/frame/client/request/retry/timer/cache 上限与过载行为。

注释按读者理解代码的顺序组织：先用直白的一句话说明函数或代码块要解决什么问题、产生什么结果；再说明参数/状态的意义、单位、前置条件和 ownership；最后解释关键算法步骤及必须保持的不变量。不要一开始就抛计算细节，让读者先猜代码用途。

对公式、坐标换算、插值、索引映射、边界遍历等不容易凭名称理解的逻辑，优先补一个短小的输入/输出例子，再讲实现细节。例如：`origin=100`、`target=500`、`progress=100`、`length=400` 时，插值坐标为 `200`。简单直观的赋值、循环或返回不需要为了形式补例子；也不要逐行翻译语法或把教程正文整段搬进源码注释。

禁止无效注释：

```cpp
// 遍历数组
for (...) {}

// 返回结果
return result;
```

## 5. API 与依赖规则

- 保持 `AGENTS.md` 规定的依赖方向；基础模块不导入 Battle/SLG 业务 DTO，Gateway 不依赖地图内部实现。
- 配置、Service handle、地图资产、随机源、外部 Adapter 显式注入，不用全局名字、当前目录或开发机绝对路径隐藏必要依赖。
- 公开结果和失败必须显式、可版本化；不用日志字符串、沉默默认值或进程退出替代未记录的多状态 API。
- 可能 yield 的函数在合同中声明；不跨 yield 保存 borrowed buffer、fd identity 或未重验业务对象。
- queue/frame/client/request/retry/timer/cache 必须有明确上限，并定义拒绝、降级或背压行为。
- 多个 Skynet Service 可能在不同 OS Thread 调用 native module；process-global mutable scratch 必须禁止或显式同步。
- 跨端协议、BMAP/manifest 和生成物使用单一版本化源、内容 hash 和原子发布语义；Runtime 不读取 Unity 工程或临时 Bake 目录。
- 示例只使用当前步骤已经引入的公开 API，不为缩短篇幅跳过 ownership、校验、错误处理或文件操作类型。

## 6. Lua 稳定接口禁止滥用 `...`

项目自有 Lua 稳定 API 默认不使用 `...` 作为长期参数/返回转发合同。

优先：

```text
固定位置参数
command + request record
明确 result record
```

Skynet/C 模块确实返回可变参数时，适配层用固定数量命名槽接收，并按 command/event 映射到语义函数。

禁止：

- 从 Service dispatch 把 `...` 原样继续传给业务函数；
- 用 `table.pack(...)` / `{...}` 隐藏未定义长期接口；
- 把可变参数保存到闭包、table、异步任务或跨 yield 使用；
- 仅因 Skynet 示例这么写就保留动态签名；
- 教程完整代码用 `...` 代替已知业务参数。

只有职责本身就是“转发未知签名”的通用基础设施才可申请局部例外；例外必须写明 WHY、参数/ownership 约束，并有参数数量、nil 洞、返回值和 yield 测试。

## 7. Shell / PowerShell / 构建脚本

脚本同样是课程源码，不是黑盒命令。

文件头和函数入口遵守前述合同；关键命令解释 WHY，尤其：

```text
set -euo pipefail / ErrorActionPreference
脚本目录推导与当前目录无关性
curl 下载固定版本、-fL、重试、临时文件
解压目录与原子移动
.pinned-tag / .pinned-commit / manifest / hash
make / cmake / compiler / gdb
exec / nohup / PID / lock / SIGTERM 生命周期
环境变量对子进程与 Skynet Service 的作用域
```

第三方源码快照默认使用 `curl` + 固定 tag/commit 下载并校验；不要把“初始化依赖”同时维护成 `git clone` 和下载快照两套语义，除非当前仓库明确使用 Git submodule（例如 FlyWow）。

## 8. FlyWow 热更/框架修改

涉及 FlyWow 热更时必须验证：

```text
版本兼容
状态迁移
失败回滚
对象生命周期
```

清空 `package.loaded` 不能被描述成完整热更合同。

涉及从课程抽取 FlyWow 模块时，另读：

```text
docs/FLYWOW_EXTRACTION_POLICY.md
```

## 9. 文档中的完整代码

教程里的可复制代码与真实源码使用同一质量门槛：

- 文件步骤标明新建/完整替换/局部修改/只读；
- 累计代码能从上一阶段真实基线继续修改；
- 公开签名、文件头、注释、测试和调用例同步；
- 不用省略号替代当前步骤必须掌握的关键代码；
- 不为展示“最终架构”提前加入未来模块。

教学结构本身见：

```text
docs/CODEX_TEACHING_GUIDE.md
```

## 10. 验证门槛

声明完成前按影响范围执行：

1. 构建受影响的 Unity/C#/Native/Lua/生成器 target；
2. 运行聚焦的成功、边界和失败路径测试；
3. 适用时验证资源上限、释放路径、确定性、并发和 yield/ownership；
4. 同步文件头、公开 API 示例、教程步骤、测试、版本/兼容说明；
5. 逐个检查变更函数和字段的合同注释；
6. 最终报告明确区分静态检查、编译、单元测试、集成运行和未验证项。

缺少合同注释或把未验证内容写成“通过”，视为 P0 未完成。
