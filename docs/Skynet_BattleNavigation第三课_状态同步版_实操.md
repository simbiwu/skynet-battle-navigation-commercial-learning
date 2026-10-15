# Skynet Battle Navigation 第三课：状态同步工程导读

本课交付一套可运行的状态同步工程。请直接阅读完整代码、运行服务端与 Unity 场景并观察验证结果；本文解释各部分为什么存在、数据如何流动，以及失败时由谁处理，不要求按章节复制文件。

本课从 Lesson 2 已完成的 Server、地图和导航资产开始。状态同步与帧同步各自拥有模拟、协议与恢复合同。两版复用现有 Gateway、协议生成流程和 FlyWow Navigation，不共用 Battle 模拟。状态同步用 TCP。

## 1. 最终运行链路

    Unity StateBattleController
      -> TCP Envelope + StateJoin
      -> FlyWow Gateway：握手、framing、command/body编解码
      -> State Dispatcher：分配Battle ID，固定选择Worker
      -> State Worker：创建Battle，拥有会话与快照/事件历史
      -> StateRuntime：60 Hz固定Tick，调用FlyWow Navigation Context
      <- Worker回送控制回复，或发出没有关联号的StatePush
      <- Gateway按连接身份定向投递
      <- Unity预测、权威校正、事件消费和远端插值

| 部分 | 拥有什么 | 负责什么 | 不负责什么 |
| --- | --- | --- | --- |
| FlyWow Gateway | TCP/WS连接、协议解码、连接身份 | 握手、framing、command/body编解码、双向转发、定向 Push | Battle归属、命令幂等、技能和状态 |
| State Dispatcher | Worker handles、Battle ID | 按 Battle ID 选择 Worker，限制控制请求并发，回送控制结果 | 单位状态、导航 Context、战斗规则 |
| State Worker | 本 Worker 的 Battle、会话代数、凭据、快照历史、回放 | 调 Core、确认水位、恢复和资源上限 | Socket、Proto 字节和 Unity 对象 |
| State Runtime | 单场单位、输入、冷却、弹丸、事件 | 固定 Tick 内权威规则 | Skynet、网络 I/O、DB、墙钟、yield |
| Unity Controller | 本地预测、显示历史、Unity 对象 | 即时响应、权威校正、远端显示、恢复和离线回放 | 正式位置、命中、伤害、HP、胜负 |
| FlyWow Navigation | 地图快照与 Battle-local Context | 地面移动、寻路、动态占位、空中 AABB 查询 | Battle 身份、技能和网络合同 |

工程按商业实时战斗要求保留权威、低延迟反馈、版本身份、容量边界、生命周期和失败语义；样例只缩小玩法内容。本课是一个玩家、两名 AI、一个地图和三个技能，不包含账号、匹配、经济奖励、AOI、完整 Buff、完整空中导航或进程崩溃后的持久化恢复。

## 2. 固定基线与坐标

Server 每秒推进 60 个固定逻辑 Tick，一个 Tick 是 1/60 秒，约 16.67 ms。状态复制为 20 Hz，即每 3 个模拟 Tick 一次；已提交的重要事件尽快推送。Unity 渲染频率独立。连接使用 TCP；TCP 保证字节流顺序，不代表 Battle 已接受命令。

TCP 的顺序流也带来队头阻塞：丢失或停顿的数据会延迟后面的状态。客户端因此先做有界预测，最多保留 24 个输入；达到上限就暂停继续预测，500 ms 无状态时提示恢复。测试覆盖延迟、抖动和 500 ms 字节流停顿，但没有覆盖真实 IP 丢包；这组结果不能解释成 TCP 对丢包零阻塞。

Battle 使用整数毫米 x_mm/y_mm/z_mm。示例地图为 map_id=1001、map_version=1。Map SHA-256 对应已发布 BMAP 字节；Config SHA-256 对应状态同步、UnitProfile、NavigationProfile 配置字节，不是模拟代码哈希。simulation_version 标记规则合同。影响战斗结果的代码更新时按版本规则升级它；改配置时重新生成配置身份。客户端入场时校验不匹配就停止战斗。

