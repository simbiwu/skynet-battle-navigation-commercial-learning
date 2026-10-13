# 第三课帧同步版实操编写进度

最后更新：2026-10-13。本文件用于更换会话后恢复任务。

## 当前交付

`docs/Skynet_BattleNavigation第三课_帧同步版_实操.md` 已替换为完整实操正文，包含逐阶段教学、完整可复制源码、文件新建/局部修改/完整替换边界、构建/启动/调试/审计/回放步骤。23个源码片段含22个完整文件和唯一Proto追加片段，约166KB。大小不是完成证据；完整源码与实际验证记录才是。

状态同步文档保持原蓝图，未开展其实现；后续再单独完成，不为了两版共用增加复杂度。实操从第二课基线开始，不依赖旧第三课。

2026-10-11 收口：帧同步文档统一为单一 `UnitProfile` 配置文件/静态只读表。玩家、地面敌人和飞行敌人均通过有效 `profile_id` 查询；最大 HP、移动模式、速度、地面导航参数、飞行间隙和高度边界都从同一记录读取。FlyWow `NavigationProfile` 仅作为该记录内调用 `GridPathfinder` 的参数视图，不另建 Profile ID、配置文件或 Registry。

2026-10-11 命名收口：CMake 对外链接目标统一为 `FlyWow::Navigation`，FlyWow 内部静态库目标为 `flywow_navigation_core`；帧同步教程和构建链路文档已同步该合同，C++ 命名空间保持 `flywow_navigation`。

2026-10-12 单位标识命名：Battle运行时单位统一使用 `instance_id` / `unit_instance_id`；`Unit.unit_profile_id` 对应 `UnitProfile.unit_id`，两者用于静态配置查询。同步帧同步文档、Native Core、Lua Runtime与Unity C# 输入字段；只改源代码标识符，C ABI字段顺序/尺寸和Checkpoint V3编码顺序/值保持不变。

2026-10-13 通用注释规则收口：项目规则覆盖所有模块、语言与课程可复制代码；FlyWow 规则仅约束 FlyWow 自有代码。帧同步 Core 的空中追击实现与实操副本已补充水平距离度量、追击高度公式、方向意图、步长门槛和三维停止距离说明，不改变运行行为。

2026-10-13 注释审阅扩展：除空中追击外，帧同步 Core 与实操代码副本补充了多轴步长近似、地面路径缓存/重规划条件、技能效果与冷却、弹丸推进/寿命、帧内目标和伤害顺序、Checkpoint V3 编码与原子恢复说明；FlyWow HotUpgrade Native、控制器、Runtime 与模块暂存代码补充了随机令牌、规范路径/扫描边界、审计文件持久化、事务发布顺序、候选回滚、闭包重绑定及 yield/排空边界说明。均为注释变更，不改变运行行为。

2026-10-13 结构体字段注释与对齐收口：项目与FlyWow编码Skill要求手写C++ `struct` 的每个字段说明业务职责，并在整个结构范围内对齐字段名、赋值符和 `///<` 注释。帧同步Core头文件及实操文档中的对应数据结构已同步；只调整注释与空格，保留字段顺序、类型、初始值、C ABI和Checkpoint V3布局。

2026-10-11 CMake 归属收口：完整静态库、公开别名、Lua Binding、测试和 Benchmark 由 `navigation/native/CMakeLists.txt` 管理；删除 `grid_map/CMakeLists.txt`，Grid Map 仅作为 Navigation 内部实现源。`FlyWow::Navigation` 是构建树内 alias，不产生独立库文件；`flywow_navigation_lua` 生成供 Skynet 加载的 `flywow_navigation_native.so`。

## 用户最新约束

- 中途提问通常是任务中的讨论；简短答复后继续原任务，不自行结束工作。
- 用户本轮明确授权完整实施，包含 Gateway；本次已在 FlyWow 子模块中完成定向主动消息校验修复并验证，最终由用户审核。Server 源码留在 WSL 主工作区，未部署到其它 Server 工作区。
- 玩家控制地面单位；飞行单位是Server控制的敌人，玩家不控制飞行单位。
- 飞行高度不能固定。当前Core保存可变Y，飞行AI派生水平和升降意图；出生2000mm不是固定飞行层。Client只在帧同步Core中复现确定性AI，不拥有正式敌人控制权。
- 当前地图是2.5D地表Grid。空中单位忽略地面walkable/clearance，但校验XZ边界、地表穿透与最大高度；不宣称具有尚无资产支持的完整三维空域导航。
- 三种技能：近战瞬发、立即结算伤害的表现弹丸、到达才结算的逻辑火球。目标类型和正式距离包含高度。
- 帧同步版内部Server/Unity编译同一C++Core；状态同步版允许独立实现。
- 当前帧同步传输沿用已有FlyWow TCP，明确队头阻塞风险；不额外自造UDP安全/拥塞系统。

