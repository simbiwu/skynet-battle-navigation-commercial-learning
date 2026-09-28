# Skynet Battle Navigation 第二课实操：从世界位置 A→B 到 Server 权威自动战斗

第一课已经完成一条真实可运行的地图生产与查询链：

```text
Tuanjie Scene
-> NavMesh Authoring
-> Grid Sampling
-> BMAP V1
-> C++ BMapReader
-> immutable GridMap
-> MapRegistry
-> Lua C Binding
-> Skynet Query
```

第二课不重做这条链。现在第一次出现新的业务需求：

> 一个地面单位位于世界位置 A，需要绕过静态障碍和战斗中的其他单位，移动到世界位置 B；随后把这套导航能力放进一个 Server 权威、可确定性重放的自动战斗中。

这一个需求会自然长出本课全部核心对象：

```text
谁在走？
-> AgentProfile

A 到 B 的结果用什么表示？
-> Path

一场 Battle 自己的查询临时数据和动态占位放哪里？
-> NavigationContext

怎样从 A 找到 B？
-> Grid A*

其他单位怎样阻挡当前单位？
-> DynamicOccupancy

目标中心已经被占用，近战单位应该走到哪里？
-> Attack Position

怎样避免每 Tick 都重新 A*？
-> Path 生命周期 + Repath Policy

谁拥有战斗状态、谁允许 yield？
-> BattleMgr / BattleWorker / pure battle_core

Server 算完以后怎样验证客户端只负责表现？
-> Unity Replay

离线验收通过后，怎样让 Unity 从独立 Gateway 发起同一场自动战斗？
-> RunAutoBattle 请求 -> Battle Process -> 权威 Event -> Unity Replay
```

第二课先用 batch 入口验证 Battle 核心和 Replay；第 23.5 节再接通下面这条最终请求链：

```text
Unity RunAutoBattle(scenario_id=1001)
  -> FlyWow Gateway Process（只拥有连接、framing、Protobuf）
  -> gateway_proxy -> cluster.call("battle", "@battle_dispatch", ...)
  -> Map/Battle Process 的 battle_dispatch
  -> 从 Server 场景配置构造 immutable snapshot
  -> BattleMgr
  -> skynet.call(BattleWorker, "simulate", snapshot)   [这里会 yield]

BattleWorker
  -> acquire map/version
  -> create battle-local NavigationContext
  -> place dynamic units
  -> battle_core.simulate(...)                         [核心阶段 no-yield]
       -> target select
       -> find attack position
       -> context:find_path(...)
          -> WorldPosition -> GridPos
          -> Grid A*
          -> Path(WorldPosition)
       -> follow cached Path
       -> only repath on explicit trigger
       -> attack / hp / death
       -> ordered BattleEvent
  -> 返回有界的确定性 Event Log

Unity
  -> 解析本次响应中的权威 Event Log
  -> replay MOVE_PATH / MOVE_STOPPED / ATTACK / UNIT_DEAD
  -> never overwrite Server result
```

本课仍然只使用第一课的单层 2.5D Grid。不会引入：

```text
DetourNavigationBackend
Recast / Detour
Polygon NavMesh
SkillDefinition / SkillRuntime
Projectile
Flying Navigation
PlayerCommand
完整 Battle Snapshot/Event 在线同步
```

可选第四课第一次出现第二种地面导航实现时，才正式抽取 `INavigationBackend / GridNavigationBackend / DetourNavigationBackend`。第二课末尾只整理当前已经被 `BattleWorker` 使用过的稳定 Grid 导航调用面。

---

## 第一课 Gateway 与第二课战斗调度的边界

第二课不重新实现网络接入。第一课已经由 `server/third_party/skynet-flywow/service/flywow_gateway.lua` 负责 TCP/WebSocket、framing、Protobuf 解码、连接生命周期和错误合同；第二课先完成 BattleMgr、BattleWorker 和 `battle_core`，第 23.5 节才把它们接到独立 Battle Process 的分发入口。

进入战斗业务时，Gateway 传递的是已经解码的 `command`、`request`、`request_id` 和 `connection_id`。业务层根据 command 调用 BattleMgr；BattleMgr 可以 `skynet.call` BattleWorker 并 yield，BattleWorker 再调用 no-yield 的 `battle_core.simulate()`。网络 fd、frame buffer 和 Protobuf codec 不得进入 BattleWorker 或模拟核心。

如果需要多个监听端口，仍由 composition root 创建多个 `flywow_gateway` Service，并分别注入端口和业务 handler；第二课的战斗状态不能写入 Gateway 全局状态。

## 第一课到第二课的双进程运行模式

第二课先把“接入层”和“地图查询”放到不同的 Skynet Process 中；此时跨进程请求仍只有 `QueryCell`。第 23.5 节在自动战斗通过 batch 验证后，把 BattleMgr/Worker 接入同一 Battle Process。默认的单进程 `main` 保留为第一课 QueryCell 调试入口；第二课最终自动战斗请求使用双进程入口。Gateway Process 只拥有客户端连接，Map/Battle Process 拥有地图查询和战斗状态。

```text
Gateway Process
  gateway_main
    -> gateway_proxy
    -> FlyWow Gateway（TCP/WebSocket、frame、Protobuf、连接生命周期）
    -> skynet.cluster.call("battle", "@battle_dispatch", "gateway_dispatch", request_record)

Map/Battle Process
  battle_main
    -> navigation_query（当前已实现的地图查询入口）
    -> battle_dispatch（当前先指向 Query Service；第 23.5 节改为独立分发 Service）
```

这里的 `cluster.call` 只传递已经解码的 request record；fd、frame buffer、Protobuf codec 和 Lua State 都不会跨进程传递。`battle_dispatch` 是明确存在跨启动树发现需求时才使用的名字，Map/Battle Process 启动完成后注册它，Gateway Process 先等待 `ready` 再监听客户端端口。远程进程不可用时，Proxy 返回 `REMOTE_UNAVAILABLE`，由 FlyWow Gateway 按统一错误合同记录并关闭当前请求连接。

本节涉及的文件操作如下：

| 文件 | 操作 | 直接用途 |
| --- | --- | --- |
| `server/config/process_gateway.lua` | [新建文件] | Gateway 监听端口和远程 cluster 地址 |
| `server/config/process_battle.lua` | [新建文件] | Battle cluster 监听端口和入口名 |
| `server/config/skynet_gateway.lua` | [新建文件] | Gateway Process 的 Skynet bootstrap |
| `server/config/skynet_battle.lua` | [新建文件] | Map/Battle Process 的 Skynet bootstrap |
| `server/service/gateway_main.lua` | [新建文件] | 创建 Proxy 和 FlyWow Gateway |
| `server/service/gateway_proxy.lua` | [新建文件] | 把已解码请求转成 cluster RPC |
| `server/service/battle_main.lua` | [新建文件] | 创建 Query、开放 cluster 并注册入口 |
| `server/scripts/linux/run_lesson2_processes.sh` | [新建文件] | 统一启动、停止、状态和诊断两个进程 |

这些文件属于 Server 编辑源 `~/workspace/skynet-battle-navigation-commercial-learning/server/`。Windows 主工作区只同步 Git 提交，不复制 WSL 目录。

### 双进程启动与验证

在 WSL 中进入 Server 编辑源。脚本会先启动 Battle Process，等待 `LESSON2_BATTLE_PROCESS_READY`，再启动 Gateway Process；因此 Gateway 端口就绪时，远程 Query 入口已经完成地图加载和 cluster 注册。

```bash
cd ~/workspace/skynet-battle-navigation-commercial-learning/server
BUILD_TYPE=Debug ./scripts/linux/run_server.sh build
./scripts/linux/run_lesson2_processes.sh doctor
./scripts/linux/run_lesson2_processes.sh start
./scripts/linux/run_lesson2_processes.sh status
```

默认端口是 Gateway `19011`、Gateway Process cluster `2527`、Map/Battle Process cluster `2528`。日志位于 `server/logs/lesson2/gateway.log` 和 `server/logs/lesson2/battle.log`，应分别看到：

```text
LESSON2_BATTLE_PROCESS_READY
FLYWOW_GATEWAY_READY
LESSON2_GATEWAY_PROCESS_READY
```

停止时必须让 Gateway 先停止，再停止 Battle，避免仍有客户端请求尝试访问已经退出的远程节点：

```bash
./scripts/linux/run_lesson2_processes.sh stop
```

`run_lesson2_processes.sh doctor` 只检查固定 Skynet、FlyWow submodule、协议 descriptor、registry 和两个 bootstrap 文件是否存在；它不会启动服务，也不会生成新的协议版本。修改端口时必须同时更新两个 `process_*.lua` 文件以及本节中的验证说明，不能在脚本中写死第二套配置。

### 为未来 2D 地图保留的接入边界

本课仍只实现 2.5D Ground Grid，但业务调用从现在开始遵守三个约束：

1. 业务位置使用整数世界/逻辑坐标、`map_id` 和 `map_version`；长期 Path、BattleEvent 和持久状态不保存 `GridPos` 或 `grid_z`。
2. 地图 manifest 负责声明空间类型、坐标轴、原点、Cell 尺寸、资产格式版本和内容 hash。Unity BMAP 是当前输入，未来 H5/Tiled/JSON 通过离线导入器接入，Server 不读取客户端工程目录。
3. 俯视角 2D 可以复用 Grid A*、动态占位和确定性战斗；横版平台的重力、跳跃和多层平台属于另一种运动模型，不能把固定高度当作完整支持。

因此，第二课完成后将地图加载、寻路上下文、BattleWorker 和 Replay 抽取到 Skynet-FlyWow 时，网络模块仍不依赖地图，地图模块仍不依赖网络，Unity/H5 只替换表现层 Adapter。只有出现第二个真实地图消费者后，才从 2.5D 与 2D 的共同调用面提取稳定接口。

---

## 0. 开始前先确认第一课的真实边界

本文按累计施工顺序编写。读者从第一节开始时，以第一课完成后的仓库为基线；每一节只修改前面步骤已经创建的文件，后续代码默认前一节已经完成并通过验证。不要从后文章节复制代码覆盖尚未完成的前置实现。

本课依赖的第一课真实 C++ 类型位于：

```text
server/native/grid_map/include/bmap_format.h
server/native/grid_map/include/grid_map.h
server/native/grid_map/include/map_registry.h
server/native/grid_map/include/nav_result.h
server/native/lua_battle_nav/src/lua_battle_nav.cpp
```

第一课已经固定：

```cpp
struct WorldPosition {
    std::int32_t x_mm; // 世界 X，整数毫米；业务位置允许为负数。
    std::int32_t y_mm; // 世界高度 Y，整数毫米；来自地表高度事实。
    std::int32_t z_mm; // 世界 Z，整数毫米；业务位置允许为负数。
};

struct GridPos {
    std::int32_t x; // 当前地图内的 Grid X 下标；算法坐标，不直接作为业务位置。
    std::int32_t z; // 当前地图内的 Grid Z 下标；算法坐标，不直接作为业务位置。
};

struct NavCell {
    std::int32_t height_mm;       // Cell Center 地表世界 Y，毫米。
    std::uint16_t flags;          // 静态属性 bitset；bit 0 表示 Walkable。
    std::uint8_t area_type;       // 稳定地表 Area 编码；不是 Unity 运行时对象引用。
    std::uint8_t clearance_cells; // 到静态障碍/边界的保守距离，单位 Cell。
};
```

### 0.1 第二课的文件操作原则

本课不会为了“最终目录漂亮”先移动第一课文件。当前能力继续增加在已经工作的 `server/native/grid_map/`；目录调整不属于本课功能链。

所有操作都使用以下四种标签：

```text
[新建文件]
[完整替换]
[局部修改]
[只阅读]
```

---

# 第一部分：先让“谁在走”和“返回什么”变成明确合同

## 1. AgentProfile：同一张地图，不同单位不是同一种可走规则

第一课的 `NavCell.clearance_cells` 只是静态地图属性：

> 这个 Cell 离静态障碍/地图边界还有多少格保守空间。

现在第一次出现“谁要经过这个 Cell”。Small Soldier 和 Large Boss 可以共享同一张 BMAP，但它们对窄路、坡度和 Area 的可接受范围不同。

### 1.1 空间关系先看图

仍然使用 500mm Cell：

```text
世界 X ->

        500mm     500mm     500mm
     +---------+---------+---------+
 Z ^ |    #    |    #    |    #    |
   | +---------+---------+---------+
   | |    #    |  C(1)   |    #    |
   | +---------+---------+---------+
   | |    #    |    #    |    #    |
     +---------+---------+---------+

#      = 静态不可走
C(1)   = 可走 Cell，但 clearance_cells = 1
```

读图要点：`C(1)` 不是说这个 Cell 里已经放了一个单位，也不是说它的半径是 1；它表示这个 Cell 到最近静态障碍或地图边界只有 1 个 Grid 步长的保守空间。这个值在第一课导出 BMAP 时计算，运行时保持不变；动态单位不会写进 `clearance_cells`。

把它看成“地图先标出的通道宽度”：

```text
# # # # #
# 1 1 1 #
# 1 2 1 #
# 1 1 1 #
# # # # #
```

中心 Cell 的 `clearance_cells=2`，边缘可走 Cell 的值为 1。若 Cell 尺寸是 500mm，半径 200mm 的单位只需要 1 格，可以进入边缘 Cell；半径 600mm 的单位需要 2 格，只能进入中心这类空间。

如果单位半径只有 200mm，课程的保守规则允许 `required_clearance_cells=1`。如果半径需要 600mm，规则要求至少 2 格静态空间，这个 Cell 就会被拒绝。

这个换算是 2.5D Grid 的保守近似：

```text
required_clearance_cells
= max(1, ceil(radius_mm / cell_size_mm))
```

代码使用整数向上除法保存这个含义：

```text
radius=600，cell_size_mm=500
(600 + 500 - 1) / 500 = 2
```

如果直接做整数除法 `600 / 500`，结果会被截断成 1，单位就可能错误地进入空间不足的 Cell。这里保留整数写法，不调用浮点 `ceil`；`radius` 和 `cell_size_mm` 都是非负整数，公式得到的正是向上取整结果。

它不是连续几何的精确 Minkowski Sum。课程把这种保守性作为明确语义，而不是假装 Grid 能提供无限精度。

坡度也来自已有数据。相邻两格的中心高度分别为 `h0` 和 `h1`，水平距离为：

```text
直走：cell_size_mm
斜走：约 1.414 * cell_size_mm
```

为了避免浮点比较，使用千分比坡度：

```text
abs(height_delta_mm) * 1000
<= max_slope_permille * horizontal_distance_mm
```

例如：

```text
max_slope_permille = 500
约等于 50% 坡度
```

`max_step_mm` 另外限制单次高度跳变；即使平均坡度允许，也不能跨越一个不应该被当作坡面的高度断层。

这里要区分地图事实和单位规则：

```text
BMAP / Unity 采样：每个 Cell 实际的 height_mm、Walkable、Area、clearance_cells
Server AgentProfile：这个单位允许的 max_step_mm、max_slope_permille、体型和 Area 策略
```

`height_delta` 是相邻两个 BMAP Cell 的实际高度差；`max_step_mm` 和 `max_slope_permille` 是 Server 对当前单位的限制。同一张地图可以让不同单位使用不同的台阶和坡度规则。Unity Bake 也可能提前把过陡区域导出为不可走；Server 只能在这个基础上继续拒绝，不能把已经不是 Walkable 的 Cell 恢复为可走。

### 1.2 AgentProfile 学习导航

本文件解决的问题：把单位对静态地图的导航约束集中成一份只读 record，让 A* 不从 Lua 的零散字段猜规则。

本节必须掌握：

```text
radius_mm                  单位静态体型约束
max_step_mm                相邻 Cell 最大高度跳变
max_slope_permille         最大坡度千分比
area_allowed[256]          哪些静态 Area 可以进入
area_cost_permille[256]    进入不同 Area 的相对成本
```

必须精读：字段单位、`ValidateAgentProfile()`、`RequiredClearanceCells()`。

可以略读：`std::array` 初始化语法。

输入、输出和失败条件：

```text
输入：一份 AgentProfile + 当前 Grid cell_size_mm
输出：合法 profile 或明确 INVALID_AGENT
失败：id=0、radius<0、step/slope 非法、允许 Area 的 cost<1000
```

这里规定允许 Area 的 cost 最低为 `1000`。这样 A* 的 Octile Heuristic 仍然保持可采纳；泥地可以 2000、3000，但本课不实现“公路速度 0.8 倍成本”这种低于基础成本的情况。

运行验证：第 10 节统一 `navigation_test` 会同时验证 Small/Large、Slope 和 Area Cost。

理解自测：

```text
1. 为什么 clearance 是地图属性，而 radius 是单位属性？
2. 为什么 area cost 放 AgentProfile，而不是直接写死在 GridMap？
3. 如果允许 cost=500，现有 heuristic 为什么需要同步调整？
```

### 1.3 创建 AgentProfile

[新建文件]

```text
server/native/grid_map/include/agent_profile.h
```

```cpp
// 职责：定义地面单位在 Grid 导航中的静态通行规则。
// 边界：Server Runtime Navigation Input；由 Battle 配置创建，A* 只读使用。
// 输入/输出：单位体型、坡度和 Area 策略 -> Cell 可通行判定参数。
// 生命周期：随 NavigationContext/Battle 输入存活；查询期间不可修改。
// 不负责：不保存单位当前位置，不保存动态占位，不执行寻路。
#pragma once

#include "bmap_format.h"
#include "nav_result.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>

namespace battle_nav {

struct AgentProfile {
    std::uint32_t id = 0;          // Battle 内稳定 Profile ID；0 保留为非法值。
    std::int32_t radius_mm = 0;    // 地面圆形 footprint 半径，毫米；合法范围 [0, INT32_MAX]。
    std::int32_t max_step_mm = 0;  // 相邻 Cell 允许的最大高度跳变，毫米；必须 >=0。
    std::uint32_t max_slope_permille = 0; // 高差/水平距离 *1000 的上限。

    // area_type 是 uint8，因此固定 256 项避免 map 查找和查询期动态分配。
    std::array<std::uint8_t, 256> area_allowed{};       // 1=允许进入，0=禁止。
    std::array<std::uint16_t, 256> area_cost_permille{}; // 1000=基础成本，>=1000。
};

// 构造一份最常用的“全部 Area 允许、基础成本 1000”默认表。
// 仅分配/返回一个小值对象；不访问地图、不加锁、不 yield。
inline AgentProfile MakeDefaultAgentProfile(std::uint32_t id) {
    AgentProfile profile;
    profile.id = id;
    profile.area_allowed.fill(1);
    profile.area_cost_permille.fill(1000);
    return profile;
}

// 验证 Profile 是否满足本课 A* 的整数成本与 Heuristic 前提。
// 成功返回 true；失败返回 kInvalidAgent + detail。
inline NavResult<bool> ValidateAgentProfile(const AgentProfile& profile) {
    if (profile.id == 0 || profile.radius_mm < 0 || profile.max_step_mm < 0) {
        return NavResult<bool>::Failure(
            NavError::kInvalidAgent,
            "agent id/radius/max_step is invalid");
    }

    for (std::size_t area = 0; area < profile.area_allowed.size(); ++area) {
        if (profile.area_allowed[area] == 0) {
            continue;
        }
        if (profile.area_cost_permille[area] < 1000) {
            return NavResult<bool>::Failure(
                NavError::kInvalidAgent,
                "allowed area cost must be >= 1000 permille");
        }
    }
    return NavResult<bool>::Success(true);
}

// 把毫米制半径转换为第一课 clearance_cells 的保守需求。
// clearance_cells 是地图到静态障碍/边界的距离；本函数计算单位至少需要的格数。
// cell_size_mm 必须 >0；返回值至少为 1，并在 uint8 范围饱和。
inline std::uint8_t RequiredClearanceCells(
    const AgentProfile& profile,
    std::uint32_t cell_size_mm) {
    if (cell_size_mm == 0) {
        return std::numeric_limits<std::uint8_t>::max();
    }
    const std::uint64_t radius = static_cast<std::uint64_t>(profile.radius_mm);

    // 这是非负整数的向上除法 ceil(radius / cell_size_mm)。
    // 例如 radius=600、cell_size_mm=500 时，直接相除会得到 1，
    // 而 (600 + 500 - 1) / 500 得到 2，才能拒绝只有一格空间的 Cell。
    const std::uint64_t cells = (radius + cell_size_mm - 1) / cell_size_mm;

    // 半径为 0 的单位仍至少按一个 Cell 需求处理，避免把 clearance=0 的障碍格当成可站立格。
    const std::uint64_t at_least_one = cells == 0 ? 1 : cells;

    // BMAP 字段是 uint8_t；超出可表达范围时饱和为 255，而不是发生窄化回绕。
    return static_cast<std::uint8_t>(
        at_least_one > 255 ? 255 : at_least_one);
}

} // namespace battle_nav
```

谁马上会使用它：第 6 节 A* 的 `CanOccupyStaticCell()`。完成后暂时看不到路径变化，这是正常的；当前只是把“谁能走”从隐含规则变成明确输入。

---

### 1.4 先手算一次 A*：它为什么能找到最低成本路径

本节解决的问题：在开始写 `Path`、`NavigationContext` 和 A* 主循环之前，先建立一次完整的 A* 搜索模型。这里不新建文件；完成后，读者应该能够手算一次搜索，并说明最终 Path 是怎样产生的。

本节必须掌握：

```text
可走 Cell       = 图中的节点
合法移动        = 节点之间的边
OPEN            = 已发现、等待扩展的候选节点
CLOSED          = 已经扩展完成的节点
g               = 起点到当前节点的真实累计成本
h               = 当前节点到终点的估计成本
f = g + h       = 本轮优先级
parent          = 当前节点在候选路径中的前一个节点
```

先看一个只使用非负坐标的小地图。`S` 是起点，`G` 是终点，`#` 是静态障碍；每个可走 Cell 的坐标由底部的 `X` 和左侧的 `Z` 读出。

```text
Z ^
4 | .  .  .  .  G
3 | .  #  #  .  .
2 | .  .  .  .  .
1 | .  .  #  .  .
0 | S  .  .  .  .
  +----------------> X
    0  1  2  3  4
```

读图要点：`S=(0,0)`，`G=(4,4)`；`#` 只表示不能作为路径节点的 Cell。路径是否能连接两个可走 Cell，还要看这两个 Cell 之间的移动边是否合法，例如对角移动的两个正交侧格也必须允许通过。

A* 的一次查询可以按下面的顺序理解：

```text
1. 把 S 放入 OPEN，设置 g(S)=0，记录 parent(S)=无。
2. 从 OPEN 取出 f 最小的节点；取出的节点进入 CLOSED。
3. 检查它的邻居，拒绝越界、障碍、AgentProfile 不允许或边不合法的邻居。
4. 对每个合法邻居计算 tentative_g。
5. 如果邻居第一次发现，或 tentative_g 更小，就更新 g、parent，并放入或调整 OPEN。
6. 取出 G 时沿 parent 反向回溯，再反转顺序，得到 S -> G 的路径。
7. OPEN 为空仍未取出 G 时，返回 NO_PATH。
```

例如从 `S=(0,0)` 第一次扩展后，假设相邻格均满足 AgentProfile：

```text
节点       g       h（到 G 的 Octile 估计）       f       parent
(1,0)     1000             5242                  6242     S
(0,1)     1000             5242                  6242     S
(1,1)     1414             4242                  5656     S
```

下一轮优先取 `f` 最小的 `(1,1)`。这里的 `OPEN` 是算法概念，不要求必须是链表；本课用 Binary Min Heap 实现它。`CLOSED` 也不需要另建一个集合，当前查询的 `NodeState::kClosed` 就能表达这个状态。

#### 为什么 `min` 是斜走次数，剩余差值是直走次数

从 `a=(0,0)` 到 `b=(4,3)`，两个轴分别相差：

```text
dx = |4 - 0| = 4
dz = |3 - 0| = 3
```

一次对角移动会同时让 X 和 Z 各前进 1 格。因此最多只能斜走较小的差值：

```text
diagonal = min(dx, dz) = min(4, 3) = 3
```

斜走 3 次后，Z 方向已经完成，X 方向还剩 1 格：

```text
straight = max(dx, dz) - diagonal
         = max(4, 3) - 3
         = 1
```

所以这段无障碍的理论路线可以理解为：3 次斜走加 1 次直走，估计成本为 `3 * 1414 + 1 * 1000 = 5242`。这里计算的是没有障碍时的最低估计；实际 A* 仍然要逐条检查障碍、AgentProfile 和对角侧格。

#### 为什么 A* 返回最低导航成本路径

本课假定所有移动成本都非负，并使用：

```text
直走基础成本 = 1000
斜走基础成本 = 1414
允许 Area Cost >= 1000
```

`h` 使用 Octile Distance，并且不会高估当前节点到终点的最低剩余成本；在本课的基础移动成本和 `Area Cost >= 1000` 约束下，它还满足一致性。因此，当 A* 从 OPEN 中取出终点时，已经没有另一条更低成本的候选路径能够绕过它；沿 `parent` 回溯得到的路径就是最低总导航成本路径。也因为启发式一致，节点进入 CLOSED 后本课不需要重新打开。

这里的“最短”指最低导航成本，不一定是几何距离最短。泥地的 Area Cost 更高时，算法可能选择几何上更长但成本更低的路线。

```text
A*       = g + h
Dijkstra = g + 0
```

当 `h=0` 时，A* 退化为 Dijkstra，仍然可以得到最低成本路径；有效的启发式只是帮助搜索更集中地朝终点推进。

#### 复杂度先知道结论，证明留在实现细节中

设本次可能访问的节点数为 `V`，合法邻接边数为 `E`。Binary Heap 版本的最坏情况为：

```text
时间复杂度：O((V + E) log V)
空间复杂度：O(V)
```

本课每个 Grid Cell 最多检查 8 个邻居，因此 `E = O(V)`，可以进一步记为：

```text
时间复杂度：O(V log V)
空间复杂度：O(V)
```

实际访问节点数通常小于整张地图的 Cell 数，受启发式、障碍布局、起终点距离和 AgentProfile 约束影响。本课的 `NavigationContext` 为每个 Cell 预留 scratch，但查询期间不为每个 Node 执行 `new/delete`；最终 `Path` 保存结果所需的 vector 分配仍然允许。

#### 对角移动为什么还要检查两个侧格

对角邻居不是“只要目标 Cell 可走就可以添加的一条边”。以 A 到 B 为例：

```text
Z ^
  |
  |  [ B ] [ # ]
  |  [ # ] [ A ]  -> 想从 A 斜走到 B
  +--------------> X
```

如果 A 的坐标是 `(x,z)`，对角偏移是 `(dx,dz)`，则必须同时验证：

```text
目标格：   (x + dx, z + dz)
水平侧格： (x + dx, z)
垂直侧格： (x, z + dz)
```

图中 B 自身可以是可走格，但这条 A -> B 的直接对角边是非法的，因为两个侧格都是障碍。若地图外还有绕行空间，B 仍可能通过其他路径到达；若图中只有这四个格子，则 B 对 A 完全不可达。第 7 节加入动态占位后，三个格子还要同时检查动态阻挡。

运行验证：先用一个小地图手算 OPEN/CLOSED 和 `parent`，再由第 10 节的直线、绕障碍、无路、对角阻挡测试验证同一套规则。

理解自测：

```text
1. 为什么 CLOSED 不是“障碍格列表”？
2. 为什么 A* 的 Path 要在 parent 回溯之后才构造？
3. 如果把允许 Area Cost 改成 500，Octile heuristic 的前提发生了什么变化？
4. 图中 B 可走时，为什么 A -> B 仍然可能是非法边？
```

---

## 2. Path：A* 的结果必须回到世界坐标

A* 内部会使用 `GridPos` 和 node index，但 Battle、Lua、Replay 不应该长期依赖 Grid 的 origin/cell size。

正式结果必须是：

```text
Path
└─ WorldPosition[0..N-1]  单位：整数毫米
```

路径点通常位于 Cell Center，所以 Y 来自第一课 `NavCell.height_mm`。

### 2.1 Path 学习导航

本文件解决的问题：把一次成功寻路的结果保存成不可变世界坐标路径，供 Lua/Battle/Replay 读取。

本节必须掌握：

```text
Path point 属于世界坐标边界
GridPos 只在构建 Path 之前存在
Path 构建后 immutable
最终 Path 分配允许发生；A* node 不能 per-node new/delete
```

必须精读：`WorldPoint()`、`length_mm()`、构造时 ownership。

可以略读：`std::vector` getter。

输入、输出和失败：

```text
输入：A* 沿 parent 回溯并转换得到的、已经验证的 WorldPosition 点序列
输出：immutable Path
失败：空路径由 FindPath 返回 NO_PATH/其他显式错误，不用空 Path 偷偷表达失败
```

运行验证：直线路径、绕障碍路径和 smoothing 测试会读取 Path 世界点。

理解自测：为什么 Lua 不应该拿到 `{grid_x, grid_z}` 数组作为正式路径？

### 2.2 创建 Path

[新建文件]

```text
server/native/grid_map/include/navigation_path.h
```

```cpp
// 职责：保存一次成功地面导航产生的不可变世界坐标路径。
// 边界：Server Runtime Navigation Result；Lua/Battle/Replay 只看 WorldPosition。
// 输入/输出：有序 WorldPosition 点 -> 只读 Path 和总长度。
// 生命周期：由调用者或 Lua userdata 持有；构建完成后不再修改。
// 不负责：不保存 A* node、GridPos、dynamic occupancy 或未来 Off-Mesh 语义。
#pragma once

#include "bmap_format.h"

#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <utility>
#include <vector>

namespace battle_nav {

class Path final {
public:
    Path() = default;

    // 接管已经按行进顺序排列的世界坐标点。
    // points 可以只含一个点（start==end）；本构造不执行地图合法性检查。
    explicit Path(std::vector<WorldPosition> points, std::uint64_t length_mm)
        : points_(std::move(points)), length_mm_(length_mm) {}

    // 返回路径点数量；不分配、不加锁、不 yield。
    std::size_t count() const noexcept { return points_.size(); }

    // 读取 index 对应的世界坐标点；越界抛 out_of_range，仅供已验证调用者使用。
    const WorldPosition& WorldPoint(std::size_t index) const {
        if (index >= points_.size()) {
            throw std::out_of_range("path point index out of range");
        }
        return points_[index];
    }

    // 返回整条路径在 XZ 平面的整数毫米长度；不包含动画或墙钟时间。
    std::uint64_t length_mm() const noexcept { return length_mm_; }

    // Native 内部只读访问连续点数组；返回引用不拥有数据。
    const std::vector<WorldPosition>& points() const noexcept { return points_; }

private:
    std::vector<WorldPosition> points_; // 按移动顺序保存；Path 独占内存。
    std::uint64_t length_mm_ = 0;       // XZ 折线总长度，单位毫米。
};

} // namespace battle_nav
```

这里出现的 `std::vector` 分配属于“最终结果分配”。本课禁止的是：A* 每访问一个 Node 都 `new Node`，或者 open list 每次 push 都构造一堆堆上对象。最终返回一条 Path，本身需要保存结果，这是合理分配。

---

# 第二部分：先建立每场 Battle 私有的查询上下文，再写 A*

## 3. NavigationContext：把 A* scratch 的 owner 先确定下来

如果直接在 `GridPathfinder::FindPath()` 里写：

```cpp
static std::vector<Node> nodes;
static std::vector<int> open_heap;
```

单线程测试很可能全部通过；多个 Skynet Service 在不同 OS Thread 同时调用时，会互相覆盖：

```text
Thread A: node[123].parent = 50
Thread B: node[123].parent = 890
Thread A: 回溯 parent -> 路径突然跳到 B 的查询
```

因此先建立 owner，再写算法。

现在才需要把 ownership 画完整：

```text
进程级，只读，可多线程共享
┌──────────────────────────────────────────────┐
│ MapRegistry                                  │
│   └─ shared_ptr<const GridMap>               │
│        ├─ BMapMetadata                       │
│        └─ const vector<NavCell>              │
└──────────────────────────────────────────────┘
                       ▲
                       │ shared immutable asset
                       │
每场 Battle 私有       │
┌──────────────────────┴───────────────────────┐
│ NavigationContext                            │
│   ├─ shared_ptr<const GridMap>               │
│   ├─ A* Node Scratch                         │
│   ├─ Binary Heap Scratch                     │
│   ├─ query generation                        │
│   └─ 第 7 节加入的 DynamicOccupancy          │
└──────────────────────────────────────────────┘
```

读图要点：

1. `GridMap` 保存 map/version 对应的静态事实，加载后 immutable，可以跨 Battle 共享。
2. `NavigationContext` 保存一次 Battle 的查询临时状态，不能跨 Battle 共享。
3. `g_cost / parent / open/closed / heap_index / generation` 都属于一次查询，不能写进 `GridMap`。
4. 第 7 节出现的动态单位也只属于当前 Battle，不能写进 `NavCell`。
5. 图中的 `GridPos` 仍只是 Native 算法坐标；正式业务位置继续使用 `WorldPosition(mm)`。

### 3.1 Skynet Service、Lua State 和 OS Thread 的关系

这张图的线程安全结论来自三个不同层次：

```text
Skynet Service
  -> 通常拥有自己的 Lua State
  -> 消息处理协程可以在 yield 点交错

Skynet Worker Thread
  -> 调度不同 Service
  -> 一个 Service 在生命周期中可能被不同 Worker Thread 调度

C/C++ Native Module
  -> 进程级代码和静态数据
  -> 不同 Service 可以在不同 OS Thread 同时进入同一份 Native 代码
```

因此 immutable `GridMap` 可以共享；process-global mutable A* scratch、current Path buffer 和 DynamicOccupancy 都不可以共享。即使一个 Lua Service 内没有两个 Lua 指令流同时执行，另一个 Service 仍可能从另一个 OS Thread 进入同一份 Native 模块。

### 3.2 generation stamp 解决什么问题

假设地图 512×512：

```text
cell_count = 262144
```

每次 FindPath 前把 26 万个 Node 全部 `memset` 清零，会把“搜索访问了 2000 个节点”的算法变成“每次至少触碰 26 万个节点”。

本课给每个 Node 保存：

```text
generation
```

每次查询只做：

```text
context.query_generation++
```

访问一个 Node 时：

```text
if node.generation != current_generation:
    把这个 Node 当成本次第一次访问
    初始化 g/parent/heap/state
    node.generation = current_generation
```

这样只初始化真正访问到的节点。

Generation 从 `UINT32_MAX` 回卷时，才一次性把 generation 数组清零。这个极低频分支必须存在，不能让旧查询的 generation 与新查询碰撞。

### 3.3 Binary Heap 中的三个 index 不要混

A* 里会同时出现：

```text
node_index   = z * width + x        Grid Cell 对应的稳定 Node 编号
heap_slot    = 当前 Node 在 binary heap 数组中的位置
parent_index = 最优路径上一个 Node 的 node_index
```

它们都可能是 `int32_t`，所以注释必须持续写明是哪一种 index。

### 3.4 NavigationContext 学习导航

本文件解决的问题：让每场 Battle/每个独立 Query owner 自己持有 A* scratch，避免全局可变查询状态。

本节必须掌握：

```text
NodeScratch 生命周期 = NavigationContext 生命周期
open_heap 预分配一次
query_generation 每次查询递增
GridMap shared_ptr<const> 只读共享
```

必须精读：`NodeScratch` 字段、`BeginQuery()`、`TouchNode()`、`heap` ownership。

可以略读：getter。

输入、输出和失败：

```text
输入：shared_ptr<const GridMap>
输出：一个可重复执行 FindPath 的 battle-local context
失败：null map、cell_count 超过 int32 node_index 能力
```

运行验证：第 11 节并发测试会让多个 Context 同时查询同一 GridMap。

理解自测：如果把 `query_generation_` 设成全局 atomic，为什么仍然没有解决 `g_cost/parent/heap` 的共享污染？

### 3.5 创建 NavigationContext 的第一版

这一版只放静态 A* scratch。第 7 节出现动态单位以后，再对同一文件做局部修改加入 `DynamicOccupancy`。

[新建文件]

```text
server/native/grid_map/include/navigation_context.h
```

```cpp
// 职责：拥有一场 Battle/一次独立导航会话的 A* 可变查询状态。
// 边界：Server Runtime Battle-local Navigation；只读共享 GridMap，可写状态绝不跨 Context。
// 输入/输出：immutable GridMap -> 可重复使用的 Node/Heap scratch。
// 生命周期：通常与一场 Battle 相同；销毁时释放本 Context 的全部 scratch。
// 不负责：不拥有 MapRegistry，不把 GridPos 暴露给 Lua 业务，不执行 Skynet yield。
#pragma once

#include "grid_map.h"
#include "nav_result.h"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

namespace battle_nav {

class NavigationContext final {
public:
    enum class NodeState : std::uint8_t {
        kUnseen = 0,
        kOpen = 1,
        kClosed = 2,
    };

    struct NodeScratch {
        std::uint32_t generation = 0; // 只有等于 query_generation_ 时其余字段才属于当前查询。
        std::uint64_t g_cost = 0;     // 起点到当前 node 的累计整数成本；大图不会发生 uint32 回绕。
        std::int32_t parent_index = -1; // 最优前驱 node_index；-1 表示起点/未设置。
        std::int32_t heap_index = -1;   // 当前 node 在 binary heap 中的 slot；不在 heap 时为 -1。
        NodeState state = NodeState::kUnseen; // 本次 query 的 unseen/open/closed 状态。
    };

    // 为 map 分配一次 dense scratch；构造阶段会发生 O(cell_count) 内存分配。
    // map 必须非空，cell_count 必须可由 int32 node_index 表示。
    explicit NavigationContext(std::shared_ptr<const GridMap> map);

    // 开始一次新查询：递增 generation、清空 heap_size，不扫描清零全部 Node。
    // Generation 回卷时才 O(cell_count) 清零 generation 字段。
    void BeginQuery();

    // 取得 node_index 对应的当前查询 NodeScratch；首次触碰时按当前 generation 初始化。
    // node_index 必须位于 [0, cell_count)；返回引用归本 Context 所有。
    NodeScratch& TouchNode(std::int32_t node_index);

    // 只读访问共享静态地图；返回 shared_ptr 引用，不转移所有权。
    const std::shared_ptr<const GridMap>& map() const noexcept { return map_; }

    // Binary Heap backing array；元素是 node_index。容量在构造时一次性分配为 cell_count。
    std::vector<std::int32_t>& heap_storage() noexcept { return heap_; }
    const std::vector<std::int32_t>& heap_storage() const noexcept { return heap_; }

    // 当前 heap 的有效 slot 数；[0, heap_size_) 才是本次查询数据。
    std::size_t heap_size() const noexcept { return heap_size_; }
    void set_heap_size(std::size_t value) noexcept { heap_size_ = value; }

    // 当前查询 generation；只用于 GridPathfinder，不进入业务数据。
    std::uint32_t query_generation() const noexcept { return query_generation_; }

    // 调试/Benchmark：本次 A* 真正 Touch 的 Node 数。
    std::uint32_t visited_nodes() const noexcept { return visited_nodes_; }

private:
    std::shared_ptr<const GridMap> map_; // 与 MapRegistry 共享 immutable GridMap 所有权。
    std::vector<NodeScratch> nodes_;     // 每 Cell 一个 scratch record，本 Context 独占。
    std::vector<std::int32_t> heap_;     // Binary Heap 的 node_index 存储，本 Context 独占。
    std::size_t heap_size_ = 0;          // 本次 query 的有效 heap slot 数。
    std::uint32_t query_generation_ = 0; // 0 保留为“从未属于任何查询”。
    std::uint32_t visited_nodes_ = 0;    // 本次查询 Touch 的唯一 Node 计数。
};

} // namespace battle_nav
```

[新建文件]

```text
server/native/grid_map/src/navigation_context.cpp
```

```cpp
// 职责：实现 NavigationContext 的 scratch 分配、generation 生命周期和按需 Node 初始化。
// 边界：Server Runtime Battle-local Mutable State；不访问 Skynet/Lua，不执行 I/O。
// 输入/输出：immutable GridMap -> 可复用 A* scratch。
// 内存：构造时按 cell_count 分配 nodes + heap；每次查询不做 per-node allocation。
// 不负责：不计算邻居、不判断 Agent、不生成 Path。
#include "navigation_context.h"

#include <algorithm>
#include <limits>
#include <stdexcept>
#include <utility>

namespace battle_nav {

NavigationContext::NavigationContext(std::shared_ptr<const GridMap> map)
    : map_(std::move(map)) {
    if (!map_) {
        throw std::invalid_argument("NavigationContext requires map");
    }
    if (map_->cell_count() >
        static_cast<std::size_t>(std::numeric_limits<std::int32_t>::max())) {
        throw std::invalid_argument("map has too many cells for int32 node index");
    }

    // Dense scratch 在 Context 构造阶段一次分配；查询热路径只重用这些内存。
    nodes_.resize(map_->cell_count());
    heap_.resize(map_->cell_count());
}

void NavigationContext::BeginQuery() {
    ++query_generation_;
    if (query_generation_ == 0) {
        // uint32 generation 回卷后必须清掉旧标记，避免几十亿次前的 Node 被误认为当前查询。
        for (NodeScratch& node : nodes_) {
            node.generation = 0;
        }
        query_generation_ = 1;
    }
    heap_size_ = 0;
    visited_nodes_ = 0;
}

NavigationContext::NodeScratch& NavigationContext::TouchNode(
    std::int32_t node_index) {
    if (node_index < 0 ||
        static_cast<std::size_t>(node_index) >= nodes_.size()) {
        throw std::out_of_range("A* node_index outside scratch array");
    }

    NodeScratch& node = nodes_[static_cast<std::size_t>(node_index)];
    if (node.generation != query_generation_) {
        // 只初始化本次查询真正访问的 Node；不对整张地图 memset。
        node.generation = query_generation_;
        node.g_cost = std::numeric_limits<std::uint64_t>::max();
        node.parent_index = -1;
        node.heap_index = -1;
        node.state = NodeState::kUnseen;
        ++visited_nodes_;
    }
    return node;
}

} // namespace battle_nav
```

### 3.6 这里会占多少内存

`NodeScratch` 含 `uint64_t g_cost`，实际大小受 ABI 对齐影响，不能在文档里写死。用 `sizeof(NavigationContext::NodeScratch)` 记录当前编译产物；Heap 还需要每 Cell 一个 `int32_t`，Occupancy 需要一个 `uint32_t`。

粗略估算：

```text
80x60      = 4,800 cells      很小
256x256    = 65,536 cells     约 MB 级 scratch
512x512    = 262,144 cells    数 MB scratch/context
```

因此“每场 Battle 一个 Context”并不等于“可以无限创建大地图 Context”。商业项目需要结合：

```text
同时活跃 Battle 数
地图 cell_count
每场寻路频率
Worker 数
内存预算
```

再决定是否做 scratch pool、分区地图或更稀疏的数据结构。本课先把 correctness 和 ownership 做对，再用第 12 节 Benchmark 给下一步优化提供数据。

---

# 第三部分：第一次真正实现 Grid A*

## 4. 先给现有 GridMap 增加 A* 所需的只读热路径访问

第一课 `GridMap` 已经可以 `WorldToGrid()`、`GridToWorldCenter()` 和 `QueryWorld()`。A* 每访问一个邻居都调用返回 `NavResult<NavCell>` 的高层接口，会反复构造错误对象和字符串；它需要一个更低层但仍然只读的 Cell 访问入口。

这里不改变 GridMap ownership，也不把任何 A* 状态塞进去。

### 4.1 GridMap 局部修改学习导航

本次修改解决的问题：让 Native A* 在已知 GridPos 时零分配读取 Cell。

必须精读：`TryCell()` 的边界和返回指针生命周期。

可以略读：现有第一课函数。

输入、输出和失败：

```text
输入：GridPos
输出：const NavCell*；越界返回 nullptr
失败不构造字符串，因为这是 A* 内部热路径
```

运行验证：所有第一课 `grid_map_test` 必须继续通过。

理解自测：为什么这个指针可以跨当前函数短期读取，却不能在 GridMap 销毁后保存？

### 4.2 修改 `grid_map.h`

[局部修改]

```text
server/native/grid_map/include/grid_map.h
```

找到：

```cpp
NavResult<NavCell> QueryWorld(const WorldPosition& world) const;
```

在它后面增加：

```cpp
    // Native 导航热路径按 GridPos 读取 immutable Cell。
    // grid 越界返回 nullptr；成功指针指向 GridMap 内部 const vector，调用方不释放。
    // 本函数不分配、不加锁、不修改共享状态。
    const NavCell* TryCell(const GridPos& grid) const noexcept;
```

### 4.3 修改 `grid_map.cpp`

[局部修改]

在 `QueryWorld()` 后、`Contains()` 前增加：

```cpp
const NavCell* GridMap::TryCell(const GridPos& grid) const noexcept {
    if (!Contains(grid)) {
        return nullptr;
    }
    return &cells_[IndexOf(grid)];
}
```

这就是本次对第一课 `GridMap` 的全部修改。

---

## 5. 扩展显式错误，再写 A*

第一课错误主要服务资产加载和单 Cell 查询。现在第一次出现路径失败，需要区分：

```text
OUT_OF_BOUNDS
START_NOT_NAVIGABLE
END_NOT_NAVIGABLE
NO_PATH
INVALID_AGENT
CONTEXT_CLOSED
PATH_TOO_LONG
DYNAMIC_OCCUPIED
MOVE_BLOCKED
```

`NO_PATH` 不是异常，也不能用空 Path 表示；它是完全合法的业务结果。

### 5.1 修改 `nav_result.h`

[局部修改]

在第一课 `NavError` 的 `kInvalidArgument` 后增加：

```cpp
    kInvalidAgent,          // AgentProfile 本身不合法或 profile_id 不存在。
    kStartNotNavigable,    // 起点在地图内，但不满足静态/动态通行规则。
    kEndNotNavigable,      // 终点在地图内，但不满足静态/动态通行规则。
    kNoPath,               // 起终点均合法，但当前规则下不存在连通路径。
    kContextClosed,        // Lua/业务仍在调用已经关闭的 NavigationContext。
    kPathTooLong,          // 回溯点数或累计长度超过项目保护上限。
    kDynamicOccupied,      // 动态占位提交与其他 Unit 冲突。
    kMoveBlocked,          // 缓存路径的本次跨格已被静态或动态规则拒绝。
    kInternalError,        // Native 未预期异常在 C ABI 边界被收敛，不能继续传播。
```

### 5.2 修改 `nav_result.cpp`

[局部修改]

在 `NavErrorName()` 的 switch 中增加：

```cpp
    case NavError::kInvalidAgent: return "INVALID_AGENT";
    case NavError::kStartNotNavigable: return "START_NOT_NAVIGABLE";
    case NavError::kEndNotNavigable: return "END_NOT_NAVIGABLE";
    case NavError::kNoPath: return "NO_PATH";
    case NavError::kContextClosed: return "CONTEXT_CLOSED";
    case NavError::kPathTooLong: return "PATH_TOO_LONG";
    case NavError::kDynamicOccupied: return "DYNAMIC_OCCUPIED";
    case NavError::kMoveBlocked: return "MOVE_BLOCKED";
    case NavError::kInternalError: return "INTERNAL_ERROR";
```

新增错误以后，后面的 Binding 只按稳定名字做映射；Battle 不能解析 `detail` 文案做业务分支。

---

## 6. GridPathfinder：Binary Heap + generation stamp + 8-way A*

现在输入和 owner 都已经存在，才开始 A*。

### 6.1 本课 A* 的固定规则

```text
邻居：8-way
直走基础成本：1000
斜走基础成本：1414
Heuristic：Octile Distance
Open List：Binary Min Heap；逻辑上保存待扩展候选节点
Closed List：NodeState::kClosed；逻辑上保存已扩展节点
Node Scratch：NavigationContext dense array
Node 初始化：generation stamp
per-node new/delete：禁止
corner cutting：禁止
clearance：检查目标 Cell 和对角侧 Cell
step/slope：检查 current -> neighbor
area allowed/cost：检查目标 Cell
错误：显式 NavError
```

### 6.2 为什么不用 `std::priority_queue`

普通 `priority_queue` 很适合基础 A*，但本课还需要：

```text
Decrease-Key
heap_index
不为同一个 Node 反复 push 多个 stale entry
可观测 visited/open 状态
```

所以自己维护一个 `node_index[]` Binary Heap。每个 NodeScratch 保存自己的 `heap_index`，松弛后直接 `SiftUp()`。

### 6.3 corner cutting 图示

```text
Z ^
  |
  |  [ B ] [ # ]
  |  [ # ] [ A ]  -> 想从 A 斜走到 B
  +--------------> X

A -> B 是对角移动。
两个正交侧格都是 #。
```

这里要区分“目标 Cell 可走”和“当前到目标的移动边合法”。如果只检查 B 自己可走，单位会从两个障碍的角之间“切过去”。因此对角移动 `(dx,dz)` 时，必须同时验证：

```text
(x + dx, z)
(x, z + dz)
```

而且使用与真正目标格一致的 `AgentProfile` 静态约束。第 7 节加入动态占位后，这两个侧格也会同时检查动态阻挡。

因此，图中的 B 可以是可走 Cell，但 A -> B 的直接对角边仍然非法。若地图外存在绕行空间，A 仍可能绕路到达 B；若图中只有这四个格子，则 B 对 A 完全不可达。

### 6.4 slope / step / area 的判定顺序

对一个邻居，先做便宜拒绝，再做成本计算：

```text
1. Grid 边界
2. Walkable
3. clearance
4. area allowed
5. max_step
6. max_slope
7. diagonal side cells（若斜走）
8. 计算 area-adjusted move cost
9. A* relax
```

这里不做动态占位。先让静态规则独立通过 Golden Test；第 7 节再叠加 Battle-local overlay。

### 6.5 GridPathfinder 学习导航

本文件解决的问题：在第一课 immutable GridMap 上执行一条工程化 A* 查询，并返回世界坐标 Path。

本节必须掌握：

```text
node_index / parent_index / heap_index
Binary Heap push/pop/decrease-key
generation stamp
open / closed 状态
Octile heuristic
corner cutting
clearance / step / slope / area cost
Path 回溯后 Grid -> World
```

必须精读：`CanOccupyStaticCell()`、`CanTraverseStatic()`、Heap 操作和 `FindPathStatic()` 主循环。

可以略读：方向数组常量、普通 overflow guard。

输入、输出和失败：

```text
输入：NavigationContext、AgentProfile、start_world、end_world
输出：Path(WorldPosition)
失败：OUT_OF_BOUNDS / START_NOT_NAVIGABLE / END_NOT_NAVIGABLE / NO_PATH / INVALID_AGENT
```

内存与锁：

```text
查询开始：0 次全图清零
访问 Node：0 次 heap allocation
Open List：复用 Context heap_storage
最终 Path：会按结果点数分配 vector
锁：0
共享可变状态：0
yield：0
```

运行验证：第 10 节统一测试入口。

理解自测：

```text
1. 为什么 closed Node 仍要带 generation？
2. 为什么 heap 中保存 node_index，而不是 Node*？
3. 为什么 Area Cost 乘在进入 neighbor 的 move cost 上？
4. 为什么本课要求 cost >= 1000？
```

### 6.6 创建 `grid_pathfinder.h`

[新建文件]

```text
server/native/grid_map/include/grid_pathfinder.h
```

```cpp
// 职责：声明当前 GridMap 的 A* 路径查询入口。
// 边界：Server Runtime Native Navigation；内部使用 GridPos，外部只接受/返回 WorldPosition。
// 输入/输出：NavigationContext + AgentProfile + A/B 世界坐标 -> Path 或显式 NavError。
// 生命周期：不保存全局状态；所有 scratch 由调用者传入的 NavigationContext 拥有。
// 不负责：本阶段不处理动态占位、不调用 Skynet、不做 Unity 表现。
#pragma once

#include "agent_profile.h"
#include "navigation_context.h"
#include "navigation_path.h"

namespace battle_nav {

class GridPathfinder final {
public:
    // 在静态 GridMap 上寻找 A->B 路径。
    // start/end 使用整数毫米世界坐标；Y 只用于输入完整性，归格使用 XZ。
    // 成功 Path 的点全部为世界坐标；函数不加锁、不 yield。
    static NavResult<Path> FindPathStatic(
        NavigationContext& context,
        const AgentProfile& profile,
        const WorldPosition& start,
        const WorldPosition& end);
};

} // namespace battle_nav
```

### 6.7 创建 `grid_pathfinder.cpp`

[新建文件]

```text
server/native/grid_map/src/grid_pathfinder.cpp
```

```cpp
// 职责：实现 Grid 8-way A*、Binary Heap、Agent 静态通行规则和 Path 回溯。
// 边界：Server Runtime Native Navigation；只读 GridMap，scratch 全部来自 NavigationContext。
// 输入/输出：WorldPosition A/B -> WorldPosition Path；失败使用 NavError。
// 内存：A* Node/Open 不做 per-node allocation；最终 Path 会分配结果 vector。
// 不负责：本文件当前不处理 DynamicOccupancy；第 7 节在同一判定链上叠加。
#include "grid_pathfinder.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <cstdint>
#include <limits>
#include <vector>

namespace battle_nav {
namespace {

constexpr std::uint32_t kStraightCost = 1000;
constexpr std::uint32_t kDiagonalCost = 1414;
constexpr std::size_t kMaxPathPoints = 65535;

struct Direction {
    std::int8_t dx;             // Grid X 偏移。
    std::int8_t dz;             // Grid Z 偏移。
    std::uint32_t base_cost;    // 1000=直走，1414=对角。
};

constexpr std::array<Direction, 8> kDirections{{
    {-1,  0, kStraightCost},
    { 1,  0, kStraightCost},
    { 0, -1, kStraightCost},
    { 0,  1, kStraightCost},
    {-1, -1, kDiagonalCost},
    {-1,  1, kDiagonalCost},
    { 1, -1, kDiagonalCost},
    { 1,  1, kDiagonalCost},
}};

// 把合法 GridPos 映射成稳定 node_index；width 来自 immutable map metadata。
std::int32_t NodeIndex(const GridMap& map, const GridPos& p) {
    const std::uint64_t index =
        static_cast<std::uint64_t>(p.z) * map.metadata().width +
        static_cast<std::uint32_t>(p.x);
    return static_cast<std::int32_t>(index);
}

// 把 node_index 还原成 GridPos；node_index 必须来自当前 map。
GridPos GridFromIndex(const GridMap& map, std::int32_t node_index) {
    const std::uint32_t width = map.metadata().width;
    return GridPos{
        static_cast<std::int32_t>(static_cast<std::uint32_t>(node_index) % width),
        static_cast<std::int32_t>(static_cast<std::uint32_t>(node_index) / width),
    };
}

// Octile Distance：8-way、直走1000、斜走1414 的可采纳启发式。
// 因为本课允许 Area Cost 只会 >=1000，所以真实代价不会低于此估计。
std::uint64_t Heuristic(const GridPos& a, const GridPos& b) {
    // 先提升到 int64 再相减，避免极端 GridPos 的 int32 减法溢出。
    const std::uint32_t dx = static_cast<std::uint32_t>(std::llabs(
        static_cast<long long>(a.x) - b.x));
    const std::uint32_t dz = static_cast<std::uint32_t>(std::llabs(
        static_cast<long long>(a.z) - b.z));

    // 一次对角移动同时消耗 X/Z 各 1 格，所以最多能斜走较小的轴向差值。
    // 例如 a=(0,0)、b=(4,3)：dx=4、dz=3，diagonal=min(4,3)=3。
    const std::uint32_t diagonal = std::min(dx, dz);

    // 斜走后，较长轴还剩的格数只能直走；上例为 max(4,3)-3=1。
    const std::uint32_t straight = std::max(dx, dz) - diagonal;

    // 上例的估计成本为 3*1414 + 1*1000 = 5242；不考虑障碍和动态占位。
    return static_cast<std::uint64_t>(diagonal) * kDiagonalCost +
        static_cast<std::uint64_t>(straight) * kStraightCost;
}

// 函数职责：只判断一个 Grid Cell 是否满足 Agent 的“单格静态站立条件”。
// map：当前 immutable GridMap；借用，不转移所有权；查询不修改地图。
// profile：已经通过 ValidateAgentProfile() 的单位规则；借用，不修改。
// grid：当前地图的 Grid 坐标，单位为 Cell；必须使用当前 map 的坐标范围。
// 返回值：Cell 存在、Walkable、clearance 和 Area 都满足时返回 true；否则返回 false。
// 不判断 current->next 的高差、坡度、对角侧格或动态占位；这些属于移动边或 Battle 状态。
// 不执行 I/O、分配、加锁或 yield；复杂度 O(1)。
bool CanOccupyStaticCell(
    const GridMap& map,
    const AgentProfile& profile,
    const GridPos& grid) {
    const NavCell* cell = map.TryCell(grid);
    if (cell == nullptr || !cell->IsWalkable()) {
        return false;
    }

    const std::uint8_t required =
        RequiredClearanceCells(profile, map.metadata().cell_size_mm);
    if (cell->clearance_cells < required) {
        return false;
    }

    const std::uint8_t area = cell->area_type;
    return profile.area_allowed[area] != 0;
}

// 函数职责：判断 current->next 这条 Grid 边是否满足静态高度、坡度和 corner-cutting 规则。
// map：当前 immutable GridMap；借用，不转移所有权；提供 Cell 高度和尺寸。
// profile：已经验证的 AgentProfile；借用；提供 max_step、max_slope、clearance 和 Area 规则。
// current：移动起点 Grid 坐标，单位为 Cell；必须属于当前 map。
// next：移动目标 Grid 坐标，单位为 Cell；通常等于 current + (dx,dz)。
// dx：X 轴格偏移，合法值为 -1、0、1；与 next.x-current.x 一致。
// dz：Z 轴格偏移，合法值为 -1、0、1；与 next.z-current.z 一致；dx/dz 都非 0 表示斜走。
// 返回值：目标格和移动边满足规则时返回 true；目标不可站、台阶/坡度超限或切角时返回 false。
// 不执行 I/O、分配、加锁或 yield；不检查 DynamicOccupancy；复杂度 O(1)。
bool CanTraverseStatic(
    const GridMap& map,
    const AgentProfile& profile,
    const GridPos& current,
    const GridPos& next,
    std::int32_t dx,
    std::int32_t dz) {
    if (!CanOccupyStaticCell(map, profile, next)) {
        return false;
    }

    const NavCell* from = map.TryCell(current);
    const NavCell* to = map.TryCell(next);
    if (from == nullptr || to == nullptr) {
        return false;
    }

    // height_mm 来自 BMAP 的 Cell Center 地表高度；max_step_mm 来自 Server AgentProfile。
    // 先提升到 long long 再相减，避免两个 int32 高度相减时在 32 位范围内溢出。
    const std::uint64_t height_delta = static_cast<std::uint64_t>(
        std::llabs(static_cast<long long>(to->height_mm) - from->height_mm));
    if (height_delta > static_cast<std::uint64_t>(profile.max_step_mm)) {
        return false;
    }

    // dx/dz 是 Grid 格偏移，不是毫米；两个都非 0 表示一次对角移动。
    // 对角水平距离用 1414/1000（约等于 sqrt(2)）的整数近似，避免查询热路径浮点比较。
    // 先转 uint64_t 再乘 1414，避免较大 cell_size_mm 在 32 位乘法中溢出。
    const std::uint64_t horizontal_mm =
        (dx != 0 && dz != 0)
            ? static_cast<std::uint64_t>(map.metadata().cell_size_mm) * 1414 / 1000
            : map.metadata().cell_size_mm;
    // 不使用浮点除法，交叉相乘表达：height_delta / horizontal_mm
    // 不能大于 max_slope_permille / 1000；刚好相等时允许通过。
    if (height_delta * 1000 >
        static_cast<std::uint64_t>(profile.max_slope_permille) * horizontal_mm) {
        return false;
    }

    if (dx != 0 && dz != 0) {
        // 禁止 corner cutting：斜走时两个正交侧格都必须用同一 AgentProfile 检查通过。
        const GridPos side_x{current.x + dx, current.z};
        const GridPos side_z{current.x, current.z + dz};
        if (!CanOccupyStaticCell(map, profile, side_x) ||
            !CanOccupyStaticCell(map, profile, side_z)) {
            return false;
        }
    }
    return true;
}

// 计算进入 next Cell 的整数移动成本；Area Cost 属于 AgentProfile。
std::uint32_t MoveCost(
    const GridMap& map,
    const AgentProfile& profile,
    const GridPos& next,
    std::uint32_t base_cost) {
    const NavCell* cell = map.TryCell(next);
    const std::uint32_t area_cost = profile.area_cost_permille[cell->area_type];
    const std::uint64_t scaled =
        static_cast<std::uint64_t>(base_cost) * area_cost / 1000;
    return scaled > std::numeric_limits<std::uint32_t>::max()
        ? std::numeric_limits<std::uint32_t>::max()
        : static_cast<std::uint32_t>(scaled);
}

// heap 中两个 node 谁优先：f=g+h 更小优先；f 相同则 h 小，再 node_index 小。
// 最后的 node_index tie-break 保证相同输入下顺序稳定。
bool HeapLess(
    NavigationContext& context,
    const GridMap& map,
    std::int32_t lhs,
    std::int32_t rhs,
    const GridPos& goal) {
    auto& left = context.TouchNode(lhs);
    auto& right = context.TouchNode(rhs);
    const std::uint64_t lh = Heuristic(GridFromIndex(map, lhs), goal);
    const std::uint64_t rh = Heuristic(GridFromIndex(map, rhs), goal);
    const std::uint64_t lf = left.g_cost + lh;
    const std::uint64_t rf = right.g_cost + rh;
    if (lf != rf) return lf < rf;
    if (lh != rh) return lh < rh;
    return lhs < rhs;
}

// 交换 heap 两个 slot，同时维护对应 NodeScratch.heap_index。
void HeapSwap(
    NavigationContext& context,
    std::size_t a,
    std::size_t b) {
    auto& heap = context.heap_storage();
    std::swap(heap[a], heap[b]);
    context.TouchNode(heap[a]).heap_index = static_cast<std::int32_t>(a);
    context.TouchNode(heap[b]).heap_index = static_cast<std::int32_t>(b);
}

void SiftUp(
    NavigationContext& context,
    const GridMap& map,
    std::size_t slot,
    const GridPos& goal) {
    auto& heap = context.heap_storage();
    while (slot > 0) {
        const std::size_t parent_slot = (slot - 1) / 2;
        if (!HeapLess(context, map, heap[slot], heap[parent_slot], goal)) {
            break;
        }
        HeapSwap(context, slot, parent_slot);
        slot = parent_slot;
    }
}

void SiftDown(
    NavigationContext& context,
    const GridMap& map,
    std::size_t slot,
    const GridPos& goal) {
    auto& heap = context.heap_storage();
    const std::size_t size = context.heap_size();
    for (;;) {
        const std::size_t left = slot * 2 + 1;
        if (left >= size) break;
        const std::size_t right = left + 1;
        std::size_t best = left;
        if (right < size && HeapLess(context, map, heap[right], heap[left], goal)) {
            best = right;
        }
        if (!HeapLess(context, map, heap[best], heap[slot], goal)) {
            break;
        }
        HeapSwap(context, slot, best);
        slot = best;
    }
}

void HeapPush(
    NavigationContext& context,
    const GridMap& map,
    std::int32_t node_index,
    const GridPos& goal) {
    auto& heap = context.heap_storage();
    const std::size_t slot = context.heap_size();
    heap[slot] = node_index;
    context.set_heap_size(slot + 1);
    context.TouchNode(node_index).heap_index = static_cast<std::int32_t>(slot);
    SiftUp(context, map, slot, goal);
}

std::int32_t HeapPop(
    NavigationContext& context,
    const GridMap& map,
    const GridPos& goal) {
    auto& heap = context.heap_storage();
    const std::int32_t result = heap[0];
    const std::size_t new_size = context.heap_size() - 1;
    context.set_heap_size(new_size);
    context.TouchNode(result).heap_index = -1;
    if (new_size > 0) {
        heap[0] = heap[new_size];
        context.TouchNode(heap[0]).heap_index = 0;
        SiftDown(context, map, 0, goal);
    }
    return result;
}

// 使用整数毫米计算 XZ 线段长度，最终 Path 长度用于日志/Benchmark/Replay。
std::uint64_t SegmentLengthMm(const WorldPosition& a, const WorldPosition& b) {
    const long double dx = static_cast<long double>(b.x_mm) - a.x_mm;
    const long double dz = static_cast<long double>(b.z_mm) - a.z_mm;
    return static_cast<std::uint64_t>(std::llround(std::sqrt(dx * dx + dz * dz)));
}

// 函数职责：把已经找到的 goal parent 链回溯成最终 Path。
// context：当前查询的 NavigationContext；借用并读取 NodeScratch，不转移所有权。
// map：当前 immutable GridMap；借用；负责 node_index -> GridPos -> WorldPosition 转换。
// goal_index：已经到达的目标 node_index；必须属于当前 map，且 parent 链最终能到达起点。
// 返回值：成功返回按起点到终点排列的 WorldPosition Path 和 XZ 折线长度。
// 失败：parent 链超过 kMaxPathPoints 返回 PATH_TOO_LONG；世界坐标转换失败返回对应 NavError。
// 分配与状态：为回溯序列和最终 Path 分配 vector；不执行 I/O、加锁或 yield，不修改 GridMap/profile；复杂度 O(L)，L 为路径节点数。
NavResult<Path> BuildPath(
    NavigationContext& context,
    const GridMap& map,
    std::int32_t goal_index) {
    // parent_index 指向起点方向；先保存 goal -> start 的反向 node_index 序列。
    std::vector<std::int32_t> reversed;
    reversed.reserve(64); // 只为最终回溯结果分配；不是 per-node heap allocation。

    std::int32_t current = goal_index;
    // 每个 Node 只沿 parent 访问一次；上限同时防止损坏 parent 链导致无限增长。
    while (current >= 0) {
        if (reversed.size() >= kMaxPathPoints) {
            return NavResult<Path>::Failure(
                NavError::kPathTooLong,
                "path point count exceeds safety limit");
        }
        reversed.push_back(current);
        const auto& node = context.TouchNode(current);
        current = node.parent_index;
    }
    // 回溯天然得到终点到起点，反转后才符合 Path 的行进顺序。
    std::reverse(reversed.begin(), reversed.end());

    // 下面分配的是最终 Path 数据；A* 搜索阶段没有为 Node 单独分配对象。
    std::vector<WorldPosition> points;
    points.reserve(reversed.size());
    std::uint64_t length_mm = 0;
    // node_index 只在 Native 内部使用；输出前统一转换为地图定义的世界毫米坐标。
    for (std::int32_t node_index : reversed) {
        const auto world = map.GridToWorldCenter(GridFromIndex(map, node_index));
        if (!world.ok()) {
            return NavResult<Path>::Failure(world.error, world.detail);
        }
        if (!points.empty()) {
            length_mm += SegmentLengthMm(points.back(), world.value);
        }
        points.push_back(world.value);
    }
    // Path 接管 points 的所有权；调用者通过 NavResult 获取不可变结果。
    return NavResult<Path>::Success(Path(std::move(points), length_mm));
}

} // namespace

// 函数职责：组织一次不含 DynamicOccupancy 的静态 Grid 8-way A* 查询。
// context：当前 Battle/Query 的 scratch owner；函数会修改其中的 generation、NodeScratch 和 Binary Heap，不能与其他查询并发共享。
// profile：单位导航规则；函数内部先验证，查询期间只读，不转移所有权。
// start/end：整数毫米 WorldPosition；归格和寻路使用 X/Z，Y 只参与输入记录，不由客户端覆盖地图高度。
// 返回值：成功返回按行进顺序排列的世界坐标 Path；失败返回 OUT_OF_BOUNDS、INVALID_AGENT、起终点不可走或 NO_PATH。
// 分配与状态：会重置当前 Context 查询状态并为最终 Path 分配结果内存；不执行 I/O、加锁或 yield，不处理动态占位；最坏时间 O(V log V)，scratch 空间 O(V)。
NavResult<Path> GridPathfinder::FindPathStatic(
    NavigationContext& context,
    const AgentProfile& profile,
    const WorldPosition& start,
    const WorldPosition& end) {
    // 先验证 profile 的 id、体型和 Area Cost 前提；失败立即返回，不启动查询或修改 scratch。
    const auto valid_profile = ValidateAgentProfile(profile);
    if (!valid_profile.ok()) {
        return NavResult<Path>::Failure(valid_profile.error, valid_profile.detail);
    }

    // 运行时只从 context 取得 immutable GridMap；WorldPosition 先按地图 origin/cell_size 转成 GridPos。
    const GridMap& map = *context.map();
    const auto start_grid = map.WorldToGrid(start);
    if (!start_grid.ok()) {
        return NavResult<Path>::Failure(NavError::kOutOfBounds, "start outside map");
    }
    const auto end_grid = map.WorldToGrid(end);
    if (!end_grid.ok()) {
        return NavResult<Path>::Failure(NavError::kOutOfBounds, "end outside map");
    }
    // 起点和终点必须先满足单格站立条件；边坡度和切角规则留给邻居扩展阶段。
    if (!CanOccupyStaticCell(map, profile, start_grid.value)) {
        return NavResult<Path>::Failure(
            NavError::kStartNotNavigable,
            "start cell rejected by walkable/clearance/area");
    }
    if (!CanOccupyStaticCell(map, profile, end_grid.value)) {
        return NavResult<Path>::Failure(
            NavError::kEndNotNavigable,
            "end cell rejected by walkable/clearance/area");
    }

    // BeginQuery 递增 generation 并清空本次 Heap 的逻辑范围；不会逐个 memset 整张地图。
    context.BeginQuery();
    const std::int32_t start_index = NodeIndex(map, start_grid.value);
    const std::int32_t goal_index = NodeIndex(map, end_grid.value);
    auto& start_node = context.TouchNode(start_index);
    start_node.g_cost = 0;
    start_node.parent_index = -1;
    start_node.state = NavigationContext::NodeState::kOpen;
    HeapPush(context, map, start_index, end_grid.value);

    while (context.heap_size() > 0) {
        // HeapPop 取出当前 f 最小的候选；同一节点被重复入堆时，Closed 状态会过滤旧条目。
        const std::int32_t current_index = HeapPop(context, map, end_grid.value);
        auto& current_node = context.TouchNode(current_index);
        if (current_node.state == NavigationContext::NodeState::kClosed) {
            continue;
        }
        current_node.state = NavigationContext::NodeState::kClosed;
        if (current_index == goal_index) {
            return BuildPath(context, map, goal_index);
        }

        // 当前节点出堆后才扩展它的 8 个邻居；每条边都重新执行目标格、坡度和切角验证。
        const GridPos current_grid = GridFromIndex(map, current_index);
        for (const Direction& direction : kDirections) {
            const GridPos next{
                current_grid.x + direction.dx,
                current_grid.z + direction.dz,
            };
            if (!CanTraverseStatic(
                    map, profile, current_grid, next,
                    direction.dx, direction.dz)) {
                continue;
            }

            // node_index 是当前 map 内稳定的一维索引；NodeScratch 由 Context 独占。
            const std::int32_t next_index = NodeIndex(map, next);
            auto& next_node = context.TouchNode(next_index);
            if (next_node.state == NavigationContext::NodeState::kClosed) {
                continue;
            }

            // candidate 是经当前节点到 next 的真实 g-cost；Area Cost 已在 MoveCost 中加入。
            const std::uint32_t step = MoveCost(map, profile, next, direction.base_cost);
            const std::uint64_t candidate = current_node.g_cost + step;
            if (next_node.state != NavigationContext::NodeState::kUnseen &&
                candidate >= next_node.g_cost) {
                continue;
            }

            // 只有发现新节点或找到更低 g-cost 时才改 parent；否则保留已有最优候选。
            next_node.g_cost = candidate;
            next_node.parent_index = current_index;
            if (next_node.state == NavigationContext::NodeState::kUnseen) {
                next_node.state = NavigationContext::NodeState::kOpen;
                HeapPush(context, map, next_index, end_grid.value);
            } else {
                // 已经在 Open 中，本次找到更低 g-cost；heap_index 直接执行 decrease-key。
                SiftUp(
                    context,
                    map,
                    static_cast<std::size_t>(next_node.heap_index),
                    end_grid.value);
            }
        }
    }

    // OPEN 耗尽仍未弹出 goal，说明静态规则下不存在可达路径。
    return NavResult<Path>::Failure(
        NavError::kNoPath,
        "open list exhausted before reaching goal");
}

} // namespace battle_nav
```

### 6.7.1 `BuildPath()`：把 parent 链变成 Path

`BuildPath()` 不再搜索。它只处理 A* 已经找到终点之后的结果构造：

```text
goal_index
-> parent_index 反向回溯
-> reversed = [goal, ..., start]
-> reverse(reversed)
-> node_index -> GridPos -> WorldPosition
-> 计算 XZ 折线长度
-> Path(WorldPosition[0..N-1])
```

例如：

```text
parent(2) = 1
parent(1) = 0
parent(0) = -1
```

从目标 2 开始得到：

```text
reversed = [2, 1, 0]
```

反转后才是业务需要的行进顺序：

```text
[0, 1, 2]
```

`goal_index` 和 `parent_index` 是 Native A* 的内部索引；`BuildPath()` 完成转换后，Lua、Battle 和 Replay 只看到 `WorldPosition`，不会长期依赖 `GridPos`。`reversed` 和最终 `points` 的分配属于结果构造分配，不是 A* 每访问一个 Node 就分配对象。

它还负责两个边界：回溯节点超过 `kMaxPathPoints` 时返回 `PATH_TOO_LONG`，某个 Node 无法转换成世界坐标时传播 `GridToWorldCenter()` 的错误。它不重新检查寻路合法性，也不重新执行 A*。

### 6.7.2 `FindPathStatic()`：组织一次完整的静态查询

`FindPathStatic()` 是对外的 A* 查询入口，内部顺序固定为：

```text
1. ValidateAgentProfile(profile)
2. WorldPosition start/end -> GridPos
3. 用 CanOccupyStaticCell() 检查起点和终点自身
4. BeginQuery()，初始化 start 的 g=0、parent=-1、state=Open
5. 从 Binary Heap 取 f 最小节点并置为 Closed
6. 到达 goal：调用 BuildPath() 返回结果
7. 否则检查 8 个邻居，用 CanTraverseStatic() 验证移动边
8. 计算 candidate g，更新 parent；新节点 HeapPush，旧节点 decrease-key
9. OPEN 为空仍未到达 goal：返回 NO_PATH
```

这个函数拥有本次查询的控制流程，但不拥有地图资产：`GridMap` 由 `MapRegistry` 以 immutable 形式共享，A* 可变 scratch 和 Heap 由传入的 `NavigationContext` 独占。函数不 yield、不调用 Skynet，也不把动态单位写入静态地图；动态占位在后续 Battle 查询策略中叠加。

理解自测：

```text
1. 为什么 FindPathStatic() 找到目标后不直接返回 node_index？
2. 为什么 BuildPath() 要先得到 [goal,...,start]，再 reverse？
3. 哪些数据属于 GridMap，哪些数据属于 NavigationContext？
4. start/end Cell 合法，为什么仍可能返回 NO_PATH？
```

> 说明：`BuildPath()` 为了输出精确毫米折线长度使用 `sqrt`。它不参与 A* 排序、通行判定和确定性 tie-break；真正的搜索成本全部是整数。若项目要求跨不同 CPU/标准库得到 bit-for-bit 相同的 `length_mm`，把这里替换成项目统一的整数平方根即可。逻辑 Event 的确定性不要依赖这个统计字段。

### 6.8 为什么现在还没有 DynamicOccupancy

因为当前先锁定静态算法错误：

```text
walkable
clearance
step
slope
area cost
corner cutting
```

如果一开始把动态单位也混进去，`NO_PATH` 时会很难判断是地图、Agent 还是 Battle 状态造成。下一节在静态 Golden Cases 全通过之后，再把动态层叠上去。


## 6.9 Path 端点仍然使用业务 WorldPosition

### 6.9.1 先明确要修复的问题

A* 搜索的是 Grid Cell。搜索成功后，`BuildPath()` 可以把每个 `node_index` 转成对应的 Cell Center，但 Battle 输入的起点和终点可能位于 Cell 内的任意毫米位置。

例如 Cell 尺寸为 `500mm`，地图原点从 `0mm` 开始：

```text
业务起点 WorldPosition： (100, 0, 200)
起点所在 Cell：          (0, 0)
该 Cell Center：          (250, 地表高度, 250)
```

如果直接把 Cell Center 作为 Path 第一个点，单位会从 `(100, 200)` 先移动或瞬移到 `(250, 250)`。Replay 看到的起点就不再是 Server 收到的真实业务位置。

终点也有同样的问题：业务请求可能要求到达 `(900, 1200)`，但目标 Cell Center 是 `(750, 1250)`。Cell 层面的可达性仍然正确，毫米层面的 Path 端点却丢失了。

本节要保持两个层次的职责：

```text
Grid 层：决定哪些 Cell 可走、parent 链是什么、路径经过哪些 Cell
World 层：保留业务起点/终点的 X/Z，并用 Server 地图高度作为 Y
```

这不是把 A* 改成连续空间寻路。A* 仍然只在 Cell 上运行；这里只是在路径已经找到以后，修正输出端点。

### 6.9.2 `BuildPath()` 新增的两个参数

[局部修改]

修改文件：

```text
server/native/grid_map/src/grid_pathfinder.cpp
```

这个函数是文件内的实现细节，不需要把它加入公共头文件。将原来的声明：

```cpp
NavResult<Path> BuildPath(
    NavigationContext& context,
    const GridMap& map,
    std::int32_t goal_index);
```

改为：

```cpp
NavResult<Path> BuildPath(
    NavigationContext& context,
    const GridMap& map,
    std::int32_t goal_index,
    const WorldPosition& start_world,
    const WorldPosition* exact_end_world);
```

参数含义如下：

```text
context          当前查询的 A* scratch owner；借用，不转移所有权
map              immutable GridMap；借用，不修改
goal_index       A* 已经找到的目标 Cell 的内部索引
start_world      业务传入的真实起点；必填，只读取 X/Z
exact_end_world  可选的真实终点；nullptr 表示保留 goal Cell Center
```

`exact_end_world` 使用指针是为了表达“可选”：

```cpp
&end    // 精确 FindPath：最后一点使用业务终点 X/Z
nullptr // FindPathToRange：最后一点使用搜索得到的 goal Cell Center
```

指针只是借用调用者的对象，不负责释放内存。它只在 `BuildPath()` 同步执行期间使用，不能保存到 `Path` 或异步任务中。

### 6.9.3 完整修改 `BuildPath()`

保留原来的 parent 回溯和 Grid-to-World 转换，但要把“累计长度”延后到端点修正之后。这样可以避免先按 Cell Center 算出旧长度，再修改点坐标后留下错误的 `length_mm`。

```cpp
// 函数职责：把已经找到的 goal parent 链转换为最终 WorldPosition Path，并收敛业务端点。
// context：当前查询的 NavigationContext；借用 NodeScratch，不转移所有权。
// map：当前 immutable GridMap；借用，负责 node_index -> GridPos -> WorldPosition。
// goal_index：已经到达的目标 node_index；必须属于当前 map。
// start_world：业务传入的真实起点；只读取 X/Z，Y 仍由地图 Cell 高度提供。
// exact_end_world：可选的业务终点；非空时只覆盖最后点的 X/Z，nullptr 时保留 goal Cell Center。
// 返回值：成功返回从起点到终点排列的 Path；失败返回 parent 链过长或坐标转换错误。
// 所有权与复杂度：Path 拥有最终 points；不执行 I/O、加锁或 yield；复杂度 O(L)，L 为路径节点数。
NavResult<Path> BuildPath(
    NavigationContext& context,
    const GridMap& map,
    std::int32_t goal_index,
    const WorldPosition& start_world,
    const WorldPosition* exact_end_world) {
    // parent_index 从目标指向起点；先得到 goal -> start 的反向序列。
    std::vector<std::int32_t> reversed;
    reversed.reserve(64);

    std::int32_t current = goal_index;
    // 每个 Node 沿 parent 只访问一次；上限防止损坏链导致无限增长。
    while (current >= 0) {
        if (reversed.size() >= kMaxPathPoints) {
            return NavResult<Path>::Failure(
                NavError::kPathTooLong,
                "path point count exceeds safety limit");
        }
        reversed.push_back(current);
        const auto& node = context.TouchNode(current);
        current = node.parent_index;
    }

    // 回溯得到的是终点到起点，Path 必须按实际行进方向排列。
    std::reverse(reversed.begin(), reversed.end());

    // 这里只分配最终 Path 的点；A* 搜索阶段没有为每个 Node 分配对象。
    std::vector<WorldPosition> points;
    points.reserve(reversed.size());
    for (std::int32_t node_index : reversed) {
        // node_index 只在 Native 内部使用；输出前转换成地图定义的世界毫米坐标。
        const auto world = map.GridToWorldCenter(GridFromIndex(map, node_index));
        if (!world.ok()) {
            return NavResult<Path>::Failure(world.error, world.detail);
        }
        points.push_back(world.value);
    }

    if (!points.empty()) {
        // 起点 Cell 的 Y 仍来自 GridMap，只有 X/Z 恢复为业务输入位置。
        // 客户端传入的 Y 不覆盖 Server 的权威地表高度。
        points.front().x_mm = start_world.x_mm;
        points.front().z_mm = start_world.z_mm;
    }

    if (exact_end_world != nullptr && !points.empty()) {
        if (points.size() == 1 &&
            (points.front().x_mm != exact_end_world->x_mm ||
             points.front().z_mm != exact_end_world->z_mm)) {
            // A/B 在同一 Cell 但毫米位置不同；追加真实终点，避免丢失 B。
            WorldPosition exact_end = points.front();
            exact_end.x_mm = exact_end_world->x_mm;
            exact_end.z_mm = exact_end_world->z_mm;
            points.push_back(exact_end);
        } else {
            // 多个 Cell 时，只修正最后一个点的 X/Z；Y 仍保留目标 Cell 高度。
            points.back().x_mm = exact_end_world->x_mm;
            points.back().z_mm = exact_end_world->z_mm;
        }
    }

    // 端点已经修正，必须重新计算长度；不能使用修改前的 Cell Center 长度。
    std::uint64_t length_mm = 0;
    for (std::size_t i = 1; i < points.size(); ++i) {
        length_mm += SegmentLengthMm(points[i - 1], points[i]);
    }

    // Path 接管 points 的所有权；调用者通过 NavResult 获取最终结果。
    return NavResult<Path>::Success(Path(std::move(points), length_mm));
}
```

这里有三个必须保持的规则：

```text
1. 只修正 X/Z，不让业务输入的 Y 覆盖地图高度。
2. 端点修正发生在 node_index -> WorldPosition 完成以后。
3. length_mm 必须在端点修正以后重新计算。
```

### 6.9.4 修改 `FindPathStatic()` 的调用

[局部修改]

`FindPathStatic()` 已经持有业务输入的 `start` 和 `end`。当 A* 弹出目标节点时，把这两个 WorldPosition 传给 `BuildPath()`：

原代码：

```cpp
if (current_index == goal_index) {
    return BuildPath(context, map, goal_index);
}
```

修改为：

```cpp
if (current_index == goal_index) {
    // 精确寻路保留调用者传入的起点和终点 X/Z；Y 仍由地图 Cell 高度决定。
    return BuildPath(
        context,
        map,
        goal_index,
        start,
        &end);
}
```

`start` 和 `end` 是 `FindPathStatic()` 的引用参数，在本次同步函数调用返回前始终有效；`BuildPath()` 只借用它们，不保存指针。

### 6.9.5 用例和验证结果

用例一：起点和终点在不同 Cell。

```text
Cell size = 500mm
业务起点 = (100, 0, 200)
业务终点 = (900, 0, 1200)

中间 Cell：使用 Cell Center
Path.front().x/z = (100, 200)
Path.back().x/z  = (900, 1200)
Path.front().y   = 起点 Cell 的静态 height_mm
Path.back().y    = 终点 Cell 的静态 height_mm
```

用例二：A/B 落在同一个 Cell，但毫米位置不同。

```text
A = (100, 0, 200)
B = (400, 0, 300)

A* 只有一个 node。
BuildPath() 先生成 A 所在 Cell Center，
然后保留 A 作为第一个点，再追加 B 作为最后一个点。
```

用例三：范围寻路。

```text
exact_end_world = nullptr
Path.back() = A* 找到的攻击位置 Cell Center
```

验证时至少检查：

```text
1. 普通 FindPath 的第一个点 X/Z 等于输入 start。
2. 普通 FindPath 的最后一个点 X/Z 等于输入 end。
3. 所有输出点的 Y 都来自对应地图 Cell，而不是客户端 Y。
4. 同一 Cell 内 A/B 不同位置时，Path 包含两个点且 length_mm 正确。
5. 范围寻路传 nullptr 时，不会把最后一点替换成目标单位中心。
```

---

# 第四部分：动态单位出现后，再给每场 Battle 增加 DynamicOccupancy

## 7. DynamicOccupancy：静态地图不再足够

静态 A* 跑通以后，出现第一个 Battle 问题：

```text
地图上这条路静态可走，
但现在另一个单位正站在这里。
```

第一课的 BMAP 不能修改：

```text
GridMap = 地图资产事实
DynamicOccupancy = 当前 Battle 的瞬时事实
```

如果把单位写进 `NavCell.flags`：

```text
Battle A Unit 10 occupy cell 500
-> 修改共享 GridMap
-> Battle B 同时看到 cell 500 被阻挡
```

这会直接破坏 Battle 隔离和 Native 线程安全。

### 7.1 DynamicOccupancy 的课程模型

每场 Battle 的 `DynamicOccupancy` 保存当前动态实体实际覆盖的 Cell。它是动态事实索引，不是游戏规则本身：

```text
DynamicOccupancy：某个单位的 AgentProfile + 中心 Cell -> 实际 footprint Cells
                 某个 Cell -> 当前有哪些 unit_id
业务回调：        这些实体是否阻挡当前移动单位
```

本课单位用圆形 `radius_mm`，映射到 Grid 时采用保守 footprint：

```text
检查以中心 Cell 为原点的有限邻域；
某邻居 Cell Center 到单位中心的距离
<= radius_mm + cell_size_mm/2
则由该单位实际占用。
```

这里要区分“路径意图”和“动态事实”：`Path` 只是单位当前想走的路线，`DynamicOccupancy` 只记录单位已经真实占用的 Cell。本课不预约整条 Path，也不提前锁定终点。

还要区分“保存事实”和“解释事实”：导航底层可以计算 footprint、保存多个实体的占用记录，但不能把“只要有其他 owner 就一定阻挡”写死。Grid 默认规则、Cell 级覆盖规则和业务回调共同决定是否允许进入：

```text
Grid 默认“有其他实体时能否重叠”
    -> Cell 级覆盖“有其他实体时能否重叠”
        -> 业务层回调根据当前实体关系做最终判断
```

例如 Grid 默认禁止穿人，Cell `(1,0)` 也设为禁止：该 Cell 空着时仍然可以进入；只有它被别的实体实际占用时才拒绝重叠。`Walkable/Area/Clearance` 才决定空 Cell 本身是否可站立。地图配置允许重叠也不强迫业务允许；业务回调仍可按阵营或单位类型拒绝。

本课统一采用一个简单语义：

```text
允许进入 = 允许经过 = 允许停留
```

不额外设计“只能经过不能停留”的状态。

```text
FindPath：    根据当前状态和业务回调生成一条可行路线，不承诺未来每个 Cell 都归这个单位
Move：        到达下一步时重新调用同一业务回调，成功后才写入真实占用
提交失败：   原位置保持不变，单位等待、停下或重新寻找附近位置
```

例如普通地面单位采用“独占”业务规则：

```text
A 先提交到 B -> 回调允许，DynamicOccupancy 写入 A
C 后提交到 B -> 回调发现 B 有 A，返回 false
```

如果业务规则允许同一 Cell 共存：

```text
A 先提交到 B -> DynamicOccupancy 写入 A
C 后提交到 B -> 回调返回 true，DynamicOccupancy 同时保存 A、C
```

业务回调不需要重新计算半径或 footprint，直接复用 `DynamicOccupancy::ForEachFootprintCell()` 和 `ForEachOccupant()` 即可。

这个策略故意不比较“谁离得近”或“谁速度快”，也不创建容易过期的长时间预约。单位断线、死亡、换目标时，只需要释放它当前真实持有的 footprint，不需要清理整条未来路径的锁。

这不是完整 steering/crowd system。它解决的是本课需要的离散动态阻挡、冲突提交和寻路避让。完整人群系统可能增加局部邻居查询、速度调整、目标站位分配或 RVO/ORCA，但不能用“每 Tick 为所有单位重新 A*”替代；路径通常只在明确失效时单独重算。

### 7.2 为什么 Move 必须先验证，再 commit

错误写法：

```text
clear old footprint
-> 发现 new footprint 被占用
-> 返回失败
```

失败以后，单位已经从 Occupancy 消失。

正确顺序：

```text
Validate static rules and business callback
-> 业务层已经决定是否允许与现有实体共存
-> clear old footprint owned by self
-> write new footprint facts
-> success
```

这表示“真实占用”的原子语义：失败时旧位置仍然存在，成功时才完成从旧 footprint 到新 footprint 的转换。`DynamicOccupancy` 只提交事实，不再次决定实体冲突规则。它不是未来路径预约，也不保证单位下一次一定能进入目标 Cell。

如果同一个 Tick 有多个单位请求同一目标 Cell，BattleWorker 必须按固定顺序调用 `Move()`，例如按稳定的 `unit_id` 或已排序的行动序号：

```text
    先处理的请求先执行业务回调和事实提交
    后处理的请求根据最新事实重新判断，允许共存则加入，禁止共存则失败
```

网络到达顺序不能直接作为胜负规则，否则相同输入可能因为网络时序不同而产生不同 Replay。距离、移动速度和等待时间当前不参与仲裁；它们属于以后增加公平调度或 Crowd 行为时的策略。

单个 `NavigationContext` 在 BattleWorker no-yield 核心中由同一个 Battle owner 使用，所以这里不加 mutex。多个 Battle 各自有自己的 Occupancy；共享锁不是正确的隔离方式。

### 7.3 DynamicOccupancy 学习导航

本文件解决的问题：保存一场 Battle 的动态 footprint 事实，并为业务回调提供统一查询入口。

本节必须掌握：

```text
DynamicOccupancy 只保存事实，不决定游戏规则
一个 Cell 可以保存多个动态实体 ID
footprint 与 Agent radius 的关系
Move validate-before-commit
ForEachFootprintCell 不重复计算半径
ForEachOccupant 查询当前实体
Path 是可失效的移动意图，不是预留合同
冲突提交按固定顺序执行
```

必须精读：`ForEachFootprintCell()`、`IsFootprintBlocked()`、`Move()`、`Release()`。

可以略读：lambda 调用语法。

输入、输出和失败：

```text
输入：GridMap 尺寸、AgentProfile、`NavigationAgentHandle`、中心 GridPos 和业务动态回调
输出：业务层允许/拒绝，或 DynamicOccupancy 的事实提交结果
失败：越界 footprint、无效句柄、静态规则拒绝或业务回调拒绝
```

内存：查询不构造临时 footprint vector；事实提交可能扩展 Cell 的实体列表。

运行验证：第 10 节统一测试覆盖 occupy/move/release/conflict/ignore self。

理解自测：为什么 Occupancy 可以保存“谁在这里”，但不能直接决定“谁可以进入这里”？

### 7.4 Agent 身份、动态查询和 DynamicOccupancy

本节的实际目标是让 Battle 保存“当前真实占用”，同时让底层导航不依赖业务实体 ID 的具体类型。课程仓库已提供下列四个基线文件；本节先读懂它们，随后第 7.5、7.6 节沿用这组接口。完成后可以通过第 7.6 节的 Native 测试观察占用和移动结果。

文件操作：

```text
[只读] server/native/grid_map/include/navigation_agent.h
[只读] server/native/grid_map/include/navigation_query.h
[只读] server/native/grid_map/include/dynamic_occupancy.h
[只读] server/native/grid_map/src/dynamic_occupancy.cpp
```

下面的短代码块只抽出必须精读的接口，不是可覆盖文件的完整代码。头文件依赖、namespace、私有字段、模板函数体以及 `.cpp` 的提交实现，以这些路径下的课程源码为准。第一次运行时先执行第 7.6 节的测试；不要用节选覆盖仓库文件。

这一版接口不使用 `uint32_t unit_id`、单 owner 的 `owner_by_cell` 或独立 `Place()`；身份与提交入口统一为：

```text
业务身份 -> NavigationAgentHandle
体型规则 -> AgentProfile
当前事实 -> DynamicOccupancy
动态业务规则 -> DynamicNavigationPolicy
```

#### 7.4.1 navigation_agent.h

本文件解决的问题：导航层需要识别“同一个移动实体”，但不应该规定业务层使用 32 位 ID、64 位 Handle 还是对象指针。

```cpp
// 职责：定义导航层使用的实体句柄和一次查询所需的 Agent 视图。
// 边界：Server Runtime Native Navigation；不拥有业务实体，不保存 Battle 位置。
// 输入/输出：业务层提供稳定 opaque handle 和 AgentProfile -> NavigationAgent 视图。
// 生命周期/所有权：NavigationAgent 只借用 profile；调用期间 profile 必须有效。
// 不负责：不保存业务指针、Lua userdata，也不建立业务 ID 映射表。
#pragma once

#include "agent_profile.h"
#include <cstdint>

namespace battle_nav {

struct NavigationAgentHandle {
    std::uint64_t value = 0; // 0=无效；同一 Context 内必须唯一。

    // 返回句柄是否可以参与导航查询和动态占用提交。
    bool valid() const noexcept { return value != 0; }
};

// 两个句柄按稳定 token 比较，Occupancy 清理时只移除当前实体。
inline bool operator==(
    const NavigationAgentHandle& lhs,
    const NavigationAgentHandle& rhs) noexcept {
    return lhs.value == rhs.value;
}

// 与 operator== 配套；业务实体 ID 的类型不进入导航层。
inline bool operator!=(
    const NavigationAgentHandle& lhs,
    const NavigationAgentHandle& rhs) noexcept {
    return !(lhs == rhs);
}

struct NavigationAgent {
    NavigationAgentHandle handle;          // 当前实体的导航身份。
    const AgentProfile* profile = nullptr; // 借用的静态体型规则。
};

} // namespace battle_nav
```

#### 7.4.2 navigation_query.h

本文件解决的问题：把动态查询所需的当前 Agent、地图、Occupancy、来源和目标 Cell 统一传给业务回调。

```cpp
// 职责：定义动态进入回调的查询参数和策略合同。
// 边界：Server Runtime Native Navigation；只描述一次查询，不拥有 Battle 状态。
// 输入/输出：NavigationAgent + 候选 Cell + 动态事实 -> 业务层 true/false。
// 生命周期/所有权：query 内指针只在一次 FindPath/MoveUnit 调用期间有效。
// 不负责：不实现阵营、实体类型、技能碰撞规则，也不执行 I/O 或 yield。
#pragma once

#include "navigation_agent.h"
#include <cstdint>

namespace battle_nav {

class DynamicOccupancy;
class GridMap;

enum class DynamicQueryPurpose : std::uint8_t {
    kFindPath = 0, // A* 规划阶段。
    kMove = 1,     // 实际提交前的重新验证。
};

struct DynamicNavigationQuery {
    const NavigationAgent* agent = nullptr;      // 当前移动者；只借用。
    const GridMap* map = nullptr;                // immutable 地图。
    const DynamicOccupancy* occupancy = nullptr; // 当前动态事实。
    GridPos from{};                              // 来源中心 Cell。
    GridPos target{};                            // 候选目标中心 Cell。
    DynamicQueryPurpose purpose = DynamicQueryPurpose::kFindPath;
};

// true=允许进入 target；false=拒绝候选。
using DynamicEnterCallback = bool (*) (
    void* user_data,
    const DynamicNavigationQuery& query);

struct DynamicNavigationPolicy {
    void* user_data = nullptr;               // 业务状态；底层不释放。
    DynamicEnterCallback callback = nullptr; // 同步、只读、不能 yield。
};

} // namespace battle_nav
```

#### 7.4.3 dynamic_occupancy.h/.cpp

本文件解决的问题：记录每个 Cell 当前有哪些动态实体，以及每个实体当前覆盖哪些 Cell。它保存事实，不决定业务冲突规则。

```cpp
// 职责：声明一场 Battle 的动态 footprint 事实索引和统一 Move/Release 接口。
// 边界：Server Runtime Battle-local Mutable State；不修改共享 GridMap。
// 输入/输出：NavigationAgentHandle + AgentProfile + GridPos -> 查询或 NavResult。
// 生命周期/所有权：由 NavigationContext 持有；Cell 列表和 footprint 记录由本对象拥有。
// 不负责：不决定实体是否互相阻挡；规则由业务回调决定。
class DynamicOccupancy final {
public:
    // map 必须在本对象生命周期内有效；构造时建立 Cell 列表。
    explicit DynamicOccupancy(const GridMap& map);

    // 越界视为阻挡；ignore_handle 只忽略当前移动者自己。
    bool IsBlocked(
        const GridPos& grid,
        NavigationAgentHandle ignore_handle) const noexcept;

    // 遍历完整 footprint，判断是否有其他动态实体。
    bool IsFootprintBlocked(
        const AgentProfile& profile,
        const GridPos& center,
        NavigationAgentHandle ignore_handle) const noexcept;

    // callback 返回 false 时提前停止；不构造临时实体列表。
    template <typename Callback>
    bool ForEachOccupant(
        const GridPos& grid,
        Callback callback) const;

    // 统一计算 Agent footprint；业务层不重复计算半径覆盖范围。
    template <typename Callback>
    bool ForEachFootprintCell(
        const AgentProfile& profile,
        const GridPos& center,
        Callback callback) const;

    // 首次调用登记出生位置；后续调用自动清理旧 footprint 再写入 target。
    // 目标越界或参数非法时失败，旧事实保持不变。
    NavResult<bool> Move(
        NavigationAgentHandle handle,
        const AgentProfile& profile,
        const GridPos& target);

    // 释放 handle 当前记录的全部 footprint；重复释放安全。
    NavResult<bool> Release(NavigationAgentHandle handle);

    // Debug/Test：返回任意 occupant；空 Cell 或越界返回无效句柄。
    NavigationAgentHandle FirstOccupantAt(
        const GridPos& grid) const noexcept;
};
```

`Move()` 的当前实现顺序是：计算目标 footprint、验证边界、准备容量、清理旧 Cell、写入新 Cell。目标验证失败时不会清理旧占用。它不判断“允许共存”还是“互相阻挡”；这属于 7.6 的业务回调。

### 7.5 把 Occupancy 加到 NavigationContext

Context 必须拥有本场 Battle 的 Occupancy，才能让路径查询和移动提交读取同一份动态事实。课程源码已经完成这一连接；阅读下面的成员关系和初始化顺序，运行第 7.6 节测试确认它生效。

文件操作：

```text
[只读] server/native/grid_map/include/navigation_context.h
[只读] server/native/grid_map/src/navigation_context.cpp
```

下面两段是成员与构造逻辑节选，省略了其余 A* scratch、头文件和 namespace，不可作为完整替换代码。

当前 `NavigationContext` 的成员关系是：

```cpp
// 文件职责：拥有一次 Battle 的 A* scratch 和动态占用事实。
// 所属边界：Server Runtime Battle-local Navigation。
// 输入/输出：immutable GridMap -> Node/Heap scratch + DynamicOccupancy。
// 生命周期/所有权：一个 Battle 独占一个 Context；Context 拥有这些可变状态。
// 不负责：不拥有业务实体、不保存 HP/AI、不跨 Battle 共享动态状态。
class NavigationContext final {
private:
    std::shared_ptr<const GridMap> map_; // immutable 地图共享所有权。
    DynamicOccupancy occupancy_;         // 当前 Battle 的真实动态 footprint。
    // nodes_、heap_、generation 等 A* scratch 保持当前源码定义。
};
```

公开访问器当前是：

```cpp
// 返回当前 Battle 私有动态占用；调用者只能在 Context owner 内修改。
DynamicOccupancy& occupancy() noexcept { return occupancy_; }
const DynamicOccupancy& occupancy() const noexcept { return occupancy_; }
```

`navigation_context.cpp` 使用下列安全的初始化顺序：

```cpp
// map 为空时抛出异常，避免 occupancy_ 解引用空 shared_ptr。
const GridMap& RequireMap(
    const std::shared_ptr<const GridMap>& map) {
    if (!map) {
        throw std::invalid_argument("NavigationContext requires map");
    }
    return *map;
}

NavigationContext::NavigationContext(
    std::shared_ptr<const GridMap> map)
    : map_(std::move(map)),
      occupancy_(RequireMap(map_)) {
    // 随后检查 cell_count，并分配 nodes_ 和 heap_。
}
```

业务实体不归 `NavigationContext` 所有。业务层调用导航时形成一个短生命周期的视图：

```cpp
const NavigationAgent agent{
    NavigationAgentHandle{business_agent_id},
    &agent_profile};
```

如果业务身份是指针或其他 Handle，由业务适配层先转换为稳定 token；导航层不建立通用映射表。

### 7.6 把动态占位叠加到 A*

静态地图无法回答“这一刻谁站在目标 Cell”，因此路径查询和移动提交都要使用本场 Battle 的动态规则。课程源码已经把这个规则接入 A*；本节检查公开签名、判断顺序与调用时机，再运行测试。

文件操作：

```text
[只读] server/native/grid_map/include/grid_pathfinder.h
[只读] server/native/grid_map/src/grid_pathfinder.cpp
```

下方只摘录公开接口；完整文件头、逐参数合同和实现均在对应课程源码中，不能用此节选覆盖头文件。

完成本节后，公开接口必须是：

```cpp
// 文件职责：声明 Grid 8-way A* 的静态和 Battle-local 动态路径查询入口。
// 所属边界：Server Runtime Native Navigation。
// 输入/输出：Context + Agent/WorldPosition -> Path 或明确 NavError。
// 生命周期/所有权：不保存全局状态；scratch 和动态事实由 Context 拥有。
// 不负责：不调用 Skynet，不执行 Unity 表现，不实现局部 Crowd 避碰。
class GridPathfinder final {
public:
    static NavResult<Path> FindPathStatic(
        NavigationContext& context,
        const AgentProfile& profile,
        const WorldPosition& start,
        const WorldPosition& end);

    static NavResult<Path> FindPath(
        NavigationContext& context,
        const NavigationAgent& agent,
        const WorldPosition& start,
        const WorldPosition& end,
        const DynamicNavigationPolicy& policy);

    static NavResult<bool> MoveUnit(
        NavigationContext& context,
        const NavigationAgent& agent,
        const WorldPosition& from,
        const WorldPosition& to,
        const DynamicNavigationPolicy& policy);
};
```

`CanOccupy()` 的当前判断顺序是：

```text
CanOccupyStaticCell()
-> Walkable / Clearance / Area
-> 枚举目标 footprint：仅在 Cell 有其他实体时应用 Grid/Cell 重叠配置
-> DynamicNavigationPolicy.callback()
```

`GridMap::AllowsDynamicEntry()` 读取的是 immutable 地图配置，不是“空格能不能走”的判定；底层把它和 `DynamicOccupancy::ForEachOccupant()` 组合，且只忽略当前 `agent.handle`。因此 `kBlock` Cell 空着时可走，有别的实体时即使回调返回 true 也不能重叠。

对角边的两个正交侧 Cell 也调用同一套 `CanOccupy()`，因此不能从动态单位之间切角。

`FindPath()` 和 `MoveUnit()` 使用相同的业务回调，但时机不同：

```cpp
// 规划阶段：读取当前快照，结果是可能失效的移动意图。
const NavigationAgent agent{
    NavigationAgentHandle{business_agent_id},
    &agent_profile};

const NavResult<Path> path = GridPathfinder::FindPath(
    context,
    agent,
    start_world,
    end_world,
    dynamic_policy);

// 提交阶段：真正跨格前重新验证，成功后才更新 Occupancy。
const NavResult<bool> moved = GridPathfinder::MoveUnit(
    context,
    agent,
    from_world,
    to_world,
    dynamic_policy);
```

```text
FindPath：按查询时刻的动态事实规划
MoveUnit：按提交时刻的动态事实复验并提交
失败：旧位置保持不变，路径失效或等待重寻路
```

这不是整条路径预约。`Path` 只是移动意图，`DynamicOccupancy` 只记录真实提交的 footprint；断线、死亡或离场时调用 `Release(agent.handle)`。

本节验证：

```text
cd "$(git rev-parse --show-toplevel)"
./server/native/grid_map/make_test.sh
```

必须看到 `grid_map_test` 和 `navigation_test` 全部通过。验证失败时先修复本节，不能带着不一致的接口继续进入第 8 节。

---

## 8. Path Smoothing：不能为了好看破坏已经正确的路径

本节建立在第 7.6 节已经通过测试的接口上：`FindPath()`、`MoveUnit()`、`NavigationAgent` 和 `DynamicNavigationPolicy` 的签名不得自行改回旧版。下面新增 smoothing 时继续复用同一套 `CanTraverse()`，不复制第二套通行规则。

第 7.6 节验证完成后，课程仓库中的 `grid_pathfinder.cpp/.h` 已提供本节的 smoothing 与 `ValidatePath*()`；本节先读懂它们并运行已有 Native 测试。第 9 节才继续增加攻击范围入口。下方代码块是精读节选，不用于覆盖整个文件。

Grid A* 的原始点可能是：

```text
A -> (1,0) -> (2,1) -> (3,1) -> (4,2) -> B
```

Unity 如果逐点播放，会有明显锯齿。可以删除中间冗余点，但不能只做几何直线判断。

每条候选简化 Segment 必须重新验证：

```text
walkable
clearance
step
slope
corner cutting
dynamic occupancy
area policy
```

还要注意 Area Cost：

```text
A* 绕开一大片 Mud
-> 纯 line-of-sight smoothing 直接穿过 Mud
-> 路径虽然“可走”，但改变了 A* 的成本选择
```

因此本课只有在：

```text
直接 Segment 合法
并且
direct_segment_cost <= original_subpath_cost
```

时才允许替换。

### 8.1 Smoothing 学习导航

本节解决的问题：减少 Grid 锯齿点，同时保持原静态/动态合法性和 Area Cost 语义。

必须精读：Supercover 遍历为什么覆盖线段穿过的所有 Cell、为何 smoothing 后重新走同一 `CanTraverse()`。

可以略读：Bresenham/Supercover 的整数误差变量。

输入、输出和失败：

```text
输入：已经由 A* 得到的 Grid node 序列
输出：点数 <= 原路径的合法序列
失败：某候选 shortcut 不合法时保留原中间点，不把整次 FindPath 判失败
```

内存：允许为最终 smoothing 结果 reserve O(path_points)；不做 per-map-size 分配。

运行验证：`navigation_test` 的 `TestSmoothedPathSegments()` 检查直线删点、动态绕行复验和非法长 Segment 拒绝。

理解自测：为什么“Raycast 没撞墙”还不足以证明 smoothing 正确？

### 8.2 在 `grid_pathfinder.cpp` 中阅读 Supercover 验证

[只读] `server/native/grid_map/src/grid_pathfinder.cpp`

[只读] `server/native/grid_map/include/grid_pathfinder.h`

`SegmentCheck`、`ValidateGridSegment()` 和 `SmoothGridPath()` 都是 `.cpp` 匿名 namespace 内的实现细节，位置在 `CanTraverse()`、`MoveCost()` 之后。不要把它们放进 `.h`：`QueryPolicy`、`CanTraverse()`、`MoveCost()` 也只定义在这个 `.cpp` 的匿名 namespace 中。头文件只声明公开的 `ValidatePathStatic()` 和 `ValidatePath()`。这样可以避免头文件引用不可见类型，也避免每个包含头文件的编译单元重复生成实现。

```cpp
struct SegmentCheck {
    bool valid = false;     // false=任一穿过的 Cell 边不合法。
    std::uint64_t cost = 0; // 使用与 A* 相同的 Area-adjusted cost；仅 valid 时读取。
};

// 使用整数 Supercover 思路逐 Cell 穿过一条 Grid 直线。
// 每一步都重新调用与 A* 相同的 CanTraverse，因此 corner/clearance/slope/dynamic 不会绕过。
// map/profile：immutable 地图与体型；policy/occupancy：本次查询的只读动态事实。
// from/to：已确认在本地图内的 Cell 坐标；返回 valid 和累计成本，不转移所有权。
// 不执行 I/O、分配、加锁或 yield；复杂度与线段穿过的 Cell 数成正比。
SegmentCheck ValidateGridSegment(
    const GridMap& map,
    const AgentProfile& profile,
    const QueryPolicy& policy,
    const DynamicOccupancy& occupancy,
    GridPos from,
    const GridPos& to) {
    // 先提升再相减；GridPos 虽为 int32，两个坐标之差不保证仍落在 int32。
    const std::int64_t delta_x =
        static_cast<std::int64_t>(to.x) - from.x;
    const std::int64_t delta_z =
        static_cast<std::int64_t>(to.z) - from.z;
    const int step_x = delta_x > 0 ? 1 : (delta_x < 0 ? -1 : 0);
    const int step_z = delta_z > 0 ? 1 : (delta_z < 0 ? -1 : 0);
    const std::int64_t nx = delta_x < 0 ? -delta_x : delta_x;
    const std::int64_t nz = delta_z < 0 ? -delta_z : delta_z;

    std::int64_t ix = 0;
    std::int64_t iz = 0;
    std::uint64_t cost = 0;
    while (ix < nx || iz < nz) {
        // 比较下一次跨越 X/Z 网格边界的归一化时刻。
        const std::int64_t lhs = (1 + 2 * ix) * nz;
        const std::int64_t rhs = (1 + 2 * iz) * nx;

        GridPos next = from;
        std::uint32_t base = kStraightCost;
        int dx = 0;
        int dz = 0;
        if (lhs == rhs) {
            dx = step_x;
            dz = step_z;
            ++ix;
            ++iz;
            base = kDiagonalCost;
        } else if (lhs < rhs) {
            dx = step_x;
            ++ix;
        } else {
            dz = step_z;
            ++iz;
        }
        next.x += dx;
        next.z += dz;

        if (!CanTraverse(
                map,
                profile,
                from,
                next,
                dx,
                dz,
                policy,
                occupancy)) {
            return SegmentCheck{};
        }
        cost += MoveCost(map, profile, next, base);
        from = next;
    }
    return SegmentCheck{true, cost};
}
```

在 A* 到达 goal、回溯得到 `reversed` 并反转以后，先把 node index 转成 GridPos 数组，再做有界 greedy smoothing。这里的 `raw` 是 A* 已验证的相邻 Cell 序列，返回的新 vector 由 `BuildPath()` 接收：

```cpp
// 用 A* 原路径成本约束最多 32 个后续候选，避免平滑变成无界全对全扫描。
// map/profile/policy/occupancy：与本次查询相同的只读借用；raw：相邻 Cell 序列。
// 返回新 vector，由调用者拥有；shortcut 无效时保留原来的相邻点。
std::vector<GridPos> SmoothGridPath(
    const GridMap& map,
    const AgentProfile& profile,
    const QueryPolicy& policy,
    const DynamicOccupancy& occupancy,
    const std::vector<GridPos>& raw) {
    if (raw.size() <= 2) {
        return raw;
    }

    constexpr std::size_t kMaxShortcutLookahead = 32;
    std::vector<GridPos> out;
    out.reserve(raw.size());
    out.push_back(raw.front());
    std::size_t anchor = 0;
    while (anchor + 1 < raw.size()) {
        std::size_t best = anchor + 1;
        std::uint64_t original_cost = 0;

        for (std::size_t candidate = anchor + 1;
             candidate < raw.size() &&
                 candidate <= anchor + kMaxShortcutLookahead;
             ++candidate) {
            // 原路径每条相邻边已合法；累计其真实 Area-adjusted 成本。
            const GridPos prev = raw[candidate - 1];
            const GridPos next = raw[candidate];
            const bool diagonal = prev.x != next.x && prev.z != next.z;
            original_cost += MoveCost(
                map, profile, next,
                diagonal ? kDiagonalCost : kStraightCost);
            const SegmentCheck direct = ValidateGridSegment(
                map,
                profile,
                policy,
                occupancy,
                raw[anchor],
                next);
            // 当前 shortcut 不合格，并不代表更远的候选也不合格；继续尝试。
            if (direct.valid && direct.cost <= original_cost) {
                best = candidate;
            }
        }

        out.push_back(raw[best]);
        anchor = best;
    }
    return out;
}
```

最后：

```text
parent 回溯 node_index
-> raw GridPos
-> SmoothGridPath
-> 每个 GridPos 调 GridToWorldCenter
-> Path(WorldPosition)
```

课程源码的 `BuildPath()` 已接收 `profile`、`QueryPolicy` 和 `DynamicOccupancy` 三个只读借用参数。`FindPathImpl()` 命中 goal 时传入当前 `profile`、`policy` 和 `context.occupancy()`；`BuildPath()` 反转 parent 链，用 `GridFromIndex()` 得到 `raw`，再把 `SmoothGridPath()` 的结果转换为世界点。最后仍按第 6.9 节修正真实起终点的 X/Z 并重新计算长度。第 9 节增加范围终点时，要沿用这份新签名。

平滑减少的是**折线拐点**，不跳过沿途 Cell。例如原路径沿直线依次经过
`(0,0) -> (1,1) -> (2,2) -> (3,3)`，平滑后可以只保存起点和终点；
单位仍沿这段直线逐步前进。如果原路线有弯折，新直线经过的 Cell 也可能
与原路线不同；平滑时必须先验证**新直线**上的静态通行条件。第 17 节在
Battle 出现真实调用者时增加 `context:advance_path(request)`：Battle 每个逻辑
Tick 只提供本 Tick 的整数毫米距离预算，Native 内部把长 Segment 拆成不超过
半个 Cell 的提交，并复用 `MoveUnit()` 逐步验证动态占位。一次提交最多从当前
Cell 进入一个相邻 Cell；一个 Tick 预算较大时，Native 可以连续提交多个子步。
这样路径点少、视觉运动直，后来站到途中 Cell 的单位仍可阻挡移动。业务层
不能把长 Segment 终点直接交给 `DynamicOccupancy::Move()`，也不需要自己实现
Grid 拆步和世界坐标插值。

几何上，直线不会比它替换的折线更长；代码还要求新线段的 Area 加权
Grid 成本不高于原段。不过 `Path.length_mm()` 当前逐段四舍五入再相加，
极短线段可能使显示的整数毫米数出现少量取整差；这个统计值不参与 A* 的比较或
移动合法性判断，不要把它误当成寻路成本。

`ValidatePathImpl()` 是 Native Test/Debug 使用的只读复验入口。它先验证 Profile、非空 Path 和起点，再把相邻世界点转换回 Grid 坐标，交给同一个 `ValidateGridSegment()`：

```cpp
// 复验输出 Path 的起点及每个 Grid Segment；参数只读借用。
// 成功返回 true；空路径、越界、无效 Profile 或非法边返回明确 NavError。
// 不修改 Occupancy/scratch，不执行 I/O、加锁或 yield。
NavResult<bool> ValidatePathImpl(
    NavigationContext& context,
    const AgentProfile& profile,
    const Path& path,
    const QueryPolicy& policy) {
    const auto valid_profile = ValidateAgentProfile(profile);
    if (!valid_profile.ok()) {
        return NavResult<bool>::Failure(valid_profile.error, valid_profile.detail);
    }
    if (path.count() == 0) {
        return NavResult<bool>::Failure(NavError::kNoPath, "empty path");
    }
    const GridMap& map = *context.map();
    const auto first = map.WorldToGrid(path.WorldPoint(0));
    if (!first.ok()) {
        return NavResult<bool>::Failure(first.error, first.detail);
    }
    if (!CanOccupy(map, profile, first.value, first.value,
                   policy, context.occupancy())) {
        return NavResult<bool>::Failure(
            NavError::kStartNotNavigable, "path start rejected");
    }
    GridPos from = first.value;
    for (std::size_t i = 1; i < path.count(); ++i) {
        const auto to = map.WorldToGrid(path.WorldPoint(i));
        if (!to.ok()) {
            return NavResult<bool>::Failure(to.error, to.detail);
        }
        if (!ValidateGridSegment(
                map, profile, policy, context.occupancy(), from, to.value).valid) {
            return NavResult<bool>::Failure(
                NavError::kNoPath, "path contains invalid Grid segment");
        }
        from = to.value;
    }
    return NavResult<bool>::Success(true);
}
```

`grid_pathfinder.h` 的 `public` 区只声明两个诊断入口：

```cpp
// 复验一条只使用静态地图规则的 Path；成功返回 true。
// context 提供 map 和临时验证环境；profile/path 只在调用期间借用。
static NavResult<bool> ValidatePathStatic(
    NavigationContext& context,
    const AgentProfile& profile,
    const Path& path);

// 按与 FindPath 相同的动态规则复验 Path；不修改 Occupancy。
// agent/policy 的生命周期要覆盖本次同步调用；函数不执行 I/O 或 yield。
static NavResult<bool> ValidatePath(
    NavigationContext& context,
    const NavigationAgent& agent,
    const Path& path,
    const DynamicNavigationPolicy& policy);
```

`ValidatePathStatic()` 构造内部静态 `QueryPolicy`，`ValidatePath()` 用 `agent + policy` 构造动态 `QueryPolicy`，两者都调用 `ValidatePathImpl()`。它们只是诊断包装，不复制通行规则；正式跨格提交入口仍然是 `MoveUnit()`。

缓存 Path 在生成后，其他单位仍可能移动到下一步的目标格或两个对角侧格。`move_unit` 因此不能只调用 `DynamicOccupancy::Move()` 检查终点 footprint；否则会重新出现动态 corner cutting。正式单步提交复用 A* 的 `CanTraverse()`；长 Segment 的只读诊断使用 `ValidateGridSegment()`：

```cpp
const NavigationAgent agent{
    NavigationAgentHandle{business_agent_id},
    &agent_profile};

const NavResult<bool> moved = GridPathfinder::MoveUnit(
    context,
    agent,
    from_world,
    to_world,
    dynamic_policy);
```

`MoveUnit()` 内部负责把世界坐标转换成相邻 Grid Cell，重新执行静态边、坡度、corner cutting、Grid/Cell 动态配置和业务回调检查；全部通过后才调用 `DynamicOccupancy::Move(agent.handle, *agent.profile, target_grid)`。

这里的“验证后提交”在一次同步 Native 调用里完成；同一 Battle 的 Context 只有一个 owner，所以两步之间没有另一个线程修改同一 Occupancy。不同 Battle 使用不同 Context，不需要为共享静态地图加锁。

本节立刻运行一次 Native 回归：

```bash
cd "$(git rev-parse --show-toplevel)"
./server/native/grid_map/make_test.sh
```

`navigation_test` 的 `TestSmoothedPathSegments()` 既断言开阔直线被缩成两个点，也调用 `ValidatePathStatic/ValidatePath` 逐段复验；还构造一条穿过动态占用格的非法长 Segment，确认它被拒绝。只断言“点变少了”不足以证明路径仍可走。

---

## 9. 起点/终点已被单位占用时，先区分 self 和 target

Battle 中两个常见情况：

```text
start Cell 被自己占用
end Cell 是目标中心，被目标占用
```

第一种由业务回调通过 `query.agent->handle` 识别自己；如果允许移动者继续站在自己的 footprint 上，只忽略这个句柄，不能忽略其他实体。

第二种不能简单 `ignore target` 后让攻击者走到目标身体中心。近战真实需求是：

> 找到一个处于 attack range、自己能站立、当前未被其他单位占用的位置。

这就是 Attack Position。

### 9.1 为什么这里不需要“未来 Backend 抽象”

业务只要求：

```text
给定 start / target / attack_range
-> 找到一条最终进入攻击范围的合法地面路径
```

现在底层只有 Grid，所以直接在当前 Grid 导航能力里实现。可选第四课接 Detour 时，再从 Grid 与 Detour 的两个真实实现中抽取共同 Contract。

### 9.2 本课的 FindPathToRange

课程源码从 start 做同一套 A*/Dijkstra 搜索，只把“终点条件”从：

```text
current == exact goal Cell
```

改成：

```text
current Cell Center 到 target_world 的 XZ 距离 <= attack_range_mm
并且当前 Cell 满足完整通行/Occupancy 规则
```

为了避免给“一个目标区域”设计错误的过高 heuristic，本课第一版对这个入口使用 `h=0`，也就是保留同一套 Binary Heap/Relax 的 Dijkstra 形式。它只在需要生成/重生成攻击路径时运行，不是每 Tick 运行。

后续 Benchmark 如果证明大地图攻击寻路成为瓶颈，可以增加对目标圆的可采纳 heuristic；不要先写一个看似聪明但可能破坏最优性的估计。

[只读] `server/native/grid_map/include/grid_pathfinder.h`

[只读] `server/native/grid_map/src/grid_pathfinder.cpp`

`grid_pathfinder.h` 已声明以下公开入口；本节阅读签名，不要把节选重复粘贴进头文件：

```cpp
    // 寻找到任一“进入 target 攻击范围”的合法 Cell；target 中心可以被目标自己占用。
    // agent.handle 标识移动者；业务回调只忽略自己，绝不忽略目标实体的 footprint。
    static NavResult<Path> FindPathToRange(
        NavigationContext& context,
        const NavigationAgent& agent,
        const WorldPosition& start,
        const WorldPosition& target,
        std::uint32_t attack_range_mm,
        const DynamicNavigationPolicy& policy);
```

目标判定使用整数平方距离。搜索节点按 Cell Center 判断；同一公式也能
检查单位的真实世界位置：

```cpp
// 用整数平方距离判断真实世界点是否已进入目标攻击范围。
// world/target：借用的 XZ 毫米坐标；range_mm：包含边界的非负半径。
// 返回 true 表示无需再向 Cell Center 移动；不分配、不加锁、不 yield。
bool WorldWithinAttackRange(
    const WorldPosition& world,
    const WorldPosition& target,
    std::uint32_t range_mm) {
    const std::int64_t dx =
        static_cast<std::int64_t>(world.x_mm) - target.x_mm;
    const std::int64_t dz =
        static_cast<std::int64_t>(world.z_mm) - target.z_mm;
    const std::uint64_t ax = static_cast<std::uint64_t>(dx < 0 ? -dx : dx);
    const std::uint64_t az = static_cast<std::uint64_t>(dz < 0 ? -dz : dz);
    if (ax > range_mm || az > range_mm) {
        return false;
    }
    const std::uint64_t range2 =
        static_cast<std::uint64_t>(range_mm) * range_mm;
    const std::uint64_t ax2 = ax * ax;
    // 先检查单轴，再做减法；避免两个极端坐标平方相加溢出 uint64。
    return az * az <= range2 - ax2;
}

// 搜索 goal 使用 Cell Center；世界点检查与它共用相同距离公式。
// map/grid：借用静态地图和候选 Cell；target/range_mm：XZ 世界毫米目标和半径。
// 返回 true 表示 Cell Center 在攻击范围内；地图查询失败视为 false；不修改状态。
bool InAttackRange(
    const GridMap& map,
    const GridPos& grid,
    const WorldPosition& target,
    std::uint32_t range_mm) {
    const auto world = map.GridToWorldCenter(grid);
    return world.ok() && WorldWithinAttackRange(world.value, target, range_mm);
}
```

`FindPathToRange()` 已复用原来的：

```text
CanTraverse
MoveCost
Binary Heap
NodeScratch
generation stamp
Build/Smooth Path
```

源码没有复制主循环，而是在 `.cpp` 匿名 namespace 中用 `GoalPolicy` 表达精确终点和攻击范围终点：

```cpp
struct GoalPolicy {
    bool exact = true;              // true=必须到 exact_grid；false=进入 target_world 的攻击范围即可。
    GridPos exact_grid{};           // 仅 exact=true 时使用。
    WorldPosition target_world{};   // 仅 exact=false 时使用，单位毫米。
    std::uint32_t attack_range_mm = 0;
};

bool IsGoal(const GridMap& map, const GridPos& current, const GoalPolicy& goal) {
    if (goal.exact) {
        return current.x == goal.exact_grid.x && current.z == goal.exact_grid.z;
    }
    return InAttackRange(map, current, goal.target_world, goal.attack_range_mm);
}

std::uint64_t GoalHeuristic(const GridPos& current, const GoalPolicy& goal) {
    // 精确 A->B 使用 Octile；目标区域第一版使用 Dijkstra(h=0) 保证不高估。
    return goal.exact ? Heuristic(current, goal.exact_grid) : 0;
}
```

`FindPathImpl()` 先按 `range_goal` 构造 `GoalPolicy`；精确模式才提前检查目标 Cell 可站立。范围模式的目标中心可被别人占用，只要求目标世界点在地图内。搜索循环的关键两处现在是：

```cpp
if (IsGoal(map, current_grid, goal)) {
    auto path = BuildPath(context, map, profile, policy, context.occupancy(),
                         current_index, start, goal.exact ? &end : nullptr);
    if (!path.ok() || !range_goal || current_index != start_index ||
        path.value.count() != 1 ||
        WorldWithinAttackRange(start, end, attack_range_mm)) {
        return path;
    }

    // 起点 Cell Center 已入范围，但真实 start_world 仍可能在范围外。
    // 此时追加同 Cell 的合法中心点，避免返回无法推进的单点 Path。
    const auto center = map.GridToWorldCenter(current_grid);
    if (!center.ok()) {
        return NavResult<Path>::Failure(center.error, center.detail);
    }
    std::vector<WorldPosition> points;
    points.reserve(2);
    points.push_back(path.value.WorldPoint(0));
    points.push_back(center.value);
    const std::uint64_t length_mm = SegmentLengthMm(points[0], points[1]);
    return NavResult<Path>::Success(Path(std::move(points), length_mm));
}

// HeapLess / SiftUp / SiftDown 统一读取 GoalHeuristic，而不是写死 exact end。
```

`FindPath()` 和 `FindPathStatic()` 调用同一个 `FindPathImpl(..., range_goal=false, attack_range_mm=0)`；`FindPathToRange()` 调用它的 `range_goal=true` 形式。内部构造对应的 `GoalPolicy`；其余 Neighbor/Relax/Heap/Parent/Smoothing 代码完全共用。

范围查询命中的 goal 是攻击者可站立的 Cell，不是目标单位中心。调用第 6.9 节的 `BuildPath()` 时，`exact_end_world` 因此传 `nullptr`，保留命中 Cell Center 的 X/Z；误传 `&target` 会把最后一个 Path 点移动到目标身体内。第 8 节为 `BuildPath()` 新增的 profile/policy/occupancy 参数同样要传入，不能改回旧签名。

有一个容易漏的边界：500mm Cell 的中心距目标 150mm，真实起点却在该 Cell
另一侧、距目标 300mm，而攻击范围是 200mm。A* 会立即命中起点 Cell，
但不能把真实起点当作“已进入范围”。源码在这种单 Cell 结果后补入 Cell
Center；真实起点已经在范围内时保持单点 Path。

不要创建 `AttackAStar.cpp`。复制两套搜索代码，后面修 corner cutting 时很容易只修其中一套。

运行 `./server/native/grid_map/make_test.sh`，确认 `navigation_test` 中的
`TestFindPathToOccupiedTargetRange()` 和 `TestRangeGoalUsesActualStartPosition()`
通过：目标中心由另一实体占用时停在合法攻击位置；起点 Cell Center
合格但真实起点未入范围时返回可移动终点；范围为 0 且目标被占时不可达。

---

# 第五部分：统一测试入口，先把导航风险锁死

## 10. 不给每个小节创建测试程序

第二课新增一个统一 Native 测试入口：

```text
server/native/grid_map/tests/navigation_test.cpp
```

第一课已有：

```text
grid_map_test.cpp
```

保留它作为第一课回归，不重命名。第二课所有 A*/Agent/Occupancy/Smoothing/Concurrency 都进入 `navigation_test`。

测试地图使用进程内构造的 `GridMap`，这样失败时不会把 BMAP Loader、Unity Exporter 和 A* 混成同一个问题。

### 10.1 测试必须覆盖的风险

```text
[ ] 起点越界
[ ] 终点越界
[ ] 起点不可走
[ ] 终点不可走
[ ] 无路径
[ ] 直线路径
[ ] 同一 Cell 内 A/B 不同仍保留两个精确业务端点
[ ] 绕障碍
[ ] 8-way corner cutting
[ ] clearance 不足
[ ] slope 超限
[ ] area cost 影响路线选择
[ ] dynamic occupancy
[ ] Grid/Cell 禁止穿人时空 Cell 仍可走；有其他实体时拒绝重叠
[ ] Cell 级允许重叠能覆盖 Grid 默认禁令，业务回调仍可继续拒绝
[ ] move conflict 不破坏旧 occupancy
[ ] 缓存路径提交移动时重新检查动态 diagonal side cells
[ ] ignore self
[ ] target center 被占用时 FindPathToRange 停在合法攻击位置
[ ] 负世界坐标转换
[ ] smoothing 后每段仍合法
[ ] 同输入/map/version/seed 重复结果一致
[ ] 多 NavigationContext 并发无共享 scratch 污染
```

这里的 deterministic Native test 不需要 RNG；它反复查询同一输入，要求 Path 世界点完全一致。Battle seed 与完整 Event 的重复模拟到第 20 节再验证。

### 10.2 navigation_test 学习导航

本文件解决的问题：用一个可执行程序锁定第二课 Native 导航全部高风险语义。

必须精读：每个 case 为什么存在、它锁定哪类线上 bug。

可以略读：`assert`、synthetic map builder 的机械初始化。

输入、输出和失败：

```text
输入：进程内 synthetic GridMap
输出：assert + 最终 ALL_TESTS_OK
失败：任何断言中止，定位到具体 case
```

运行验证：CTest。

理解自测：如果 `around wall` 通过但 `corner cutting` 没测，仍可能出现什么穿墙？

### 10.3 阅读统一测试入口

[只读]

```text
server/native/grid_map/tests/navigation_test.cpp
```

课程仓库已提供下面的完整测试文件，且与当前 WSL 源码保持一致；不要再新建或覆盖它。逐个运行和精读高风险用例即可。为了避免测试自己复制生产 `clearance` 算法，synthetic case 直接明确填入每格期望的 `clearance_cells`；这里测试的是“运行时消费 clearance 是否正确”，不是重复测试 Unity 第一课的 Clearance Builder。

```cpp
// 职责：统一验证第二课 Agent/A*/Occupancy/Smoothing/Determinism/Concurrency 风险。
// 边界：Native Test；不启动 Skynet、不读 Unity Scene、不依赖真实 BMAP 文件。
// 输入/输出：内存 synthetic GridMap -> assert 或 ALL_TESTS_OK。
// 生命周期：每个 case 创建独立 map/context；并发 case 共享 const map 但 Context 独立。
// 不负责：不做性能结论，性能由 navigation_benchmark 单独记录条件。
#include "agent_profile.h"
#include "dynamic_occupancy.h"
#include "grid_map.h"
#include "grid_pathfinder.h"
#include "navigation_context.h"

#include <cassert>
#include <cstdint>
#include <iostream>
#include <memory>
#include <thread>
#include <vector>

using namespace battle_nav;

namespace {

// 创建全可走 synthetic map；origin 是毫米制世界原点，返回 immutable shared owner。
std::shared_ptr<const GridMap> MakeMap(
    std::uint32_t width,
    std::uint32_t height,
    std::int32_t origin_x_mm = 0,
    std::int32_t origin_z_mm = 0,
    GridDynamicEntryRules dynamic_rules = {}) {
    BMapMetadata meta;
    meta.map_id = 9001;
    meta.map_version = 1;
    meta.width = width;
    meta.height = height;
    meta.cell_size_mm = 500;
    meta.origin_x_mm = origin_x_mm;
    meta.origin_z_mm = origin_z_mm;

    std::vector<NavCell> cells(width * height);
    for (NavCell& cell : cells) {
        cell.flags = kWalkableFlag;
        cell.height_mm = 0;
        cell.area_type = 0;
        cell.clearance_cells = 10;
    }
    return std::make_shared<const GridMap>(
        meta, std::move(cells), std::move(dynamic_rules));
}

// 构造带自定义 Cell 的地图，避免测试通过 const GridMap 后再修改共享资产。
std::shared_ptr<const GridMap> MakeMapFromCells(
    std::uint32_t width,
    std::uint32_t height,
    std::vector<NavCell> cells,
    std::int32_t origin_x_mm = 0,
    std::int32_t origin_z_mm = 0) {
    BMapMetadata meta;
    meta.map_id = 9002;
    meta.map_version = 1;
    meta.width = width;
    meta.height = height;
    meta.cell_size_mm = 500;
    meta.origin_x_mm = origin_x_mm;
    meta.origin_z_mm = origin_z_mm;
    return std::make_shared<const GridMap>(meta, std::move(cells));
}

// 把测试 GridPos 转为 z-major 数组下标；调用者保证 x/z 在范围内。
std::size_t Idx(std::uint32_t width, int x, int z) {
    return static_cast<std::size_t>(z) * width + x;
}

// 返回测试统一的小型地面 Agent；按值返回，不持有地图或共享状态。
AgentProfile Small() {
    AgentProfile p = MakeDefaultAgentProfile(1);
    p.radius_mm = 200;
    p.max_step_mm = 600;
    p.max_slope_permille = 1000;
    return p;
}

// 默认测试业务规则：目标 footprint 内只能出现移动者自己。
// query 中的指针由本次同步导航调用拥有；回调不保存、不分配、不 yield。
bool ExclusiveDynamicRule(
    void*,
    const DynamicNavigationQuery& query) {
    if (query.agent == nullptr || query.agent->profile == nullptr ||
        query.occupancy == nullptr) {
        return false;
    }
    return query.occupancy->ForEachFootprintCell(
        *query.agent->profile,
        query.target,
        [&](const GridPos& grid) {
            bool allowed = true;
            query.occupancy->ForEachOccupant(
                grid,
                [&](NavigationAgentHandle other) {
                    if (other != query.agent->handle) {
                        allowed = false;
                        return false;
                    }
                    return true;
                });
            return allowed;
        });
}

// 构造无所有权的同步查询策略；策略只引用上面的纯函数回调。
DynamicNavigationPolicy ExclusivePolicy() {
    return DynamicNavigationPolicy{nullptr, &ExclusiveDynamicRule};
}

// 业务允许多实体共存；地图级/Cell 级“禁止穿人”仍由底层先行检查。
bool SharedDynamicRule(void*, const DynamicNavigationQuery& query) {
    return query.agent != nullptr && query.agent->profile != nullptr &&
        query.occupancy != nullptr &&
        query.occupancy->ForEachFootprintCell(
            *query.agent->profile,
            query.target,
            [](const GridPos&) { return true; });
}

// 返回无状态的“业务允许共存”策略；回调不拥有 query 中的指针。
DynamicNavigationPolicy SharedPolicy() {
    return DynamicNavigationPolicy{nullptr, &SharedDynamicRule};
}

// 构造 Y=0 的毫米制测试世界位置；正式地表 Y 由 GridMap 输出。
WorldPosition P(int x_mm, int z_mm) {
    return WorldPosition{x_mm, 0, z_mm};
}

// 断言两个 Path 的所有逻辑字段完全一致；失败终止当前 Test 进程。
void AssertSamePath(const Path& a, const Path& b) {
    assert(a.count() == b.count());
    assert(a.length_mm() == b.length_mm());
    for (std::size_t i = 0; i < a.count(); ++i) {
        const auto& pa = a.WorldPoint(i);
        const auto& pb = b.WorldPoint(i);
        assert(pa.x_mm == pb.x_mm);
        assert(pa.y_mm == pb.y_mm);
        assert(pa.z_mm == pb.z_mm);
    }
}

// 锁定越界、不可走起点和不可走终点的稳定错误码。
void TestBoundsAndBlockedEndpoints() {
    auto map = MakeMap(5, 5);
    NavigationContext ctx(map);
    const AgentProfile p = Small();

    auto r = GridPathfinder::FindPathStatic(ctx, p, P(-1, 250), P(2250, 2250));
    assert(!r.ok() && r.error == NavError::kOutOfBounds);

    r = GridPathfinder::FindPathStatic(ctx, p, P(250, 250), P(2500, 250));
    assert(!r.ok() && r.error == NavError::kOutOfBounds);

    std::vector<NavCell> cells(25);
    for (auto& c : cells) {
        c.flags = kWalkableFlag;
        c.clearance_cells = 10;
    }
    cells[Idx(5, 0, 0)].flags = 0;
    cells[Idx(5, 4, 4)].flags = 0;
    auto blocked = MakeMapFromCells(5, 5, std::move(cells));
    NavigationContext blocked_ctx(blocked);

    r = GridPathfinder::FindPathStatic(blocked_ctx, p, P(250, 250), P(1750, 1750));
    assert(!r.ok() && r.error == NavError::kStartNotNavigable);
    r = GridPathfinder::FindPathStatic(blocked_ctx, p, P(750, 250), P(2250, 2250));
    assert(!r.ok() && r.error == NavError::kEndNotNavigable);
}

// 锁定直线成功、绕墙成功以及最终 Segment 复验。
void TestStraightAndAroundWall() {
    auto map = MakeMap(7, 5);
    NavigationContext ctx(map);
    const AgentProfile p = Small();
    auto straight = GridPathfinder::FindPathStatic(ctx, p, P(250, 1250), P(3250, 1250));
    assert(straight.ok());
    assert(straight.value.count() == 2); // 开阔直线的中间 Grid 点已被平滑掉。

    std::vector<NavCell> cells(35);
    for (auto& c : cells) {
        c.flags = kWalkableFlag;
        c.clearance_cells = 10;
    }
    for (int z = 0; z < 4; ++z) {
        cells[Idx(7, 3, z)].flags = 0; // 墙在 z=4 留一个口。
    }
    auto wall = MakeMapFromCells(7, 5, std::move(cells));
    NavigationContext wall_ctx(wall);
    auto around = GridPathfinder::FindPathStatic(
        wall_ctx, p, P(250, 250), P(3250, 250));
    assert(around.ok());
    assert(around.value.count() >= 3);
    assert(GridPathfinder::ValidatePathStatic(
        wall_ctx, p, around.value).ok());
}

// A/B 位于同一 Cell 时不需要搜索多个 Node，但正式 Path 仍必须到达精确 B。
void TestSameCellExactEndpoints() {
    auto map = MakeMap(2, 2);
    NavigationContext ctx(map);
    const auto result = GridPathfinder::FindPathStatic(
        ctx, Small(), P(100, 100), P(400, 400));
    assert(result.ok() && result.value.count() == 2);
    assert(result.value.WorldPoint(0).x_mm == 100);
    assert(result.value.WorldPoint(0).z_mm == 100);
    assert(result.value.WorldPoint(1).x_mm == 400);
    assert(result.value.WorldPoint(1).z_mm == 400);
}

// 锁定无路可达与 8-way 禁止切角规则。
void TestNoPathAndCornerCutting() {
    std::vector<NavCell> cells(9);
    for (auto& c : cells) {
        c.flags = kWalkableFlag;
        c.clearance_cells = 10;
    }
    // Start=(0,0)，Goal=(1,1)，两个正交侧格都阻挡；若允许切角会错误成功。
    cells[Idx(3, 1, 0)].flags = 0;
    cells[Idx(3, 0, 1)].flags = 0;
    auto map = MakeMapFromCells(3, 3, std::move(cells));
    NavigationContext ctx(map);
    auto r = GridPathfinder::FindPathStatic(ctx, Small(), P(250, 250), P(750, 750));
    assert(!r.ok() && r.error == NavError::kNoPath);
}

// 锁定 Agent clearance 差异和整数坡度拒绝。
void TestClearanceAndSlope() {
    std::vector<NavCell> cells(15);
    for (auto& c : cells) {
        c.flags = kWalkableFlag;
        c.clearance_cells = 3;
    }
    // 中间列只给 clearance=1；Small 可走，Large 要 2 格，因此 Large 必须失败/绕开。
    for (int z = 0; z < 3; ++z) {
        cells[Idx(5, 2, z)].clearance_cells = 1;
    }
    auto map = MakeMapFromCells(5, 3, cells);
    NavigationContext ctx_small(map);
    auto small = Small();
    assert(GridPathfinder::FindPathStatic(
        ctx_small, small, P(250, 750), P(2250, 750)).ok());

    auto large = Small();
    large.id = 2;
    large.radius_mm = 700; // required_clearance_cells = 2。
    NavigationContext ctx_large(map);
    auto large_path = GridPathfinder::FindPathStatic(
        ctx_large, large, P(250, 750), P(2250, 750));
    assert(!large_path.ok() && large_path.error == NavError::kNoPath);

    // 单独锁定 slope：1 个 500mm Cell 跨 1000mm 高差，max_step 放行但 slope 拒绝。
    cells.assign(3, NavCell{});
    for (auto& c : cells) {
        c.flags = kWalkableFlag;
        c.clearance_cells = 10;
    }
    cells[1].height_mm = 1000;
    auto slope_map = MakeMapFromCells(3, 1, std::move(cells));
    auto slope_agent = Small();
    slope_agent.max_step_mm = 1500;
    slope_agent.max_slope_permille = 500;
    NavigationContext slope_ctx(slope_map);
    auto slope = GridPathfinder::FindPathStatic(
        slope_ctx, slope_agent, P(250, 250), P(1250, 250));
    assert(!slope.ok() && slope.error == NavError::kNoPath);
}

// 锁定 Area Cost 会改变最优路径，且 smoothing 不会切回高成本区域。
void TestAreaCostChangesRoute() {
    const int w = 7;
    const int h = 3;
    std::vector<NavCell> cells(w * h);
    for (auto& c : cells) {
        c.flags = kWalkableFlag;
        c.clearance_cells = 10;
        c.area_type = 0;
    }
    // 中间直线标为 Mud(area=1)，上下两行保持 Normal。
    for (int x = 1; x < 6; ++x) {
        cells[Idx(w, x, 1)].area_type = 1;
    }
    auto map = MakeMapFromCells(w, h, std::move(cells));
    auto p = Small();
    p.area_cost_permille[1] = 5000;
    NavigationContext ctx(map);
    auto r = GridPathfinder::FindPathStatic(ctx, p, P(250, 750), P(3250, 750));
    assert(r.ok());
    assert(r.value.count() >= 3); // 高成本直线不能被平滑成单条捷径。

    bool left_middle_row = false;
    for (std::size_t i = 0; i < r.value.count(); ++i) {
        if (r.value.WorldPoint(i).z_mm != 750) {
            left_middle_row = true;
        }
    }
    assert(left_middle_row);
    assert(GridPathfinder::ValidatePathStatic(ctx, p, r.value).ok());
}

// 锁定平滑只删合法拐点：动态绕行保留，穿过占位格的长 Segment 必须拒绝。
void TestSmoothedPathSegments() {
    auto map = MakeMap(5, 3);
    NavigationContext ctx(map);
    const AgentProfile profile = Small();
    const NavigationAgent self{NavigationAgentHandle{10}, &profile};
    const NavigationAgent blocker{NavigationAgentHandle{20}, &profile};
    assert(ctx.occupancy().Move(self.handle, profile, GridPos{0, 1}).ok());
    assert(ctx.occupancy().Move(blocker.handle, profile, GridPos{2, 1}).ok());

    // 同一静态地图的直线可压成两个点；动态 blocker 只属于当前 Battle Context。
    const auto static_path = GridPathfinder::FindPathStatic(
        ctx, profile, P(250, 750), P(2250, 750));
    assert(static_path.ok() && static_path.value.count() == 2);
    assert(GridPathfinder::ValidatePathStatic(
        ctx, profile, static_path.value).ok());

    const auto detour = GridPathfinder::FindPath(
        ctx, self, P(250, 750), P(2250, 750), ExclusivePolicy());
    assert(detour.ok() && detour.value.count() >= 3);
    assert(GridPathfinder::ValidatePath(
        ctx, self, detour.value, ExclusivePolicy()).ok());

    // 手工构造“直接穿过 blocker”的长线段；构造 Path 本身不代表通过动态复验。
    const Path invalid(
        std::vector<WorldPosition>{P(250, 750), P(2250, 750)}, 2000);
    assert(!GridPathfinder::ValidatePath(
        ctx, self, invalid, ExclusivePolicy()).ok());
}

// Grid 默认禁止穿人、Cell 允许覆盖：空格始终可走，配置只约束有其他实体的格子。
void TestGridAndCellDynamicOverlapRules() {
    GridDynamicEntryRules rules;
    rules.default_allow = false;
    rules.per_cell.resize(6, CellDynamicEntryRule::kUseGridDefault);
    rules.per_cell[Idx(3, 2, 0)] = CellDynamicEntryRule::kAllow;
    auto map = MakeMap(3, 2, 0, 0, std::move(rules));
    NavigationContext ctx(map);
    const AgentProfile profile = Small();
    const NavigationAgent mover{NavigationAgentHandle{100}, &profile};

    // 即使默认禁止穿人，(1,0) 空着时仍可作为路径终点。
    assert(GridPathfinder::FindPath(
        ctx, mover, P(250, 250), P(750, 250), SharedPolicy()).ok());
    assert(ctx.occupancy().Move(
        NavigationAgentHandle{200}, profile, GridPos{1, 0}).ok());
    assert(ctx.occupancy().Move(
        NavigationAgentHandle{300}, profile, GridPos{2, 0}).ok());

    // (1,0) 有人时必须绕行；(2,0) 虽有人，但 Cell 级覆盖允许共存。
    const auto result = GridPathfinder::FindPath(
        ctx, mover, P(250, 250), P(1250, 250), SharedPolicy());
    assert(result.ok());
    assert(GridPathfinder::ValidatePath(
        ctx, mover, result.value, SharedPolicy()).ok());
    for (std::size_t i = 0; i < result.value.count(); ++i) {
        const auto grid = map->WorldToGrid(result.value.WorldPoint(i));
        assert(grid.ok());
        assert(!(grid.value.x == 1 && grid.value.z == 0));
    }
}

// 锁定统一 Move、多个实体事实和冲突时保留旧位置。
void TestDynamicOccupancyAndAtomicMove() {
    auto map = MakeMap(7, 3);
    NavigationContext ctx(map);
    auto p = Small();
    const NavigationAgent a{NavigationAgentHandle{100}, &p};
    const NavigationAgent c{NavigationAgentHandle{200}, &p};

    assert(ctx.occupancy().Move(a.handle, p, GridPos{2, 1}).ok());
    assert(ctx.occupancy().Move(c.handle, p, GridPos{4, 1}).ok());
    assert(ctx.occupancy().IsBlocked(GridPos{2, 1}, NavigationAgentHandle{}));
    assert(!ctx.occupancy().IsBlocked(
        GridPos{2, 1}, a.handle)); // 只忽略移动者自己。

    // a 先移入空格，再尝试移入 c 的格子。第二次失败后，a 必须仍在旧位置。
    const auto first_move = GridPathfinder::MoveUnit(
        ctx, a, P(1250, 750), P(1750, 750), ExclusivePolicy());
    assert(first_move.ok());
    const auto conflict = GridPathfinder::MoveUnit(
        ctx, a, P(1750, 750), P(2250, 750), ExclusivePolicy());
    assert(!conflict.ok());
    assert(ctx.occupancy().FirstOccupantAt(GridPos{3, 1}) == a.handle);
    assert(ctx.occupancy().FirstOccupantAt(GridPos{4, 1}) == c.handle);
}

// 业务允许共存时提交两个真实 owner；较大半径仍须检查整个目标 footprint。
void TestSharedCellAndRadiusFootprint() {
    auto map = MakeMap(5, 5);
    NavigationContext ctx(map);
    const AgentProfile small = Small();
    const NavigationAgent first{NavigationAgentHandle{100}, &small};
    const NavigationAgent second{NavigationAgentHandle{200}, &small};
    assert(ctx.occupancy().Move(first.handle, small, GridPos{2, 2}).ok());
    assert(ctx.occupancy().Move(second.handle, small, GridPos{3, 2}).ok());
    const auto moved = GridPathfinder::MoveUnit(
        ctx, second, P(1750, 1250), P(1250, 1250), SharedPolicy());
    assert(moved.ok());
    std::uint32_t count = 0;
    assert(ctx.occupancy().ForEachOccupant(
        GridPos{2, 2}, [&](NavigationAgentHandle) {
            ++count;
            return true;
        }));
    assert(count == 2);

    AgentProfile large = Small();
    large.id = 2;
    large.radius_mm = 500;
    assert(ctx.occupancy().IsFootprintBlocked(
        large, GridPos{3, 2}, second.handle));
    assert(!ctx.occupancy().ForEachFootprintCell(
        large, GridPos{4, 4}, [](const GridPos&) { return true; }));
}

// 缓存 Path 生成后，两个对角侧格可能被其他单位占据；提交移动时仍必须拒绝切角。
void TestMoveRevalidatesDynamicCorner() {
    auto map = MakeMap(3, 3);
    NavigationContext ctx(map);
    auto p = Small();
    const NavigationAgent self{NavigationAgentHandle{10}, &p};
    const NavigationAgent side_x{NavigationAgentHandle{20}, &p};
    const NavigationAgent side_z{NavigationAgentHandle{30}, &p};
    assert(ctx.occupancy().Move(self.handle, p, GridPos{0, 0}).ok());
    assert(ctx.occupancy().Move(side_x.handle, p, GridPos{1, 0}).ok());
    assert(ctx.occupancy().Move(side_z.handle, p, GridPos{0, 1}).ok());

    const auto moved = GridPathfinder::MoveUnit(
        ctx, self, P(250, 250), P(750, 750), ExclusivePolicy());
    assert(!moved.ok());
    assert(ctx.occupancy().FirstOccupantAt(GridPos{0, 0}) == self.handle);
    assert(!ctx.occupancy().FirstOccupantAt(GridPos{1, 1}).valid());
}

// 攻击目标中心被目标占用时，搜索必须停在攻击范围内的其他合法 Cell。
void TestFindPathToOccupiedTargetRange() {
    auto map = MakeMap(7, 3);
    NavigationContext ctx(map);
    auto p = Small();
    const NavigationAgent self{NavigationAgentHandle{10}, &p};
    const NavigationAgent target{NavigationAgentHandle{20}, &p};
    assert(ctx.occupancy().Move(self.handle, p, GridPos{0, 1}).ok());
    assert(ctx.occupancy().Move(target.handle, p, GridPos{5, 1}).ok());

    const auto result = GridPathfinder::FindPathToRange(
        ctx,
        self,
        P(250, 750),
        P(2750, 750),
        750,
        ExclusivePolicy());
    assert(result.ok());
    assert(GridPathfinder::ValidatePath(
        ctx, self, result.value, ExclusivePolicy()).ok());

    const WorldPosition& endpoint = result.value.WorldPoint(result.value.count() - 1);
    const auto endpoint_grid = map->WorldToGrid(endpoint);
    assert(endpoint_grid.ok());
    assert(!(endpoint_grid.value.x == 5 && endpoint_grid.value.z == 1));
    const std::int64_t dx = static_cast<std::int64_t>(endpoint.x_mm) - 2750;
    const std::int64_t dz = static_cast<std::int64_t>(endpoint.z_mm) - 750;
    assert(dx * dx + dz * dz <= 750LL * 750LL);
    const auto no_room = GridPathfinder::FindPathToRange(
        ctx, self, P(250, 750), P(2750, 750), 0, ExclusivePolicy());
    assert(!no_room.ok());
}

// 范围 goal 的 Cell Center 合格时，真实起点仍可能位于同 Cell 的攻击范围外。
// 这种情况下必须返回可移动的 Center 终点；真实起点已在范围内则保持单点 Path。
void TestRangeGoalUsesActualStartPosition() {
    auto map = MakeMap(3, 1);
    NavigationContext ctx(map);
    auto profile = Small();
    const NavigationAgent self{NavigationAgentHandle{10}, &profile};
    assert(ctx.occupancy().Move(self.handle, profile, GridPos{0, 0}).ok());

    const auto outside = GridPathfinder::FindPathToRange(
        ctx, self, P(100, 250), P(400, 250), 200, ExclusivePolicy());
    assert(outside.ok());
    assert(outside.value.count() == 2);
    assert(outside.value.WorldPoint(0).x_mm == 100);
    assert(outside.value.WorldPoint(1).x_mm == 250);
    assert(GridPathfinder::ValidatePath(
        ctx, self, outside.value, ExclusivePolicy()).ok());

    const auto inside = GridPathfinder::FindPathToRange(
        ctx, self, P(300, 250), P(400, 250), 200, ExclusivePolicy());
    assert(inside.ok());
    assert(inside.value.count() == 1);
    assert(inside.value.WorldPoint(0).x_mm == 300);
}
// 锁定负世界坐标使用 floor 归格，负数不等于越界。
void TestNegativeWorldCoordinates() {
    auto map = MakeMap(4, 4, -1000, -1000);
    NavigationContext ctx(map);
    auto r = GridPathfinder::FindPathStatic(
        ctx, Small(), P(-750, -750), P(750, 750));
    assert(r.ok());
    assert(r.value.WorldPoint(0).x_mm == -750);
    assert(r.value.WorldPoint(0).z_mm == -750);
}

// 在同一 Context 重复查询，锁定 generation 复用与稳定 tie-break。
void TestDeterministicRepeatedQuery() {
    auto map = MakeMap(20, 20);
    NavigationContext ctx(map);
    auto first = GridPathfinder::FindPathStatic(
        ctx, Small(), P(250, 250), P(9250, 9250));
    assert(first.ok());
    for (int i = 0; i < 100; ++i) {
        auto next = GridPathfinder::FindPathStatic(
            ctx, Small(), P(250, 250), P(9250, 9250));
        assert(next.ok());
        AssertSamePath(first.value, next.value);
    }
}

// 多线程只共享 immutable map，各线程 Context 独占；结果必须与 baseline 一致。
void TestIndependentContextsConcurrent() {
    auto map = MakeMap(64, 64);
    const AgentProfile p = Small();
    const WorldPosition start = P(250, 250);
    const WorldPosition end = P(31750, 31750);

    NavigationContext baseline_ctx(map);
    auto baseline = GridPathfinder::FindPathStatic(baseline_ctx, p, start, end);
    assert(baseline.ok());

    const int thread_count = 8;
    const int iterations = 500;
    std::vector<std::thread> threads;
    // 不使用 vector<bool>：它按 bit 打包，不同线程写“不同元素”仍可能落在同一机器字。
    std::vector<int> ok(thread_count, 1);
    for (int t = 0; t < thread_count; ++t) {
        threads.emplace_back([&, t]() {
            // 关键：每个线程/模拟 owner 都有独立 Context；只共享 const GridMap。
            NavigationContext local(map);
            for (int i = 0; i < iterations; ++i) {
                auto r = GridPathfinder::FindPathStatic(local, p, start, end);
                if (!r.ok()) {
                    ok[t] = 0;
                    return;
                }
                if (r.value.count() != baseline.value.count() ||
                    r.value.length_mm() != baseline.value.length_mm()) {
                    ok[t] = 0;
                    return;
                }
                for (std::size_t point = 0; point < r.value.count(); ++point) {
                    const auto& a = baseline.value.WorldPoint(point);
                    const auto& b = r.value.WorldPoint(point);
                    if (a.x_mm != b.x_mm || a.y_mm != b.y_mm || a.z_mm != b.z_mm) {
                        ok[t] = 0;
                        return;
                    }
                }
            }
        });
    }
    for (auto& thread : threads) thread.join();
    for (int value : ok) assert(value == 1);
}

} // namespace

// 运行全部第二课 Native correctness/stress case；任一 assert 失败返回非零。
int main() {
    TestBoundsAndBlockedEndpoints();
    TestStraightAndAroundWall();
    TestSameCellExactEndpoints();
    TestNoPathAndCornerCutting();
    TestClearanceAndSlope();
    TestAreaCostChangesRoute();
    TestSmoothedPathSegments();
    TestGridAndCellDynamicOverlapRules();
    TestDynamicOccupancyAndAtomicMove();
    TestSharedCellAndRadiusFootprint();
    TestMoveRevalidatesDynamicCorner();
    TestFindPathToOccupiedTargetRange();
    TestRangeGoalUsesActualStartPosition();
    TestNegativeWorldCoordinates();
    TestDeterministicRepeatedQuery();
    TestIndependentContextsConcurrent();

    std::cout << "ALL_TESTS_OK\n";
    return 0;
}
```

### 10.4 smoothing 测试不能只看 Path 点数

使用上一步已经加入的 `GridPathfinder::ValidatePathStatic/ValidatePath` 重新验证最终结果。至少断言：

```text
1. 原始路径可达；
2. smoothing 后 count <= raw count；
3. 每一段 supercover 仍通过：
   walkable / clearance / slope / area / corner / occupancy；
4. Mud detour case 不会被 smoothing 直接切回高成本区域；
5. 动态阻挡存在时 shortcut 不穿过被占 Cell。
```

不要写成：

```cpp
assert(smoothed.count() < raw.count());
```

因为“点变少”本身不是正确性。

### 10.5 核对 CMake 与统一测试脚本

[只读]

```text
server/native/grid_map/CMakeLists.txt
```

这个 Build 文件当前构建第二课导航核心和正确性测试；第 12 节才引入 Benchmark，不要在本节提前添加未使用的性能程序。当前文件头是：

```cmake
# 职责：构建 grid_map_core 和第一/二课 Native 导航回归测试。
# 边界：Server Native Build；不下载依赖，不构建 Skynet 本体。
# 输入/输出：本目录 C++ 源码 -> 静态库、测试可执行文件和 CTest 用例。
# 运行时机：第一/二课 Native 代码变化后，由 make_test.sh 驱动。
# 不负责：不下载依赖、不加载 Unity Scene、不启动 BattleWorker、不生成 BMAP。
```

`grid_map_core` 已包含：

```cmake
    src/navigation_context.cpp
    src/dynamic_occupancy.cpp
    src/grid_pathfinder.cpp
```

在第一课 `grid_map_test` 后，文件已包含：

```cmake
add_executable(navigation_test tests/navigation_test.cpp)
target_link_libraries(navigation_test PRIVATE grid_map_core pthread)
target_compile_options(navigation_test PRIVATE -Wall -Wextra -Wpedantic)
add_test(NAME navigation_test COMMAND navigation_test)
```

`make_test.sh` 已会运行第二课测试；核对它的文件头和实际命令即可：

[只读]

```text
server/native/grid_map/make_test.sh
```

```bash
# 职责：配置、编译并运行 GridMap 与 Grid Navigation 的 Native 回归测试。
# 边界：Server Native Build/Test；不下载依赖，不构建 Skynet 或 Lua Binding。
# 输入/输出：native/grid_map 源码 -> build/grid_map 构建产物和 CTest 结果。
# 运行时机：修改 BMAP、坐标、A*、占位或 NavigationContext 后执行。
# 不负责：不生成 BMAP，不启动 Skynet，不修改源码或测试数据。
```

运行：

```bash
cd "$(git rev-parse --show-toplevel)/server"
./native/grid_map/make_test.sh
```

`make_test.sh` 使用 CTest，所以新增 target 后无需再创建第二套测试脚本。

预期：

```text
grid_map_test     Passed
navigation_test   Passed
100% tests passed
```

CTest 默认隐藏成功用例的 stdout。需要亲眼看到 `ALL_TESTS_OK` 时，执行 `ctest --test-dir build/grid_map -V -R navigation_test`，或直接运行构建目录中的 `navigation_test`；不要把“默认输出没显示 marker”误判为测试没执行。

---

## 11. Concurrency Stress 的正确测试模型

错误测试：

```text
8 个 thread
-> 共用同一个 NavigationContext
```

这只能证明“你故意违反 ownership 后会不会撞得明显”。

本课要验证的正确模型是：

```text
                  shared_ptr<const GridMap>
                    /      |       \
                   /       |        \
          Context A   Context B   Context C
          scratch A   scratch B   scratch C
          occupancy A occupancy B occupancy C
```

多个 OS Thread 可以同时进入 `grid_map_core`，但它们的 mutable query state 完全不同。

如果环境支持，再额外跑：

```bash
cmake -S native/grid_map -B build/grid_map-tsan \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_CXX_FLAGS="-fsanitize=thread -fno-omit-frame-pointer" \
  -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=thread"
cmake --build build/grid_map-tsan -j"$(nproc)"
ctest --test-dir build/grid_map-tsan --output-on-failure
```

TSAN 是额外证据，不替代 ownership 设计。某些 WSL/工具链组合不支持 TSAN 时，记录环境限制，不把“没有跑 TSAN”包装成“已经证明无竞争”。

---

## 12. Benchmark：性能数字必须带条件

现在功能正确，才测性能。

统一 Benchmark。这个文件马上用于本节三组地图测试，并由 CMake 的 `navigation_benchmark` target 直接运行。

[新建文件]

```text
server/native/grid_map/benchmark/navigation_benchmark.cpp
```

```cpp
// 职责：在固定 synthetic Grid/query set 下记录 Grid A* 延迟、QPS、访问节点和 Context 内存条件。
// 边界：Standalone Benchmark；不启动 Skynet/Unity，不作为 correctness test。
// 输入/输出：固定地图尺寸/blocked ratio/query count -> 条件化性能统计。
// 生命周期：每组 case 创建一个 immutable map 和一个独立 NavigationContext。
// 不负责：不宣称跨机器性能，不把 Benchmark 数字写成产品 SLA。
#include "grid_pathfinder.h"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <iostream>
#include <memory>
#include <numeric>
#include <vector>

using namespace battle_nav;

namespace {

// 推进固定 LCG；state 由当前 Benchmark case 独占，返回下一 uint32 样本。
std::uint32_t Next(std::uint32_t& state) {
    state = state * 1664525u + 1013904223u;
    return state;
}

// 创建给定尺寸和阻挡率的可复现 synthetic map；不模拟真实 Clearance 分布。
std::shared_ptr<const GridMap> MakeSynthetic(
    std::uint32_t width,
    std::uint32_t height,
    std::uint32_t blocked_percent,
    std::uint32_t seed) {
    BMapMetadata meta;
    meta.map_id = width * 10000 + height;
    meta.map_version = 1;
    meta.width = width;
    meta.height = height;
    meta.cell_size_mm = 500;

    std::vector<NavCell> cells(static_cast<std::size_t>(width) * height);
    for (std::uint32_t z = 0; z < height; ++z) {
        for (std::uint32_t x = 0; x < width; ++x) {
            NavCell& cell = cells[static_cast<std::size_t>(z) * width + x];
            const bool border = x == 0 || z == 0 || x + 1 == width || z + 1 == height;
            const bool blocked = !border && (Next(seed) % 100u) < blocked_percent;
            cell.flags = blocked ? 0 : kWalkableFlag;
            cell.clearance_cells = blocked ? 0 : 10;
            cell.area_type = 0;
            cell.height_mm = 0;
        }
    }
    return std::make_shared<const GridMap>(meta, std::move(cells));
}

// 从 map 中确定性抽取一个可走 Cell Center；map 至少有一格可走是前置条件。
WorldPosition RandomWalkable(
    const GridMap& map,
    std::uint32_t& seed) {
    for (;;) {
        const GridPos grid{
            static_cast<std::int32_t>(Next(seed) % map.metadata().width),
            static_cast<std::int32_t>(Next(seed) % map.metadata().height),
        };
        const NavCell* cell = map.TryCell(grid);
        if (cell != nullptr && cell->IsWalkable()) {
            const auto world = map.GridToWorldCenter(grid);
            if (world.ok()) return world.value;
        }
    }
}

// 对耗时副本排序并返回 [0,1] 分位点；values 必须非空。
double Percentile(std::vector<double> values, double p) {
    std::sort(values.begin(), values.end());
    const std::size_t index = static_cast<std::size_t>(
        (values.size() - 1) * p);
    return values[index];
}

// 单线程执行一组固定 query set，并输出带完整条件的延迟/访问量统计。
void RunCase(std::uint32_t width, std::uint32_t height) {
    constexpr std::uint32_t kBlockedPercent = 15;
    constexpr int kQueries = 2000;
    auto map = MakeSynthetic(width, height, kBlockedPercent, 0x12345678u);
    NavigationContext context(map);
    AgentProfile profile = MakeDefaultAgentProfile(1);
    profile.radius_mm = 200;
    profile.max_step_mm = 500;
    profile.max_slope_permille = 1000;

    std::uint32_t seed = 0xabcdef01u;
    std::vector<double> microseconds;
    microseconds.reserve(kQueries);
    std::uint64_t visited_sum = 0;
    std::uint64_t path_points_sum = 0; // 成功路径实际保存的 WorldPosition 点数。
    int success = 0;
    int no_path = 0;

    const auto all_begin = std::chrono::steady_clock::now();
    for (int i = 0; i < kQueries; ++i) {
        const WorldPosition start = RandomWalkable(*map, seed);
        const WorldPosition end = RandomWalkable(*map, seed);
        const auto begin = std::chrono::steady_clock::now();
        const auto result = GridPathfinder::FindPathStatic(
            context, profile, start, end);
        const auto finish = std::chrono::steady_clock::now();
        microseconds.push_back(std::chrono::duration<double, std::micro>(
            finish - begin).count());
        visited_sum += context.visited_nodes();
        if (result.ok()) {
            ++success;
            path_points_sum += result.value.count();
        }
        else if (result.error == NavError::kNoPath) ++no_path;
    }
    const auto all_end = std::chrono::steady_clock::now();
    const double seconds = std::chrono::duration<double>(all_end - all_begin).count();

    const std::size_t cells = map->cell_count();
    // Context 创建时按 Cell 预分配 Node、Heap 和 Occupancy 的 Cell 索引。
    // 这里只统计这些固定数组的下界：不含 vector 容量余量、实体 footprint、
    // GridMap、Path 分配以及 allocator 元数据，不能当作进程实测内存。
    const std::size_t node_scratch_bytes =
        cells * sizeof(NavigationContext::NodeScratch);
    const std::size_t heap_bytes = cells * sizeof(std::int32_t);
    const std::size_t occupancy_index_bytes_est =
        cells * sizeof(std::vector<NavigationAgentHandle>);
    const std::size_t context_payload_bytes_est =
        node_scratch_bytes + heap_bytes + occupancy_index_bytes_est;
    // Path 点数组的按元素下界；仅累计成功查询，不包含 vector 容量余量。
    const std::uint64_t path_points_bytes_est =
        path_points_sum * sizeof(WorldPosition);

    std::cout
        << "BENCH width=" << width
        << " height=" << height
        << " blocked_percent=" << kBlockedPercent
        << " queries=" << kQueries
        << " threads=1"
        << " success=" << success
        << " no_path=" << no_path
        << " p50_us=" << Percentile(microseconds, 0.50)
        << " p95_us=" << Percentile(microseconds, 0.95)
        << " p99_us=" << Percentile(microseconds, 0.99)
        << " qps=" << (kQueries / seconds)
        << " avg_visited=" << (visited_sum / static_cast<double>(kQueries))
        << " node_scratch_bytes=" << node_scratch_bytes
        << " heap_bytes=" << heap_bytes
        << " occupancy_index_bytes_est=" << occupancy_index_bytes_est
        << " context_payload_bytes_est=" << context_payload_bytes_est
        << " path_points=" << path_points_sum
        << " path_points_bytes_est=" << path_points_bytes_est
        << "\n";
}

} // namespace

// 依次运行三种地图尺寸；成功返回 0，不把结果解释成产品 SLA。
int main() {
    RunCase(80, 60);
    RunCase(256, 256);
    RunCase(512, 512);
    return 0;
}
```

Benchmark 源文件创建后，构建系统还不知道这个新 target。对已存在的
`server/native/grid_map/CMakeLists.txt` 做局部修改，让本节能直接构建并运行它：

[局部修改]

```cmake
add_executable(navigation_benchmark benchmark/navigation_benchmark.cpp)
target_link_libraries(navigation_benchmark PRIVATE grid_map_core pthread)
target_compile_options(navigation_benchmark PRIVATE -Wall -Wextra -Wpedantic)
```

运行前记录环境：

```bash
lscpu | sed -n '1,20p'
g++ --version
cmake -S native/grid_map -B build/grid-map-release -DCMAKE_BUILD_TYPE=Release
cmake --build build/grid-map-release -j"$(nproc)"
./build/grid-map-release/navigation_benchmark
```

只需要一个程序，覆盖：

```text
80x60
256x256
512x512 synthetic
```

每组记录：

```text
CPU
compiler + version
build type / -O
map width/height
blocked ratio
query count
thread count
p50/p95/p99
qps
visited nodes
node_scratch_bytes / heap_bytes / occupancy_index_bytes_est
context_payload_bytes_est（固定数组下界，不是进程实测内存）
path_points / path_points_bytes_est（成功路径点数组的按元素下界）
```

### 12.1 Benchmark 不能证明什么

如果测试得到：

```text
80x60 p99 = 0.08ms
```

只能说明：

> 在这台 CPU、这个编译器、这个 Build、这组地图和 query set 下，观测到该结果。

不能写：

```text
“A* p99 就是 0.08ms”
“商业服一定扛得住”
```

真实 Battle 还包含 AI、动态占位、Lua/C 边界、事件生成和大量同时 Battle。

### 12.2 Benchmark 特别关注 Context 内存

程序打印：

```text
node_scratch_bytes
heap_bytes
occupancy_index_bytes_est
context_payload_bytes_est
```

`DynamicOccupancy` 为每个 Cell 保存一个 occupant vector，还会按实际实体分配
footprint；因此 `occupancy_index_bytes_est` 只覆盖空场景的固定 Cell 索引下界。
要回答真实常驻内存或峰值内存，应在指定单位数量下另测进程内存，不能把
这个估算值写成完整的 `occupancy_bytes`。

如果 512x512 的每 Battle Context 内存不可接受，这就是需要下一轮设计的证据。可选方向包括：

```text
Worker-local scratch pool
Context 按地图尺寸复用
Battle 分区/局部导航窗
稀疏 scratch
降低 cell density
```

本课不在没有数据的情况下提前实现这些优化。


# 第六部分：只有真实调用者出现以后，才扩展 Lua C Binding

## 13. Lua 业务仍然只看 WorldPosition

本节开始扩展第一课只提供 `load_map/query_cell` 的 Lua Native Binding。操作前必须已经完成第 8–12 节的 Native 接口和测试；本节新增动态寻路入口，不假设它们在第一课代码中已经存在。

Native 导航已经有了：

```text
AgentProfile
Path
NavigationContext
Grid A*
DynamicOccupancy
FindPathToRange
```

现在 BattleWorker 才真正需要跨 Lua/C 边界。

正式 Lua 调用面保持：

```lua
local context, err = battle_nav.new_context(
    map_id,
    map_version,
    profiles)

local path, err = context:find_path(
    profile_id,
    start_world,
    end_world,
    self_unit_id)

local path, err = context:find_path_to_range(
    profile_id,
    start_world,
    target_world,
    attack_range_mm,
    self_unit_id)
```

`GridPos` 只允许出现在 Native Debug 日志和测试，不进入 `battle_core.lua`。

### 13.1 为什么 Context 和 Path 使用 userdata

如果每次 FindPath 都把结果拆成几十个 Lua table：

```text
C++ Path
-> N 个 Lua table
-> N*3 个 integer field
-> GC 压力
```

本课先让 `Path` 作为 Native userdata 持有连续 `std::vector<WorldPosition>`：

```lua
path:count()
path:world_point(i)
path:length_mm()
```

Battle 在“生成/重生成路径”时保存本实体的 Path userdata；路线点仍可读取一次，
用于生成 `MOVE_PATH` Event。后续每个 Tick 把同一个 Path 交给 Native 推进入口，
不会反复创建 userdata，也不会把 Grid 拆步算法复制到 Lua。

`NavigationContext` 也使用 userdata，因为它真实拥有：

```text
A* scratch
binary heap
DynamicOccupancy
shared_ptr<const GridMap>
```

它不能被序列化跨 Skynet Service 发送。

### 13.2 一个很重要的 Skynet 所有权限制

```text
BattleMgr Lua State
   context userdata   X 不应该存在这里再发给 Worker

skynet.call
   只能发送可序列化 snapshot/value

BattleWorker Lua State
   在本 Service 内创建 NavigationContext userdata
   在本 Service 内使用和销毁
```

每个 Skynet Service 有自己的 Lua State。不要把某个 State 创建的 userdata 指针塞到另一个 Service。

### 13.3 Context 中怎样保存 AgentProfile

本课不增加进程级可变 `AgentProfileRegistry`。一场 Battle 在创建 Context 时传入自己冻结的 profile definitions：

```lua
profiles = {
    {
        id = 1,
        radius_mm = 200,
        max_step_mm = 600,
        max_slope_permille = 1000,
        area_cost_permille = {
            [0] = 1000,
            [1] = 3000,
            [2] = 1000,
            [3] = 1500,
        },
    },
}
```

Binding 把它复制成 `std::vector<AgentProfile>` 存在 Context userdata 旁边。Profile 数量通常远小于单位数；按 `profile_id` 做线性查找简单、稳定，也不依赖 unordered_map iteration。

`new_context()` 每调用一次都会新建 Context，并复制一次传入的 profiles；API 不会自动按
地图或实体合并。BattleWorker 的正确调用粒度是**每场 Battle 一次**：同场所有实体必须
看见同一份 DynamicOccupancy，并按 `profile_id` 共享这场 Context 中的只读 Profile。
例如 20 个普通士兵都使用 `profile_id=1`，这场 Battle 仍是 1 个 Context、1 份 Profile #1、
20 个不同的实体 Handle，以及最多 20 条各自持有的 Path。另一场 Battle 会创建独立
Context 和 Profile 快照，但可以通过 `shared_ptr<const GridMap>` 共享同一张只读地图。

如果错误地给每个实体创建 Context，它们的 DynamicOccupancy 会互相隔离，A 寻路时看不见
B 的占位；同时每个 Context 都重复分配按地图 Cell 数量计算的 A* scratch。这不是本课
Context 的所有权模型。

如果正式项目 Profile 来自全局版本化配置系统，可以在接入时把“配置快照 -> Context profiles”替换为已有配置读取；不要为了本课另造一整套配置中心。

### 13.4 Binding 修改学习导航

本次修改解决的问题：让每个 BattleWorker Lua State 能创建自己的 Context、调用 Pathfinding 和维护动态占位。

必须精读：

```text
LuaNavigationContext userdata ownership
LuaPath userdata ownership
__gc / close
profile 解析与校验
WorldPosition int32 range check
nil,error 返回合同
```

可以略读：重复的 metatable 注册样板和 `luaL_Reg` 数组语法。必须看懂 Lua C 函数的栈参数/返回值、`__index` 方法查找、`__gc` 析构，以及 full/light userdata 的所有权；下一小节先建立这些最小知识。

输入、输出和失败：

```text
输入：map/version/profiles/WorldPosition/unit_id
输出：context/path userdata；place_unit 成功返回归一地表 Y 后的 WorldPosition；失败统一返回 nil,{code,message}
失败：map 不存在、profile 不存在、坐标越界、NO_PATH、CONTEXT_CLOSED、occupancy conflict
```

内存：

```text
new_context   O(cell_count) Context + Occupancy 分配
find_path     A* scratch 复用；最终 Path vector + userdata 分配
world_point   创建一个很小 Lua table
```

锁/yield：Binding 内不调用 `skynet.call`、不 yield。`MapRegistry::Find` 仍是第一课的短锁查找；拿到 `shared_ptr<const GridMap>` 后 A* 不持有 Registry lock。

C++ exception 边界：`NavigationContext` 构造、Path 分配等 Native 代码如果抛出 `std::exception`，Binding 必须在 C++ 内捕获并转换为 `INTERNAL_ERROR`；异常不能穿过 `lua_CFunction` ABI。

运行验证：第 14 节先用单 Worker smoke，再进入 Battle。

理解自测：为什么 `Path userdata` 可以在同一 Worker 的多个 Lua 函数间传递，但不应该通过 `skynet.call` 发给另一个 Service？

### 13.5 扩展现有 `lua_battle_nav.cpp`

这是第一课已有文件，所以只做局部修改，不整份重建。

#### 13.5.1 沿一条真实调用链读懂 Lua C API

本节只跟踪一个实际操作：Lua 加载 `battle_nav`，创建 `NavigationContext`，调用 `context:find_path()` 并取得 `Path`。下面每张栈图都按同一个方向读：**左边是栈底，右边是栈顶**。标在值下方的 `+1` 是正索引；`-1` 永远表示本次 API 调用前的栈顶，`-2` 表示它下面一个值。API 改变栈后，负索引随之重新计算。

**第一步：加载模块并注册函数。** Lua `require "battle_nav"` 会调用导出的 `extern "C" luaopen_battle_nav()`。C linkage 让加载器能按固定符号名找到入口；普通辅助函数如 `register_path_meta()` 只在 C++ 内部调用，不需要导出。

一个 `.so` 可以导出多个函数，也可以包含多个 `luaopen_*` 入口；并不存在“一份 `.so` 只能对应一个加载函数”的限制。一次 `require "battle_nav"` 会按 `package.cpath` 找到动态库，再按模块名查找 `luaopen_battle_nav`，不会把库里的所有 `luaopen_*` 都调用一遍。若多个模块名通过文件布局、符号链接或自定义搜索器映射到同一个 `.so`，该库可以分别导出这些模块名对应的入口；每次 `require` 仍只选择与当前模块名匹配的入口。加载成功后模块缓存于 `package.loaded`，再次 require 通常直接取缓存。

`luaopen_battle_nav()` 先在当前 Lua State 注册 Context/Path metatable，再执行 `lua_newtable()`。它创建的只是一个普通空 table；只有当入口把它返回、`require` 把它缓存到 `package.loaded["battle_nav"]` 后，我们才把这个返回值称为 `battle_nav` 模块。

下面逐个看注册 `load_map` 时每个 API 怎样改变栈。`...` 表示 `require` 传给加载函数的参数，它们位于本例值的下方；表格只列本例正在操作的栈顶部分。值按**栈底到栈顶**排列：

| 执行的 API | 调用前：栈底 → 栈顶 | 调用后：栈底 → 栈顶 | 具体动作 |
| --- | --- | --- | --- |
| `lua_newtable(L)` | `...` | `... · 空 table` | 新建普通 table 并压栈；此时它只是候选模块表。 |
| `lua_pushlightuserdata(L, &MapRegistry::Instance())` | `... · 空 table` | `... · 空 table · Registry 指针` | 把进程级 Registry 的裸指针压到栈顶。 |
| `lua_pushcclosure(L, l_load_map, 1)` | `... · 空 table · Registry 指针` | `... · 空 table · load_map 闭包` | 取走栈顶 1 个值作为 upvalue，再压入闭包；指针被闭包捕获。 |
| `lua_setfield(L, -2, "load_map")` | `... · 空 table(-2) · load_map 闭包(-1)` | `... · table` | `-2` 指 table，`-1` 指闭包；把闭包设为 table 的 `load_map` 字段，然后弹出闭包。 |
| `return 1` | `... · table(-1)` | 将栈顶 1 个值返回给调用者 | 返回这个 table；`require` 随后缓存它。 |

例如 `lua_setfield(L, -2, "load_map")` 执行后，栈顶只剩 table，但 table 里已经有 `load_map` 函数。`return 1` 不是 `lua_pop`：它告诉 Lua C 调用框架把栈顶的一个值作为函数结果交还给 `require`。

这里的指针是 **lightuserdata**：Lua 只保存地址，不拥有、不复制、不析构 `MapRegistry`。地址有效依赖 Native 进程级 Registry 的生命周期。每个 Service 的 `require` 都有自己的 module table、closure 和 Lua State；它们可以指向同进程的 Registry，但 closure 不是跨 Service 消息。

本课保留闭包 upvalue，是为了让你看懂“创建 Lua C 函数时绑定依赖”的做法。当前 `MapRegistry::Instance()` 已经是进程级单例，因此这段绑定在本实现里不是必需的；若工程确定永远只用这个单例，`l_load_map()` 等 C 入口可直接调用 `MapRegistry::Instance()`，省去 lightuserdata、upvalue 和 `registry(L)` helper。只有需要把不同 Registry 显式绑定给不同函数实例时，闭包捕获才带来实际价值。不要把教学示例理解成所有单例都必须经闭包传递。

代码注释也要表达这个取舍：当前保留 `lua_pushlightuserdata + lua_pushcclosure` 是课程 Binding 的显式依赖示例；它不是 `MapRegistry` 单例的必需调用步骤。阅读下面的实际 C++ 代码时，把它看作“理解 closure/upvalue 的教学写法”，不要因此在新的生产 Binding 中机械复制。

**第二步：创建 Context userdata。** Lua 调用 `battle_nav.new_context(map_id, map_version, profiles)`。入口参数位置和对应正/负索引如下：

| 从栈底到栈顶 | 正索引 | 负索引 |
| --- | ---: | ---: |
| `map_id` | `1` | `-3` |
| `map_version` | `2` | `-2` |
| `profiles` | `3` | `-1` |

`luaL_checkinteger(L, 1)` 读取并校验 `map_id`，不弹出它；`luaL_checktype(L, 3, LUA_TTABLE)` 检查 `profiles` 类型，也不改变栈。随后创建 full userdata 并挂好 metatable：

| 执行到哪一步 | 从栈底到栈顶 | 栈顶索引 |
| --- | --- | --- |
| 入口 | `map_id · map_version · profiles` | `profiles = -1` |
| `lua_newuserdatauv` 后 | `map_id · map_version · profiles · context_userdata` | `context_userdata = -1` |
| placement new 后 | `map_id · map_version · profiles · context_userdata` | 不变；只在 userdata 内存构造 C++ owner |
| `luaL_getmetatable` 后 | `map_id · map_version · profiles · context_userdata · meta` | `meta = -1`，userdata = `-2` |
| `lua_setmetatable(L, -2)` 后 | `map_id · map_version · profiles · context_userdata` | `meta` 已弹出并附着到 userdata |

**full userdata** 是 Lua State 管理的一块存储；`lua_newuserdatauv` 把它压栈，placement new 在其中构造 `LuaNavigationContext`，但不会自动调用 C++ 析构函数。`luaL_getmetatable` 从当前 State 的 registry 取出已注册的元表并压栈；`lua_setmetatable(L, -2)` 把栈顶元表挂到它下面的 userdata 上，然后弹出元表。成功时 `l_new_context()` 以 `return 1` 返回栈顶 Context userdata。

**第三步：看 metatable 怎样连上方法和析构。** `register_context_meta()` / `register_path_meta()` 在 `luaopen_battle_nav()` 中执行。下面以 Path 为例；表格里每行都是执行完该 API 后的完整栈（左底右顶）：

| API 调用 | 调用后栈（栈底 → 栈顶） | 发生了什么 |
| --- | --- | --- |
| `luaL_newmetatable(L, kPathMeta)` | `meta` | 从 registry 创建或取回元表，并压入；返回布尔值说明是否新建。 |
| `lua_pushcfunction(L, l_path_gc)` | `meta · gc_fn` | 压入析构回调。 |
| `lua_setfield(L, -2, "__gc")` | `meta` | `-2` 指 meta；把 `gc_fn` 设为字段并弹出回调。 |
| `lua_newtable(L)` | `meta · methods` | 创建方法表并压入。 |
| `lua_pushcfunction`，再 `lua_setfield(L, -2, "count")` | `meta · methods` | 函数先压栈；`-2` 指 methods，设置 `count` 后弹出函数。其他方法同理。 |
| `lua_setfield(L, -2, "__index")` | `meta` | `-2` 指 meta；把 methods 表挂到 `meta.__index` 并弹出 methods。 |
| `lua_pop(L, 1)` | 空栈 | 弹出 meta；注册函数净栈变化为 0。 |

以后 Lua 读取 `path.count` 时，`__index` 会到 methods 表查找 C 函数。Context 的注册方式相同，只是方法名不同。`__gc` 字段让 Lua 知道 userdata 不再可达、准备回收时要调用哪个 C 函数。

**第四步：从 Lua 方法调用跟到 C 函数返回。** `__index` 找到 `find_path` 后，冒号调用：

```lua
local path, err = context:find_path(profile_id, start_world, end_world, self_unit_id)
```

等价于把 `context` 显式作为第一个参数：

```lua
local path, err = context.find_path(
    context, profile_id, start_world, end_world, self_unit_id)
```

因此 `l_context_find_path()` 进入时的栈是：

| 从栈底到栈顶 | 正索引 | 负索引 |
| --- | ---: | ---: |
| Context userdata（冒号调用隐式传入） | `1` | `-5` |
| `profile_id` | `2` | `-4` |
| `start_world` table | `3` | `-3` |
| `end_world` table | `4` | `-2` |
| `self_unit_id` | `5` | `-1` |

`luaL_checkudata(L, 1, kContextMeta)` 检查第一个参数确实是 Context userdata，栈不变。读坐标时 `lua_getfield` 把字段值压栈，`lua_pop(L, 1)` 随即弹出，因此每读完一个字段都回到入口 `top=5`。成功时 `push_path()` 创建 Path full userdata、挂上 Path metatable，栈顶成为第 6 个值；`return 1` 把它作为 `path` 返回。失败时 `push_nav_failure()` 在原参数上方压入 `nil` 和 error table，`return 2` 把这两个栈顶值作为 `path, err` 返回。

这里 `lua_getfield` **压入**字段值，`lua_setfield` **弹出**待设置的字段值；`lua_push*` 压栈，`lua_pop` 弹栈。每次使用 `-1/-2` 都以该 API 调用前的栈为准。`return n` 表示把栈顶 n 个值交给 Lua，不是 C++ 的成功/失败码。

**最后看对象何时释放。** `context:close()` 调用绑定的关闭函数，立即释放 Context 内的大块寻路状态；Context userdata 本身仍在 Lua 栈/变量中。对象之后不再可达时，`__gc` 回调在栈上收到该 userdata，执行 placement-new owner 的 C++ 析构，释放外层 userdata 内的成员。Path userdata 也由自己的 `__gc` 析构。Lightuserdata 没有这样的自动析构机制；两种 userdata 都属于创建它们的 Lua State，`skynet.call` 跨 Service 传递的是 Snapshot、ID、坐标等序列化值。

Lua 的 `luaL_error` 会用非局部跳转离开 C 函数；如果它跳过了持有资源的 C++ 局部变量析构，就会泄漏。因此本 Binding 对可预期失败返回 `nil,error`，并在 C++ 内捕获异常，不让异常穿过 Lua C ABI。

读后可以用同一条调用链检查自己是否理解：入口函数怎样被模块 table 找到，参数如何按索引取出，Context/Path 怎样通过 metatable 调用，返回值为何是 `return 1` 或 `return 2`，以及 Native 对象在哪一步释放。下面开始按这个顺序修改 `lua_battle_nav.cpp`。

[局部修改]

```text
server/native/lua_battle_nav/src/lua_battle_nav.cpp
```

它现在不只做静态 Cell 查询。先把文件头完整替换为当前真实职责：

```cpp
// 职责：在 Lua 与 Native Grid 导航之间转换参数、错误、Context 和 Path ownership。
// 边界：Server Runtime Binding；调用 MapRegistry/GridMap/GridPathfinder，不包含 Battle AI。
// 输入/输出：Lua map/profile/WorldPosition/unit -> userdata、WorldPosition 或 nil + error table。
// 生命周期：模块 table 属于当前 Lua State；Context/Path userdata 由该 State 的 GC 管理。
// 锁/yield：Registry 查找只持短锁；Native 查询同步执行，不 yield。
// 不负责：不执行 skynet.call，不保存 HP/技能，不允许 userdata 跨 Lua State 传递。
```

在现有 include 区增加：

```cpp
#include "agent_profile.h"
#include "grid_pathfinder.h"
#include "navigation_context.h"
#include "navigation_path.h"

#include <exception>
#include <memory>
#include <new>
#include <utility>
#include <vector>
```

现有匿名 namespace 中已有 `using battle_nav::MapRegistry;`。本节后续节选使用未加命名空间前缀的导航类型，因此在同一区域局部增加：

```cpp
using battle_nav::DynamicNavigationPolicy;
using battle_nav::NavigationAgent;
using battle_nav::NavigationAgentHandle;
```

这些是当前 Binding 实现的局部类型别名，不改变公开 API；如果选择每处写 `battle_nav::` 全限定名，就不要重复添加别名。

在匿名 namespace 内增加两个 userdata owner：

```cpp
constexpr const char* kContextMeta = "battle_nav.NavigationContext";
constexpr const char* kPathMeta = "battle_nav.Path";

struct LuaNavigationContext {
    std::unique_ptr<battle_nav::NavigationContext> context; // 当前 Lua State 独占。
    std::vector<battle_nav::AgentProfile> profiles;         // 创建后冻结，只读查找。
    bool closed = false;                                    // close/__gc 后拒绝调用。
};

struct LuaPath {
    battle_nav::Path path; // userdata 独占 immutable Path 结果。
};
```

增加通用 helper：

```cpp
// 校验 Context userdata 类型和生命周期；关闭后返回 nullptr，不转移所有权。
LuaNavigationContext* check_context(lua_State* L, int index) {
    auto* value = static_cast<LuaNavigationContext*>(
        luaL_checkudata(L, index, kContextMeta));
    if (value->closed || !value->context) {
        return nullptr;
    }
    return value;
}

// 校验 Path userdata 类型并返回 non-owning 指针；类型错误 luaL_error。
LuaPath* check_path(lua_State* L, int index) {
    return static_cast<LuaPath*>(luaL_checkudata(L, index, kPathMeta));
}

// 按稳定 profile_id 线性查找只读配置；不存在返回 nullptr。
const battle_nav::AgentProfile* find_profile(
    const LuaNavigationContext& owner,
    std::uint32_t profile_id) {
    for (const auto& profile : owner.profiles) {
        if (profile.id == profile_id) return &profile;
    }
    return nullptr;
}

// 从 Lua table 读取 int32 毫米 WorldPosition；字段缺失或越界 luaL_error。
battle_nav::WorldPosition world_position(lua_State* L, int index) {
    luaL_checktype(L, index, LUA_TTABLE);
    battle_nav::WorldPosition p;
    p.x_mm = int32_field(L, index, "x_mm");
    p.y_mm = int32_field(L, index, "y_mm");
    p.z_mm = int32_field(L, index, "z_mm");
    return p;
}

// 读取正 uint32 业务 ID；当前查询必须明确传入已有实体的 self 句柄。
// 越界通过 luaL_error 终止当前 Lua 调用，不允许 0 或负数变成有效 ID。
std::uint32_t uint32_arg(
    lua_State* L,
    int index,
    const char* name) {
    const lua_Integer raw = luaL_checkinteger(L, index);
    if (raw < 1 ||
        static_cast<std::uint64_t>(raw) >
            std::numeric_limits<std::uint32_t>::max()) {
        luaL_error(L, "%s outside uint32 business range", name);
    }
    return static_cast<std::uint32_t>(raw);
}

// 把一个毫米 WorldPosition 复制为新 Lua table；栈净增加 1。
void push_world_position(lua_State* L, const battle_nav::WorldPosition& p) {
    lua_newtable(L);
    lua_pushinteger(L, p.x_mm); lua_setfield(L, -2, "x_mm");
    lua_pushinteger(L, p.y_mm); lua_setfield(L, -2, "y_mm");
    lua_pushinteger(L, p.z_mm); lua_setfield(L, -2, "z_mm");
}

// 压入 nil,{code,message} 并返回 Lua 结果数量 2。
int push_nav_failure(
    lua_State* L,
    battle_nav::NavError error,
    const std::string& detail) {
    push_error(L, battle_nav::NavErrorName(error), detail);
    return 2;
}

// 把 Path move 进新 userdata 并挂 metatable；栈净增加 1。
void push_path(lua_State* L, battle_nav::Path path) {
    void* storage = lua_newuserdatauv(L, sizeof(LuaPath), 0);
    new (storage) LuaPath{std::move(path)};
    luaL_getmetatable(L, kPathMeta);
    lua_setmetatable(L, -2);
}
```

> 当前 Skynet v1.8.0 内置 PUC Lua 5.4.7，所以这里使用 `lua_newuserdatauv`。不要换成 Lua 5.1/5.2 的 userdata API 再假装 ABI 一致。

增加 Profile 解析函数。它在 `new_context` 时执行，不在每次 A* 热路径解析 Lua table：

```cpp
// 解析并验证一项 Lua Profile；返回按值快照，字段错误 luaL_error。
battle_nav::AgentProfile parse_profile(lua_State* L, int index) {
    const int abs = lua_absindex(L, index);
    luaL_checktype(L, abs, LUA_TTABLE);

    battle_nav::AgentProfile profile = battle_nav::MakeDefaultAgentProfile(1);

    lua_getfield(L, abs, "id");
    const lua_Integer raw_id = luaL_checkinteger(L, -1);
    lua_pop(L, 1);
    if (raw_id <= 0 ||
        static_cast<std::uint64_t>(raw_id) >
            std::numeric_limits<std::uint32_t>::max()) {
        luaL_error(L, "profile id must be positive uint32");
    }
    profile.id = static_cast<std::uint32_t>(raw_id);

    profile.radius_mm = int32_field(L, abs, "radius_mm");
    profile.max_step_mm = int32_field(L, abs, "max_step_mm");

    lua_getfield(L, abs, "max_slope_permille");
    const lua_Integer slope = luaL_checkinteger(L, -1);
    lua_pop(L, 1);
    if (slope < 0 || slope > std::numeric_limits<std::uint32_t>::max()) {
        luaL_error(L, "max_slope_permille outside uint32 range");
    }
    profile.max_slope_permille = static_cast<std::uint32_t>(slope);

    // area_cost_permille 使用 Lua key=0..255；未配置保持默认 1000。
    lua_getfield(L, abs, "area_cost_permille");
    if (lua_istable(L, -1)) {
        for (int area = 0; area < 256; ++area) {
            lua_geti(L, -1, area);
            if (!lua_isnil(L, -1)) {
                const lua_Integer cost = luaL_checkinteger(L, -1);
                if (cost < 0 || cost > 65535) {
                    luaL_error(L, "area cost outside uint16 range");
                }
                profile.area_cost_permille[area] =
                    static_cast<std::uint16_t>(cost);
            }
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1);

    lua_getfield(L, abs, "area_allowed");
    if (lua_istable(L, -1)) {
        for (int area = 0; area < 256; ++area) {
            lua_geti(L, -1, area);
            if (!lua_isnil(L, -1)) {
                profile.area_allowed[area] = lua_toboolean(L, -1) ? 1 : 0;
            }
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1);

    // NavResult 内含 std::string；先让它离开作用域再 luaL_error，
    // 避免 Lua longjmp 跳过 C++ 对象析构。
    const char* validation_error = nullptr;
    {
        const auto valid = battle_nav::ValidateAgentProfile(profile);
        if (!valid.ok()) {
            validation_error = battle_nav::NavErrorName(valid.error);
        }
    }
    if (validation_error != nullptr) {
        luaL_error(L, "invalid agent profile: %s", validation_error);
    }
    return profile;
}
```

创建 Context：

```cpp
// Lua battle_nav.new_context(map_id, map_version, profiles_array)
// 成功返回 context userdata；地图查找只持有第一课 Registry 短锁，不 yield。
int l_new_context(lua_State* L) {
    auto* maps = registry(L);
    const lua_Integer raw_map_id = luaL_checkinteger(L, 1);
    const lua_Integer raw_map_version = luaL_checkinteger(L, 2);
    if (raw_map_id <= 0 || raw_map_version <= 0 ||
        static_cast<std::uint64_t>(raw_map_id) > std::numeric_limits<std::uint32_t>::max() ||
        static_cast<std::uint64_t>(raw_map_version) > std::numeric_limits<std::uint32_t>::max()) {
        return luaL_error(L, "map_id/map_version must be positive uint32");
    }
    const auto map_id = static_cast<std::uint32_t>(raw_map_id);
    const auto map_version = static_cast<std::uint32_t>(raw_map_version);
    luaL_checktype(L, 3, LUA_TTABLE);

    // 先构造并挂 metatable。后续 luaL_check* 可能通过 Lua longjmp 报错；
    // userdata 已受 GC 管理，profiles/context 不会因跳过 C++ 栈析构而泄漏。
    void* storage = lua_newuserdatauv(L, sizeof(LuaNavigationContext), 0);
    auto* owner = new (storage) LuaNavigationContext;
    luaL_getmetatable(L, kContextMeta);
    lua_setmetatable(L, -2);

    try {
        // found 的 NavResult 含 std::string；把它限制在本作用域中，确保在调用任何
        // 可能 luaL_error 的 profile parser 之前完成正常 C++ 析构。
        {
            const auto found = maps->Find(map_id, map_version);
            if (!found.ok()) {
                return push_nav_failure(L, found.error, found.detail);
            }
            owner->context.reset(
                new battle_nav::NavigationContext(found.value));
        }

        const lua_Integer count = luaL_len(L, 3);
        if (count <= 0) {
            return luaL_error(L, "profiles must not be empty");
        }
        owner->profiles.reserve(static_cast<std::size_t>(count));
        for (lua_Integer i = 1; i <= count; ++i) {
            lua_geti(L, 3, i);
            const battle_nav::AgentProfile profile = parse_profile(L, -1);
            lua_pop(L, 1);
            for (const auto& existing : owner->profiles) {
                if (existing.id == profile.id) {
                    return luaL_error(
                        L, "duplicate profile id: %u", profile.id);
                }
            }
            owner->profiles.push_back(profile);
        }
        owner->closed = false;
    } catch (const std::exception& exception) {
        // C++ exception 不能穿越 Lua C ABI；userdata 保持有效并由 __gc 析构。
        return push_nav_failure(
            L, battle_nav::NavError::kInternalError, exception.what());
    }
    return 1;
}
```

当前课程先提供一个“其他实体都阻挡”的默认业务规则。它属于 Binding 适配层，底层 `DynamicOccupancy` 仍只保存事实；以后阵营、穿人或同格规则变化时替换这个 callback，不修改 A*：

```cpp
// 判断 agent 的整个目标 footprint 是否只包含自己。
// query 中所有指针只在本次同步调用期间有效；本函数不保存引用、不分配、不 yield。
bool ExclusiveDynamicRule(
    void*,
    const battle_nav::DynamicNavigationQuery& query) {
    if (query.agent == nullptr || query.agent->profile == nullptr ||
        query.occupancy == nullptr) {
        return false;
    }

    const battle_nav::NavigationAgentHandle self = query.agent->handle;
    return query.occupancy->ForEachFootprintCell(
        *query.agent->profile,
        query.target,
        [&](const battle_nav::GridPos& grid) {
            bool allowed = true;
            query.occupancy->ForEachOccupant(
                grid,
                [&](battle_nav::NavigationAgentHandle other) {
                    if (other != self) {
                        allowed = false;
                        return false;
                    }
                    return true;
                });
            return allowed;
        });
}
```

Context Path API：

```cpp
// Lua context:find_path：读取毫米世界坐标并同步查询；成功返回 Path userdata，失败 nil,error。
int l_context_find_path(lua_State* L) {
    LuaNavigationContext* owner = check_context(L, 1);
    if (owner == nullptr) {
        return push_nav_failure(L, battle_nav::NavError::kContextClosed, "context is closed");
    }
    const auto profile_id = uint32_arg(L, 2, "profile_id");
    const auto* profile = find_profile(*owner, profile_id);
    if (profile == nullptr) {
        return push_nav_failure(L, battle_nav::NavError::kInvalidAgent, "profile_id not found");
    }
    const auto start = world_position(L, 3);
    const auto end = world_position(L, 4);
    const auto self_id = uint32_arg(L, 5, "self_unit_id");

    try {
        const NavigationAgent agent{
            NavigationAgentHandle{self_id},
            profile};
        const DynamicNavigationPolicy dynamic_policy{
            nullptr,
            &ExclusiveDynamicRule};
        auto result = battle_nav::GridPathfinder::FindPath(
            *owner->context,
            agent,
            start,
            end,
            dynamic_policy);
        if (!result.ok()) {
            return push_nav_failure(L, result.error, result.detail);
        }
        push_path(L, std::move(result.value));
        return 1;
    } catch (const std::exception& exception) {
        return push_nav_failure(
            L, battle_nav::NavError::kInternalError, exception.what());
    }
}

// Lua context:find_path_to_range：搜索合法攻击位置；不忽略 target 占位，不 yield。
int l_context_find_path_to_range(lua_State* L) {
    LuaNavigationContext* owner = check_context(L, 1);
    if (owner == nullptr) {
        return push_nav_failure(L, battle_nav::NavError::kContextClosed, "context is closed");
    }
    const auto profile_id = uint32_arg(L, 2, "profile_id");
    const auto* profile = find_profile(*owner, profile_id);
    if (profile == nullptr) {
        return push_nav_failure(L, battle_nav::NavError::kInvalidAgent, "profile_id not found");
    }
    const auto start = world_position(L, 3);
    const auto target = world_position(L, 4);
    const lua_Integer raw_range = luaL_checkinteger(L, 5);
    const auto self_id = uint32_arg(L, 6, "self_unit_id");
    if (raw_range < 0 || raw_range > std::numeric_limits<std::uint32_t>::max()) {
        return luaL_error(L, "attack_range_mm outside uint32 range");
    }

    try {
        const NavigationAgent agent{
            NavigationAgentHandle{self_id},
            profile};
        const DynamicNavigationPolicy dynamic_policy{
            nullptr,
            &ExclusiveDynamicRule};
        auto result = battle_nav::GridPathfinder::FindPathToRange(
            *owner->context,
            agent,
            start,
            target,
            static_cast<std::uint32_t>(raw_range),
            dynamic_policy);
        if (!result.ok()) {
            return push_nav_failure(L, result.error, result.detail);
        }
        push_path(L, std::move(result.value));
        return 1;
    } catch (const std::exception& exception) {
        return push_nav_failure(
            L, battle_nav::NavError::kInternalError, exception.what());
    }
}
```

Occupancy API：

```cpp
// Lua context:place_unit：出生场景的薄包装；用同一个 MoveUnit 规则提交首个 footprint。
// 成功返回 Server 地表 Y 归一化的 WorldPosition；失败不改变原有动态事实。
int l_context_place_unit(lua_State* L) {
    LuaNavigationContext* owner = check_context(L, 1);
    if (owner == nullptr) {
        return push_nav_failure(L, battle_nav::NavError::kContextClosed, "context is closed");
    }
    const auto profile_id = uint32_arg(L, 2, "profile_id");
    const auto unit_id = uint32_arg(L, 3, "unit_id");
    const auto* profile = find_profile(*owner, profile_id);
    if (profile == nullptr) {
        return push_nav_failure(L, battle_nav::NavError::kInvalidAgent, "profile_id not found");
    }
    const auto world = world_position(L, 4);
    const auto grid = owner->context->map()->WorldToGrid(world);
    if (!grid.ok()) return push_nav_failure(L, grid.error, grid.detail);

    try {
        // 先准备返回位置；失败时尚未写入 Occupancy，不需要回滚已有 footprint。
        auto normalized = owner->context->map()->GridToWorldCenter(grid.value);
        if (!normalized.ok()) {
            return push_nav_failure(L, normalized.error, normalized.detail);
        }

        // 出生也是一次 from==to 的 MoveUnit：使用与真实移动相同的静态、
        // Grid/Cell 动态配置和业务回调，不能直接写 DynamicOccupancy 绕过冲突规则。
        const NavigationAgent agent{NavigationAgentHandle{unit_id}, profile};
        const DynamicNavigationPolicy dynamic_policy{
            nullptr, &ExclusiveDynamicRule};
        const auto placed = battle_nav::GridPathfinder::MoveUnit(
            *owner->context, agent, world, world, dynamic_policy);
        if (!placed.ok()) {
            return push_nav_failure(L, placed.error, placed.detail);
        }

        // Battle 正式位置保留输入 XZ；Y 来自 Server Grid 的权威地表高度。
        normalized.value.x_mm = world.x_mm;
        normalized.value.z_mm = world.z_mm;
        push_world_position(L, normalized.value);
        return 1;
    } catch (const std::exception& exception) {
        return push_nav_failure(
            L, battle_nav::NavError::kInternalError, exception.what());
    }
}

// Lua context:move_unit：复验当前子步并提交占位；成功返回 Server 地表 Y 归一的世界位置。
// from/to 为毫米世界坐标，to 的 X/Z 保留，Y 由目标 Cell 的 BMAP 高度决定。
// 失败返回 nil,error 且不写入新的动态事实；同步调用，不 I/O、不 yield。
int l_context_move_unit(lua_State* L) {
    LuaNavigationContext* owner = check_context(L, 1);
    if (owner == nullptr) {
        return push_nav_failure(L, battle_nav::NavError::kContextClosed, "context is closed");
    }
    const auto profile_id = uint32_arg(L, 2, "profile_id");
    const auto unit_id = uint32_arg(L, 3, "unit_id");
    const auto* profile = find_profile(*owner, profile_id);
    if (profile == nullptr) {
        return push_nav_failure(L, battle_nav::NavError::kInvalidAgent, "profile_id not found");
    }
    const auto from_world = world_position(L, 4);
    const auto to_world = world_position(L, 5);
    // 缓存路径生成后动态占位仍会变化。正式提交必须重新验证本次跨格，
    // 包括对角侧格；只检查终点 footprint 会允许动态 corner cutting。
    try {
        // 先准备权威返回位置；若归格失败，尚未提交 Occupancy。
        const auto to_grid = owner->context->map()->WorldToGrid(to_world);
        if (!to_grid.ok()) {
            return push_nav_failure(L, to_grid.error, to_grid.detail);
        }
        auto normalized = owner->context->map()->GridToWorldCenter(to_grid.value);
        if (!normalized.ok()) {
            return push_nav_failure(L, normalized.error, normalized.detail);
        }

        const NavigationAgent agent{
            NavigationAgentHandle{unit_id},
            profile};
        const DynamicNavigationPolicy dynamic_policy{
            nullptr,
            &ExclusiveDynamicRule};
        const auto moved = battle_nav::GridPathfinder::MoveUnit(
            *owner->context,
            agent,
            from_world,
            to_world,
            dynamic_policy);
        if (!moved.ok()) return push_nav_failure(L, moved.error, moved.detail);
        // 成功提交后，Battle 保存与静态地图一致的 Y，不使用折线端点的 Y 插值。
        normalized.value.x_mm = to_world.x_mm;
        normalized.value.z_mm = to_world.z_mm;
        push_world_position(L, normalized.value);
        return 1;
    } catch (const std::exception& exception) {
        return push_nav_failure(
            L, battle_nav::NavError::kInternalError, exception.what());
    }
}

// 返回当前 Context 静态地图 Cell 边长，单位毫米；只读、零分配、不 yield。
int l_context_cell_size_mm(lua_State* L) {
    LuaNavigationContext* owner = check_context(L, 1);
    if (owner == nullptr) {
        return push_nav_failure(L, battle_nav::NavError::kContextClosed, "context is closed");
    }
    lua_pushinteger(L, owner->context->map()->metadata().cell_size_mm);
    return 1;
}

// Lua context:release_unit：释放该 handle 当前记录的 footprint；成功返回 true。
int l_context_release_unit(lua_State* L) {
    LuaNavigationContext* owner = check_context(L, 1);
    if (owner == nullptr) {
        return push_nav_failure(L, battle_nav::NavError::kContextClosed, "context is closed");
    }
    const auto unit_id = uint32_arg(L, 2, "unit_id");
    try {
        const NavigationAgentHandle handle{unit_id};
        const auto released = owner->context->occupancy().Release(
            handle);
        if (!released.ok()) {
            return push_nav_failure(L, released.error, released.detail);
        }
        lua_pushboolean(L, 1);
        return 1;
    } catch (const std::exception& exception) {
        return push_nav_failure(
            L, battle_nav::NavError::kInternalError, exception.what());
    }
}
```

Path API：

```cpp
// 返回 Path 世界点数量；不分配、不修改 Path。
int l_path_count(lua_State* L) {
    auto* value = check_path(L, 1);
    lua_pushinteger(L, static_cast<lua_Integer>(value->path.count()));
    return 1;
}

// 返回 Lua 1-based index 对应的毫米 WorldPosition table；越界 luaL_error。
int l_path_world_point(lua_State* L) {
    auto* value = check_path(L, 1);
    const lua_Integer lua_index = luaL_checkinteger(L, 2);
    if (lua_index <= 0 ||
        static_cast<std::size_t>(lua_index) > value->path.count()) {
        return luaL_error(L, "path index out of range");
    }
    push_world_position(L, value->path.WorldPoint(
        static_cast<std::size_t>(lua_index - 1)));
    return 1;
}

// 返回 XZ 折线总长度，单位毫米。
int l_path_length_mm(lua_State* L) {
    auto* value = check_path(L, 1);
    lua_pushinteger(L, static_cast<lua_Integer>(value->path.length_mm()));
    return 1;
}

// 析构 placement-new LuaPath；仅由 Lua __gc 调用一次。
int l_path_gc(lua_State* L) {
    auto* value = check_path(L, 1);
    value->~LuaPath();
    return 0;
}

// 幂等关闭 Context 的大块 Native 内存；userdata 本体保留到 __gc。
int l_context_close(lua_State* L) {
    auto* owner = static_cast<LuaNavigationContext*>(
        luaL_checkudata(L, 1, kContextMeta));
    if (!owner->closed) {
        owner->context.reset();
        owner->closed = true;
    }
    return 0;
}

// __gc 必须真正调用 placement-new 对象析构函数；vector capacity 才会释放。
// 析构 placement-new owner，释放 profiles capacity 和尚未 close 的 Context。
int l_context_gc(lua_State* L) {
    auto* owner = static_cast<LuaNavigationContext*>(
        luaL_checkudata(L, 1, kContextMeta));
    owner->~LuaNavigationContext();
    return 0;
}
```

注册 metatable：

```cpp
// 在当前 Lua State 注册一次 Path metatable；栈净变化为 0。
void register_path_meta(lua_State* L) {
    if (luaL_newmetatable(L, kPathMeta)) {
        lua_pushcfunction(L, l_path_gc);
        lua_setfield(L, -2, "__gc");
        lua_newtable(L);
        lua_pushcfunction(L, l_path_count); lua_setfield(L, -2, "count");
        lua_pushcfunction(L, l_path_world_point); lua_setfield(L, -2, "world_point");
        lua_pushcfunction(L, l_path_length_mm); lua_setfield(L, -2, "length_mm");
        lua_setfield(L, -2, "__index");
    }
    lua_pop(L, 1);
}

// 在当前 Lua State 注册一次 Context metatable；栈净变化为 0。
void register_context_meta(lua_State* L) {
    if (luaL_newmetatable(L, kContextMeta)) {
        lua_pushcfunction(L, l_context_gc);
        lua_setfield(L, -2, "__gc");
        lua_newtable(L);
        lua_pushcfunction(L, l_context_find_path);
        lua_setfield(L, -2, "find_path");
        lua_pushcfunction(L, l_context_find_path_to_range);
        lua_setfield(L, -2, "find_path_to_range");
        lua_pushcfunction(L, l_context_place_unit);
        lua_setfield(L, -2, "place_unit");
        lua_pushcfunction(L, l_context_move_unit);
        lua_setfield(L, -2, "move_unit");
        lua_pushcfunction(L, l_context_release_unit);
        lua_setfield(L, -2, "release_unit");
        lua_pushcfunction(L, l_context_cell_size_mm);
        lua_setfield(L, -2, "cell_size_mm");
        lua_pushcfunction(L, l_context_close);
        lua_setfield(L, -2, "close");
        lua_setfield(L, -2, "__index");
    }
    lua_pop(L, 1);
}
```

最后修改现有 `luaopen_battle_nav()`：先注册两个 metatable，再把 `new_context` 放进模块 table。

修改前核心结构：

```cpp
extern "C" int luaopen_battle_nav(lua_State* L) {
    luaL_checkversion(L);
    lua_newtable(L);
    ...
}
```

修改后：

```cpp
extern "C" int luaopen_battle_nav(lua_State* L) {
    luaL_checkversion(L);

    register_context_meta(L);
    register_path_meta(L);
    lua_newtable(L);

    lua_pushlightuserdata(L, &MapRegistry::Instance());
    lua_pushcclosure(L, l_load_map, 1);
    lua_setfield(L, -2, "load_map");

    lua_pushlightuserdata(L, &MapRegistry::Instance());
    lua_pushcclosure(L, l_query_cell, 1);
    lua_setfield(L, -2, "query_cell");

    lua_pushlightuserdata(L, &MapRegistry::Instance());
    lua_pushcclosure(L, l_new_context, 1);
    lua_setfield(L, -2, "new_context");
    return 1;
}
```

### 13.6 每个需要导航的 Service 显式加载 Native 模块

第一课已经把 Binding 收敛为标准 Lua C Module：`battle_nav.so` 导出 `luaopen_battle_nav`。因此 BattleWorker 的 Service 入口或其私有业务模块直接写：

```lua
local battle_nav = require "battle_nav"
assert(type(battle_nav.new_context) == "function")
```

`require` 只在当前 Service 的 Lua State 中创建并缓存模块 table；C++ `MapRegistry::Instance()` 仍由同一进程的 Native Module 共享。每场战斗的 `NavigationContext` 由当前 BattleWorker 创建并独占，不能放进第一课 Query Service 再通过高频 `skynet.call` 代理。

第二课继续遵守目录身份：真正通过 `newservice()` 启动的 BattleWorker 入口放在 `service/`；被它 `require` 的战斗、AI 和导航协调模块放在 `lualib/`。

---

## 14. 先做 Lua/Native smoke，不急着上 Battle

在进入 AI 前，先用一个独立的 Skynet Service Lua State 证明这些 Native
调用可用；正式 BattleWorker 在第 18 节使用同一 Binding：

```text
new_context
-> place unit
-> find_path
-> path:world_point
-> move/release occupancy
```

这个检查要在真正的 Skynet Service Lua State 中运行；同进程的
`navigation_query` 必须先加载 BMAP。新建一次性 Smoke Service，
它直接使用第 13 节的 Binding，成功后输出 `NAVIGATION_SMOKE_OK`。

[新建文件]

```text
server/service/battle/navigation_smoke.lua
```

```lua
-- 职责：在单个 Skynet Lua State 中验证地图、Context、Path 与动态占位接线。
-- 边界：Server Test/Debug Service；不参与正式 Battle 或 Gateway 接入。
-- 输入/输出：已发布 Battle_1001 BMAP -> NAVIGATION_SMOKE_OK 或明确错误。
-- 生命周期：运行一次；查询 Service 先加载地图，本 Service 验证后退出。
-- 不负责：不计算 AI/伤害，不编写 Replay，不做性能测试。
local skynet = require "skynet"
local battle_nav = require "battle_nav"

-- 把 Binding 的 nil,{code,message} 合同变成可读的 Smoke 失败日志。
-- value/error 属于本次同步调用；成功返回原值，失败抛错终止此检查；不 I/O、不 yield。
local function require_nav(value, err)
    assert(value, err and (err.code .. ": " .. err.message) or "navigation call failed")
    return value
end

-- 等待同进程地图加载完成，然后在当前 Lua State 执行同步 Native 查询。
-- 无参数；成功输出 marker；启动阶段可 yield，导航调用本身不 yield。
skynet.start(function()
local query_service = skynet.newservice("navigation_query")
assert(skynet.call(query_service, "lua", "ready"))

local profiles = {
    {
        id = 1,
        radius_mm = 200,
        max_step_mm = 600,
        max_slope_permille = 1000,
        area_cost_permille = {
            [0] = 1000,
            [1] = 3000,
            [2] = 1000,
            [3] = 1500,
        },
    },
}

local context = require_nav(battle_nav.new_context(1001, 1, profiles))

local start = { x_mm = -11000, y_mm = 0, z_mm = 4000 }
local target = { x_mm = 11000, y_mm = 0, z_mm = -4000 }

start = require_nav(context:place_unit(1, 1001, start))
target = require_nav(context:place_unit(1, 2001, target))

local path = require_nav(context:find_path_to_range(
    1,
    start,
    target,
    900,
    1001))

print("PATH_OK count=", path:count(), " length_mm=", path:length_mm())
for i = 1, path:count() do
    local p = path:world_point(i)
    print(i, p.x_mm, p.y_mm, p.z_mm)
end

-- 同 Cell Move 验证首次占位仍可由同一 handle 提交；跨格移动由 Native 测试覆盖。
start = require_nav(context:move_unit(1, 1001, start, start))
require_nav(context:release_unit(1001))
require_nav(context:release_unit(2001))
context:close()
skynet.error("NAVIGATION_SMOKE_OK")
skynet.exit()
end)
```

正常配置的 `start` 指向 Gateway 的 `main`。为 Smoke 新建一个只覆盖入口的
配置文件；固定 Skynet 的 `include` 会沿用同目录基础配置中的搜索路径。

[新建文件]

```text
server/config/skynet_navigation_smoke.lua
```

```lua
-- 职责：为第 14 节 Lua/Native Smoke 选择独立启动入口。
-- 边界：Server Runtime Bootstrap 配置；复用基础 Skynet 配置。
-- 输入/输出：已有 Skynet/FlyWow/Native 构建 -> 单次 Smoke Service。
-- 生命周期：Skynet 启动时读取一次；不拥有地图或 Context。
-- 不负责：不运行正式 Gateway，不复制搜索路径或地图业务配置。
include "skynet.lua"
start = "battle/navigation_smoke"
```

从 `server/` 目录、在依赖与 Native Binding 已构建且 FlyWow submodule 已初始化后运行：

```bash
FLYWOW_ROOT="$PWD/third_party/skynet-flywow" \
  ./third_party/skynet/skynet config/skynet_navigation_smoke.lua
```

预期日志包含 `NAVIGATION_SMOKE_OK`。失败时先看 `NAV_QUERY_READY` 是否出现，
再看 `new_context` 的错误码；验证后从终端停止进程，避免遗留的查询 Service
占用调试端口。

这里使用的两个世界位置直接来自仓库 `Battle1001SceneBuilder.cs`：

```text
Team1_Spawn_01 = (-11m, 0.05m,  4m)
Team2_Spawn_01 = ( 11m, 0.05m, -4m)
```

正式毫米位置的 Y 最终应使用 Server Grid 对应高度，不依赖 Unity Marker 的 `0.05m` 显示偏移。

如果这里失败，先停在 Binding/Native 层。不要用 Battle AI 的更多状态掩盖基础接线问题。

---

# 第七部分：BattleWorker 出现后，才讨论 no-yield 核心

## 15. BattleWorker 的真实边界

本节第一次创建完整的 BattleWorker、Battle Core 和 Replay 链路。它们不是前置代码；只有第 13–14 节 Lua/Native smoke 已通过后，才按本节顺序新增这些文件。

本课最重要的 Skynet 结构不是“用了多少 Service”，而是 yield 边界：

```text
BattleMgr
  prepare snapshot
  -> skynet.call(worker, "simulate", snapshot)
     ^ 允许 yield

BattleWorker dispatch
  -> 创建/准备本地 NavigationContext
  -> battle_core.simulate(snapshot, context)
     ^ 从这里开始 no-yield
  -> return events
```

核心 `simulate()` 期间禁止：

```text
skynet.call
skynet.sleep
socket read/write
DB query
HTTP/RPC
等待墙钟时间
```

可以做：

```text
Lua table/array 访问
确定性整数计算
同步 Native C 调用
A*
DynamicOccupancy
事件 append
```

### 15.1 为什么 no-yield 不是“Skynet 不能 yield”

`BattleMgr` 调 Worker 本来就会 yield。第一课当前由 FlyWow Gateway 接收 TCP/WebSocket 请求、完成 framing 和 Protobuf 解码，再把已命名的业务 request 交给业务 Service；BattleMgr 可以在业务调度层执行 `skynet.call(BattleWorker, "lua", "simulate", snapshot)` 并 yield。接入层、BattleMgr 和 BattleWorker 的并发不会改变 `battle_core.simulate()` 的 no-yield 规则。`socketdriver + netpack` 仍是第一课保留的 Skynet 底层阅读材料，不是第二课需要重新实现的 Gateway。

约束只针对**已经开始推进某段 Battle 状态的核心临界区**：

```text
read battle state
-> AI
-> move
-> damage
-> emit ordered events
-> complete segment
```

如果中间 `skynet.call(DB)`：

```text
Unit A 已移动
-> yield
-> 其他消息进入同一 Service
-> 读到半更新 Battle
```

就必须引入复杂的状态锁/事务/版本检查。本课选择更简单的 owner model：核心推进期间不 yield。

### 15.2 在线模式与自动战斗怎样共用同一核心

第二课先真正运行自动模式：

```text
simulate(snapshot)
-> CPU 快速推进到结束
-> 完整 Event Log
```

核心从现在开始就把状态生命周期和驱动方式分开：

```lua
battle_core.create(snapshot, context)
battle_core.step(state, context)
battle_core.is_finished(state)
battle_core.finish(state)
```

因此第三课在线模式只增加外层驱动：

```text
收到 PlayerCommand
-> validate
-> 连续 step 若干 fixed tick
-> 输出 Event + 周期 Snapshot
-> 返回等待下一批命令
```

自动模式的 `simulate()` 只是连续调用同一组 `create/step/is_finished/finish`。第三课的在线驱动持有同一种 state，分段调用 `step()`，不会复制第二套 AI、导航、移动或攻击结算。

---

## 16. Battle 输入：Snapshot 只保存确定性需要的事实

本课自动战斗最小输入：

```lua
{
    battle_id = 70001,
    battle_version = 1,
    map_id = 1001,
    map_version = 1,
    seed = 123456,
    tick_ms = 50,
    max_logic_ms = 30000,

    profiles = {...},
    units = {...},
}
```

单位：

```lua
{
    id = 1001,
    camp = 1,
    agent_profile_id = 1,
    position = {x_mm=..., y_mm=..., z_mm=...},
    move_speed_mm_per_sec = 2500,
    attack_range_mm = 900,
    attack_damage = 10,
    attack_cooldown_ms = 1000,
    hp = 100,
}
```

`attack_damage/cooldown` 是最小普攻参数，不是第三课 Skill System。没有 SkillDefinition、Projectile、Cast Command。

第二课自动战斗示例在第 17 节固定资源预算：每场最多 128 个单位、2000 个 Tick、20000 条事件。输入超出单位/Tick 预算会在创建 state 时失败；运行中事件达到上限会终止本次模拟。第 18 节 Worker 负责关闭该场的 NavigationContext，并把失败返回调用方。这些数值是本课验收场景的边界，扩大规模前需要结合 Benchmark 与内存预算调整。

### 16.1 确定性规则现在就固定

```text
Unit iteration：按 unit.id 升序
Target tie：距离平方更小优先；相同则 target.id 更小
A* tie：f -> h -> node_index
Tick：固定 tick_ms
位置/HP/时间：整数
随机：本课 AI 不依赖随机；seed 仍写入输入和输出身份
Event：append 顺序就是权威逻辑顺序
```

相同：

```text
battle_version
map_id
map_version
snapshot/input
seed
```

必须得到相同逻辑 Event。

---

## 17. `battle_core.lua`：纯模拟核心不 require skynet

### 17.1 本文件解决的问题

它拥有一场自动战斗的**可变业务状态**：Unit HP、目标、当前 Path、攻击 CD、logic time。

它不拥有：

```text
Skynet Service address
Socket
DB connection
MapRegistry
Unity object
```

谁马上使用：`battle_worker.lua`。

完成后能观察：给定 snapshot + context，直接得到有序 Event Log。

### 17.2 学习导航

必须掌握：

```text
state ownership
fixed tick
目标选择稳定顺序
Path cache
repath trigger
整数移动预算
Occupancy commit
attack/death event order
```

必须精读：`choose_target()`、`ensure_attack_path()`、`advance_move()`、`step()`、`simulate()`。

可以略读：复制 table 的样板。

输入、输出和失败：

```text
输入：已经完成版本校验的 snapshot + battle-local context
输出：{result, end_logic_ms, events}
失败：非法 snapshot 直接 error，由 Worker 在边界收敛；NO_PATH 作为 AI 状态处理，不崩进程
```

内存/yield：Event Log 和单位状态会按 Battle 大小分配 Lua 内存；本节显式限制单位数、Tick 数和事件数，超限由 Worker 返回失败。核心不 yield。

理解自测：为什么 Path 失效只设置 `need_repath=true`，而不是每 Tick 都直接 A*？

### 17.3 真实调用者出现后，再增加 Native 按 Tick 推进接口

到这一节才第一次出现“Battle 每个 Tick 沿 Path 前进”的真实调用者，因此现在才扩展
Native API。第 14 节的 smoke 仍使用单步 `move_unit` 验证占位提交，不要求提前实现本节。

这个接口的职责边界是：

```text
Battle：计算当前生效速度和本 Tick 的整数毫米距离预算
Native：沿 Path 消耗预算、处理路点游标、拆分相邻 Cell 子步、逐步提交 Occupancy
Battle：根据 moving / reached / blocked 决定继续、攻击或安排重寻路
```

不要把 Buff、定身、加速叠加规则放进 `AgentProfile` 或 Native。`AgentProfile` 描述
“能不能经过”，`distance_mm` 表示 Battle 已经结算完成的“本 Tick 最多走多远”。

对以下已有文件做局部修改：

```text
server/native/grid_map/include/navigation_path.h
server/native/grid_map/include/grid_pathfinder.h
server/native/grid_map/src/grid_pathfinder.cpp
server/native/lua_battle_nav/src/lua_battle_nav.cpp
```

Native 内部为每个 Path userdata 保存一个跟随游标；路线点仍然不可变，游标只记录该实体
已经消费到哪一段。公开结果使用三种稳定状态：

```cpp
// Path 跟随状态只描述本次 Tick 的导航结果；业务层决定何时重寻路或攻击。
enum class PathAdvanceStatus : std::uint8_t {
    kMoving = 0, // 预算已经用完，Path 后面仍有路点。
    kReached = 1, // 已经消费到 Path 最后一个路点。
    kBlocked = 2, // 某个子步被最新静态/动态规则拒绝，位置停在最后一次成功提交处。
};

// 一个 Path userdata 独占一个 cursor；下标使用 C++ 0-based，不进入 Snapshot/Event。
struct PathFollowCursor {
    std::size_t next_point_index = 1;    // 下一个待追踪路点；count 表示已结束。
    std::uint64_t segment_progress_mm = 0; // 当前线段从固定起点累计消费的毫米数。
};

// Native 一次 fixed-tick 推进的结果；position 是已经成功提交的权威位置。
struct PathAdvanceResult {
    PathAdvanceStatus status = PathAdvanceStatus::kMoving;
    WorldPosition position{};
    std::uint32_t consumed_mm = 0; // 本次调用真正消费的距离预算。
    bool moved = false;            // X/Z 是否至少发生过一次成功变化。
};
```

在 `GridPathfinder` 增加公开入口。`MoveUnit()` 保留为 Native 内部复用的单步原语和
第 14 节 smoke 的诊断入口；Battle 核心不再自己循环调用它：

```cpp
// 沿同一实体独占的 Path 消耗一次 fixed-tick 距离预算。
// context/agent/path/policy：同步借用；cursor 由该 Path userdata 独占并在成功子步后更新。
// from：当前权威世界毫米位置；distance_mm：Battle 已结算的本 Tick 非负移动预算。
// 返回 moving/reached/blocked 和最后成功位置；blocked 是正常业务结果，不作为 NavError。
// 参数非法才返回失败；函数不执行 I/O、加锁或 yield，但会修改 cursor 和 Occupancy。
static NavResult<PathAdvanceResult> AdvancePath(
    NavigationContext& context,
    const NavigationAgent& agent,
    const Path& path,
    PathFollowCursor& cursor,
    const WorldPosition& from,
    std::uint32_t distance_mm,
    const DynamicNavigationPolicy& policy);
```

在 `grid_pathfinder.cpp` 的匿名 namespace 增加安全插值 helper。它使用固定线段起点和
累计进度；乘法无法由 `int64` 安全表示时显式失败，不允许坐标静默回绕：

```cpp
// 按 progress/length 在线段单轴上做整数插值；除法向 0 截断且每次都相对固定 origin。
// origin/target 是世界毫米坐标；progress 必须不大于 length，out 由调用方提供。
// 成功返回 true；乘法或最终 int32 坐标越界返回 false；不分配、不修改共享状态。
bool InterpolateAxis(
    std::int32_t origin,
    std::int32_t target,
    std::uint64_t progress,
    std::uint64_t length,
    std::int32_t* out) {
    if (out == nullptr || length == 0 || progress > length ||
        length > static_cast<std::uint64_t>(
            std::numeric_limits<std::int64_t>::max())) {
        return false;
    }

    const std::int64_t delta =
        static_cast<std::int64_t>(target) - origin;
    const std::uint64_t magnitude = static_cast<std::uint64_t>(
        delta < 0 ? -delta : delta);
    if (magnitude != 0 &&
        progress > static_cast<std::uint64_t>(
            std::numeric_limits<std::int64_t>::max()) / magnitude) {
        return false;
    }

    const std::int64_t signed_progress =
        static_cast<std::int64_t>(progress);
    const std::int64_t offset =
        delta * signed_progress / static_cast<std::int64_t>(length);
    const std::int64_t value = static_cast<std::int64_t>(origin) + offset;
    if (value < std::numeric_limits<std::int32_t>::min() ||
        value > std::numeric_limits<std::int32_t>::max()) {
        return false;
    }
    *out = static_cast<std::int32_t>(value);
    return true;
}
```

然后实现 `GridPathfinder::AdvancePath()`。下面是完整函数；它不重新 A*，只消费已经
生成的 Path：

```cpp
// 沿已有 Path 消耗一次 fixed-tick 距离预算；完整合同见头文件声明。
NavResult<PathAdvanceResult> GridPathfinder::AdvancePath(
    NavigationContext& context,
    const NavigationAgent& agent,
    const Path& path,
    PathFollowCursor& cursor,
    const WorldPosition& from,
    std::uint32_t distance_mm,
    const DynamicNavigationPolicy& policy) {
    if (agent.profile == nullptr || !agent.handle.valid() || path.count() == 0) {
        return NavResult<PathAdvanceResult>::Failure(
            NavError::kInvalidArgument,
            "AdvancePath requires valid agent and non-empty path");
    }
    if (cursor.next_point_index > path.count() ||
        (path.count() > 1 && cursor.next_point_index == 0)) {
        return NavResult<PathAdvanceResult>::Failure(
            NavError::kInvalidArgument, "Path cursor is outside path");
    }

    PathAdvanceResult output;
    output.position = from;
    if (cursor.next_point_index == path.count()) {
        output.status = PathAdvanceStatus::kReached;
        return NavResult<PathAdvanceResult>::Success(output);
    }

    const std::uint64_t cell_size_mm = context.map()->metadata().cell_size_mm;
    const std::uint64_t max_substep_mm =
        std::max<std::uint64_t>(1, cell_size_mm / 2);
    constexpr std::uint64_t kMaxSubstepsPerCall = 4096;
    if (distance_mm > max_substep_mm * kMaxSubstepsPerCall) {
        return NavResult<PathAdvanceResult>::Failure(
            NavError::kInvalidArgument,
            "distance budget exceeds bounded substep count");
    }

    std::uint64_t budget = distance_mm;
    std::uint64_t substeps = 0;
    while (budget > 0 && cursor.next_point_index < path.count()) {
        const WorldPosition& origin =
            path.WorldPoint(cursor.next_point_index - 1);
        const WorldPosition& goal =
            path.WorldPoint(cursor.next_point_index);
        const std::uint64_t length = SegmentLengthMm(origin, goal);
        if (length == 0) {
            ++cursor.next_point_index;
            cursor.segment_progress_mm = 0;
            continue;
        }
        if (cursor.segment_progress_mm >= length) {
            return NavResult<PathAdvanceResult>::Failure(
                NavError::kInternalError,
                "Path cursor progress is outside current segment");
        }
        if (++substeps > kMaxSubstepsPerCall) {
            return NavResult<PathAdvanceResult>::Failure(
                NavError::kInternalError,
                "AdvancePath exceeded validated substep count");
        }

        const std::uint64_t remaining =
            length - cursor.segment_progress_mm;
        const std::uint64_t step =
            std::min<std::uint64_t>(budget, std::min(remaining, max_substep_mm));
        const std::uint64_t progress = cursor.segment_progress_mm + step;

        WorldPosition candidate = output.position;
        if (progress == length) {
            candidate.x_mm = goal.x_mm;
            candidate.z_mm = goal.z_mm;
        } else if (!InterpolateAxis(
                       origin.x_mm, goal.x_mm, progress, length,
                       &candidate.x_mm) ||
                   !InterpolateAxis(
                       origin.z_mm, goal.z_mm, progress, length,
                       &candidate.z_mm)) {
            return NavResult<PathAdvanceResult>::Failure(
                NavError::kInvalidArgument,
                "Path segment interpolation exceeds integer range");
        }

        if (candidate.x_mm != output.position.x_mm ||
            candidate.z_mm != output.position.z_mm) {
            const auto moved = MoveUnit(
                context, agent, output.position, candidate, policy);
            if (!moved.ok()) {
                if (moved.error == NavError::kMoveBlocked ||
                    moved.error == NavError::kDynamicOccupied) {
                    output.status = PathAdvanceStatus::kBlocked;
                    return NavResult<PathAdvanceResult>::Success(output);
                }
                return NavResult<PathAdvanceResult>::Failure(
                    moved.error, moved.detail);
            }

            // MoveUnit 提交的是 Grid footprint；权威 Y 必须重新取目标 Cell 地表高度。
            const auto target_grid = context.map()->WorldToGrid(candidate);
            if (!target_grid.ok()) {
                return NavResult<PathAdvanceResult>::Failure(
                    target_grid.error, target_grid.detail);
            }
            const auto normalized = context.map()->GridToWorldCenter(target_grid.value);
            if (!normalized.ok()) {
                return NavResult<PathAdvanceResult>::Failure(
                    normalized.error, normalized.detail);
            }
            output.position = normalized.value;
            output.position.x_mm = candidate.x_mm;
            output.position.z_mm = candidate.z_mm;
            output.moved = true;
        }

        cursor.segment_progress_mm = progress;
        budget -= step;
        output.consumed_mm += static_cast<std::uint32_t>(step);
        if (progress == length) {
            ++cursor.next_point_index;
            cursor.segment_progress_mm = 0;
        }
    }

    output.status = cursor.next_point_index == path.count()
        ? PathAdvanceStatus::kReached
        : PathAdvanceStatus::kMoving;
    return NavResult<PathAdvanceResult>::Success(output);
}
```

最后在 `lua_battle_nav.cpp` 修改 `push_path()`，保证每次查询结果都有自己独立的 cursor：

```cpp
// 把 immutable Path 和该实体私有 cursor move 进新 userdata；栈净增加 1。
void push_path(lua_State* L, battle_nav::Path path) {
    void* storage = lua_newuserdatauv(L, sizeof(LuaPath), 0);
    new (storage) LuaPath{
        std::move(path),
        battle_nav::PathFollowCursor{}};
    luaL_getmetatable(L, kPathMeta);
    lua_setmetatable(L, -2);
}
```

再增加 request 整数字段读取和状态转换 helper：

```cpp
// 从 request table 读取 uint32；allow_zero=false 时 0 也属于合同错误。
// 字段缺失、类型错误或越界通过 luaL_error 终止当前 Lua 调用；栈净变化为 0。
std::uint32_t uint32_request_field(
    lua_State* L,
    int request_index,
    const char* name,
    bool allow_zero) {
    const int request = lua_absindex(L, request_index);
    lua_getfield(L, request, name);
    const lua_Integer raw = luaL_checkinteger(L, -1);
    lua_pop(L, 1);
    if (raw < (allow_zero ? 0 : 1) ||
        static_cast<std::uint64_t>(raw) >
            std::numeric_limits<std::uint32_t>::max()) {
        luaL_error(L, "field '%s' outside uint32 range", name);
    }
    return static_cast<std::uint32_t>(raw);
}

// 把 Native 状态映射为稳定 Lua 字符串；未知枚举视为 Native 编程错误。
const char* path_advance_status_name(
    battle_nav::PathAdvanceStatus status) {
    switch (status) {
    case battle_nav::PathAdvanceStatus::kMoving: return "moving";
    case battle_nav::PathAdvanceStatus::kReached: return "reached";
    case battle_nav::PathAdvanceStatus::kBlocked: return "blocked";
    }
    return nullptr;
}
```

`l_context_advance_path()` 的完整 Binding 如下。所有可能 `luaL_error` 的 request 解析都在
进入 Native 之前完成；一旦开始提交 Occupancy，就不再解析 Lua 输入：

```cpp
// Lua context:advance_path(request)：消费一个 fixed-tick 距离预算并返回最后成功位置。
// request 的 path/from_world 只在本次同步调用借用；函数不 I/O、不加锁、不 yield。
// blocked 是成功 result 状态；参数、生命周期或 Native 内部错误返回 nil,error。
int l_context_advance_path(lua_State* L) {
    LuaNavigationContext* owner = check_context(L, 1);
    if (owner == nullptr) {
        return push_nav_failure(
            L, battle_nav::NavError::kContextClosed, "context is closed");
    }
    luaL_checktype(L, 2, LUA_TTABLE);

    const std::uint32_t profile_id =
        uint32_request_field(L, 2, "profile_id", false);
    const std::uint32_t unit_id =
        uint32_request_field(L, 2, "unit_id", false);
    const std::uint32_t distance_mm =
        uint32_request_field(L, 2, "distance_mm", true);
    const auto* profile = find_profile(*owner, profile_id);
    if (profile == nullptr) {
        return push_nav_failure(
            L, battle_nav::NavError::kInvalidAgent,
            "profile_id not found");
    }

    lua_getfield(L, 2, "path");
    LuaPath* path_owner = check_path(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, 2, "from_world");
    const battle_nav::WorldPosition from_world = world_position(L, -1);
    lua_pop(L, 1);

    try {
        const NavigationAgent agent{
            NavigationAgentHandle{unit_id},
            profile};
        const DynamicNavigationPolicy dynamic_policy{
            nullptr,
            &ExclusiveDynamicRule};
        auto advanced = battle_nav::GridPathfinder::AdvancePath(
            *owner->context,
            agent,
            path_owner->path,
            path_owner->cursor,
            from_world,
            distance_mm,
            dynamic_policy);
        if (!advanced.ok()) {
            return push_nav_failure(
                L, advanced.error, advanced.detail);
        }

        const char* status = path_advance_status_name(advanced.value.status);
        if (status == nullptr) {
            return push_nav_failure(
                L, battle_nav::NavError::kInternalError,
                "unknown PathAdvanceStatus");
        }
        lua_newtable(L);
        lua_pushstring(L, status);
        lua_setfield(L, -2, "status");
        push_world_position(L, advanced.value.position);
        lua_setfield(L, -2, "position");
        lua_pushinteger(L, advanced.value.consumed_mm);
        lua_setfield(L, -2, "consumed_mm");
        lua_pushboolean(L, advanced.value.moved ? 1 : 0);
        lua_setfield(L, -2, "moved");
        return 1;
    } catch (const std::exception& exception) {
        return push_nav_failure(
            L, battle_nav::NavError::kInternalError, exception.what());
    }
}
```

在 `register_context_meta()` 中注册：

```cpp
lua_pushcfunction(L, l_context_advance_path);
lua_setfield(L, -2, "advance_path");
```

Binding 必须先完成全部 request 类型和范围校验，再进入 `AdvancePath()`；不要在已经提交
部分 Occupancy 后调用可能 `luaL_error` 的解析函数。`LuaPath.cursor` 只由这次同步调用
修改，不跨 yield，也不与其他实体共用同一个 Path userdata。

在 `navigation_test.cpp` 补三类用例，统一留到第 27 节运行完整 Native 回归：一个预算跨过
多个平滑路点时正确返回 `moving/reached`；途中出现动态阻挡时返回 `blocked` 并保留最后
成功位置；异常大预算在修改 Occupancy 前被拒绝。这里不为每个小改动重复执行整套测试。

实现遵守四个不变量：每个子步不超过半个 Cell；只有 `MoveUnit()` 成功才推进权威位置；
失败保留本 Tick 已成功提交的位置；插值始终相对固定线段起点和累计进度计算，避免低速
斜走时反复取整为原位置。还要给一次调用设置最大子步数，调用前先验证预算，避免极小
Cell 与异常速度组合制造无界循环。

Lua Binding 将 cursor 放在 `LuaPath` wrapper 中，不要求业务层保存 `path_index` 或
`segment_progress_mm`：

```cpp
struct LuaPath {
    battle_nav::Path path;               // immutable 路线点，由 userdata 独占。
    battle_nav::PathFollowCursor cursor; // 只服务这个实体的跟随进度，不跨 Lua State。
};
```

新增的方法使用 request/result record，避免继续扩大位置参数列表：

```lua
local advanced, err = context:advance_path({
    profile_id = self.agent_profile_id,
    unit_id = self.id,
    path = self.path,
    from_world = self.position,
    distance_mm = tick_distance_mm,
})

-- 成功：
-- {
--     status = "moving" | "reached" | "blocked",
--     position = {x_mm=..., y_mm=..., z_mm=...},
--     consumed_mm = 125,
--     moved = true,
-- }
--
-- 参数、类型或 Context 生命周期错误：nil,{code,message}
```

`blocked` 不是 C API 失败：本 Tick 可能已经走完前几个子步，结果中的 `position` 必须
保留最后成功位置。Battle 收到它后丢弃旧 Path，并按 cooldown 决定何时重新 A*。

### 17.4 创建 `battle_core.lua`

[新建文件]

```text
server/lualib/battle/battle_core.lua
```

```lua
-- 职责：执行一场地面自动战斗的确定性 fixed-tick 核心模拟。
-- 边界：Server Battle Core；不 require skynet，不访问网络/DB/墙钟时间。
-- 输入/输出：已验证 snapshot + battle-local NavigationContext -> ordered BattleEvent log。
-- 生命周期：state 只属于一次 simulate；Context 由 BattleWorker 创建并独占。
-- yield：核心函数禁止任何外部 yield；Native 导航调用为同步本地调用。
-- 不负责：不处理在线输入、额外战斗子系统或在线状态同步。
local M = {}

-- 本课自动 Battle 的资源预算；超限显式失败，不让完整 Event Log 无界增长。
-- 这些是教学场景上限，扩大规模前要结合 Benchmark 和部署内存预算重新设定。
local MAX_UNITS = 128
local MAX_TICKS = 2000
local MAX_EVENTS = 20000

-- 验证一个 Lua integer 的业务范围；失败立即终止本次 simulate，由 Worker 收敛错误。
local function integer_between(value, name, minimum, maximum)
    if math.type(value) ~= "integer" or value < minimum or value > maximum then
        error(string.format("%s must be integer in [%d,%d]", name, minimum, maximum))
    end
    return value
end

-- 验证 Battle 使用的 WorldPosition。坐标限制在正负 10^9mm，保证二维距离平方不溢出 int64。
local function checked_position(value, name)
    assert(type(value) == "table", name .. " must be table")
    return {
        x_mm = integer_between(value.x_mm, name .. ".x_mm", -1000000000, 1000000000),
        y_mm = integer_between(value.y_mm, name .. ".y_mm", -1000000000, 1000000000),
        z_mm = integer_between(value.z_mm, name .. ".z_mm", -1000000000, 1000000000),
    }
end

-- 整数平方距离；WorldPosition 全部使用毫米。
local function distance2(a, b)
    local dx = a.x_mm - b.x_mm
    local dz = a.z_mm - b.z_mm
    return dx * dx + dz * dz
end

-- 深度只复制一层 WorldPosition，避免事件与后续可变 unit.position 共用同一 table。
local function copy_position(p)
    return { x_mm = p.x_mm, y_mm = p.y_mm, z_mm = p.z_mm }
end

-- 按 unit.id 排序得到稳定迭代顺序；返回新数组，不修改输入 snapshot.units。
local function sorted_units(snapshot)
    local units = {}
    for i, source in ipairs(snapshot.units) do
        local prefix = string.format("units[%d]", i)
        units[i] = {
            id = integer_between(source.id, prefix .. ".id", 1, 0x7fffffff),
            camp = integer_between(source.camp, prefix .. ".camp", 1, 0x7fffffff),
            agent_profile_id = integer_between(
                source.agent_profile_id, prefix .. ".agent_profile_id", 1, 0x7fffffff),
            position = checked_position(source.position, prefix .. ".position"),
            move_speed_mm_per_sec = integer_between(
                source.move_speed_mm_per_sec,
                prefix .. ".move_speed_mm_per_sec", 1, 1000000),
            attack_range_mm = integer_between(
                source.attack_range_mm, prefix .. ".attack_range_mm", 0, 1000000000),
            attack_damage = integer_between(
                source.attack_damage, prefix .. ".attack_damage", 1, 0x7fffffff),
            attack_cooldown_ms = integer_between(
                source.attack_cooldown_ms,
                prefix .. ".attack_cooldown_ms", 1, 0x7fffffff),
            hp = integer_between(source.hp, prefix .. ".hp", 1, 0x7fffffff),
            max_hp = source.hp,
            target_id = nil,
            next_attack_ms = 0,
            path = nil,
            need_repath = true,
            repath_not_before_ms = 0,
            last_target_position = nil,
            move_numerator_remainder = 0,
        }
    end
    table.sort(units, function(a, b) return a.id < b.id end)
    return units
end

-- 构造 id->unit 查找表；只做直接查找，不依赖 pairs() 迭代顺序。
local function index_units(units)
    local by_id = {}
    for _, unit in ipairs(units) do
        assert(by_id[unit.id] == nil, "duplicate unit id")
        by_id[unit.id] = unit
    end
    return by_id
end

-- 把事件追加到唯一 Event Log；达到预算时失败，由 Worker 关闭 Context 并返回错误。
-- state/event 只归本场 Battle 所有；seq 由 append 顺序严格递增；不 I/O、不 yield。
local function emit(state, event)
    assert(#state.events < MAX_EVENTS, "battle event limit exceeded")
    state.next_event_seq = state.next_event_seq + 1
    event.seq = state.next_event_seq
    event.logic_ms = state.logic_ms
    state.events[#state.events + 1] = event
end

-- 从全部存活敌人中选最近目标；距离相同用更小 unit.id 稳定打破平局。
local function choose_target(state, self)
    local best = nil
    local best_dist2 = nil
    for _, candidate in ipairs(state.units) do
        if candidate.hp > 0 and candidate.camp ~= self.camp then
            local d2 = distance2(self.position, candidate.position)
            if best == nil or d2 < best_dist2 or
               (d2 == best_dist2 and candidate.id < best.id) then
                best = candidate
                best_dist2 = d2
            end
        end
    end
    return best
end

-- 判断攻击者当前位置是否已经进入目标攻击范围；使用整数平方距离。
local function in_attack_range(self, target)
    local range2 = self.attack_range_mm * self.attack_range_mm
    return distance2(self.position, target.position) <= range2
end

-- Path userdata 只在 replan 点读取一次，复制成 Lua 连续世界点供后续 Tick 使用。
local function copy_path_points(path)
    local points = {}
    for i = 1, path:count() do
        points[i] = path:world_point(i)
    end
    return points
end

-- 当前目标是否相对上次规划位置移动超过一个 Grid Cell 量级。
-- 阈值由 Context 的真实 cell_size_mm 提供，不复制一份地图配置。
local function target_moved_enough(self, target, threshold_mm)
    if self.last_target_position == nil then return true end
    return distance2(self.last_target_position, target.position) >=
        threshold_mm * threshold_mm
end

-- 停止现有移动并发送权威最终位置。只有确实持有 Path 时才发事件，避免空闲 Tick 刷屏。
local function stop_movement(state, self, reason)
    if self.path == nil then return end
    self.path = nil
    emit(state, {
        type = "MOVE_STOPPED",
        unit_id = self.id,
        reason = reason,
        position = copy_position(self.position),
    })
end

-- 只在明确 trigger + cooldown 允许时重新寻路；NO_PATH 会退避而不是每 Tick 重试。
local function ensure_attack_path(state, context, self, target)
    if in_attack_range(self, target) then
        stop_movement(state, self, "IN_ATTACK_RANGE")
        self.need_repath = false
        return true, false
    end

    if target_moved_enough(self, target, state.repath_distance_mm) then
        self.need_repath = true
    end
    if not self.need_repath or state.logic_ms < self.repath_not_before_ms then
        return self.path ~= nil, false
    end

    local path, err = context:find_path_to_range(
        self.agent_profile_id,
        self.position,
        target.position,
        self.attack_range_mm,
        self.id)
    if not path then
        -- 动态拥堵或暂时 NO_PATH 不应该在 50ms 后再次全图 A*。
        self.path = nil
        self.repath_not_before_ms = state.logic_ms + 300
        emit(state, {
            type = "MOVE_STOPPED",
            unit_id = self.id,
            reason = err and err.code or "NO_PATH",
            position = copy_position(self.position),
        })
        return false, false
    end

    self.path = path
    self.need_repath = false
    self.repath_not_before_ms = state.logic_ms + 300
    self.last_target_position = copy_position(target.position)

    emit(state, {
        type = "MOVE_PATH",
        unit_id = self.id,
        speed_mm_per_sec = self.move_speed_mm_per_sec,
        points = copy_path_points(path),
    })
    -- 新 Path 在当前 tick 边界发布；从下一个 tick 才消费移动预算，Replay 时间与 Server 对齐。
    return true, true
end

-- 当前 Tick 可移动的整数毫米预算；remainder 保留除以1000的余数，避免长期速度漂移。
local function movement_budget(self, tick_ms)
    local numerator = self.move_speed_mm_per_sec * tick_ms +
        self.move_numerator_remainder
    local whole = numerator // 1000
    self.move_numerator_remainder = numerator % 1000
    return whole
end

-- 沿缓存 Path 推进一个 fixed tick。
-- Battle 只提供已经结算完成的整数毫米预算；路点游标、插值、Grid 拆步和 Occupancy
-- 提交由 Native 完成。返回 true 表示位置实际变化；函数同步执行且不 yield。
local function advance_move(state, context, self)
    if self.path == nil then return false end

    local budget = movement_budget(self, state.tick_ms)
    local advanced, err = context:advance_path({
        profile_id = self.agent_profile_id,
        unit_id = self.id,
        path = self.path,
        from_world = self.position,
        distance_mm = budget,
    })
    if advanced == nil then
        error(string.format(
            "advance_path failed unit=%d code=%s message=%s",
            self.id,
            err and err.code or "UNKNOWN",
            err and err.message or ""))
    end

    -- position 是最后一个成功提交的权威位置；blocked 也可能已经移动了一段。
    self.position = advanced.position
    if advanced.status == "blocked" then
        self.need_repath = true
        stop_movement(state, self, "MOVE_BLOCKED")
    elseif advanced.status == "reached" then
        -- Path 可能因目标在规划后移动而先结束。若仍未进入攻击范围，
        -- 下一次 cooldown 允许时重新规划，不能永久站在旧终点。
        self.need_repath = true
        stop_movement(state, self, "PATH_END")
    elseif advanced.status ~= "moving" then
        error("advance_path returned unknown status")
    end
    return advanced.moved
end

-- 执行最小普通攻击；这是固定数值的 Battle rule，不是 Skill System。
local function try_attack(state, context, self, target)
    if not in_attack_range(self, target) then return false end
    -- 无论 CD 是否已经结束，进入攻击范围后都先停止客户端正在播放的旧 Path。
    stop_movement(state, self, "IN_ATTACK_RANGE")
    self.need_repath = false
    if state.logic_ms < self.next_attack_ms then return false end

    self.next_attack_ms = state.logic_ms + self.attack_cooldown_ms
    target.hp = math.max(0, target.hp - self.attack_damage)
    emit(state, {
        type = "ATTACK",
        attacker_id = self.id,
        target_id = target.id,
        damage = self.attack_damage,
        target_hp = target.hp,
    })

    if target.hp == 0 then
        local released, release_error = context:release_unit(target.id)
        if not released then
            error(string.format(
                "release_unit failed unit=%d code=%s message=%s",
                target.id,
                release_error and release_error.code or "UNKNOWN",
                release_error and release_error.message or ""))
        end
        emit(state, {
            type = "UNIT_DEAD",
            unit_id = target.id,
            killer_id = self.id,
            position = copy_position(target.position),
        })
    end
    return true
end

local function alive_camp_count(state)
    local camps = {}
    local count = 0
    for _, unit in ipairs(state.units) do
        if unit.hp > 0 and not camps[unit.camp] then
            camps[unit.camp] = true
            count = count + 1
        end
    end
    return count
end

-- 推进一个 fixed tick；函数内禁止调用任何可能 yield 的 Skynet/网络/DB API。
function M.step(state, context)
    assert(state.final_result == nil, "cannot step a finished battle")
    assert(state.logic_ms < state.max_logic_ms, "cannot step past max_logic_ms")
    -- state.logic_ms 表示本次结算完成的 tick 边界；本 step 内事件时间不会倒退。
    state.logic_ms = state.logic_ms + state.tick_ms
    for _, self in ipairs(state.units) do
        if self.hp > 0 then
            local target = self.target_id and state.by_id[self.target_id] or nil
            if target == nil or target.hp <= 0 then
                target = choose_target(state, self)
                local old_target = self.target_id
                self.target_id = target and target.id or nil
                self.need_repath = true
                if self.target_id ~= old_target then
                    -- 旧 Path 的业务前提已经消失；即使没有新目标，也要让 Replay 停止旧移动。
                    stop_movement(state, self, "TARGET_CHANGED")
                    emit(state, {
                        type = "TARGET_CHANGED",
                        unit_id = self.id,
                        target_id = self.target_id or 0,
                    })
                end
            end

            if target ~= nil and target.hp > 0 then
                if not try_attack(state, context, self, target) then
                    local _, new_path = ensure_attack_path(
                        state, context, self, target)
                    if not new_path then
                        advance_move(state, context, self)
                    end
                    -- 移动后再次检查，进入攻击范围的同 Tick 可以立即攻击。
                    if target.hp > 0 then
                        try_attack(state, context, self, target)
                    end
                end
            end
        end
    end
end

-- 从冻结 snapshot 创建模拟状态并完成初始占位；返回值由同一 Battle owner 持有。
-- 本函数不 yield。在线驱动创建一次后可分段调用 M.step；自动驱动交给 M.simulate。
function M.create(snapshot, context)
    assert(type(snapshot) == "table", "snapshot must be table")
    integer_between(snapshot.battle_id, "battle_id", 1, 0x7fffffff)
    integer_between(snapshot.battle_version, "battle_version", 1, 0x7fffffff)
    integer_between(snapshot.map_id, "map_id", 1, 0x7fffffff)
    integer_between(snapshot.map_version, "map_version", 1, 0x7fffffff)
    integer_between(snapshot.seed, "seed", -0x7fffffffffffffff, 0x7fffffffffffffff)
    integer_between(snapshot.tick_ms, "tick_ms", 1, 1000)
    integer_between(snapshot.max_logic_ms, "max_logic_ms", 1, 0x7fffffff)
    assert(snapshot.max_logic_ms % snapshot.tick_ms == 0,
        "max_logic_ms must be divisible by tick_ms")
    assert(snapshot.max_logic_ms // snapshot.tick_ms <= MAX_TICKS,
        "battle tick limit exceeded")
    assert(type(snapshot.units) == "table" and
        #snapshot.units > 0 and #snapshot.units <= MAX_UNITS,
        "units must be a non-empty array within limit")

    local units = sorted_units(snapshot)
    local cell_size_mm = integer_between(
        context:cell_size_mm(), "cell_size_mm", 1, 1000000000)
    local state = {
        battle_id = assert(snapshot.battle_id),
        battle_version = snapshot.battle_version,
        map_id = snapshot.map_id,
        map_version = snapshot.map_version,
        seed = snapshot.seed,
        tick_ms = snapshot.tick_ms,
        max_logic_ms = snapshot.max_logic_ms,
        -- 从真实 GridMap 读取，不把第一课 500mm Cell 硬编码进 Battle 逻辑。
        repath_distance_mm = cell_size_mm,
        logic_ms = 0,
        next_event_seq = 0,
        units = units,
        by_id = index_units(units),
        events = {},
    }

    for _, unit in ipairs(units) do
        local normalized_position, err = context:place_unit(
            unit.agent_profile_id,
            unit.id,
            unit.position)
        assert(normalized_position, string.format(
            "place_unit failed unit=%d code=%s message=%s",
            unit.id,
            err and err.code or "UNKNOWN",
            err and err.message or ""))
        -- XZ 保留 snapshot 的业务位置，Y 由 Server Grid 归一；后续 Spawn/Path 使用同一高度事实。
        unit.position = normalized_position
    end
    emit(state, {
        type = "BATTLE_BEGIN",
        battle_id = state.battle_id,
        battle_version = state.battle_version,
        map_id = state.map_id,
        map_version = state.map_version,
        seed = state.seed,
    })
    for _, unit in ipairs(state.units) do
        emit(state, {
            type = "UNIT_SPAWN",
            unit_id = unit.id,
            position = copy_position(unit.position),
        })
    end
    return state
end

-- 判断当前状态是否到达胜负或逻辑时限；只读、不分配、不 yield。
function M.is_finished(state)
    return state.logic_ms >= state.max_logic_ms or
        alive_camp_count(state) <= 1
end

-- 封存已经结束的 state 并生成一次 BATTLE_END；重复调用属于编程错误。
function M.finish(state)
    assert(M.is_finished(state), "cannot finish a running battle")
    assert(state.final_result == nil, "battle state already finished")
    local result = alive_camp_count(state) <= 1 and "FINISHED" or "TIMEOUT"
    state.final_result = result
    emit(state, { type = "BATTLE_END", result = result })
    return {
        battle_id = state.battle_id,
        battle_version = state.battle_version,
        map_id = state.map_id,
        map_version = state.map_version,
        seed = state.seed,
        result = result,
        end_logic_ms = state.logic_ms,
        events = state.events,
    }
end

-- 自动战斗入口：不等待墙钟时间，CPU 连续 fixed-tick 推进直到结束或达到逻辑时限。
function M.simulate(snapshot, context)
    local state = M.create(snapshot, context)

    while not M.is_finished(state) do
        M.step(state, context)
    end
    return M.finish(state)
end

return M
```

`advance_move` 每个 Tick 只调用一次 Native `advance_path`。一个平滑线段可以穿过
多个 Cell，Native 会把本 Tick 预算拆成多个不超过半格的子步，并在每个子步复用
`MoveUnit()`。业务层不保存 Grid 拆步参数，也不计算线段插值。途中动态规则拒绝时，
Native 返回最后成功提交的位置和 `blocked`；Battle 发出 `MOVE_STOPPED`，再按冷却
时间安排下一次 A*。

第二课尚未引入 Buff 系统，因此 `move_speed_mm_per_sec` 就是当前生效速度。第三课加入
加速、减速或定身后，由 Battle 属性规则先算出当前 Tick 的有效速度，再沿用同一个
整数预算公式；Native `advance_path` 不读取 Buff，也不自行决定单位应该有多快。

这里把 `state.logic_ms` 定义为“本次结算完成后的 tick 边界”。`M.step()` 先推进到下一个边界，再给本次事件统一打时间戳，所以同一 Event 数组中的 `logic_ms` 不会因单位顺序而倒退。新生成的 `MOVE_PATH` 在当前边界发布，从下一个 tick 才消费移动预算；这样 Unity 从 Path 事件到 `MOVE_STOPPED` 的播放时长与 Server 实际移动 tick 数一致。

### 17.5 为什么不能每 Tick 重算路径

假设：

```text
200 个单位
20 Tick/s
每 Tick 1 次 A*
```

就是：

```text
4000 次 A*/秒/战场
```

而目标多数 Tick 只移动几十到几百毫米，原 Path 仍然可用。

本课只在这些 trigger 设置 `need_repath`：

```text
target changed
target 相对规划位置移动 >= 1 Cell
当前 Path 被 DynamicOccupancy 阻挡
Path 走完但仍未进入 attack range
NO_PATH 的退避时间到期
```

并有：

```text
repath_not_before_ms
```

限制动态拥堵时的重试频率。

实际项目还可以增加：

```text
路径走廊局部失效
目标速度预测
群体 flow field
局部 steering
带过期时间的软 Claim（只作为偏好，不等于真实占用）
```

这些都应该由负载数据推动。整条 Path 的强预约需要处理过期、断线、死亡、换目标、动态技能和多单位死锁，容易造成“空气墙”式的僵硬表现，因此不作为本课默认方案。

---

## 18. `battle_worker.lua`：Context 的真正 owner

### 18.1 文件职责

Worker 接收纯数据 Snapshot，在自己的 Lua State 创建 Context，然后进入 no-yield 核心。

谁马上使用：`battle_mgr.lua`。

完成后能观察：一次 `skynet.call(worker,"simulate",snapshot)` 返回完整 Event Log。

### 18.2 学习导航

必须精读：Context 创建位置、`xpcall` 边界、simulate 前后哪里可以/不可以 yield。

可以略读：Skynet dispatch 样板。

输入、输出和失败：

```text
输入：可序列化 snapshot
输出：可序列化 result/event tables
失败：Native Context 创建失败或核心 assert -> Worker 返回明确错误 table
```

### 18.3 创建 Worker

[新建文件]

```text
server/service/battle/battle_worker.lua
```

```lua
-- 职责：拥有一个 Skynet Battle Worker Lua State，并为每次模拟创建 battle-local NavigationContext。
-- 边界：Skynet Service Adapter；dispatch 外层可以与 Skynet 交互，battle_core.simulate 内 no-yield。
-- 输入/输出：可序列化 snapshot -> 可序列化 battle result/event log。
-- 生命周期：Service 长驻；NavigationContext 只覆盖一次 simulate，结束后 close。
-- 不负责：不监听网络、不访问 DB、不在核心模拟中 skynet.call。
local skynet = require "skynet"
local battle_nav = require "battle_nav"
local battle_core = require "battle.battle_core"

-- 为一次可序列化 snapshot 创建并独占 Context，然后连续模拟到结束。
-- 成功返回 result；创建或核心失败返回 nil,error；核心阶段不 I/O、不 yield。
local function simulate(snapshot)
    local context, err = battle_nav.new_context(
        snapshot.map_id,
        snapshot.map_version,
        snapshot.profiles)
    if not context then
        return nil, {
            code = err and err.code or "CONTEXT_CREATE_FAILED",
            message = err and err.message or "new_context failed",
        }
    end

    -- 从这里进入核心状态推进。battle_core 不 require skynet，也没有外部 yield 点。
    local ok, result = xpcall(
        battle_core.simulate,
        debug.traceback,
        snapshot,
        context)

    context:close()
    if not ok then
        return nil, { code = "SIMULATE_FAILED", message = result }
    end
    return result
end

skynet.start(function()
    skynet.dispatch("lua", function(_, _, command, payload)
        if command == "simulate" then
            skynet.retpack(simulate(assert(payload)))
            return
        end
        error("unknown battle worker command: " .. tostring(command))
    end)
end)
```

`xpcall` 不是事务机制。它只是确保异常越过 core 边界时能够关闭 Context 并把错误变成可观察结果。核心已经修改过的局部 state 不会继续复用，因为整次 simulate 失败并结束。

---

## 19. `battle_mgr.lua`：允许 yield 的调度层

这里第一次真正出现：

```lua
skynet.call(worker, "lua", "simulate", snapshot)
```

它会 yield，这是允许的，因为 BattleMgr 自己不在持有“推进到一半”的 Battle Core 状态。

### 19.1 文件职责

管理固定 Worker Pool，并把一次自动 Battle 分配给某个 Worker。

本课不做复杂负载均衡。稳定 round-robin 足够验证 service/yield 边界；真实项目可以根据 queue depth/CPU/战场成本演进。

### 19.2 创建 Manager

[新建文件]

```text
server/service/battle/battle_mgr.lua
```

```lua
-- 职责：创建固定 BattleWorker Pool，并把独立 Battle snapshot 分发到 Worker。
-- 边界：Skynet Orchestration；这里允许 skynet.call/yield，不直接修改 Battle 内部状态。
-- 输入/输出：simulate(snapshot) -> Worker 返回的 result 或 error。
-- 生命周期：Manager/Worker 长驻；snapshot 在消息发送时序列化复制。
-- 不负责：不执行 AI/A*/伤害，不保存 NavigationContext userdata。
local skynet = require "skynet"

local workers = {}
local next_worker = 1

-- 按稳定 round-robin 选择 Worker；Manager 单 Service owner 修改 next_worker。
local function choose_worker()
    local worker = workers[next_worker]
    next_worker = next_worker % #workers + 1
    return worker
end

-- 把纯数据 snapshot 发给一个 Worker；本函数会在 skynet.call 处 yield。
local function simulate(snapshot)
    local worker = choose_worker()
    -- 这是明确允许的 yield 点。Manager 没有推进到一半的 Battle mutable state。
    return skynet.call(worker, "lua", "simulate", snapshot)
end

skynet.start(function()
    local count = tonumber(skynet.getenv("battle_worker_count")) or 2
    assert(count >= 1)
    for _ = 1, count do
        workers[#workers + 1] = skynet.newservice("battle/battle_worker")
    end

    skynet.dispatch("lua", function(_, _, command, payload)
        if command == "simulate" then
            skynet.retpack(simulate(assert(payload)))
            return
        end
        error("unknown battle manager command: " .. tostring(command))
    end)
end)
```

注意 Worker 的服务名取决于当前 Skynet `luaservice` 搜索路径。仓库已经提交第一课的 `server/config/skynet.lua`，其 `./service/?.lua` 与 `./lualib/?.lua` 可以继续解析第二课的 `battle/...` 子路径；第二课直接沿用这份进程配置，不为匹配课程阶段另造 `lesson2_server` 入口。

---

## 20. 一个真实的 Battle_1001 自动战斗输入

仓库真实场景出生点：

```text
Team1_Spawn_01 = (-11000, groundY,  4000) mm
Team2_Spawn_01 = ( 11000, groundY, -4000) mm
```

批量入口必须与加载 BMAP 的查询 Service 位于同一个 Skynet 进程：
`MapRegistry` 在进程内共享，Worker 的 `new_context` 才能找到已发布的地图。
本节先创建批量入口，随后用单独的启动配置选择它；正常 Gateway 启动入口不改。

[新建文件]

```text
server/service/battle/batch_runner.lua
```

```lua
-- 职责：构造一个固定 Battle_1001 自动战斗输入，调用 BattleMgr 并做 determinism smoke。
-- 边界：Skynet Test/Batch Entry；只服务课程验收，不包含战斗规则。
-- 输入/输出：固定 snapshot -> 两次模拟结果、确定性比较和可选 Replay 文件。
-- 生命周期：运行一次后可退出；不作为长期在线 Gateway。
-- 不负责：不实现 AI/A*，不定义其他战斗子系统类型。
local skynet = require "skynet"

-- 构造 Battle_1001 的冻结输入；每次调用返回全新的 table，避免两次 smoke 共享可变状态。
local function snapshot()
    return {
        battle_id = 70001,
        battle_version = 1,
        map_id = 1001,
        map_version = 1,
        seed = 123456,
        tick_ms = 50,
        max_logic_ms = 30000,
        profiles = {
            {
                id = 1,
                radius_mm = 200,
                max_step_mm = 600,
                max_slope_permille = 1000,
                area_cost_permille = {
                    [0] = 1000,
                    [1] = 3000,
                    [2] = 1000,
                    [3] = 1500,
                },
            },
        },
        units = {
            {
                id = 1001,
                camp = 1,
                agent_profile_id = 1,
                position = { x_mm = -11000, y_mm = 0, z_mm = 4000 },
                move_speed_mm_per_sec = 2500,
                attack_range_mm = 900,
                attack_damage = 20,
                attack_cooldown_ms = 1000,
                hp = 100,
            },
            {
                id = 2001,
                camp = 2,
                agent_profile_id = 1,
                position = { x_mm = 11000, y_mm = 0, z_mm = -4000 },
                move_speed_mm_per_sec = 2200,
                attack_range_mm = 900,
                attack_damage = 18,
                attack_cooldown_ms = 1100,
                hp = 100,
            },
        },
    }
end

-- 只比较逻辑字段，不用 tostring(table)；pairs/hash 地址顺序不能当 determinism 证据。
local function assert_same_result(a, b)
    assert(a.battle_id == b.battle_id)
    assert(a.battle_version == b.battle_version)
    assert(a.map_id == b.map_id and a.map_version == b.map_version)
    assert(a.seed == b.seed)
    assert(a.result == b.result)
    assert(a.end_logic_ms == b.end_logic_ms)
    assert(#a.events == #b.events)
    for i = 1, #a.events do
        local x = a.events[i]
        local y = b.events[i]
        assert(x.seq == i and y.seq == i)
        if i > 1 then
            assert(x.logic_ms >= a.events[i - 1].logic_ms)
            assert(y.logic_ms >= b.events[i - 1].logic_ms)
        end
        assert(x.seq == y.seq)
        assert(x.logic_ms == y.logic_ms)
        assert(x.type == y.type)
        assert(x.unit_id == y.unit_id)
        assert(x.attacker_id == y.attacker_id)
        assert(x.target_id == y.target_id)
        assert(x.killer_id == y.killer_id)
        assert(x.damage == y.damage)
        assert(x.target_hp == y.target_hp)
        assert(x.speed_mm_per_sec == y.speed_mm_per_sec)
        assert(x.reason == y.reason)
        assert(x.result == y.result)
        local xp, yp = x.position, y.position
        assert((xp == nil) == (yp == nil))
        if xp ~= nil then
            assert(xp.x_mm == yp.x_mm and xp.y_mm == yp.y_mm and xp.z_mm == yp.z_mm)
        end
        local xa, ya = x.points or {}, y.points or {}
        assert(#xa == #ya)
        for point = 1, #xa do
            assert(xa[point].x_mm == ya[point].x_mm)
            assert(xa[point].y_mm == ya[point].y_mm)
            assert(xa[point].z_mm == ya[point].z_mm)
        end
    end
end

skynet.start(function()
    -- Query Service 在同一进程完成地图加载；ready 返回后才创建 Worker，
    -- 避免 new_context 在空 MapRegistry 上查询。批量入口不启动 Gateway。
    local query_service = skynet.newservice("navigation_query")
    assert(skynet.call(query_service, "lua", "ready"))
    local mgr = skynet.newservice("battle/battle_mgr")
    local first, err1 = skynet.call(mgr, "lua", "simulate", snapshot())
    assert(first, err1 and err1.message)
    local second, err2 = skynet.call(mgr, "lua", "simulate", snapshot())
    assert(second, err2 and err2.message)
    assert_same_result(first, second)
    skynet.error("BATTLE_DETERMINISM_OK events=", #first.events,
                 " end_logic_ms=", first.end_logic_ms,
                 " result=", first.result)
end)
```

Skynet 已有的 `config/skynet.lua` 把 `start` 固定为正常 Gateway 的 `main`。
批量验收需要另一个入口，因此新增一个只覆盖启动 Service 的配置文件；
`include` 会沿用原配置中的 Lua 搜索路径和固定运行参数，不复制第二份配置。

[新建文件]

```text
server/config/skynet_batch.lua
```

```lua
-- 职责：为自动战斗验收选择 batch_runner，而不改正常 Gateway 的启动入口。
-- 边界：Server Runtime Bootstrap 配置；复用同目录的基础 Skynet 配置。
-- 输入/输出：基础配置和已构建的依赖 -> 单次 Battle 批量入口。
-- 生命周期：Skynet 进程启动时读取一次；不拥有 Battle/Map 状态。
-- 不负责：不加载 BMAP、不运行战斗核心、不创建第二套 Lua 搜索路径。
include "skynet.lua"
start = "battle/batch_runner"
```

`include` 的相对路径以当前配置文件所在目录为基准；固定 Skynet 的配置加载器
会先展开 `config/skynet_batch.lua`，再从同目录读取 `skynet.lua`。
从 `server/` 目录运行，先确认第一课依赖和 Native Binding 已构建，
再启动批量入口：

```bash
FLYWOW_ROOT="$PWD/third_party/skynet-flywow" \
  ./third_party/skynet/skynet config/skynet_batch.lua
```

正常克隆需要先初始化 FlyWow submodule。若本机调试使用独立 FlyWow 源码，
把 `FLYWOW_ROOT` 指向该已验证版本即可；不要改运行时 Lua 搜索路径来迁就工作区。
预期日志包含 `BATTLE_DETERMINISM_OK`。批量入口不监听 Gateway 端口；
进程仍有长驻 Query/Worker Service，验收后由终端停止它。

### 20.1 这里故意没有“等待 30 秒”

`max_logic_ms=30000` 表示最多模拟 30 秒**逻辑时间**。CPU 可能几十毫秒就完成整场。

不能写：

```lua
for ... do
    skynet.sleep(5) -- 等 50ms 墙钟
end
```

自动 Battle 的价值就是可以快速算完，再让 Unity 按逻辑时间慢慢播放。

---

# 第八部分：Battle Event 与 Unity Replay

## 21. Event 是逻辑事实，不是每 Tick 位置流

第二课至少输出：

```text
BATTLE_BEGIN
UNIT_SPAWN
TARGET_CHANGED
MOVE_PATH
MOVE_STOPPED
ATTACK
UNIT_DEAD
BATTLE_END
```

不会每 50ms 发一个 POSITION Event。移动表现由：

```text
MOVE_PATH
+ speed_mm_per_sec
+ 后续 MOVE_STOPPED / 新 MOVE_PATH
```

重建。

第三课在线模式会增加周期 Snapshot 用于加入/重连/校正；第二课 Replay 只是离线验证，不提前实现完整同步。

### 21.1 Replay 文件为什么先用 JSON

当前用途是：

```text
Server 自动模拟完
-> 把一次结果作为调试/演示 artifact
-> Unity 手工加载回放
```

它不是第三课线上协议，因此本课不扩展 Protobuf Battle Snapshot/Event Schema。JSON 可直接查看，便于核对 `logic_ms/seq/position/path`。

如果正式项目已有统一战报二进制/Protobuf 格式，接入时替换 Writer 即可；Battle Event 的 ownership 和逻辑时间不变。

---

## 22. `replay_writer.lua`：只序列化已经完成的逻辑结果

### 22.1 文件职责

把已完成的 Battle result 写成固定字段顺序 JSON。Writer 在核心 `simulate()` 返回之后执行，所以文件 I/O 不在 no-yield 核心。

### 22.2 学习导航

必须精读：为什么 Writer 位于 simulate 之后、为什么 Event 顺序按数组而不是按 map/pairs。

可以略读：JSON escape 的机械实现。

输入、输出和失败：

```text
输入：immutable-by-convention result table
输出：battle_replay.json
失败：非法 result 在打开文件前报 Lua error；I/O error 返回 nil,error，
      只影响 Replay artifact，不回滚已经完成的 Battle result
```

### 22.3 创建 Writer

[新建文件]

```text
server/lualib/battle/replay_writer.lua
```

```lua
-- 职责：把已经完成的 Battle result 以固定字段顺序写成可人工审查的 JSON Replay。
-- 边界：Server Debug/Replay Artifact；只在 battle_core.simulate 返回后执行 I/O。
-- 输入/输出：result table -> UTF-8 JSON 文件。
-- 生命周期：一次调用打开/关闭文件；不保存战斗状态。
-- 不负责：不参与权威结算，不在核心 simulate 内调用，不实现在线同步协议。
local M = {}

-- 把受控事件字符串编码为 JSON string；返回新字符串，不执行 I/O。
local function quote(s)
    s = tostring(s)
    s = s:gsub("\\", "\\\\")
         :gsub('"', '\\"')
         :gsub("\n", "\\n")
         :gsub("\r", "\\r")
         :gsub("\t", "\\t")
    return '"' .. s .. '"'
end

-- 编码一个毫米制 WorldPosition；nil 编码为 JSON null。
local function position(p)
    if p == nil then return "null" end
    return string.format(
        '{"x_mm":%d,"y_mm":%d,"z_mm":%d}',
        p.x_mm, p.y_mm, p.z_mm)
end

-- 按数组顺序编码 Path 世界点；不使用 pairs，保证 artifact 字段顺序稳定。
local function points(value)
    local out = { "[" }
    for i, p in ipairs(value or {}) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = position(p)
    end
    out[#out + 1] = "]"
    return table.concat(out)
end

-- 以固定字段顺序编码一个权威事件；缺失的可选字段使用稳定默认值。
local function event(e)
    -- 字段顺序固定，缺失的可选字段写成 null/0，避免不同 Lua hash 顺序影响 artifact。
    return table.concat({
        "{",
        '"seq":', tostring(e.seq), ",",
        '"logic_ms":', tostring(e.logic_ms), ",",
        '"type":', quote(e.type), ",",
        '"unit_id":', tostring(e.unit_id or 0), ",",
        '"target_id":', tostring(e.target_id or 0), ",",
        '"attacker_id":', tostring(e.attacker_id or 0), ",",
        '"killer_id":', tostring(e.killer_id or 0), ",",
        '"damage":', tostring(e.damage or 0), ",",
        '"target_hp":', tostring(e.target_hp or 0), ",",
        '"speed_mm_per_sec":', tostring(e.speed_mm_per_sec or 0), ",",
        '"reason":', quote(e.reason or ""), ",",
        '"result":', quote(e.result or ""), ",",
        '"position":', position(e.position), ",",
        '"points":', points(e.points),
        "}"
    })
end

-- 编码完整 Battle result；返回 UTF-8 JSON 字符串，不读写文件。
function M.encode(result)
    local out = {
        "{",
        '"battle_id":', tostring(result.battle_id), ",",
        '"battle_version":', tostring(result.battle_version), ",",
        '"map_id":', tostring(result.map_id), ",",
        '"map_version":', tostring(result.map_version), ",",
        '"seed":', tostring(result.seed), ",",
        '"result":', quote(result.result), ",",
        '"end_logic_ms":', tostring(result.end_logic_ms), ",",
        '"events":[',
    }
    for i, e in ipairs(result.events) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = event(e)
    end
    out[#out + 1] = "]}"
    return table.concat(out)
end

-- 把 result 写到 path。成功返回 true；打开、写入或关闭失败返回 nil,error。
-- result 必须是已完成且结构合法的 Battle 结果；编码错误会抛出 Lua error。
-- 本函数执行同步文件 I/O，只能在 battle_core.simulate 已经返回以后调用。
function M.write(path, result)
    -- 先编码再打开文件：若输入不完整导致编码失败，不会留下一个空 Replay 文件。
    local json = M.encode(result)
    local file, open_error = io.open(path, "wb")
    if file == nil then return nil, open_error end
    local ok, write_error = file:write(json, "\n")
    if ok == nil then
        file:close()
        return nil, write_error
    end
    local closed, close_error = file:close()
    if closed == nil then return nil, close_error end
    return true
end

return M
```

Writer 创建完成后，批量入口才有输出 Replay 的能力。对已有
`server/service/battle/batch_runner.lua` 做一次局部修改：

[局部修改]

文件顶部增加：

```lua
local replay_writer = require "battle.replay_writer"
```

两次 determinism 验证通过后增加：

```lua
local replay_ok, replay_error = replay_writer.write(
    "tmp/battle_replay.json", first)
assert(replay_ok, replay_error)
skynet.error("BATTLE_REPLAY_OK path=tmp/battle_replay.json")
```

本课约定从仓库的 `server/` 目录启动 Skynet，因此启动 batch 前先在该目录执行 `mkdir -p tmp`。Writer 的相对路径会落到 `server/tmp/battle_replay.json`；若本机启动脚本改变了工作目录，就把输出根目录作为启动配置显式传入，不能依赖碰巧的 cwd。

这个 I/O 在 `battle_core.simulate()` 已经结束之后，所以不违反核心 no-yield/无外部 I/O 边界。

---

## 23. Unity Replay：Client 只按 Server logic_ms 表现

第二课不需要漂亮角色。两个 Capsule/Cube 足够验证：

```text
Server Path 是否绕墙
移动时间是否符合 logic_ms
重新规划是否覆盖旧 Path
攻击/死亡是否按 Event 顺序发生
```

### 23.1 Unity 边界先解释清楚

本节的 Unity 代码属于：

```text
Client Runtime / Debug Presentation
```

`BattleReplayPlayer` 是 Play Mode 中的回放组件。它读取 Server 已经完成的逻辑结果，作用类似 Server 侧“按时间戳消费 append-only Event Log 的只读投影”：只更新显示对象，不重新执行业务规则。当前步骤需要它来验证 Server Path、攻击与死亡事件能被独立客户端完整观察。

进入 Play Mode 后，在 Unity 的 Hierarchy 观察 `ReplayUnit_*`，在 Scene/Game 视图观察移动，在 Console 观察攻击和结束日志。它属于 Client Runtime / Debug Presentation；BMAP 导出仍属于 Authoring/Asset，A* 与伤害仍属于 Server Runtime。

它不能：

```text
NavMeshAgent 重新寻路后覆盖 Server Path
客户端自己重新判定是否进入攻击范围
客户端重新计算伤害
客户端把本地碰撞结果写回 Server
```

`Transform.position` 使用米：

```text
server 2500mm -> Unity 2.5f
```

Y 也来自 Server Path point；不要重新从 Unity NavMesh Sample 一个不同高度替换它。

### 23.2 BattleReplayPlayer 学习导航

本文件解决的问题：按 Server `logic_ms` 顺序消费 Replay Event，并显示两支地面单位的移动、攻击和死亡。

必须精读：毫米转米、Server logic time 与 Unity elapsed time 的映射、MOVE_PATH 覆盖旧移动。

可以略读：`GameObject.CreatePrimitive`、Material/颜色等纯显示样板。

输入、输出和失败：

```text
输入：TextAsset JSON Replay
输出：Play Mode 中的单位移动/日志/死亡显示
失败：JSON 无效、seq 倒序、未知 unit 时明确 Debug.LogError
```

### 23.3 创建 Replay Player

[新建文件]

```text
unity/BattleNavigation/Assets/BattleNavigation/Client/BattleReplayPlayer.cs
```

```csharp
// 职责：按 Server 生成的 logic_ms/seq 回放第二课自动战斗事件。
// 边界：Unity Client Runtime Debug Presentation；Server Event 是权威输入。
// 输入/输出：Replay JSON TextAsset -> 基础几何体移动、攻击日志和死亡显示。
// 生命周期：Play Mode 开始时解析一次；Update 只推进表现时间。
// 不负责：不重新寻路、不计算命中/伤害、不把客户端位置回写 Server。
using System;
using System.Collections.Generic;
using UnityEngine;

namespace BattleNavigation.Client
{
    /// <summary>Replay 中一个 Server 世界坐标点；三个分量单位都是毫米。</summary>
    [Serializable]
    public sealed class ReplayPosition
    {
        public int x_mm; // Server 世界 X，毫米。
        public int y_mm; // Server 权威地表 Y，毫米。
        public int z_mm; // Server 世界 Z，毫米。
    }

    /// <summary>一个按 seq/logic_ms 排序的 Server 逻辑事件；字段名与 JSON 合同一致。</summary>
    [Serializable]
    public sealed class ReplayEvent
    {
        public int seq;                         // Battle 内从 1 开始严格递增。
        public int logic_ms;                    // fixed-tick 逻辑时间，毫秒。
        public string type;                     // 稳定事件类型名。
        public int unit_id;                     // 事件主体；0 表示该类型不使用。
        public int target_id;                   // 目标单位；0 表示无。
        public int attacker_id;                 // 攻击者；0 表示无。
        public int killer_id;                   // 击杀者；0 表示无。
        public int damage;                      // 本次权威伤害；非攻击事件为 0。
        public int target_hp;                   // 伤害结算后的权威 HP。
        public int speed_mm_per_sec;             // MOVE_PATH 表现速度，毫米/秒。
        public string reason;                   // 停止/失败原因；无则空串。
        public string result;                   // BATTLE_END 结果；无则空串。
        public ReplayPosition position;         // 权威事件位置；可为 null。
        public ReplayPosition[] points;         // MOVE_PATH 世界点；其他事件为空数组。
    }

    /// <summary>一次完整离线 Replay 的身份、结束状态和有序事件数组。</summary>
    [Serializable]
    public sealed class ReplayDocument
    {
        public int battle_id;          // 本次 Battle 身份。
        public int battle_version;     // Battle 规则版本。
        public int map_id;             // BMAP 地图 ID。
        public int map_version;        // BMAP 地图版本。
        public long seed;              // 本次确定性输入 seed。
        public string result;          // FINISHED 或 TIMEOUT。
        public int end_logic_ms;        // 模拟结束逻辑时间，毫秒。
        public ReplayEvent[] events;    // 按 seq 保存的 Server 事件。
    }

    /// <summary>
    /// 第二课离线 Replay 播放器。只消费 Server Event，不拥有任何权威战斗规则。
    /// </summary>
    public sealed class BattleReplayPlayer : MonoBehaviour
    {
        // Server 输出并复制到 Unity Assets 的 JSON Replay；只读。
        [SerializeField] private TextAsset replayJson;
        // 播放倍速；1=按 logic_ms 实时播放，2=两倍速。
        [SerializeField, Min(0.1f)] private float playbackSpeed = 1f;

        private sealed class ActiveMove
        {
            public ReplayPosition[] points = Array.Empty<ReplayPosition>(); // Server Path 世界点，毫米。
            public int nextPoint = 1;       // 下一个目标点数组下标。
            public float speedMeters = 0f;  // 由 Server mm/s 转换，纯表现参数。
        }

        // unit_id -> Client Runtime 显示对象；由本组件创建和销毁。
        private readonly Dictionary<int, GameObject> units =
            new Dictionary<int, GameObject>();
        // unit_id -> 当前表现 Path；新 MOVE_PATH 会覆盖旧值。
        private readonly Dictionary<int, ActiveMove> moves =
            new Dictionary<int, ActiveMove>();
        private ReplayDocument replay; // 当前只读 Replay 文档。
        private int nextEvent;          // 下一个尚未消费的 events 数组下标。
        private float logicMs;          // 客户端表现时间，毫秒；不回写 Server。

        /// <summary>解析 Replay 并重置播放状态；失败时抛出明确异常。</summary>
        private void Start()
        {
            if (replayJson == null)
                throw new InvalidOperationException("Replay JSON is not assigned");
            replay = JsonUtility.FromJson<ReplayDocument>(replayJson.text);
            if (replay == null || replay.events == null)
                throw new InvalidOperationException("Replay JSON is invalid");
            if (replay.end_logic_ms < 0)
                throw new InvalidOperationException("Replay end_logic_ms is invalid");
            if (replay.events.Length > 0 &&
                (replay.events[0] == null || replay.events[0].seq != 1))
                throw new InvalidOperationException("Replay event seq must start at 1");

            for (var i = 0; i < replay.events.Length; ++i)
            {
                if (replay.events[i] == null ||
                    replay.events[i].logic_ms < 0 ||
                    replay.events[i].logic_ms > replay.end_logic_ms ||
                    (i > 0 &&
                     (replay.events[i].seq != replay.events[i - 1].seq + 1 ||
                      replay.events[i].logic_ms < replay.events[i - 1].logic_ms)))
                    throw new InvalidOperationException("Replay event order is invalid");
            }
        }

        /// <summary>
        /// 把本帧切成事件前后的小段：先播放旧 Path 到事件时刻，再应用权威事件。
        /// 输入是 Unity 帧时长；只修改显示状态，不重新计算 Server 的移动或伤害。
        /// </summary>
        private void Update()
        {
            if (replay == null) return;
            var frameEndMs = Mathf.Min(
                logicMs + Time.deltaTime * 1000f * playbackSpeed,
                replay.end_logic_ms);
            while (nextEvent < replay.events.Length &&
                   replay.events[nextEvent].logic_ms <= frameEndMs)
            {
                // 同一帧可能跨过多个事件；旧 Path 只播放到下一事件的逻辑时间。
                var eventMs = replay.events[nextEvent].logic_ms;
                AdvanceMoves(Mathf.Max(0f, eventMs - logicMs) / 1000f);
                logicMs = eventMs;
                Apply(replay.events[nextEvent]);
                ++nextEvent;
            }
            // 新 MOVE_PATH 从自己的事件时刻以后才开始移动；BATTLE_END 后不再推进。
            AdvanceMoves(Mathf.Max(0f, frameEndMs - logicMs) / 1000f);
            logicMs = frameEndMs;
        }

        /// <summary>应用一个权威事件；只改变显示对象和本地表现状态。</summary>
        private void Apply(ReplayEvent value)
        {
            switch (value.type)
            {
                case "BATTLE_BEGIN":
                    Debug.Log($"Battle {replay.battle_id} begin seed={replay.seed}");
                    break;
                case "UNIT_SPAWN":
                    if (value.position != null)
                        GetOrCreate(value.unit_id, value.position);
                    break;
                case "MOVE_PATH":
                    BeginMove(value);
                    break;
                case "MOVE_STOPPED":
                    StopMove(value);
                    break;
                case "ATTACK":
                    Debug.Log($"ATTACK {value.attacker_id}->{value.target_id} " +
                              $"damage={value.damage} hp={value.target_hp}");
                    break;
                case "UNIT_DEAD":
                    Kill(value.unit_id);
                    break;
                case "TARGET_CHANGED":
                    break; // 第二课只保留调试语义，不要求视觉效果。
                case "BATTLE_END":
                    moves.Clear(); // 结束事件终止所有纯表现插值，不能越过权威结束时间继续移动。
                    Debug.Log($"Battle end result={value.result}");
                    break;
                default:
                    Debug.LogError("Unknown replay event: " + value.type);
                    break;
            }
        }

        /// <summary>开始/覆盖某单位当前移动表现；新 MOVE_PATH 权威替换旧表现路径。</summary>
        private void BeginMove(ReplayEvent value)
        {
            if (value.points == null || value.points.Length == 0) return;
            if (!units.TryGetValue(value.unit_id, out var unit))
            {
                Debug.LogError("MOVE_PATH for unknown unit: " + value.unit_id);
                return;
            }
            unit.transform.position = ToUnity(value.points[0]);
            moves[value.unit_id] = new ActiveMove
            {
                points = value.points,
                nextPoint = value.points.Length > 1 ? 1 : value.points.Length,
                speedMeters = value.speed_mm_per_sec / 1000f,
            };
        }

        /// <summary>按 MOVE_STOPPED 的 Server 最终位置停止本地插值。</summary>
        private void StopMove(ReplayEvent value)
        {
            moves.Remove(value.unit_id);
            if (value.position != null)
            {
                if (units.TryGetValue(value.unit_id, out var unit))
                    unit.transform.position = ToUnity(value.position);
                else
                    Debug.LogError("MOVE_STOPPED for unknown unit: " + value.unit_id);
            }
        }

        /// <summary>仅做路径折线插值；不会使用 NavMeshAgent 重新求路。</summary>
        private void AdvanceMoves(float deltaSeconds)
        {
            foreach (var pair in moves)
            {
                if (!units.TryGetValue(pair.Key, out var unit)) continue;
                var move = pair.Value;
                var remaining = move.speedMeters * deltaSeconds;
                while (remaining > 0f && move.nextPoint < move.points.Length)
                {
                    var target = ToUnity(move.points[move.nextPoint]);
                    var distance = Vector3.Distance(unit.transform.position, target);
                    if (distance <= remaining || distance <= 0.0001f)
                    {
                        unit.transform.position = target;
                        remaining -= distance;
                        ++move.nextPoint;
                    }
                    else
                    {
                        unit.transform.position = Vector3.MoveTowards(
                            unit.transform.position, target, remaining);
                        remaining = 0f;
                    }
                }
            }
        }

        /// <summary>返回现有显示对象；不存在时创建一个 Capsule 作为课程观察对象。</summary>
        private GameObject GetOrCreate(int unitId, ReplayPosition position)
        {
            if (units.TryGetValue(unitId, out var value)) return value;
            value = GameObject.CreatePrimitive(PrimitiveType.Capsule);
            value.name = "ReplayUnit_" + unitId;
            value.transform.position = ToUnity(position);
            units.Add(unitId, value);
            return value;
        }

        /// <summary>把 Server 整数毫米世界坐标转换为 Unity 世界米；轴保持 X/Y/Z 不变。</summary>
        private static Vector3 ToUnity(ReplayPosition p)
        {
            return new Vector3(p.x_mm / 1000f, p.y_mm / 1000f, p.z_mm / 1000f);
        }

        /// <summary>按 Server UNIT_DEAD 事件销毁显示对象；不在客户端重新判定 HP。</summary>
        private void Kill(int unitId)
        {
            moves.Remove(unitId);
            if (units.TryGetValue(unitId, out var value))
            {
                Destroy(value);
                units.Remove(unitId);
            }
            else
            {
                Debug.LogError("UNIT_DEAD for unknown unit: " + unitId);
            }
        }
    }
}
```

### 23.4 实际操作

Server 自动战斗生成：

```text
server/tmp/battle_replay.json
```

把它复制到：

```text
unity/BattleNavigation/Assets/BattleNavigation/Generated/Replay/battle_replay.json
```

`Generated/Replay` 是运行生成物目录，不要手工维护里面的逻辑内容。

在 `Battle_1001` Scene：

```text
Create Empty -> ReplayPlayer
Add Component -> BattleReplayPlayer
把 battle_replay.json 拖到 Replay Json
Play
```

观察：

```text
两单位使用 Server Path 绕开 CenterBlock/其他静态障碍
动态碰撞导致的重规划不会互相穿格
攻击发生在进入 attack range 后
UNIT_DEAD 后对象消失
整个播放耗时按 logic_ms，而不是 Server 模拟实际 CPU 耗时
```

常见误解：

```text
Unity Capsule 穿插视觉模型
```

先检查 Server Path world points 与 BMAP Overlay。如果 Server 点合法而显示模型体积比 AgentProfile 大，这是 Client presentation 参数不一致；不要让 NavMeshAgent 在客户端重新规划去“修正”权威路径。

### 23.5 补齐独立 Gateway 的自动战斗请求闭环

前面的 batch + JSON 文件已经证明同一场自动战斗可确定性地运行和回放；它仍需要人工启动 batch、搬运 Replay。现在增加一次性 `RunAutoBattle` 请求：Unity 只提交固定 `scenario_id=1001`，Server 构造 Snapshot、完整模拟并返回有界的权威事件。它是“一次请求返回整场结果”，不是第三课的实时指令或在线 Snapshot 流。

```text
Unity -> Gateway Process -> gateway_proxy -> cluster
      -> Battle Process / battle_dispatch
         -> BattleMgr -> BattleWorker -> battle_core
      <- RunAutoBattleResponse(ordered events)
Unity -> BattleReplayPlayer（只表现响应）
```

这里的 `battle_dispatch` 首次有两个真实调用目标：`QueryCell` 继续交给 `navigation_query`；`RunAutoBattle` 交给 BattleMgr。Gateway、Proxy 和固定协议编解码仍归 FlyWow；Battle Process 不持有客户端 fd，也不加载 Protobuf descriptor。Battle 请求在 Manager/Worker 处可以 yield，核心 `battle_core.simulate()` 仍然 no-yield。

本节按“协议 -> Server 场景与分发 -> Unity 客户端 -> 双进程验收”实施。先保留第 20、22 节的 batch/JSON 路径作为独立回归，不把它改成网络请求。

#### 23.5.1 给现有协议增加一个有界结果命令

为什么现在改协议：Gateway 的 command registry 从 `.proto` 自动生成，没有 `RunAutoBattle` RPC 时请求会在 Gateway 被拒绝。直接使用第一课的唯一协议源，新增消息和 command `1002`；`QueryCell=1001` 的字段号、语义和响应不变。客户端只传场景 ID，不能传 Snapshot、位置、HP 或战斗结算。完整 Event Log 通过强类型消息返回，JSON Writer 仍只做离线调试产物。

[局部修改] `shared/protocol/navigation_query.proto`（Server 协议源工作区）

文件头的职责/输入输出/不负责改为覆盖 `QueryCell` 和一次性自动战斗结果；`Envelope.command` 注释增加 `RunAutoBattle=1002`。原文件头五行完整替换为下面五行；保留原有 `syntax`、`package`、字段号与定义：

```proto
// 职责：定义 Gateway 查询静态地图和请求一次性自动战斗的共享消息合同。
// 边界：跨 Unity Client Runtime、FlyWow Gateway 和 Server Battle Process 的协议资产。
// 输入/输出：Envelope 承载 QueryCell 或 RunAutoBattle 请求及其强类型响应。
// 生命周期：由构建工具生成各端绑定并随同一协议版本发布；运行时只读。
// 不负责：不决定地图通行、战斗结果或客户端连接生命周期。
```

原 `Envelope` 中仅把 `command` 那行改为：

```proto
uint32 command = 2; // body 的业务消息类型；QueryCell=1001，RunAutoBattle=1002。
```

随后在原 `NavigationService` 后新增以下消息和 Service，不修改已有字段号：

```proto
// 一次性自动战斗只选择已发布 Server 场景；客户端不能提供权威单位状态。
message RunAutoBattleRequest {
  uint32 scenario_id = 1; // 本课固定 1001；其他值返回 BAD_SCENARIO。
}

// 一条已结算的 Server 逻辑事件；坐标与 Path 点均为毫米世界坐标。
message BattleEvent {
  uint32 seq = 1;                     // 本场从 1 连续递增。
  uint32 logic_ms = 2;                // fixed-tick 逻辑时间，非墙钟时间。
  string type = 3;                    // 第 21 节的稳定事件名。
  uint32 unit_id = 4;                 // 无主体的事件为 0。
  uint32 target_id = 5;               // 无目标的事件为 0。
  uint32 attacker_id = 6;             // 非攻击事件为 0。
  uint32 killer_id = 7;               // 非死亡事件为 0。
  uint32 damage = 8;                  // 非攻击事件为 0。
  uint32 target_hp = 9;               // 非攻击事件为 0。
  uint32 speed_mm_per_sec = 10;       // MOVE_PATH 的表现速度。
  string reason = 11;                 // 停止原因；无则空串。
  string result = 12;                 // BATTLE_END 结果；无则空串。
  WorldPosition position = 13;        // 有权威位置的事件才设置。
  repeated WorldPosition points = 14; // MOVE_PATH 的世界点；其余事件为空。
}

// 一个有界的一次性战斗结果；业务失败也返回本消息，不靠断线表达可预期拒绝。
message RunAutoBattleResponse {
  enum ResultCode {
    RESULT_UNSPECIFIED = 0;
    OK = 1;
    BAD_SCENARIO = 2;
    BUSY = 3;
    BATTLE_FAILED = 4;
    RESULT_TOO_LARGE = 5;
  }
  ResultCode result = 1;       // 稳定机器结果码；客户端不得按 message 分支。
  string message = 2;          // 限长诊断文字，不包含内部堆栈或敏感状态。
  uint32 battle_id = 3;        // 只在 OK 时有效。
  uint32 battle_version = 4;   // 只在 OK 时有效。
  uint32 map_id = 5;           // 只在 OK 时有效。
  uint32 map_version = 6;      // 只在 OK 时有效。
  sint64 seed = 7;             // 只在 OK 时有效。
  string battle_result = 8;    // FINISHED 或 TIMEOUT。
  uint32 end_logic_ms = 9;     // 本场最终逻辑时间。
  repeated BattleEvent events = 10; // 只在 OK 时返回，顺序即 seq 顺序。
}

// FlyWow 构建器从 RPC 注释生成同一 Envelope 下的新 command registry。
service BattleService {
  // command_id=1002；不复用 QueryCell 的 1001。
  rpc RunAutoBattle(RunAutoBattleRequest) returns (RunAutoBattleResponse);
}
```

这是增加命令的兼容扩展，当前 `Envelope.protocol_version=1` 不因新 RPC 自动加一；旧客户端仍只发 `1001`。不兼容字段变更才按协议版本策略升级。协议源及 Server descriptor/registry、Unity C# 生成物必须作为同一发布版本验证；双工作区先串行同步协议提交，不能手工把某工作区的 `.proto` 覆盖到另一侧。

[只读] `server/protocol/build_server_descriptor.sh`、`shared/protocol/build_unity_cs.ps1` 和 FlyWow 的 `tools/generate_gateway_registry.py`。它们已有固定生成职责，不复制或手改 registry。协议修改后，在 WSL 的仓库根目录执行 `./server/protocol/build_server_descriptor.sh`，在 `server/` 执行 `./scripts/linux/run_server.sh build`；同步同一协议提交到 Windows 工作区后执行 `shared/protocol/build_unity_cs.ps1`。核对生成的 registry 有 `[1001] QueryCell` 与 `[1002] RunAutoBattle`，而不是改 `server/lualib/protocol/navigation_registry.lua` 的生成代码。正式部署只消费已发布 descriptor、registry 和 Unity 生成类型。

#### 23.5.2 把固定 Snapshot 从 batch 入口提取为两个调用者共用的输入

为什么需要这个文件：batch 确定性测试和在线请求要运行同一个 `Battle_1001`，不能复制两份容易漂移的单位参数。该模块只构造新 Snapshot，不持有战斗状态；完成后两种入口的相同 ID 会得到相同初始输入。

[新建文件] `server/lualib/battle/scenario_1001.lua`

学习导航：精读 `make_snapshot()` 的输入白名单和每次新建 table；可以略读两单位的固定数值。输入是场景 ID；成功返回全新的纯数据 Snapshot，未知 ID 返回 `nil,code`；无 I/O、无 yield。

```lua
-- 职责：为 batch 与 Gateway 请求构造同一份 Battle_1001 自动战斗输入。
-- 边界：Server Battle Input；只返回纯 Lua 数据，不持有 Context 或客户端连接。
-- 输入/输出：scenario_id=1001 -> 全新 Snapshot；其他 ID -> nil,BAD_SCENARIO。
-- 生命周期：每次调用创建新 table；调用者独占返回值并交给 BattleMgr。
-- 不负责：不运行 AI/寻路、不相信客户端位置/HP、不读取 Unity Scene。
local M = {}

-- 只接受已发布固定场景；每次返回独立深层 table，避免 batch 两次运行共享状态。
-- scenario_id 是客户端可提供的唯一选择值；返回 Snapshot 或 nil,错误码；不 I/O、不 yield。
function M.make_snapshot(scenario_id)
    if scenario_id ~= 1001 then return nil, "BAD_SCENARIO" end
    return {
        battle_id = 70001,     -- 本次演示场景的战斗标识；不由客户端指定。
        battle_version = 1,    -- 战斗规则版本；参与确定性输入。
        map_id = 1001,         -- 使用第一课已发布的地图资产。
        map_version = 1,      -- 地图版本必须与加载资产一致。
        seed = 123456,         -- 固定随机种子，便于两种入口对照。
        tick_ms = 50,          -- 每个逻辑 Tick 的毫秒数。
        max_logic_ms = 30000, -- 防止战斗无限运行的逻辑时间上限。
        profiles = {
            {
                id = 1,
                radius_mm = 200,
                max_step_mm = 600,
                max_slope_permille = 1000,
                area_cost_permille = {
                    [0] = 1000, [1] = 3000, [2] = 1000, [3] = 1500,
                },
            },
        },
        units = {
            {
                id = 1001, camp = 1, agent_profile_id = 1,
                position = { x_mm = -11000, y_mm = 0, z_mm = 4000 },
                move_speed_mm_per_sec = 2500, attack_range_mm = 900,
                attack_damage = 20, attack_cooldown_ms = 1000, hp = 100,
            },
            {
                id = 2001, camp = 2, agent_profile_id = 1,
                position = { x_mm = 11000, y_mm = 0, z_mm = -4000 },
                move_speed_mm_per_sec = 2200, attack_range_mm = 900,
                attack_damage = 18, attack_cooldown_ms = 1100, hp = 100,
            },
        },
    }
end

return M
```

[局部修改] `server/service/battle/batch_runner.lua`：文件头改成“使用共享场景模块运行两次确定性验收”；在 `local skynet = require "skynet"` 后增加 `local scenario = require "battle.scenario_1001"`。删除第 20 节从 `-- 构造 Battle_1001 的冻结输入` 到对应 `local function snapshot() ... end` 的整段，原有两次调用改为：

```lua
local first, err1 = skynet.call(mgr, "lua", "simulate", assert(scenario.make_snapshot(1001)))
local second, err2 = skynet.call(mgr, "lua", "simulate", assert(scenario.make_snapshot(1001)))
```

其余确定性比较和第 22 节 Writer 调用保持不变。`scenario.make_snapshot()` 每次给 Worker 一个新 table；仍可运行 `skynet_batch.lua` 得到 `BATTLE_DETERMINISM_OK`。

#### 23.5.3 把 `battle_dispatch` 从 Query 别名改成真正的进程入口

为什么需要这个 Service：当前 `battle_main.lua` 直接把 `navigation_query` 注册为 `@battle_dispatch`，只能处理 `QueryCell`。现在有两个调用目标，分发 Service 只保存 Query/Manager 的 handle，不拥有地图、战斗 Context、客户端 fd 或 Protobuf。一个请求在 `skynet.call` 中 yield 时，其他请求可能进入同一 Service；`in_flight` 只由本 Service 的 Lua State 修改，限制同时等待的自动战斗数。

[局部修改] `server/service/battle/battle_mgr.lua`：在已有 `skynet.dispatch("lua", ...)` 内，`simulate` 分支前增加启动探针；不改 Worker 选择和模拟函数。

```lua
if command == "ready" then
    skynet.retpack(#workers > 0)
    return
end
```

[新建文件] `server/service/battle_dispatch.lua`

学习导航：精读 `configure()` 的 handle 注入、`dispatch_gateway()` 的命令分支、`run_auto_battle()` 的并发限额和结果大小限额；可以略读事件数组的机械计数。输入是 FlyWow 已解码的 request record；输出 `{ok=true,response=<对应 Proto table>}` 或不可恢复协议错误 record。预期业务拒绝使用 `RunAutoBattleResponse.result`，让客户端得到稳定错误码；远程进程故障仍由现有 `gateway_proxy` 转成 `REMOTE_UNAVAILABLE` 并关闭连接。跨 Service call 会 yield，核心状态始终归 Worker。

```lua
-- 职责：把 Battle Process 的已解码 Gateway 请求分给 Query 或自动战斗 Manager。
-- 边界：Server Runtime RPC Adapter；不持有 fd、frame、descriptor 或 Battle Context。
-- 输入/输出：gateway_dispatch request record -> 对应 Proto response record。
-- 生命周期：battle_main 注入两个 Service handle 后注册为 cluster 入口；每次请求独立协程。
-- 不负责：不实现 A*/AI/结算，不接受客户端 Snapshot，不编码 Protobuf。
local skynet = require "skynet"
local scenario = require "battle.scenario_1001"

local query_service = nil    -- 本进程 Query Service handle；只由 battle_main 注入一次。
local battle_mgr = nil       -- 本进程 Manager Service handle；只由 battle_main 注入一次。
local in_flight = 0          -- 当前正在等待完整自动战斗结果的请求数。
local MAX_IN_FLIGHT = 4      -- 超限返回 BUSY，不让 Worker 队列无界堆积。
local MAX_EVENTS = 100       -- 一次网络响应最多承载的 Event 数。
local MAX_POINTS = 200      -- 所有 MOVE_PATH 世界点的总数上限。
local MAX_TEXT_BYTES = 64   -- 单个事件字符串的 UTF-8 byte 上限。

local RESULT = {
    OK = 1, BAD_SCENARIO = 2, BUSY = 3,
    BATTLE_FAILED = 4, RESULT_TOO_LARGE = 5,
}

-- 注入本进程已有 Service handle；重复注入是启动配置错误，不能静默替换 owner。
-- handles 由 battle_main 拥有并传入；成功返回 true；不 I/O、不 yield。
local function configure(handles)
    assert(query_service == nil and battle_mgr == nil, "battle_dispatch already configured")
    assert(type(handles) == "table" and type(handles.query_service) == "number" and
        type(handles.battle_mgr) == "number", "invalid battle_dispatch handles")
    query_service = handles.query_service
    battle_mgr = handles.battle_mgr
    return true
end

-- 构造本 RPC 的业务失败响应；message 只用固定短文案，不返回内部错误堆栈。
-- code/message 均为当前调用的值；返回新 record；不 I/O、不 yield。
local function rejected(code, message)
    return { ok = true, response = { result = code, message = message } }
end

-- 保守限制结果规模；FlyWow 最终仍会按实际编码长度检查 65535-byte frame。
-- result 是 Worker 返回的纯 Lua 数据；成功返回 true，超限/结构错误返回 false。
-- 不加载 Proto descriptor、不编码网络消息；O(events + path points)，不 yield。
local function within_response_budget(result)
    if type(result) ~= "table" or type(result.events) ~= "table" or
        #result.events > MAX_EVENTS then return false end
    local point_count = 0
    for _, event in ipairs(result.events) do
        if type(event) ~= "table" or type(event.type) ~= "string" or
            #event.type > MAX_TEXT_BYTES or
            #(event.reason or "") > MAX_TEXT_BYTES or
            #(event.result or "") > MAX_TEXT_BYTES then return false end
        point_count = point_count + #(event.points or {})
        if point_count > MAX_POINTS then return false end
    end
    return true
end

-- 只把 scenario_id 当作客户端选择值；Snapshot/AI/HP 均由 Server 构造与结算。
-- request 来自已解码 Protobuf；返回 RunAutoBattleResponse；Manager call 会 yield。
-- 业务拒绝不占用 in_flight；call 异常或 Worker 失败在本边界收敛。
local function run_auto_battle(request)
    if type(request) ~= "table" or request.scenario_id ~= 1001 then
        return rejected(RESULT.BAD_SCENARIO, "unknown scenario_id")
    end
    if in_flight >= MAX_IN_FLIGHT then
        return rejected(RESULT.BUSY, "battle request limit reached")
    end
    local snapshot = assert(scenario.make_snapshot(request.scenario_id))
    in_flight = in_flight + 1
    local call_ok, result, worker_error = pcall(
        skynet.call, battle_mgr, "lua", "simulate", snapshot)
    in_flight = in_flight - 1
    if not call_ok or result == nil then
        -- 完整错误只进 Server 日志；客户端得到稳定码，不泄露 traceback。
        skynet.error("RunAutoBattle failed: ",
            tostring(call_ok and worker_error and worker_error.code or result))
        return rejected(RESULT.BATTLE_FAILED, "battle simulation failed")
    end
    if not within_response_budget(result) then
        return rejected(RESULT.RESULT_TOO_LARGE, "battle result exceeds demo response limit")
    end
    -- Event 字段名与 Proto BattleEvent 相同；只返回纯数据，不跨进程传 userdata。
    return { ok = true, response = {
        result = RESULT.OK,
        message = "",
        battle_id = result.battle_id,
        battle_version = result.battle_version,
        map_id = result.map_id,
        map_version = result.map_version,
        seed = result.seed,
        battle_result = result.result,
        end_logic_ms = result.end_logic_ms,
        events = result.events,
    } }
end

-- 保留 QueryCell 原路由，新增 Battle 分支；Gateway 已完成 command/请求类型校验。
-- payload 是本次 cluster 消息拥有的普通 table；返回 result record；Query/Manager call 会 yield。
local function dispatch_gateway(payload)
    assert(query_service ~= nil and battle_mgr ~= nil, "battle_dispatch is not ready")
    assert(type(payload) == "table", "gateway payload must be table")
    if payload.command == "QueryCell" and payload.command_id == 1001 then
        return skynet.call(query_service, "lua", "gateway_dispatch", payload)
    end
    if payload.command == "RunAutoBattle" and payload.command_id == 1002 then
        return run_auto_battle(payload.request)
    end
    return { ok = false, error = {
        code = "UNKNOWN_COMMAND", message = "command/id mismatch",
    } }
end

-- 安装固定签名的 Service dispatch；session/source 是 Skynet 元数据，不是业务参数。
-- configure/ready/gateway_dispatch 均由明确调用者使用；后者可能 yield。
skynet.start(function()
    skynet.dispatch("lua", function(_session, _source, command, payload)
        if command == "configure" then
            skynet.retpack(configure(payload))
        elseif command == "ready" then
            skynet.retpack(query_service ~= nil and battle_mgr ~= nil)
        elseif command == "gateway_dispatch" then
            skynet.retpack(dispatch_gateway(payload))
        else
            error("unknown battle_dispatch command: " .. tostring(command))
        end
    end)
end)
```

`MAX_EVENTS=100`、`MAX_POINTS=200` 与限长字符串是这个一次性 Demo RPC 的保守输出预算；第 17 节 Battle 核心自己的 20000 Event 上限仍用于保护模拟内存，两者不是同一个预算。完整结果超出网络预算时返回 `RESULT_TOO_LARGE`，仍可通过第 22 节离线 Writer 检查。FlyWow 在真正编码后再次检查 frame 长度；若以后放大场景，应先设计分页或战报资产拉取，不能悄悄提高 TCP uint16 上限。

[完整替换] `server/service/battle_main.lua`：它现在创建 Query、Manager、分发 Service 三个 owner，并只把分发 Service 注册为 `@battle_dispatch`。`gateway_main.lua` 与 `gateway_proxy.lua` 仍然只读，不需要了解 Battle 业务。

```lua
-- 职责：组装 Lesson 2 Map/Battle Process 的 Query、Manager 和跨进程分发入口。
-- 边界：Server Runtime Composition Root；只注入 handle，不持有网络 fd 或战斗 Context。
-- 输入/输出：进程配置与已构建 Service -> READY 的 battle_dispatch cluster 入口。
-- 生命周期：启动完成后本入口退出，子 Service 与 cluster listener 继续运行。
-- 不负责：不解析 Protobuf、不执行 AI/A*、不保存客户端连接。
local cluster = require "skynet.cluster"
local skynet = require "skynet"
local process = require "config.process_battle"

-- 先完成地图加载和 Worker Pool 初始化，再对外发布跨进程入口。
-- 无参数/返回；创建 Service、执行本地 call/cluster I/O，可 yield；失败阻止 READY。
skynet.start(function()
    local query_service = skynet.newservice("navigation_query")
    assert(skynet.call(query_service, "lua", "ready"))
    local mgr = skynet.newservice("battle/battle_mgr")
    assert(skynet.call(mgr, "lua", "ready"))
    local dispatcher = skynet.newservice("battle_dispatch")
    assert(skynet.call(dispatcher, "lua", "configure", {
        query_service = query_service,
        battle_mgr = mgr,
    }))
    assert(skynet.call(dispatcher, "lua", "ready"))

    -- 只有分发 Service READY 后才开放 cluster 名；QueryCell 与 Battle 共用此入口。
    cluster.open(process.cluster.local_listen, process.cluster.max_clients)
    cluster.register(process.cluster.service_name, dispatcher)
    skynet.error("LESSON2_BATTLE_PROCESS_READY node=", process.cluster.service_name,
                 " query=", skynet.address(query_service),
                 " manager=", skynet.address(mgr),
                 " dispatch=", skynet.address(dispatcher))
    skynet.exit()
end)
```

[局部修改] `server/scripts/linux/run_lesson2_processes.sh`：`doctor()` 对 `battle_dispatch.lua`、`battle/battle_mgr.lua`、`battle/battle_worker.lua` 增加存在性检查；保持原先 Battle 先 READY、Gateway 后监听和 Gateway 先停止的顺序。脚本不替你生成协议或运行 batch。`gateway_main.lua`、`gateway_proxy.lua`、`config/process_gateway.lua`、`config/process_battle.lua` 均为[只读]：它们现有的 handle 注入、远程节点名和端口无需改动。

在 `doctor()` 已有的 Service 文件检查后加入：

```bash
# 双进程 READY 现在依赖真正的 Battle 分发入口和已实现的 Manager/Worker。
[[ -f "$SERVER_ROOT/service/battle_dispatch.lua" &&
   -f "$SERVER_ROOT/service/battle/battle_mgr.lua" &&
   -f "$SERVER_ROOT/service/battle/battle_worker.lua" ]] ||
    fail "battle dispatch or worker services missing"
```

#### 23.5.4 Unity 从 Gateway 取回强类型结果

为什么现在才提取客户端传输：第一课只有 `QueryCell` 一个消费者，`ServerQueryClient` 自己拥有短连接即可。现在增加第二个命令，把共同的 Envelope/TCP framing 提取成一个小型 Client Runtime 连接对象；两个业务客户端仍各自解析自己的响应。不要让 Unity `NavMeshAgent` 或客户端状态覆盖返回的 Server 事件。

[新建文件] `unity/BattleNavigation/Assets/BattleNavigation/Scripts/Protocol/GatewayEnvelopeClient.cs`

学习导航：精读 2-byte big-endian length、request_id 回显校验、短读循环和 `Dispose`；可以略读 `TcpClient` 构造样板。输入是 command 与 Protobuf request；返回对应响应 Envelope，协议不匹配或连接失败抛异常。一个实例只由一个调用线程拥有，不共享并发请求。

```csharp
// 职责：为 QueryCell 和一次性自动战斗共用 TCP length + Envelope 往返。
// 边界：Unity Client Runtime Transport；不理解地图或战斗结果字段。
// 输入/输出：command + Protobuf request -> 同 request_id 的 response Envelope。
// 生命周期：实例独占 TcpClient/NetworkStream；调用方用 Dispose 关闭。
// 不负责：不重试、不连接池化、不在 Unity Update 同步阻塞。
using System;
using System.IO;
using System.Net.Sockets;
using System.Threading;
using Battle.Navigation.V1;
using BattleNavigation.Protocol;
using Google.Protobuf;

namespace BattleNavigation.Client
{
    /// <summary>一个调用线程独占的短连接 Envelope 客户端。</summary>
    public sealed class GatewayEnvelopeClient : IDisposable
    {
        private const uint ProtocolVersion = 1; // 与 Gateway 配置一致的 Envelope 版本。
        private static long nextRequestId;       // 当前客户端进程内单调增加，跨实例不重用。
        private readonly TcpClient client;       // 当前实例独占 Socket 生命周期。
        private readonly NetworkStream stream;   // 与 client 绑定的同步读写流。

        /// <summary>建立一个短连接；失败抛异常，调用方不得在每帧 Update 调用。</summary>
        /// <param name="host">Gateway 主机名或 IP，由当前场景显式配置。</param>
        /// <param name="port">Gateway TCP 端口，1..65535。</param>
        public GatewayEnvelopeClient(string host, int port)
        {
            client = new TcpClient();
            try
            {
                // 连接最多等待 3 秒；BattleRequester 会在后台 Task 中执行本同步客户端。
                if (!client.ConnectAsync(host, port).Wait(3000))
                    throw new TimeoutException("Gateway connect timeout");
                stream = client.GetStream();
                stream.ReadTimeout = 3000;
                stream.WriteTimeout = 3000;
            }
            catch
            {
                client.Dispose();
                throw;
            }
        }

        /// <summary>发送一个完整 Envelope 并验证一次对应响应；失败抛协议或 I/O 异常。</summary>
        /// <param name="command">生成 registry 中的 command ID，例如 1001/1002。</param>
        /// <param name="request">调用方拥有的 Protobuf request；本函数不保存它。</param>
        /// <returns>新解析的 response Envelope；body 的业务类型由调用方解析。</returns>
        public Envelope RoundTrip(uint command, IMessage request)
        {
            if (request == null) throw new ArgumentNullException(nameof(request));
            var requestId = checked((ulong)Interlocked.Increment(ref nextRequestId));
            var envelope = new Envelope
            {
                ProtocolVersion = ProtocolVersion,
                Command = command,
                RequestId = requestId,
                Body = ByteString.CopyFrom(request.ToByteArray()),
            };
            var frame = LengthFrame.Pack(envelope.ToByteArray());
            stream.Write(frame, 0, frame.Length);
            var response = Envelope.Parser.ParseFrom(ReadFrame());
            if (response.ProtocolVersion != ProtocolVersion ||
                response.Command != command || response.RequestId != requestId)
                throw new InvalidDataException("Gateway response identity mismatch");
            return response;
        }

        /// <summary>读一个 uint16 big-endian 长度帧；EOF、空帧或短读抛异常。</summary>
        /// <returns>新分配的完整 Envelope byte 数组，调用者拥有。</returns>
        private byte[] ReadFrame()
        {
            var header = ReadExact(LengthFrame.HeaderSize);
            var size = (header[0] << 8) | header[1];
            if (size < 1 || size > LengthFrame.MaxFrameBytes)
                throw new InvalidDataException("invalid Gateway frame length");
            return ReadExact(size);
        }

        /// <summary>循环读满指定字节数；TCP 短读不会被当成完整消息。</summary>
        /// <param name="count">本次需要的精确 byte 数，必须大于零。</param>
        /// <returns>新分配的精确长度缓冲区；EOF 抛 EndOfStreamException。</returns>
        private byte[] ReadExact(int count)
        {
            var bytes = new byte[count];
            var offset = 0;
            while (offset < count)
            {
                var read = stream.Read(bytes, offset, count - offset);
                if (read == 0) throw new EndOfStreamException();
                offset += read;
            }
            return bytes;
        }

        /// <summary>关闭本实例拥有的流与 Socket；不影响别的客户端实例。</summary>
        public void Dispose()
        {
            stream?.Dispose();
            client.Dispose();
        }
    }
}
```

[完整替换] `unity/BattleNavigation/Assets/BattleNavigation/Scripts/Protocol/ServerQueryClient.cs`：保留第一课的公开 `Query()` 签名，改为借用共同传输。第一课 Editor Window 不需要改调用代码；这一步完成后先回归 `QueryCell`。

```csharp
// 职责：把一次地图静态查询编码为 QueryCell 并解释其强类型响应。
// 边界：Unity Client Runtime/Editor Debug；传输由 GatewayEnvelopeClient 独占。
// 输入/输出：地图身份与毫米世界位置 -> QueryCellResponse。
// 生命周期：实例拥有一个 GatewayEnvelopeClient，由 Dispose 关闭。
// 不负责：不做高频寻路、不读 Battle Event、不在 Update 同步阻塞。
using System;
using Battle.Navigation.V1;

namespace BattleNavigation.Client
{
    /// <summary>第一课 QueryCell 调试调用面；第二课只复用传输，不改变查询合同。</summary>
    public sealed class ServerQueryClient : IDisposable
    {
        private const uint QueryCellCommand = 1001; // 与生成 registry 同步的 command ID。
        private readonly GatewayEnvelopeClient gateway; // 当前实例独占的短连接。

        /// <summary>连接指定 Gateway；连接失败抛异常。</summary>
        /// <param name="host">Gateway 主机名或 IP。</param>
        /// <param name="port">Gateway TCP 端口。</param>
        public ServerQueryClient(string host, int port)
        {
            gateway = new GatewayEnvelopeClient(host, port);
        }

        /// <summary>同步查询一个毫米世界点；协议/连接失败抛异常，业务错误留在 Result。</summary>
        /// <param name="mapId">已发布地图 ID。</param>
        /// <param name="mapVersion">期望的地图版本。</param>
        /// <param name="xMm">世界 X，毫米。</param>
        /// <param name="yMm">世界 Y，毫米。</param>
        /// <param name="zMm">世界 Z，毫米。</param>
        /// <returns>由当前请求新解析的 QueryCellResponse。</returns>
        public QueryCellResponse Query(uint mapId, uint mapVersion, long xMm, long yMm, long zMm)
        {
            var request = new QueryCellRequest
            {
                MapId = mapId,
                MapVersion = mapVersion,
                Position = new WorldPosition { XMm = xMm, YMm = yMm, ZMm = zMm },
            };
            var envelope = gateway.RoundTrip(QueryCellCommand, request);
            return QueryCellResponse.Parser.ParseFrom(envelope.Body);
        }

        /// <summary>关闭当前短连接；由 Editor 调用方 using 管理。</summary>
        public void Dispose() { gateway.Dispose(); }
    }
}
```

[新建文件] `unity/BattleNavigation/Assets/BattleNavigation/Scripts/Protocol/ServerBattleClient.cs`

学习导航：它只负责命令 `1002` 与强类型响应解析；不计算 AI、不播放事件。输入固定场景 ID，返回业务成功或失败的 `RunAutoBattleResponse`；网络/协议失败抛异常。实例独占短连接，不在 Unity 主线程每帧调用。

```csharp
// 职责：向独立 Gateway 发出一次固定场景自动战斗请求并读取强类型响应。
// 边界：Unity Client Runtime RPC Adapter；共享 GatewayEnvelopeClient 传输。
// 输入/输出：scenario_id -> RunAutoBattleResponse（包含业务 ResultCode）。
// 生命周期：实例拥有一个短连接，调用方用 Dispose 关闭。
// 不负责：不上传 Snapshot、不计算战斗、不执行 Unity 场景表现。
using System;
using Battle.Navigation.V1;

namespace BattleNavigation.Client
{
    /// <summary>一次性自动战斗请求适配器；业务拒绝仍返回可解析响应。</summary>
    public sealed class ServerBattleClient : IDisposable
    {
        private const uint RunAutoBattleCommand = 1002; // 与生成 registry 一致。
        private readonly GatewayEnvelopeClient gateway; // 当前请求独占的连接。

        /// <summary>连接目标 Gateway；连接失败抛异常。</summary>
        /// <param name="host">Gateway 主机名或 IP。</param>
        /// <param name="port">Gateway TCP 端口。</param>
        public ServerBattleClient(string host, int port)
        {
            gateway = new GatewayEnvelopeClient(host, port);
        }

        /// <summary>同步运行 Server 已发布场景；网络错误抛异常，业务错误读取 Result。</summary>
        /// <param name="scenarioId">本课只允许 1001；不能传单位位置或 HP。</param>
        /// <returns>新解析的完整一次性战斗响应。</returns>
        public RunAutoBattleResponse Run(uint scenarioId)
        {
            var request = new RunAutoBattleRequest { ScenarioId = scenarioId };
            var envelope = gateway.RoundTrip(RunAutoBattleCommand, request);
            return RunAutoBattleResponse.Parser.ParseFrom(envelope.Body);
        }

        /// <summary>关闭当前短连接。</summary>
        public void Dispose() { gateway.Dispose(); }
    }
}
```

[局部修改] `unity/BattleNavigation/Assets/BattleNavigation/Client/BattleReplayPlayer.cs`：第 23.3 节的 `ReplayDocument/ReplayEvent` 类型和 `Update/Apply/AdvanceMoves` 均保留。把原 `Start()` 完整替换为以下两个方法：有 TextAsset 时继续离线回放；未指定 TextAsset 时等待在线请求调用 `Play()`。`Play()` 每次先清掉旧显示对象，验证事件顺序后才发布新 Replay。

```csharp
/// <summary>有离线 TextAsset 时自动加载；联网模式留空并等待请求组件调用 Play。</summary>
private void Start()
{
    if (replayJson != null)
        Play(JsonUtility.FromJson<ReplayDocument>(replayJson.text));
}

/// <summary>从一份已完成的 Server 结果开始/重新开始纯表现回放。</summary>
/// <param name="document">调用方创建的 ReplayDocument；此后不得修改其事件数组。</param>
/// <exception cref="InvalidOperationException">文档为空、时间或 seq 顺序非法。</exception>
public void Play(ReplayDocument document)
{
    if (document == null || document.events == null)
        throw new InvalidOperationException("Replay document is invalid");
    if (document.end_logic_ms < 0 || document.events.Length == 0 ||
        document.events[0] == null || document.events[0].seq != 1)
        throw new InvalidOperationException("Replay event seq must start at 1");
    for (var i = 0; i < document.events.Length; ++i)
    {
        if (document.events[i] == null ||
            document.events[i].logic_ms < 0 ||
            document.events[i].logic_ms > document.end_logic_ms ||
            (i > 0 &&
             (document.events[i].seq != document.events[i - 1].seq + 1 ||
              document.events[i].logic_ms < document.events[i - 1].logic_ms)))
            throw new InvalidOperationException("Replay event order is invalid");
    }

    // 先验证、再清理旧表现；无论来自 JSON 还是网络，Server Event 都是唯一权威输入。
    foreach (var unit in units.Values) Destroy(unit);
    units.Clear();
    moves.Clear();
    replay = document;
    nextEvent = 0;
    logicMs = 0f;
}
```

为什么需要请求组件：`ServerBattleClient.Run()` 是同步 I/O，不能放在 Unity `Update()` 阻塞每一帧。这个组件只在 `Start` 发起一次后台请求，完成后回到 Unity 主线程把纯数据交给 `BattleReplayPlayer`。客户端只做字段转换，不计算寻路、伤害或死亡。

[新建文件] `unity/BattleNavigation/Assets/BattleNavigation/Client/BattleReplayRequester.cs`

学习导航：精读 `Start()` 的后台 I/O 与 Unity 主线程分界、`ConvertResult()` 的字段映射和 checked 缩窄；可以略读 `Task` 轮询样板。输入是固定场景 ID/Gateway 地址；成功后播放器收到新的 `ReplayDocument`，业务失败/连接失败明确写日志。组件不保存 Server 战斗状态，不发位置或 HP。

```csharp
// 职责：向独立 Gateway 请求一次 Battle_1001，并把权威结果交给现有 ReplayPlayer。
// 边界：Unity Client Runtime Adapter；后台线程只做同步 TCP/Protobuf，主线程只做场景表现。
// 输入/输出：Gateway 地址和 scenario_id -> BattleReplayPlayer.Play(ordered events)。
// 生命周期：Play Mode Start 发起一次请求；任务完成后不保留 Socket/Task 队列。
// 不负责：不提交 Snapshot、不重算 AI/Path/伤害、不实现第三课在线流同步。
using System;
using System.Collections;
using System.Threading.Tasks;
using Battle.Navigation.V1;
using UnityEngine;

namespace BattleNavigation.Client
{
    /// <summary>第二课一次性自动战斗的 Unity 请求入口。</summary>
    public sealed class BattleReplayRequester : MonoBehaviour
    {
        // 该地址对应独立 Gateway Process；本课本机双进程端口为 19011。
        [SerializeField] private string host = "127.0.0.1";
        [SerializeField, Min(1)] private int port = 19011;
        // 客户端只选择 Server 已发布场景，不上传任何单位事实。
        [SerializeField, Min(1)] private int scenarioId = 1001;
        // 与本组件同 Scene 的纯表现播放器；必须在 Inspector 显式注入。
        [SerializeField] private BattleReplayPlayer replayPlayer;

        /// <summary>后台执行一次阻塞短连接；完成后在 Unity 主线程开始回放。</summary>
        /// <returns>Unity 协程；失败写日志并结束，不修改现有 Replay。</returns>
        private IEnumerator Start()
        {
            if (replayPlayer == null)
            {
                Debug.LogError("BattleReplayPlayer is not assigned");
                yield break;
            }
            var selectedScenario = checked((uint)scenarioId);
            var selectedHost = host;
            var selectedPort = port;
            // Task 内不访问 Unity 对象；Socket 和 Proto 结果只由后台调用拥有。
            var pending = Task.Run(() =>
            {
                using (var client = new ServerBattleClient(selectedHost, selectedPort))
                    return client.Run(selectedScenario);
            });
            while (!pending.IsCompleted) yield return null;
            if (pending.IsCanceled)
            {
                Debug.LogError("RunAutoBattle request was canceled");
                yield break;
            }
            if (pending.IsFaulted)
            {
                Debug.LogException(pending.Exception.GetBaseException());
                yield break;
            }
            var response = pending.Result;
            if (response.Result != RunAutoBattleResponse.Types.ResultCode.Ok)
            {
                Debug.LogError($"RunAutoBattle rejected: {response.Result} {response.Message}");
                yield break;
            }
            try
            {
                replayPlayer.Play(ConvertResult(response));
                Debug.Log("BATTLE_GATEWAY_RESULT_LOADED events=" + response.Events.Count);
            }
            catch (Exception exception)
            {
                Debug.LogException(exception);
            }
        }

        /// <summary>只做 Proto Event 到现有 Replay DTO 的字段映射，保持 seq/logic_ms 原顺序。</summary>
        /// <param name="response">Server 已成功返回的只读强类型结果。</param>
        /// <returns>新分配的 ReplayDocument；字段越界抛 OverflowException。</returns>
        private static ReplayDocument ConvertResult(RunAutoBattleResponse response)
        {
            var events = new ReplayEvent[response.Events.Count];
            for (var i = 0; i < events.Length; ++i)
            {
                var source = response.Events[i];
                var points = new ReplayPosition[source.Points.Count];
                for (var point = 0; point < points.Length; ++point)
                    points[point] = ConvertPosition(source.Points[point]);
                events[i] = new ReplayEvent
                {
                    seq = checked((int)source.Seq),
                    logic_ms = checked((int)source.LogicMs),
                    type = source.Type,
                    unit_id = checked((int)source.UnitId),
                    target_id = checked((int)source.TargetId),
                    attacker_id = checked((int)source.AttackerId),
                    killer_id = checked((int)source.KillerId),
                    damage = checked((int)source.Damage),
                    target_hp = checked((int)source.TargetHp),
                    speed_mm_per_sec = checked((int)source.SpeedMmPerSec),
                    reason = source.Reason,
                    result = source.Result,
                    position = source.Position == null ? null : ConvertPosition(source.Position),
                    points = points,
                };
            }
            return new ReplayDocument
            {
                battle_id = checked((int)response.BattleId),
                battle_version = checked((int)response.BattleVersion),
                map_id = checked((int)response.MapId),
                map_version = checked((int)response.MapVersion),
                seed = response.Seed,
                result = response.BattleResult,
                end_logic_ms = checked((int)response.EndLogicMs),
                events = events,
            };
        }

        /// <summary>把 Proto 的 sint64 毫米坐标缩窄到当前 Unity Replay 的 int 范围。</summary>
        /// <param name="position">Server 世界坐标；只读，不保存引用。</param>
        /// <returns>新 ReplayPosition；越界抛 OverflowException，不静默截断。</returns>
        private static ReplayPosition ConvertPosition(WorldPosition position)
        {
            return new ReplayPosition
            {
                x_mm = checked((int)position.XMm),
                y_mm = checked((int)position.YMm),
                z_mm = checked((int)position.ZMm),
            };
        }
    }
}
```

#### 23.5.5 从双进程启动到 Unity 可观察结果

协议与 Server 文件按上述步骤完成后，再集中构建和验证一次；不要每修改一个教学文件就重跑整套测试。先停止旧进程，以免旧 descriptor/registry 与新协议混用。从 WSL 仓库根目录生成 descriptor，再进入 `server/` 构建并启动双进程：

```bash
cd ~/workspace/skynet-battle-navigation-commercial-learning/server
./scripts/linux/run_lesson2_processes.sh stop
./protocol/build_server_descriptor.sh
BUILD_TYPE=Debug ./scripts/linux/run_server.sh build
./scripts/linux/run_lesson2_processes.sh doctor
./scripts/linux/run_lesson2_processes.sh start
./scripts/linux/run_lesson2_processes.sh status
```

确认生成 registry 中 `1001=QueryCell`、`1002=RunAutoBattle`，Server descriptor 的 source hash 与修改后的 `.proto` 一致。协议源码在 WSL 编辑源完成并按本课程双工作区规则串行同步后，Windows 工作区运行 `shared/protocol/build_unity_cs.ps1`，让 Unity 重新导入生成的 `NavigationQuery.cs`；Unity `.meta` 由 Editor 生成并随变更提交，不手改生成 C#。同一发布提交需要包含 `.proto`、Server descriptor/registry、Unity 生成物和哈希校验文件。

先用第一课 `ServerQueryWindow` 指向双进程 Gateway 端口 `19011` 查询一个 Cell，确认原 `QueryCell` 没被 Battle 路由改坏。随后在 `Battle_1001` Scene：

```text
ReplayPlayer 对象：挂 BattleReplayPlayer，Replay Json 留空
同一对象：挂 BattleReplayRequester，把 Replay Player 指向上面的组件
Host=127.0.0.1，Port=19011，Scenario Id=1001
Play：看到 BATTLE_GATEWAY_RESULT_LOADED、单位移动、攻击和死亡
```

这次不运行 batch，也不复制 `battle_replay.json`；Unity 的一次请求必须实际经过独立 Gateway/cluster/BattleMgr/Worker。`BATTLE_GATEWAY_RESULT_LOADED` 只证明拿到并校验了完整响应，还要观察整个 Replay 到 `BATTLE_END`。再把 Inspector 的 `Scenario Id` 改为 `9999`：预期得到 `BAD_SCENARIO`，没有 Spawn/Replay；改回 1001 后重新成功。启动日志应先出现 `LESSON2_BATTLE_PROCESS_READY`，再出现 `LESSON2_GATEWAY_PROCESS_READY`；Gateway 仍不加载 BMAP，Battle Process 仍不拥有客户端 fd。

本课 `RunAutoBattle` 只接受固定场景，并限制同时请求数、Event 数、Path 点数及最终 Gateway frame。可预期业务拒绝返回 `ResultCode`；远程进程不可用时现有 Proxy 记录 `REMOTE_UNAVAILABLE`，Gateway 关闭该请求连接，Unity 显示连接异常。要支持大规模战报、分页/资产拉取、账号鉴权、限流、取消与 drain 编排，需要另立阶段；不能把当前一次性 65,535-byte 响应称为生产级实时同步。


---

# 第九部分：课程后段才整理稳定 Grid Navigation API

## 24. 现在已经有真实调用者，可以看见哪些概念是稳定的

到这里 `battle_core` 已经真正使用：

```text
WorldPosition
AgentProfile
NavigationContext
Path
find_path
find_path_to_range
DynamicOccupancy
```

而这些仍然是 Grid 实现细节：

```text
GridPos
NavCell
node_index
heap_index
parent_index
generation stamp
Binary Heap
Octile heuristic
Supercover
```

因此第二课末尾可以把调用面冻结成：

```lua
battle_nav.new_context(map_id, map_version, profiles)

context:find_path(profile_id, start_world, end_world, self_unit_id)
context:find_path_to_range(
    profile_id, start_world, target_world, attack_range_mm, self_unit_id)
context:place_unit(profile_id, unit_id, world_position) -- -> normalized WorldPosition
context:advance_path({
    profile_id = profile_id,
    unit_id = unit_id,
    path = path,
    from_world = current_world,
    distance_mm = tick_distance_mm,
}) -- -> {status,position,moved,consumed_mm}
context:release_unit(unit_id)
context:cell_size_mm()
context:close()

path:count()
path:world_point(i)
path:length_mm()
```

`advance_path` 是 Battle 每个 fixed Tick 调用一次的稳定移动入口；`distance_mm`
来自 Battle 的速度/Buff 规则。Native 内部仍以 `MoveUnit()` 作为单步验证和
Occupancy 提交原语，但不把逐 Cell 拆步责任暴露给 Lua Battle 代码。

这就是当前 BattleWorker 的稳定 **Grid Navigation API**。

### 24.1 本课明确不创建这些文件

```text
navigation_api.h 中的 INavigationBackend
GridNavigationBackend
DetourNavigationBackend
DetourQueryContext
NAVSRC
DNAV
nav_builder
```

原因不是“不考虑演进”，而是现在只有一个实现。可选 Lesson 4 第一次加入 Detour 时，再从：

```text
已工作的 Grid 调用者
+
真实 Detour 实现
```

中提取 Backend Contract，才能验证抽象到底是否正确。

### 24.2 本课保持现有目录

第二课继续使用 `server/native/grid_map/`，不安排目录迁移。当前验收对象是 A*、动态占位、BattleWorker 和 Replay 的行为链；路径重组不会增加可观察能力，还会把 include/CMake 机械改动混入功能调试。以后真的出现第二种导航实现时，再在可选第四课依据两个真实实现决定目录和 Backend 边界。

---

# 第十部分：完整构建、测试、调试和验收

## 25. 本课 Native CMake 最终应该包含什么

`grid_map_core` 最终源码：

```text
第一课已有：
src/bmap_reader.cpp
src/grid_map.cpp
src/map_registry.cpp
src/nav_result.cpp

第二课新增：
src/navigation_context.cpp
src/dynamic_occupancy.cpp
src/grid_pathfinder.cpp
```

Headers：

```text
第一课已有：
bmap_format.h
bmap_reader.h
grid_map.h
map_registry.h
nav_result.h

第二课新增：
agent_profile.h
navigation_path.h
navigation_agent.h
navigation_query.h
navigation_context.h
dynamic_occupancy.h
grid_pathfinder.h
```

测试：

```text
grid_map_test        第一课 regression
navigation_test      第二课 unified correctness/concurrency
navigation_benchmark 第二课 standalone benchmark
```

不要出现：

```text
lesson2_astar.cpp
lesson02_server.lua
lesson2_context.h
```

课程阶段不应该泄漏到产品源码命名。

---

## 26. GDB：真正值得下断点的位置

Native：

```bash
gdb --args build/grid_map/navigation_test
```

建议断点：

```gdb
break battle_nav::NavigationContext::BeginQuery
break battle_nav::GridPathfinder::FindPath
break battle_nav::DynamicOccupancy::Move
run
```

观察一个 Node 时重点看：

```text
node_index
node.generation
node.g_cost
node.parent_index
node.heap_index
node.state
context.query_generation
context.heap_size
```

如果路径随机变化，优先检查：

```text
heap tie-break
未初始化 generation
parent 被其他 Context 污染
unordered iteration 进入逻辑顺序
```

Lua：在 `battle_core.lua` 下断点观察：

```text
state.logic_ms
unit.target_id
unit.need_repath
unit.repath_not_before_ms
unit.path（每个实体独占的 Path userdata；跟随 cursor 由 Native wrapper 保存）
unit.position
```

但不要在调试时加入 `skynet.sleep()` 改变核心结构；调试工具不能偷偷改变被验证对象。

---

## 27. 第二课完整验收顺序

按执行链验收，不要只跑最后的 Battle：

```text
1. 第一课 grid_map_test 仍然通过
2. navigation_test -> ALL_TESTS_OK
3. static A* straight / wall / no path / corner cases
4. Agent clearance / slope / area cost
5. DynamicOccupancy 首次登记/move/release/conflict
6. 缓存 Path 跨格提交会拒绝新出现的动态切角阻挡
7. FindPathToRange 在 target center 被占用时返回合法攻击位置
8. smoothing 合法性复验
9. concurrency stress：shared immutable map + independent contexts
10. benchmark：80x60 / 256x256 / 512x512，记录条件
11. skynet_navigation_smoke.lua 启动同进程 Query，输出 NAVIGATION_SMOKE_OK
12. skynet_batch.lua 启动批量入口；BattleMgr -> Worker simulate
13. core simulate 期间没有 skynet.call/sleep/I/O
14. Path 结束会按 cooldown 重寻路，进入攻击范围会停止旧移动
15. 相同 snapshot/map/version/seed 两次 Event 一致
16. 输出 battle_replay.json
17. Unity 按 Server Path/Event 完成 Replay
18. 独立 Battle Process 的 battle_dispatch 同时路由 QueryCell 与 RunAutoBattle
19. Gateway Process 经 cluster 请求固定场景，返回有界的强类型 Event Log
20. Unity 不搬运 JSON，直接请求 1001 并完成 Replay；日志出现 BATTLE_GATEWAY_RESULT_LOADED
21. 请求未知场景返回 BAD_SCENARIO；原 QueryCell 仍可用
```

最终应该看到：

```text
ALL_TESTS_OK
NAVIGATION_SMOKE_OK
BATTLE_DETERMINISM_OK
BATTLE_REPLAY_OK
BATTLE_GATEWAY_RESULT_LOADED
```

---

## 28. 第二课面试复盘

完成这一课以后，应该能脱离代码回答下面的问题。

### 为什么 A* scratch 不能全局共享？

因为 Native Module 可以被多个 Skynet Service 从不同 OS Thread 同时进入。`g_cost/parent/open/closed/heap_index` 是查询级可变状态，全局共享会产生真实数据竞争和路径污染。静态 `GridMap` 能共享的前提是加载后 immutable。

### generation stamp 解决什么？

避免每次 Query 对全地图 Node Scratch 做 O(map_cells) 清零。每次查询递增 generation，只有实际访问的 Node 才懒初始化；回卷时才全量清 generation。

### 为什么 Binary Heap 保存 node_index？

Node 数据已经在 Context 的 dense array 中。Heap 只需要保存稳定 index；这样没有 per-node allocation，并且 `heap_index` 可以直接支持 decrease-key。

### 8-way 为什么必须防 corner cutting？

对角目标 Cell 自己可走并不代表单位可以穿过两个正交障碍的夹角。对角移动必须同时验证两个侧格，并使用同一 Agent/Occupancy 规则。

### clearance、slope、area cost 分别属于什么？

```text
clearance  GridMap 静态空间属性，AgentProfile 决定要求多少
slope      相邻 Cell height + AgentProfile 阈值共同决定
area       GridMap 提供 area_type，AgentProfile 决定 allowed/cost
```

### 为什么 DynamicOccupancy 不放进 GridMap？

GridMap 是 map/version 对应的进程级共享资产；Occupancy 是某一场 Battle 当前 Tick 的可变事实。生命周期和共享范围完全不同。

### 为什么 Path 返回 WorldPosition？

Battle/Replay 需要稳定业务坐标。GridPos 绑定 origin/cell size/当前 Grid 实现，不能成为长期业务合同。

### 为什么不每 Tick A*？

绝大多数 Tick 路径仍然有效。每 Tick A* 会把单位数×Tick 频率直接放大成大量完整搜索，并在拥堵时形成正反馈。缓存 Path，只在目标变化、路径失效等明确 trigger 下重算。

### BattleWorker 为什么核心 no-yield？

让一次状态推进成为清晰的单 owner 临界区。中途外部 `skynet.call` 会允许协程交错，引入半更新状态、版本变化和复杂补偿。准备好 Snapshot 后，本地连续 simulate，再一次性返回。

### 同一个 Skynet Service 和 OS Thread 是一回事吗？

不是。Service 是 Actor/消息处理实体，Lua State 属于 Service 运行环境；OS Worker Thread 是调度执行资源。Native 进程级模块可能同时从多个 Service/Thread 进入，所以 Native 线程安全不能只看一个 Lua State。

### 哪些地方会分配内存？

```text
Context 创建：NodeScratch + Heap + Occupancy，O(cell_count)
FindPath：最终 raw/smoothed Path points 分配，A* Node 本身不 per-node allocation
Lua Path userdata：每条新 Path 一次
Battle repath：实体保存 Path userdata；世界点只复制进 MOVE_PATH Event
Event Log：按事件数量增长
Unity Replay：解析 JSON 和创建显示对象
```

### 哪些地方可能 yield？

```text
BattleMgr -> skynet.call(worker)      会
网络/DB/Socket                         会/可能
BattleWorker 调 battle_core 之前       dispatch 边界可
battle_core.simulate/step              禁止
Native find_path/occupancy             不会
Unity Replay                           与 Server yield 无关
```

---

## 29. 已知限制与何时演进

第二课完成的是商业项目可以真实使用的**单层 Grid 地面导航与自动战斗骨架**，但范围明确：

```text
支持：
单层 2.5D
坡地/台地
不同 Agent clearance/slope/area
动态单位离散 footprint
Server AI target/move/basic attack
确定性 Event Replay

不支持：
桥上+桥下同 XZ
多层楼
完整 crowd steering
局部避障速度障碍
飞行
技能/弹丸
Player 在线输入
完整在线 Snapshot/Event Sync
Polygon NavMesh / Off-Mesh
```

出现这些需求时：

```text
大量密集单位互相卡位
-> 先 Benchmark，再考虑 reservation/steering/flow field

桥上下层、多层平台、复杂不规则表面
-> 可选 Lesson 4 Recast/Detour

玩家实时操作、技能/弹丸、空中单位
-> Lesson 3
```

---

## 30. 文档结束前的自审计

本课实现时逐项检查：

```text
[ ] 所有现有路径都来自当前仓库或明确写为“第二课新建”。
[ ] 第一课 bmap_format/GridMap/MapRegistry 没有被重新创建。
[ ] WorldPosition 仍然是 Lua/Battle/Replay 正式业务位置。
[ ] GridPos 只存在 Native Grid 算法和 Debug/Test。
[ ] AgentProfile 在 A* 首次需要体型前出现。
[ ] Path 在第一次真正返回路线前出现。
[ ] NavigationContext 在 A* scratch 首次出现前确定 owner。
[ ] DynamicOccupancy 在静态 A* 跑通以后才加入。
[ ] A* 使用 Binary Heap、generation stamp、无 per-node allocation。
[ ] 8-way 对角同时检查两个 side Cell，禁止 corner cutting。
[ ] clearance/slope/area/dynamic 都进入统一 CanTraverse 判定链。
[ ] smoothing 复用同一合法性规则，并保留 Area Cost 语义。
[ ] 缓存 Path 的每次跨格提交重新验证目标格和 diagonal side cells。
[ ] 每个 Battle/Query 拥有独立 NavigationContext。
[ ] 没有 global mutable A* scratch。
[ ] Battle core 内没有 skynet.call/skynet.sleep/Socket/DB/I/O。
[ ] 超出单位数、Tick 数或事件数预算时，本次 Battle 显式失败并由 Worker 关闭 Context。
[ ] Path 有明确 repath trigger 和 cooldown，不每 Tick A*。
[ ] Path 结束但尚未进入攻击范围时会重新置位 need_repath。
[ ] 进入攻击范围会发送 MOVE_STOPPED，Unity 不继续播放旧 Path。
[ ] Event 顺序有稳定 seq/logic_ms。
[ ] 相同 input/map/version/battle_version/seed 得到同逻辑 Event。
[ ] Unity Replay 只表现 Server 结果，不重新寻路覆盖 Path。
[ ] 独立 Gateway Process 只管连接和编解码；Map/Battle Process 才拥有地图和战斗状态。
[ ] RunAutoBattle 的客户端输入只有固定场景 ID；Snapshot、结算和 Event 都由 Server 生成。
[ ] 并发、事件数和响应帧大小均有上限；业务拒绝返回稳定结果码。
[ ] Unity 可通过 Gateway/cluster/BattleMgr/Worker 直接获取结果并回放，无需搬运 JSON。
[ ] 没有 INavigationBackend / GridNavigationBackend / DetourNavigationBackend。
[ ] 没有 Recast/Detour/Polygon NavMesh 教学内容。
[ ] 没有 SkillRuntime/Projectile/FlyingNavigation/PlayerCommand。
[ ] 没有 lesson2.lua、lesson02_server 等课程阶段命名进入工程。
[ ] 所有新增源码示例有职责/边界/输入输出/生命周期/非职责文件头。
[ ] 关键函数说明参数、返回、失败、分配/锁/yield 边界。
[ ] node_index/heap_index/parent_index/generation/open/closed 有明确注释。
[ ] 测试使用统一 navigation_test，不为每个小知识点创建独立程序。
```

如果把本教程落实到仓库后，再执行：

```bash
git diff --check
```

它应该无输出并以 0 退出。若出现 trailing whitespace 或 conflict marker，先修文档/源码格式，再提交。

---

## 31. 本课最终执行链

```text
第一课结果
WorldPosition + immutable GridMap
        |
        v
AgentProfile
        |
        v
NavigationContext
  ├─ A* scratch + generation
  ├─ Binary Heap
  └─ DynamicOccupancy
        |
        v
GridPathfinder
  ├─ World -> Grid
  ├─ clearance / step / slope / area
  ├─ 8-way no corner cutting
  ├─ dynamic occupancy
  ├─ A* / attack-range goal
  ├─ smoothing + revalidation
  └─ Grid -> World Path
        |
        v
Lua Context/Path userdata
        |
        v
BattleWorker
  prepare context
  -> battle_core no-yield
       target
       cached path
       conditional repath
       move
       basic attack
       deterministic event
  -> return
        |
        v
        +--------------------------+
        |                          |
        v                          v
batch_runner -> Replay JSON    BattleMgr <- battle_dispatch <- cluster <- Gateway Process <- Unity 请求
        |                          |
        v                          v
Unity 离线回放             有界 RunAutoBattleResponse
                                   |
                                   v
                             Unity Client Runtime
                             回放 Server world path/events
```

两条验证路径都完成以后，第二课才算结束：batch/JSON 用于确定性回归，独立 Gateway 双进程请求用于从 Unity 触发并观察 Server 权威结果。它把第一课的“Server 能查询地图”推进成“Server 能在一场独立 Battle 中使用自己的动态导航状态，确定性地完成地面 AI 移动和基础战斗，并让 Unity 只按权威结果回放”。

---

## 32. 回头看一场战斗：对象、所有权与生命周期

前面的实现同时出现地图、单位、查询状态和跨 Service 消息。把它们按生命周期放在一起，就能看清哪些数据共享、哪些只存在于一次战斗中。下面描述的是本课完成后的运行链；仅完成到第 13 节时，BattleWorker 和自动战斗入口尚未接入。

### 32.1 从启动到寻路，谁持有什么

```text
Gateway Process                         Map/Battle Process（另一个进程）
客户端连接 / frame / Proto              启动：Query Service 加载 BMAP
        │                                         │
        │                              Native MapRegistry（进程级）
        │                                         └─ shared_ptr<const GridMap>
        │                                            同进程 Service 可引用
        │
        └─ 场景 ID ──cluster──> battle_dispatch ──> BattleMgr
                                                  │ Snapshot（纯 Lua 值）
                                                  │ skynet.call：打包/传值，可能 yield
                                                  v
                                       BattleWorker（自己的 Lua State）
                                       ├─ require battle_nav：注册本 State 的 metatable
                                       ├─ new_context(map_id, version, profiles)
                                       │    └─ Context userdata（本 Worker、本场战斗）
                                       │         ├─ 引用同进程只读 GridMap
                                       │         ├─ 复制 AgentProfile 定义
                                       │         ├─ A* scratch / heap
                                       │         └─ DynamicOccupancy（本场动态事实）
                                       ├─ 单位 Lua state + NavigationAgentHandle
                                       ├─ 寻路 -> 临时 Path userdata
                                       │             └─ 复制世界点到单位 Lua state
                                       └─ no-yield simulate -> Event/Result 纯值
                                                  │
                                                  └─ close Context；结果传回 Unity
```

读图要点：两个进程各有自己的地址空间；Gateway 不持有 `GridMap`。Map/Battle Process 中的 Registry 和地图供本进程的 Query Service、BattleWorker 使用，但各 Service 的 Lua State、metatable 和 userdata 互不共享。启动时加载的是地图；`NavigationContext` 直到 Worker 收到一次战斗 Snapshot 才创建。`skynet.call` 两侧传的是可序列化的值，不能把 userdata 或 C++ 指针沿箭头发送。

### 32.2 名字相近的对象，各自解决什么问题

| 对象 | 作用与所有者 | 存活范围 / 能否跨 Service 传 |
| --- | --- | --- |
| BMAP、`MapRegistry`、`GridMap` | BMAP 是发布资产；Native Registry 按地图 ID/版本持有进程内只读 `GridMap`。 | 地图随所在进程存活；同进程 Native 查询可取得 `shared_ptr<const GridMap>`，不同进程不共享指针。跨进程只传地图身份并各自加载已发布资产。 |
| `WorldPosition`、`GridPos` | 前者是毫米世界坐标；后者是 Grid 内部 Cell 下标。 | 世界坐标值可进 Snapshot/Event；`GridPos` 留在当前 Grid 算法和调试边界。 |
| `AgentProfile` | 一个体型/坡度/Area 规则定义；不是“场上的一个兵”。 | Snapshot 带 profile 值；`new_context` 复制到本场 Context userdata，战斗结束释放。 |
| 业务单位、`NavigationAgentHandle`、`NavigationAgent` | 业务单位的 Lua state 保存 HP、位置、缓存路线；Handle 是 Context 内辨认该实体的导航 token；`NavigationAgent` 将 Handle 与借用的 Profile 组合供一次 Native 调用使用。 | 单位状态归当前 BattleWorker；Handle 是值，不等于 Lua userdata 或业务 ID 的通用指针；`NavigationAgent` 不跨调用保存借用指针。 |
| `NavigationContext`、`DynamicOccupancy` | Context userdata 由 Worker 创建并独占，持有本场 Native 查询状态；Occupancy 记录本场单位覆盖哪些 Cell。 | 每次 `simulate` 新建并关闭；绝不放进共享 `GridMap`，也不跨 Service 发送。 |
| `Path` | 一次查询的路线结果。Binding 返回本 Lua State 的 Path userdata；路线点不可变，Lua wrapper 另外独占该实体的跟随 cursor。 | 查询时产生；实体在移动期间持有，每 Tick 交给 `advance_path`；停止、受阻或重寻路后解除引用，最终由该 State 的 GC 回收。 |
| Snapshot、Event/Result | Snapshot 是本次战斗的冻结输入；Event/Result 是 Server 结算出的有序输出。 | 普通可序列化值，经 Service/进程边界传递；不包含 Context、Path userdata 或 Native 指针。 |

这里的三层不要混同：`GridMap/NavigationContext/Path` 是 Native 对象；Lua userdata 是当前 Lua State 用来持有 Context 或 Path 的包装；Snapshot、世界坐标和 Event 是跨 Service 的值。`battle_nav.new_context(...)` 在当前 Worker 创建 Context userdata，`context:find_path(...)` 在同一 Worker 得到 Path userdata；模块名 `battle_nav.NavigationContext` 只是 metatable 名称，不是跨 State 的对象地址。

### 32.3 一次成功或失败的释放顺序

1. 启动 Map/Battle Process：Query Service 加载并校验 BMAP，Native Registry 持有只读地图。各 Service 第一次 `require "battle_nav"` 时，只在自己的 Lua State 注册模块 table 和 metatable；此时没有战斗 Context 或 Path userdata。
2. 准备 Snapshot：自动请求由 Server 场景模块构造，batch 入口也使用同一场景；BattleMgr 把纯数据交给 Worker。跨 Service 的 `skynet.call` 可以 yield，Worker 收到的是可序列化值，不是 Manager 的 Lua 对象引用。
3. Worker 创建 Context：`new_context` 按 `map_id/map_version` 在本进程 Registry 查图，Context 持有共享只读地图引用，独占 profiles、A* scratch 和动态占位。创建失败返回明确错误，不进入模拟。
4. 核心模拟：单位按 Handle 提交占位/移动；需要寻路时生成并由该实体保存 Path userdata，世界点只复制到 `MOVE_PATH` Event。后续每 Tick 把距离预算交给 Native `advance_path`；目标变化或路线失效才重寻路。同步 Native 调用和 `battle_core.simulate` 均不 yield。
5. 结束或异常：Worker 的 `xpcall` 边界在核心返回或抛错后都执行 `context:close()`，释放大块 Native 状态；之后返回可序列化 Result 或错误。Context userdata 本体和不再引用的 Path userdata最终由本 Lua State 的 `__gc` 处理；`__gc` 是兜底，不代替战斗结束时的显式 `close()`。只读地图继续留在进程 Registry，供下一场战斗复用。

检查是否理解：同一个 Worker 连续模拟两场战斗，会创建两个先后独立的 Context；它们可以引用同一张只读地图，却不会复用上一场的动态占位或 A* scratch。若把战斗交给另一个 Service，传 Snapshot/地图身份/世界坐标，不传上一场的 Context、Path userdata。这样就能判断新概念是在表达真实的所有权和生命周期，还是只给同一件事换了名字。

### 32.4 一次完整寻路的关键函数调用链

先看启动和 Context 创建。下面的箭头表示实际调用，不表示把 C++ 对象跨 Service 传递；`skynet.call`/cluster 所在的边界传的是可序列化值：

```text
battle_main.lua 的 skynet.start
  ├─ skynet.newservice("navigation_query")
  │    └─ navigation_query.lua 的 skynet.start
  │         └─ query_logic.start(config)
  │              └─ battle_nav.load_map(bmap_path) -> Binding l_load_map
  │                   └─ MapRegistry::Load -> BMapReader::Read -> 只读 GridMap 入 Registry
  └─ skynet.newservice("battle/battle_mgr")
       └─ BattleMgr 的 skynet.start -> skynet.newservice("battle/battle_worker")
            └─ BattleWorker require "battle_nav" -> luaopen_battle_nav
                 └─ register_context_meta / register_path_meta（只在该 Lua State）

一次 simulate 请求：BattleMgr 内的局部函数 simulate(snapshot)
  -> skynet.call(Worker, "lua", "simulate", snapshot)（此处可能 yield）
  -> BattleWorker.simulate(snapshot)
       -> battle_nav.new_context(map_id, map_version, profiles)
            -> Binding l_new_context -> MapRegistry::Find
                 -> NavigationContext(shared_ptr<const GridMap>)
                 -> 复制 profiles、建立本场 scratch/Occupancy
       -> battle_core.simulate(snapshot, context)（以下核心流程不 yield）
```

Query Service 加载地图后，Worker 通过同进程 Native Registry 查找，不通过 `skynet.call` 向 Query Service 借地图；`new_context` 不重新读取 BMAP。若地图 ID/版本不存在，Binding 返回 `nil,error`，Worker 不进入核心模拟。

以本课“单位追到敌人攻击范围”为例。此时 Context 已创建，单位出生占位已提交；一次实际查询沿着下面的函数进入 Native A*：

```text
battle_core.simulate -> M.step -> 局部函数 ensure_attack_path(state, context, self, target)
  └─ context:find_path_to_range(profile_id, start_world, target_world, range_mm, self_id)
       └─ Binding l_context_find_path_to_range：校验参数、查本 Context 的 Profile
            └─ GridPathfinder::FindPathToRange(context, agent, start, target, range, policy)
                 └─ FindPathImpl：WorldPosition -> GridPos；检查起点、目标范围
                      ├─ BeginQuery：复用本 Context 的 scratch，递增 generation
                      ├─ HeapPop：取当前最低估计成本的候选 Cell
                      ├─ CanTraverse：静态通行 + 坡度/切角 + 动态占位回调
                      ├─ MoveCost：直/斜移动成本与 Area Cost；更新 g/parent/Heap
                      └─ 命中可站立的攻击范围 Cell
                           └─ BuildPath：回溯 parent -> 平滑并复验 -> 世界坐标 Path
            └─ Binding push_path：成功包装成当前 Lua State 的 Path userdata；失败返回 nil,error
  └─ 核心把 Path userdata 保存到 self.path；复制 world_point 只用于 MOVE_PATH Event
```

`AgentProfile` 决定这个单位能否通过某格；`NavigationAgentHandle` 告诉动态规则“移动者是谁”，检查占位时只忽略自己。`NavigationContext` 提供本场地图引用、Occupancy 和 A* scratch；`GridPathfinder` 用它们完成**这一次**查询。攻击范围查询的目标是范围内某个合法落脚 Cell，不要求走进目标单位中心；精确 A→B 查询使用同一主循环，但以确切终点 Cell 为目标。两种查询的启发式区别见第 9 节。

找到 Path 只表示**查询当时**这条路线合法。后续 Tick 的移动提交是另一条函数链，不会因为有缓存 Path 就跳过检查：

```text
battle_core.simulate -> M.step -> 局部函数 advance_move(state, context, self)
  ├─ Battle 按当前生效速度与 tick_ms 计算整数 distance_mm
  └─ context:advance_path({profile_id, unit_id, path, from_world, distance_mm})
       └─ Binding l_context_advance_path：先完整校验 request，再进入 Native
            └─ GridPathfinder::AdvancePath
                 ├─ 使用 Path userdata 私有 cursor 追踪当前 Segment
                 ├─ 把本 Tick 预算拆成不超过半个 Cell 的有界子步
                 ├─ 每个子步调用 MoveUnit
                 │    ├─ CanTraverse：复验静态边、坡度、切角和动态规则
                 │    └─ DynamicOccupancy::Move：全部通过后提交新 footprint
                 └─ 返回 moving/reached/blocked、最后成功位置和 consumed_mm
```

平滑后的长线段不会一次跨多格提交；高移速同一 Tick 可以在 Native 内执行多个受限子步。若某个子步失败，`advance_path` 返回 `blocked`，已成功提交的位置不回退，核心发出 `MOVE_STOPPED` 并标记重寻路。若目标移动或路线走完仍未进入攻击范围，也按明确条件与 cooldown 再次寻路，不每 Tick 重跑 A*。若初次查询返回 `nil,error`，单位停止当前移动并在退避时间到达后才考虑重试。模拟成功或异常返回到 Worker 后，Worker 调用 `context:close()` → Binding `l_context_close` 释放本场 Native 状态；不再引用的 Path userdata 由该 Lua State 的 `l_path_gc` 回收。

下一课才继续加入人工 Player 输入、Ground/Flying Enemy、技能、弹丸、Air Grid/NoFly，以及在线 Snapshot/Event 同步。