基线是 Skynet v1.8.0、其内置修改版 Lua 5.4.7、C++17、Tuanjie 1.10.0 / Unity 2022.3 LTS、AI Navigation 1.1.7；本课没有升级这些版本。

先把地图零点记为 O。非负例子：位置 x=1000 mm、z=0 mm 表示从 O 沿 +X 走 1 m。坐标小于零表示沿轴负方向；负坐标是合法世界位置，不是错误输入。

    +Z（毫米）
      ↑
      │
      O────────→ +X（毫米）
      │
      ↓
     -Z

读图要点：O 是发布地图定义的世界原点；轴箭头表示正方向，另一侧为负方向；坐标单位是毫米，1000 mm = 1 m。网络和长期 Battle 合同使用毫米世界坐标；Grid Cell、PolyRef 等只属于导航内部；Unity Transform 只负责表现。X/Z 为水平位置，Y 为地表高度。Client 预测调用同一 FlyWow Navigation 移动实现。

每份移动输入代表一个 60 Hz 采样。设速度 v 的单位为 mm/s，输入序号 n；经过 n 次采样的时间是 n/60 秒。恒速距离的原始关系是“距离 = 速度 × 时间”，所以理想累计距离为 v × n/60 mm。Server 和 Native 位置使用整数毫米，于是把累计值向下取整；本 Tick 的位移就是本次累计距离减去前一 Tick 的累计距离：

    累计距离(n) = floor(n × v / 60)
    本次距离(n) = 累计距离(n) - 累计距离(n - 1)

floor 向下取整；相邻累计值相减可把毫米余数分散到各 Tick，避免每 Tick 单独截断造成长期少走。非负例子：速度 3000 mm/s，前两 Tick 累计是 floor(3000/60)=50 mm、floor(6000/60)=100 mm，因此两次位移都是 50 mm。斜向同时按 X/Z 移动时，每轴乘 707/1000；两个分量平方和约为 0.707²+0.707²=0.9997，长度约等于一个单轴单位，所以对角线不会更快。runtime.lua 和 Native 预测使用相同序号累计规则。

## 3. 服务端调用链与所有权

| 文件 | 职责及阅读问题 |
| --- | --- |
| server/config/state_gateway_process.lua | Gateway OS 进程入口和搜索路径；为何不加载地图/Battle Native？ |
| server/config/state_battle_process.lua | Battle OS 进程入口；如何加载 FlyWow Navigation？ |
| server/service/gateway/state_sync/main.lua、proxy.lua | 复用 FlyWow Gateway 组装、异步转发和 handler 注入；响应如何找到连接？ |
| server/service/battle/state_sync/main.lua | 载入地图/Profile并校验运行时地图 hash，再启动 Dispatcher。 |
| server/service/battle/state_sync/dispatch.lua | 请求转业务值、路由 Worker、最多 64 个控制调用在途、稳定错误。 |
| server/service/battle/state_sync/worker.lua | Battle Owner；定时 Tick、快照/事件水位、恢复、回放和终止。 |
| server/lualib/battle/state_sync/runtime.lua | 无 Skynet 依赖的单场权威规则；step 不 yield。 |
| server/lualib/battle/state_sync/replication.lua | 从客户端确认的基线生成 Delta；缺基线发送全量。 |
| server/third_party/skynet-flywow/navigation/ | 只调用固定子模块公开的 Lua/Native API；地图及 Context 由 FlyWow 管理。 |

Dispatcher 按 battle_id % worker_count + 1 固定路由。每个 Worker 在自己的 Lua State 内修改自己持有的 Battle；动态状态不放入共享可变导航数据。Skynet 定时器按厘秒唤醒并计算应推进的 Tick，单次最多补 4 Tick，不跳过超时积欠。每轮 A* 总预算 4 次并轮转 Battle 起点；预算不足只延迟 AI 重规划，不停战斗时钟。

Core 依次消费一个移动采样、校验和执行玩家技能、更新 AI、推进逻辑弹丸、检查胜负。没有输入时使用中立方向。每个 Native Context 属于一场 Battle；创建失败、正常结束、超时、过载和 Worker 关闭都关闭 Context。

## 4. Proto 与 Gateway 无 request_id 合同

