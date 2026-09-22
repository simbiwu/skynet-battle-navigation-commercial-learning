# Skynet Battle Navigation 第一课实操：从 Unity 地图到 Skynet 查询

第一课完成一条可以亲手运行、调试和破坏测试的地图生产链。团结引擎中的 3D 场景先经过 NavMesh Authoring，再采样成单层 2.5D Grid；Exporter 写出带版本和 CRC 的 BMAP；WSL 中的 C++ Module 加载 BMAP，多个 Skynet QueryWorker 共享同一份 immutable GridMap；最后，Unity 用 Protobuf 发送 WorldPosition，Server 返回这个位置的可走性、高度、Area 和 Clearance。

```text
Tuanjie Scene
  -> NavMesh Authoring
  -> Grid Sampling / Validation
  -> BMAP V1
  -> C++ BMapReader / GridMap / MapRegistry
  -> Lua C Binding
  -> Skynet QueryWorker
  -> TCP + Protobuf
  -> Unity Server Query Window
```

这条链中有两个不同的数据边界：

```text
离线资产：Unity -> BMAP -> Server
运行消息：Unity <-> Protobuf <-> Skynet
```

不要把 BMAP 改成 Protobuf。BMAP 是大块、定长、可随机索引的导航资产；Protobuf 是运行时请求和响应。两者的版本、校验和失败路径都要明确。

本课正式出现：

```text
WorldPosition
GridPos
NavCell
BMapReader
GridMap
MapRegistry
Lua C Binding
Skynet Query Service
```

本课不实现：

```text
A*
AgentProfile
Path
NavigationContext
Dynamic Occupancy
BattleWorker
INavigationBackend
Detour
```

第三课会增加另一种导航实现，所以正式业务位置使用 WorldPosition，不把 GridPos 存成长期业务数据。第一课只需要记住这一句，不展开未来模块。

### 这份教程怎样分工

学习者以 Server 开发经验为前提，但不默认熟悉 Unity。为了避免把时间消耗在摆放模型上，仓库已经提供 `Battle_1001` 基础场景；其余与资产生产链有关的工作都由学习者按教程亲自完成。

```text
工程预先提供：基础场景几何、灯光、观察相机、双方出生点、基础 Collider

学习者实操：
打开工程
-> 安装并确认 Package
-> 理解 GameObject / Component / Collider
-> 添加并配置 NavMeshSurface
-> Bake 并观察结果
-> 运行 Grid Sampling / Validator
-> Export BMAP
-> 检查 manifest / CRC
-> 导入 Server
-> 编译、运行、调试和测试
```

Unity 专有名词首次用于操作前会解释“是什么、为什么需要、它影响哪条边界”。如果一个操作只改变显示、不影响 Server 资产，文档也会明确说明。

课程中的版本管理统一使用 VS Code 内置 Source Control 和 Git。此前主要使用 SVN 的学习者，先完成 [VS Code Git 实操：给长期使用 SVN 的开发者](VS_CODE_GIT_FOR_SVN.md)，尤其要理解 `Stage -> Commit -> Push` 与 SVN Commit 的区别。

## 1. 本课要完成的行为与四个终端

最终在 Unity 的 `Server Query` 窗口依次查询四个点：

```text
Ground       -> walkable=true，height_mm=0
CenterBlock  -> walkable=false
Slope        -> walkable=true，height_mm>0
Outside      -> error_code=OUT_OF_BOUNDS
```

同一个点会在三个位置显示同样的结果：

```text
Unity Scene Overlay
C++ Golden Query
Unity -> Skynet Protobuf Response
```

实操过程中保留四个终端：

```text
Windows PowerShell   检查 Editor、生成 C# Protobuf、查看 G 盘资产
WSL Build            编译 Skynet、lua-protobuf 和 battle_nav.so
WSL Server           运行 Skynet，不在这个终端继续执行构建命令
WSL Command          跑测试、查看端口、连接 Debug Console
```

Unity Editor 是第五个可观察现场。不要把 Server 长驻进程、构建命令和临时测试混在同一个 Terminal；否则报错以后很难知道当前目录、环境变量和进程属于哪一步。

## 2. 检查现有环境，不做破坏性重装

当前机器已经安装：

```text
Tuanjie Editor 1.10.0
Editor build 2022.3.62t12_ab02e98c9779
G:\Tuanjie\Editors\2022.3.62t12\Editor\Tuanjie.exe
```

Windows PowerShell：

```powershell
$editor = 'G:\Tuanjie\Editors\2022.3.62t12\Editor\Tuanjie.exe'
Get-Item -LiteralPath $editor |
    Select-Object FullName,
        @{Name='ProductVersion'; Expression={$_.VersionInfo.ProductVersion}}
Get-AuthenticodeSignature -LiteralPath $editor |
    Select-Object Status, StatusMessage
Get-PSDrive C,G |
    Select-Object Name,
        @{Name='FreeGB'; Expression={[math]::Round($_.Free / 1GB, 2)}}
```

预期 ProductVersion：

```text
2022.3.62t12_ab02e98c9779
```

Editor 已经在 G 盘，不重新通过 Hub 下载。若 Hub 的 Installs 页面没有自动列出它，使用 `Locate/定位` 并选择：

```text
G:\Tuanjie\Editors\2022.3.62t12\Editor\Tuanjie.exe
```

这只是让 Hub 记录一个已有 Editor，不会复制安装文件。

WSL Build 终端：

```bash
pwd
uname -a
cat /etc/os-release
g++ --version
cmake --version
make --version
git --version
gdb --version
```

再确认参考工程的开发环境存在，但不把它合并到新项目：

```bash
test -d /mnt/g/simbi/dev/skynet-slg-learning
find /mnt/g/simbi/dev/skynet-slg-learning -maxdepth 2 -type f \
  -name 'AGENTS.md' -o -name 'README.md'
```

`skynet-slg-learning` 只提供教学组织、依赖固定、Skynet ownership/yield、测试和调试方式。不要从中复制 Login、World、Region、H5 或双协议业务。

## 3. 固定目录：资料、Unity、Server 各有位置

```text
课程资料：
G:\simbi\dev\skynet-battle-navigation-commercial-learning

Unity 工程：
G:\simbi\dev\skynet-battle-navigation-commercial-learning\unity\BattleNavigation

Server 工程：
~/workspace/skynet-battle-navigation-server
```

为什么 Server 不放 `/mnt/g`：Skynet、CMake 和大量小文件编译在 WSL Linux 文件系统中更稳定，也避免 Windows/WSL 文件权限和文件监听差异。Unity 工程放 G 盘，因为 Editor、Library 和导入缓存体积大，C 盘空间有限。

Server 运行时也不直接读取 Unity Project。BMAP 从 Windows 产物目录显式导入到 Server 的 `maps/`，这一步就是课程里的最小资产发布动作。

### 3.1 给 Server 开发者的 Unity 名词表

这一课不要求你转型做客户端，但下面这些词会直接影响 Server 最终加载的地图。先建立一个后端视角的对应关系，后面的操作就不会变成机械点击。

#### Project（工程）

Unity Project 是包含 `Assets/`、`Packages/` 和 `ProjectSettings/` 的整个目录，可以类比成一个带依赖锁定和运行配置的 Server 仓库。

```text
Assets/          业务资源和 C# 脚本，类似 src/ + assets/
Packages/        Package 依赖声明和锁文件，类似 package manifest/lock
ProjectSettings/ 引擎级配置，类似服务配置与构建配置
Library/         本机导入缓存，类似 build cache，不提交 Git
```

#### Scene（场景）

`.unity` Scene 是一组对象及其配置的序列化文件。它不是图片，也不是 Server 地图文件。可以把它类比成“编辑器中的对象配置树”。

本课的 Scene 是：

```text
Assets/BattleNavigation/Scenes/Battle_1001.unity
```

Server 不读取 Scene。Scene 只是 BMAP 的上游 Authoring Source。

#### GameObject（游戏对象）

GameObject 本身主要提供名称、层级和开关，具体能力来自挂在它上面的 Component。可以类比成一个只有 identity 和 component list 的 Entity。

例如 `MainGround` 是 GameObject，它通过以下 Component 获得能力：

```text
Transform     位置、旋转、缩放
MeshFilter    使用什么几何网格
MeshRenderer  怎样显示
BoxCollider   怎样参与物理与导航采集
```

#### Component（组件）

Component 是挂在 GameObject 上的功能或数据单元，接近“组合优于继承”里的组件。`NavMeshSurface`、`BoxCollider` 和本课的 `BattleMapRoot` 都是 Component。

在 Inspector 里点击 `Add Component`，就是给当前 GameObject 增加一个组件实例。

#### Hierarchy（层级窗口）

Hierarchy 显示当前 Scene 中 GameObject 的父子树。父子关系会影响组织方式，也可能影响 Transform。它可以类比成进程内的一棵配置对象树，不是磁盘目录。

#### Inspector（属性窗口）

选中 GameObject 后，Inspector 显示该对象所有 Component 的字段。可以类比成管理后台里的结构化配置编辑器。修改后必须保存 Scene，否则重新打开会丢失。

#### Transform

每个 GameObject 都有 Transform：

```text
Position  世界或父节点局部位置
Rotation  旋转
Scale     缩放
```

Unity 默认用米，Server 本课正式协议用毫米。因此 `x=1.5` 米写入协议时是 `x_mm=1500`，不能让两端猜单位。

#### Mesh、Renderer 与 Material

```text
Mesh      物体的三角形几何形状
Renderer  把 Mesh 画到屏幕
Material  颜色、贴图和渲染方式
```

它们主要回答“玩家看见什么”。Server 导航不能只根据 Renderer 推断阻挡，因为装饰模型可能可穿过，也可能使用与实际阻挡不同的简化形状。

#### Collider（碰撞体）

Collider 是用于物理碰撞和空间占用的几何描述，例如 `BoxCollider`。在本课中它还是 NavMesh 的采集输入。

后端类比：Renderer 像展示 DTO，Collider 才像经过业务确认的判定数据。建筑看起来有墙，不代表 Server 可以从贴图推断墙；必须用 Collider 明确表达“这里阻挡”。

本课选择 `Use Geometry = Physics Colliders`，含义是：Bake 时读取 Collider，不读取视觉 Mesh。

#### Layer（层）与 Layer Mask（层掩码）

Layer 是 GameObject 的分类编号；Layer Mask 是“允许哪些分类参与本次操作”的位集合，类似权限 bit mask 或按类型过滤的数据源。

NavMeshSurface 的 Layer Mask 决定哪些对象会进入 Bake。若把特效、出生点标记或摄像机也采集进去，结果可能污染；若漏掉地面 Layer，Bake 后会没有蓝色区域。

#### Static（静态标记）

Static 表示对象不会在运行时移动，引擎可以对它做离线预处理。本课地面、墙、台地属于静态 Authoring 数据；动态战斗单位不属于它们。

不要把“Static”理解成 C++ `static` 变量。这里描述的是场景对象生命周期。

#### Package Manager

Package Manager 是 Unity 的依赖管理界面，作用接近 Conan/vcpkg/npm 的包管理器。本课用它安装固定版本的 AI Navigation，而不是从论坛随便下载一个脚本压缩包。

#### AI Navigation

AI Navigation 是提供 NavMesh Authoring 组件的 Unity Package。它解决的是离线导航表面构建与编辑器配置，不是 Server 运行时寻路库。

```text
AI Navigation != Recast/Detour Server Runtime
AI Navigation != BMAP
```

#### NavMesh

Navigation Mesh，导航网格。它用多边形表达角色能够站立和移动的表面。Scene View 中 Bake 成功后看到的蓝色区域就是可行走 NavMesh 的可视化。

本课不会把 Unity NavMesh 文件发给 Server。它只是 Unity 内的“可走性权威输入”，随后还要采样成 2.5D Grid。

#### NavMeshSurface

NavMeshSurface 是挂在 GameObject 上的 Authoring Component。它定义：

```text
为哪一种 Agent 构建
从哪些 GameObject 收集数据
收集 Renderer 还是 Collider
使用哪些 Layer
构建范围是什么
```

可以把它类比成离线地图构建任务的配置对象。没有它，构建输入和范围就不够显式、难以复现。

#### Agent

Agent 是在 NavMesh 上移动的角色模型，常见参数有半径、高度、最大坡度和可跨越台阶高度。它们会改变哪些地方能够 Bake 成可走区域。

第一课只用一个默认 Agent 验证地图，不提前引入业务 `AgentProfile`。两者不是同一个概念：Unity Agent 是 Authoring/Bake 参数；第二课的 `AgentProfile` 才是 Server 寻路约束。

#### Bake

Bake 是离线构建动作：读取 Scene 中符合规则的静态几何，计算出 NavMesh。

```text
Scene GameObject + Collider + Surface 配置
                    ↓ Bake
              Unity NavMesh
```

Bake 不是运行游戏，不是 BMAP Export，也不是 Server 寻路。它与“编译资产”更接近。

#### Scene View 与 Game View

```text
Scene View  编辑器工作视图，用来选对象、看 Collider 和 NavMesh
Game View   运行游戏时摄像机看到的画面
```

本课主要使用 Scene View。我们关心的是地图生产，不需要先做角色控制和漂亮画面。

#### Gizmo 与 Overlay

Gizmo 是只在编辑器中辅助观察的线框、图标或颜色标记；Overlay 是叠加显示的调试信息。它们帮助你检查采样格子和出生点，不进入 Server 资产。

#### Console

Console 是 Unity 的日志与编译错误窗口，接近 Server 日志终端。红色通常表示脚本编译或运行错误，黄色是警告。进入下一步前应先清理与本课有关的红色错误。

## 4. 创建 Unity 工程并固定 Package

当前仓库已经创建好 Unity 工程，不需要再在 Hub 中新建。使用下列 Editor 打开：

```text
Editor:  G:\Tuanjie\Editors\2022.3.62t12\Editor\Tuanjie.exe
Project: G:\simbi\dev\skynet-battle-navigation-commercial-learning\unity\BattleNavigation
```

### 4.1 第一次打开工程

可以从 Tuanjie Hub 选择 `Open` 并定位到 Project 目录，也可以直接运行 Editor 后选择工程。不要选择到 `Assets` 子目录；Project 根目录必须同时看到：

```text
Assets
Packages
ProjectSettings
```

第一次打开时 Editor 会生成 `Library/` 并编译 C#，可能需要几分钟。等待右下角进度结束，然后打开：

```text
Window -> General -> Console
```

成功标准：

```text
Console 没有红色 C# 编译错误；
Project 窗口能展开 Assets/BattleNavigation；
顶部没有一直停留在 Compiling 状态。
```

如果出现红色错误，先看最上面的第一条。后续错误常常只是第一条编译错误的连锁结果，不要从最后一条开始修。

### 4.2 亲自安装 AI Navigation 1.1.5

当前 `Packages/manifest.json` 没有预写 AI Navigation，安装动作留给你完成。打开：

```text
Window -> Package Manager
```

在 Package Manager 左上角点击 `+`，选择：

```text
Add package by name...
```

填写：

```text
Name:    com.unity.ai.navigation
Version: 1.1.5
```

点击 `Add`，等待 Package Manager 完成下载和脚本重编译。

为什么固定 `1.1.5`：课程截图、Inspector 字段和生成行为必须可复现。Package 小版本变化也可能改变默认参数或序列化字段；遇到不存在的版本时应先停止并记录错误，不能自行改装“最新版”。

安装完成后，在 Package Manager 的 `In Project` 列表里应看到 AI Navigation。再打开：

```text
G:\simbi\dev\skynet-battle-navigation-commercial-learning\unity\BattleNavigation\Packages\manifest.json
G:\simbi\dev\skynet-battle-navigation-commercial-learning\unity\BattleNavigation\Packages\packages-lock.json
```

`manifest.json` 中应出现：

```json
{
  "dependencies": {
    "com.unity.ai.navigation": "1.1.5"
  }
}
```

`packages-lock.json` 还会记录实际解析结果和依赖深度。不要只改 JSON 假装安装成功；必须让 Package Manager 完成解析，并确认 Console 没有编译错误。

如果 Package Manager 提示网络或 registry 错误：

1. 复制完整错误到运行笔记；
2. 不要删除整个 `Library/` 作为第一反应；
3. 不要从未知网站下载 `NavMeshSurface.cs` 放进 Assets；
4. 先确认 Tuanjie Hub 登录、网络和 Package Registry；
5. 仍失败时停在这里排查，不进入 Bake。

### 4.3 为什么不能跳过 Package 安装

内置 `com.unity.modules.ai` 提供运行时 NavMesh 基础 API，但本课需要 AI Navigation Package 提供的 `NavMeshSurface` Authoring 工作流。我们的目标不是让某台机器“勉强能 Bake”，而是让采集来源、范围和参数能保存在 Scene 中并接受版本控制。

工程已经包含 `.gitignore`，规则如下：

```gitignore
/Library/
/Temp/
/Obj/
/Logs/
/UserSettings/
/MemoryCaptures/
/Recordings/
/BuildArtifacts/

*.csproj
*.sln
*.user
*.pidb
*.booproj
*.svd
*.pdb
*.mdb
*.opendb
*.VC.db

.vs/
.vscode/
```

`Assets/`、`Packages/manifest.json`、`Packages/packages-lock.json` 和 `ProjectSettings/` 必须提交。`Library/` 可以从源文件恢复，不提交。

## 5. 创建 Server 空工程并固定 Skynet

