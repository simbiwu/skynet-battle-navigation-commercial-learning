# Target Architecture

> 这份文档描述第三课结束后的最终架构。它不是 Lesson 1 的文件创建清单。Lesson 1 不要照着最终架构一次实现所有抽象。

> Client Editor 使用团结引擎 1.10.0（Unity 2022.3 LTS 技术基线）。图中涉及 Unity API 的概念均按团结兼容 API 实现。

## 最终三课结构

```text
                             BUILD / AUTHORING

                +------------------------------+
                | Tuanjie 1.10 Scene           |
                |------------------------------|
                | Terrain / Mesh               |
                | Navigation Areas             |
                | Obstacles                    |
                | Spawn                        |
                | Links                        |
                +--------------+---------------+
                               |
                  +------------+-------------+
                  |                          |
                  | Lesson 1                 | Lesson 3
                  v                          v
        +-------------------+        +-----------------------+
        | Grid Exporter     |        | NavSource Exporter    |
        +---------+---------+        +-----------+-----------+
                  |                              |
                  v                              v
             BMAP V1                         NAVSRC V1
                  |                              |
                  |                              v
                  |                    +---------------------+
                  |                    | C++ nav_builder     |
                  |                    | Recast 1.6.0        |
                  |                    +----------+----------+
                  |                               |
                  |                               v
                  |                           DNAV V1
                  |                               |
                  +--------------+----------------+
                                 |
                                 v

                              SERVER

+----------------------------------------------------------------+
| Skynet Process                                                 |
|                                                                |
|  +----------------------------------------------------------+  |
|  | battle_nav.so                                            |  |
|  |----------------------------------------------------------|  |
|  | NavigationAssetRegistry                                  |  |
|  |                                                          |  |
|  |  +-------------------+  +-----------------------------+  |  |
|  |  | Grid Backend      |  | Detour Backend              |  |  |
|  |  |-------------------|  |-----------------------------|  |  |
|  |  | BMAP              |  | DNAV                        |  |  |
|  |  | Grid A*           |  | dtNavMesh                   |  |  |
|  |  | Clearance         |  | dtNavMeshQuery              |  |  |
|  |  +-------------------+  +-----------------------------+  |  |
|  |                    \        /                            |  |
|  |                 INavigationBackend                      |  |
|  +-------------------------+--------------------------------+  |
|                            |                                   |
|             +--------------+--------------+                    |
|             | BattleNavigationContext     |                    |
|             | dynamic battle-only state   |                    |
|             +--------------+--------------+                    |
|                            |                                   |
|  +-------------------------v-------------------------------+  |
|  | BattleWorker Pool                                       |  |
|  |----------------------------------------------------------|  |
|  | Target / AI / Logical Movement / Attack / Event         |  |
|  +-------------------------+-------------------------------+  |
+----------------------------|-----------------------------------+
                             |
                             v
                         BattleEvent
                             |
                             v
                          Unity Replay
```

## 公共 Navigation Domain

### WorldPosition

Battle 层位置：

```text
x_mm
y_mm
z_mm
```

使用毫米整数作为规则输入。

### NavLocation

不要让上层业务知道：

```text
GridPos
dtPolyRef
```

概念：

```cpp
struct NavLocation {
    WorldPosition world;
    BackendLocation opaque_backend_location;
};
```

Lua 不持久化 `opaque_backend_location`。

它只在当前 Native context 内缓存使用。

战报 / Persistence 只保存 World Position 和 map/version。

### Path

公共路径由：

```text
World Points
Segment Type
Logic Length
```

组成。

Grid Backend：

```text
normal segment
```

Detour Backend：

```text
normal
off-mesh jump
off-mesh drop
off-mesh ladder
```

## 为什么业务 API 从第一课就用 World Position

如果 Lua 写成：

```lua
find_path(sx, sz, ex, ez)
```

其中 `sx` 是 Grid Index，第三课必然修改业务接口。

正确：

```lua
nav_context:find_path(
    agent_profile,
    start_world,
    end_world,
    options
)
```

Grid Backend 自己转换：

```text
World -> Grid
```

Detour：

```text
World -> nearest polygon
```

## Registry

概念 Key：

```text
backend_type
map_id
map_version
```

例如：

```text
GRID / 1001 / 7
DETOUR / 2001 / 3
```

Battle Snapshot 指定：

```text
navigation_asset_id
map_id
map_version
```

生产中也可以 Map Config 决定 backend。

## Grid Asset

共享：

```text
BMAP
```

immutable。

## Detour Asset

共享：

```text
DNAV
```

加载：

```text
dtNavMesh
```

immutable。

QueryContext：

```text
per thread / per query
```

不能把一个带 mutable node pool 的 `dtNavMeshQuery` 在多个线程无保护共享。

## Battle Dynamic State

公共概念：

```text
DynamicObstacle
UnitOccupancy
Reservation
```

Grid 和 Detour 实现不同。

Battle 层不能直接操作：

```text
occupancy[x][z]
```

而通过：

```text
navigation_context
```

调用。

## Recast Offline

Recast 只存在：

```text
tools/nav_builder
CI Asset Build
local authoring validation
```

不链接进普通 Skynet Runtime 也是合理选择。

Server Runtime 至少需要：

```text
Detour
```

是否将 Recast 也链接到 Server Binary 由生产需求决定；课程不需要。

## Detour Tiled NavMesh

第三课直接理解：

```text
tile
poly
poly ref
salt
link
detail mesh
off-mesh connection
query filter
```

地图小也按 Tiled Pipeline 做。

目标不是为了大地图炫技，而是避免第三课只学一个无法自然扩展的 Solo Demo。

## Dynamic Topology

三类变化分开：

### Unit Movement

```text
不重建 NavMesh
```

用 Battle dynamic policy。

### 临时大障碍

可以评估：

```text
DetourTileCache
```

### 永久地图版本变化

重新：

```text
NAVSRC -> nav_builder -> DNAV new map_version
```

正在进行的 Battle pin 旧 map version，不能半场切地图。

## Client

Client 不要求与 Server Poly ID 一致。

必须一致：

```text
passability semantics
map version
logical arrival
event order
```

如果需要极高一致性，未来可以：

```text
Detour Native Plugin on Client
```

但不是三课必做。