## 编辑边界

WSL主编辑源：`/home/simbi/workspace/skynet-battle-navigation-commercial-learning`。本文与源码工作稿只写这里。
Windows仅Unity编辑源；文档/Server非Unity文件通过Git工作流同步，不覆盖Windows已有未提交内容。
未commit/push；Gateway 子模块改动本轮按用户授权已实施；不修改独立FlyWow工作区。

## 已验证

- Linux Release Core/Binding编译、Native CTest、Lua Binding/Runtime测试。
- 固定protoc生成descriptor、C#与Lua Registry；Lua源码syntax检查。
- Gateway新测试的真实红/绿：原拒绝条件失败，隔离修复通过；旧epoch、未ready、关闭/未知目标、广播边界。
- 真实双Skynet进程：握手、单客户端定向帧推送、正式输入hash重演、错误凭据拒绝、断线恢复generation=2、Checkpoint和日志重演。
- 此前独立验证记录包含 Windows Release Native/CTest 与 Windows/Linux Golden 238 行一致；本轮 Unity 工程接入尚未能通过 Unity Editor 重新构建确认。
- 较早的隔离验证记录曾通过 C# 客户端与真实 Linux Gateway 的 30 帧 hash 核对；该记录早于本轮 xLua/Frame 客户端接入，不代表当前 Windows Unity 改动已编译或联调。

未验证：Unity Editor完整Play/场景表现、长期容量压测、全部网络故障、其它目标平台。文档提供实操验收，不将这些项目写成作者已通过。

详细结果：`codex/work/lesson_03_frame_sync/verification_results.json`。

本轮 Unit Profile 文档代码验证（WSL/Linux 隔离目录）：从正式实操提取的 `CMakeLists.txt`、Core、Lua Binding、frame_test 和配置完成 Release 构建；`frame_native` CTest 通过；实际加载器拒绝 15 种非法 Profile 配置，且失败后旧配置快照仍可创建 Engine。此次没有重跑 Windows DLL/Unity Editor 跨端验证，旧记录中的 Windows 结果不覆盖本轮新增的 Unit Profile 改动。

## 作者工作稿与复现

- `codex/work/lesson_03_frame_sync/complete_author.py`：完整代码记录与隔离验证工具；不安装教程到用户Server。
- `codex/work/lesson_03_frame_sync/write_practical.py`：正文生成记录。
- `codex/work/lesson_03_frame_sync/source_index.json`：片段索引。
- `codex/work/lesson_03_frame_sync/validation/`：Windows隔离C#验收源码，属于作者Test，不是额外课程Runtime。
- `author_draft.py` 是早期未完成草稿，只作为complete_author的原始片段输入；其旧占位API不可直接复制。正式教学代码以实操正文为准。
- 隔离Linux目录 `/tmp/flywow_frame_course_verify` 可在重启后丢失；不得把临时目录存在当完成状态。需要重验证时先由complete_author.stage_files生成，重新CMake/build/test。

## 下一次任务

用户可以按帧同步实操开始学习；随提问辅导与审计其实际修改。状态同步版仍待以后授权开展完整实操，不能把现有蓝图当成已完成教程。任何学习源码编辑仍遵守AGENTS/WORKSPACE_WORKFLOW/编码Skill。

2026-10-13 AIRN 帧同步应用扩展：按当前授权将 AIRN V1 空中寻路改成第三课主实操第 5.24 节和第 4 阶段，说明 Unity Authoring 配对导出、显式双路径加载、飞行 AirBody Profile、Frame-local 动态 AABB、固定高度寻路与变高 move/sweep、Checkpoint V3 派生重建。Server/FlyWow 用户运行源码未提前部署；`battle_1001` 当前无 AIRN 静态文件，静态端到端加载需作者之后在 Windows 场景导出再同步。新增隔离 API 组合测试验证动态障碍/寻路/推进/扫掠/移动，AIR Benchmark 重跑 7 个场景全部达到既有断言。
2026-10-13 AIRN 文档核对：章节操作按 MapRoot 的实际 `exportAirNavigation`、`airObstacleLayers`、`exportDirectory` 与版本化候选发布器说明；没有虚构文件名 Inspector。当前 `write_practical.py` 与 `complete_author.py` 早于 UnitProfile 完整稿，运行会把正式实操降回旧草稿；再次生成前必须先同步生成源。
2026-10-13 60 Tick/s 基线收口：第三课帧同步实操统一为固定1/60秒逻辑步长；Native/Core、Lua Worker、协议、Unity预测与回放校验同步使用60Hz。单位速度配置由mm/Tick改为mm/s，Core用整数帧号累计差分换算位移；冷却、弹丸寿命、地面AI重规划/阻挡重试、输入lead/future window/缺输入保持及180秒帧上限均按原实际时长换算。Skynet的10ms Timer只轮询截止，Worker按单调时钟起点和绝对帧号计算并向上量化截止，避免逐Tick累加漂移。帧同步模拟版本升为2以拒绝旧20Hz客户端和Replay；Checkpoint V3字节布局未变，仍保存帧号计量状态。未修改主工作区Server/Gateway、Unity源码、FlyWow或Windows文档副本；未执行Git操作。静态时间合同扫描通过；实操文档提取的完整 Frame Core 通过 C++17 语法检查；以文档原样提取的整数移动函数行为检查通过（60帧单位/弹丸位移总量、不同连续移动片段误差边界）；Skynet 10ms绝对截止映射数学检查通过（首帧lead 100ms、60帧无累计漂移）；固定 Lua 5.4.7 编译器通过 frame_sync.lua、Runtime、Worker 语法检查。未运行 Native CTest、Unity构建或双端联调，因此不宣称这些验证通过。