WSL Build 终端：

```bash
mkdir -p ~/workspace/skynet-battle-navigation-server
cd ~/workspace/skynet-battle-navigation-server
git init
git branch -M main

mkdir -p \
  config \
  lualib/protocol \
  maps \
  native/grid_map/include \
  native/grid_map/src \
  native/grid_map/tests \
  protocol/generated \
  scripts/linux \
  service/nav \
  tests/protocol \
  tests/skynet
```

新建 `~/workspace/skynet-battle-navigation-server/.gitignore`：

```gitignore
/build/
/logs/
/tmp/
/third_party/skynet/
/third_party/lua-protobuf/
/third_party/lua-protobuf-runtime/
/protocol/generated/*.pb
*.so
*.o
core
core.*
```

新建 `scripts/linux/bootstrap_skynet.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

source_dir="third_party/skynet"
expected_tag="v1.8.0"

mkdir -p third_party

if [[ ! -d "$source_dir/.git" ]]; then
    if [[ -e "$source_dir" ]]; then
        echo "SKYNET_SOURCE_INVALID path=$source_dir" >&2
        exit 1
    fi

    git clone \
        --branch "$expected_tag" \
        --depth 1 \
        https://github.com/cloudwu/skynet.git \
        "$source_dir"
fi

actual_tag="$(git -C "$source_dir" describe --tags --exact-match HEAD 2>/dev/null || true)"
if [[ "$actual_tag" != "$expected_tag" ]]; then
    echo "SKYNET_VERSION_MISMATCH expected=$expected_tag actual=$actual_tag" >&2
    exit 1
fi

echo "SKYNET_SOURCE_OK tag=$actual_tag commit=$(git -C "$source_dir" rev-parse HEAD)"
```

新建 `scripts/linux/build_skynet.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

test -f third_party/skynet/Makefile
make -C third_party/skynet linux

test -x third_party/skynet/skynet
test -f third_party/skynet/3rd/lua/lua.h
echo "SKYNET_BUILD_OK"
```

赋予执行权限并运行：

```bash
chmod +x scripts/linux/bootstrap_skynet.sh scripts/linux/build_skynet.sh
./scripts/linux/bootstrap_skynet.sh
./scripts/linux/build_skynet.sh
```

脚本发现已有目录版本不符时只报错，不自动 reset、不删除用户文件。新项目需要自己的恢复脚本；“本机另一个仓库已经有 Skynet”不能代替当前项目的可复现依赖声明。

## 6. 创建 Battle_1001 场景

场景和基础 Authoring 脚本已经生成：

```text
Assets/BattleNavigation/Editor
Assets/BattleNavigation/Runtime
Assets/BattleNavigation/Scenes
Assets/BattleNavigation/Tests/Editor
```

保存场景：

```text
Assets/BattleNavigation/Scenes/Battle_1001.unity
```

实际层级：

```text
BattleMapRoot
├── Environment
│   ├── Ground
│   ├── StaticObstacles
│   └── Landmarks
├── SpawnPoints
├── Lighting
└── Authoring Camera
```

课程场景参数：

```text
MainGround    center=(0, -0.25, 0), scale=(30, 0.5, 20)
West/EastRamp 连接地面与两侧台地
CenterBlock   地图中央静态障碍
West/EastPillar 两侧静态障碍
Team1/2 Spawn 空 GameObject，只作为 Golden Point 标记
```

需要重建场景时使用：

```text
Tools -> Battle Navigation -> Create or Rebuild Battle_1001 Scene
```

该菜单会覆盖场景里的手工调整，交互模式下会先询问。先执行 `Validate Battle_1001 Authoring`，确认地图身份、网格范围、Collider 和双方出生点都正确。

从这里开始，地图转换必须由学习者亲自操作：安装/确认 AI Navigation Package、配置 NavMeshSurface、点击 Bake、检查 2.5D 限制、运行 Grid Sampling/Validator、执行 BMAP Export、核对 manifest/CRC，最后再导入 Server。自动化脚本不会替你完成这条生产链。

### 6.1 打开已经生成的场景

在 Project 窗口依次展开：

```text
Assets
-> BattleNavigation
-> Scenes
-> Battle_1001
```

双击 `Battle_1001`。如果 Unity 询问是否保存当前 Untitled Scene，当前空场景可以选择 `Don't Save`。

成功后 Hierarchy 顶层应看到 `BattleMapRoot`。在 Scene View 中按 `F` 可以把当前选中对象居中；如果画面中什么也没有，先在 Hierarchy 选中 `BattleMapRoot`，再把鼠标移到 Scene View 按 `F`。

为什么场景由工程预先生成：摆 Cube、调摄像机和颜色并不是本课程的教学目标，也不能帮助理解 Server 资产边界。你需要亲自理解的是这些几何怎样成为导航输入。

### 6.2 先运行 Authoring Validator

点击：

```text
Tools -> Battle Navigation -> Validate Battle_1001 Authoring
```

打开 Console，预期日志类似：

```text
BATTLE_1001_AUTHORING_OK map=battle_1001 version=1 grid=60x40 cell_mm=500 colliders=12 spawns=4
```

这一步还没有检查 NavMesh，也没有生成 BMAP。它只证明：地图身份、网格范围、基础 Collider 和双方出生点存在。将验证拆层后，未来出现错误时才能判断是 Scene Authoring、Bake、Sampling 还是 Export 出错。

### 6.3 亲自检查 Collider

在 Hierarchy 展开：

```text
BattleMapRoot
-> Environment
   -> Ground
   -> StaticObstacles
   -> Landmarks
```

依次选择 `MainGround`、`CenterBlock`、`WestRamp`、`WestPlateau`。在 Inspector 中确认每个对象都有 `Box Collider`。

检查时关注：

```text
Center       Collider 相对 GameObject 的局部中心
Size         Collider 的局部尺寸
Is Trigger   必须关闭；Trigger 不表达实体阻挡
Enabled      必须开启
```

点击 Inspector 中 Collider 组件的 `Edit Collider` 按钮，Scene View 会显示绿色线框和编辑手柄。线框应包住对应的地面、墙、坡道或台地。

为什么不直接采集 Renderer：

```text
Renderer = 展示事实
Collider = 导航/碰撞事实
```

商业项目的视觉模型经常有装饰细节、洞、复杂三角形或 LOD。用 Renderer 烘焙会让换皮和美术优化意外改变 Server 路径；用简化 Collider 可以把导航语义稳定下来。

出生点和相机不需要 Collider。动态单位也不能加入这批静态 Collider；它们将在第二课通过每场战斗独立的动态占位表达。

### 6.4 创建 Navigation 配置对象

在 Hierarchy 选中 `BattleMapRoot`，右键选择：

```text
Create Empty
```

把新对象重命名为：

```text
Navigation
```

为什么单独建对象：`NavMeshSurface` 是构建配置，不是地面本身。独立对象能把“地图几何”和“如何构建导航”分开，并让配置跟随 Scene 保存。

保持 Navigation 的 Transform 为：

```text
Position = (0, 0, 0)
Rotation = (0, 0, 0)
Scale    = (1, 1, 1)
```

如果数值被改过，点击 Transform 组件右上菜单，选择 `Reset`。Surface 的 Volume 范围使用这个 Transform 作为参考；不必要的缩放会让范围难以理解。

### 6.5 添加 NavMeshSurface

选中 `Navigation`，在 Inspector 点击：

```text
Add Component
```

搜索并添加：

```text
Nav Mesh Surface
```

如果搜不到：

```text
先确认 Package Manager 的 In Project 中存在 AI Navigation 1.1.5；
再确认 Console 没有红色编译错误；
不要继续创建同名 C# 脚本。
```

### 6.6 配置 NavMeshSurface

按下面的值配置：

```text
Agent Type      Humanoid（本课只使用一个默认 Bake Agent）
Collect Objects Volume
Use Geometry    Physics Colliders
Layer Mask      Default
Volume Center   (0, 4, 0)
Volume Size     (30, 12, 20)
```

不同版本 Inspector 的字段布局可能略有差异，但语义应一致。

逐项解释：

- `Agent Type`：决定 Bake 使用的半径、高度、坡度和台阶参数。本课只验证单一静态地图，不在这里教学 Server `AgentProfile`。
- `Collect Objects = Volume`：只采集一个明确盒状范围内的对象。相比 `All`，它不会因为 Scene 以后增加远处展示模型而悄悄改变地图。
- `Use Geometry = Physics Colliders`：以 Collider 为导航事实，忽略纯视觉 Mesh 细节。
- `Layer Mask = Default`：当前课程生成的地图几何都位于 Default Layer。相机和出生点没有 Collider，因此不会成为可走表面。
- `Volume Center/Size`：覆盖 30×20 米地图，并在 Y 方向容纳地面、坡道、台地和墙。

设置完按 `Ctrl+S` 保存 Scene。没有保存时，Inspector 看起来已修改，但重开 Scene 后配置可能消失。

### 6.7 点击 Bake 前先做 2.5D 检查

本课程的 BMAP 约束是：

```text
one XZ -> one walkable height
```

允许坡地、丘陵、台地和普通建筑障碍；不允许桥上+桥下、多层楼或地下+地面重叠。

在 Scene View 旋转观察场景，确认：

```text
没有可以同时从上层和下层行走的桥；
没有两个可进入楼层占用同一 XZ；
坡道只连接地面和一个台地；
台地下方没有可进入空间；
墙和柱子是实体阻挡。
```

为什么必须在 Bake 前检查：NavMesh 本身能够表达多层多边形，但第一课 BMAP 的单层 Grid 不能。等 Export 才发现多层冲突，会浪费排错时间；Exporter 仍必须再次检测并 Fail，不能静默挑一个高度。

### 6.8 亲自 Bake NavMesh

在 Hierarchy 选中 `Navigation`，找到 NavMeshSurface 组件底部的 `Bake` 按钮并点击。

Bake 会读取 Volume 内、Layer Mask 匹配且带 Collider 的对象，根据 Agent 参数生成导航多边形。它不会生成 Server 文件。

完成后 Scene View 应显示蓝色可行走区域。若没显示，确认 Scene View 顶部或右上角的 NavMesh/Gizmos 可视化已开启。

成功标准：

```text
MainGround 大部分区域为蓝色；
坡道与对应台地连续；
CenterBlock、Pillar 和四周墙附近留出不可走区域；
墙外没有意外的大片蓝色区域；
场景没有上下两层同时可走的区域。
```

这里不要追求蓝色区域贴住障碍边缘。Agent 有半径，中心点必须和墙保持距离；边缘缩进是正确行为。

### 6.9 Bake 后的典型问题

#### 完全没有蓝色区域

按顺序检查：

```text
AI Navigation Package 是否安装成功；
NavMeshSurface 是否在启用状态；
Collect Objects 的 Volume 是否覆盖地图；
Layer Mask 是否包含 Default；
Use Geometry 是否选择 Physics Colliders；
MainGround 的 BoxCollider 是否启用。
```

#### 障碍物上面也出现蓝色

这不一定是错误。建筑屋顶或台地顶部如果足够宽、坡度合法，NavMesh 会认为它可站立。需要判断它是否应该可到达：

- 如果是设计中的台地，应保留并确保有坡道连通；
- 如果是不可进入建筑顶部，应通过明确的导航 Area/Modifier 或 Authoring Collider 排除；
- 不要仅仅因为“不好看”就删除 Collider。

#### 坡道和地面之间断开

检查坡道 Collider 是否真的接触地面与台地，坡度是否超过 Agent Max Slope，以及高度差是否超过 Step Height。不要先增加 Server Grid 的邻接容差；问题仍在 Unity Authoring 阶段。

#### 障碍附近蓝色区域太窄或太宽

这通常由 Agent Radius 决定。第一课保持默认 Agent 参数并记录实际值，不为了某个截图反复微调。第二课出现真实单位尺寸需求后才引入业务侧 AgentProfile。

### 6.10 保存你的 Bake 结果

确认结果后按 `Ctrl+S`。检查 Project 窗口和 Scene 是否出现 NavMeshData 关联。关闭再重新打开 `Battle_1001`，确认蓝色结果仍可显示。

到这里你只完成了：

```text
Scene Authoring -> Unity NavMesh
```

还没有完成：

```text
Unity NavMesh -> Grid Snapshot -> BMAP -> Server
```

下一节开始实现和理解 `BattleMapRoot`、采样坐标、Validator 与 Writer。等工具代码准备完毕后，真正的 Sampling、Export 和 Server 导入仍由你亲自执行。

## 7. BattleMapRoot：不要从 Renderer 猜 Server Bounds

完整路径：

```text
Assets/BattleNavigation/Runtime/BattleMapRoot.cs
```

```csharp
using System;
using UnityEngine;

namespace BattleNavigation
{
    [DisallowMultipleComponent]
    public sealed class BattleMapRoot : MonoBehaviour
    {
        [Header("Identity")]
        [Min(1)] public uint mapId = 1001;
        [Min(1)] public uint mapVersion = 1;

        [Header("Grid in Unity meters")]
        public Vector2 originMeters = Vector2.zero;
        [Min(0.1f)] public float sizeXMeters = 40f;
        [Min(0.1f)] public float sizeZMeters = 30f;
        [Min(0.01f)] public float cellSizeMeters = 0.5f;

        [Header("Sampling")]
        public float sampleBaseYMeters = 0f;
        [Min(0.01f)] public float sampleRadiusMeters = 0.225f;
        [Min(0.01f)] public float multiLayerSeparationMeters = 0.25f;

        public int Width
        {
            get { return CheckedCellCount(sizeXMeters, cellSizeMeters, "sizeX"); }
        }

        public int Height
        {
            get { return CheckedCellCount(sizeZMeters, cellSizeMeters, "sizeZ"); }
        }

        public int CellSizeMm
        {
            get { return MetersToMillimeters(cellSizeMeters, "cellSize"); }
        }

        public int OriginXMm
        {
            get { return MetersToMillimeters(originMeters.x, "originX"); }
        }

        public int OriginZMm
        {
            get { return MetersToMillimeters(originMeters.y, "originZ"); }
        }

        public Vector3 GridToWorldCenter(int x, int z)
        {
            if (x < 0 || x >= Width || z < 0 || z >= Height)
            {
                throw new ArgumentOutOfRangeException(
                    string.Format("grid outside map: ({0},{1})", x, z));
            }

            return new Vector3(
                originMeters.x + (x + 0.5f) * cellSizeMeters,
                sampleBaseYMeters,
                originMeters.y + (z + 0.5f) * cellSizeMeters);
        }

        public void ValidateOrThrow()
        {
            if (mapId == 0 || mapVersion == 0)
            {
                throw new InvalidOperationException("mapId/mapVersion must be non-zero");
            }

            int width = Width;
            int height = Height;
            checked
            {
                _ = width * height;
                _ = width * height * BMapFormat.CellStride;
            }

            if (sampleRadiusMeters >= cellSizeMeters)
            {
                throw new InvalidOperationException(
                    "sampleRadiusMeters must be smaller than cellSizeMeters");
            }
        }

        private static int CheckedCellCount(float size, float cellSize, string field)
        {
            if (!float.IsFinite(size) || !float.IsFinite(cellSize) ||
                size <= 0f || cellSize <= 0f)
            {
                throw new InvalidOperationException(field + " contains invalid number");
            }

            double cells = size / cellSize;
            double rounded = Math.Round(cells, MidpointRounding.AwayFromZero);
            if (Math.Abs(cells - rounded) > 0.000001)
            {
                throw new InvalidOperationException(
                    field + " must be an integer multiple of cellSize");
            }

            return checked((int)rounded);
        }

        public static int MetersToMillimeters(float meters, string field)
        {
            if (!float.IsFinite(meters))
            {
                throw new InvalidOperationException(field + " is not finite");
            }

            return checked((int)Math.Round(
                meters * 1000.0,
                MidpointRounding.AwayFromZero));
        }
    }
}
```

`BattleMapRoot` 是 Authoring Contract。Renderer Bounds 会随着装饰模型、LOD 或临时对象变化，不能拿来决定 Server 原点和宽高。

## 8. 定义 NavCell 和 BMAP 常量

完整路径：

```text
Assets/BattleNavigation/Runtime/NavCell.cs
```

```csharp
namespace BattleNavigation
{
    public static class NavCellFlags
    {
        public const ushort Walkable = 1 << 0;
        public const ushort VisionBlock = 1 << 1;
        public const ushort SkillBlock = 1 << 2;
        public const ushort Water = 1 << 3;
    }

    public enum BattleArea : byte
    {
        Normal = 0,
        Mud = 1,
        Grass = 2,
        WaterShallow = 3,
    }

    public struct GridPos
    {
        public int x;
        public int z;

        public GridPos(int xValue, int zValue)
        {
            x = xValue;
            z = zValue;
        }
    }

    public struct NavCell
    {
        public int heightMm;
        public ushort flags;
        public byte areaType;
        public byte clearanceCells;

        public bool IsWalkable
        {
            get { return (flags & NavCellFlags.Walkable) != 0; }
        }
    }
}
```

完整路径：

```text
Assets/BattleNavigation/Runtime/BMapFormat.cs
```

```csharp
namespace BattleNavigation
{
    public static class BMapFormat
    {
        public const ushort FormatVersion = 1;
        public const ushort HeaderSize = 64;
        public const ushort CellStride = 8;

        public const int HeaderCrcOffset = 52;
        public const int MagicSize = 4;

        public static readonly byte[] Magic =
        {
            (byte)'B', (byte)'M', (byte)'A', (byte)'P'
        };
    }
}
```

