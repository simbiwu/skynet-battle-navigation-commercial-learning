# AGENTS.md — 全局工作规则

本文件只规定每项任务都要遵守的边界。项目主线是 Unity Authoring → 版本化导航资产 → C++ Native Navigation → Skynet 权威 Battle → Unity Replay。课程细节按任务读取 `codex/LESSON_xx_SPEC.md`；技术选型与版本以 `docs/ENGINEERING_DECISIONS.md` 为准，不静默升级。文档路由见 `codex/CODEX_START_HERE.md`。

固定基线：Skynet v1.8.0、其自带修改版 Lua 5.4.7、C++17、CMake/Linux/WSL2、团结引擎 1.10.0（Unity 2022.3 LTS）、AI Navigation 1.1.7；Recast 1.6.0 仅在可选 Lesson 4 使用。

本仓库独立，不合并 `Skynet-slg-learning` 的业务代码；FlyWow 通过固定提交的 submodule 使用。

## 权限与工作区

- 用户没有明确说“开始、修改、实现、更新、执行、同步”等时，只分析和给方案，不修改文件。
- 未经用户明确要求，不 commit、push、force push、改远端分支，也不覆盖另一工作区的未提交内容。
- 涉及编辑源、Windows/WSL 同步或 Git 操作，先读 `docs/WORKSPACE_WORKFLOW.md`。WSL 主工作区是 Server、FlyWow、文档及非 Unity 文件的唯一编辑源；Unity 工程和 Unity 生成的导航资产保留 Windows 编辑源。
- FlyWow 只能在 WSL 主工作区内的 `server/third_party/skynet-flywow/` 子模块修改；不要直接修改独立的 `/home/simbi/workspace/skynet-flywow` 工作区。FlyWow 子模块必须先提交并推送，再由主仓库更新 submodule 指针并提交推送。
- 已有未提交修改属于用户；只改当前任务涉及的内容。

## Git 操作指导

- 当用户询问提交、更新、同步、分支或其他 Git 操作时，默认只提供可直接执行的具体命令、逐条说明，以及 VS Code 图形界面的对应步骤；不替用户执行任何 Git 命令。
- 只有用户明确要求助手代为操作 Git（例如“帮我提交并推送”）时，才可执行相应操作。用户要求某项文件或课程修改，不等于授权提交、推送或其他 Git 操作。
- 指令应结合当前仓库、分支、工作区和未提交改动给出；有风险或前置条件时，先说明检查命令、预期结果及遇到异常时应停止的位置。

## 需求边界与主动扩展

- 本课程以成熟、真实运营的商业实时战斗体验及其完整核心框架为目标。设计和实现必须按目标系统的真实职责、合同、生命周期与失败语义考虑，不能因为这是课程、演示或当前样例规模较小，就把核心架构改成玩具方案。
- 可以缩小教学样例的内容规模，例如角色、技能、地图、美术和演示场景数量；不得因此省略或弱化目标架构必需的核心机制。每课应明确哪些内容是样例缩减，哪些合同和机制仍按商业系统要求成立。
- 状态同步与帧同步是两套独立的战斗网络方案和课程目标。分别设计和说明其权威归属、输入与结果传输、时序、确定性或状态校正、客户端响应、断线恢复等适用的核心合同；除非用户明确决定采用混合方案，不得把两套方案混为一谈或以一套替代另一套。成熟实时战斗的快速操作响应是必须满足的体验要求，不得作为可选优化或后续阶段处理；应从玩法设计阶段就纳入低延迟反馈，以及网络延迟、抖动、丢包和迟到输入下的响应与恢复策略，例如状态同步的本地预测、服务器校正和远端插值，或帧同步的输入预测与回滚等适用机制。对同类商业核心要求也应主动识别并纳入设计，不等待用户逐项提醒。
- 本节的范围约束用于避免偏离目标的泛化，不得用来删减满足商业实时战斗目标所必需的职责、合同、机制或验证。实现功能时仍应聚焦当前明确目标，不主动加入该目标架构并不需要的通用系统。
- 只有当前功能实际创建、持有或积累的资源或状态，才要求定义对应的上限、过载和失败行为；但目标架构必需的容量边界和失败语义必须按需定义。
- 可以主动补齐当前功能及其目标架构正常工作所必需的错误处理、资源释放、线程安全、生命周期和边界检查，但不要扩大到目标之外的功能职责和系统边界。
- 如果额外能力对目标架构并非必需，只在完成说明中提出建议，不直接实现。

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
- Git 提交说明的标题和正文必须使用中文；稳定技术术语、API 名称、命令和路径可保留英文。涉及多项内容时，必须在正文中逐项列出具体改动，不得只用笼统标题概括。