协议按职责拆分：`wire_header.proto` 定义共用的 `battle.transport.v1.Envelope`，`lesson_03/state_sync.proto` 定义状态同步消息；各课导航和帧同步分别位于各自课程目录。Envelope 使用 protocol_version=1、command=2、body=3，不定义 request_id。协议版本为 4；各课程 descriptor 和客户端生成物按当前源同步更新。Gateway 负责连接、版本、command/body 编解码和透明转发，不解释 Battle。

Gateway 不要求客户端请求带关联号，也不要求 Server 主动 Push 带关联号。Server 主动 STATE_PUSH 就没有 request_id。定向发送仍核对 gateway_epoch、正数 connection_id、handler 来源和连接存活；connection_id=0 表示配置允许的广播。这些身份信息解决发给哪个连接，不承担 Battle 命令序号。

业务消息有各自序号：

| 字段 | 合同 |
| --- | --- |
| input_seq | 连续方向采样序号；区分接收、排队、实际消费水位。 |
| cast_seq | 离散施法序号；相同序号/内容可重试，内容冲突拒绝。 |
| snapshot_seq / base_seq | 快照编号与 Delta 基线；base_seq=0 为全量。 |
| event_seq | Server 已提交事件的序号；重复忽略、跳号恢复。 |
| generation | 恢复后的会话代数；旧连接命令失去授权。 |

长连接客户端按 command 关联控制回复，同一 command 最多一个控制请求在途；主动 Push 走独立队列。控制请求超时会关闭连接，防止迟到回复配给后来同 command 的请求。移动输入是单向 Send；若 Server 拒绝输入，会以 StatePush 错误码通知。可靠性来自 Battle 序号合同、全量恢复和 TCP 连接生命周期，不是 Gateway 的业务确认。

## 5. 权威移动、AI 和技能

