# Lesson 3 实操：Recast / Detour Polygon NavMesh Backend

## 这课解决什么

第二课结束时，你已经实际使用过 `AgentProfile / Path / NavigationContext / INavigationBackend`。所以第三课不再重新设计 Battle API，只学习一个新的导航实现。

前两课的 2.5D Grid：

```text
one XZ -> one height
```

无法表达：

```text
桥上
桥下
```

同时可走。

Lesson 3 创建一张新地图：

```text
Battle_2001
```

包含：

```text
Ground Road
Bridge
Ramp
Upper Platform
Gap + Jump Link
Mud Area
Blocked Area
```

完成后：

```text
同一 Skynet BattleWorker
```

可以使用：

```text
DetourNavigationBackend
```

而 Unit AI 主流程不改。

---

# Part A：先理解 Recast / Detour 边界

## Recast

负责：

```text
triangle geometry
-> voxel
-> heightfield
-> compact heightfield
-> regions
-> contours
-> polygon mesh
-> detail mesh
```

它是 Build Tool。

## Detour

负责：

```text
load navmesh
nearest poly
path
corridor
straight path
raycast
poly query
```

它是 Runtime。

## 本课生产链

```text
Unity
-> NAVSRC

nav_builder
-> Recast
-> Detour Tile Data
-> DNAV

Skynet Server
-> Detour
-> Query
```

Server 启动不会重新跑 Recast。

---

# Stage 0：固定第三方

固定：

```text
Recast Navigation v1.6.0
```

第三方目录：

```text
third_party/recastnavigation
```

Bootstrap Script：

- checkout exact tag；
- verify tag；
- 不自动跟 main；
- 记录 License。

CMake 只构建课程需要：

```text
Recast
Detour
DetourTileCache（若本课做到临时拓扑障碍）
```

不需要先把 RecastDemo 链入 Server。

---

# Stage 1：Unity Battle_2001

创建：

```text
Assets/Scenes/Battle_2001.unity
```

结构：

```text
Ground
Road_Under_Bridge
Bridge
Ramp
UpperPlatform
GapA
GapB
JumpLink
MudArea
NavigationSourceRoot
```

先用 Unity 自己的 Navigation View 检查设计。

这一步是 Authoring Validation，不是 Server Asset。

---

# Stage 2：NavigationSourceExporter

新目录：

```text
Assets/BattleNavigation/Editor/NavSource/
```

输出：

```text
battle_2001.navsrc
battle_2001.navsrc.manifest.json
```

Exporter 收集明确 Navigation Source：

```text
vertices
triangles
area
bounds
off-mesh links
```

不要：

```text
遍历所有 Renderer
```

然后把所有 Triangle 当 Server Geometry。

建立：

```text
NavigationExportMarker
LayerMask
Area Mapping
Link Authoring
```

---

# Stage 3：坐标

NAVSRC 统一：

```text
right-handed / left-handed conversion rule
axis
unit
origin
```

Unity：

```text
X/Y/Z meters
```

项目文件建议存：

```text
int32 millimeter
```

Builder 转：

```text
float Recast world unit
```

必须写 Golden 坐标 Test：

```text
Unity known point
NAVSRC dump
Builder debug OBJ
```

三者一致。

---

# Stage 4：NAVSRC Validator

检查：

```text
vertex count
index range
degenerate triangle
NaN / overflow
bounds
area
link endpoint
duplicate source
CRC
```

Link 端点没有邻近可走 Source：

```text
Error
```

---

# Stage 5：Standalone nav_builder

WSL：

```text
tools/nav_builder/
  CMakeLists.txt
  main.cpp
  navsrc_reader.cpp
  recast_builder.cpp
  dnav_writer.cpp
  build_config.cpp
  debug_dump.cpp
```

命令：

```bash
./nav_builder \
  --input maps/source/battle_2001.navsrc \
  --config config/nav/agent_small.json \
  --output maps/runtime/battle_2001_small.dnav \
  --dump-stats
```

这不是 Skynet Service。

它是 Build Tool。

---

# Stage 6：Recast Build Config

理解并实际调整：

```text
cellSize
cellHeight
walkableSlopeAngle
walkableHeight
walkableClimb
walkableRadius
maxEdgeLen
maxSimplificationError
minRegionArea
mergeRegionArea
maxVertsPerPoly
detailSampleDist
detailSampleMaxError
tileSize
```

不要照抄 RecastDemo 默认值后称为商业参数。

用实际：

```text
Small Agent
Large Agent
Bridge
Ramp
Narrow Path
```

验证。

---

# Stage 7：Tiled Build

课程直接走：

```text
Tiled NavMesh
```

理解：

```text
tile X/Y
border
tile bounds
poly
external link
```

测试地图小也照做。

输出统计：

```text
tile count
poly count
vertex count
build ms
asset bytes
```

---

# Stage 8：Detour Tile Data

每 Tile：

```text
rcPolyMesh
rcPolyMeshDetail
off-mesh data
-> dtNavMeshCreateParams
-> dtCreateNavMeshData
```

然后项目 DNAV Writer 保存。

不要直接把进程里的：

```text
dtNavMesh object memory
```

dump 到文件。

---

# Stage 9：DNAV Loader

Server：

```text
native/navigation/detour/
```

读取：

```text
DNAV Header
Tile Directory
Tile Payload
```

校验。

创建：

```text
dtNavMesh
```

逐 Tile：

