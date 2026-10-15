# 第三课状态同步完整工程实施记录

状态：完整工程与配套课程导读已落地；本次最终回归通过。用户确认基线：60 Hz、TCP、Gateway Envelope 不要求 request_id，Server 主动 Push 不携带 request_id。

## 交付内容

- Gateway、Server、Frame、第二课 Proxy 和 Unity 协议消费端统一迁移到协议兼容版本 4。Envelope 保留字段 3 的编号和名字，不传 request_id；Gateway 可向有效连接发送无需关联请求的 StatePush。
- Server 状态同步工程包含纯 Lua 权威 Runtime、固定 Worker 分片、多 Battle 调度、60 Hz Tick、20 Hz 状态复制、输入/技能序号、AI、三种技能、Event/Snapshot、Resync、断线恢复、资源上限和有界回放。
- Unity 客户端复用 Frame 使用的 FlyWow Gateway 长 TCP 连接；预测通过链接 FlyWow Navigation 的薄 C ABI 完成；支持输入预测/校正、远端插值、事件消费、恢复和离线状态回放。
- 完整运行场景、协议 C# 与必要配置位于 Windows Unity 工程；原 Authoring/Battle 场景保留。
- 沿用 UnitProfile、NavigationProfile、协议生成、FlyWow Gateway 和 Navigation。FlyWow 子模块只增加地图内容 hash 返回合同并复用现有 SHA-256 实现，没有复制导航实现。
- 配套导读围绕现有工程说明代码职责、协议、运行方式、失败边界和验证结果，不再要求逐文件复制。

## 核心合同

- Server 每秒 60 Tick；每 3 Tick 发布一次常规状态；已提交语义事件尽快发布。
- Gateway 处理连接、版本、framing 和透明投递；Battle 处理输入消费、技能幂等、事件序号、快照基线和恢复权限。
- Server 决定正式位置、AI、技能合法性、命中、伤害、HP、死亡和胜负。Client 只提交意图并临时预测。
- 长连接客户端按 command 配对控制回复，同一 command 最多一个控制请求在途；超时关闭连接避免迟到回复错配。主动 Push 走独立队列，无需 request_id。
- 恢复限于仍存活的同一 Battle；凭据在 Battle 生命周期内稳定，恢复成功递增 generation 并使旧连接失效。终态关闭 Native Context。Worker 进程崩溃后的持久化恢复不属于本课。
- 资源边界覆盖 Worker/Battle、输入窗口、A* 查询、快照/Event 历史、最长 Tick 与回放条数/字节预算；超限有稳定拒绝或终止语义。

## 验证记录

运行基线：Skynet v1.8.0 与内置修改版 Lua 5.4.7、Linux/WSL2、C++17、Windows x64 Tuanjie Editor 2022.3.62t12（Unity 2022.3 LTS）、i5-10400F 2.90 GHz / 12 逻辑线程。日志和构建产物保存在各自工程的 Build/log 目录及 WSL Server 日志目录。

- 状态同步 Lua Core/Worker 测试通过：STATE_CORE_TEST_OK、STATE_WORKER_TEST_OK。覆盖方向输入、消费水位、重复/冲突序号、技能效果、快照复制、过载和 Context 生命周期。
- 双 Skynet TCP 集成通过：STATE_TCP_INTEGRATION_OK battle=1 consumed=8 generation=2。覆盖入场、坏凭据、输入、施法、恢复代数、旧会话拒绝、全量 Resync、离开和回放凭据隔离。
- 最终运行 lesson3_run_state_sync.sh test，Core、Worker、TCP 集成全部通过。
- Gateway 全范围最终回归通过：gateway_async_integration.py --scope all。TCP/WS 握手与异步收发、网络限制、第一课本地、第二课 Cluster 和跨 Cluster close 均通过，结果为 GATEWAY_ASYNC_INTEGRATION_OK scope=all。
- FlyWow Gateway Python 用例 9 passed、1 skipped（可选 Crypto 环境未配置）；Gateway Lua async 合同测试通过。descriptor/registry 检查确认 Envelope 不含 request_id 且拒绝旧协议版本。第二课当前场景回归结束：55 个事件、228 个路径点；修正既有输出上限与当前内容不匹配，没有放宽断言。
- FlyWow Navigation 原有 3 项 Linux CTest 全通过；本课 Native 构建成功。Windows DLL 对 Server 产生的 180 Tick 三组移动向量逐 Tick 比对，位置完全一致：STATE_WINDOWS_SERVER_GOLDEN_OK。
- Unity EditMode Runner 23/23 通过，ClientTests 程序集 8/8；包含 Delta 基线、实体修改/删除、事件重复/缺口、过期快照和基线淘汰。
- 真实双进程 Unity Play Mode 通过：STATE_UNITY_PLAY_OK tick=120，结果文件为 {"tick":120,"passed":true}。运行包括实际 Editor 编译、Native 插件加载与 TCP 联机；自动 Play 不替代人工画面和手感检查。
- TCP relay 条件为 40/80/120/200 ms RTT、10 ms 抖动、500 ms 下行停顿。待处理输入峰值为 6/8/11/16/24；停顿达到 24 个输入上限后预测暂停。这是 TCP 字节流延迟/停顿实验，不是 IP 丢包或 OS 网络整形测试。
- CPU 采样环境为 GCC 15.2、RelWithDebInfo FlyWow Native 和独立 Lua Core。1/16/32 场、每场 3 单位时 Tick p99 约 2.65/5.84/6.45 ms，最大约 2.67/7.43/6.47 ms。A* 预算启用后，16/32 场尾延迟从同一压力模型下约 42/86 ms 降至约 6 ms。这是单机 Core 压测，不代表生产容量或端到端时延。

## 尚未覆盖

- 没有测真实 IP 丢包、OS 网络整形、长时间 soak、完整 Native RSS、多机或生产容量。
- 没有运行 ASAN/TSAN，也没有人工检查画面质量、弹丸观感和操作手感。
- 已验证 Windows x64 DLL 与 Editor；其他平台未验证。
- 状态回放播放有限权威状态轨迹与语义事件，不重新执行 Battle Core，不提供帧同步回滚。
- Battle Worker 进程崩溃后的状态持久化恢复属于独立专题。

## 关键入口

- 课程导读：docs/Skynet_BattleNavigation第三课_状态同步版_实操.md
- 课程合同：codex/LESSON_03_SPEC.md
- Server 配置与运行：server/config/state_sync.lua、server/scripts/lessons/lesson3_run_state_sync.sh
- 权威模拟/复制：server/lualib/battle/state_sync/runtime.lua、replication.lua
- Service：server/service/battle/state_sync/main.lua、dispatch.lua、worker.lua
- 协议唯一源：shared/protocol/navigation_query.proto
- Unity 客户端：unity/BattleNavigation/Assets/BattleNavigation/client/state_sync/
- Native 预测：server/native/state_sync/
- FlyWow Navigation 合同：server/third_party/skynet-flywow/navigation/CONTRACT.md

没有执行 commit、push、切换分支或另一工作区 Git 同步。