单位与导航配置沿用 server/config/unit_profiles.lua、server/config/unit_profiles/*.lua、server/config/navigation_profiles.lua 及其 Profile 文件。state_sync.lua 只配置 Tick、容量、地图和样例技能。

| ID | 模型 | 样例规则 |
| --- | --- | --- |
| 1 | 瞬时效果 | 距离不超过 900 mm，冷却 36 Tick；合法施法在该 Tick 结算 14 伤害。 |
| 2 | 表现弹丸 | 距离不超过 9000 mm，冷却 72 Tick；Server 接受 Tick 结算 12 伤害并发 Event，Unity 播放约 300 ms 纯表现弹丸。 |
| 3 | 逻辑弹丸 | 距离不超过 9000 mm，冷却 72 Tick；Server 以 6000 mm/s 推进，最长 180 Tick、半径 50 mm，逐 Tick 扫掠碰撞，命中才产生 20 伤害。 |

Server 校验施法者、目标存活/阵营、距离、序号与冷却。Unity 按键可以立即显示并撤销预备动作；QUEUED 仅表示排队，正式执行结果由包含 cast_seq 的 StateEvent 表示。Unity 表现弹丸不计算命中或修改 HP；逻辑弹丸由 Server 推进和碰撞。

AI 样例选择最近存活对手，平距按实例 ID 稳定排序；远距离时用 FlyWow find_path_to_unit_range 求路、advance_path 推进。地面移动和动态占位仍走现有 Navigation Context。空中 AABB 查询仅用于单位间弹丸扫掠；当前 BMAP 不含楼体空中遮挡体，不能声称弹丸会被任意建筑阻挡。

Server Battle 通过 require "flywow_navigation" 调用 FlyWow Navigation 的公开 Lua API，这些 API 由 FlyWow Native Lua Binding 注册。直接注册的 C++ 回调标识符与 Lua 可见名称逐字符一致，例如 `find_path_to_unit_range`。Unity 本地预测另走 P/Invoke C ABI；两条跨语言边界遵守各自的名称合同。

## 6. Snapshot、Event 与快速反馈

Snapshot 表示某个 Server Tick 的正式状态，包含单位、HP、冷却、逻辑弹丸、输入消费水位、事件水位和胜负。Delta 明确指向客户端已确认基线，包含变更和显式删除；没有基线则服务端发全量，客户端找不到基线则 Resync，不猜测合并。历史最多保存 64 份。

Event 表示 CAST、伤害或 BOLT_END 等正式语义结果。重复序号不会重复触发效果；缺号请求恢复。Server 保留 512 个 Event，每条 Push 最多 64 个；确认水位落后到窗口外时，发送 EVENT_GAP 和全量快照覆盖状态。状态每 3 Tick 更新；有新事件时可立即推送。Push 不依赖一个等待中的请求。

Unity 每 1/60 秒采样键盘，通过 StateMovement 的 DllImport 调用 FlyWow Navigation 薄 C ABI（ss_open、ss_reset、ss_step、ss_close）；这些符号是 Unity P/Invoke 合同，不是注册给 Lua 的 C++ Binding 回调，名称须与客户端导入声明保持一致。客户端先预测本机角色，再异步发送输入。权威 Snapshot 到达后，客户端移除已消费序号之前的预测输入，从权威位置重置，再重放尚未消费输入。校正误差小于 1 m 时平滑，达到 1 m 时直接收敛。

远端单位按快照历史插值，时间线落后约 6 Tick（100 ms）以吸收更新间隔和抖动；数据不足时最多外推 3 Tick（50 ms）。500 ms 未收状态就暂停输入并显示 Recover。用户可请求恢复；基线或事件缺口触发 Resync。客户端立即响应，Server 始终决定最终结果。

## 7. 恢复、资源上限和回放

恢复凭据是 Battle 会话内稳定的 32 字节随机值，长度检查后常数时间比较；它不是账号凭据，不进入回放或日志。恢复成功后 generation 增加，旧连接身份被拒绝。凭据在 Battle 生命周期内不旋转，因此恢复回包丢失后仍可重试。仅存活 Battle 可恢复；结束战斗返回 ENDED。

上限对应实际持有资源：每 Worker 32 场；每场 10800 Tick（180 秒）；移动待消费窗口 24；单轮 A* 4 次；Event 窗口 512；快照基线 64；回放最多 10800 条且编码保守预算 8 MiB。回放超限明确以 REPLAY_LIMIT 终止该场并关闭 Context，不静默截断。断线 Battle 保留 30 秒；终态关闭 Native Context，只有限期保留结果与回放。Worker 进程崩溃后的持久化恢复不属于本课。

回放保存初始权威状态、新提交事件及全量状态检查点；网络重发不重复记录。每页最多 4 条。Unity 保存 Protobuf 文件并离线播放记录的状态轨迹和事件；它不会重新执行权威 Battle Core，也没有回滚验证，不是帧同步确定性回放。

## 8. 打开和运行

编辑源遵循 docs/WORKSPACE_WORKFLOW.md：Server、FlyWow、协议源和文档在 WSL 主工作区；Unity、场景和 Unity 生成文件在 Windows 工作区。生成脚本只写明示的 Unity Assets，不覆盖不匹配的已发布地图。

在 WSL Server 目录运行：

    cd ~/workspace/skynet-battle-navigation-commercial-learning/server
    bash scripts/lessons/lesson3_run_state_sync.sh prepare
    bash scripts/lessons/lesson3_run_state_sync.sh build
    bash scripts/lessons/lesson3_run_state_sync.sh test

prepare 校验 BMAP/manifest hash，生成配置身份、Server descriptor、Gateway registry并检查协议。Unity C# 和客户端只读配置由同一准备脚本生成到 Windows 编辑源；它检查已有 BMAP hash，不覆盖地图。Windows DLL 由 lesson3_build_state_sync_windows.sh 从 WSL Native 源交叉构建到明确的插件目录；构建机需要 MinGW-w64 C/C++ 工具链。本机已安装所需工具并提供 Assets/Plugins/x86_64/state_navigation.dll。

    python3 scripts/lessons/prepare_state_sync.py --unity-output /mnt/g/simbi/dev/skynet-battle-navigation-commercial-learning/unity/BattleNavigation/Assets
    bash scripts/lessons/lesson3_build_state_sync_windows.sh /mnt/g/simbi/dev/skynet-battle-navigation-commercial-learning/unity/BattleNavigation/Assets/Plugins/x86_64

在线运行需两个 WSL 终端，均在 Server 目录：

    bash scripts/lessons/lesson3_run_state_sync.sh battle

    bash scripts/lessons/lesson3_run_state_sync.sh gateway

用固定版 Tuanjie Editor 打开 unity/BattleNavigation，运行 Assets/BattleNavigation/Scenes/State_Battle_1001.unity。Gateway 默认监听 127.0.0.1:19031。WASD 移动，J/K/L 施放三个技能；界面显示状态、Tick、预测队列和校正距离，并提供 Recover、Save Replay。设置 Controller 的 ReplayPath 可离线加载回放。benchmark 是单独性能采样；battle/gateway 前台运行，可由各自终端 Ctrl+C 停止。

## 9. 验证记录与边界

codex/LESSON_03_STATE_SYNC_PROGRESS.md 记录运行环境、具体用例和限制。已取得的证据包括：

- FlyWow Gateway、Lua、Proxy、descriptor/registry 的无 request_id 迁移；旧版本拒绝；真实 TCP/WS 握手、异步、限制和断线路径。
- 状态同步 Core、Worker 和双 Skynet TCP 集成；包含输入消费、技能、恢复代数、旧会话拒绝、全量 Resync、离开和回放凭据隔离。
- FlyWow Navigation 构建及原有 3 项 CTest、本课 Native 构建通过；Windows DLL 对 Server 生成的 180 Tick 三组移动向量逐 Tick 完全一致。
- TCP relay 条件为 40/80/120/200 ms RTT、10 ms 抖动和 500 ms 下行中断。待处理输入峰值分别 6/8/11/16/24；中断时达到 24 上限后预测暂停。这模拟字节流延迟与停顿，不等同 IP 丢包或操作系统网络整形。
- Unity 实机编译、5 项 Snapshot/Event 合并测试和 Play Mode 120 Tick 通过；自动检查不代替人工画面和操作手感评估。
- 第二课 Battle 在协议合同迁移后以当前场景成功结束；旧 Gateway TCP/WS、第二课本地和 Cluster 路径已回归。

CPU Benchmark 环境为 i5-10400F 2.90 GHz、12 逻辑线程、GCC 15.2、RelWithDebInfo FlyWow Native、独立 Lua Core 驱动。单/16/32 Battle，每场 3 单位，Tick p99 约 2.65/5.84/6.45 ms，最大约 2.67/7.43/6.47 ms。A* 预算启用后，16/32 Battle 尾延迟从相同压力模型下约 42/86 ms 降至约 6 ms。它是单机 Core 压测，不能作为生产容量或端到端时延承诺。没有测完整 Native RSS、长时 soak、多平台或 ASAN/TSAN。

## 10. 阅读顺序

1. 读 D045、D046 和 Lesson 03 Spec，确认协议版本、60 Hz、TCP 与交付边界。
2. 沿 wire_header.proto、lesson_03/state_sync.proto、prepare_state_sync.py、Gateway codec/Proxy、State Dispatcher/Worker 追 Join，再追一次无 request_id 的主动 StatePush。
3. 读 runtime.lua 的配置校验、accept_inputs、accept_cast、移动、AI、弹丸、step 和 snapshot；对照坏输入、重复、冲突、Context 关闭用例。
4. 读 replication.lua 与 Unity StateReplica.cs，手算一个基线、修改和删除 Delta；删除本地基线应触发 Resync。
5. 读 StateMovement.cs、StateBattleController.cs，追踪预测输入如何由 consumed_input_seq 清理并重放，再检查远端插值和 Recover。
6. 重跑 prepare/build/test；另跑 benchmark 时记录硬件和压力条件。

应能回答：TCP 没有 request_id 时控制回复如何配对、Push 怎么识别？已接收但未消费的输入如何表达？没有基线时为什么不能应用 Delta？恢复回复丢失后为什么凭据仍可重试？下行停顿时何时停止预测？回放超过 8 MiB 后为什么结束当前 Battle 而不静默返回不完整数据？

帧同步采用逐帧输入、确定性模拟与回滚；本课状态同步采用 Server 固定 Tick、状态校正和远端插值，是两套独立战斗网络方案。Lesson 2 批量 Battle/Replay 仍独立存在。FlyWow Gateway、协议生成和已验证 Navigation 按公开合同复用；Battle/Skill 留在宿主工程。
