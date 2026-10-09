# 职责：把隔离验证后的完整源码与分阶段教学写入WSL文档源。
# 不修改当前Server/FlyWow，不提交、不推送、不覆盖Windows文档。
from pathlib import Path
import runpy
import shutil
import json

author_source=Path(__file__).with_name('complete_author.py')
if not author_source.exists(): author_source=Path('/mnt/g/simbi/dev/skynet-battle-navigation-commercial-learning/.frame_complete_author.py')
A=runpy.run_path(str(author_source))
R=A['R']; S=A['S']; F=A['F']; META=A['META']
# 进程配置必须是Skynet配置沙箱可执行的完整文本；沙箱没有dofile。
for role in ['battle','gateway']:
    path='server/config/frame_'+role+'_process.lua'
    F[path]=F[path].replace('dofile("./config/'+role+'_process.lua")',(R/('server/config/'+role+'_process.lua')).read_text().strip())
parts=[]
def prose(value): parts.append(value.strip()+'\n\n')
def source(path,operation='新建'):
    language,why,focus=META[path]
    prose(f'### {path}\n\n**操作：{operation}。** {why}\n\n学习导航：精读 {focus} 可以略读固定声明与语言样板。输入、输出和失败语义见文件头及 API 注释；本节验证命令在该阶段末尾。阅读后应能解释这些状态的 owner、修改时机和释放位置。\n\n```{language}\n{F[path]}```')

