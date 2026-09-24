# Polygon Navigation Asset Pipeline：NAVSRC V1 / DNAV V1

> 状态：本文属于可选 Lesson 4 Recast/Detour 专题，不是前三课交互战斗闭环的前置内容。

## 为什么分两个文件

可选 Lesson 4 生产链：

```text
Unity
-> NAVSRC
-> nav_builder
-> DNAV
-> Server
```

`NAVSRC` 是 Authoring Source。

`DNAV` 是 Server Runtime Asset。

两者不能混。

## NAVSRC V1

目标：

> Unity 导出“构建 NavMesh 所需的稳定输入”，而不是导出 Unity 内部 NavMesh 二进制。

### Header

至少：

```text
magic = "NSRC"
format_version
map_id
map_version
source_revision
vertex_count
triangle_count
area_count
link_count
bounds
payload_size
payload_crc32
```

### Vertex

建议 float32 world meter 或 integer mm。

如果用 float32，必须明确 IEEE754 little endian。

课程更倾向：

```text
int32 millimeter
```

再在 Builder 转 float。

### Triangle

```text
v0
v1
v2
area_id
flags
```

### Area

例如：

```text
GROUND
MUD
WATER_SHALLOW
NO_WALK
```

### Link

```text
start_world
end_world
radius
bidirectional
area
flags
user_id
traversal_type
```

`traversal_type`：

```text
JUMP
DROP
LADDER
PORTAL
```

### Source CRC

Builder Manifest 应记录 NAVSRC CRC。

## Unity Source Selection

不要把整个 Scene 所有 Mesh Renderer 无条件导出。

明确 Authoring：

```text
NavigationSourceRoot
LayerMask
NavMeshModifier
Nav Area
Custom NavigationExportMarker
```

视觉装饰可以不进入 Source。

## DNAV V1

外层项目格式。

内部每个 tile payload 可以直接存：

```text
dtCreateNavMeshData()
```

生成的 Detour Tile Data Bytes。

外层 Header：

```text
magic = "DNAV"
format_version
map_id
map_version
agent_profile_id
recast_version
builder_version
tile_count
bounds
build_config_hash
payload_crc32
```

### Tile Directory

每 tile：

```text
tile_x
tile_y
layer
data_offset
data_size
tile_crc32
```

Runtime：

```text
validate outer DNAV
-> iterate tile directory
-> dtNavMesh::addTile
```

## 为什么还有外层 DNAV

Detour tile 自己有内部：

```text
magic
version
```

但项目还需要：

- map/version；
- agent class；
- asset CRC；
- builder fingerprint；
- tile directory；
- project compatibility；
- future migration。

## Build Config

Manifest 保存：

```text
cs
ch
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
partitionType
```

课程不把这些参数硬说成行业标准。

通过地图和 Agent 调整。

## Runtime 版本

DNAV Runtime 必须拒绝：

```text
unsupported format version
wrong agent profile
wrong map version
CRC error
invalid tile directory
overlap / duplicate tile policy violation
```

## Asset Build Reproducibility

同：

```text
NAVSRC bytes
Recast version
Builder version
Build Config
```

应尽量产生相同语义 NavMesh。

若 Binary 不完全 bit-identical，也要能通过 Golden Query 验证相同可达性。

课程会记录 Build Fingerprint。
