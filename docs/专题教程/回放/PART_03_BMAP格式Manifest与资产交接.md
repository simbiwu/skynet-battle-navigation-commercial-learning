# PART 3：BMAP 格式、Manifest 与资产交接

本节回答一个实际问题：Unity Editor 算出的 Grid 数据，怎样变成 Server 可以安全读取的文件？

上一节得到的是 Unity 内存中的 `BattleMapSnapshot`：每个 Cell 已有 `height`、`Walkable`、`Area` 和 `Clearance`。Unity 的 C# 对象、C++ 的 `struct` 和磁盘文件不是同一种东西。Server 不能直接读取 Unity 工程，也不能假设 C++ 内存布局刚好和 C# 一样。

本节建立这条资产交接链：

```text
Unity Snapshot
    ↓ 逐字段编码
BMAP V1（二进制运行时资产）
    + Manifest（人和 CI 查看用的摘要）
    ↓ 发布到 shared/navigation
Server BMapReader
    ↓ 校验通过后逐字段解码
immutable GridMap
```

## 1. BMAP 和 Manifest 分别解决什么问题

下面这些做法不能作为跨语言资产格式：

```text
把 C# struct 整块写进文件
把 C++ struct 直接 reinterpret_cast 成文件
把 Unity 序列化文件交给 Server 读取
```

因为类型宽度、内存对齐、字节序和版本演进都可能不同；文件损坏时，直接读取还可能把错误数据当成合法地图。

BMAP 把字段顺序、字段宽度、字节序、长度和校验方式写成稳定合同。`BMAP` 是 Server 运行时真正读取的二进制资产；`Manifest` 是给人、发布脚本和 CI 快速审查的 JSON 摘要。Server Runtime 不把 Manifest 当地图数据源。

## 2. BMAP V1 的整体布局

```text
byte 0
┌──────────────────────────────┐
│ Header：固定 64 bytes         │
│ 地图身份、尺寸、原点、CRC 等    │
└──────────────────────────────┘
┌──────────────────────────────┐
│ Cell Payload：width*height*8  │
│ 每个 Cell 固定 8 bytes         │
└──────────────────────────────┘
byte end
```

关键规则：

```text
Header       = 64 bytes
每个 Cell    = 8 bytes
整数         = Little Endian
Cell 顺序    = z * width + x
```

`z * width + x` 不是可以两边各自决定的细节。Writer 和 Reader 必须使用同一规则，否则 Unity 写出的 `(x,z)` 会在 Server 变成另一个格子。

## 3. Header 保存什么

Header 保存的是“怎样解释后续 Payload”的元数据，而不是所有地图内容。

| 偏移 | 长度 | 字段 | 作用 |
|---:|---:|---|---|
| 0 | 4 | `magic` | 固定为 `BMAP`，快速确认文件类型 |
| 4 | 2 | `format_version` | 文件结构版本，当前为 1 |
| 6 | 2 | `header_size` | Header 长度，当前为 64 |
| 8 | 4 | `map_id` | 业务地图 ID，例如 1001 |
| 12 | 4 | `map_version` | 这张地图内容是哪一版 |
| 16 | 4 | `width` | X 方向 Cell 数 |
| 20 | 4 | `height` | Z 方向 Cell 数 |
| 24 | 4 | `cell_size_mm` | Cell 边长，单位毫米 |
| 28 | 4 | `origin_x_mm` | Grid 原点 X，允许负数 |
| 32 | 4 | `origin_z_mm` | Grid 原点 Z，允许负数 |
| 36 | 4 | `flags` | V1 保留字段，当前为 0 |
| 40 | 2 | `cell_stride` | 一个 Cell 的字节数，当前为 8 |
| 42 | 2 | `reserved0` | 保留字段，当前为 0 |
| 44 | 4 | `payload_size` | Payload 总字节数 |
| 48 | 4 | `payload_crc32` | 只校验 Payload |
| 52 | 4 | `header_crc32` | 校验 Header 本身 |
| 56 | 8 | `reserved` | 保留，当前为 0 |

### 3.1 `format_version` 和 `map_version` 的区别

```text
format_version = Reader 应该怎样解释文件结构
map_version    = 同一张地图的内容是哪一版
```

例如美术移动了 Battle_1001 的一堵墙：

```text
format_version = 1
map_id = 1001
map_version = 2
```

Reader 仍然使用 V1 布局，但地图内容已经变化。只有文件字段布局变化，才需要讨论升级 `format_version`。

### 3.2 Battle_1001 的尺寸推导

```text
width        = 60
height       = 40
cell_size_mm = 500
origin       = (-15000, -10000)
```

```text
Cell 总数       = width * height = 60 * 40 = 2400
Payload 字节数  = 2400 * 8 = 19200
BMAP 文件总大小 = 64 + 19200 = 19264 bytes
```

当前仓库的 `shared/navigation/battle_1001/battle_1001.bmap` 正是 19264 bytes。这个关系是 Reader 检查文件完整性的基础。