prose(r'''
# 第三课：帧同步版——从玩家输入到可预测、可恢复的实时战斗

本课从**完成第二课后的仓库**开始。按本文逐节创建文件、修改 Gateway、生成协议、构建 Native、启动双进程，再接入 Unity；不需要旧第三课代码，也不运行旧第三课启动脚本。状态同步版是另一套独立课程，本文件不实现它。

本文交付的是实操步骤和完整源码。当前工作区的 Server/FlyWow 不会因为文档编写而提前安装这些改动，**Gateway 修改也由你在第 3 节亲自完成并审计**。作者验证使用隔离目录，具体已验证与尚未验证项目见最后一节。

## 0. 最终效果与学习顺序

### 0.1 本课玩法

- 玩家控制地面单位 `1001`：WASD 移动，J 近战，K 表现弹丸，L 逻辑火球。
- Server 控制地面敌人 `2002` 和飞行敌人 `2001`，自动寻找最近的活敌人并接近、施法。AI 不依赖墙钟、浮点物理或客户端 Transform。
- 飞行敌人会水平飞行和升降。`2000mm` 只是出生高度；不是运行时固定高度。AI 根据目标当前位置和地表穿透限制调整高度。
- 消灭全部敌方单位结束；双方同帧死亡判平局。没有组队、掉落、奖励或结算界面。180 秒仍未结束判平局，避免一场 Battle 无限持有输入日志。

地面玩家/地面敌人受 BMAP 通行与地表规则限制；飞行敌人不使用地面 A*、walkable 或 clearance 作为空中阻挡。当前资产是 2.5D 地表 Grid：飞行只验证 XZ 地图边界、单位不得穿过地表，以及规则定义的 `10000mm` 世界高度上界。飞行高度在这个范围内变化，不是固定层。真正的立体建筑/天花板/禁飞体积需要对应空域资产；不能把地表 Grid 包装成已经支持三维空间碰撞的 NavMesh。

### 0.2 你会真正实现什么

|阶段|当前问题|可观察产物|
|---|---|---|
|1|第二课一次性模拟不接收在线输入|冻结新玩法、输入与固定帧合同|
|2|两端各自算战斗容易分歧|同一 C++17 Core、Checkpoint、确定性测试|
|3|Gateway 拒绝目标连接的主动消息|你亲自修改的定向 push 合同与审计测试|
|4|网络 DTO 与模拟状态不能混为一层|唯一 Proto 的兼容扩展与生成 Registry|
|5|实时 Battle 要跨消息保持生命周期|Runtime、Worker、Dispatch、双进程入口|
|6|先验证 Server 真链路，再调表现|真实握手/推帧/重连/输入回放集成测试|
|7|Unity 不能在 Update 阻塞读网络|有界长期连接、主线程双模拟实例|
|8|玩家不能等一次 RTT 才看到动作|本地预测、输入确认、恢复重演、表现收敛|
|9|结束后要证明输入能还原逻辑|分页日志、输入回放、逐帧状态 hash|
|10|本机正常网络不是性能结论|跨平台 Golden、失败审计、网络与容量验证|

### 0.3 当前基线与编辑位置

固定 Skynet v1.8.0、自带 Lua 5.4.7、C++17、团结引擎 1.10.0（Unity 2022.3 LTS）、AI Navigation 1.1.7、protoc 36.2。FlyWow 使用当前固定 submodule，不静默升级。

**WSL 操作**指主工作区 `/home/simbi/workspace/skynet-battle-navigation-commercial-learning`。Server、FlyWow、协议源、文档在这里修改。**Windows 操作**指 Unity 工作区 `G:simbidevskynet-battle-navigation-commercial-learning`。Unity C#、Scene、插件设置在 Windows 操作。非 Unity 文件通过工作区 Git 流程交付；不要用另一份目录覆盖未提交修改。本文中的 Git 同步步骤由你按实际提交与审核节奏执行，作者不代替你提交或推送。

先在 WSL 仓库根目录执行只读检查：

```bash
cd /home/simbi/workspace/skynet-battle-navigation-commercial-learning
git status --short
git -C server/third_party/skynet-flywow status --short
git submodule status
test -x server/third_party/skynet/skynet
test -x server/third_party/skynet/3rd/lua/lua
test -x server/third_party/protoc-36.2/bin/protoc
test -f shared/navigation/battle_1001/battle_1001.bmap
test -f shared/navigation/battle_1001/battle_1001.manifest.json
```

若已有同名 `frame_sync` 文件，先审阅其内容；不要无条件覆盖你的学习修改。本课新建 `config/frame_sync.lua`，不会要求覆盖已有 `config/battle.lua`。第二课 Gateway/Battle 入口继续独立使用原端口；新版本客户端 TCP 端口为 `19021`，Cluster 为 `2537/2538`。

## 1. 同步合同：确认输入帧，双方按相同规则推进

### 1.1 一帧到底同步什么

Server 每 `50ms` 截止并执行一个逻辑帧，正常出站消息是：`battle_id + generation + FrameRecord(input,supplied,hash)`。位置变化不立即插入另一次模拟或另一个额外帧，施法意图也是目标帧的一部分。每帧只有一条权威采用的玩家输入；敌方 AI 输入由确定性 Core 根据该帧状态派生。

这属于帧同步：正常网络传输入帧，不持续传单位完整状态。Server 同时运行 Core 校验规则，并决定哪些输入被正式采用，防止客户端把位置、HP、技能命中或状态 hash当作可信结果。加入、断线恢复与分歧恢复是控制流程，允许传完整 Checkpoint；**恢复传状态不会把正常同步协议变成状态同步**。

```mermaid
flowchart LR
  P[Unity 按键] --> C[本地预测 Core]
  P --> N[长期 TCP 连接]
  N --> G[FlyWow Gateway]
  G --> X[Frame Proxy / Cluster]
  X --> D[Frame Dispatch]
  D --> W[Worker 截止输入帧]
  W --> S[Server Core]
  S --> R[正式输入帧 + hash]
  R --> G
  G --> U[Unity confirmed Core]
  U --> B[从确认状态恢复并重演未确认输入]
  B --> C
  C --> V[渲染位置与可撤销表现]
```

### 1.2 为什么仍然有本地预测

若 RTT=100ms，先提交输入、等 Server 回来再启动移动，手感会直接承担这个 RTT。本课 Unity 在下一次本地固定步就使用按键意图推进预测 Core；施法按键在当前渲染帧先显示可撤销黄闪。Server 结果到达后，confirmed Core 用正式输入推进并核对 hash，predicted Core 从 confirmed Checkpoint 恢复，再重演还未确认的意图。

例如 confirmed=40、predicted=43：Server 正式采用第 41 帧的补缺输入而没有采用本地预测的右移。confirmed 执行 Server 的 41；predicted 恢复 confirmed 的 41，依次重演仍保留的 42、43。正式 HP、死亡与结束读取 confirmed；渲染位置可以读取 predicted，并做短时间收敛。Transform 不写回 Core。

初始预测提前两帧，Server 创建后给两个 Tick 的准备时间。提前量是明确的调度参数，不是用 `Time.deltaTime` 推断正式帧号。最多允许比确认帧前进 8 帧；网络停顿超过窗口时停止继续猜测，并通过恢复入口获取新的正式状态。课程默认两帧提前量适合本地及稳定低 RTT 验收，不保证所有公网 RTT；最后一节要求在实际延迟条件下记录窗口失败与恢复行为。

### 1.3 缺输入、迟到与追赶

|情况|正式规则|
|---|---|
|某帧按截止时间收到输入|采用它，`supplied=true`|
|缺输入|最多保持上次方向两帧，之后停止；技能永不沿用|
|输入帧不大于已完成帧|`LATE`，不能改写历史|
|未来帧超过当前帧+8|`INPUT_WINDOW`|
|同一未来帧重复相同输入|幂等 `OK`|
|同一未来帧不同输入|`CONFLICT`，首个接受值保持不变|
|Worker 落后墙钟|最多连续补 4 帧；逐帧执行和记录，不扩大 dt、不跳帧|
|超过追赶预算|本场显式 `OVERLOAD`，停止并保留短期诊断/回放状态|

这里不会为了等一个连接而阻塞整个 Worker。一个 Worker 拥有多场 Battle，每场各自保存输入截止、当前帧与 Native 实例。

### 1.4 传输选择

本版复用已经存在的 FlyWow TCP 长连接、应用握手与 Protobuf。TCP 保证字节流有序到达，不保证低延迟：丢包会导致队头阻塞。帧号、缺输入规则、窗口、确认与恢复仍由 Battle 定义，不能把 TCP 的可靠性当作业务确认。

本课不会另外创造一套 UDP 会话/加密/拥塞控制。商业产品能选择可靠流或成熟的数据报传输，取决于目标网络与玩法；帧同步并不由 TCP/UDP 决定。这里明确保留 TCP 的队头阻塞风险，最后给出实际延迟/丢包验证步骤，不宣称本机验收证明所有公网实时场景。

## 2. 先做可恢复的确定性模拟，不先堆网络文件

### 2.1 坐标与状态

长期单位位置是有符号 64 位毫米 `x/y/z`。`GridPos` 只出现在导航内部；Unity 显示才除以 `1000f`。地面高度来自 BMAP，空中单位的高度是可变逻辑事实。不能把物理 Rigidbody、NavMeshAgent、Transform 或动画回调用于正式移动与命中。

本课每帧固定顺序：校验玩家意图 → 帧号递增 → 从帧开始状态产生 AI → 按 ID 移动 → 校验/施法 → 推进弹丸 → 同帧统一伤害提交 → 死亡/结束。最后统一伤害避免处理 ID 小者时先杀死另一方、取消对方已经应当发生的同帧攻击。

整数移动预算：`3000mm/s × 50ms / 1000ms = 150mm`。双轴分别 `106mm`，三轴分别 `86mm`；这是编译进规则的量化近似，不在不同平台调用浮点 sqrt。地面/空中子步不超过 `cell_size/4`，X、Z、Y 顺序固定。地面校验通行、clearance 和地表高差；空中只验证其自己的空间边界。飞行 AI 在障碍地表变高时爬升；接近目标时会调整高度，客户端按同样规则派生，不接受玩家发来的敌人坐标。

地面 AI 使用 FlyWow 现有 `GridPathfinder::FindPathStatic`；每个 Engine 独占 `NavigationContext` scratch。当前不保存路线缓存，所以恢复当前逻辑状态后可重新查询；scratch 的查询代数/堆槽不是玩法状态，不能直接序列化其指针。查询成本按地图与单位数增长，最后要求单独测 CPU；不会用“只有几个单位”替代这个成本说明。

### 2.2 技能基础框架

|技能|效果类型|目标移动类型|正式伤害发生时刻|冷却|
|---|---|---|---|---|
|J 近战|Instant|地面|施放成功的当前帧|12帧=600ms|
|K 表现弹丸|VisualBolt|地面/空中|施放成功的当前帧；之后飞行仅表现|24帧=1200ms|
|L 逻辑火球|LogicalBolt|地面/空中|弹丸到达目标的逻辑帧|24帧=1200ms|

定义与运行态分开：Skill 定义保存范围、冷却、伤害、Effect 与目标类型掩码；Unit 只保存各技能 ready 帧；Bolt 保存实例 ID、施法者、目标、过期帧、位置和到达伤害。施放失败不消费冷却，不创建弹丸。Target 根据合法类型选择最近活敌人，等距按 ID；正式距离包含高度，不再只算 XZ。

表现弹丸和逻辑弹丸都可由渲染器画出来，但前者 `damage=0`，到达/消失不会再打一次伤害。逻辑弹丸速度采用三轴 Chebyshev 长度的整数归一，400mm/帧，最多存在60帧；目标死亡或到期即移除。两种魔法弹丸在本玩法中忽略地面障碍，不声称实现了射线遮挡。施法黄闪只是即时预备反馈，不等于命中。

Unit.ready、Bolt.next_id/到期/位置/伤害、Unit.move_mode 和高度全部在 Checkpoint 中；回滚必须恢复它们，不能只把单位位置拉回。范围/伤害是业务定义，不塞进 Gateway，也不让导航模块依赖技能。

### 2.3 规范化 Checkpoint

不能 `memcpy(State)`：vector 内存、指针、padding 和编译器布局不同。这里逐字段写小端格式版本1。

|布局|字节数|内容|
|---|---:|---|
|头|20|version/frame/winner/next_bolt/unit_count，各uint32|
|每单位|52|id/camp/move_mode；XYZ各int64；hp int32；ready[3]各uint32|
|弹丸数|4|uint32|
|每弹丸|44|id/caster/target/expires/damage各4字节；XYZ各int64|

最大 `20 + 64×52 + 4 + 128×44 = 8984 bytes`，ABI 缓冲预算为16384 bytes。restore 先读候选值、验证版本/数量/范围/排序/引用，再唯一发布；坏状态不能留下半个新世界。每步异常也恢复旧 State。FNV32 用于逐帧分歧诊断，不用于抗作弊、安全身份或资产完整性；地图 SHA256 与规则源码 hash 独立校验。

### 2.4 新建 Native 文件

在 WSL 仓库中创建以下文件。Core 属于宿主玩法；FlyWow 提供导航和 Lua Binding 公共实现，不把本课技能写进 submodule，不复制导航源码。CMake 编译固定子模块中的原始 source；Windows 构建关闭 Lua Binding，保留同一 Core。
''')

