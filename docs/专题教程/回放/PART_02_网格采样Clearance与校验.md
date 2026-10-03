# PART 2：从 NavMesh 采样到可验证的网格快照

目录入口：[章节目录](README_章节目录.md)；前置阅读：[PART 1](PART_01_Unity场景与Bake及BMAP导出的分工.md)。

本节从 `BattleMapExporter.Export()` 的中间阶段开始。Bake 已经产生 NavMeshData，但 Server 需要的是固定尺寸、固定索引和固定字段的 Grid 数据。本节追踪三步：从 NavMesh 三角形采样基础 Cell，给 Cell 计算 Clearance，再在写盘前验证整个 Snapshot。

```text
已 Bake 的 NavMesh
      ↓ BattleMapSampler.Sample
基础 Snapshot：height / walkable / area
      ↓ BattleMapClearance.Compute
完整 Snapshot：再加入 clearance_cells
      ↓ BattleMapValidator.ValidateSnapshot
允许交给 BMapWriter，或以明确错误停止
```

本节不展开 BMAP Header 和 C++ Reader；它们属于下一阶段的二进制合同。这里先回答“一个 Cell 的值从哪里来”。

## 1. Snapshot 是什么

`BattleMapSnapshot` 是一次导出流程中的内存快照。它把地图元数据和 Cell 数组放在一起，使采样、Clearance、校验、Overlay 和 Writer 使用同一份结果。

入口文件：

```text
unity/BattleNavigation/Assets/BattleNavigation/Editor/BattleMapSnapshot.cs
```

关键字段是：

| 字段 | 作用 |
|---|---|
| mapId / mapVersion | 标识这份地图资产 |
| width / height | X、Z 方向的格数 |
| cellSizeMm | 每格边长，单位毫米 |
| originXMm / originZMm | Grid 左下角世界坐标 |
| cells | 按 `z * width + x` 排列的 `NavCell[]` |

`Snapshot` 不是长期 Runtime 对象，也不是 Unity Asset。它只在一次导出调用中存在，最后被 Writer 编码成 BMAP。

## 2. `Sample()` 先检查什么

入口：

```text
unity/BattleNavigation/Assets/BattleNavigation/Editor/BattleMapSampler.cs
BattleMapSampler.Sample(BattleMapRoot root)
```

方法首先检查 `root`，再调用 `root.ValidateOrThrow()`，确保地图身份、尺寸、Cell 大小和数组乘法都合法。之后调用：

```csharp
NavMeshTriangulation triangulation = NavMesh.CalculateTriangulation();
```

这个 API 返回当前已加载 NavMesh 的三角形快照：

```text
vertices：所有三角形顶点的世界坐标
indices ：每三个下标组成一个三角形
areas   ：每个三角形对应的 Unity Area 编号
```

它不会直接告诉我们“第 23 个 Grid Cell 是否可走”。因此采样器仍要按照 `BattleMapRoot` 的 Grid，把每一个 Cell Center 投到这些三角形上。

如果没有顶点、没有索引，或者索引数不是 3 的倍数，采样立即失败。`areas` 数量必须等于三角形数量，否则无法知道一块表面属于哪种地表类型。

常见错误：

```text
NAVMESH_EMPTY
NAVMESH_TRIANGULATION_AREA_COUNT_MISMATCH
```

`NAVMESH_EMPTY` 通常意味着没有 Bake、Bake 结果没有加载，或者 Surface 没有收集到有效几何。它不是“所有 Cell 都不可走”的正常地图结果，因为连可用于判断的三角形都不存在。

## 3. 一个 Cell 怎样找到地面

采样器按行列遍历：

```csharp
for (int z = 0; z < snapshot.height; ++z)
{
    for (int x = 0; x < snapshot.width; ++x)
    {
        Vector3 center = root.GridToWorldCenter(x, z);
        ...
    }
}
```

以当前 Battle_1001 为例：Grid 原点是 `(-15,-10)`，Cell 边长是 `0.5` 米。

```text
Cell Center X = -15 + (x + 0.5) × 0.5
Cell Center Z = -10 + (z + 0.5) × 0.5
```