Cell 的 8 bytes 是文件契约，不是 C# struct 内存布局。后面 Writer 逐字段写，Server 逐字段读。

## 9. 采样结果先留在内存，不边采边写文件

完整路径：

```text
Assets/BattleNavigation/Editor/BattleMapSnapshot.cs
```

```csharp
using System;

namespace BattleNavigation.Editor
{
    public sealed class BattleMapSnapshot
    {
        public uint mapId;
        public uint mapVersion;
        public int width;
        public int height;
        public int cellSizeMm;
        public int originXMm;
        public int originZMm;
        public NavCell[] cells = Array.Empty<NavCell>();

        public int IndexOf(int x, int z)
        {
            if (x < 0 || x >= width || z < 0 || z >= height)
            {
                throw new ArgumentOutOfRangeException(
                    string.Format("grid outside snapshot: ({0},{1})", x, z));
            }

            return checked(z * width + x);
        }

        public NavCell CellAt(int x, int z)
        {
            return cells[IndexOf(x, z)];
        }
    }
}
```

采样、校验、Overlay 和 Writer 都消费同一个 `BattleMapSnapshot`。Overlay 不能重新 Sample；否则画面上的绿色格子可能与写入 BMAP 的数据来自两次不同查询。

## 10. 单层采样：先证明一个 XZ 只有一个高度

完整路径：

```text
Assets/BattleNavigation/Editor/BattleMapSampler.cs
```

```csharp
using System;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.AI;

namespace BattleNavigation.Editor
{
    public static class BattleMapSampler
    {
        private struct HeightCandidate
        {
            public float y;

            public HeightCandidate(float yValue)
            {
                y = yValue;
            }
        }

        public static BattleMapSnapshot Sample(BattleMapRoot root)
        {
            if (root == null)
            {
                throw new ArgumentNullException(nameof(root));
            }

            root.ValidateOrThrow();

            NavMeshTriangulation triangulation = NavMesh.CalculateTriangulation();
            if (triangulation.vertices == null || triangulation.vertices.Length == 0 ||
                triangulation.indices == null || triangulation.indices.Length == 0)
            {
                throw new InvalidOperationException(
                    "NAVMESH_EMPTY: bake NavMeshSurface before export");
            }

            var snapshot = new BattleMapSnapshot
            {
                mapId = root.mapId,
                mapVersion = root.mapVersion,
                width = root.Width,
                height = root.Height,
                cellSizeMm = root.CellSizeMm,
                originXMm = root.OriginXMm,
                originZMm = root.OriginZMm,
                cells = new NavCell[checked(root.Width * root.Height)],
            };

            for (int z = 0; z < snapshot.height; ++z)
            {
                for (int x = 0; x < snapshot.width; ++x)
                {
                    Vector3 center = root.GridToWorldCenter(x, z);
                    List<HeightCandidate> candidates = CollectHeightCandidates(
                        triangulation,
                        center.x,
                        center.z,
                        root.multiLayerSeparationMeters);

                    if (candidates.Count > 1)
                    {
                        throw new InvalidOperationException(string.Format(
                            "MULTI_LAYER_NOT_SUPPORTED map={0} grid=({1},{2}) heights={3}",
                            root.mapId,
                            x,
                            z,
                            FormatHeights(candidates)));
                    }

                    NavCell cell = default;
                    if (candidates.Count == 1)
                    {
                        center.y = candidates[0].y;
                        if (!NavMesh.SamplePosition(
                                center,
                                out NavMeshHit hit,
                                root.sampleRadiusMeters,
                                NavMesh.AllAreas))
                        {
                            throw new InvalidOperationException(string.Format(
                                "NAVMESH_SAMPLE_INCONSISTENT grid=({0},{1}) candidate_y={2}",
                                x,
                                z,
                                candidates[0].y));
                        }

                        cell.flags = NavCellFlags.Walkable;
                        cell.heightMm = BattleMapRoot.MetersToMillimeters(
                            hit.position.y,
                            "sampleHeight");
                        cell.areaType = MapArea(hit.mask);
                    }

                    snapshot.cells[snapshot.IndexOf(x, z)] = cell;
                }
            }

            BattleMapClearance.Compute(snapshot);
            BattleMapValidator.ValidateSnapshot(root, snapshot);
            return snapshot;
        }

        private static List<HeightCandidate> CollectHeightCandidates(
            NavMeshTriangulation triangulation,
            float x,
            float z,
            float separation)
        {
            var result = new List<HeightCandidate>(2);
            Vector3[] vertices = triangulation.vertices;
            int[] indices = triangulation.indices;

            for (int i = 0; i < indices.Length; i += 3)
            {
                Vector3 a = vertices[indices[i]];
                Vector3 b = vertices[indices[i + 1]];
                Vector3 c = vertices[indices[i + 2]];

                if (!TryInterpolateY(a, b, c, x, z, out float y))
                {
                    continue;
                }

                bool sameLayer = false;
                for (int candidateIndex = 0;
                     candidateIndex < result.Count;
                     ++candidateIndex)
                {
                    if (Mathf.Abs(result[candidateIndex].y - y) <= separation)
                    {
                        sameLayer = true;
                        break;
                    }
                }

                if (!sameLayer)
                {
                    result.Add(new HeightCandidate(y));
                }
            }

            result.Sort((left, right) => left.y.CompareTo(right.y));
            return result;
        }

        private static bool TryInterpolateY(
            Vector3 a,
            Vector3 b,
            Vector3 c,
            float x,
            float z,
            out float y)
        {
            double v0x = b.x - a.x;
            double v0z = b.z - a.z;
            double v1x = c.x - a.x;
            double v1z = c.z - a.z;
            double v2x = x - a.x;
            double v2z = z - a.z;

            double denominator = v0x * v1z - v1x * v0z;
            if (Math.Abs(denominator) < 1e-10)
            {
                y = 0f;
                return false;
            }

            double u = (v2x * v1z - v1x * v2z) / denominator;
            double v = (v0x * v2z - v2x * v0z) / denominator;
            const double epsilon = 1e-6;
            if (u < -epsilon || v < -epsilon || u + v > 1.0 + epsilon)
            {
                y = 0f;
                return false;
            }

            y = (float)(a.y + u * (b.y - a.y) + v * (c.y - a.y));
            return true;
        }

        private static byte MapArea(int areaMask)
        {
            int areaIndex = -1;
            for (int bit = 0; bit < 32; ++bit)
            {
                if ((areaMask & (1 << bit)) != 0)
                {
                    areaIndex = bit;
                    break;
                }
            }

            if (areaIndex < 0)
            {
                throw new InvalidOperationException("NAVMESH_AREA_MISSING");
            }

            string areaName = NavMesh.GetAreaName(areaIndex);
            switch (areaName)
            {
                case "Walkable":
                case "Normal":
                    return (byte)BattleArea.Normal;
                case "Mud":
                    return (byte)BattleArea.Mud;
                case "Grass":
                    return (byte)BattleArea.Grass;
                case "WaterShallow":
                    return (byte)BattleArea.WaterShallow;
                default:
                    throw new InvalidOperationException(
                        "UNMAPPED_NAVMESH_AREA name=" + areaName);
            }
        }

        private static string FormatHeights(List<HeightCandidate> candidates)
        {
            var values = new string[candidates.Count];
            for (int i = 0; i < candidates.Count; ++i)
            {
                values[i] = BattleMapRoot.MetersToMillimeters(
                    candidates[i].y,
                    "candidateHeight").ToString();
            }
            return "[" + string.Join(",", values) + "]";
        }
    }
}
```

这里按每个 Cell 扫描全部 NavMesh Triangle，课程 80×60 小地图足以验证语义。生产大地图应先按 XZ 建 Triangle Bin 或 Tile Index，再用 Benchmark 决定数据结构；不能在没有测量条件时声称当前实现适用于任意地图规模。

`NavMesh.SamplePosition` 负责确认 Cell Center 附近存在实际可走位置，Triangulation 检查负责发现同一 XZ 的多层候选。搜索半径不能很大，否则墙内中心会吸附到墙外 NavMesh。

## 11. 计算静态 Clearance

完整路径：

```text
Assets/BattleNavigation/Editor/BattleMapClearance.cs
```

```csharp
using System;
using System.Collections.Generic;

namespace BattleNavigation.Editor
{
    public static class BattleMapClearance
    {
        private struct Node
        {
            public int x;
            public int z;

            public Node(int xValue, int zValue)
            {
                x = xValue;
                z = zValue;
            }
        }

        private static readonly int[] NeighborX =
        {
            -1, 0, 1,
            -1,    1,
            -1, 0, 1,
        };

        private static readonly int[] NeighborZ =
        {
            -1, -1, -1,
             0,      0,
             1,  1,  1,
        };

        public static void Compute(BattleMapSnapshot snapshot)
        {
            if (snapshot == null)
            {
                throw new ArgumentNullException(nameof(snapshot));
            }

            int cellCount = checked(snapshot.width * snapshot.height);
            if (snapshot.cells == null || snapshot.cells.Length != cellCount)
            {
                throw new InvalidOperationException("CLEARANCE_CELL_COUNT_MISMATCH");
            }

            var distance = new int[cellCount];
            Array.Fill(distance, int.MaxValue);
            var queue = new Queue<Node>(cellCount);

            for (int z = 0; z < snapshot.height; ++z)
            {
                for (int x = 0; x < snapshot.width; ++x)
                {
                    int index = snapshot.IndexOf(x, z);
                    bool boundary = x == 0 || z == 0 ||
                        x == snapshot.width - 1 || z == snapshot.height - 1;

                    if (!snapshot.cells[index].IsWalkable)
                    {
                        distance[index] = 0;
                        queue.Enqueue(new Node(x, z));
                    }
                    else if (boundary)
                    {
                        // 地图外视为静态不可走；边缘可走格离外部障碍一格。
                        distance[index] = 1;
                        queue.Enqueue(new Node(x, z));
                    }
                }
            }

            while (queue.Count > 0)
            {
                Node current = queue.Dequeue();
                int currentIndex = snapshot.IndexOf(current.x, current.z);
                int nextDistance = distance[currentIndex] + 1;

                for (int direction = 0; direction < NeighborX.Length; ++direction)
                {
                    int nextX = current.x + NeighborX[direction];
                    int nextZ = current.z + NeighborZ[direction];
                    if (nextX < 0 || nextX >= snapshot.width ||
                        nextZ < 0 || nextZ >= snapshot.height)
                    {
                        continue;
                    }

                    int nextIndex = snapshot.IndexOf(nextX, nextZ);
                    if (nextDistance >= distance[nextIndex])
                    {
                        continue;
                    }

                    distance[nextIndex] = nextDistance;
                    queue.Enqueue(new Node(nextX, nextZ));
                }
            }

            for (int index = 0; index < cellCount; ++index)
            {
                NavCell cell = snapshot.cells[index];
                cell.clearanceCells = cell.IsWalkable
                    ? (byte)Math.Min(distance[index], byte.MaxValue)
                    : (byte)0;
                snapshot.cells[index] = cell;
            }
        }
    }
}
```

这个 8 邻域距离给出保守的格子 Clearance。它不是连续空间精确欧氏距离。本课先把它作为地图属性导出；第二课出现不同体型以后，再说明 Agent 半径如何消费它。

动态单位绝不能写入 `snapshot.cells`。BMAP 是共享静态地图，Battle 内单位占位要等第二课出现真实需求时再加入。

## 12. Validator 先于 Writer

完整路径：

```text
Assets/BattleNavigation/Runtime/BattleSpawnPoint.cs
```

```csharp
using UnityEngine;

namespace BattleNavigation
{
    [DisallowMultipleComponent]
    public sealed class BattleSpawnPoint : MonoBehaviour
    {
        [Min(1)] public uint spawnId = 1;
    }
}
```

给 SpawnA、SpawnB 各挂一个组件，`spawnId` 分别设为 1、2。

完整路径：

```text
Assets/BattleNavigation/Editor/BattleMapValidator.cs
```

```csharp
using System;
using System.Collections.Generic;
using UnityEngine;

namespace BattleNavigation.Editor
{
    public static class BattleMapValidator
    {
        public static void ValidateSnapshot(
            BattleMapRoot root,
            BattleMapSnapshot snapshot)
        {
            if (root == null || snapshot == null)
            {
                throw new ArgumentNullException("root/snapshot");
            }

            if (snapshot.mapId != root.mapId ||
                snapshot.mapVersion != root.mapVersion ||
                snapshot.width != root.Width ||
                snapshot.height != root.Height ||
                snapshot.cellSizeMm != root.CellSizeMm)
            {
                throw new InvalidOperationException("SNAPSHOT_METADATA_MISMATCH");
            }

            int expectedCount = checked(snapshot.width * snapshot.height);
            if (snapshot.cells == null || snapshot.cells.Length != expectedCount)
            {
                throw new InvalidOperationException("SNAPSHOT_CELL_COUNT_MISMATCH");
            }

            int walkableCount = 0;
            int minHeight = int.MaxValue;
            int maxHeight = int.MinValue;
            for (int i = 0; i < snapshot.cells.Length; ++i)
            {
                NavCell cell = snapshot.cells[i];
                if (!cell.IsWalkable)
                {
                    continue;
                }

                ++walkableCount;
                minHeight = Math.Min(minHeight, cell.heightMm);
                maxHeight = Math.Max(maxHeight, cell.heightMm);
                if (cell.clearanceCells == 0)
                {
                    throw new InvalidOperationException(
                        "WALKABLE_CELL_WITH_ZERO_CLEARANCE index=" + i);
                }
            }

            if (walkableCount == 0)
            {
                throw new InvalidOperationException("MAP_HAS_NO_WALKABLE_CELL");
            }

            float walkableRatio = (float)walkableCount / expectedCount;
            if (walkableRatio < 0.05f || walkableRatio > 0.99f)
            {
                Debug.LogWarning(string.Format(
                    "Suspicious walkable ratio: {0:P2}",
                    walkableRatio));
            }

            ValidateSpawnPoints(root, snapshot);
            Debug.Log(string.Format(
                "MAP_VALIDATE_OK map={0} version={1} size={2}x{3} " +
                "walkable={4} min_height_mm={5} max_height_mm={6}",
                snapshot.mapId,
                snapshot.mapVersion,
                snapshot.width,
                snapshot.height,
                walkableCount,
                minHeight,
                maxHeight));
        }

        private static void ValidateSpawnPoints(
            BattleMapRoot root,
            BattleMapSnapshot snapshot)
        {
            BattleSpawnPoint[] points = UnityEngine.Object.FindObjectsByType<BattleSpawnPoint>(
                FindObjectsSortMode.None);
            if (points.Length < 2)
            {
                throw new InvalidOperationException("SPAWN_POINT_MISSING expected>=2");
            }

            var ids = new HashSet<uint>();
            foreach (BattleSpawnPoint point in points)
            {
                if (point.spawnId == 0 || !ids.Add(point.spawnId))
                {
                    throw new InvalidOperationException(
                        "SPAWN_ID_INVALID_OR_DUPLICATE id=" + point.spawnId);
                }

                int worldXMm = BattleMapRoot.MetersToMillimeters(
                    point.transform.position.x,
                    "spawnX");
                int worldZMm = BattleMapRoot.MetersToMillimeters(
                    point.transform.position.z,
                    "spawnZ");
                int gridX = FloorDiv(worldXMm - snapshot.originXMm, snapshot.cellSizeMm);
                int gridZ = FloorDiv(worldZMm - snapshot.originZMm, snapshot.cellSizeMm);

                if (gridX < 0 || gridX >= snapshot.width ||
                    gridZ < 0 || gridZ >= snapshot.height)
                {
                    throw new InvalidOperationException(
                        "SPAWN_OUT_OF_BOUNDS id=" + point.spawnId);
                }

                if (!snapshot.CellAt(gridX, gridZ).IsWalkable)
                {
                    throw new InvalidOperationException(
                        "SPAWN_NOT_WALKABLE id=" + point.spawnId);
                }
            }
        }

        internal static int FloorDiv(int value, int divisor)
        {
            if (divisor <= 0)
            {
                throw new ArgumentOutOfRangeException(nameof(divisor));
            }

            int quotient = value / divisor;
            int remainder = value % divisor;
            if (remainder != 0 && value < 0)
            {
                --quotient;
            }
            return quotient;
        }
    }
}
```

`FindObjectsByType` 是 2022.3 API。如果本机团结补丁只暴露旧 API，改为 `FindObjectsOfType<BattleSpawnPoint>()` 并在文档运行记录中写明实际 API；不要静默换版本。

## 13. CRC32 和显式 Little Endian Writer

完整路径：

```text
Assets/BattleNavigation/Editor/BMapCrc32.cs
```

```csharp
using System;

namespace BattleNavigation.Editor
{
    public static class BMapCrc32
    {
        private static readonly uint[] Table = BuildTable();

        public static uint Compute(byte[] bytes)
        {
            if (bytes == null)
            {
                throw new ArgumentNullException(nameof(bytes));
            }
            return Compute(bytes, 0, bytes.Length);
        }

        public static uint Compute(byte[] bytes, int offset, int count)
        {
            if (bytes == null)
            {
                throw new ArgumentNullException(nameof(bytes));
            }
            if (offset < 0 || count < 0 || offset > bytes.Length - count)
            {
                throw new ArgumentOutOfRangeException("offset/count");
            }

            uint crc = 0xffffffffu;
            for (int i = offset; i < offset + count; ++i)
            {
                crc = Table[(crc ^ bytes[i]) & 0xffu] ^ (crc >> 8);
            }
            return crc ^ 0xffffffffu;
        }

        private static uint[] BuildTable()
        {
            var table = new uint[256];
            for (uint value = 0; value < table.Length; ++value)
            {
                uint entry = value;
                for (int bit = 0; bit < 8; ++bit)
                {
                    entry = (entry & 1u) != 0
                        ? 0xedb88320u ^ (entry >> 1)
                        : entry >> 1;
                }
                table[value] = entry;
            }
            return table;
        }
    }
}
```