for name in ['frame_core.h','frame_core.cpp','frame_binding.cpp','CMakeLists.txt','frame_test.cpp']:
    source('server/native/frame_sync/'+name)
source('server/tests/frame_binding_test.lua')
prose(r'''
### 2.5 第一次跨 Lua/C++ 边界怎样审计

`require "lesson_frame_native"` 查 `package.cpath`，加载 `server/build/frame_sync/lesson_frame_native.so`，Lua 自动调用 `luaopen_lesson_frame_native`。每个 Service 都有独立 Lua State/module cache；同一 OS 进程可以多次进入 open。每次 `native.open()` 创建独占 Engine userdata，不能把可变 Engine 当成共享全局对象。

Owner 存 Native handle：显式 close 把它设为 null；GC 只析构 userdata 里的 Owner 一次，所以不会重复释放旧 handle。Binding 读取参数失败使用返回值 `nil,error`，不依赖 Lua longjmp 穿过 C++ 局部析构。LuaTable/LuaBinding 的栈与 registry reference 机制由固定 FlyWow 的 `lua-binding/` 实现，调用方借用 userdata 至当前回调结束，不把其裸指针跨 yield 保留。

先仅构建新 Core，不启动 Server：

```bash
cd /home/simbi/workspace/skynet-battle-navigation-commercial-learning/server
cmake -S native/frame_sync -B build/frame_sync -DCMAKE_BUILD_TYPE=Release
cmake --build build/frame_sync --parallel 4
ctest --test-dir build/frame_sync --output-on-failure
./third_party/skynet/3rd/lua/lua tests/frame_binding_test.lua
```

预期 CTest `frame_native` 通过，Lua 输出 `FRAME_BINDING_OK`。`frame_test` 对两独立实例、restore后重演、坏Checkpoint保持旧状态、非法输入原子失败、飞行敌人高度变化做断言。它输出每帧 `GOLDEN frame hash`，后面与 Windows 比较；这里只证明当前 Linux 实例，不提前宣称跨平台确定性。

失败排查：`MAP_LOAD` 看相对工作目录与BMAP；`SPAWN_BLOCKED` 核对资产版本/出生点；`module not found` 核对 `.so` 名称、cpath 和构建路径；`undefined symbol lua_*` 必须使用Skynet固定Lua，不能随便换系统 Lua 5.3；DLL/so 不是可以跨OS复制使用的同一二进制。

## 3. 由你修复 Gateway 定向主动消息，并先审计

### 3.1 当前拒绝的具体含义

`connection_id>0` 指定一个已经建立的逻辑连接；`request_id=0` 表示主动消息，不属于某个客户端请求的响应。这两个字段并不矛盾。当前 `flywow_gateway.lua` 的 `deliver_data()` 把这个组合当成非法；因此业务虽然产生正式FramePush，却发不到特定玩家。

只允许 `connection_id=0/request_id=0` 的广播不能作为替代：广播会把某场战斗输入发给所有连接。也不能伪造一个旧非零request_id，把主动帧塞到控制请求的等待表。

### 3.2 局部修改 FlyWow Runtime

**操作：局部修改。WSL 子模块文件：**

`server/third_party/skynet-flywow/gateway/service/gateway/flywow_gateway.lua`

只在 `deliver_data(message)` 的参数拒绝条件中，删除这一条：

```lua
        (message.connection_id > 0 and message.request_id == 0) or
```

保留相邻的广播关联检查：

```lua
        (message.connection_id == 0 and message.request_id ~= 0) or
```

不要删除其它类型、整数、epoch、阶段、命令、编码和长度检查。后面的目标连接分支已经按 id 找连接并检查 ready；不需要改成广播循环。修改后的合同：

|connection_id|request_id|含义|
|---:|---:|---|
|>0|>0|该连接的关联响应|
|>0|0|该连接的主动推送|
|0|0|所有ready连接的主动广播|
|0|>0|非法，拒绝|

这是 FlyWow 接入合同的通用修复，代码仍不认识Battle。旧第二课 `server/service/gateway/gateway_proxy.lua` 自身还有“指定连接必须非零request_id”的验证；**本课使用独立 Frame Proxy**，其合同在第5节给出，所以不要求修改旧第二课Proxy，也不暗中依赖它突然支持主动帧。

### 3.3 完整替换审计测试

下面是完整测试文件，保留原关联响应、异步派发、旧epoch与广播用例，再新增两个连接的定向推送审计。握手替身 `ready` 由场景开关控制；它只验证 Gateway 对 ready 的处理，不冒充真实握手密码学测试。调试器替身避免单测引入宿主调试环境。
''')
source('server/third_party/skynet-flywow/gateway/tests/gateway_async_test.lua','完整替换（先比较你已有测试修改）')
prose(r'''
### 3.4 先证明测试能抓住旧错误

先放入测试，**暂不删除旧拒绝条件**，从Server工作目录执行：

```bash
./third_party/skynet/3rd/lua/lua \
  third_party/skynet-flywow/gateway/tests/gateway_async_test.lua \
  third_party/skynet-flywow
```

预期在 `target push must not broadcast` 断言失败。再按3.2删除条件，重新执行，预期 `GATEWAY_ASYNC_UNIT_OK`。

审计时逐条回答：指定连接是否只写对应fd？出站request_id是否仍为0？旧epoch、未ready、已关闭、不存在的目标是否直接丢弃？未知目标是否错误退化为广播？非零request_id广播是否仍拒绝？已有请求响应是否仍通过？源码是否保留编码失败不误关健康连接的行为？

本测试没有新增回复来源身份认证。Gateway 当前信任宿主Service边界；新 Frame Proxy对断线来源与绑定Gateway handle做检查，Worker只接收其Dispatcher。Cluster应处于可信部署网络。这些来源边界与这次“允许指定连接request_id=0”修复是不同的审计项，不能看到消息可达就说所有身份校验通过。

暂不因为教程要求而自动commit/push。你审计通过并决定发布时，按WORKSPACE_WORKFLOW：FlyWow子模块先形成已验证提交并推送，主仓库再更新submodule指针，随后Windows同步。提交标题与正文用中文。本文后续步骤在你的当前已修改WSL工作树中也能验证，不要求提前发布一个未审计版本。

## 4. 兼容扩展唯一 Proto，不手写第二份命令表

现有 `QueryCell=1001`、`RunAutoBattle=1002` 与字段号不改变，Envelope仍protocol_version=3。新增命令的 `XxxRequest/XxxResponse` 由FlyWow生成器识别：FrameInput只有Request，FramePush只有Response；输入单向发送，FramePush使用request_id=0。

**操作：局部修改 `shared/protocol/navigation_query.proto` 的CommandId，添加：**

```proto
  FRAME_JOIN = 1101;
  FRAME_INPUT = 1102;
  FRAME_PUSH = 1103;
  FRAME_RECOVER = 1104;
  FRAME_LEAVE = 1105;
  FRAME_REPLAY = 1106;
```

**操作：在同一个Proto文件末尾追加以下完整messages。** `.proto.inc`只是本文作者组织片段的名字，不是你要创建的第二份协议文件；不要新增运行时协议源。
''')
prose('```proto\n'+F['shared/protocol/frame_sync_messages.proto.inc']+'```')
prose(r'''
### 4.1 消息的业务意义

Join只选择已发布scenario_id，不携带位置、HP或Native状态。Server回传初始身份与Checkpoint。`battle_id` 是本进程不复用的战斗ID；`generation` 在恢复时递增，防止旧连接的合法旧消息写入新会话。`gateway_epoch/connection_id` 是Server内部传输身份，不是账号。

`resume_token` 是32bytes操作系统随机恢复凭据，当前没有账号登录，所以不把connection_id当作永久身份。凭据仅在控制响应中交给该客户端，恢复/回放时验证；不能写日志，也不放进保存的回放。P-256应用握手不等于登录，也不加密之后的业务数据；实际部署的链路保护与账号系统仍按各自接入层处理。

### 4.2 生成Server合同

WSL仓库根目录：

```bash
./server/protocol/build_server_descriptor.sh
python3 server/third_party/skynet-flywow/gateway/tools/generate_gateway_registry.py \
  --proto shared/protocol/navigation_query.proto \
  --output server/lualib/gateway/protocol/navigation_registry.lua
rg -n 'FRAME_|FrameInput|FramePush' server/lualib/gateway/protocol/navigation_registry.lua
```

预期descriptor非空、输出 `SERVER_DESCRIPTOR_OK`；Registry的FrameInput为request_type且response_type=nil，FramePush为request_type=nil且response_type。不要手工编辑生成物来“补推送支持”。

协议源按双工作区流程到Windows后，在Windows仓库根执行：

```powershell
./shared/protocol/build_unity_cs.ps1
```

该脚本将唯一Proto生成到现有 `Assets/BattleNavigation/Scripts/Protocol/NavigationQuery.cs`，保持已有Google.Protobuf引用。不要再把WSL生成的另一份同名C#放入Assets，否则相同类型重复定义。

失败排查：命令没有Request/Response是命名前缀不匹配；descriptor旧是没有重新生成/重启；Server与Unity使用不同map_hash/rules_hash是发布身份不一致；协议枚举编号不能因为重新排列就改变。

## 5. 实时Runtime与Worker：时间在调度层，规则在Core

### 5.1 状态ownership

|owner|持有内容|释放位置|
|---|---|---|
|Gateway|listen/client fd、握手、codec、写缓冲|连接关闭/进程停止|
|Frame Proxy|本地Gateway handle、固定Cluster目标|进程结束；不持有Battle等待表|
|Frame Dispatch|Worker handles、Battle ID分配|进程结束|
|Worker|Battle索引、会话/凭据/代数、截止时间|leave/保留期到期摘除|
|Runtime|pending输入、正式帧日志、Native Engine|Worker调用core.close|
|Engine|单位/冷却/飞行/弹丸逻辑State、私有导航scratch|userdata显式close，GC兜底|
|Unity Controller|confirmed/predicted Native、未确认输入、表现对象|OnDestroy|
|FrameConnection|Socket、读写线程、有界队列、控制等待|Dispose关闭Socket解除读阻塞|

Worker的 `M.step()` 不yield，正式状态修改是顺序事务。`skynet.call` 控制流程可能yield；入站route是pack/unpack后的值record，不借用Gateway连接对象。回复携带原epoch/id，Gateway再次核对连接有效性；不能把fd跨Cluster传给Worker。

### 5.2 先创建运行预算与资产验证

下面配置是新的独立配置，不覆盖现有battle.lua。容量是每Worker128场、4个Worker；这不是吞吐承诺，后面必须测当前地图、技能与部署机器。输入窗口8、每消息最多8输入、日志最多3600、回放页256、结束/断线保留30秒，都对应本功能确实持有的状态。
''')
source('server/config/frame_sync.lua')
source('server/scripts/lessons/prepare_frame_sync.py')
prose(r'''
WSL Server工作目录执行：

```bash
python3 scripts/lessons/prepare_frame_sync.py
```

预期 `FRAME_ASSET_OK`，生成 `config/frame_sync_asset.lua`。它保存已验证的map_id/version/hash，Runtime不读取Unity工程，也不读取开发机绝对路径。manifest文件的真实名称是 `battle_1001.manifest.json`；不是泛称 `manifest.json`。

### 5.3 Runtime：复制意图，记录实际采用输入

Runtime只管理本场的输入窗口与Core调用，不注册Service、不读网络、不以客户端时间推进。`pending`最多window条；一条输入被接受后不可改写。`records`保存实际被执行的补缺或玩家输入，不是发送方声称已执行的输入。Checkpoint只在加入/恢复/客户端重演时使用，Server不为每帧保留完整状态历史。
''')
source('server/lualib/battle/frame_sync/runtime.lua')
source('server/tests/frame_runtime_test.lua')
prose(r'''
```bash
./third_party/skynet/3rd/lua/lua tests/frame_runtime_test.lua
```

预期 `FRAME_RUNTIME_OK`。这个测试使用Native替身，只证明窗口/缺输入/关闭合同，不把它称作真实Native或网络集成。

### 5.4 Worker：每场独立截止与会话

创建时先读随机凭据，再创建Native，避免I/O失败后遗留Engine。每场到期执行最多4次；一次超预算不能影响其它场的正式帧号。Recover校验token后代数递增、替换传输会话、清除旧未来输入和方向，返回当前正式Checkpoint；不会让旧输入跨会话继续施法。

断线后保留30秒，仍按明确缺输入规则推进；结束也保留30秒供读取日志。leave直接标记移除。清除Battle时先摘索引再close，回放凭据到期后返回NOT_FOUND。这里没有把断线暂停所有AI或无限保留日志当成默认行为。
''')
source('server/service/battle/frame_sync/worker.lua')
prose(r'''
### 5.5 Dispatch与组合根

Dispatch启动固定数量Worker，把自身handle显式注入。`(battle_id-1)%workers+1` 是当前进程中的稳定分片；ID单调增加、不复用，也不在线重排Worker。控制Join/Recover/Replay/Leave使用call取得响应；输入与权威推帧用send。超时不会让Gateway停止读取其它帧。

`cluster.open` 参数是reload中配置的**节点名**，不是直接传 `127.0.0.1:2538`。后者会被当成节点名查找并报is down。`cluster.register` 的固定跨进程边界与本地Service handle注入是两件事。
''')
for path in ['server/service/battle/frame_sync/dispatch.lua','server/service/battle/frame_sync/main.lua','server/service/gateway/frame_sync/proxy.lua','server/service/gateway/frame_sync/main.lua','server/config/frame_battle_process.lua','server/config/frame_gateway_process.lua']:
    source(path)