第 `(3,2)` 格的中心是：

```text
X = -15 + 3.5 × 0.5 = -13.25 米
Z = -10 + 2.5 × 0.5 = -8.75 米
```

Y 暂时设为 0，只用于确定要检查的 XZ 位置。真正的地面 Y 由 NavMesh 三角形插值得到。

## 4. 三角形投影和高度插值

`CollectHeightCandidates()` 会遍历 NavMesh 的每个三角形。对当前 Cell Center 的 XZ 坐标，它调用 `TryInterpolateY(a,b,c,x,z,out y)`。

可以把过程理解成两步：

1. 把三角形投影到 XZ 平面，判断待测点是否落在三角形内部或边界上。
2. 点落入后，根据它在三角形内部的位置，插值得到世界 Y。

示意图：

```text
XZ 俯视；A/B/C 是 NavMesh 三角形顶点，P 是 Cell Center

             C
            / \
           / P \
          /     \
         A───────B

P 的 XZ 投影落在三角形内，因此可以从 A/B/C 的高度插出 P.y。
```

代码使用两个重心坐标 `u`、`v` 表示 P 在三角形中的位置：

```text
P = A + u × (B-A) + v × (C-A)
```

满足以下条件时，点位于三角形范围内：

```text
u >= 0
v >= 0
u + v <= 1
```

源码允许很小的 `epsilon=1e-6`，用于吸收浮点误差。它只处理点落在三角形边界时的数值扰动，不会故意扩大可走区域。

如果三角形在 XZ 平面的投影退化，二维叉积的分母接近 0，方法跳过它。这样的三角形不能可靠地用于高度插值。

得到高度后，代码使用：

```csharp
BattleMapRoot.MetersToMillimeters(y, "sampleHeight")
```

将 Unity 米制浮点数转换成整数毫米。Server 后续使用整数世界坐标，减少跨语言和浮点计算差异。

## 5. 为什么要收集 HeightCandidate

同一个 XZ 位置可能穿过多个 NavMesh 表面。例如楼梯上下层或桥面上下方，俯视投影相同，但世界 Y 不同。

```text
侧视：同一 XZ 上有两层表面

Y=6 ───────────── 上层 NavMesh
       ↑ 同一 XZ 投影
Y=0 ───────────── 下层 NavMesh
```

当前 BMAP V1 的一个 Cell 只能保存一个 `heightMm`，所以采样器不能随便选择上层或下层。`CollectHeightCandidates()` 会把同一 XZ 上的高度候选去重：高度差不超过 `multiLayerSeparationMeters=0.25` 米时视为同一层，消除相邻三角形共享边和浮点误差造成的重复。

去重后有三种情况：

| 候选数量 | Cell 结果 |
|---:|---|
| 0 | 默认 Cell，不设置 Walkable，表示不可走 |
| 1 | 设置 Walkable，写入高度和 Area |
| 大于 1 | 抛出 `MULTI_LAYER_NOT_SUPPORTED` |

拒绝多层是格式边界的显式处理。若把多个高度静默压成一个，Server 得到的地图会丢失真实层级信息，错误很难从 BMAP 结果反推出来。

一个可走 Cell 在基础采样阶段的生成逻辑是：

```csharp
NavCell cell = default;
if (candidates.Count == 1)
{
    cell.flags = NavCellFlags.Walkable;
    cell.heightMm = MetersToMillimeters(candidate.y, "sampleHeight");
    cell.areaType = MapArea(candidate.areaIndex);
}
```

这里的 `default` 很重要：不可走 Cell 的 flags、height、area 和 clearance 都先是 0。后续 Clearence 只给可走格写入距离。

## 6. Area 为什么要重新映射

NavMesh 三角形携带的是 Unity Area 编号，例如 `0`、`1`。这个编号属于 Unity 项目配置，不能直接当成长期 Server 合同。

`MapArea()` 按名称查找 Unity 当前配置的编号，再转换成稳定的 `BattleArea`：