## 2026-10-14 完整实施记录

用户授权按第三课帧同步实操完成全部实现并审核源码，明确 Gateway 改动也由实施者完成。本次改动已落地于 WSL Server/FlyWow 子模块和 Windows Unity 工程；没有执行 commit、push、分支切换或跨工作区文档/Server同步。



### 实际实施范围

- Linux Frame Core、Lua Binding、60Hz Worker/Runtime、Proto、回放/Checkpoint V3、统一 UnitProfile、地图元数据准备和集成测试安装到 WSL 主工作区；FlyWow Navigation 通过 `FlyWow::Navigation` 公开目标链接。

- 增加 AIRN 可选资产路径、统一 UnitProfile 中的飞行 AirBody、Battle-local 动态空中障碍重建、空中寻路/扫掠移动及失败原子性测试。当前发布地图没有静态 AIRN，因此只验证 BMAP-only 兼容和动态障碍，不宣称静态 AIRN 配对资产已端到端通过。

- Gateway 在 `gateway/service/gateway/flywow_gateway.lua` 移除了对“指定有效连接且 request_id=0 主动消息”的拒绝条件，保留 connection_id/request_id 范围、epoch、ready、目标连接和编码等检查。扩展 `gateway/tests/gateway_async_test.lua` 覆盖目标连接定向发送、双连接隔离、广播隔离、关闭/未知目标丢弃和旧 epoch。已验证旧条件下负向断言失败，修复后输出 `GATEWAY_ASYNC_UNIT_OK`。

- Windows Unity 工程加入 xLua Lua 5.4、FrameNative/FrameConnection/FrameLuaProfileLoader/FrameBattleController，并由同一 Lua UnitProfile 配置读取模拟参数；协议生成 C# 已按 WSL 唯一 Proto 源更新，校验值同步写入 `shared/protocol/generated/unity/NavigationQuery.cs.sha256`。

- 保留 Windows 用户文件 `codex/work/lesson_03_frame_sync/write_practical.py`；保留 WSL 用户文件 `codex/work/lesson_03_frame_sync/阶段学习总结_状态同步实操参考.md`。



### 本轮实际验证

- Linux Release CMake configure/build 成功，CTest 4/4：Frame Native、FlyWow Grid Map、Navigation、Air Navigation。

- Lua Binding 与 Runtime 测试通过；Frame Lua 文件语法检查通过。

- Gateway Lua 异步单测通过；Gateway registry Python 测试 6/6 通过。

- Proto server descriptor 生成、Gateway registry 生成、配置准备脚本、Python 语法检查通过。

- 双 Skynet 进程真实端到端联调通过：`FRAME_ONE_CLIENT_OK battle_id=4 frames=12`；Battle 与 Gateway 已停止。

- Windows Unity Editor 在当前环境不可用，未运行 Unity Editor 编译或 Play；不能把 Windows 新增 C# 工程内容表述为 Editor 已验证。当前没有静态 AIRN 资产，也未做长期容量压测、全部网络故障矩阵或其它目标平台验证。



### 当前限制与工作区边界

- Windows 与 WSL 分支/源文件状态不同；本轮只编辑 Windows Unity 所属文件以及 WSL 非 Unity 所属文件，没有擅自同步另一工作区或覆盖其未提交内容。

- 临时安装脚本和官方 xLua 下载/克隆包已清理；保留实际运行依赖 `unity/BattleNavigation/Assets/XLua` 与对应 Windows DLL。

- 无 Git 操作：未提交、未推送、未切换分支。
