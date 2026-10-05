# FlyWow Navigation 抽取与旧目录迁移

本次按用户确认的功能模块目录实施：`gateway/` 聚合网络及 SDK，`navigation/` 聚合地图生产与导航运行时。Navigation 是 FlyWow 的功能模块，不创建第二层 Git submodule，也不创建新的 OS 进程。

## 1. 唯一源码与边界

FlyWow 开发源位于 WSL 主仓库子模块 `~/workspace/skynet-battle-navigation-commercial-learning/server/third_party/skynet-flywow`：

```text
gateway/
  lualib/flywow/gateway/
  service/gateway/flywow_gateway.lua
  native/gateway_crypto/
  clients/unity/
  clients/h5/
  tools/
  scripts/
navigation/
  lualib/flywow/navigation.lua
  native/grid_map/
  native/lua/
  unity/                    # com.flywow.navigation UPM Package
  tools/
  scripts/
scripts/module_paths.py
```

静态 BMAP/Grid、A*、区域范围搜索、smoothing、动态占位、独占 Context、Lua Binding 及 Unity 的地图配置、Bake、采样、Clearance、校验、Overlay、导出迁入 Navigation。框架不依赖课程仓库布局；候选输出目录由宿主明确填写。

Battle_1001 场景、出生点、Battle Tick、技能、Gateway/Battle 进程组装和 Replay 留在课程仓库。`BattleSpawnValidator` 通过同步导出校验事件追加课程规则；普通新工程无需安装该组件。

Unity 原脚本 GUID 保留；Scene 继续保存原地图 ID、版本、原点和 Cell 边长。课程 SceneBuilder 现在显式设置 Battle_1001 参数，避免通用包默认值改变课程地图。

## 2. 如何重新接入开发源

本次没有 commit/push，未把旧 submodule gitlink 宣称为新版本。WSL Server 明确选择开发源：

```bash
cd ~/workspace/skynet-battle-navigation-commercial-learning/server
FLYWOW_ROOT="$PWD/third_party/skynet-flywow" ./scripts/linux/run_server.sh build
FLYWOW_ROOT="$PWD/third_party/skynet-flywow" ./scripts/linux/run_server.sh start
FLYWOW_ROOT="$PWD/third_party/skynet-flywow" ./scripts/linux/run_server.sh stop
```

启动工具生成 `server/run/flywow_paths.lua`，通过 `FLYWOW_PATHS_CONFIG` 注入配置。临时 shutdownctl 也使用相同路径，不再依赖临时配置所在目录。`--modules gateway navigation` 一次选择模块，统一追加 lualib、Service 和 Native 搜索路径，不需要每个配置手工拼接多条路径。

Windows Unity 使用框架源生成的离线 UPM 包。从 Windows 主仓库根目录执行：

```powershell
./scripts/windows/Connect-FlyWowNavigation.ps1 -FlyWowRoot /home/simbi/workspace/skynet-battle-navigation-commercial-learning/server/third_party/skynet-flywow
```

该工具在 `.tmp/navigation-packages/` 生成按内容 SHA-256 命名的可复现 `.tgz`，更新课程工程 manifest 的相对 `file:` 依赖。它不复制维护源码，不启动 Editor。Windows PowerShell 5.1 的中文脚本使用 UTF-8 BOM，输出 JSON 使用 UTF-8 无 BOM；两者保持 LF。

给另一 Windows Unity 工程接入时指定 `-ProjectPath`；产物和工程应位于可形成相对路径的同一磁盘。纯 Unity Package Manager 接入也可选择 Add package from tarball。WSL UNC 文件夹直接作为 UPM `file:` 依赖在本机验证失败，因此使用离线包。

正式交付需要先发布验证后的 FlyWow 提交，再更新宿主固定 gitlink；Unity 同时锁定配套包产物或相同提交。开发归档不能代替正式版本交付。

## 3. 资产合同保持与增强

现有 `shared/navigation/battle_1001/battle_1001.bmap` 字节不变，仍是 BMAP V1。清单增加空间 `ground_2_5d`、坐标轴 `x,y_height,z` 和完整 BMAP 的 SHA-256：

```text
faf042e53f7765e8aadfbefea5d4de0104f18af206b87e44dcb155a35088ac00
```

新导出写入 `map-ID-vVERSION-HASH/` 完整候选目录；先在 staging 中写 BMAP 与 Manifest，最后以目录 rename 提交。导出不覆盖正在使用的正式地图；发布系统仍需按版本/hash 验证完整包。

FlyWow `navigation/tools/verify_asset.py` 校验文件长度、CRC、空间、原点、尺度、版本及 SHA-256。Native Reader 校验 BMAP，并在分配文件缓冲前拒绝超过 128 MiB 的文件。SHA-256 门禁在发布阶段执行，单独调用 `load_map` 不等于完成内容身份校验。

Windows 仍是共享导航资产编辑源；本次没有复制覆盖 WSL 的共享目录，也没有用文件复制代替 Git 同步。Server 集成测试使用 WSL 已有、同字节的 BMAP；新 Manifest 的发布门禁验证使用 Windows 编辑源资产。

## 4. 旧调用方迁移

Native 使用 `require "flywow.navigation"`，共享库改为 `flywow_navigation.so`。旧宿主 `native/grid_map/make_test.sh` 和 `native/lua_battle_nav/make.sh` 只保留委托框架构建的薄入口，不保留第二份算法。

Gateway 采用课程现有的 CommandId、最小 Envelope 和双向 `send_data` 合同。整理过程中发现早期 sibling 的 request_id/endpoint 合同与课程现行实现不一致，已明确统一实现、文档、测试及迁移决策，删除旧 endpoint。没有把两套不兼容合同并放在新目录。

接入验证还修正三处旧 Adapter 问题：Battle 自动战斗结果去除额外 `{ok,response}` 包装，让 Gateway 编码真实字段；Gateway Proxy 消费可信本地断线通知；第一课单进程 main 保留为显式本地 Adapter，转发 Query 与 Gateway 数据，Query 继续不依赖网络。

## 5. 阅读入口与已验证范围

框架内 `navigation/README.md`、`INTEGRATION.md`、`CONTRACT.md`、`UPGRADE.md` 分别说明目录、接入、公开接口及成套迁移。源码保留并整理 A*、smoothing、Clearance、footprint、移动复验、Lua 栈与 userdata 生命周期注释；Cell 中心计算补充直接关系、提取公因子步骤及数值例子。

本次验证结果：

- 独立 Native Debug 构建及两个 CTest 通过；导航测试包括确定性、动态占位与 Context 隔离等已有用例。
- FlyWow Python/Lua 回归通过，含真实固定 Lua 加载 `.so`、路径查询、Context 隔离和关闭拒绝。
- 纯 Package 隔离 Unity 工程的 11 项 EditMode 测试通过，覆盖新场景 Bake→采样→导出、幂等和损坏清单拒绝。
- 课程隔离 Unity 工程的 15 项测试通过，包括原 Scene 的 GUID 解析、地图参数、出生点及无 Missing Script。
- 完整真实 Gateway 集成通过 TCP、WebSocket、握手、异步消息、网络限制、单进程地图查询、双进程 Battle_1001 结果和 Cluster 主动关闭。
- Gateway/Battle 优雅关闭通过，测试进程按 owner 清理。

没有把 Editor 测试当作 Player/IL2CPP 验证，也没有把网络结果验证当作人工完整观看 Unity Replay。未做商业规模压测或长期 soak；CI 新增 Native 核心构建门禁，远端 CI 未执行。正式发布和两个主工作区的 Git 同步尚未执行。
