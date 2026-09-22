# BMAP V1 Binary Format

## 设计目标

`.bmap` 是 Unity Editor 和 Linux C++ Server 之间的稳定资产格式。

它不是：

```text
C++ struct memory dump
```

也不是：

```text
Unity serialization
```

所有字段使用明确宽度和 Little Endian。

## 文件布局

```text
+----------------------+
| Header               |
+----------------------+
| Cell Payload         |
+----------------------+
```

### Header V1

建议固定 64 bytes；若最终字段调整，`header_size` 是解析依据。

逻辑字段：

```text
magic[4]             = "BMAP"
format_version u16   = 1
header_size u16
map_id u32
map_version u32
width u32
height u32
cell_size_mm u32
origin_x_mm i32
origin_z_mm i32
flags u32
cell_stride u16
reserved0 u16
payload_size u32
payload_crc32 u32
header_crc32 u32
reserved...
```

不要在代码里通过：

```cpp
reinterpret_cast<Header*>(bytes)
```

直接解析。

使用：

```cpp
read_u16_le
read_u32_le
read_i32_le
```

逐字段读取并做边界检查。

### Cell V1

固定 8 bytes：

```text
height_mm       i32
flags           u16
area_type       u8
clearance_cells u8
```

`index`：

```text
index = z * width + x
```

payload 必须满足：

```text
payload_size == width * height * cell_stride
```

乘法先做 overflow-safe 检查。

## Cell flags

第一版预留：

```text
bit 0 WALKABLE
bit 1 VISION_BLOCK
bit 2 SKILL_BLOCK
bit 3 WATER
bit 4 RESERVED
...
```

不要把 `area_type` 和 flags 混成一个不可扩展值。

## Area Type

课程至少：

```text
0 NORMAL
1 MUD
2 GRASS
3 WATER_SHALLOW
```

是否可走由 `flags` / AgentProfile 决定。

Area 可以增加 cost：

```text
NORMAL 1000
MUD    1400
```

建议使用整数 cost scale，避免不同模块随意 float。

## Height

Unity world Y：

```text
meters
```

Exporter：

```text
round(y * 1000)
-> height_mm
```

Server：

```text
int32
```

Client Debug 可以除以 1000 恢复米。

## Origin

`origin_x_mm / origin_z_mm` 是 Logic Grid 的 world-space 左下基准。

Grid cell center：

```text
world_x_mm = origin_x_mm + x * cell_size_mm + cell_size_mm / 2
world_z_mm = origin_z_mm + z * cell_size_mm + cell_size_mm / 2
```

如果 `cell_size_mm` 为奇数，需要固定 rounding rule；课程建议 CellSize 选择可以被 2 整除的毫米值，例如 500。

## CRC

### payload_crc32

只覆盖：

```text
Cell Payload
```

### header_crc32

Header 中 `header_crc32` 字段置 0 后计算 Header CRC。

Loader 顺序：

```text
read minimum header
-> validate magic/version/header_size
-> validate dimensions/stride/size overflow
-> validate header CRC
-> read payload exact size
-> validate payload CRC
-> construct immutable map
```

失败时返回明确错误，不部分加载。

## Version

两个概念：

```text
format_version
map_version
```

`format_version`：

```text
文件结构版本
```

`map_version`：

```text
同一 map_id 的内容版本
```

例如：

```text
format_version = 1
map_id = 1001
map_version = 37
```

地图美术改障碍后：

```text
map_version = 38
```

不代表 Binary Format 升级。

## Manifest

Exporter 同时输出：

```text
battle_1001.manifest.json
```

供人和 CI 查看：

```json
{
  "format_version": 1,
  "map_id": 1001,
  "map_version": 37,
  "width": 80,
  "height": 60,
  "cell_size_mm": 500,
  "origin_mm": [0, 0],
  "payload_crc32": "A1B2C3D4",
  "walkable_cells": 3972,
  "blocked_cells": 828,
  "min_height_mm": 0,
  "max_height_mm": 3240
}
```

Server 运行期不依赖 JSON Manifest。

## Single-layer Validator

Exporter 要检测：

- 一个采样 XZ 附近出现明显多个可行走高度；
- NavMesh Link / bridge 造成单层压平歧义；
- 高度差超出合理采样阈值；
- 出生区没有可走格；
- 逻辑 Bounds 外仍有目标 NavMesh；
- CellSize 过粗导致窄路消失。

检测到不支持的多层结构时：

```text
Export Failed
```

不要选“最近的一个高度”假装正确。


## 与第三课的关系

BMAP 是 Grid Backend 的 Runtime Asset。

第三课增加 DNAV，不把 BMAP V1 变成“既能 Grid 又能 Polygon”的万能格式。

公共层通过：

```text
NavigationAsset metadata
```

区分 Backend。

这样避免一个文件格式同时承载两套完全不同的拓扑结构。