prose(r'''
### 5.6 把新Native接入现有公开build入口

**操作：局部修改 `server/scripts/linux/run_server.sh`，完整替换其中 `run_build()` 函数：**

```bash
run_build() {
    prepare_runtime
    "$SCRIPT_DIR/check_lua_varargs.sh"
    cmake -S "$SERVER_ROOT/native/frame_sync" \
      -B "$SERVER_ROOT/build/frame_sync" -DCMAKE_BUILD_TYPE=Release
    cmake --build "$SERVER_ROOT/build/frame_sync" --parallel 4
    ctest --test-dir "$SERVER_ROOT/build/frame_sync" --output-on-failure
    python3 "$SERVER_ROOT/scripts/lessons/prepare_frame_sync.py"
    log "BUILD_OK"
}
```

FlyWow仍由prepare_runtime调用固定子模块的 `scripts/build_flywow.sh`，不新建第二个公共build脚本；本课只在宿主入口追加玩法Native和资产验证。新启动配置完整列出路径：Skynet配置求值环境没有dofile，不用 `dofile(base_config)` 隐藏依赖。

执行：

```bash
./scripts/linux/run_server.sh build
./third_party/skynet/3rd/lua/lua tests/frame_binding_test.lua
./third_party/skynet/3rd/lua/lua tests/frame_runtime_test.lua
```

预期各CTest和两Lua测试通过，最后build输出BUILD_OK。不要使用旧第三课的online启动命令；新进程入口如下。

## 6. 先运行真实双进程，再打开Unity

### 6.1 启动、停止与日志

WSL终端A，从server目录启动Battle：

```bash
./third_party/skynet/skynet config/frame_battle_process.lua
```

WSL终端B，从server目录启动Gateway：

```bash
./third_party/skynet/skynet config/frame_gateway_process.lua
```

日志分别写 `server/logs/frame_battle/日期.log`、`server/logs/frame_gateway/日期.log`。终端C检查：

```bash
rg -n 'FRAME_BATTLE_READY|FRAME_GATEWAY_READY|failed|error' logs/frame_battle logs/frame_gateway
ss -ltnp 'sport = :19021 or sport = :2537 or sport = :2538'
```

预期两个READY以及三个监听端口。主Service执行 `skynet.exit()` 仅退出组合根，不会关闭Worker/Gateway；停止这两场前台进程分别在对应终端Ctrl+C。不要用 `pkill skynet` 杀掉其它正在学习的进程。

### 6.2 新建真实链路测试

下面测试复用第二课已有 `server/tests/gateway_handshake_client.py`，以实际P-256握手进入Gateway，使用真实TCP/Proto/Cluster/Worker/Native。测试中的通用Protobuf wire解析只属于Test；Runtime仍由唯一Proto生成的descriptor/Registry实现。它无需另外安装Python Protobuf，但需要第二课已经安装的cryptography。
''')
source('server/tests/frame_sync_integration.py')
prose(r'''
WSL终端C执行：

```bash
python3 tests/frame_sync_integration.py
```

预期 `FRAME_INTEGRATION_OK frames=... generation=2`；帧数可能因调度在17/18等相邻值，不把日志的墙钟调度差异当成模拟分歧。断言逐帧连续和hash，不依赖固定网络包到达时刻。

此测试覆盖两独立Battle定向推送、输入采用后的Native重演、错误凭据拒绝、断线恢复代数更新、Checkpoint恢复、第一页日志重演以及回放不包含凭据。它不是完整的容量压测，也不是Unity表现验收。

失败排查顺序：无监听先看启动日志；有监听握手失败看FlyWow握手模块和固定版本；Join超时看Registry和两端Cluster节点名；Join成功无push回第3节审计条件；STATE_DIVERGENCE先比资产/规则hash，再比规范化字段，不通过强制覆盖客户端状态掩盖固定规则错误。

## 7. Windows构建同一Core，接入实际Unity客户端

### 7.1 Windows DLL

把已审核的WSL非Unity源码按Git流程同步到Windows工作区，确认相同submodule提交。Windows必须有C++17编译器与CMake；在相应Developer PowerShell中，仓库根执行：

```powershell
cmake -S server/native/frame_sync -B server/build/frame_sync_windows -A x64 -DLESSON_FRAME_LUA=OFF
cmake --build server/build/frame_sync_windows --config Release --parallel 4
ctest --test-dir server/build/frame_sync_windows -C Release --output-on-failure
New-Item -ItemType Directory -Force unity/BattleNavigation/Assets/BattleNavigation/Plugins/FrameSync | Out-Null
Copy-Item -LiteralPath server/build/frame_sync_windows/Release/frame_core.dll -Destination unity/BattleNavigation/Assets/BattleNavigation/Plugins/FrameSync/frame_core.dll
```

多配置生成器的Release产物在Release目录；使用单配置生成器时按CMake实际输出目录取DLL，不盲目假定路径。不要把Linux `.so` 改名成 `.dll`。Unity Plugin Inspector中禁用Any Platform，只启用Windows Editor/Standalone、CPU x86_64；这是本课Windows客户端的发布目标，不宣称已验证Android/iOS/WebGL。修改/重建DLL前退出Play并释放Native实例，必要时重启Editor解除DLL文件占用。

FlyWow握手继续使用前两课已部署的 `Assets/BattleNavigation/Plugins/FlyWow/FlyWow.Gateway.dll` 与BouncyCastle DLL，Google.Protobuf继续使用已有插件，不再复制SDK源码到Assets形成第二份类型。

### 7.2 Native桥：声明与规范化读取必须同源

下面三个文件在Windows Unity工程新建，放进现有 `Assets/BattleNavigation/client/`，属于已有BattleNavigation.Replay程序集，它已经引用生成Proto所在的BattleNavigation.Client程序集。不要另建一个缺引用的asmdef。
''')
for name in ['FrameNative.cs','FrameConnection.cs','FrameBattleController.cs']:
    source('unity/BattleNavigation/Assets/BattleNavigation/client/'+name)
