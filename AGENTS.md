# AGENTS.md — 全局工作规则

本文件只规定每项任务都要遵守的边界。项目主线是 Unity Authoring → 版本化导航资产 → C++ Native Navigation → Skynet 权威 Battle → Unity Replay。课程细节按任务读取 `codex/LESSON_xx_SPEC.md`；技术选型与版本以 `docs/ENGINEERING_DECISIONS.md` 为准，不静默升级。文档路由见 `codex/CODEX_START_HERE.md`。

固定基线：Skynet v1.8.0、其自带修改版 Lua 5.4.7、C++14、CMake/Linux/WSL2、团结引擎 1.10.0（Unity 2022.3 LTS）、AI Navigation 1.1.7；Recast 1.6.0 仅在可选 Lesson 4 使用。

本仓库独立，不合并 `Skynet-slg-learning` 的业务代码；FlyWow 通过固定提交的 submodule 使用。

## 权限与工作区

- 用户没有明确说“开始、修改、实现、更新、执行、同步”等时，只分析和给方案，不修改文件。
- 未经用户明确要求，不 commit、push、force push、改远端分支，也不覆盖另一工作区的未提交内容。
- 涉及编辑源、Windows/WSL 同步或 Git 操作，先读 `docs/WORKSPACE_WORKFLOW.md`。WSL 主工作区是 Server、FlyWow、文档及非 Unity 文件的唯一编辑源；Unity 工程和 Unity 生成的导航资产保留 Windows 编辑源。
- FlyWow 只能在 WSL 主工作区内的 `server/third_party/skynet-flywow/` 子模块修改；不要直接修改独立的 `/home/simbi/workspace/skynet-flywow` 工作区。FlyWow 子模块必须先提交并推送，再由主仓库更新 submodule 指针并提交推送。
- 已有未提交修改属于用户；只改当前任务涉及的内容。

## 按需读取

- 先识别任务和受影响文件，只读相关 Spec、合同、源码与测试；不要默认遍历整个仓库或通读所有课程。
- 新增、修改或评审 C#、C++、Lua、Shell、PowerShell、Proto、CMake、配置、测试及教程中的可复制代码时，先读 `.agents/skills/skynet-battle-navigation-coding-standard/SKILL.md`。
- 编写课程教学内容时读 `docs/CODEX_TEACHING_GUIDE.md`；涉及 FlyWow 抽取或独立仓库时读 `docs/FLYWOW_EXTRACTION_POLICY.md`。

## 长期工程边界

- Server 决定正式位置、路径、技能、命中、伤害、HP、死亡和逻辑事件；Client 只提交意图与表现需求，不能覆盖 Server 结果。
- 长期 Battle/Persistence/Replay 合同使用整数世界或逻辑坐标、`map_id`、`map_version` 与内容 hash；`GridPos`、`grid_z`、`dtPolyRef` 和客户端坐标轴只属于具体实现。
- 静态地图资产加载后不可变；每场 Battle 自己拥有单位状态、occupancy、reservation 等动态数据。多个 Skynet Service 可能在不同 OS Thread 调用同一 Native Module，不共享可变的全局查询 scratch；可变 context 需隔离或显式同步。
- `service/` 放由 `skynet.newservice`/`uniqueservice` 启动的入口，`lualib/` 放 Service 内 `require` 的普通模块；按实际进程角色分组（如 `gateway/`、`battle/`，新增 DB 进程时用 `db/`）。目录不创建 OS 进程，也不共享 Lua State；进程由配置 `start` 入口组装。Service handle 由启动者保存并显式传递，不让 Service `skynet.call` 自己。
- 保持依赖单向：Gateway 不依赖地图/导航内部实现，地图/导航不依赖网络，Battle Core 不依赖 Client DTO 或表现层。公共模块只放稳定、真正复用的合同。
- `shared/protocol/` 是唯一协议源与生成物边界，`shared/navigation/` 是验证后发布的导航资产边界；Server Runtime 不读取 Unity 工程、临时 Bake 目录或开发机绝对路径。跨端合同保留版本、hash、兼容性和原子发布语义。
- 只在出现真实调用者、第二种实现或可测试合同时抽取接口；不为未来课程预建空 Manager、Service、DTO 或目录树。

## 课程、验证与冲突

- 课程顺序与完成条件由 `docs/COURSE_ROADMAP.md` 和对应 `codex/LESSON_xx_SPEC.md` 决定；旧教程不能覆盖较新的 Spec 或已编号 Engineering Decision。
- 修改后按影响范围做真实验证，报告静态检查、编译、单元测试、集成运行、适用的并发/确定性/Benchmark，以及尚未验证项。不能把代码审阅说成测试通过。测试策略见 `docs/TEST_STRATEGY.md`。
- 冲突优先级：用户当前明确指令 > 本文件 > 对应 Lesson Spec / 已编号 Engineering Decision > 其他说明文档。
