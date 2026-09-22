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
