# 第一课第 31 节最终回顾 / 调试 / 验收更新说明

基线仓库：`simbiwu/skynet-battle-navigation-commercial-learning`

基线：`main@73405415491dca3e4fbb1b3dd02627af63f9a799`

## 1. 第一课正文重组

将原来的：

```text
31 完整执行顺序
32 结果对照与调试证据
33 常见故障
34 第一课验收清单
35 课后练习与性能基线
36 第一课面试复盘
```

收敛成唯一的最终主章节：

```text
31. 第一课最终回顾、调试与验收
```

内部依次覆盖：

```text
31.1 课程成果和完整执行链回顾
31.2 一键 Server 构建与资产导入
31.3 启动/状态/日志/安全停止
31.4 LuaPanda debug runtime 安装
31.5 VS Code 双 target 配置
31.6 Gateway -> Query LuaPanda 跟踪
31.7 battle_nav.so / GridMap gdb 跟踪
31.8 LuaPanda + gdb + Unity 完整断点演练
31.9 协议/fd/负坐标等失败验收
31.10 最终证据
31.11 最终 checklist
31.12 常见最终验收故障
31.13 性能基线/课后练习
31.14 面试复盘
31.15 第一课结束与第二课入口
```

原 32～36 的有效内容已吸收进 31，不再在第 31 节之后重复一次验收/复盘。

## 2. 新增 `lesson1_prepare.sh`

路径：

```text
server/scripts/linux/lesson1_prepare.sh
```

职责：把第一课最终 Server 准备收敛成一个 orchestration 入口。

执行链：

```text
Unity BMAP + manifest
-> manifest map/version/cell 校验
-> 原子导入 server/maps
-> run_server.sh build/rebuild
-> pinned dependencies
-> descriptor
-> Native build/test
-> doctor
-> SHA256
-> LESSON1_SERVER_PREPARE_OK
```

它复用现有 `run_server.sh`，没有复制第二套依赖/构建实现。

## 3. 新增 LuaPanda debug-only 工具链

新增：

```text
server/scripts/linux/bootstrap_luapanda.sh
server/scripts/linux/debug_luapanda.sh
server/lualib/debug/luapanda_debug.lua
server/debug/luapanda/VERSIONS.env
server/debug/luapanda/launch.json.example
```

固定：

```text
LuaPanda 3.3.1
commit e3ac3d3314f24cf939c36cac5b7dc1f2ed6ee129
LuaSocket 3.1.0
```

LuaSocket 针对仓库 Skynet bundled Lua 5.4 Header 编译到本地 third_party runtime，不安装系统 Lua 模块。

Gateway / Query 使用两个调试端口：

```text
Gateway 8818
Query   8819
```

原因：它们是两个独立 Skynet Service / Lua State。

正常 Server 启动不设置 `LUA_PANDA_ENABLE`，不会启动调试器。

## 4. Gateway / Query 的最小调试接入

修改：

```text
server/service/navigation_gateway.lua
server/service/navigation_query.lua
```

只增加 debug bootstrap 调用：

```text
luapanda_debug.start("gateway")
luapanda_debug.start("query")
```

网络模型、Query 业务、yield 边界均未改。

## 5. 新增 gdb Lesson 1 配置

路径：

```text
server/debug/gdb/lesson1.gdb
```

预置 pending breakpoints：

```text
l_query_cell
battle_nav::GridMap::WorldToGrid
battle_nav::GridMap::QueryWorld
```

支持：

```bash
./scripts/linux/debug_luapanda.sh --gdb
```

从 LuaPanda Gateway -> LuaPanda Query -> C++ gdb 完整跟踪一次真实 Unity Query。

## 6. README / gitignore

`server/README.md` 增加第一课最终准备和调试入口。

`server/.gitignore` 增加 debug-only third_party：

```text
/third_party/luapanda/
/third_party/luasocket/
/third_party/luasocket-runtime/
```

## 7. 明确未修改

本更新没有改：

```text
第二课正文
Gateway socketdriver + netpack 业务实现
Protobuf schema
BMAP 格式
Native 查询逻辑
run_server.sh 的现有商业化启动/停止模型
Unity Authoring / Exporter / Query Client
```

这次只增强第一课最终收口、构建 orchestration 和调试能力。
