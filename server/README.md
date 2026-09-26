# Battle Navigation Server

这里是课程的 WSL/Linux Server 工程。仓库根目录下的三个主要边界为：

```text
unity/BattleNavigation/   Unity Authoring 与后续客户端表现
server/                   C++、Lua、Skynet、协议与 Server 测试
shared/                   Unity、Server 与离线工具共同消费的版本化合同和发布资产
docs/                     课程正文、格式合同与架构说明
```

`third_party/`、`build/` 和 Native 二进制不提交。协议源、固定版本、Server descriptor 与已发布 BMAP 位于仓库根目录 `shared/`，必须作为同一个 Git 提交的一部分更新。Server 不读取 Unity 的实时 Bake 目录。

Server 内部目录按运行身份划分：

```text
service/   由 newservice/uniqueservice 启动的 Service 入口
lualib/    Service Lua State 内通过 require 加载的普通模块
protocol/  Server 侧协议生成/验证脚本；协议唯一源位于仓库 shared/protocol/
config/    Skynet 进程配置与只读业务配置
native/    C++ Runtime 与 Lua C Binding
run/       PID/控制锁等本机运行状态，不提交 Git
logs/      后台运行日志，不提交 Git
```

## 统一启动入口

平时不需要手工按顺序执行 bootstrap/build 脚本。`run_server.sh` 会检查固定版本项目依赖和仓库已发布生成物，并做增量 Native 构建：

```bash
cd server
./scripts/linux/run_server.sh start
./scripts/linux/run_server.sh status
./scripts/linux/run_server.sh stop
```

常用维护命令：

```bash
./scripts/linux/run_server.sh doctor
./scripts/linux/run_server.sh prepare
./scripts/linux/run_server.sh build
./scripts/linux/run_server.sh rebuild
./scripts/linux/run_server.sh start --rebuild
./scripts/linux/run_server.sh restart
./scripts/linux/run_server.sh foreground
./scripts/linux/stop_server.sh
```

约定：

- `start` 默认后台运行，PID 写入 `run/server.pid`，当前日志由 `logs/server.log` 软链接指向；
- `foreground` 适合 gdb/LuaPanda/直接观察日志；
- `prepare` 自动补齐仓库固定的 Skynet/protoc/lua-protobuf 依赖和本机构建产物；共享协议与地图缺失时明确失败，不能在部署端临时生成另一版本；
- `build` 与 `rebuild` 会执行项目 Lua 可变参数策略检查；项目自有稳定接口和业务调用必须使用具名参数；
- 系统级编译工具缺失时只给出明确安装命令，不在启动脚本里静默执行 `sudo apt`；
- `rebuild` 只清理 `server/build/*` 和 Skynet 编译产物，不删除 `shared/`、源码或 third_party 固定源码；
- `stop` 先验证 PID 的 `/proc/<pid>/exe` 确实指向本仓库 Skynet，再发送 SIGTERM；默认不会直接 `kill -9`；
- 只有显式执行 `stop --force`，且 SIGTERM 超时后，才允许 SIGKILL。

只运行 Lua 策略检查：

```bash
./scripts/linux/check_lua_varargs.sh
```

检查范围是 `service/`、`lualib/`、`protocol/`、`config/`、`tests/` 下的项目自有 `.lua`。它不扫描 `third_party/`；失败时会输出违规文件和行号。

当前课程固定 Skynet v1.8.0。该版本没有应用层 SIGTERM drain hook；第一课 Query/Gateway 没有持久化可变业务状态，因此 SIGTERM 用作当前阶段的安全进程停止手段。后续进入有持久化、在线 Battle 或跨服务事务的商业项目时，应在 Server 内增加 drain/shutdown 协议，再由进程管理器做最后兜底。

## Gateway framing

第一课 Navigation Gateway 使用 Skynet v1.8.0 的：

```text
socketdriver
+ PTYPE_SOCKET event dispatch
+ netpack.filter / netpack.pop
```

`skynet.netpack` 固定使用 `uint16 Big Endian length + payload`，因此单个 Envelope 最大 `65535` bytes。Protobuf Envelope/command/request_id 本身没有变化。

Unity 验证通过的 BMAP 与 manifest 发布到仓库根目录 `shared/navigation/battle_1001/`。Unity Bake 只改变当前工作区；提交、推送并由 Server 机器拉取相同提交后，Server 才会看到新版本。`BMapReader` 仍会在加载阶段校验格式和 CRC。

## 第一课最终准备与调试

第一课最终验收不再手工串联构建命令。先拉取同时包含 `shared/navigation` 与 `shared/protocol` 的课程提交，停止当前 Server，再执行：

```bash
BUILD_TYPE=Debug ./scripts/linux/lesson1_prepare.sh
```

需要清理本机构建产物后完整验证时：

```bash
BUILD_TYPE=Debug ./scripts/linux/lesson1_prepare.sh --rebuild
```

LuaPanda 是 debug-only 工具链。安装/验证本地调试依赖：

```bash
./scripts/linux/bootstrap_luapanda.sh
```

VS Code 先启动 `server/debug/luapanda/launch.json.example` 中的 Gateway + Query 两个 target，然后：

```bash
./scripts/linux/debug_luapanda.sh
```

LuaPanda + gdb 同时跟踪：

```bash
./scripts/linux/debug_luapanda.sh --gdb
```

Gateway 使用 8818，Query 使用 8819。两个 Service 是两个独立 Lua State，因此必须是两个调试 target。正常 `run_server.sh start` 不设置 `LUA_PANDA_ENABLE`，不会加载 LuaPanda runtime。

完整断点顺序、故障排查和验收证据见第一课第 31 节。