```text
Walkable / Normal  -> BattleArea.Normal
Mud               -> BattleArea.Mud
Grass             -> BattleArea.Grass
WaterShallow      -> BattleArea.WaterShallow
```

这样做的意义是：Unity 内部 Area 的排列可以变化，BMAP 仍使用项目定义的稳定编码。未知 Area 会抛出：

```text
UNMAPPED_NAVMESH_AREA
```

没有 Area 信息时则抛出：

```text
NAVMESH_AREA_MISSING
```

Area 描述地表类型，是否可走仍由 `Walkable` bit 决定。当前章节先保存类型，不展开 Server 如何把不同 Area 加入寻路成本；那属于后面的 AgentProfile 和 A* 章节。

## 7. Clearance 是怎样算出来的

入口：

```text
unity/BattleNavigation/Assets/BattleNavigation/Editor/BattleMapClearance.cs
BattleMapClearance.Compute(snapshot)
```

Clearance 表示一个 Cell 到最近静态障碍或地图外边界的保守距离，单位是 Cell。它服务于后续单位体型和通行判断。

### 7.1 为什么从障碍向外传播

如果对每个可走格都搜索最近障碍，重复工作很多。当前实现把所有障碍格和边界格一次性放进队列，从它们向外做多源 BFS：

```text
起点：所有不可走格，距离 0
边界可走格：距离 1
向 8 个邻居传播
每次遇到更小距离就更新
```

一个简化网格例子：

```text
初始地图（#=不可走，.=可走，边界也算外部障碍）

1 1 1 1 1
1 . . . 1
1 . # . 1
1 . . . 1
1 1 1 1 1

传播后的 clearance（8 邻域距离）

1 1 1 1 1
1 1 1 1 1
1 1 0 1 1
1 1 1 1 1
1 1 1 1 1
```

这里边界的 `1` 代表边界外有静态不可走区域；不可走 Cell 本身是 0。中心障碍的对角邻居也按一步处理，因为当前实现的八个方向边权都为 1。

### 7.2 “保守”是什么意思

当前 Clearance 不是连续空间的欧氏距离，也没有给对角线使用 `sqrt(2)` 权重。它使用 8 邻域、每一步成本 1，因此得到的是一种便于网格查询的保守 Cell 距离。

例如一个可走格到障碍的真实几何距离可能是 0.7 米，但由于 Cell 边长是 0.5 米，Clearance 只记录离散的 Cell 数。后续 Server 还会结合单位半径、实际位置和通行检查，不应该把该字段解释为精确毫米距离。

### 7.3 用 Battle_1001 的实际格子走一遍

当前地图是 `60 × 40`，Cell 边长 `0.5 米`，Grid 原点是世界 XZ=`(-15,-10)`。中央 `CenterBlock` 的世界范围约为 `X∈[-2,2]`、`Z∈[-2,2]`。

用本节前面的中心公式换算：

```text
x=26 -> centerX = -15 + 26.5 × 0.5 = -1.75
x=33 -> centerX = -15 + 33.5 × 0.5 =  1.75
z=16 -> centerZ = -10 + 16.5 × 0.5 = -1.75
z=23 -> centerZ = -10 + 23.5 × 0.5 =  1.75
```

所以局部 Grid 可以看成：

```text
z=24       .  .  .  .  .  .  .  .
z=23       .  #  #  #  #  #  #  #  .
z=22       .  #  #  #  #  #  #  #  .
z=21       .  #  #  #  #  #  #  #  .
z=20       .  #  #  #  #  #  #  #  .
z=19       .  #  #  #  #  #  #  #  .
z=18       .  #  #  #  #  #  #  #  .
z=17       .  #  #  #  #  #  #  #  .
z=16       .  #  #  #  #  #  #  #  .
z=15       .  .  .  .  .  .  .  .
             ↑              ↑
           x=26            x=33
```

`#` 表示不可走 Cell，`.` 表示可走 Cell。取同一行 `z=20`，障碍右侧的三个 Cell 是：

```text
x=33: centerX=1.75，障碍，distance=0
x=34: centerX=2.25，可走，离障碍一个八邻域步，distance=1
x=35: centerX=2.75，可走，离障碍两个八邻域步，distance=2
```