## 4. 一个 Cell 保存什么

每个 Cell 固定 8 bytes：

| Cell 内偏移 | 长度 | 字段 | 作用 |
|---:|---:|---|---|
| 0 | 4 | `height_mm` | 静态地表高度，单位毫米 |
| 4 | 2 | `flags` | 静态属性 bitset，bit 0 是 Walkable |
| 6 | 1 | `area_type` | 地表类型编码 |
| 7 | 1 | `clearance_cells` | 到静态障碍/边界的离散距离，单位 Cell |

```text
Cell = height_mm + flags + area_type + clearance_cells
     = 4 bytes  + 2     + 1         + 1
     = 8 bytes
```

Server 判断可走时只检查 bit 0：

```cpp
bool IsWalkable() const noexcept {
    return (flags & kWalkableFlag) != 0;
}
```

这样以后增加 `VISION_BLOCK`、`WATER` 等 bit 时，不会把其他属性误当成一个新的可走状态。`clearance_cells` 也只是离散 Grid 步数，不能直接解释成精确的毫米净空；体型、动态占用和移动复验在后续查询阶段处理。

## 5. 为什么按 `z * width + x` 写入

磁盘是一维连续字节，地图逻辑是二维坐标，所以要有稳定映射：

```text
index = z * width + x
```

宽度为 4 时：

```text
       x=0  x=1  x=2  x=3
z=0     0    1    2    3
z=1     4    5    6    7
z=2     8    9   10   11
```

例如 `(x=2,z=1)`：

```text
index       = 1 * 4 + 2 = 6
cell_offset = index * cell_stride = 6 * 8 = 48 bytes
```

所以 Writer 的 `payload[offset + ...]` 和 Reader 的 `payload + index * cell_stride` 必须对应同一坐标规则。

## 6. Unity Writer 的写盘流程

入口：

```text
unity/BattleNavigation/Assets/BattleNavigation/Editor/BMapWriter.cs
```

Writer 接收上一节已经采样、计算 Clearance 并通过 Validator 的 Snapshot。它不重新采样，也不补算 Clearance，让“计算”和“编码”保持独立。

`BMapWriter.Write()` 的顺序是：

```text
1. 检查 snapshot、输出路径和 Cell 数量
2. 分配 width*height*8 bytes 的 Payload
3. 按 z-major 顺序逐个写入 Cell 的 8 bytes
4. 计算 Payload CRC32
5. 构造 Header，暂时让 header_crc32=0
6. 计算 Header CRC32，再写回 Header
7. Header + Payload 写到 .tmp 文件并 Flush(true)
8. 回读 .tmp 文件执行 Verify
9. 验证成功后替换正式 BMAP
```

这里使用 `BMapLittleEndian.WriteU32`，而不是把对象内存整块写出。例如：

```text
500 = 0x000001F4
Little Endian 文件字节 = F4 01 00 00
```

这样 C# Writer、C++ Reader 和未来工具都遵守同一字节合同。

### 6.1 为什么先写临时文件

正式文件不会直接被半成品覆盖：

```text
写 battle_1001.bmap.tmp
    ↓ Flush(true)
    ↓ 回读并校验 Magic、长度、CRC
    ↓ 成功后替换 battle_1001.bmap
```

如果导出中途崩溃或校验失败，旧的正式 BMAP 仍然可用。Server 不会读到“只写了一半”的地图。

## 7. CRC32 校验保护什么

### 7.1 Payload CRC

```text
payload_crc32 = CRC32(Cell 0 + Cell 1 + ... + Cell N)
```

它回答的是：Cell 数据在写出、复制和发布过程中有没有意外损坏。

### 7.2 Header CRC

计算 Header CRC 时，先把 Header 自己的字段 `bytes[52..55]` 清零：

```text
Header 副本
    ↓ header_crc32 清零
    ↓ 计算完整 64 bytes CRC32
    ↓ 写回 header_crc32
```

Reader 会复制 Header、清零同一字段，然后重新计算并比较。CRC 用于发现意外损坏，不是身份认证，也不替代发布权限控制。

## 8. Manifest 的内容和边界

入口：

```text
unity/BattleNavigation/Assets/BattleNavigation/Editor/BMapManifestWriter.cs
```

当前 Battle_1001 的摘要：

```json
{
    "format_version": 1,
    "map_id": 1001,
    "map_version": 1,
    "width": 60,
    "height": 40,
    "cell_size_mm": 500,
    "origin_mm": [-15000, -10000],
    "payload_crc32": "FE9E6F90",
    "walkable_cells": 1508,
    "blocked_cells": 892,
    "min_height_mm": 83,
    "max_height_mm": 1550
}
```

它帮助人和 CI 快速确认：地图 ID、版本、尺寸、原点、可走格数量、高度范围和 Payload CRC 是否符合预期。`walkable_cells + blocked_cells = 1508 + 892 = 2400`，说明统计覆盖了全部 Cell。

