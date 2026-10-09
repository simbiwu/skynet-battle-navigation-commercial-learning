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
  lualib/flywow_navigation.lua
  native/grid_map/
  native/lua/
  unity/                    # com.flywow.navigation UPM Package
  tools/
  scripts/
scripts/build_flywow.sh
```

静态 BMAP/Grid、A*、区域范围搜索、smoothing、动态占位、独占 Context、Lua Binding 及 Unity 的地图配置、Bake、采样、Clearance、校验、Overlay、导出迁入 Navigation。框架不依赖课程仓库布局；候选输出目录由宿主明确填写。

Battle_1001 场景、出生点、Battle Tick、技能、Gateway/Battle 进程组装和 Replay 留在课程仓库。`BattleSpawnValidator` 通过同步导出校验事件追加课程规则；普通新工程无需安装该组件。

Unity 原脚本 GUID 保留；Scene 继续保存原地图 ID、版本、原点和 Cell 边长。课程 SceneBuilder 现在显式设置 Battle_1001 参数，避免通用包默认值改变课程地图。

## 2. 当前构建与运行时配置

FlyWow 固定从主仓库 Server submodule 加载；不使用 FLYWOW_ROOT 覆盖目录，也不在构建时生成搜索路径 Lua 文件。从 Server 根目录执行：

~~~bash
./scripts/linux/run_server.sh build
~~~

入口调用 third_party/skynet-flywow/scripts/build_flywow.sh，三个 Native 模块统一输出到 third_party/skynet-flywow/build/native/，CMake 中间文件按模块放在 build/cmake/<module>/。

Gateway、Battle 和单进程配置直接列出自己需要的 lua_path、luaservice、lua_cpath、cpath 和 preload。路径相对 server/ 工作目录，因此阅读配置时能直接看见模块来源；不通过环境变量或生成器拼接。Gateway 只加入 Gateway 模块搜索路径，Battle 只加入 Navigation/Logger。

Server 设置为 WSL 唯一编辑源，FlyWow 通过主仓库固定 submodule 修改。Unity 仍在 Windows 编辑。正式交付时按 docs/WORKSPACE_WORKFLOW.md 的顺序发布 FlyWow 并更新主仓库 gitlink。

## 3. 资产合同保持与增强

现有 `shared/navigation/battle_1001/battle_1001.bmap` 字节不变，仍是 BMAP V1。清单增加空间 `ground_2_5d`、坐标轴 `x,y_height,z` 和完整 BMAP 的 SHA-256：

```text
faf042e53f7765e8aadfbefea5d4de0104f18af206b87e44dcb155a35088ac00
```

新导出写入 `map-ID-vVERSION-HASH/` 完整候选目录；先在 staging 中写 BMAP 与 Manifest，最后以目录 rename 提交。导出不覆盖正在使用的正式地图；发布系统仍需按版本/hash 验证完整包。

FlyWow `navigation/tools/verify_asset.py` 校验文件长度、CRC、空间、原点、尺度、版本及 SHA-256。Native Reader 校验 BMAP，并在分配文件缓冲前拒绝超过 128 MiB 的文件。SHA-256 门禁在发布阶段执行，单独调用 `load_map` 不等于完成内容身份校验。

Windows 仍是共享导航资产编辑源；本次没有复制覆盖 WSL 的共享目录，也没有用文件复制代替 Git 同步。Server 集成测试使用 WSL 已有、同字节的 BMAP；新 Manifest 的发布门禁验证使用 Windows 编辑源资产。

## 4. 旧调用方迁移

Lua 外部入口使用 `require "flywow_navigation"`，文件位于 `navigation/lualib/flywow_navigation.lua`；它继续加载 Native 模块 `flywow_navigation_native`，最终产物统一位于 `third_party/skynet-flywow/build/native/flywow_navigation_native.so`。

Gateway 采用课程现有的 CommandId、最小 Envelope 和双向 `send_data` 合同。整理过程中发现早期 sibling 的 request_id/endpoint 合同与课程现行实现不一致，已明确统一实现、文档、测试及迁移决策，删除旧 endpoint。没有把两套不兼容合同并放在新目录。

接入验证还修正三处旧 Adapter 问题：Battle 自动战斗结果去除额外 `{ok,response}` 包装，让 Gateway 编码真实字段；Gateway Proxy 消费可信本地断线通知；第一课单进程 main 保留为显式本地 Adapter，转发 Query 与 Gateway 数据，Query 继续不依赖网络。

## 5. 阅读入口与已验证范围

框架内 `navigation/README.md`、`导航接入指南.md`、`CONTRACT.md`、`UPGRADE.md` 分别说明目录、接入、公开接口及成套迁移。源码保留并整理 A*、smoothing、Clearance、footprint、移动复验、Lua 栈与 userdata 生命周期注释；Cell 中心计算补充直接关系、提取公因子步骤及数值例子。

本次验证结果：

- 独立 Native Debug 构建及两个 CTest 通过；导航测试包括确定性、动态占位与 Context 隔离等已有用例。
- FlyWow Python/Lua 回归通过，含真实固定 Lua 加载 `.so`、路径查询、Context 隔离和关闭拒绝。
- 纯 Package 隔离 Unity 工程的 11 项 EditMode 测试通过，覆盖新场景 Bake→采样→导出、幂等和损坏清单拒绝。
- 课程隔离 Unity 工程的 15 项测试通过，包括原 Scene 的 GUID 解析、地图参数、出生点及无 Missing Script。
- 完整真实 Gateway 集成通过 TCP、WebSocket、握手、异步消息、网络限制、单进程地图查询、双进程 Battle_1001 结果和 Cluster 主动关闭。
- Gateway/Battle 优雅关闭通过，测试进程按 owner 清理。

没有把 Editor 测试当作 Player/IL2CPP 验证，也没有把网络结果验证当作人工完整观看 Unity Replay。未做商业规模压测或长期 soak；CI 新增 Native 核心构建门禁，远端 CI 未执行。正式发布和两个主工作区的 Git 同步尚未执行。


### Battle 射程语义

普通攻击读取进程级共享配置 UnitProfile.combat.attack_range_mm，按攻击方与目标的中心点
XZ 距离判定，单位为整数毫米。该字段不读取、不叠加 NavigationProfile.radius_mm；
0 表示中心重合，近战单位应配置正数中心距。

NavigationProfile.radius_mm 只负责导航 footprint、占位和单位间可接近距离。
context:find_path_to_unit_range 不接收 attack_range_mm，只按双方导航半径之和确定
不可重叠的中心距下界，并用 ceil(sqrt(2)*cell_size_mm) 适配离散格子的接近终点。
路径推进期间 Battle 每 Tick 独立检查战斗射程；进入攻击中心距后停止移动并执行攻击。

UnitProfile 配置按稳定 unit_id 存放在进程级 sharedata；Navigation 专用字段在独立配置表中，
由 Navigation Registry 管理。两者不复制或互相派生。已有 Battle 每次攻击判定从当前
sharedata 配置读取；Native 导航调用从当前 NavigationProfile Registry 读取导航值。

本轮验证：统一构建入口通过，FlyWow 所有 Native 模块构建及各自 CTest 通过；
导航 Lua Binding 2 项和真实 Native Battle 射程回归通过。静态 A* Benchmark 与修改前同条件数据接近：
80x60 p50 112.5→105.3us，256x256 1253.3→1199.3us，512x512 4219.6→4215.4us。
该基准不覆盖 Battle 的 sharedata 读取或单位接近查询，因此不把它当作这两项的性能测量。