代码传播时，`x=33` 出队后会访问 `x=34`：

```text
nextDistance = distance[x=33] + 1
              = 0 + 1
              = 1
```

随后 `x=34` 再把距离 2 传播给 `x=35`。因为 Cell 边长是 0.5 米，`distance=1` 可以帮助我们理解为一个离散格层级，但它不等于“精确有 0.5 米连续净空”；真正的障碍边界、Agent 半径和动态单位仍由后续导航查询判断。

### 7.4 对角线为什么也是一步

`NeighborX` 和 `NeighborZ` 一起列出了八个方向：

```text
(-1,-1)  (0,-1)  (1,-1)
(-1, 0)  当前格   (1, 0)
(-1, 1)  (0, 1)  (1, 1)
```

当前实现给八个方向统一边权 1。因此障碍右上角的对角 Cell 也会在一次传播中得到 1，不会得到 `sqrt(2)`。这正是 `clearance_cells` 的数据定义：它是八邻域的离散步数，不是毫米欧氏距离。

例如下面的局部结果：

```text
障碍周围的 distance

1 1 1
1 0 1
1 1 1
```

中心 `0` 是障碍，八个相邻格都是一步可达，所以都是 `1`。

### 7.5 地图边界也会产生 Clearance

地图外没有 Cell，但单位走到边缘时仍然需要被视为靠近静态边界。代码把边界可走格先设为 1 并加入队列：

```csharp
bool boundary = x == 0 || z == 0 ||
    x == width - 1 || z == height - 1;
```

例如 `z=0` 行的 Cell Center 是：

```text
Z = -10 + (0 + 0.5) × 0.5
  = -9.75 米
```

它可能是可走地面，但再往负 Z 已经离开地图。因此它的初始 Clearance 是 1；更靠地图内部的格子会从这个边界源继续收到 2、3……。

如果不把边界作为源，边缘格可能被算成距离无限大，Server 会误认为边缘有很宽的可用空间。

### 7.6 多个障碍怎样同时传播

`Compute()` 把所有不可走格和边界源一起放进一个队列，这叫多源 BFS。每个 Cell 保存到最近源点的最小距离：

```text
某格从中央障碍收到 5
某格从南侧边界收到 3
最终保留 min(5, 3) = 3
```

这里要特别区分两件事：**跳过当前邻居**，和**结束整个 BFS**。代码只在新距离更小时更新当前邻居：

```csharp
if (nextDistance >= distance[nextIndex])
    continue;

distance[nextIndex] = nextDistance;
queue.Enqueue(new Node(nextX, nextZ));
```

这段代码的可读含义是：

```text
新算出的距离 >= 这个邻居已经保存的距离
    说明当前传播路线没有更近
    只跳过这个邻居

新算出的距离 < 这个邻居已经保存的距离
    说明找到了更近的障碍/边界来源
    更新距离，并把这个邻居加入队列
```

因此，下面两种理解都不准确：

```text
遇到不可走格，就停止整个 BFS
遇到已有更小 distance 的格子，就停止整个 BFS
```

不可走格在初始化时本来就是距离 `0` 的传播源；已有更小距离时，只代表当前这条路线对这个邻居没有帮助。其他队列节点仍然会继续传播。

整个 BFS 的停止条件只有一个：

```csharp
while (queue.Count > 0)
```

当队列为空时，表示所有已经发现且仍可能向外传播的 Cell 都处理完了，整张地图没有新的更小距离需要传播，`Compute()` 才结束。

例如一行地图两端都是障碍：

```text
[障碍] [可走] [可走] [可走] [障碍]
```

初始化时，两个障碍同时进入队列：

```text
[0] [∞] [∞] [∞] [0]
队列 = 左障碍, 右障碍
```

两个传播源交替从队列取出并向外扩散，结果是：

```text
[0] [1] [2] [1] [0]
```

中间 Cell 从左边收到距离 2，从右边也收到距离 2，因此保留 2。如果某个 Cell 先收到距离 5，后来又从另一个障碍收到距离 3，就会从 5 更新为 3；反过来，已经是 3 时再收到 5，则跳过这次更新。

