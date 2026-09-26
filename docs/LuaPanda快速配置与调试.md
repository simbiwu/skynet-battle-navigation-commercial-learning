# LuaPanda 快速配置与调试

本文是第一课的独立补充，面向已经准备好 Server 工程、只想快速接入 LuaPanda 的开发者。第一课正文不依赖本文，也不需要为了使用本文重新阅读完整课程。

## 1. 当前调试边界

LuaPanda 调试的是 Skynet Service 各自的 Lua State。一个 Service 一个 Lua State；同时调试多个 Service 时，每个 Lua State 必须连接不同的 TCP 端口。

当前第一课端口约定：

```text
Navigation Gateway Service -> 8818
Navigation Query Service   -> 8819
```

端口由 Service 启动入口显式传入 `luapanda_debug.start(port)`。公共模块不维护 `gateway/query` 角色表，新增 Service 不需要修改公共 LuaPanda 模块。

## 2. 必须使用 WSL 工作区

VS Code 必须打开 WSL 中的仓库根目录，而不是 Windows 盘符目录：

```text
/home/simbi/workspace/skynet-battle-navigation-commercial-learning
```

左侧资源管理器最顶层应显示：

```text
skynet-battle-navigation-commercial-learning
```

左下角应显示类似：

```text
WSL: Ubuntu
```

VS Code 命令面板执行：

```text
WSL: Reopen Folder in WSL
```

在 WSL 终端确认：

```bash
pwd
ls -l .vscode/launch.json
```

`pwd` 必须是上述 WSL 仓库根目录。LuaPanda 扩展也必须安装在当前 WSL 窗口；Windows 侧单独安装不够。

## 3. 第一次准备 LuaPanda 依赖

在 WSL 中进入 Server 目录：

```bash
cd /home/simbi/workspace/skynet-battle-navigation-commercial-learning/server
./scripts/linux/bootstrap_luapanda.sh
```

该脚本会按固定版本准备：

```text
server/third_party/luapanda
server/third_party/luasocket
server/third_party/luasocket-runtime
```

LuaSocket 必须使用当前工程 Skynet bundled Lua 的 Header 和 ABI 构建。不要从系统 Lua、其他项目或网上随意复制 `socket.core` / `pb.so`。

## 4. VS Code 调试配置

如果仓库根目录没有 `.vscode/launch.json`，复制模板：

```bash
cd /home/simbi/workspace/skynet-battle-navigation-commercial-learning
mkdir -p .vscode
cp server/debug/luapanda/launch.json.example .vscode/launch.json
```

当前配置应包含三个名称：

```text
LuaPanda Lesson1 Gateway       8818
LuaPanda Lesson1 Query         8819
LuaPanda Lesson1 Gateway + Query   compound
```

如果运行和调试下拉框只显示 `LuaPanda` 和 `LuaPanda-IndependentFile`，那是扩展的配置模板，不是课程 target。检查当前打开的目录是否为 WSL 仓库根目录，以及 `.vscode/launch.json` 是否确实存在。

## 5. 启动调试

先在 VS Code 的 Run and Debug 中启动：

```text
LuaPanda Lesson1 Gateway + Query
```

再在 WSL Server 终端执行：

```bash
cd /home/simbi/workspace/skynet-battle-navigation-commercial-learning/server
./scripts/linux/debug_luapanda.sh
```

脚本会：

1. 准备并验证 LuaPanda/LuaSocket 运行时；
2. 设置 `LUA_PANDA_ENABLE=1` 和 `LUA_PANDA_HOST`；
3. 前台启动 Skynet；
4. 由每个 Service 自己使用显式端口连接对应的 LuaPanda target。

正常日志应分别出现：

```text
LUA_PANDA_CONNECT host=127.0.0.1 port=8818
LUA_PANDA_READY port=8818
LUA_PANDA_CONNECT host=127.0.0.1 port=8819
LUA_PANDA_READY port=8819
```

## 6. 新增 Service 的配置

普通 Service 不需要 LuaPanda 时，不修改任何调试配置。

需要调试时，在新 Service 的启动入口中加载公共模块，并显式传入未占用端口。例如新增 `battle_worker`：

```lua
local skynet = require "skynet"
local luapanda_debug = require "debug.luapanda_debug"

skynet.start(function()
    -- 8820 只属于 battle_worker 的 Lua State。
    luapanda_debug.start(8820)

    -- Service 的正常初始化逻辑。
end)
```

然后只在仓库根目录 `.vscode/launch.json` 增加一个 target：

```json
{
  "type": "lua",
  "request": "launch",
  "name": "LuaPanda BattleWorker",
  "cwd": "${workspaceFolder}/server",
  "connectionPort": 8820,
  "stopOnEntry": false,
  "autoPathMode": true,
  "autoReconnect": true,
  "useCHook": false
}
```

不需要修改：

```text
server/lualib/debug/luapanda_debug.lua
server/scripts/linux/debug_luapanda.sh
```

如果要同时启动它，把 `LuaPanda BattleWorker` 加入 compound；如果只调试它，直接启动这个单独 target 即可。

## 7. 断点不命中

先确认：

- VS Code target 的 `connectionPort` 与 Service 传入的端口一致；
- 当前断点文件属于 WSL 工作区中的源码；
- 没有两个 target 使用同一个端口；
- Server 日志已经出现对应的 `LUA_PANDA_READY`；
- LuaPanda 扩展安装在当前 WSL 窗口。

LuaPanda 的诊断表达式必须在 VS Code 的“调试控制台”执行，不是在 WSL Terminal 或 Unity Console 中执行。

当前 target 默认：

```json
"stopOnEntry": false
```

若输入表达式没有反应，先临时把对应 target 改为：

```json
"stopOnEntry": true
```

重新启动调试，程序停住后，在“查看 -> 调试控制台”顶部选择具体的 Gateway、Query 或新 Service 会话，再输入：

```lua
LuaPanda.doctor()
```

使用 compound 时，Gateway 和 Query 必须分别选择会话并分别诊断。也可以先执行：

```lua
LuaPanda.getInfo()
```

确认当前调试控制台确实连接到了 LuaPanda Lua State。诊断结束后把 `stopOnEntry` 改回 `false`。

## 8. LuaPanda + gdb

需要同时调试 Lua 和 C++ 时：

```bash
./scripts/linux/debug_luapanda.sh --gdb
```

该模式仍由 LuaPanda 连接 Lua State，gdb 负责 C++ 断点。它不会改变 LuaPanda 端口分配，也不会替代普通 Server 的构建和进程管理。

## 9. 常见错误

### 只看到 LuaPanda 模板

当前 VS Code 没有加载仓库根目录 `.vscode/launch.json`。重新打开 WSL 仓库根目录并执行 `Developer: Reload Window`。

### `Unable to resolve reference` 或 LuaPanda 无法连接

重新执行：

```bash
./scripts/linux/bootstrap_luapanda.sh
```

不要复制系统 LuaSocket。LuaPanda 的 LuaSocket 必须与 Skynet bundled Lua ABI 匹配。

### 端口连接失败

检查：

```bash
ss -ltnp | grep -E '8818|8819|8820'
```

确认 VS Code 已先启动对应 target，Service 端口没有冲突，并且 `LUA_PANDA_HOST` 指向正确地址。

### 修改 Service 后没有断点

确认新 Service 启动入口实际执行了：

```lua
luapanda_debug.start(你的端口)
```

普通运行没有设置 `LUA_PANDA_ENABLE=1` 时，LuaPanda 是故意不启动的。
