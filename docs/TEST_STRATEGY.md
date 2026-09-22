# Test Strategy

三课统一原则：

```text
Asset Tests
Native Core Tests
Binding Tests
Skynet Integration
Unity Validation
Determinism
Concurrency
Benchmark
Regression
```

## Lesson 1：Grid Asset

### Golden 8x8 Map

人工定义：

```text
walkable
blocked
height
clearance
area
```

Unity Export 与 C++ Load 对照。

### Corruption

```text
magic
format version
header size
width/height overflow
stride
payload size
header crc
payload crc
truncated
duplicate asset
version mismatch
```

### Coordinate

```text
World -> Grid -> World
```

检查 rounding contract。

### Multiple Skynet Service

并发只读同一静态资产。

Registry 只有一份 payload。

### Unity / Server Protobuf

真实 TCP Client 与 Skynet Gateway 覆盖：

```text
4-byte big-endian length frame
protocol version
request id
unknown command
malformed envelope/body
64 KiB packet limit
map/version mismatch
out of bounds WorldPosition
```

Unity Golden Point、协议自动化 Client 和 Native GridMap 对同一坐标返回一致语义。Client 结果只用于显示和校验，不能覆盖 Server。

## Lesson 2：Grid Path

### Golden Cases

```text
straight
around wall
no path
corner
small corridor
large corridor
slope pass
slope fail
area cost detour
```

### Dynamic

```text
occupy
move
release
conflict
ignore self
temporary block
```

### Smoothing

必须再做 collision / clearance validation。

### Battle

```text
target
repath
attack range
event order
no-yield simulation
```

### Determinism

同：

```text
map/version/input/seed/battle version
```

重复运行得到相同 Event。

### Benchmark

至少：

```text
80x60
256x256
512x512 synthetic
```

记录：

```text
CPU
compiler
-O
thread count
query count
blocked ratio
p50/p95/p99
qps
visited nodes
allocation
```

## Lesson 3：NAVSRC Builder

### NAVSRC Parser

```text
valid
crc
triangle index out of range
degenerate triangle policy
area id invalid
link invalid
bounds mismatch
overflow
```

### Recast Builder Golden

同一 NAVSRC + config：

```text
build succeeds
tile count stable
bounds stable
query golden passes
```

不强制不同平台 binary bit-for-bit 完全一致，除非实际验证支持。

但语义 Query 必须一致。

## Lesson 3：DNAV Loader

```text
magic
format
map/version
agent profile
build config hash
tile directory
duplicate tile
tile crc
payload crc
dtNavMesh addTile failure
```

## Detour Query Golden Cases

### Simple Ground

结果与 Grid 语义一致。

### Bridge

```text
bridge above
road below
```

验证：

- ground path stays ground；
- bridge path stays bridge；
- ramp is only normal connection。

### Off-Mesh

```text
jump link
```

关闭 link：

```text
NO_PATH / alternate path
```

开启：

```text
Path contains Jump segment
```

### Areas

```text
mud cost
water excluded
road preferred
```

### Agent

Small / Large。

### Nearest Poly

输入：

```text
slightly off mesh
```

Project 成功。

输入过远：

```text
START_NOT_NAVIGABLE
```

不能无限搜索最近点。

## Detour Concurrency

多个 Skynet Worker / standalone threads：

```text
same immutable dtNavMesh
separate query context
```

重复大量 Query。

可用：

- ASan / UBSan；
- TSAN standalone harness（环境支持时）；
- deterministic result compare。

## Backend Contract Test

同一个高层测试不关心 Backend：

```text
project
find path
world points
length
segment type
error mapping
```

分别运行：

```text
Grid
Detour
```

## Battle Cross-backend Test

选择没有多层结构的简单地图。

同一 Unit AI：

```text
Grid
Detour
```

不要求 Path 点完全相同。

必须都满足：

```text
合法可达
不穿障碍
最终进入 attack range
event invariant
```

## Performance Comparison

不要拿不同地图比较然后下结论。

至少固定：

```text
same source terrain semantics
same start/end set
same agent
same CPU
same build
```

比较：

```text
asset size
runtime memory
query p50/p95/p99
path points
visited nodes if meaningful
build time
```

## Bug Rule

任何：

```text
穿墙
穿层
off-mesh segment丢失
wrong map version
asset corruption
query race
client timeline drift
```

先补 Regression。