这样不需要让每个障碍单独完整扫描整张地图。所有障碍和边界源共享一个队列，传播范围相遇时保留最小距离；队列按距离层级向外扩散，先得到 0 层，再得到 1 层、2 层，最终每格保留最近障碍或边界的距离。

### 7.7 Clearance 在后续导航中的位置

Clearance 只描述静态障碍和地图边界，不包含移动中的单位。它可以用于快速过滤：

```text
clearance 太小 -> 位置明显不适合当前体型
clearance 足够 -> 仍需检查 AgentProfile、动态 occupancy 和移动复验
```

例如 Server 的 AgentProfile 半径是 200 毫米，而 Cell 边长是 500 毫米。`clearance_cells=1` 只能表示一个离散格层级，不能直接解释为“连续净空半径 500 毫米”。单位中心、障碍真实边界和动态占位仍由后续 NavigationContext 负责。

### 7.8 动态单位进入 Cell 后会不会改变 Clearance

不会。当前设计把两类数据严格分开：

```text
GridMap / BMAP
    静态地图：地面、墙、边界、height、Walkable、Area、clearance
    加载后 immutable，多场 Battle 可以共享

NavigationContext / DynamicOccupancy
    动态地图：单位当前 footprint、占用关系、移动中的状态
    每场 Battle 独占，随 Battle 创建和释放
```

单位第一次进入地图时，Native `DynamicOccupancy::Move()` 会根据 `AgentProfile` 的半径计算它覆盖的 Cell，把句柄登记到 `occupants_`，同时保存一份该单位的 `AgentFootprint`。单位移动时，代码先准备新的 footprint，再清理旧 Cell、登记新 Cell；失败时保留旧占位。

例如：

```text
静态 clearance：
障碍       单位候选位置
[#] -- 2 -- [.]       clearance=2

单位 A 登记后：
[#] -- 2 -- [A]       静态 clearance 仍然是 2
                       DynamicOccupancy 另外记录 A
```

如果单位 B 查询经过 A 当前占用的 Cell，动态查询会把该 Cell 判定为 blocked；它不会把静态 `clearance_cells` 改成 0，也不会重写 BMAP。

因此单位移动的流程是：

```text
读取 immutable GridMap 的静态 Walkable / Clearance
        ↓
读取当前 Battle 的 DynamicOccupancy
        ↓
按 AgentProfile 检查完整 footprint
        ↓
允许时提交新占位，拒绝时保留旧占位
```

当前代码中的 `NavigationContext::BeginQuery()` 只清理本次 A* 的 Node scratch 和 heap 逻辑长度，不清空 `DynamicOccupancy`。这保证新一轮寻路仍然看到本场 Battle 的真实单位占位。

只有静态地图发生变化时，才需要重新计算 Clearance。例如修改墙的位置、地面高度、NavMesh Bake 参数或地图范围，都应重新 Bake、重新采样、重新计算 Clearance 并生成新版本 BMAP，再由 Server 重新加载。动态单位出生、移动、死亡和离场只更新 occupancy，不触发资产重建。

### 7.9 写回 Snapshot 时的值类型细节

`NavCell` 是值类型。代码从数组取出一个副本，修改 `clearanceCells` 后必须再写回：

```csharp
NavCell cell = snapshot.cells[index];
cell.clearanceCells = ...;
snapshot.cells[index] = cell;
```

如果只修改局部变量而忘记写回，日志可能显示计算完成，但 Writer 仍会把旧值写入 BMAP。这是阅读 C# struct 数组时要特别注意的 ownership 和复制语义。

距离最后饱和到 `byte.MaxValue`。BMAP 每格只留 1 字节，超过 255 个 Cell 的距离都记录为 255；这不会造成文件字段溢出。

## 8. Validator 在写盘前检查什么

入口：

```text
unity/BattleNavigation/Assets/BattleNavigation/Editor/BattleMapValidator.cs
BattleMapValidator.ValidateSnapshot(root, snapshot)
```

