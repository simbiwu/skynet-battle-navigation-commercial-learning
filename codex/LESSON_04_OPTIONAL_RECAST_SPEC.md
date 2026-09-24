# Lesson 04 Optional Spec：Recast / Detour Polygon NavMesh

本专题是可选高级课，不是前三课 Server 权威战斗闭环的前置条件。只有项目出现桥上/桥下、多层平台、复杂不规则地面或 Off-Mesh Traversal 的真实需求时才进入。

固定版本：

```text
Recast Navigation v1.6.0
```

生产链：

```text
Unity NAVSRC
-> standalone nav_builder
-> Recast tiled build
-> DNAV
-> Detour Runtime Query
-> 与 Grid 共用上层 Battle API
```

禁止：

- 在 BattleWorker 运行期构建 Recast；
- 把 Unity 内部 NavMesh binary 当长期 Server Asset；
- 把 `dtPolyRef` 暴露给 Lua 业务；
- 使用跨线程 global mutable `dtNavMeshQuery`；
- 为接入 Detour 重写 AI、技能或 BattleWorker；
- 删除仍适用的 Grid 实现。

完成条件：

```text
[ ] Recast v1.6.0 pinned
[ ] NAVSRC validator/exporter
[ ] standalone nav_builder
[ ] tiled DNAV format/manifest/loader
[ ] per-context Detour query
[ ] nearest poly / corridor / straight path
[ ] bridge under/over and Off-Mesh Link tests
[ ] same BattleWorker/AI/skill code path
[ ] Grid vs Detour benchmark under same conditions
[ ] deterministic replay
[ ] ALL_TESTS_OK
```