prose(r'''
## 8. 接线与观察：每一步有具体证据

### 8.1 准备场景与发布资产

1. Unity打开已有 `Assets/BattleNavigation/Scenes/Battle_1001.unity`。执行Save As，保存为 `Battle_1001_FrameSync.unity`，保持静态地形、Camera、Light；不要再次运行地图重建/Bake菜单覆盖手工修改。
2. 在新场景中禁用第二课的 `BattleReplayRuntime` 或挂有旧Replay组件的运行对象，避免它同时生成另一批单位。原第二课场景保持独立可运行。
3. 新建空GameObject `FrameBattleRuntime`，Add Component `FrameBattleController`。Inspector设置Host=`127.0.0.1`、Port=`19021`、ReplayPath留空。
4. 保证 `Assets/StreamingAssets/navigation/battle_1001.bmap` 是第二课发布的同一BMAP。若尚无此文件，创建该目录并从Windows已发布 `shared/navigation/battle_1001/battle_1001.bmap`复制这个客户端消费文件。不是让Server读取Unity目录。
5. 先完成第4节Unity协议生成，让Editor编译；Console不能有重复Proto类型、找不到FramePush或DllNotFound。保存新场景。

如果Windows到WSL的localhost转发在你的WSL网络模式中不可用，Host填写可达WSL地址并调整Gateway监听地址；不要把Windows驱动器绝对路径写进Server Runtime。默认验收只监听127.0.0.1。

### 8.2 正常Play验收

保持第6节双进程运行，Unity进入Play。画面出现地面玩家和两个敌人；飞行敌人出生在高处，然后AI根据目标移动与升降，HUD显示其mode=2和变化的Y毫米值。地面敌人mode=1，按地面规则寻路。

按WASD：玩家应在本地固定步响应，不等网络控制响应。HUD server/predicted帧递增，predicted通常领先少量帧。靠近障碍时地面单位不穿过阻挡，飞行敌人可越过地面障碍但不能穿透地表。玩家没有升降按键。

按J/K/L：立即黄闪是可撤销预备反馈；J只能命中地面目标；K正式伤害发生在施放成功帧，球飞到目标不再扣一次；L正式伤害在逻辑球到达帧才发生。HP与死亡HUD来自confirmed，不使用黄闪或粒子碰撞作为命中证据。无合法目标/距离不足/冷却未结束时Server Core不消费冷却、不扣血。

GameObject Collider被移除，Unity物理不参与战斗。Unit Transform是predicted位置的表现收敛；Native State才是逻辑位置。飞行Y同样是Native整数坐标，不靠Animator抬高模型替代。

### 8.3 预测、回滚和表现

Controller保留两个Native实例：confirmed只执行Server正式帧，predicted执行未来本地意图。未确认输入表不是另一个全局共享Battle；恢复会清空它。每次正式输入到达，先严格验证连续帧和hash，再恢复/重演。正常重复帧可忽略；中间缺帧不能直接跳到最新帧。

表现对象以逻辑unit_id/bolt_id索引。回滚后不存在的Bolt被销毁，新Bolt重新创建；不会用一次性粒子回调重复结算伤害。Material由Controller明确拥有，销毁对象时释放；OnDestroy先关闭网络，再释放Native和表现对象。渲染Lerp只处理显示误差，不允许Lerp后的Transform影响下一步逻辑。

`rollbackCount`是同一预测帧重演后字节hash变化的观察计数；不是抗作弊指标，也不是所有权威确认次数。你还应同时观察正式frame、未来窗口和错误code，不能只盯一个数字判断同步正确。

### 8.4 断线和超窗恢复

关闭Gateway会使读线程或控制请求显式失败，Controller停止继续预测。Battle进程仍运行时，30秒内重启Gateway，点击“重连/权威状态恢复”：新连接重新握手，提交battle_id/token；Server generation递增，返回当前Checkpoint，客户端清掉旧未来输入，重新建立预测提前量。

若是纯客户端网络断线，也通过相同恢复按钮重新建立连接。超过保留期/错误token返回NOT_FOUND；不能悄悄新建另一个Battle冒充原场恢复。若Battle进程重启，内存Battle已不存在，本课没有数据库恢复，不假装resume_token能还原已经销毁的Server状态。

若发生FRAME_GAP、STATE_DIVERGENCE或PREDICTION_WINDOW，停止预测并通过同一入口请求正式恢复。反复分歧要审计源码/资产；恢复按钮不是修复确定性错误的方式。此实现让恢复显式可观察，不设置未说明的无限自动重试。

## 9. 输入回放：与旧第二课事件播放器独立

### 9.1 保存

战斗结束后30秒内点击“保存结束战斗输入回放”。客户端按256帧分页拉取日志，组装FrameReplay，写到 `Application.persistentDataPath/frame_last.pb`，HUD显示实际路径。第一页面携带初始Checkpoint及map/rules身份，但没有resume_token。单场不超过3600帧；保存是结束后的控制任务，不把每帧完整世界状态作为常规消息。

保存文件包含正式采用输入与逐帧hash，不包含客户端曾发送但被拒绝/迟到的意图。`supplied=false` 的补缺输入同样要保存，因为它也影响正式位置和技能。

### 9.2 离线播放

退出Play；Inspector将ReplayPath设置为刚保存文件的完整路径，再进入Play。无需连接Gateway，Controller验证格式版本、大小、地图hash、规则hash、初始Checkpoint，再按50ms逐条执行输入并核对每帧hash。你看到的是重新模拟的状态，不是旧Event Log根据墙钟播放动画。

修改回放输入或hash应得到REPLAY_DIVERGENCE；删除中间帧应得到REPLAY_FRAME_GAP；换BMAP或Native规则应得到ASSET_IDENTITY。不同规则版本的回放需要对应历史Core/资产包，本课不会拿当前规则“尽量播放”后仍声称结果正确。

## 10. 审计、失败验证与性能记录

### 10.1 每层证据不能混用

|层|执行项|证明什么|
|---|---|---|
|Native|CTest与Golden|相同逻辑输入、恢复与结果字节|
|Binding|frame_binding_test.lua|加载、实例隔离、返回错误、关闭|
|Runtime|frame_runtime_test.lua|窗口、幂等/冲突、补缺、不重复技能|
|Gateway|gateway_async_test.lua|定向push与旧合同边界；是替身单测|
|网络|frame_sync_integration.py|真实握手/Cluster/Worker/回放hash|
|Unity|Play和离线回放|预测手感、主线程边界、表现与生命周期|
|跨OS|Windows与Linux同一Golden输入|当前发布目标整数规则一致性|
|负载/网络|实际配置下计时与故障注入|预算是否适合目标运行条件|

### 10.2 你在实操时还要执行的负向用例

|操作|预期|观察点|
|---|---|---|
|先跑新Gateway测试但保留旧条件|定向push断言失败|证明测试抓得到旧错误|
|恢复旧epoch或不存在目标id|不写任一客户端|Gateway unit断言|
|握手未完成推送|丢弃|ready开关单测；真实连接不得先拿业务消息|
|发送已执行帧/未来9帧/同帧不同意图|LATE/INPUT_WINDOW/CONFLICT|正式历史与首个pending保持|
|恢复后旧generation发输入|拒绝，不影响新会话|Worker owns判定|
|另一连接操作本场但不提供token|不能写本场意图|epoch/id/generation归属|
|满Worker容量后Join|BUSY|不创建额外Native实例|
|Native输入错误或坏Checkpoint|nil/error，旧状态不变|真实Binding断言|
|Worker迟滞超过4帧预算|OVERLOAD|不skip帧，不扩大dt|
|Client不读socket|Gateway现有写缓冲规则关闭慢连接|不能无限保留消息|
|结束/断线30秒后恢复或回放|NOT_FOUND|索引摘除、Native close|
|反复Play/Stop/恢复|线程与Native对象释放|不留多个连接/渲染对象|
|替换规则DLL或地图版本|ASSET_IDENTITY|进入模拟前拒绝|
|删/改回放中间输入|GAP/DIVERGENCE|不能悄悄跳过坏帧|

测试每条时只注入一个变量，记录真实命令、错误code和状态变化。上表是实操验收，不等于作者已经对全部情况做了发布压力测试。

### 10.3 跨平台Golden

WSL Server目录：

```bash
./build/frame_sync/frame_test ../shared/navigation/battle_1001/battle_1001.bmap > /tmp/frame_linux_golden.txt
```

Windows仓库根：

```powershell
$windowsGolden = & ./server/build/frame_sync_windows/Release/frame_test.exe ./shared/navigation/battle_1001/battle_1001.bmap
$linuxGolden = wsl.exe -d Ubuntu -- cat /tmp/frame_linux_golden.txt
$differences = Compare-Object $linuxGolden $windowsGolden -SyncWindow 0
if ($differences) { $differences; throw '跨平台Golden不一致' }
'FRAME_CROSS_PLATFORM_OK'
```

要求逐行相同的frame/hash，不只比较最后赢家。不一致时比资产SHA、rules hash、源码换行、整型溢出/取整、导航tie-break和序列化字段。Windows源码应保留LF；规则身份以源码字节计算，CRLF转换会导致规则hash不一致。

### 10.4 性能与网络，不用样例规模代替预算

首先记录当前commit/submodule、编译器、Release/Debug、CPU、地图尺寸、单位/弹丸数与活跃Battle数。Native每帧序列化+hash成本按状态大小增长；AI A*成本受地图与单位数影响；Worker消息/CPU预算、Gateway写缓冲与客户端队列是不同层的边界。

对独立Native执行 `/usr/bin/time -v ./build/frame_sync/frame_test ...`只得到测试总成本，不是多人实时TPS。对真实Worker逐步增加独立连接与Battle，记录进程RSS、每Tick是否落后和OVERLOAD；达到配置上限必须BUSY，不通过提高所有上限掩盖失败。当前不提供已经验证的“每机支持多少万人”数字。

网络故障实验在你明确选定的测试接口执行Linux netem；不要给有其它任务的默认网络接口加全局丢包。先查 `ip route`与对应WSL本机通信接口，再在独立测试环境加延迟/抖动/丢包并移除规则。记录RTT、队头阻塞、迟到比例、预测窗口错误与恢复所需时间。对于50ms帧、提前2帧、最大8帧窗口，长时阻塞最终必须停止预测；不能无限猜测并将迟到输入写回旧历史。

真实运营前必须根据目标公网条件选择/验证传输、提前量与调度预算，Unity目标平台逐一跑确定性Golden。本文的运行核心、边界和失败机制可审计；本地测试不是所有网络/平台/容量的证明。

## 11. 原第三课知识点如何进入最终版

|原核心知识|本版实现|
|---|---|
|在线Battle生命周期|Worker持有场次、deadline、session、generation、retention|
|多Worker|固定分片、显式handles、每场独占Native|
|导航与动态状态边界|immutable BMAP；Engine私有scratch；地面与空中通行分开|
|AI|纯状态派生、最近目标、固定ID顺序、飞行升降|
|基础技能|Def/ready/Bolt分离，三种Effect，目标类型与高度距离|
|事件/状态观察|正式FrameRecord、hash、confirmed HUD与逻辑Bolt ID|
|Replay|初始Checkpoint+正式采用输入日志，重新模拟核对hash|
|断线恢复|凭据/会话代数、当前Checkpoint、清旧输入、保留期|
|客户端表现|可撤销即时反馈、预测位置、确认HP、回滚对象清理|

旧第三课Event Buffer、旧在线配置或旧Unity组件不是前置依赖。两版不为了共用模拟而增加复杂度；同一帧同步版本两端编译相同Core，是本版确定性合同的实现选择。

## 12. 本课完成检查

- [ ] 从第二课基线逐节创建文件，未依赖旧第三课业务实现。
- [ ] 你亲自完成并审计Gateway目标连接request_id=0修改，红/绿单测真实执行。
- [ ] 唯一Proto、descriptor、Lua Registry与Unity生成物一致。
- [ ] Native/Lua/真实双进程测试通过；报告失败路径与未验证项。
- [ ] 玩家地面操作快速响应；地面敌人寻路、飞行敌人水平移动与升降。
- [ ] 三种技能结算时刻可观察；高度影响正式距离/命中。
- [ ] 输入确认、预测、恢复重演、超窗停止、重连代数边界可解释。
- [ ] 结束输入回放不含凭据，逐帧hash一致。
- [ ] Windows/Linux Golden一致；Unity实际Play、网络故障与资源释放已执行。

### 作者验证记录

2026-10-10，代码在隔离目录编译/运行，未安装到当前Server/FlyWow源码。已执行Linux C++编译与Native CTest、Lua Binding/Runtime测试、Gateway替身单测、唯一Proto/Registry生成、真实双Skynet进程集成；Windows客户端使用现有Unity模块、Google.Protobuf和FlyWow SDK做C#编译。Windows Native与跨平台/客户端链路结果在验证记录中单独记载。

Unity Editor完整Play/场景表现、长期压力测试、所有网络故障及其它目标平台尚未由这些测试替代。按本课步骤实操时仍须完成对应验收，不把“源码可编译”写成“Unity游戏已联调通过”。
''')

