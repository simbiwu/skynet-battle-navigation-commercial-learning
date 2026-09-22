# Native Navigation API

## 目录

第三课结束时建议：

```text
native/navigation/
  include/
    navigation_api.h
    navigation_types.h
    navigation_asset.h
    navigation_context.h
    navigation_path.h
    agent_profile.h

  common/
    navigation_registry.cpp
    path_codec.cpp

  grid/
    bmap_reader.cpp
    grid_map.cpp
    grid_backend.cpp
    astar.cpp
    grid_query_context.cpp
    grid_dynamic_state.cpp

  detour/
    dnav_reader.cpp
    detour_map.cpp
    detour_backend.cpp
    detour_query_context.cpp
    detour_dynamic_state.cpp
    detour_filter.cpp

  lua/
    lua_battle_nav.cpp

  tests/
  benchmark/

tools/
  nav_builder/
```

## Public Lua API

### Registry

```lua
nav.load_asset(path)
nav.freeze_registry()
nav.asset_info(asset_id, map_version)
```

不要分：

```lua
load_grid_map
load_detour_map
```

作为业务正式 API。

Debug / Tool 可以有 Backend-specific API。

### Context

```lua
local context, err =
    nav.new_context(
        asset_id,
        map_version
    )
```

### Project

```lua
local location, err =
    context:project(
        profile_id,
        {
            x_mm = ...,
            y_mm = ...,
            z_mm = ...
        }
    )
```

业务通常可让 `find_path` 内部 Project。

显式 Project 用于：

- spawn validation；
- debug；
- teleport；
- recover position。

### Path

```lua
local path, err =
    context:find_path(
        profile_id,
        start_world,
        end_world,
        options
    )
```

共同返回：

```text
Path userdata
```

API：

```lua
path:count()
path:world_point(index)
path:length_mm()
path:segment_type(index)
path:traversal_user_id(index)
path:encode_v1()
```

## Error Contract

通用：

```text
ASSET_NOT_FOUND
MAP_VERSION_MISMATCH
OUT_OF_BOUNDS
START_NOT_NAVIGABLE
END_NOT_NAVIGABLE
NO_PATH
INVALID_AGENT
CONTEXT_CLOSED
PATH_TOO_LONG
UNSUPPORTED_TRAVERSAL
INTERNAL_ERROR
```

Grid-specific 错误不应直接污染 Battle Lua。

Detour-specific：

```text
DT_STATUS_...
```

转换成项目错误，并可在 debug detail 中记录底层 status。

## Native Interface

```cpp
class INavigationBackend
{
public:
    virtual ~INavigationBackend() = default;

    virtual ProjectResult Project(...) const = 0;
    virtual PathResult FindPath(...) const = 0;
    virtual RaycastResult Raycast(...) const = 0;
};
```

## Grid Query Context

- flat arrays；
- generation stamp；
- binary heap；
- no per-node new/delete。

## Detour Query Context

典型成员：

```text
dtNavMeshQuery
poly corridor scratch
straight path scratch
query filter
```

不要：

```text
static dtNavMeshQuery g_query;
static dtPolyRef g_path[...];
```

给所有 Skynet Thread 共用。

Query Context 可以：

- thread_local pool；
- explicit pool；
- per-call RAII；

最终根据 Benchmark。

## Detour Map

`dtNavMesh` 初始化后普通 Query 视为只读。

地图版本 pin。

运行中的 Battle 不替换它。

## Filter

项目 Filter 统一 Agent / Area 语义：

```text
poly flags
include flags
exclude flags
area costs
```

不要在每个业务 Module 自己创建不同 Filter。

## Find Path Detour Pipeline

概念：

```text
world start
-> findNearestPoly
world end
-> findNearestPoly
-> findPath
-> poly corridor
-> findStraightPath
-> Path userdata
```

Off-Mesh Segment 不能丢失 metadata。

## Dynamic State

Grid：

```text
cell occupancy
```

Detour：

课程第一版可以保留一个 battle-local spatial occupancy overlay，按 world space 查询单位 footprint。

不要修改 `dtNavMesh` 来表示每个移动 Unit。

## Path Encoding

Path Wire V1 应使用 World Position，而不是 Grid Point：

```text
path_version
point_count
for each:
  x_mm
  y_mm
  z_mm
  incoming_segment_type
  traversal_user_id
```

这样 Grid / Detour 共用客户端 Replay。

可以做 delta / varint 优化，但先 Benchmark。

## Memory

Registry 统计：

```text
static asset bytes
tile bytes
map count
version count
```

Context 统计：

```text
query scratch
dynamic occupancy
path result bytes
```

Lua Debug API 可查询概要，但不要暴露内部 pointer。

## Lua / C Boundary

- 参数范围检查；
- integer overflow 检查；
- exception 不穿越 C boundary；
- userdata `__gc` 生命周期明确；
- closed context 再调用返回错误；
- 不允许一个 context 在多个 Lua State 传递；
- path immutable。