```text
addTile
```

失败返回项目错误。

---

# Stage 10：Detour Query Context

每 Query Context：

```text
dtNavMeshQuery
poly scratch
straight path scratch
dtQueryFilter / project filter wrapper
```

不要全局共用一个 mutable `dtNavMeshQuery`。

Map 本身 immutable shared。

---

# Stage 11：Project World Position

公共：

```lua
context:project(profile_id, world)
```

Detour 内：

```text
findNearestPoly
```

要定义 Search Extent。

不能：

```text
extent = huge
```

把楼上点吸附到楼下或很远 Poly。

Project Result：

```text
nearest point
poly ref internal
```

Lua 不拿 PolyRef。

---

# Stage 12：FindPath

流程：

```text
Project Start
Project End
-> findPath
-> Poly Corridor
-> findStraightPath
-> common Path
```

Path 返回 World Point。

BattleWorker 无需修改。

---

# Stage 13：Bridge Test

地图：

```text
        BRIDGE
===================

       5m height

-------------------
     ROAD BELOW
```

Case 1：

```text
Start Road Left
End Road Right
```

Path：

```text
road below
```

不能瞬移上桥。

Case 2：

```text
Start Bridge
End Bridge
```

Path：

```text
bridge
```

Case 3：

```text
Ground -> Bridge
```

只能：

```text
Ramp
```

---

# Stage 14：Off-Mesh Link

Gap：

```text
Platform A     Platform B
─────────      ─────────
         \    /
          gap
```

Author：

```text
Jump Link
```

Builder 生成 Off-Mesh Connection。

Detour Path 遇到：

```text
off mesh
```

公共 Path：

```text
segment_type = Jump
traversal_user_id = ...
```

Battle Event：

```text
TRAVERSAL_STARTED
TRAVERSAL_FINISHED
```

Unity：

```text
jump animation
```

不要把 Jump Link 当普通 Walk 直线。

---

# Stage 15：Query Filter

统一 Area：

```text
GROUND
MUD
WATER
DANGER
```

Profile：

```text
include flags
exclude flags
area cost
```

验证：

```text
short mud
vs
long road
```

Query 是否按 Cost 选择。

---

# Stage 16：Agent Class

至少比较：

```text
Small
Large
```

方案 A：

```text
one conservative NavMesh
```

方案 B：

```text
two DNAV assets
```

实际做哪一个由课程地图决定。

必须记录：

```text
asset bytes
build time
path validity
narrow corridor behavior
```

---

# Stage 17：Detour Backend 接入公共接口

实现：

```text
DetourNavigationBackend
```

公共：

```text
Project
FindPath
Raycast
```

Lua API 不新增：

```text
detour_find_path
```

Battle 仍：

```lua
context:find_path(...)
```

---

# Stage 18：Dynamic Unit Occupancy

不要因为有 Detour 就用 TileCache 表示每个英雄。

移动 Unit：

```text
battle-local spatial occupancy
```

Detour 负责 Static Topology。

两层协作。

课程可以：

```text
world-space spatial hash
```

表示 Unit footprint。

---

# Stage 19：TileCache 小案例

如果时间允许做一个：

```text
Gate Closed
Gate Open
```

这种“拓扑级临时障碍”。

使用：

```text
DetourTileCache
```

理解局部 tile rebuild。

这一阶段不是必做核心。

即使不编码，也必须讲清商业边界。

---

# Stage 20：Grid vs Detour Backend 对照

选择一张单层简单地图，分别生成：

```text
BMAP
DNAV
```

跑同一批：

```text
start/end
agent
query count
```

记录：

```text
asset size
runtime memory
build time
query p50/p95/p99
path point count
```

不要预设 winner。

---

# Stage 21：Battle Cross-backend

同一：

```text
BattleSimulator
TargetSelector
EventWriter
```

配置：

```text
navigation_backend = grid
```

跑。

然后：

```text
navigation_backend = detour
```

跑。

AI 源代码不改。

Path 可以不同，但都必须：

```text
合法
到达攻击范围
不穿墙
事件 invariant 正确
```

---

# Stage 22：Determinism / Replay

Battle Snapshot 记录：

```text
navigation backend
asset id
map id
map version
battle version
seed
```

Detour Build Asset 通过 map_version / asset version pin。

同一 DNAV 跑：

```text
N times
```

Event 一致。

---

# Stage 23：Failure

测试：

```text
bad NAVSRC
bad DNAV CRC
missing tile
wrong agent asset
findNearestPoly fail
partial path policy
off-mesh disabled
unsupported traversal
```

不能：

```text
segfault Skynet
```

---

# Stage 24：Lesson 3 完成

你应该能解释：

1. Recast 和 Detour 为什么分开；
2. 为什么 Recast 放离线 Builder；
3. Unity 为什么导 NAVSRC 而不是把内部 NavMesh Binary 当 Server Contract；
4. Tiled NavMesh 的结构；
5. Poly Corridor 和 Straight Path 区别；
6. Bridge 为什么天然解决 Grid 的 XZ 重叠问题；
7. Off-Mesh Connection 如何进入 Battle Event；
8. Detour Query Context 为什么不能全局共享 mutable buffer；
9. 为什么移动 Unit 不应该全靠 TileCache；
10. 为什么 BattleWorker 基本不需要知道 Grid / Detour；
11. 什么场景继续用 Grid，什么场景直接用 Polygon NavMesh。