Manifest 是观察和发布审查数据，不是完整地图，也不能替代 BMAP Reader 的格式、长度和 CRC 校验。当前字段中的 `payload_crc32` 是内容校验摘要；如果长期发布合同需要密码学内容 hash，应在明确合同后增加独立字段，不能把 CRC 当作身份 hash。

## 9. Server Reader 的六个阶段

入口：

```text
server/native/grid_map/src/bmap_reader.cpp
```

`BMapReader::Read(path)` 把磁盘文件当作不可信输入，不直接 `reinterpret_cast` 成 C++ struct。

### 9.1 读取并检查最小长度

```text
以 binary 打开文件
取得文件长度
文件至少 64 bytes
回到文件开头，一次读入 byte buffer
```

### 9.2 检查 Magic、版本和 Header 长度

```text
file[0..3] == "BMAP"
format_version == 1
header_size == 64
```

### 9.3 逐字段解码 Header

Reader 使用 `ReadU16Le`、`ReadU32Le`、`ReadI32Le`：

```cpp
metadata.map_id = ReadU32Le(file.data() + 8);
metadata.origin_x_mm = ReadI32Le(file.data() + 28);
```

`+8` 和 `+28` 是文件合同中的 byte 偏移，不是 `BMapMetadata` 在内存中的成员偏移。

### 9.4 交叉检查尺寸和文件长度

```text
cell_count         = width * height
expected_payload   = cell_count * cell_stride
expected_file_size = header_size + expected_payload
```

Battle_1001 应该是：`60*40=2400`，`2400*8=19200`，`64+19200=19264`。三者不一致就拒绝加载，避免少读、越界或接受未知尾部。

### 9.5 校验两个 CRC

```text
复制 Header，清零 header_crc32，计算并比较 Header CRC
计算 Payload CRC，与 payload_crc32 比较
```

任一失败，返回明确的 `NavError`，不构造半成品地图。

### 9.6 逐 Cell 解码并构造 immutable GridMap

```cpp
source = payload + index * cell_stride;
cell.height_mm = ReadI32Le(source);
cell.flags = ReadU16Le(source + 4);
cell.area_type = source[6];
cell.clearance_cells = source[7];
```

全部通过后才构造 `shared_ptr<const GridMap>`。GridMap 自己持有解码后的 Cell，不借用 Reader 的临时文件缓冲；Reader 返回后可以释放文件字节。

## 10. 资产发布到 Server 的位置

```text
shared/navigation/battle_1001/
├── battle_1001.bmap
└── battle_1001.manifest.json
```

Server 配置使用 BMAP：

```text
server/config/battle.lua
    bmap = "../shared/navigation/battle_1001/battle_1001.bmap"
```

这个路径相对于 Server 工作目录，不是 Unity 工程绝对路径。Server Runtime 不读取 Unity Scene、Bake 临时目录或开发机路径。

正确交接链是：

```text
Unity 导出并验证
    ↓
提交 shared/navigation 的 BMAP + Manifest
    ↓
Server 工作区取得同一份资产
    ↓
BMapReader 启动时再次校验
    ↓
GridMap 进入 MapRegistry / NavigationContext
```

`GridMap` 保存 immutable 静态数据、负责 WorldPosition 与 GridPos 转换和 Cell 查询；动态单位占用、寻路队列和战斗状态属于后面的 `NavigationContext`，不写回 BMAP。

## 11. 常见失败路径

```text
BMAP_BAD_MAGIC / kBadMagic
    传入的不是 BMAP，或文件开头被覆盖

payload_size != width * height * cell_stride
    文件截断、Header 被篡改或版本合同不一致

BMAP_HEADER_CRC_MISMATCH
BMAP_PAYLOAD_CRC_MISMATCH
    文件复制/写盘损坏，或 Writer/Reader 的 CRC 参数不一致

format_version 和 map_version 混用
    Server 不清楚是切换解析方式，还是切换地图内容
```

遇到 CRC 错误不能“重新算一次然后接受”，否则会把已经变化或损坏的资产伪装成合法资产。

## 12. 本节读完后应该能回答什么

```text
为什么 BMAP 不能是 C++ struct 的内存转储？
Header 和 Cell Payload 分别保存什么？
为什么 Cell 固定为 8 bytes？
为什么二维坐标按 z*width+x 写入？
Battle_1001 的 19264 bytes 如何推导？
payload_crc32 和 header_crc32 分别保护什么？
为什么 Writer 先写 .tmp、验证后再替换？
Manifest 为什么存在，为什么 Server 不把它当运行时地图？
Reader 为什么先检查长度和 CRC，之后才构造 GridMap？
静态 GridMap 和动态 NavigationContext 的边界在哪里？
```

下一节进入 Server 启动和服务组合：谁读取这个 BMAP、什么时候读取、`MapRegistry` 如何保存地图，以及 Battle 进程怎样把静态地图交给后续导航查询。
