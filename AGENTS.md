# AGENTS.md - Skynet Battle Navigation 全局规则

本文件只保存**所有任务都必须遵守的硬规则、编辑边界和文档路由**。课程细节、架构决策、教学展开和模块抽取策略分别放在 `codex/` 与 `docs/` 中，不在这里重复。

## 1. 项目定位

主线：

```text
Unity / 团结引擎 Authoring
-> Versioned Server Navigation Asset
-> C++ Native Navigation
-> Skynet Server-authoritative Battle
-> Unity Replay / Presentation
```

功能可以按课程范围缩小，但不能用 Demo 捷径破坏 ownership、错误合同、资源上限、版本校验、测试和可演进边界。

本仓库是独立项目，不合并 `Skynet-slg-learning` 业务代码。`Skynet-slg-learning` 只可作为教学组织和工程纪律参考。

## 2. 固定技术基线

除非用户明确要求升级，否则不得静默改变：

```text
Server: Skynet v1.8.0
Lua:   Skynet bundled modified Lua 5.4.7
C++:   C++14
Build: CMake / Linux / WSL2
Client Editor: 团结引擎 1.10.0（Unity 2022.3 LTS 技术基线）
AI Navigation: com.unity.ai.navigation@1.1.7
Lesson 4 optional: Recast Navigation v1.6.0
```

版本、依赖与历史决策以 `docs/ENGINEERING_DECISIONS.md` 为准。

## 3. 修改权限与 Git 安全

没有用户明确的“开始、修改、实现、更新、执行、同步”等指令时：

```text
只分析、解释和给方案；不修改文件。
```

没有用户明确要求时：

```text
不 commit
不 push
不 force push
不改远端分支
不覆盖另一工作区未提交内容
```

涉及 Windows / WSL 双工作区、编辑源、同步、提交或 Push 时，必须先读取：

```text
docs/WORKSPACE_WORKFLOW.md
```

## 4. 代码任务必须加载编码规范

新增、修改或评审以下内容前：

```text
C# / C++ / Lua / Shell / PowerShell / Proto / CMake
配置 / 测试 / 可复制教程代码
```

必须读取并应用：

```text
.agents/skills/skynet-battle-navigation-coding-standard/SKILL.md
```

代码注释、函数合同、ownership、Lua `...` 限制、Shell 说明和验证门槛都由该 Skill 负责；不要在本文件重复展开。

## 5. 全局工程边界

以下规则跨 Lesson 长期有效。

### 5.1 Server 权威

Client 只提交输入意图和表现需求。正式位置、路径、技能合法性、命中、伤害、HP、死亡和逻辑事件由 Server 决定。

Client 结果不得覆盖 Server 结果。

### 5.2 正式业务坐标

长期业务合同使用整数世界/逻辑坐标、`map_id`、`map_version` 和内容 hash。

不得把下列实现细节泄露为长期 Battle / Persistence / Replay 合同：

```text
GridPos
grid_z
dtPolyRef
某个客户端坐标轴
```

具体空间合同见：

```text
docs/ENGINEERING_DECISIONS.md
docs/NAVIGATION_ABSTRACTION.md
```

### 5.3 Static / Dynamic 分离

静态地图资产加载后保持 immutable；每场 Battle 的 occupancy、reservation、单位状态等动态数据由该 Battle 自己拥有。

禁止把动态单位写入共享静态地图。

### 5.4 Native 并发

多个 Skynet Service 可能在不同 OS Thread 调用同一 Native Module。

因此：

```text
immutable static asset 可以共享
global mutable A* / Detour scratch 禁止
每个 query / battle 的 mutable context 必须隔离或显式同步
```

### 5.5 Skynet 运行身份决定目录

```text
service/  只放 skynet.newservice / uniqueservice 启动的 Service 入口
lualib/   只放当前 Service Lua State 内 require 的普通模块
protocol/ 放协议源、版本清单和生成物
config/   放进程配置和只读业务配置
```

不要用 `worker`、`agent`、`gateway` 等名字把普通模块伪装成 Service。

Service handle 优先由启动者保存并显式注入；不要用全局服务名隐藏本可显式传递的依赖，也不要让 Service `skynet.call` 自己。

### 5.6 依赖方向

保持单向、可解释的依赖：

```text
composition root
  -> 独立基础模块
  -> 少量稳定公共合同
  -> 固定运行时依赖

业务模块 -> 基础模块
基础模块 -X-> Battle/SLG 具体业务
Gateway -X-> 地图/导航内部实现
地图/导航 -X-> 网络
Battle Core -X-> Client DTO / Unity / H5 表现层
```

`common` 只容纳真正稳定、被多个模块共同需要的最小合同，不能成为无归属代码和循环依赖的收容目录。

### 5.7 跨端合同

仓库根目录 `shared/` 是课程阶段的版本化发布边界：