CRC 使用常见的 reflected CRC-32/ISO-HDLC 多项式。Unity Writer 和 C++ Reader 必须用同一组 Golden Bytes 验证，不能只各自对自己的输出通过。

完整路径：

```text
Assets/BattleNavigation/Editor/BMapLittleEndian.cs
```

```csharp
using System;

namespace BattleNavigation.Editor
{
    public static class BMapLittleEndian
    {
        public static void WriteU16(byte[] target, int offset, ushort value)
        {
            Require(target, offset, 2);
            target[offset] = (byte)value;
            target[offset + 1] = (byte)(value >> 8);
        }

        public static void WriteU32(byte[] target, int offset, uint value)
        {
            Require(target, offset, 4);
            target[offset] = (byte)value;
            target[offset + 1] = (byte)(value >> 8);
            target[offset + 2] = (byte)(value >> 16);
            target[offset + 3] = (byte)(value >> 24);
        }

        public static void WriteI32(byte[] target, int offset, int value)
        {
            WriteU32(target, offset, unchecked((uint)value));
        }

        public static ushort ReadU16(byte[] source, int offset)
        {
            Require(source, offset, 2);
            return (ushort)(source[offset] | source[offset + 1] << 8);
        }

        public static uint ReadU32(byte[] source, int offset)
        {
            Require(source, offset, 4);
            return (uint)(
                source[offset] |
                source[offset + 1] << 8 |
                source[offset + 2] << 16 |
                source[offset + 3] << 24);
        }

        private static void Require(byte[] bytes, int offset, int size)
        {
            if (bytes == null || offset < 0 || size < 0 ||
                offset > bytes.Length - size)
            {
                throw new ArgumentOutOfRangeException("binary range");
            }
        }
    }
}
```

这里没有使用 `BitConverter`，因为它跟随宿主机字节序。课程机器虽然是 Little Endian，也要把文件格式的字节序写进代码。

## 14. BMAP Writer、回读校验和 Manifest

完整路径：

```text
Assets/BattleNavigation/Editor/BMapWriter.cs
```

```csharp
using System;
using System.IO;

namespace BattleNavigation.Editor
{
    public static class BMapWriter
    {
        public static void Write(BattleMapSnapshot snapshot, string path)
        {
            if (snapshot == null)
            {
                throw new ArgumentNullException(nameof(snapshot));
            }
            if (string.IsNullOrWhiteSpace(path))
            {
                throw new ArgumentException("output path is empty", nameof(path));
            }

            int cellCount = checked(snapshot.width * snapshot.height);
            if (snapshot.cells == null || snapshot.cells.Length != cellCount)
            {
                throw new InvalidOperationException("BMAP_CELL_COUNT_MISMATCH");
            }

            int payloadSize = checked(cellCount * BMapFormat.CellStride);
            var payload = new byte[payloadSize];
            for (int index = 0; index < cellCount; ++index)
            {
                int offset = index * BMapFormat.CellStride;
                NavCell cell = snapshot.cells[index];
                BMapLittleEndian.WriteI32(payload, offset, cell.heightMm);
                BMapLittleEndian.WriteU16(payload, offset + 4, cell.flags);
                payload[offset + 6] = cell.areaType;
                payload[offset + 7] = cell.clearanceCells;
            }

            uint payloadCrc = BMapCrc32.Compute(payload);
            byte[] header = BuildHeader(snapshot, payloadSize, payloadCrc);
            uint headerCrc = BMapCrc32.Compute(header);
            BMapLittleEndian.WriteU32(
                header,
                BMapFormat.HeaderCrcOffset,
                headerCrc);

            string fullPath = Path.GetFullPath(path);
            string directory = Path.GetDirectoryName(fullPath)
                ?? throw new InvalidOperationException("output directory missing");
            Directory.CreateDirectory(directory);

            string temporaryPath = fullPath + ".tmp";
            using (var stream = new FileStream(
                       temporaryPath,
                       FileMode.Create,
                       FileAccess.Write,
                       FileShare.None))
            {
                stream.Write(header, 0, header.Length);
                stream.Write(payload, 0, payload.Length);
                stream.Flush(true);
            }

            Verify(temporaryPath);
            if (File.Exists(fullPath))
            {
                File.Replace(temporaryPath, fullPath, null);
            }
            else
            {
                File.Move(temporaryPath, fullPath);
            }
        }

        public static void Verify(string path)
        {
            byte[] file = File.ReadAllBytes(path);
            if (file.Length < BMapFormat.HeaderSize)
            {
                throw new InvalidDataException("BMAP_TRUNCATED_HEADER");
            }

            for (int i = 0; i < BMapFormat.MagicSize; ++i)
            {
                if (file[i] != BMapFormat.Magic[i])
                {
                    throw new InvalidDataException("BMAP_BAD_MAGIC");
                }
            }

            ushort version = BMapLittleEndian.ReadU16(file, 4);
            ushort headerSize = BMapLittleEndian.ReadU16(file, 6);
            uint payloadSize = BMapLittleEndian.ReadU32(file, 44);
            uint expectedPayloadCrc = BMapLittleEndian.ReadU32(file, 48);
            uint expectedHeaderCrc = BMapLittleEndian.ReadU32(file, 52);

            if (version != BMapFormat.FormatVersion ||
                headerSize != BMapFormat.HeaderSize)
            {
                throw new InvalidDataException("BMAP_HEADER_VERSION_OR_SIZE");
            }
            if (payloadSize != file.Length - headerSize)
            {
                throw new InvalidDataException("BMAP_PAYLOAD_SIZE_MISMATCH");
            }

            byte[] header = new byte[headerSize];
            Buffer.BlockCopy(file, 0, header, 0, header.Length);
            BMapLittleEndian.WriteU32(header, BMapFormat.HeaderCrcOffset, 0);
            if (BMapCrc32.Compute(header) != expectedHeaderCrc)
            {
                throw new InvalidDataException("BMAP_HEADER_CRC_MISMATCH");
            }
            if (BMapCrc32.Compute(file, headerSize, checked((int)payloadSize)) !=
                expectedPayloadCrc)
            {
                throw new InvalidDataException("BMAP_PAYLOAD_CRC_MISMATCH");
            }
        }

        private static byte[] BuildHeader(
            BattleMapSnapshot snapshot,
            int payloadSize,
            uint payloadCrc)
        {
            var header = new byte[BMapFormat.HeaderSize];
            Buffer.BlockCopy(BMapFormat.Magic, 0, header, 0, 4);
            BMapLittleEndian.WriteU16(header, 4, BMapFormat.FormatVersion);
            BMapLittleEndian.WriteU16(header, 6, BMapFormat.HeaderSize);
            BMapLittleEndian.WriteU32(header, 8, snapshot.mapId);
            BMapLittleEndian.WriteU32(header, 12, snapshot.mapVersion);
            BMapLittleEndian.WriteU32(header, 16, checked((uint)snapshot.width));
            BMapLittleEndian.WriteU32(header, 20, checked((uint)snapshot.height));
            BMapLittleEndian.WriteU32(header, 24, checked((uint)snapshot.cellSizeMm));
            BMapLittleEndian.WriteI32(header, 28, snapshot.originXMm);
            BMapLittleEndian.WriteI32(header, 32, snapshot.originZMm);
            BMapLittleEndian.WriteU32(header, 36, 0);
            BMapLittleEndian.WriteU16(header, 40, BMapFormat.CellStride);
            BMapLittleEndian.WriteU16(header, 42, 0);
            BMapLittleEndian.WriteU32(header, 44, checked((uint)payloadSize));
            BMapLittleEndian.WriteU32(header, 48, payloadCrc);
            BMapLittleEndian.WriteU32(header, 52, 0);
            // 56..63 reserved，new byte[] 已经清零。
            return header;
        }
    }
}
```

完整路径：

```text
Assets/BattleNavigation/Editor/BMapManifestWriter.cs
```

```csharp
using System;
using System.IO;
using UnityEngine;

namespace BattleNavigation.Editor
{
    public static class BMapManifestWriter
    {
        [Serializable]
        private sealed class Manifest
        {
            public uint format_version;
            public uint map_id;
            public uint map_version;
            public int width;
            public int height;
            public int cell_size_mm;
            public int[] origin_mm = Array.Empty<int>();
            public string payload_crc32 = string.Empty;
            public int walkable_cells;
            public int blocked_cells;
            public int min_height_mm;
            public int max_height_mm;
        }

        public static void Write(BattleMapSnapshot snapshot, string bmapPath)
        {
            byte[] bmap = File.ReadAllBytes(bmapPath);
            uint payloadCrc = BMapLittleEndian.ReadU32(bmap, 48);
            int walkable = 0;
            int minHeight = int.MaxValue;
            int maxHeight = int.MinValue;

            foreach (NavCell cell in snapshot.cells)
            {
                if (!cell.IsWalkable)
                {
                    continue;
                }
                ++walkable;
                minHeight = Math.Min(minHeight, cell.heightMm);
                maxHeight = Math.Max(maxHeight, cell.heightMm);
            }

            var manifest = new Manifest
            {
                format_version = BMapFormat.FormatVersion,
                map_id = snapshot.mapId,
                map_version = snapshot.mapVersion,
                width = snapshot.width,
                height = snapshot.height,
                cell_size_mm = snapshot.cellSizeMm,
                origin_mm = new[] { snapshot.originXMm, snapshot.originZMm },
                payload_crc32 = payloadCrc.ToString("X8"),
                walkable_cells = walkable,
                blocked_cells = snapshot.cells.Length - walkable,
                min_height_mm = minHeight,
                max_height_mm = maxHeight,
            };

            string manifestPath = Path.ChangeExtension(bmapPath, ".manifest.json");
            File.WriteAllText(manifestPath, JsonUtility.ToJson(manifest, true) + "\n");
        }
    }
}
```

JSON Manifest 供人和 CI 查看，不参与 Server Runtime 加载。Server 的权威输入只有通过校验的 BMAP。

## 15. Editor 菜单：采样、校验、写入、再回读

完整路径：

```text
Assets/BattleNavigation/Editor/BattleMapExporter.cs
```

```csharp
using System;
using System.IO;
using UnityEditor;
using UnityEngine;

namespace BattleNavigation.Editor
{
    public static class BattleMapExporter
    {
        public static BattleMapSnapshot LastSnapshot { get; private set; }

        [MenuItem("Tools/Battle Navigation/Export BMAP")]
        public static void Export()
        {
            try
            {
                BattleMapRoot[] roots = UnityEngine.Object.FindObjectsByType<BattleMapRoot>(
                    FindObjectsSortMode.None);
                if (roots.Length != 1)
                {
                    throw new InvalidOperationException(
                        "BATTLE_MAP_ROOT_COUNT expected=1 actual=" + roots.Length);
                }

                BattleMapSnapshot snapshot = BattleMapSampler.Sample(roots[0]);
                string outputDirectory = Path.GetFullPath(Path.Combine(
                    Application.dataPath,
                    "..",
                    "BuildArtifacts",
                    "Navigation"));
                string bmapPath = Path.Combine(
                    outputDirectory,
                    string.Format("battle_{0}.bmap", snapshot.mapId));

                BMapWriter.Write(snapshot, bmapPath);
                BMapManifestWriter.Write(snapshot, bmapPath);
                LastSnapshot = snapshot;
                SceneView.RepaintAll();

                Debug.Log(string.Format(
                    "BMAP_EXPORT_OK path={0} map={1} version={2} size={3}x{4}",
                    bmapPath,
                    snapshot.mapId,
                    snapshot.mapVersion,
                    snapshot.width,
                    snapshot.height));
            }
            catch (Exception exception)
            {
                Debug.LogError("BMAP_EXPORT_FAILED " + exception);
                throw;
            }
        }
    }
}
```

第一次执行：

```text
Tools -> Battle Navigation -> Export BMAP
```

预期输出：

```text
G:\simbi\dev\skynet-battle-navigation-unity\BuildArtifacts\Navigation\battle_1001.bmap
G:\simbi\dev\skynet-battle-navigation-unity\BuildArtifacts\Navigation\battle_1001.manifest.json
```

PowerShell 检查大小和 Hash：

```powershell
$dir = 'G:\simbi\dev\skynet-battle-navigation-unity\BuildArtifacts\Navigation'
Get-Item -LiteralPath "$dir\battle_1001.bmap"
Get-Content -LiteralPath "$dir\battle_1001.manifest.json" -Raw
Get-FileHash -LiteralPath "$dir\battle_1001.bmap" -Algorithm SHA256
```

80×60、每 Cell 8 bytes、Header 64 bytes 时，文件大小应为：

```text
64 + 80 * 60 * 8 = 38464 bytes
```

若不是这个值，先检查 width、height 和 cell_stride，不要直接改测试期望。

## 16. Scene Overlay 使用同一份 Snapshot

完整路径：

```text
Assets/BattleNavigation/Editor/BattleMapOverlay.cs
```

```csharp
using UnityEditor;
using UnityEngine;

namespace BattleNavigation.Editor
{
    [InitializeOnLoad]
    public static class BattleMapOverlay
    {
        private static bool enabled = true;

        static BattleMapOverlay()
        {
            SceneView.duringSceneGui += Draw;
        }

        [MenuItem("Tools/Battle Navigation/Toggle Overlay")]
        private static void Toggle()
        {
            enabled = !enabled;
            SceneView.RepaintAll();
        }

        private static void Draw(SceneView sceneView)
        {
            if (!enabled || BattleMapExporter.LastSnapshot == null)
            {
                return;
            }

            BattleMapSnapshot snapshot = BattleMapExporter.LastSnapshot;
            float cellSize = snapshot.cellSizeMm / 1000f;
            float originX = snapshot.originXMm / 1000f;
            float originZ = snapshot.originZMm / 1000f;

            for (int z = 0; z < snapshot.height; ++z)
            {
                for (int x = 0; x < snapshot.width; ++x)
                {
                    NavCell cell = snapshot.CellAt(x, z);
                    float y = cell.heightMm / 1000f + 0.03f;
                    Vector3 center = new Vector3(
                        originX + (x + 0.5f) * cellSize,
                        y,
                        originZ + (z + 0.5f) * cellSize);
                    float half = cellSize * 0.47f;
                    var corners = new[]
                    {
                        center + new Vector3(-half, 0f, -half),
                        center + new Vector3(-half, 0f,  half),
                        center + new Vector3( half, 0f,  half),
                        center + new Vector3( half, 0f, -half),
                    };

                    Color fill = cell.IsWalkable
                        ? new Color(0f, 0.8f, 0.1f, 0.18f)
                        : new Color(0.9f, 0f, 0f, 0.22f);
                    Handles.DrawSolidRectangleWithOutline(
                        corners,
                        fill,
                        new Color(fill.r, fill.g, fill.b, 0.55f));
                }
            }
        }
    }
}
```

Overlay 只显示 `LastSnapshot`，不重新调用 NavMesh API。需要检查单格详细值时，在下一节的 Inspector/测试中打印，不要给 4800 格同时画文字导致 Scene View 卡顿。

## 17. Unity EditMode Test 先锁定字节和坐标

在 Package Manager 确认 Test Framework 已存在。创建 Assembly Definition：

```text
Assets/BattleNavigation/Tests/EditMode/BattleNavigation.EditorTests.asmdef
```

```json
{
  "name": "BattleNavigation.EditorTests",
  "rootNamespace": "BattleNavigation.Tests",
  "references": [
    "BattleNavigation.Runtime",
    "BattleNavigation.Editor"
  ],
  "includePlatforms": ["Editor"],
  "autoReferenced": false,
  "overrideReferences": false,
  "precompiledReferences": [],
  "defineConstraints": [],
  "versionDefines": [],
  "noEngineReferences": false
}
```

如果前面的 Runtime/Editor 目录尚未建立对应 asmdef，先不创建这个文件，让测试使用默认 Assembly；不要留下引用不存在 Assembly 的半成品。项目稳定后再补 asmdef，这个迁移不改变运行语义。

完整路径：

```text
Assets/BattleNavigation/Tests/EditMode/BMapBinaryTests.cs
```