Validator 是导出闸门。它发现错误后抛出异常，不修复场景，也不静默跳过坏格。

它按顺序检查：

1. Snapshot 和 BattleMapRoot 的地图 ID、版本、宽高、Cell 大小一致。
2. `cells.Length == width * height`。
3. 可走格数量不为 0。
4. 每个可走格的 `clearanceCells` 不为 0。
5. 可走格比例过低或过高时输出警告。
6. 出生点数量、SpawnId 唯一性、位置范围和所在格可走。

### 8.1 为什么要检查元数据一致

Snapshot 中的 width、origin 和 Cell 大小会进入 BMAP Header。若 Snapshot 和 Root 不一致，采样得到的 Cell 可能被写入另一套空间合同，Server 查询会出现稳定但错误的坐标结果。

### 8.2 为什么出生点要再次映射

出生点使用世界坐标，校验时先转换为整数毫米，再根据：

```text
gridX = floor((worldX_mm - originX_mm) / cellSize_mm)
gridZ = floor((worldZ_mm - originZ_mm) / cellSize_mm)
```

这里必须使用向负无穷取整。当前地图原点有负坐标，C# 整数除法默认向 0 截断，会让负数边界落入错误 Cell。

例子：

```text
相对坐标 = -1 mm
Cell 大小 = 500 mm

数学上的格子下标：floor(-1 / 500) = -1
C# 向 0 截断：-1 / 500 = 0
```

所以代码额外实现 `FloorDiv()`，避免地图负轴边界错一格。

出生点检查失败时可能得到：

```text
SPAWN_POINT_MISSING
SPAWN_ID_INVALID_OR_DUPLICATE
SPAWN_OUT_OF_BOUNDS
SPAWN_NOT_WALKABLE
```

## 9. 完整调用顺序和观察日志

正式导出入口中的顺序是：

```csharp
BattleMapSnapshot snapshot = BattleMapSampler.Sample(root);
BattleMapClearance.Compute(snapshot);
BattleMapValidator.ValidateSnapshot(root, snapshot);
BMapWriter.Write(snapshot, bmapPath);
BMapManifestWriter.Write(snapshot, bmapPath);
```

这意味着：

- Sample 只负责基础高度、Walkable 和 Area；
- Clearance 只补静态距离；
- Validator 只判断合同和数据是否能进入文件；
- Writer 只编码已经确定的 Snapshot；
- Manifest 读取成功写出的 BMAP 生成审查摘要。

调试“某格为什么不可走”时，按这个顺序查：

```text
1. Cell Center 是否落在 NavMesh 三角形投影内？
2. 是否有多个高度候选？
3. 三角形 Area 是否能映射到 BattleArea？
4. 该格是否在 Clearance 计算后仍有值？
5. Validator 是否因出生点或元数据拒绝？
6. Writer 是否真的写入了这份 Snapshot？
```

调试“Clearance 全是 0”时，先确认基础 Snapshot 的 Walkable bit 是否存在。不可走格本来就是 0；可走格全为 0 则会被 Validator 以 `WALKABLE_CELL_WITH_ZERO_CLEARANCE` 拒绝。

## 10. 本节检查点

脱离源码后，应能回答：

- 为什么采样器要读取 NavMesh 三角形，而不是直接遍历场景 Collider？
- 一个 Cell 的 X/Z 从哪里来，Y 又从哪里来？
- 为什么同一个 XZ 上出现两层高度时要拒绝导出？
- 为什么 Unity Area 编号要映射成稳定的 BattleArea 编码？
- 多源 BFS 的起点有哪些？地图边界为什么也算障碍来源？
- 为什么 Clearance 记录的是 Cell 距离，而不是毫米欧氏距离？
- 为什么修改 `NavCell` 后必须显式写回数组？
- 为什么负坐标映射必须使用 FloorDiv？
- Validator 通过后，哪些问题仍要到 BMAP Reader 阶段才能发现？

下一节进入 **PART 3：BMAP 文件合同、Manifest 与资产交接**，把本节生成的 Snapshot 按字节布局写入文件，再追踪正式文件如何交给 WSL Server。
