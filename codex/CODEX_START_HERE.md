# Codex Start Here

本文件负责**任务路由**，不要求每次会话完整阅读整个 `docs/`、`codex/` 或全部实操教程。

## 1. 默认工作方式

每个任务先：

```text
1. 读根目录 AGENTS.md。
2. 判断任务类型与 Lesson。
3. 只加载下面路由中与当前任务直接相关的文档。
4. 读取受影响源码、调用方和测试。
5. 修改后按影响范围 build / test / run。
```

禁止为了“理解项目”默认遍历：

```text
docs/ 全目录
codex/ 全目录
所有 Lesson 实操正文
整个仓库所有源码
```

需要扩大阅读范围时，必须由当前调用链、错误现象或架构问题驱动。

## 2. 新会话建立项目基本上下文

第一次接手本仓库、且任务不是一个已经给出明确文件/函数的小修复时，先读：

```text
AGENTS.md
README.md
docs/PROJECT_CONTEXT.md
```

然后进入具体任务路由。

不要默认再把 `TARGET_ARCHITECTURE`、`ENGINEERING_DECISIONS`、`TEST_STRATEGY` 全部加载；只有任务需要时再读。

## 3. 代码修改通用路由

任何 C# / C++ / Lua / Shell / PowerShell / Proto / CMake / 配置 / 测试修改：

```text
.agents/skills/skynet-battle-navigation-coding-standard/SKILL.md
```

然后读取：

```text
受影响源码
直接调用方
对应测试
当前模块 API/格式文档（如果存在）
```

普通修 Bug、补测试、局部实现到这里通常就够了。

## 4. Lesson 1

目标：

```text
Unity Scene
-> 2.5D Grid/BMAP
-> C++ GridMap
-> Skynet Query
```

规格：

```text
codex/LESSON_01_SPEC.md
```

按任务选择：

```text
BMAP/Exporter/Loader     -> docs/BMAP_FORMAT.md
Native Binding/API      -> docs/NATIVE_NAV_API.md + docs/LUA_C_API_BINDING_GUIDE.md
协议/Gateway            -> docs/ENGINEERING_DECISIONS.md 中 D029/D033 及相关源码
测试/验收               -> docs/TEST_STRATEGY.md Lesson 1
完整教学/重写教程        -> 对应 Lesson 1 实操 + docs/CODEX_TEACHING_GUIDE.md
```

Lesson 1 不主动展开：

```text
AgentProfile
Path
NavigationContext
INavigationBackend
Detour
```

## 5. Lesson 2

规格：

```text
codex/LESSON_02_SPEC.md
```

按任务选择：

```text
A*/Path/NavigationContext  -> docs/NATIVE_NAV_API.md + docs/NAVIGATION_ABSTRACTION.md
BattleWorker/确定性        -> Lesson 2 Spec + docs/TEST_STRATEGY.md
双进程/Gateway-Battle      -> docs/ENGINEERING_DECISIONS.md D030/D033
完整教学/重写教程          -> 对应 Lesson 2 实操 + docs/CODEX_TEACHING_GUIDE.md
```

只有任务确实涉及某个章节时才读取 300KB+ 的 Lesson 2 实操全文；局部代码任务优先读取相关源码、Spec 和 API 文档。

Lesson 2 不提前创建：

```text
SkillRuntime
Projectile
AirNavigationMap
Detour Backend
```

## 6. Lesson 3

规格：

```text
codex/LESSON_03_SPEC.md
```

重点：

```text
PlayerCommand
GroundEnemy / FlyingEnemy AI
Air Grid / NoFly
Server-authoritative Skill / Projectile
Battle Snapshot / Event
同一 BattleWorker 支持在线 fixed tick 与批量快速模拟
```

按任务选择：

```text
确定性/回归/交互测试 -> docs/TEST_STRATEGY.md Lesson 3
架构边界            -> docs/ENGINEERING_DECISIONS.md D031/D035
教学正文            -> docs/CODEX_TEACHING_GUIDE.md
```

Lesson 3 不读取旧 Polygon NavMesh 草稿来驱动主线实现。

## 7. Lesson 4 optional

只有用户明确进入 Polygon NavMesh / Recast / Detour 时读：

```text
codex/LESSON_04_OPTIONAL_RECAST_SPEC.md
docs/POLYGON_NAV_ASSET_FORMAT.md
docs/NAVIGATION_ABSTRACTION.md
docs/TARGET_ARCHITECTURE.md
docs/REFERENCES.md
```

需要旧 Recast 草稿时再读：

```text
docs/LESSON_03_PRACTICAL.md
```

该文件名属于历史遗留，只作为 Lesson 4 参考，不决定前三课主线。

## 8. 架构/全仓 Review

用户要求：

```text
重新设计
全仓 Review
模块边界审计
Grid/Detour/H5 2D 演进
ownership/yield/依赖方向检查
```

再读取：

```text
docs/TARGET_ARCHITECTURE.md
docs/ENGINEERING_DECISIONS.md
docs/NAVIGATION_ABSTRACTION.md
相关 Lesson Spec
相关源码与测试
```

如果涉及 FlyWow 抽取/框架复用，再增加：

```text
docs/FLYWOW_EXTRACTION_POLICY.md
```

## 9. Windows / WSL / Git / Submodule

涉及：

```text
在哪个工作区修改
跨工作区同步
commit / push
远端分叉
submodule 更新
```

读取：

```text
docs/WORKSPACE_WORKFLOW.md
```

涉及 FlyWow 仓库本身，再读：

```text
docs/FLYWOW_EXTRACTION_POLICY.md
```

## 10. 教程和工程教练模式

只有用户要求：

```text
写/重写教程
逐阶段辅导
解释第一次出现的 Skynet/Unity 概念
生成可学习的完整实操章节
```

才加载：

```text
docs/CODEX_TEACHING_GUIDE.md
```

课程目标岗位是 Skynet SLG Server 主程/高级工程师；默认不讲 C++/Lua 基础语法，但 Unity/团结引擎空间和 Authoring 概念第一次出现时必须从 Server 视角桥接。

## 11. 验证路由

需要定义验收、回归、损坏资产、并发、确定性或 Benchmark 时读取：

```text
docs/TEST_STRATEGY.md
```

完成报告必须分别写清：

```text
静态检查
编译
单元测试
集成运行
并发/确定性/Benchmark（适用时）
未验证项
```

## 12. Git 提交建议

提交信息继续按实际阶段和变更内容组织，不为匹配课程章节强行拆提交。

常见前缀：

```text
feat:
fix:
test:
perf:
docs:
refactor:
chore:
```

只有用户明确要求时才执行 commit 或 push。