```csharp
using System.IO;
using NUnit.Framework;
using BattleNavigation.Editor;

namespace BattleNavigation.Tests
{
    public sealed class BMapBinaryTests
    {
        [Test]
        public void Crc32MatchesPublishedVector()
        {
            byte[] bytes = System.Text.Encoding.ASCII.GetBytes("123456789");
            Assert.That(BMapCrc32.Compute(bytes), Is.EqualTo(0xcbf43926u));
        }

        [Test]
        public void LittleEndianRoundTripKeepsBits()
        {
            var bytes = new byte[8];
            BMapLittleEndian.WriteU16(bytes, 0, 0xabcd);
            BMapLittleEndian.WriteU32(bytes, 2, 0x89abcdefu);
            Assert.That(BMapLittleEndian.ReadU16(bytes, 0), Is.EqualTo(0xabcd));
            Assert.That(BMapLittleEndian.ReadU32(bytes, 2), Is.EqualTo(0x89abcdefu));
        }

        [Test]
        public void WriterProducesExactSizeAndValidCrc()
        {
            var snapshot = new BattleMapSnapshot
            {
                mapId = 1001,
                mapVersion = 7,
                width = 2,
                height = 2,
                cellSizeMm = 500,
                originXMm = -500,
                originZMm = 1000,
                cells = new[]
                {
                    Walkable(0, 2),
                    default(NavCell),
                    Walkable(500, 1),
                    Walkable(1000, 1),
                },
            };

            string directory = Path.GetFullPath(Path.Combine(
                UnityEngine.Application.dataPath,
                "..",
                "Library",
                "BattleNavigationTests"));
            Directory.CreateDirectory(directory);
            string path = Path.Combine(directory, "writer_test.bmap");

            BMapWriter.Write(snapshot, path);
            Assert.That(new FileInfo(path).Length, Is.EqualTo(64 + 4 * 8));
            Assert.DoesNotThrow(() => BMapWriter.Verify(path));
        }

        private static NavCell Walkable(int heightMm, byte clearance)
        {
            return new NavCell
            {
                heightMm = heightMm,
                flags = NavCellFlags.Walkable,
                areaType = (byte)BattleArea.Normal,
                clearanceCells = clearance,
            };
        }
    }
}
```

完整路径：

```text
Assets/BattleNavigation/Tests/EditMode/CoordinateAndClearanceTests.cs
```

```csharp
using NUnit.Framework;
using BattleNavigation.Editor;

namespace BattleNavigation.Tests
{
    public sealed class CoordinateAndClearanceTests
    {
        [TestCase(0, 500, 0)]
        [TestCase(499, 500, 0)]
        [TestCase(500, 500, 1)]
        [TestCase(-1, 500, -1)]
        [TestCase(-500, 500, -1)]
        [TestCase(-501, 500, -2)]
        public void FloorDivisionMatchesWorldGridContract(
            int value,
            int divisor,
            int expected)
        {
            Assert.That(
                BattleMapValidator.FloorDiv(value, divisor),
                Is.EqualTo(expected));
        }

        [Test]
        public void BoundaryAndBlockedCellsLimitClearance()
        {
            var snapshot = new BattleMapSnapshot
            {
                mapId = 1,
                mapVersion = 1,
                width = 5,
                height = 5,
                cellSizeMm = 500,
                cells = new NavCell[25],
            };

            for (int i = 0; i < snapshot.cells.Length; ++i)
            {
                snapshot.cells[i].flags = NavCellFlags.Walkable;
            }
            snapshot.cells[snapshot.IndexOf(1, 2)].flags = 0;

            BattleMapClearance.Compute(snapshot);

            Assert.That(snapshot.CellAt(1, 2).clearanceCells, Is.EqualTo(0));
            Assert.That(snapshot.CellAt(2, 2).clearanceCells, Is.EqualTo(1));
            Assert.That(snapshot.CellAt(4, 4).clearanceCells, Is.EqualTo(1));
        }
    }
}
```

打开：

```text
Window -> General -> Test Runner -> EditMode -> Run All
```

这一步先证明文件字节、CRC、负坐标和 Clearance。真实 Scene Sampling 仍要在导出 Battle_1001 时验证，两类失败不要混成一个 Test。

## 18. 导入 BMAP，而不是让 Server 读取 Unity Project

完整路径：

```text
~/workspace/skynet-battle-navigation-server/scripts/linux/import_bmap.sh
```

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

source_file="/mnt/g/simbi/dev/skynet-battle-navigation-unity/BuildArtifacts/Navigation/battle_1001.bmap"
source_manifest="/mnt/g/simbi/dev/skynet-battle-navigation-unity/BuildArtifacts/Navigation/battle_1001.manifest.json"
target_file="maps/battle_1001.bmap"
target_manifest="maps/battle_1001.manifest.json"

test -s "$source_file"
test -s "$source_manifest"

temporary_file="${target_file}.tmp"
temporary_manifest="${target_manifest}.tmp"
install -m 0644 "$source_file" "$temporary_file"
install -m 0644 "$source_manifest" "$temporary_manifest"
mv -f "$temporary_file" "$target_file"
mv -f "$temporary_manifest" "$target_manifest"

sha256sum "$target_file"
echo "BMAP_IMPORT_OK source=$source_file target=$target_file"
```

```bash
chmod +x scripts/linux/import_bmap.sh
./scripts/linux/import_bmap.sh
ls -l maps/battle_1001.bmap maps/battle_1001.manifest.json
```

Manifest 一同复制是为了 Review 和 CI，但 Runtime Loader 不依赖它。Server 不加载 `.unity`、GameObject、NavMeshAgent、Rigidbody 或 Animator。

## 19. Native 数据类型和错误契约

完整路径：

```text
native/grid_map/include/bmap_format.h
```

```cpp
#pragma once

#include <cstdint>

namespace battle_nav {

constexpr std::uint16_t kBMapFormatVersion = 1;
constexpr std::uint16_t kBMapHeaderSize = 64;
constexpr std::uint16_t kBMapCellStride = 8;
constexpr std::uint16_t kWalkableFlag = 1u << 0;

struct BMapMetadata {
    std::uint32_t map_id = 0;
    std::uint32_t map_version = 0;
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    std::uint32_t cell_size_mm = 0;
    std::int32_t origin_x_mm = 0;
    std::int32_t origin_z_mm = 0;
    std::uint32_t flags = 0;
};

struct NavCell {
    std::int32_t height_mm = 0;
    std::uint16_t flags = 0;
    std::uint8_t area_type = 0;
    std::uint8_t clearance_cells = 0;

    bool IsWalkable() const noexcept {
        return (flags & kWalkableFlag) != 0;
    }
};

struct WorldPosition {
    std::int32_t x_mm = 0;
    std::int32_t y_mm = 0;
    std::int32_t z_mm = 0;
};

struct GridPos {
    std::int32_t x = 0;
    std::int32_t z = 0;
};

}  // namespace battle_nav
```

完整路径：

```text
native/grid_map/include/nav_result.h
```

```cpp
#pragma once

#include <string>
#include <utility>

namespace battle_nav {

enum class NavError {
    kOk = 0,
    kIoError,
    kBadMagic,
    kUnsupportedVersion,
    kInvalidHeaderSize,
    kInvalidDimensions,
    kSizeOverflow,
    kInvalidStride,
    kPayloadSizeMismatch,
    kHeaderCrcMismatch,
    kPayloadCrcMismatch,
    kTruncated,
    kTrailingBytes,
    kDuplicateMap,
    kRegistryFrozen,
    kMapNotFound,
    kOutOfBounds,
    kInvalidArgument,
};

const char* NavErrorName(NavError error) noexcept;

template <typename T>
struct NavResult {
    NavError error = NavError::kOk;
    std::string detail;
    T value{};

    bool ok() const noexcept { return error == NavError::kOk; }

    static NavResult Success(T result) {
        NavResult output;
        output.value = std::move(result);
        return output;
    }

    static NavResult Failure(NavError code, std::string message) {
        NavResult output;
        output.error = code;
        output.detail = std::move(message);
        return output;
    }
};

}  // namespace battle_nav
```

完整路径：

```text
native/grid_map/src/nav_result.cpp
```

```cpp
#include "nav_result.h"

namespace battle_nav {

const char* NavErrorName(NavError error) noexcept {
    switch (error) {
    case NavError::kOk: return "OK";
    case NavError::kIoError: return "IO_ERROR";
    case NavError::kBadMagic: return "BMAP_BAD_MAGIC";
    case NavError::kUnsupportedVersion: return "BMAP_UNSUPPORTED_VERSION";
    case NavError::kInvalidHeaderSize: return "BMAP_INVALID_HEADER_SIZE";
    case NavError::kInvalidDimensions: return "BMAP_INVALID_DIMENSIONS";
    case NavError::kSizeOverflow: return "BMAP_SIZE_OVERFLOW";
    case NavError::kInvalidStride: return "BMAP_INVALID_CELL_STRIDE";
    case NavError::kPayloadSizeMismatch: return "BMAP_PAYLOAD_SIZE_MISMATCH";
    case NavError::kHeaderCrcMismatch: return "BMAP_HEADER_CRC_MISMATCH";
    case NavError::kPayloadCrcMismatch: return "BMAP_PAYLOAD_CRC_MISMATCH";
    case NavError::kTruncated: return "BMAP_TRUNCATED";
    case NavError::kTrailingBytes: return "BMAP_TRAILING_BYTES";
    case NavError::kDuplicateMap: return "DUPLICATE_MAP_VERSION";
    case NavError::kRegistryFrozen: return "REGISTRY_FROZEN";
    case NavError::kMapNotFound: return "MAP_NOT_FOUND";
    case NavError::kOutOfBounds: return "OUT_OF_BOUNDS";
    case NavError::kInvalidArgument: return "INVALID_ARGUMENT";
    }
    return "UNKNOWN_NAV_ERROR";
}

}  // namespace battle_nav
```

错误码属于项目 Contract。Loader 不能只返回 `false`，也不能用一条“load failed”掩盖 CRC、截断和版本错误。

## 20. GridMap：加载后只读

完整路径：

```text
native/grid_map/include/grid_map.h
```

```cpp
#pragma once

#include "bmap_format.h"
#include "nav_result.h"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace battle_nav {

class GridMap final {
public:
    GridMap(BMapMetadata metadata, std::vector<NavCell> cells);

    const BMapMetadata& metadata() const noexcept { return metadata_; }
    std::size_t cell_count() const noexcept { return cells_.size(); }
    std::size_t memory_bytes() const noexcept;

    NavResult<GridPos> WorldToGrid(const WorldPosition& world) const;
    NavResult<WorldPosition> GridToWorldCenter(const GridPos& grid) const;
    NavResult<NavCell> QueryWorld(const WorldPosition& world) const;

private:
    bool Contains(const GridPos& grid) const noexcept;
    std::size_t IndexOf(const GridPos& grid) const noexcept;
    static std::int64_t FloorDiv(std::int64_t value, std::int64_t divisor);

    const BMapMetadata metadata_;
    const std::vector<NavCell> cells_;
};

}  // namespace battle_nav
```

完整路径：

```text
native/grid_map/src/grid_map.cpp
```

```cpp
#include "grid_map.h"

#include <limits>
#include <stdexcept>
#include <utility>

namespace battle_nav {

GridMap::GridMap(BMapMetadata metadata, std::vector<NavCell> cells)
    : metadata_(metadata), cells_(std::move(cells)) {
    const std::uint64_t expected =
        static_cast<std::uint64_t>(metadata_.width) * metadata_.height;
    if (metadata_.cell_size_mm == 0 || expected != cells_.size()) {
        throw std::invalid_argument("GridMap metadata/cell mismatch");
    }
}

std::size_t GridMap::memory_bytes() const noexcept {
    return sizeof(*this) + cells_.capacity() * sizeof(NavCell);
}

NavResult<GridPos> GridMap::WorldToGrid(const WorldPosition& world) const {
    const std::int64_t relative_x =
        static_cast<std::int64_t>(world.x_mm) - metadata_.origin_x_mm;
    const std::int64_t relative_z =
        static_cast<std::int64_t>(world.z_mm) - metadata_.origin_z_mm;

    const std::int64_t grid_x = FloorDiv(relative_x, metadata_.cell_size_mm);
    const std::int64_t grid_z = FloorDiv(relative_z, metadata_.cell_size_mm);
    if (grid_x < std::numeric_limits<std::int32_t>::min() ||
        grid_x > std::numeric_limits<std::int32_t>::max() ||
        grid_z < std::numeric_limits<std::int32_t>::min() ||
        grid_z > std::numeric_limits<std::int32_t>::max()) {
        return NavResult<GridPos>::Failure(
            NavError::kOutOfBounds,
            "world coordinate cannot be represented as GridPos");
    }

    GridPos grid{
        static_cast<std::int32_t>(grid_x),
        static_cast<std::int32_t>(grid_z),
    };
    if (!Contains(grid)) {
        return NavResult<GridPos>::Failure(
            NavError::kOutOfBounds,
            "world position outside map bounds");
    }
    return NavResult<GridPos>::Success(grid);
}

NavResult<WorldPosition> GridMap::GridToWorldCenter(const GridPos& grid) const {
    if (!Contains(grid)) {
        return NavResult<WorldPosition>::Failure(
            NavError::kOutOfBounds,
            "grid position outside map bounds");
    }

    const NavCell& cell = cells_[IndexOf(grid)];
    const std::int64_t x = static_cast<std::int64_t>(metadata_.origin_x_mm) +
        static_cast<std::int64_t>(grid.x) * metadata_.cell_size_mm +
        metadata_.cell_size_mm / 2;
    const std::int64_t z = static_cast<std::int64_t>(metadata_.origin_z_mm) +
        static_cast<std::int64_t>(grid.z) * metadata_.cell_size_mm +
        metadata_.cell_size_mm / 2;
    if (x < std::numeric_limits<std::int32_t>::min() ||
        x > std::numeric_limits<std::int32_t>::max() ||
        z < std::numeric_limits<std::int32_t>::min() ||
        z > std::numeric_limits<std::int32_t>::max()) {
        return NavResult<WorldPosition>::Failure(
            NavError::kSizeOverflow,
            "grid center overflow");
    }

    return NavResult<WorldPosition>::Success(WorldPosition{
        static_cast<std::int32_t>(x),
        cell.height_mm,
        static_cast<std::int32_t>(z),
    });
}

NavResult<NavCell> GridMap::QueryWorld(const WorldPosition& world) const {
    NavResult<GridPos> grid = WorldToGrid(world);
    if (!grid.ok()) {
        return NavResult<NavCell>::Failure(grid.error, grid.detail);
    }
    return NavResult<NavCell>::Success(cells_[IndexOf(grid.value)]);
}

bool GridMap::Contains(const GridPos& grid) const noexcept {
    return grid.x >= 0 && grid.z >= 0 &&
        static_cast<std::uint32_t>(grid.x) < metadata_.width &&
        static_cast<std::uint32_t>(grid.z) < metadata_.height;
}

std::size_t GridMap::IndexOf(const GridPos& grid) const noexcept {
    return static_cast<std::size_t>(grid.z) * metadata_.width +
        static_cast<std::size_t>(grid.x);
}

std::int64_t GridMap::FloorDiv(std::int64_t value, std::int64_t divisor) {
    if (divisor <= 0) {
        throw std::invalid_argument("divisor must be positive");
    }
    std::int64_t quotient = value / divisor;
    const std::int64_t remainder = value % divisor;
    if (remainder != 0 && value < 0) {
        --quotient;
    }
    return quotient;
}

}  // namespace battle_nav
```

`metadata_` 和 `cells_` 都是 `const`。第一课没有 Query Scratch；所有查询只读输入、局部变量和 immutable Cell Array。

## 21. BMapReader：任何一个字节都不能靠 struct cast 猜

完整路径：

```text
native/grid_map/include/bmap_reader.h
```

```cpp
#pragma once

#include "grid_map.h"
#include "nav_result.h"

#include <memory>
#include <string>

namespace battle_nav {

class BMapReader final {
public:
    static NavResult<std::shared_ptr<const GridMap>> Read(
        const std::string& path);
};

}  // namespace battle_nav
```

完整路径：

```text
native/grid_map/src/bmap_reader.cpp
```

```cpp
#include "bmap_reader.h"

#include <array>
#include <cstdint>
#include <fstream>
#include <limits>
#include <sstream>
#include <utility>
#include <vector>