document=''.join(parts)
document=document.replace('Server 每 `50ms` 截止并执行一个逻辑帧','Server 每 `50ms` 截止并执行一个逻辑帧；输入截止以 Worker 处理消息的时钟为准，Timer 晚执行不能重新开放过期帧')
document=document.replace('施放失败不消费冷却，不创建弹丸。','施放失败不消费冷却，不创建弹丸。逻辑弹丸满槽拒绝施法；表现弹丸满槽仅省略视觉飞行，正式伤害和冷却仍提交，避免表现资源决定战斗结果。')
document=document.replace('AI 根据目标当前位置和地表穿透限制调整高度。','AI 根据目标当前位置、水平距离与地表穿透限制调整高度：远距追击时抬高，接近时下俯；不是沿固定高度层移动。')
document=document.replace('Windows Native与跨平台/客户端链路结果在验证记录中单独记载。','Windows Release Native CTest 通过；Windows/Linux Golden 240行逐行一致；Windows C#客户端连接真实Linux Gateway，连续30帧调用Windows Native核对Server hash通过。Gateway红/绿测试已真实验证旧条件使定向推送断言失败、隔离修复后通过。C# Native句柄使用SafeHandle，主路径Dispose，P/Invoke借用时自动保活。')
target=R/'docs/Skynet_BattleNavigation第三课_帧同步版_实操.md'
document=document.replace('Golden 240行','Golden 238行')
target.write_text(document,encoding='utf-8')
work=R/'codex/work/lesson_03_frame_sync'
if author_source.resolve()!=(work/'complete_author.py').resolve(): shutil.copy2(author_source,work/'complete_author.py')
if Path(__file__).resolve()!=(work/'write_practical.py').resolve(): shutil.copy2(__file__,work/'write_practical.py')
(work/'source_index.json').write_text(json.dumps({p:{'language':META[p][0],'why':META[p][1]} for p in F},ensure_ascii=False,indent=2))
print('FRAME_DOCUMENT_WRITTEN',len(document.encode()),'source_files',len(F))
