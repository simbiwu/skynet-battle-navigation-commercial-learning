# 官方参考资料

资料包生成时核对的官方/上游资料。

## 团结引擎 1.10 / Unity 2022.3 LTS

团结引擎 1.10 官方手册：

```text
https://docs.unity.cn/cn/tuanjiemanual/Manual/
```

官方说明团结引擎 1.10 以 Unity 2022 LTS 为研发基础。

官方下载：

```text
https://unity.cn/tuanjie/releases
```

课程 Editor 基线：

```text
Tuanjie Editor 1.10.0
Windows x64
```

## AI Navigation

课程使用：

```text
com.unity.ai.navigation@1.1.7
```

Unity 2022.3 官方兼容文档：

```text
https://docs.unity.cn/cn/2022.3/Manual/com.unity.ai.navigation.html
```

1.1 系列提供本课程需要的：

```text
NavMeshSurface
NavMeshModifier
NavMeshModifierVolume
NavMeshObstacle
NavMeshLink
Editor / Runtime NavMesh Build
```

不要在资料中继续假设 Unity 6 / AI Navigation 2.0.9。

由学习者通过团结引擎 Package Manager 确认或安装 1.1.7，并确认项目 `Packages/manifest.json` / lock 文件记录一致；遇到不可解析时先记录并排查，不静默改用其他版本。

Windows 命令行安装参数：

```text
https://docs.unity.cn/cn/tuanjiemanual/Manual/InstallingUnity.html
```

课程实际安装版本与路径：

```text
Tuanjie 1.10.0 / 2022.3.62t12
<Tuanjie Editor 安装目录>
```

## Protobuf

Schema 与编译器上游：

```text
https://github.com/protocolbuffers/protobuf
```

Server Lua Runtime：

```text
https://github.com/starwing/lua-protobuf
0.5.3
ee4beb3865e2b82ea94b8a4314d78875c550ce20
```

Unity C# Runtime：

```text
https://www.nuget.org/packages/Google.Protobuf/3.36.2
Google.Protobuf 3.36.2
protoc 36.2
```

生成代码和 Descriptor 由同一份 `.proto` 构建。普通 Skynet Service 不在启动路径动态编译 Schema。

## Recast Navigation

Upstream：

```text
https://github.com/recastnavigation/recastnavigation
```

Release：

```text
https://github.com/recastnavigation/recastnavigation/releases
```

课程固定：

```text
v1.6.0
```

上游模块：

```text
Recast
Detour
DetourTileCache
DetourCrowd
```

README 描述：

```text
Recast = navmesh generation
Detour = runtime navmesh / path query
```

## Detour NavMesh

Source / Docs：

```text
https://github.com/recastnavigation/recastnavigation/tree/main/Detour
```

`dtNavMesh` 使用 Tile、Polygon Mesh、Detail Mesh、Off-Mesh Connection。

## 注意

Codex 实操时仍需按固定 Tag 检查实际 Header/API。

不要根据最新 `main` 随意修改课程，再把版本漂移隐藏掉。