namespace battle_nav {
namespace {

constexpr std::size_t kHeaderCrcOffset = 52;

std::uint16_t ReadU16Le(const std::uint8_t* bytes) noexcept {
    return static_cast<std::uint16_t>(bytes[0]) |
        static_cast<std::uint16_t>(bytes[1]) << 8;
}

std::uint32_t ReadU32Le(const std::uint8_t* bytes) noexcept {
    return static_cast<std::uint32_t>(bytes[0]) |
        static_cast<std::uint32_t>(bytes[1]) << 8 |
        static_cast<std::uint32_t>(bytes[2]) << 16 |
        static_cast<std::uint32_t>(bytes[3]) << 24;
}

std::int32_t ReadI32Le(const std::uint8_t* bytes) noexcept {
    return static_cast<std::int32_t>(ReadU32Le(bytes));
}

void WriteU32Le(std::uint8_t* bytes, std::uint32_t value) noexcept {
    bytes[0] = static_cast<std::uint8_t>(value);
    bytes[1] = static_cast<std::uint8_t>(value >> 8);
    bytes[2] = static_cast<std::uint8_t>(value >> 16);
    bytes[3] = static_cast<std::uint8_t>(value >> 24);
}

std::uint32_t Crc32(const std::uint8_t* bytes, std::size_t size) noexcept {
    std::uint32_t crc = 0xffffffffu;
    for (std::size_t i = 0; i < size; ++i) {
        crc ^= bytes[i];
        for (int bit = 0; bit < 8; ++bit) {
            crc = (crc & 1u) != 0
                ? 0xedb88320u ^ (crc >> 1)
                : crc >> 1;
        }
    }
    return crc ^ 0xffffffffu;
}

std::string SizeDetail(
    std::uint64_t expected,
    std::uint64_t actual) {
    std::ostringstream stream;
    stream << "expected=" << expected << " actual=" << actual;
    return stream.str();
}

}  // namespace

NavResult<std::shared_ptr<const GridMap>> BMapReader::Read(
    const std::string& path) {
    std::ifstream stream(path, std::ios::binary | std::ios::ate);
    if (!stream) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kIoError,
            "cannot open: " + path);
    }

    const std::streamoff end = stream.tellg();
    if (end < 0) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kIoError,
            "tellg failed: " + path);
    }
    const std::uint64_t file_size = static_cast<std::uint64_t>(end);
    if (file_size < kBMapHeaderSize) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kTruncated,
            SizeDetail(kBMapHeaderSize, file_size));
    }
    if (file_size > std::numeric_limits<std::size_t>::max()) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kSizeOverflow,
            "file larger than addressable memory");
    }

    stream.seekg(0, std::ios::beg);
    std::vector<std::uint8_t> file(static_cast<std::size_t>(file_size));
    stream.read(
        reinterpret_cast<char*>(file.data()),
        static_cast<std::streamsize>(file.size()));
    if (!stream || static_cast<std::size_t>(stream.gcount()) != file.size()) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kTruncated,
            "short read: " + path);
    }

    if (file[0] != 'B' || file[1] != 'M' ||
        file[2] != 'A' || file[3] != 'P') {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kBadMagic,
            "magic is not BMAP");
    }

    const std::uint16_t format_version = ReadU16Le(file.data() + 4);
    const std::uint16_t header_size = ReadU16Le(file.data() + 6);
    if (format_version != kBMapFormatVersion) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kUnsupportedVersion,
            "format_version=" + std::to_string(format_version));
    }
    if (header_size != kBMapHeaderSize) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kInvalidHeaderSize,
            "header_size=" + std::to_string(header_size));
    }

    BMapMetadata metadata;
    metadata.map_id = ReadU32Le(file.data() + 8);
    metadata.map_version = ReadU32Le(file.data() + 12);
    metadata.width = ReadU32Le(file.data() + 16);
    metadata.height = ReadU32Le(file.data() + 20);
    metadata.cell_size_mm = ReadU32Le(file.data() + 24);
    metadata.origin_x_mm = ReadI32Le(file.data() + 28);
    metadata.origin_z_mm = ReadI32Le(file.data() + 32);
    metadata.flags = ReadU32Le(file.data() + 36);
    const std::uint16_t cell_stride = ReadU16Le(file.data() + 40);
    const std::uint16_t reserved0 = ReadU16Le(file.data() + 42);
    const std::uint32_t payload_size = ReadU32Le(file.data() + 44);
    const std::uint32_t expected_payload_crc = ReadU32Le(file.data() + 48);
    const std::uint32_t expected_header_crc = ReadU32Le(file.data() + 52);

    if (metadata.map_id == 0 || metadata.map_version == 0 ||
        metadata.width == 0 || metadata.height == 0 ||
        metadata.cell_size_mm == 0) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kInvalidDimensions,
            "zero identity/dimension/cell size");
    }
    if (cell_stride != kBMapCellStride || reserved0 != 0) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kInvalidStride,
            "cell_stride/reserved mismatch");
    }

    const std::uint64_t cell_count =
        static_cast<std::uint64_t>(metadata.width) * metadata.height;
    const std::uint64_t expected_payload_size =
        cell_count * static_cast<std::uint64_t>(cell_stride);
    if (cell_count > std::numeric_limits<std::size_t>::max() ||
        expected_payload_size > std::numeric_limits<std::uint32_t>::max()) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kSizeOverflow,
            "dimension multiplication overflow");
    }
    if (payload_size != expected_payload_size) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kPayloadSizeMismatch,
            SizeDetail(expected_payload_size, payload_size));
    }

    const std::uint64_t expected_file_size = header_size + expected_payload_size;
    if (file_size < expected_file_size) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kTruncated,
            SizeDetail(expected_file_size, file_size));
    }
    if (file_size > expected_file_size) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kTrailingBytes,
            SizeDetail(expected_file_size, file_size));
    }

    std::array<std::uint8_t, kBMapHeaderSize> header{};
    std::copy_n(file.data(), header.size(), header.data());
    WriteU32Le(header.data() + kHeaderCrcOffset, 0);
    if (Crc32(header.data(), header.size()) != expected_header_crc) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kHeaderCrcMismatch,
            "header crc mismatch");
    }

    const std::uint8_t* payload = file.data() + header_size;
    if (Crc32(payload, payload_size) != expected_payload_crc) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kPayloadCrcMismatch,
            "payload crc mismatch");
    }

    std::vector<NavCell> cells;
    cells.resize(static_cast<std::size_t>(cell_count));
    for (std::size_t index = 0; index < cells.size(); ++index) {
        const std::uint8_t* source = payload + index * cell_stride;
        cells[index].height_mm = ReadI32Le(source);
        cells[index].flags = ReadU16Le(source + 4);
        cells[index].area_type = source[6];
        cells[index].clearance_cells = source[7];
    }

    try {
        std::shared_ptr<const GridMap> map =
            std::make_shared<const GridMap>(metadata, std::move(cells));
        return NavResult<std::shared_ptr<const GridMap>>::Success(std::move(map));
    } catch (const std::exception& exception) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kInvalidDimensions,
            exception.what());
    }
}

}  // namespace battle_nav
```

注意 Loader 先验证尺寸乘法，再相信 payload_size。若先按文件字段分配内存，损坏文件可以诱导超大分配。

## 22. MapRegistry：启动阶段写一次，冻结后共享读

完整路径：

```text
native/grid_map/include/map_registry.h
```

```cpp
#pragma once

#include "bmap_reader.h"
#include "grid_map.h"
#include "nav_result.h"

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

namespace battle_nav {

class MapRegistry final {
public:
    static MapRegistry& Instance();

    NavResult<std::shared_ptr<const GridMap>> Load(const std::string& path);
    NavResult<bool> Freeze();
    NavResult<std::shared_ptr<const GridMap>> Find(
        std::uint32_t map_id,
        std::uint32_t map_version) const;
    std::size_t map_count() const;

private:
    struct Key {
        std::uint32_t map_id;
        std::uint32_t map_version;

        bool operator==(const Key& other) const noexcept {
            return map_id == other.map_id && map_version == other.map_version;
        }
    };

    struct KeyHash {
        std::size_t operator()(const Key& key) const noexcept {
            return static_cast<std::size_t>(key.map_id) * 0x9e3779b1u ^
                key.map_version;
        }
    };

    MapRegistry() = default;

    mutable std::mutex mutex_;
    bool frozen_ = false;
    std::unordered_map<Key, std::shared_ptr<const GridMap>, KeyHash> maps_;
};

}  // namespace battle_nav
```

完整路径：

```text
native/grid_map/src/map_registry.cpp
```

```cpp
#include "map_registry.h"

#include <sstream>
#include <utility>

namespace battle_nav {

MapRegistry& MapRegistry::Instance() {
    static MapRegistry registry;
    return registry;
}

NavResult<std::shared_ptr<const GridMap>> MapRegistry::Load(
    const std::string& path) {
    // 文件 I/O 和 CRC 不占用 Registry Lock。
    NavResult<std::shared_ptr<const GridMap>> loaded = BMapReader::Read(path);
    if (!loaded.ok()) {
        return loaded;
    }

    const BMapMetadata& metadata = loaded.value->metadata();
    const Key key{metadata.map_id, metadata.map_version};
    std::lock_guard<std::mutex> lock(mutex_);
    if (frozen_) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kRegistryFrozen,
            "load attempted after freeze");
    }
    if (maps_.find(key) != maps_.end()) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kDuplicateMap,
            "duplicate map/version");
    }

    maps_.emplace(key, loaded.value);
    return loaded;
}

NavResult<bool> MapRegistry::Freeze() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (frozen_) {
        return NavResult<bool>::Success(false);
    }
    frozen_ = true;
    return NavResult<bool>::Success(true);
}

NavResult<std::shared_ptr<const GridMap>> MapRegistry::Find(
    std::uint32_t map_id,
    std::uint32_t map_version) const {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto iterator = maps_.find(Key{map_id, map_version});
    if (iterator == maps_.end()) {
        std::ostringstream detail;
        detail << "map_id=" << map_id << " map_version=" << map_version;
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kMapNotFound,
            detail.str());
    }
    return NavResult<std::shared_ptr<const GridMap>>::Success(iterator->second);
}

std::size_t MapRegistry::map_count() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return maps_.size();
}

}  // namespace battle_nav
```

这里为了第一课清楚且正确，`Find` 也使用一个短锁。锁只保护 Registry 查找和 shared_ptr 复制，不包围 Grid Query。冻结后可再通过 Benchmark 决定是否改成一次发布、无锁只读快照；不能在没有负载数据时提前增加复杂同步方案。

## 23. Native 单元测试与 CMake

完整路径：

```text
native/grid_map/tests/grid_map_test.cpp
```

```cpp
#include "grid_map.h"

#include <cassert>
#include <cstdint>
#include <iostream>
#include <vector>

using battle_nav::BMapMetadata;
using battle_nav::GridMap;
using battle_nav::NavCell;
using battle_nav::WorldPosition;

