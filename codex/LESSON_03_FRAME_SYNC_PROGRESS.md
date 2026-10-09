# 第三课帧同步版实操编写进度

最后更新：2026-10-10。本文件用于更换会话后恢复任务。

## 当前交付

`docs/Skynet_BattleNavigation第三课_帧同步版_实操.md` 已替换为完整实操正文，包含逐阶段教学、完整可复制源码、文件新建/局部修改/完整替换边界、构建/启动/调试/审计/回放步骤。23个源码片段含22个完整文件和唯一Proto追加片段，约166KB。大小不是完成证据；完整源码与实际验证记录才是。

状态同步文档保持原蓝图，未开展其实现；后续再单独完成，不为了两版共用增加复杂度。实操从第二课基线开始，不依赖旧第三课。

## 用户最新约束

- 中途提问通常是任务中的讨论；简短答复后继续原任务，不自行结束工作。
- **Gateway修改留给用户亲自在实操中完成并审计。当前主工作区Server/FlyWow不提前部署这些教程代码。** 作者只在隔离目录修复并验证。
- 玩家控制地面单位；飞行单位是Server控制的敌人，玩家不控制飞行单位。
- 飞行高度不能固定。当前Core保存可变Y，飞行AI派生水平和升降意图；出生2000mm不是固定飞行层。Client只在帧同步Core中复现确定性AI，不拥有正式敌人控制权。
- 当前地图是2.5D地表Grid。空中单位忽略地面walkable/clearance，但校验XZ边界、地表穿透与最大高度；不宣称具有尚无资产支持的完整三维空域导航。
- 三种技能：近战瞬发、立即结算伤害的表现弹丸、到达才结算的逻辑火球。目标类型和正式距离包含高度。
- 帧同步版内部Server/Unity编译同一C++Core；状态同步版允许独立实现。
- 当前帧同步传输沿用已有FlyWow TCP，明确队头阻塞风险；不额外自造UDP安全/拥塞系统。

## 编辑边界

WSL主编辑源：`/home/simbi/workspace/skynet-battle-navigation-commercial-learning`。本文与源码工作稿只写这里。
Windows仅Unity编辑源；文档/Server非Unity文件通过Git工作流同步，不覆盖Windows已有未提交内容。
未commit/push，未改主工作区Gateway，不修改独立FlyWow工作区。

## 已验证

- Linux Release Core/Binding编译、Native CTest、Lua Binding/Runtime测试。
- 固定protoc生成descriptor、C#与Lua Registry；Lua源码syntax检查。
- Gateway新测试的真实红/绿：原拒绝条件失败，隔离修复通过；旧epoch、未ready、关闭/未知目标、广播边界。
- 真实双Skynet进程：握手、两场定向push隔离、正式输入hash重演、错误凭据拒绝、断线恢复generation=2、Checkpoint和日志重演。
- Windows Release Native编译/CTest，Windows/Linux Golden 238行一致。
- C#使用真实Unity模块与现有SDK插件编译通过；Windows C#客户端连真实Linux Gateway，30帧使用Windows Native逐帧核对hash通过。

未验证：Unity Editor完整Play/场景表现、长期容量压测、全部网络故障、其它目标平台。文档提供实操验收，不将这些项目写成作者已通过。

详细结果：`codex/work/lesson_03_frame_sync/verification_results.json`。

## 作者工作稿与复现

- `codex/work/lesson_03_frame_sync/complete_author.py`：完整代码记录与隔离验证工具；不安装教程到用户Server。
- `codex/work/lesson_03_frame_sync/write_practical.py`：正文生成记录。
- `codex/work/lesson_03_frame_sync/source_index.json`：片段索引。
- `codex/work/lesson_03_frame_sync/validation/`：Windows隔离C#验收源码，属于作者Test，不是额外课程Runtime。
- `author_draft.py` 是早期未完成草稿，只作为complete_author的原始片段输入；其旧占位API不可直接复制。正式教学代码以实操正文为准。
- 隔离Linux目录 `/tmp/flywow_frame_course_verify` 可在重启后丢失；不得把临时目录存在当完成状态。需要重验证时先由complete_author.stage_files生成，重新CMake/build/test。

## 下一次任务

用户可以按帧同步实操开始学习；随提问辅导与审计其实际修改。状态同步版仍待以后授权开展完整实操，不能把现有蓝图当成已完成教程。任何学习源码编辑仍遵守AGENTS/WORKSPACE_WORKFLOW/编码Skill。
