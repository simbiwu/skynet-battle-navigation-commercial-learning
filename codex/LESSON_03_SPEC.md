# Lesson 03 Spec

主文档：

```text
docs/LESSON_03_PRACTICAL.md
```

格式：

```text
docs/POLYGON_NAV_ASSET_FORMAT.md
```

## 固定版本

```text
Recast Navigation v1.6.0
```

不要跟 main。

## P0 Architecture

```text
Unity NAVSRC
-> standalone nav_builder
-> Recast
-> DNAV
-> Detour Backend
-> same Navigation API
-> same BattleWorker
```

## 禁止

- Server runtime Recast whole map on Battle start；
- 把 Unity internal NavMesh binary 当长期 Server asset；
- 把 dtPolyRef 暴露给 Lua 业务；
- 新增 `detour_find_path` 让 Battle 分支判断 Backend；
- 一个 global mutable dtNavMeshQuery 给所有线程；
- 用 TileCache 表示所有移动 Unit；
- 为了接 Detour 重写 Battle AI；
- 删除 Grid Backend。

## 完成

```text
[ ] Recast v1.6.0 pinned
[ ] Battle_2001 bridge/multilevel scene
[ ] NavSource exporter
[ ] NAVSRC validator
[ ] standalone nav_builder
[ ] Recast tiled build
[ ] DNAV format / manifest
[ ] DNAV loader
[ ] dtNavMesh load tiles
[ ] separate query contexts
[ ] nearest poly
[ ] find path / corridor
[ ] straight path
[ ] bridge under/over tests
[ ] ramp connection test
[ ] off mesh jump
[ ] area filter
[ ] agent class strategy
[ ] common Path segment metadata
[ ] same BattleWorker code path
[ ] backend contract tests
[ ] Grid vs Detour benchmark
[ ] deterministic replay
[ ] failure tests
[ ] ALL_TESTS_OK
```
