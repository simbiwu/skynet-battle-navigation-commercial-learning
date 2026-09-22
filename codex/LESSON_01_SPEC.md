# Lesson 01 Spec

主文档：

```text
docs/Skynet_BattleNavigation第一课_从Unity地图到Skynet查询_实操.md
```

## 本课只教

```text
WorldPosition
GridPos
NavCell
BMAP
GridMap
MapRegistry
Lua C Binding
Skynet Query
Protobuf Query Contract
Unity -> Skynet End-to-End Query
```

## 本课不教

```text
AgentProfile
Path
NavigationContext
A*
BattleWorker
INavigationBackend
Detour
```

可以在文档结尾用一句话说明：

> 后面会有第二种导航实现，所以业务位置不长期绑定 GridPos。

不能展开未来接口。

## 完成

```text
[ ] Unity scene
[ ] navigation authoring
[ ] BattleMapRoot
[ ] exporter
[ ] height
[ ] area
[ ] clearance
[ ] single-layer validation
[ ] BMAP
[ ] manifest
[ ] overlay
[ ] C++ reader
[ ] immutable GridMap
[ ] MapRegistry
[ ] Lua binding
[ ] multi-service query
[ ] pinned lua-protobuf / protoc / C# runtime
[ ] generated server descriptor and Unity C# types
[ ] TCP length framing and malformed packet tests
[ ] Unity real Protobuf query against Skynet
[ ] corruption tests
[ ] golden coordinate test
[ ] ALL_TESTS_OK
```

## 面试讲解验收

完成代码不等于完成第一课。学习者还需要脱离文档讲清：

```text
[ ] Unity Scene、NavMesh、BMAP 和运行时 Protobuf 的边界
[ ] WorldPosition / GridPos 的职责与负坐标换算
[ ] 2.5D one XZ -> one walkable height 的能力和限制
[ ] BMAP header、payload、CRC、字节序与拒绝策略
[ ] GridMap immutable 和 MapRegistry 启动期 ownership
[ ] Lua C Binding 为什么保持薄，不持有业务状态
[ ] 多 Skynet Service / 多 OS Thread 查询的安全条件
[ ] MapService 为什么不做所有高频查询的永久代理
[ ] malformed frame、错误版本、错误地图和越界怎样失败
[ ] Unity / Native / Skynet golden result 怎样互相证明
```

面试陈述结构：

```text
当前问题
-> 约束
-> 设计选择
-> 真实执行链
-> 测试证据
-> 已知限制
-> 何时进入 Lesson 2
```