```text
shared/protocol/    唯一 .proto 源、固定工具版本、可验证生成物
shared/navigation/  验证通过并准备发布的导航资产与 manifest
```

Server Runtime 不读取 Unity `Assets/`、Library、临时 Bake 目录或开发机绝对路径。

协议和资产必须保留版本、hash、兼容性和原子发布语义。

### 5.8 不提前制造抽象

只有当前出现真实调用者、第二种实现或可测试合同后，才抽取稳定接口。

禁止为了“商业级”提前创建未来式 interface、Manager、Service、DTO、目录树或 placeholder。

## 6. Lesson 门禁

课程顺序以以下文件为准：

```text
docs/COURSE_ROADMAP.md
codex/LESSON_01_SPEC.md
codex/LESSON_02_SPEC.md
codex/LESSON_03_SPEC.md
codex/LESSON_04_OPTIONAL_RECAST_SPEC.md
```

只保留下面四条全局门禁：

```text
Lesson 1: 只完成地图生产、BMAP、C++ GridMap、Skynet Query；不提前实现 A* / AgentProfile / Path / NavigationContext / INavigationBackend。
Lesson 2: 由真实 FindPath/Battle 需求引入 A*、AgentProfile、Path、NavigationContext、DynamicOccupancy、BattleWorker；不提前实现 Lesson 3 技能和空中系统。
Lesson 3: 完成 Server 权威交互战斗；不引入 Recast/Detour，不接受客户端权威位置/命中/伤害。
Lesson 4 optional: 第一次真实接入第二种导航实现时再形成 Grid/Detour 双 Backend。
```

具体完成条件不要从本文件推断，必须读取对应 Lesson Spec。

## 7. FlyWow 边界

课程仓库通过：

```text
server/third_party/skynet-flywow
```

Git submodule 固定已验证的 FlyWow 提交。

涉及以下事项时必须读取：

```text
docs/FLYWOW_EXTRACTION_POLICY.md
```

包括：

```text
FlyWow 独立仓库开发
FLYWOW_ROOT 覆盖
课程能力何时可抽取
模块公开合同
依赖限制
迁移/测试/提交边界
```

Gateway、地图、导航和战斗模块不得因“抽取框架”而互相增加不必要依赖。

## 8. Codex 阅读策略

### 8.1 默认只读最小必要上下文

每次任务：

```text
1. 读取 AGENTS.md
2. 识别当前任务类型
3. 只读取该任务直接相关的 Spec / API / Decision / Test 文档
4. 读取受影响源码和测试
```

禁止把以下操作当作默认前置：

```text
完整遍历 docs/
完整遍历 codex/
完整阅读所有 Lesson 实操
因为“需要理解项目”就读取整个仓库
```

详细路由见：

```text
codex/CODEX_START_HERE.md
```

### 8.2 教学/文档任务

只有在编写或修改课程教学内容时，才额外读取：

```text
docs/CODEX_TEACHING_GUIDE.md
```

不要让普通修 Bug、补测试或小范围实现任务承担整套教学上下文。

## 9. 验证与完成报告

完成修改前必须按影响范围执行真实验证，至少区分：

```text
静态检查
编译
单元测试
集成运行
并发/确定性/Benchmark（适用时）
尚未验证项
```

不能把“代码看起来正确”写成“测试通过”，也不能把单元测试写成端到端验证。

测试策略见：

```text
docs/TEST_STRATEGY.md
```

## 10. 文档路由

```text
项目背景/学习目标              -> docs/PROJECT_CONTEXT.md
课程顺序/每课边界              -> docs/COURSE_ROADMAP.md + codex/LESSON_xx_SPEC.md
架构与长期演进                -> docs/TARGET_ARCHITECTURE.md
已确认技术决策                -> docs/ENGINEERING_DECISIONS.md
测试/回归/并发/Benchmark       -> docs/TEST_STRATEGY.md
BMAP                           -> docs/BMAP_FORMAT.md
Native Navigation API          -> docs/NATIVE_NAV_API.md
Navigation 抽象                -> docs/NAVIGATION_ABSTRACTION.md
Polygon Nav Asset              -> docs/POLYGON_NAV_ASSET_FORMAT.md
Lua C API                      -> docs/LUA_C_API_BINDING_GUIDE.md
Windows/WSL/Git 工作流         -> docs/WORKSPACE_WORKFLOW.md
FlyWow 抽取与仓库边界          -> docs/FLYWOW_EXTRACTION_POLICY.md
Codex 教学与教程写作           -> docs/CODEX_TEACHING_GUIDE.md
编码规范                       -> .agents/skills/skynet-battle-navigation-coding-standard/SKILL.md
```

当两个文档发生冲突时：

```text
用户当前明确指令
> AGENTS.md 全局硬规则
> 对应 Lesson Spec / 已编号 Engineering Decision
> 其他说明文档
```

不要自行用旧教程正文覆盖较新的 Spec 或 Engineering Decision。