int main() {
    BMapMetadata metadata;
    metadata.map_id = 1001;
    metadata.map_version = 1;
    metadata.width = 2;
    metadata.height = 2;
    metadata.cell_size_mm = 500;
    metadata.origin_x_mm = -500;
    metadata.origin_z_mm = 1000;

    std::vector<NavCell> cells(4);
    cells[0].flags = battle_nav::kWalkableFlag;
    cells[0].height_mm = 100;
    cells[0].clearance_cells = 1;

    const GridMap map(metadata, std::move(cells));

    const auto first = map.WorldToGrid(WorldPosition{-250, 0, 1250});
    assert(first.ok());
    assert(first.value.x == 0 && first.value.z == 0);

    const auto before_origin = map.WorldToGrid(WorldPosition{-501, 0, 1250});
    assert(!before_origin.ok());
    assert(before_origin.error == battle_nav::NavError::kOutOfBounds);

    const auto query = map.QueryWorld(WorldPosition{-250, 9999, 1250});
    assert(query.ok());
    assert(query.value.IsWalkable());
    assert(query.value.height_mm == 100);

    std::cout << "GRID_MAP_TEST_OK\n";
    return 0;
}
```

完整路径：

```text
native/grid_map/CMakeLists.txt
```

```cmake
cmake_minimum_required(VERSION 3.16)
project(battle_grid_map LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_library(grid_map_core STATIC
    src/bmap_reader.cpp
    src/grid_map.cpp
    src/map_registry.cpp
    src/nav_result.cpp
)
target_include_directories(grid_map_core PUBLIC include)
target_compile_options(grid_map_core PRIVATE -Wall -Wextra -Wpedantic)

add_executable(grid_map_test tests/grid_map_test.cpp)
target_link_libraries(grid_map_test PRIVATE grid_map_core pthread)

enable_testing()
add_test(NAME grid_map_test COMMAND grid_map_test)
```

第一次构建：

```bash
cd ~/workspace/skynet-battle-navigation-server
cmake -S native/grid_map -B build/grid_map -DCMAKE_BUILD_TYPE=Debug
cmake --build build/grid_map -j"$(nproc)"
ctest --test-dir build/grid_map --output-on-failure
```

预期：

```text
GRID_MAP_TEST_OK
100% tests passed
```

## 24. 给查询链路定义唯一的 Protobuf 合同

到这里，Unity 已经能导出 BMAP，C++ 已经能读取静态地图。下一步不是给 Lua 业务对象加一堆字段，而是先把跨进程边界写成一个可以独立测试的协议。

本课只定义“查询一个世界坐标对应的静态网格信息”。`GridPos` 是地图内部调试结果，正式业务位置仍然是 `WorldPosition` 毫米坐标。第三课会增加另一种导航实现，因此 Lua 业务不把 `GridPos` 当长期持久业务坐标。

### 24.1 创建协议文件

文件：`~/workspace/skynet-battle-navigation-server/protocol/navigation_query.proto`

```proto
syntax = "proto3";

package battle.navigation.v1;

message Envelope {
  uint32 protocol_version = 1;
  uint32 command = 2;
  uint64 request_id = 3;
  bytes body = 4;
}

message WorldPosition {
  int64 x_mm = 1;
  int64 y_mm = 2;
  int64 z_mm = 3;
}

message QueryCellRequest {
  string map_id = 1;
  uint32 map_version = 2;
  WorldPosition position = 3;
}

message QueryCellResponse {
  enum ResultCode {
    RESULT_UNSPECIFIED = 0;
    OK = 1;
    MAP_NOT_FOUND = 2;
    MAP_VERSION_MISMATCH = 3;
    OUT_OF_BOUNDS = 4;
    NOT_WALKABLE = 5;
    BAD_REQUEST = 6;
    INTERNAL_ERROR = 7;
  }

  ResultCode result = 1;
  string message = 2;
  string map_id = 3;
  uint32 map_version = 4;
  int32 grid_x = 5;
  int32 grid_z = 6;
  int32 cell_height_mm = 7;
  uint32 area = 8;
  uint32 clearance = 9;
}
```

命令号在 Lua 和 C# 中使用同一个常量：`QUERY_CELL = 1001`。协议版本不随业务小改动自动递增；只有兼容性边界改变时才递增，并在测试里保留旧版本拒绝用例。

### 24.2 固定生成工具版本

文件：`protocol/VERSIONS.env`

```bash
PROTOC_VERSION=36.2
LUA_PROTOBUF_COMMIT=ee4beb3865e2b82ea94b8a4314d78875c550ce20
GOOGLE_PROTOBUF_VERSION=3.36.2
```

下载或升级工具前先查看 `docs/ENGINEERING_DECISIONS.md` 的 D029。Server 使用已存在环境中的 lua-protobuf 0.5.3，Unity C# 使用 `Google.Protobuf` 3.36.2；本课不允许某台机器自动使用“当前最新版”。

文件：`protocol/build_server_descriptor.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROTOC="${PROTOC:-protoc}"
OUT="$ROOT/protocol/generated/server"
mkdir -p "$OUT"

command -v "$PROTOC" >/dev/null
"$PROTOC" --version
rm -f "$OUT/navigation_query.pb"
"$PROTOC" \
  --descriptor_set_out="$OUT/navigation_query.pb" \
  --include_imports \
  -I "$ROOT/protocol" \
  "$ROOT/protocol/navigation_query.proto"

test -s "$OUT/navigation_query.pb"
sha256sum "$OUT/navigation_query.pb" > "$OUT/navigation_query.pb.sha256"
echo "SERVER_DESCRIPTOR_OK $OUT/navigation_query.pb"
```

文件：`protocol/build_unity_cs.ps1`

```powershell
param(
    [string]$Protoc = "protoc.exe",
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")),
    [string]$UnityGenerated = "Assets/Generated/Protocol"
)

$ErrorActionPreference = "Stop"
$protoDir = Join-Path $Root "protocol"
$outDir = Join-Path $Root $UnityGenerated
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
& $Protoc `
  "--csharp_out=$outDir" `
  "-I$protoDir" `
  (Join-Path $protoDir "navigation_query.proto")
if ($LASTEXITCODE -ne 0) { throw "protoc failed: $LASTEXITCODE" }
Write-Output "UNITY_PROTOBUF_CS_OK $outDir"
```

PowerShell 生成出来的 C# 文件必须提交到 Unity 工程，Server descriptor 则由构建脚本生成到 `protocol/generated/server`。这样 Unity 编辑器没有安装 protoc 时也可以打开工程，Server 仍然能在 Linux 上检查 descriptor 是否和提交内容一致。

### 24.3 给协议写一个可观察的 descriptor 检查

文件：`protocol/check_descriptor.lua`

```lua
local pb = require "pb"

local path = assert(..., "usage: lua check_descriptor.lua descriptor.pb")
local data = assert(io.open(path, "rb")):read("*a")
assert(pb.load(data))

assert(pb.type(".battle.navigation.v1.Envelope"))
assert(pb.type(".battle.navigation.v1.QueryCellRequest"))
assert(pb.type(".battle.navigation.v1.QueryCellResponse"))
print("PROTO_DESCRIPTOR_OK")
```

运行：

```bash
cd ~/workspace/skynet-battle-navigation-server
lua protocol/check_descriptor.lua protocol/generated/server/navigation_query.pb
```

如果这里失败，不要继续调 Unity TCP。先解决协议生成或 lua-protobuf 加载问题。

## 25. Lua C Binding：只暴露静态查询，不把 Skynet 业务塞进 C++

Lua C Binding 的职责很窄：把 Lua table 转成 C++ 输入，调用已经完成线程安全设计的 `MapRegistry`，再把 `NavResult<QueryCell>` 转成 Lua table。它不保存 Lua 状态，不创建协程，不执行 `skynet.call`，也不把动态单位写进共享地图。

### 25.1 C Binding 头文件

文件：`native/lua_battle_nav/include/lua_battle_nav.h`

```cpp
#pragma once

struct lua_State;

extern "C" int luaopen_battle_nav(lua_State* L);
```

### 25.2 Binding 实现

文件：`native/lua_battle_nav/src/lua_battle_nav.cpp`

```cpp
#include "lua_battle_nav.h"

#include "map_registry.h"

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

#include <cstdint>
#include <memory>
#include <string>

namespace {

using battle::navigation::GridMap;
using battle::navigation::MapRegistry;

MapRegistry* registry(lua_State* L) {
    void* p = lua_touserdata(L, lua_upvalueindex(1));
    return static_cast<MapRegistry*>(p);
}

std::int64_t integer_field(lua_State* L, int index, const char* name) {
    lua_getfield(L, index, name);
    if (!lua_isinteger(L, -1)) {
        luaL_error(L, "field '%s' must be integer", name);
    }
    const auto value = static_cast<std::int64_t>(lua_tointeger(L, -1));
    lua_pop(L, 1);
    return value;
}

void push_error(lua_State* L, const char* code, const std::string& message) {
    lua_pushnil(L);
    lua_newtable(L);
    lua_pushstring(L, code);
    lua_setfield(L, -2, "code");
    lua_pushlstring(L, message.data(), message.size());
    lua_setfield(L, -2, "message");
}

int l_query_cell(lua_State* L) {
    auto* maps = registry(L);
    const char* map_id = luaL_checkstring(L, 1);
    const auto version = static_cast<std::uint32_t>(luaL_checkinteger(L, 2));
    luaL_checktype(L, 3, LUA_TTABLE);

    battle::navigation::WorldPosition position;
    position.x_mm = integer_field(L, 3, "x_mm");
    position.y_mm = integer_field(L, 3, "y_mm");
    position.z_mm = integer_field(L, 3, "z_mm");

    const auto found = maps->Find(map_id);
    if (!found.ok()) {
        push_error(L, "MAP_NOT_FOUND", found.message());
        return 2;
    }
    const auto& map = *found.value();
    if (map.version() != version) {
        push_error(L, "MAP_VERSION_MISMATCH", "requested map version is not loaded");
        return 2;
    }

    const auto result = map.QueryWorld(position);
    if (!result.ok()) {
        push_error(L, result.code_string(), result.message());
        return 2;
    }

    const auto& cell = result.value();
    lua_newtable(L);
    lua_pushinteger(L, cell.grid_x);
    lua_setfield(L, -2, "grid_x");
    lua_pushinteger(L, cell.grid_z);
    lua_setfield(L, -2, "grid_z");
    lua_pushinteger(L, cell.height_mm);
    lua_setfield(L, -2, "cell_height_mm");
    lua_pushinteger(L, cell.area);
    lua_setfield(L, -2, "area");
    lua_pushinteger(L, cell.clearance);
    lua_setfield(L, -2, "clearance");
    lua_pushboolean(L, cell.walkable ? 1 : 0);
    lua_setfield(L, -2, "walkable");
    return 1;
}

} // namespace

extern "C" int luaopen_battle_nav(lua_State* L) {
    auto* maps = static_cast<MapRegistry*>(lua_touserdata(L, lua_upvalueindex(1)));
    (void)maps;
    luaL_checkversion(L);
    lua_newtable(L);
    lua_pushcfunction(L, l_query_cell);
    lua_setfield(L, -2, "query_cell");
    return 1;
}
```

上面 `luaopen_battle_nav` 需要在注册时绑定 `MapRegistry*` upvalue。为避免不同 Lua 版本的 `luaL_requiref` 签名混乱，工程里使用一个明确的注册函数：

文件：`native/lua_battle_nav/src/lua_battle_nav_register.cpp`

```cpp
#include "lua_battle_nav.h"
#include "map_registry.h"

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

extern "C" int battle_nav_register(lua_State* L,
                                    battle::navigation::MapRegistry* registry) {
    lua_pushlightuserdata(L, registry);
    lua_pushcclosure(L, luaopen_battle_nav, 1);
    lua_call(L, 0, 1);
    lua_setglobal(L, "battle_nav");
    return 0;
}
```

实际接入 Skynet 时只在服务初始化阶段调用一次 `battle_nav_register`。多个 Service 可以共享 immutable 地图；每个 Service 的 Lua State 只拥有自己的模块 table。任何临时查询数据都在栈和局部变量里，不能放在 C++ 全局可写 scratch。

### 25.3 Binding 的 CMake 目标

文件：`native/lua_battle_nav/CMakeLists.txt`

```cmake
cmake_minimum_required(VERSION 3.16)
project(battle_nav_lua LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(PkgConfig REQUIRED)
pkg_check_modules(LUA REQUIRED lua5.4)

add_library(battle_nav_lua MODULE
    src/lua_battle_nav.cpp
    src/lua_battle_nav_register.cpp
)
target_include_directories(battle_nav_lua PRIVATE
    include
    ../grid_map/include
    ${LUA_INCLUDE_DIRS}
)
target_link_libraries(battle_nav_lua PRIVATE grid_map_core ${LUA_LIBRARIES})
target_compile_options(battle_nav_lua PRIVATE -Wall -Wextra -Wpedantic)
set_target_properties(battle_nav_lua PROPERTIES PREFIX "")
```

如果当前 WSL 的 Skynet 使用 Lua 5.3，则把 `lua5.4` 改为实际 `pkg-config --list-all` 能找到的版本，并记录到 `docs/REFERENCES.md`。这里不能为了让示例“看起来能编译”而偷偷切换 Lua 版本。

## 26. Skynet 服务：先完成 Lua 内部查询，再接 TCP

为了让故障定位有层次，先写一个不经过 TCP 的服务调用。这样可以区分“地图/Biding 错误”和“协议/网络错误”。服务之间仍然遵守 Skynet 的 ownership/yield 规则：加载地图只发生在启动阶段；一次查询不在 C++ 模块里 yield；Lua 服务可以在消息边界 yield，但不会把正在构建的响应 table 共享给别的协程。

### 26.1 服务目录

```text
service/
  main.lua
  nav/
    bootstrap.lua
    query_worker.lua
    tcp_gateway.lua
protocol/
  codec.lua
config/
  lesson1.lua
```

### 26.2 配置

文件：`config/lesson1.lua`

```lua
return {
    host = "127.0.0.1",
    port = 19001,
    protocol_version = 1,
    query_cell_command = 1001,
    max_frame_bytes = 64 * 1024,
    map = {
        id = "battle_1001",
        version = 1,
        bmap = "assets/maps/battle_1001_v1.bmap",
    },
}
```

端口只绑定回环地址，避免第一课把测试服务暴露到局域网。需要局域网测试时显式把 `host` 改成 `0.0.0.0`，并在启动日志中打印出这一变更。

### 26.3 Protobuf codec

文件：`protocol/codec.lua`

```lua
local pb = require "pb"

local M = {}
M.ENVELOPE = ".battle.navigation.v1.Envelope"
M.REQUEST = ".battle.navigation.v1.QueryCellRequest"
M.RESPONSE = ".battle.navigation.v1.QueryCellResponse"

function M.load_descriptor(path)
    local f = assert(io.open(path, "rb"))
    local data = f:read("*a")
    f:close()
    assert(pb.load(data), "cannot load protobuf descriptor: " .. path)
end

function M.encode_envelope(command, request_id, body, version)
    local envelope = {
        protocol_version = version,
        command = command,
        request_id = request_id,
        body = body,
    }
    return assert(pb.encode(M.ENVELOPE, envelope))
end

function M.decode_envelope(bytes)
    local value = assert(pb.decode(M.ENVELOPE, bytes))
    return value
end

function M.encode_query_request(value)
    return assert(pb.encode(M.REQUEST, value))
end

function M.decode_query_request(bytes)
    return assert(pb.decode(M.REQUEST, bytes))
end

function M.encode_query_response(value)
    return assert(pb.encode(M.RESPONSE, value))
end

function M.decode_query_response(bytes)
    return assert(pb.decode(M.RESPONSE, bytes))
end

return M
```

`pb.load` 只在 bootstrap 阶段执行一次；不要在每个请求里读 descriptor。lua-protobuf 的错误必须转成服务层明确错误，不能让 malformed bytes 直接穿过 `pcall` 后变成空响应。

### 26.4 查询 Worker

文件：`service/nav/query_worker.lua`

```lua
local skynet = require "skynet"
local codec = require "protocol.codec"

local M = {}
local config

local RESULT = {
    OK = 1,
    MAP_NOT_FOUND = 2,
    MAP_VERSION_MISMATCH = 3,
    OUT_OF_BOUNDS = 4,
    NOT_WALKABLE = 5,
    BAD_REQUEST = 6,
    INTERNAL_ERROR = 7,
}

local function result_error(code, message)
    return {
        result = RESULT[code] or RESULT.INTERNAL_ERROR,
        message = message,
    }
end

function M.start(options)
    config = assert(options)
    assert(battle_nav, "battle_nav native module is not registered")
    assert(battle_nav.load_map(config.map.id, config.map.version, config.map.bmap))
end

function M.query(request)
    if type(request) ~= "table" or type(request.map_id) ~= "string" or
       type(request.position) ~= "table" then
        return result_error("BAD_REQUEST", "missing map_id or position")
    end
    if request.map_id ~= config.map.id then
        return result_error("MAP_NOT_FOUND", "map is not loaded")
    end
    if request.map_version ~= config.map.version then
        return result_error("MAP_VERSION_MISMATCH", "map version mismatch")
    end

    local ok, value, err = pcall(
        battle_nav.query_cell,
        request.map_id,
        request.map_version,
        request.position)
    if not ok then
        skynet.error("battle_nav.query_cell panic: ", value)
        return result_error("INTERNAL_ERROR", "native query failed")
    end
    if not value then
        return result_error(err.code or "INTERNAL_ERROR", err.message)
    end

    return {
        result = RESULT.OK,
        message = "",
        map_id = request.map_id,
        map_version = request.map_version,
        grid_x = value.grid_x,
        grid_z = value.grid_z,
        cell_height_mm = value.cell_height_mm,
        area = value.area,
        clearance = value.clearance,
    }
end

return M
```

这里故意没有 `Path`、`AgentProfile`、`NavigationContext` 或 `BattleWorker`。本课行为只是静态地图查询，代码中的对象数量应该和行为需求相匹配。

### 26.5 Bootstrap

文件：`service/nav/bootstrap.lua`

```lua
local skynet = require "skynet"
local query_worker = require "service.nav.query_worker"

local M = {}

function M.start(config)
    query_worker.start(config)
    local address = skynet.self()
    skynet.register("NAV_QUERY")
    skynet.dispatch("lua", function(_, source, command, payload)
        if command == "query_cell" then
            local request = assert(payload)
            local response = query_worker.query(request)
            skynet.ret(skynet.pack(response))
        else
            error("unknown NAV_QUERY command: " .. tostring(command))
        end
    end)
    skynet.error("NAV_QUERY_READY ", address, " map=", config.map.id,
                 " version=", config.map.version)
end

return M
```

`query_cell` 是单次同步 C++ 查询。它没有跨服务 `skynet.call`，因此不会把本课的静态查询变成隐藏的服务链。后续 BattleWorker 需要每场战斗自己的上下文时，再按 Lesson 2 的执行链设计。

## 27. TCP 长度帧：把 Protobuf 安全送到 Skynet

协议帧为：

```text
4 bytes unsigned length, big-endian
length bytes Envelope protobuf
```

`length` 只描述 Envelope 字节数，最大 64 KiB。网络层不能依赖一次 `socket.read` 就得到完整消息，也不能把一次 `read` 得到的多个消息当成一个 protobuf。

### 27.1 Lua 长度帧工具

文件：`service/nav/frame.lua`

```lua
local M = {}

local function u32be(n)
    assert(n >= 0 and n <= 0xffffffff)
    local b1 = math.floor(n / 0x1000000) % 0x100
    local b2 = math.floor(n / 0x10000) % 0x100
    local b3 = math.floor(n / 0x100) % 0x100
    local b4 = n % 0x100
    return string.char(b1, b2, b3, b4)
end

local function read_u32be(s)
    local a, b, c, d = s:byte(1, 4)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

function M.pack(payload, max_frame)
    assert(#payload <= max_frame, "frame too large")
    return u32be(#payload) .. payload
end

function M.unpack(buffer, max_frame)
    if #buffer < 4 then
        return nil, buffer
    end
    local length = read_u32be(buffer:sub(1, 4))
    if length > max_frame then
        return false, "frame too large"
    end
    if #buffer < 4 + length then
        return nil, buffer
    end
    return buffer:sub(5, 4 + length), buffer:sub(5 + length)
end

return M
```

### 27.2 TCP Gateway

文件：`service/nav/tcp_gateway.lua`

```lua
local skynet = require "skynet"
local socket = require "skynet.socket"
local frame = require "service.nav.frame"
local codec = require "protocol.codec"

local M = {}

local function send_response(fd, config, request_id, response)
    local body = codec.encode_query_response(response)
    local envelope = codec.encode_envelope(
        config.query_cell_command, request_id, body, config.protocol_version)
    socket.write(fd, frame.pack(envelope, config.max_frame_bytes))
end

local function client_loop(fd, config)
    local buffer = ""
    while true do
        local chunk = socket.read(fd)
        if not chunk then
            break
        end
        buffer = buffer .. chunk
        while true do
            local payload, rest = frame.unpack(buffer, config.max_frame_bytes)
            if payload == false then
                socket.close(fd)
                return
            end
            if not payload then
                buffer = rest
                break
            end
            buffer = rest

            local ok, envelope = pcall(codec.decode_envelope, payload)
            if not ok or envelope.protocol_version ~= config.protocol_version then
                socket.close(fd)
                return
            end
            if envelope.command ~= config.query_cell_command then
                socket.close(fd)
                return
            end
            local decoded_ok, request = pcall(codec.decode_query_request, envelope.body)
            if not decoded_ok then
                socket.close(fd)
                return
            end
            local response = skynet.call("NAV_QUERY", "lua", "query_cell", request)
            send_response(fd, config, envelope.request_id, response)
        end
    end
    socket.close(fd)
end

function M.start(config)
    local listen_fd = socket.listen(config.host, config.port)
    socket.start(listen_fd, function(fd, addr)
        skynet.error("NAV_TCP_ACCEPT fd=", fd, " addr=", addr)
        skynet.fork(client_loop, fd, config)
    end)
    skynet.error("NAV_TCP_READY ", config.host, ":", config.port)
    return listen_fd
end

return M
```

Skynet 不同小版本的 `socket.start` 回调参数可能有细微差异。以当前仓库里实际的 `lualib/skynet/socket.lua` 为准核对一次；如果参数顺序不同，只改这一个 Gateway，不改变协议和 Query Worker。文档中的关键约束是：半包/粘包必须处理、长度必须限流、错误帧必须关闭连接、业务查询不把 client fd 传到 C++。

## 28. 启动 Skynet 并验证 Server 内部链路

文件：`service/main.lua`

```lua
local skynet = require "skynet"
local config = require "config.lesson1"
local codec = require "protocol.codec"
local bootstrap = require "service.nav.bootstrap"
local gateway = require "service.nav.tcp_gateway"

skynet.start(function()
    codec.load_descriptor("protocol/generated/server/navigation_query.pb")
    bootstrap.start(config)
    gateway.start(config)
end)
```

文件：`scripts/linux/run_server.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

export LD_LIBRARY_PATH="$ROOT/native/grid_map/build:$ROOT/native/lua_battle_nav/build:${LD_LIBRARY_PATH:-}"
exec "$ROOT/third_party/skynet/skynet" "$ROOT/service/main.lua"
```

启动前检查：

```bash
cd ~/workspace/skynet-battle-navigation-server
test -f assets/maps/battle_1001_v1.bmap
test -f protocol/generated/server/navigation_query.pb
test -f native/lua_battle_nav/build/battle_nav_lua.so
scripts/linux/run_server.sh
```

预期日志：

```text
PROTO_DESCRIPTOR_OK
NAV_QUERY_READY ... map=battle_1001 version=1
NAV_TCP_READY 127.0.0.1:19001
```

若只看到 `NAV_QUERY_READY` 没有 `NAV_TCP_READY`，先检查 Skynet socket 模块和端口占用；不要把问题归因到 BMAP。

### 28.1 Lua 内部 smoke test

文件：`scripts/linux/query_smoke.lua`

```lua
local skynet = require "skynet"

skynet.start(function()
    local response = skynet.call("NAV_QUERY", "lua", "query_cell", {
        map_id = "battle_1001",
        map_version = 1,
        position = { x_mm = 0, y_mm = 0, z_mm = 0 },
    })
    assert(response.result ~= nil)
    skynet.error("QUERY_SMOKE result=", response.result,
                 " grid=", response.grid_x, ",", response.grid_z)
    skynet.exit()
end)
```

第一次 smoke test 不要求坐标一定可走；它验证的是 descriptor、Lua dispatch、C Binding、MapRegistry 和 BMAP reader 都能形成闭环。坐标语义测试由 Unity 导出报告和 C++ 测试共同保证。

## 29. Unity C# Protobuf 客户端

### 29.1 安装 C# runtime

在 Tuanjie 工程中使用已固定的 `Google.Protobuf` 3.36.2 DLL，放到：

```text
G:\simbi\dev\skynet-battle-navigation-commercial-learning\unity\BattleNavigation\Assets\Plugins\Google.Protobuf.dll
```

不要把 `Google.Protobuf.dll` 从系统中随意复制一个“能加载”的版本。版本必须和 `protocol/VERSIONS.env`、`docs/ENGINEERING_DECISIONS.md` 一致。若 package manager 导入失败，先用 NuGet 包内容解压 DLL，再在 Unity Inspector 中确认平台勾选为 Editor/Standalone。

### 29.2 TCP framing

文件：`unity/BattleNavigation/Assets/Scripts/Protocol/LengthFrame.cs`

```csharp
using System;
using System.Buffers.Binary;

namespace BattleNavigation.Protocol
{
    public static class LengthFrame
    {
        public const int HeaderSize = 4;
        public const int MaxFrameBytes = 64 * 1024;

        public static byte[] Pack(byte[] payload)
        {
            if (payload == null) throw new ArgumentNullException(nameof(payload));
            if (payload.Length > MaxFrameBytes) throw new ArgumentOutOfRangeException(nameof(payload));
            var output = new byte[HeaderSize + payload.Length];
            BinaryPrimitives.WriteUInt32BigEndian(output.AsSpan(0, HeaderSize), (uint)payload.Length);
            Buffer.BlockCopy(payload, 0, output, HeaderSize, payload.Length);
            return output;
        }

        public static bool TryRead(ref byte[] buffer, out byte[] payload)
        {
            payload = null;
            if (buffer == null || buffer.Length < HeaderSize) return false;
            var length = BinaryPrimitives.ReadUInt32BigEndian(buffer.AsSpan(0, HeaderSize));
            if (length > MaxFrameBytes) throw new InvalidOperationException("frame too large");
            if (buffer.Length < HeaderSize + length) return false;
            payload = new byte[length];
            Buffer.BlockCopy(buffer, HeaderSize, payload, 0, (int)length);
            var remaining = buffer.Length - HeaderSize - (int)length;
            var next = new byte[remaining];
            Buffer.BlockCopy(buffer, HeaderSize + (int)length, next, 0, remaining);
            buffer = next;
            return true;
        }
    }
}
```

如果当前 Tuanjie API profile 不支持 `System.Buffers.Binary`，使用项目中已有的等价大端读写函数，不要改变线协议。端序必须由单元测试锁定。

### 29.3 ServerQueryClient

文件：`unity/BattleNavigation/Assets/Scripts/Protocol/ServerQueryClient.cs`

```csharp
using System;
using System.IO;
using System.Net.Sockets;
using Battle.Navigation.V1;
using Google.Protobuf;
using BattleNavigation.Protocol;

namespace BattleNavigation.Client
{
    public sealed class ServerQueryClient : IDisposable
    {
        private const uint ProtocolVersion = 1;
        private const uint QueryCellCommand = 1001;
        private static ulong nextRequestId = 1;
        private readonly TcpClient client;
        private readonly NetworkStream stream;

        public ServerQueryClient(string host, int port)
        {
            client = new TcpClient();
            client.Connect(host, port);
            stream = client.GetStream();
            stream.ReadTimeout = 3000;
            stream.WriteTimeout = 3000;
        }

        public QueryCellResponse Query(string mapId, uint mapVersion, long xMm, long yMm, long zMm)
        {
            var request = new QueryCellRequest {
                MapId = mapId,
                MapVersion = mapVersion,
                Position = new WorldPosition { XMm = xMm, YMm = yMm, ZMm = zMm },
            };
            var body = request.ToByteArray();
            var envelope = new Envelope {
                ProtocolVersion = ProtocolVersion,
                Command = QueryCellCommand,
                RequestId = nextRequestId++, Body = ByteString.CopyFrom(body),
            };
            var frame = LengthFrame.Pack(envelope.ToByteArray());
            stream.Write(frame, 0, frame.Length);
            var responseEnvelope = Envelope.Parser.ParseFrom(ReadFrame());
            if (responseEnvelope.ProtocolVersion != ProtocolVersion)
                throw new InvalidDataException("protocol version mismatch");
            if (responseEnvelope.RequestId != envelope.RequestId)
                throw new InvalidDataException("request id mismatch");
            return QueryCellResponse.Parser.ParseFrom(responseEnvelope.Body);
        }

        private byte[] ReadFrame()
        {
            var header = ReadExact(4);
            var length = (header[0] << 24) | (header[1] << 16) | (header[2] << 8) | header[3];
            if (length < 0 || length > LengthFrame.MaxFrameBytes)
                throw new InvalidDataException("invalid frame length");
            return ReadExact(length);
        }

        private byte[] ReadExact(int count)
        {
            var result = new byte[count];
            var offset = 0;
            while (offset < count)
            {
                var read = stream.Read(result, offset, count - offset);
                if (read == 0) throw new EndOfStreamException();
                offset += read;
            }
            return result;
        }

        public void Dispose()
        {
            stream?.Dispose();
            client?.Close();
        }
    }
}
```

`ServerQueryClient` 只用于编辑器调试窗口和自动化测试，不把它挂在战斗单位的 `Update()` 上。Lesson 1 没有高频寻路业务，网络查询频率也必须低；后续 BattleWorker 的模拟不能每 Tick 依赖外部 TCP。

### 29.4 查询调试窗口

文件：`unity/BattleNavigation/Assets/Editor/ServerQueryWindow.cs`

```csharp
#if UNITY_EDITOR
using UnityEditor;
using UnityEngine;
using BattleNavigation.Client;

namespace BattleNavigation.Editor
{
    public sealed class ServerQueryWindow : EditorWindow
    {
        private string host = "127.0.0.1";
        private int port = 19001;
        private string mapId = "battle_1001";
        private uint mapVersion = 1;
        private long xMm;
        private long yMm;
        private long zMm;
        private string result = "not queried";

        [MenuItem("Tools/Battle Navigation/Server Query")]
        private static void Open() => GetWindow<ServerQueryWindow>("Server Query");

        private void OnGUI()
        {
            host = EditorGUILayout.TextField("Host", host);
            port = EditorGUILayout.IntField("Port", port);
            mapId = EditorGUILayout.TextField("Map Id", mapId);
            mapVersion = (uint)EditorGUILayout.IntField("Map Version", (int)mapVersion);
            xMm = EditorGUILayout.LongField("X mm", xMm);
            yMm = EditorGUILayout.LongField("Y mm", yMm);
            zMm = EditorGUILayout.LongField("Z mm", zMm);
            if (GUILayout.Button("Query Server"))
            {
                try
                {
                    using (var client = new ServerQueryClient(host, port))
                    {
                        var response = client.Query(mapId, mapVersion, xMm, yMm, zMm);
                        result = $"{response.Result}: grid=({response.GridX},{response.GridZ}) " +
                                 $"height={response.CellHeightMm} area={response.Area} " +
                                 $"clearance={response.Clearance} message={response.Message}";
                    }
                }
                catch (System.Exception ex)
                {
                    result = ex.GetType().Name + ": " + ex.Message;
                }
            }
            EditorGUILayout.HelpBox(result, MessageType.Info);
        }
    }
}
#endif
```

## 30. Protobuf 与 TCP 测试

### 30.1 C# framing tests

文件：`unity/BattleNavigation/Assets/Tests/Editor/LengthFrameTests.cs`

```csharp
using NUnit.Framework;
using BattleNavigation.Protocol;

public sealed class LengthFrameTests
{
    [Test]
    public void BigEndianRoundTrip()
    {
        var input = new byte[] { 0x01, 0x02, 0x80, 0xff };
        var frame = LengthFrame.Pack(input);
        Assert.That(frame[0], Is.EqualTo(0));
        Assert.That(frame[1], Is.EqualTo(0));
        Assert.That(frame[2], Is.EqualTo(0));
        Assert.That(frame[3], Is.EqualTo(4));
        var buffer = frame;
        Assert.That(LengthFrame.TryRead(ref buffer, out var output), Is.True);
        Assert.That(output, Is.EqualTo(input));
        Assert.That(buffer.Length, Is.EqualTo(0));
    }

    [Test]
    public void PartialFrameWaits()
    {
        var frame = LengthFrame.Pack(new byte[] { 1, 2, 3 });
        var partial = new byte[5];
        System.Array.Copy(frame, partial, partial.Length);
        Assert.That(LengthFrame.TryRead(ref partial, out _), Is.False);
    }
}
```

### 30.2 Server protocol negative cases

用 Python 或 Lua 写一个只连接 `127.0.0.1:19001` 的测试客户端，依次验证：

```text
1. length=0，连接关闭或返回明确 BAD_REQUEST；
2. length=65537，服务立即关闭连接；
3. protocol_version=999，服务不执行地图查询；
4. command=9999，服务不执行地图查询；
5. Envelope body 不是 QueryCellRequest，服务不崩溃；
6. 两个 frame 一次 write，服务返回两个独立响应；
7. 一个 frame 分 3 次 write，服务仍能返回一个响应；
8. response.request_id 必须等于 request.request_id；
9. map_version 不匹配只能得到 MAP_VERSION_MISMATCH；
10. 世界坐标越界只能得到 OUT_OF_BOUNDS。
```

测试完成后查看 Server 日志，确认 malformed frame 不会触发 C++ 崩溃，也不会留下一个永远等待的协程。

## 31. 完整执行顺序

每一步先验证结果，再进入下一步；不要最后才发现版本或坐标错误。

### 31.1 Unity 导出

```text
1. 打开 G:\Tuanjie\Editors\2022.3.62t12\Editor\Tuanjie.exe。
2. 打开 unity\BattleNavigation\ 项目和 Battle_1001.unity。
3. 检查 BattleMapRoot：mapId=battle_1001、mapVersion=1、cellSizeMm=500。
4. 执行 Tools/Battle Navigation/Validate Map Authoring。
5. 确认没有 ERROR，报告包含 walkable、area、height、clearance。
6. 执行 Tools/Battle Navigation/Export BMAP。
7. 确认 .bmap 和 .json manifest 同时存在。
8. 运行 Unity EditMode 测试。
```

导出的 `.bmap` 是 Server 输入资产，不是 Server 运行时加载的 Unity 场景。Server 不需要 Unity、GameObject、Rigidbody、NavMeshAgent 或 Animator。

### 31.2 Server 构建与资产导入

```bash
cd ~/workspace/skynet-battle-navigation-server
protocol/build_server_descriptor.sh
lua protocol/check_descriptor.lua protocol/generated/server/navigation_query.pb
cmake -S native/grid_map -B build/grid_map -DCMAKE_BUILD_TYPE=Debug
cmake --build build/grid_map -j"$(nproc)"
ctest --test-dir build/grid_map --output-on-failure
cmake -S native/lua_battle_nav -B build/lua_battle_nav
cmake --build build/lua_battle_nav -j"$(nproc)"
scripts/linux/import_bmap.sh \
  ../skynet-battle-navigation-commercial-learning/unity/BattleNavigation/Assets/Generated/Maps/battle_1001_v1.bmap \
  assets/maps/battle_1001_v1.bmap
```

`import_bmap.sh` 必须检查 magic、header_size=64、cell_count 与文件长度、payload CRC，并拒绝覆盖不同 map_id 或 map_version 的现有文件。

### 31.3 启动和联调

```bash
cd ~/workspace/skynet-battle-navigation-server
scripts/linux/run_server.sh
```

Unity 打开 `Tools/Battle Navigation/Server Query`，输入 `127.0.0.1`、`19001`、`battle_1001`、`1`，再输入场景世界坐标。然后查询 `x_mm=999999999`，预期结果是 `OUT_OF_BOUNDS`，而不是崩溃或卡住。

## 32. 结果对照与调试证据

对一个成功查询至少保存五份证据：

```text
1. Unity Validator report：采样总数、walkable、area、height、clearance。
2. BMAP manifest：map_id、map_version、cellSizeMm、originMm、crc32。
3. C++ grid_map_test：同一坐标得到相同 GridPos、height、area、clearance。
4. Skynet log：NAV_QUERY_READY、NAV_TCP_READY、request_id、result。
5. Unity Query Window：Server 返回的 QueryCellResponse。
```

排查时按上游到下游核对，不要看到 Unity 结果不对就直接修改 C++ `WorldToGrid`。

### 32.1 负坐标人工算例

假设 `origin_x_mm=-5000`、`origin_z_mm=10000`、`cell_size_mm=500`，查询 `world_x_mm=-4999`、`world_z_mm=10501`：

```text
grid_x = floor((-4999 - (-5000)) / 500) = 0
grid_z = floor((10501 - 10000) / 500) = 1
```

负坐标不能使用 C++ 整数截断直接除法。文档和测试都必须覆盖左侧边界。

### 32.2 高度和 clearance

`height_mm` 是静态 walkable 高度，不是动态单位 Y 坐标；`clearance` 是静态占用下的邻域信息，不包含动态单位。Lesson 2 引入 `DynamicOccupancy` 后，动态阻挡只存在于战斗上下文，不能改写共享 `GridMap`。

### 32.3 LuaPanda 与 gdb

LuaPanda 断点放在 `service/nav/query_worker.lua` 的 `M.query`，观察 request 和 response。C++ 调试：

```bash
cd ~/workspace/skynet-battle-navigation-server
gdb --args third_party/skynet/skynet service/main.lua
```

```gdb
break battle::navigation::BMapReader::Read
break battle::navigation::GridMap::QueryWorld
break battle_nav_register
run
```

多个 Skynet Service 可同时读同一个 immutable `GridMap`；任何可写临时数组都必须属于调用上下文，不能放在 C++ 全局。

## 33. 常见故障

### Unity 找不到 Google.Protobuf

检查 `Assets/Plugins/Google.Protobuf.dll`、Inspector 平台勾选和重复 DLL。DLL 加载问题与 schema 无关，不要先重生成协议。

### descriptor type not found

运行 `sha256sum protocol/generated/server/navigation_query.pb` 和 `lua protocol/check_descriptor.lua ...`。如果 descriptor 能加载但 type 不存在，说明 Unity 和 Server 使用的 `.proto` 不是同一份；`.proto` 是唯一权威。

### 结果全部 OUT_OF_BOUNDS

对照 Unity manifest 的 originMm、BMAP header 的 originMm、Server 的 map_id/map_version，以及查询窗口是否把米转换成毫米。Server 不猜测单位。

### 网格编号相差一格

先跑 BMapBinaryTests 和 C++ 负坐标测试，再用 32.1 的人工算例对照。不要通过把 origin 加一个 cell 来修现象。

### TCP 偶发卡住

检查客户端是否完整读取 4 字节 header，Server 是否处理半包/粘包，`socket.read` 返回值是否符合当前 Skynet 版本。异常连接必须关闭。

### Unity 与 Server 结果不同

以 Server 为最终结果。对照顺序是同一 map_id/map_version → 同一毫米坐标 → 同一 BMAP CRC → 同一 C++ `GridMap::QueryWorld`。Unity 只负责 Authoring、导出和调试显示。

## 34. 第一课验收清单

```text
[ ] Unity 工程使用 G:\Tuanjie\Editors\2022.3.62t12。
[ ] Battle_1001 场景可打开，NavMesh Authoring 可复现。
[ ] Exporter 生成 BMAP 和 manifest，失败条件有明确错误。
[ ] BMAP header、payload、CRC 可独立读取和验证。
[ ] BMapReader 不做 struct cast，显式处理小端和长度溢出。
[ ] GridMap 加载后 immutable。
[ ] MapRegistry 可按 map_id 查找并拒绝版本不匹配。
[ ] Lua Binding 只暴露静态查询，没有全局可写 scratch。
[ ] lua-protobuf descriptor 可以加载。
[ ] TCP 使用 4 字节大端长度，最大 64 KiB。
[ ] Unity 使用 Google.Protobuf 生成类型发送真实 protobuf。
[ ] Server 返回 request_id、result、grid、height、area、clearance。
[ ] 半包、粘包、错误版本、未知命令、超大 frame 有测试。
[ ] Unity 结果不能覆盖 Server 结果。
[ ] 本课没有 A*、AgentProfile、Path、NavigationContext、DynamicOccupancy、BattleWorker 或 INavigationBackend。
```

最后一条是课程边界验收。只有在 Lesson 2 第一次出现“从 A 到 B 要寻路”时，才引入这些对象。

## 35. 课后练习与性能基线

1. 在 Unity Debug Window 增加“显示九宫格”按钮，发送九个相邻 WorldPosition 并绘制 Scene Overlay；不修改 BMAP、不把 GridPos 存成业务位置、每个 request_id 可追踪。
2. 复制 BMAP，只修改 payload 一个字节，确认 BMapReader 拒绝加载并打印 CRC mismatch；恢复正确文件后再确认 MapRegistry 注册地图。
3. 给 Envelope 增加调试字段，验证旧 Server 忽略未知字段；再修改字段号，观察测试失败。
4. 在 Linux 本机、Debug 构建、固定地图规模下执行 10000 次本地 `GridMap::QueryWorld`，记录总耗时、平均耗时、p50/p95/p99 和内存变化；再执行 1000 次 TCP 查询，分开记录网络/Protobuf 开销，并写明机器、编译类型、地图规模。

## 36. 下一课的自然入口

第一课结束时系统能回答：给定 battle_version 对应的 map_id/map_version 和 WorldPosition，Server 能验证静态地图并返回该位置的静态网格事实。

下一课只有在需求变成“从 A 到 B 要寻路”时才引入 `Path`、`AgentProfile`、`NavigationContext`、Grid A*、`DynamicOccupancy`、`BattleWorker`。Lesson 2 后段再把已有调用者的 Grid 能力整理成可替换 Backend；Lesson 3 才引入 `INavigationBackend`、`GridNavigationBackend`、`DetourNavigationBackend`，把 Recast Build 放进离线 `nav_builder`，把 Detour Query 放进运行时。

这就是本课的完成标准：Unity Authoring、BMAP、Native Reader、GridMap、MapRegistry、Lua Binding、Skynet Query 和 Unity Protobuf 调试链路都能被真实执行、独立测试、明确定位。
