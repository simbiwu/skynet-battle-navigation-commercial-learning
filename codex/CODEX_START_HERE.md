# Codex Start Here

按任务找文档；权限和全局边界只看 `AGENTS.md`。已给出明确文件/函数的小任务直接读受影响源码、调用方和测试，不先读完整课程或全仓文档。首次接手且任务范围宽时，再读 `README.md` 与 `docs/PROJECT_CONTEXT.md`。

| 任务 | 按需读取 |
|---|---|
| 代码或可复制教程代码 | `.agents/skills/skynet-battle-navigation-coding-standard/SKILL.md`、受影响源码、直接调用方与测试 |
| Lesson 1 地图/BMAP/Native Query | `codex/LESSON_01_SPEC.md`；格式读 `docs/BMAP_FORMAT.md`，Binding 读 `docs/NATIVE_NAV_API.md` / `docs/LUA_C_API_BINDING_GUIDE.md` |
| Lesson 2 寻路/BattleWorker/双进程 | `codex/LESSON_02_SPEC.md`；按需读 `docs/NAVIGATION_ABSTRACTION.md`、`docs/SKYNET_CLUSTER_AND_HARBOR.md` |
| Lesson 3 当前续写任务 | 先读 `codex/LESSON_03_FRAME_SYNC_PROGRESS.md`；帧同步完整实操正文已交付，状态同步保留蓝图；作者验证与未验证项见进度记录 |
| Lesson 3 帧同步、状态同步 | `codex/LESSON_03_SPEC.md`；先读 `docs/Skynet_BattleNavigation第三课_帧同步版_实操.md`，再读 `docs/Skynet_BattleNavigation第三课_状态同步版_实操.md` |
| Gateway/Battle 韧性与持久化专题 | `docs/Skynet_BattleNavigation专题_GatewayBattle链路韧性与战斗持久化_实操.md` 对应阶段；这是第三课后的独立专题 |
| Lesson 4 optional Recast/Detour | `codex/LESSON_04_OPTIONAL_RECAST_SPEC.md`、`docs/POLYGON_NAV_ASSET_FORMAT.md`；旧 `docs/LESSON_03_PRACTICAL.md` 仅作历史参考 |
| 教程编写或逐阶段辅导 | `docs/CODEX_TEACHING_GUIDE.md` 和当前 Lesson 的实操对应段落 |
| 架构/技术选型 | `docs/ENGINEERING_DECISIONS.md`、相关模块合同；全仓 Review 再读 `docs/TARGET_ARCHITECTURE.md` |
| 验收、确定性、并发、Benchmark | `docs/TEST_STRATEGY.md` 的相关章节 |
| Windows/WSL 编辑源、同步、Git | `docs/WORKSPACE_WORKFLOW.md` |
| FlyWow Gateway 异步收发与握手 | `docs/FLYWOW_GATEWAY_ASYNC.md`、`docs/FLYWOW_GATEWAY_HANDSHAKE.md` |
| FlyWow 抽取或独立仓库 | `docs/FLYWOW_EXTRACTION_POLICY.md` |

需要扩大阅读范围时，由当前调用链、错误或设计问题决定。大型实操只读当前阶段；不要因为文件名中有 Lesson 就把全文当作每次任务的前置上下文。
