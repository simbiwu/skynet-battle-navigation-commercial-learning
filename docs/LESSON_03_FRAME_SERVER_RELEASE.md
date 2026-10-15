# 第三课帧同步 Linux Server 发布

本流程复用现有 Skynet、Lua Protobuf、FlyWow Logger/Gateway 和 Frame Native 构建入口，不调用下载、Git 或工作区同步。只在 WSL Server 编辑源运行；Unity 单独交付。构建需要现有固定依赖源码、protoc、Linux 编译工具、CMake 和 Python；解压验收脚本需要 Python 3.12+ 及现有客户端测试依赖 cryptography。

从 WSL 主仓库根目录执行：

```bash
python3 server/scripts/linux/package_frame_server.py <新版本号>
python3 server/scripts/linux/verify_frame_release.py releases/lesson03-frame-server-<新版本号>-linux-x86_64.tar.gz
```

同版本已存在时拒绝覆盖。打包会更新本工作区的编译产物、Server descriptor/校验值、Gateway registry 和地图元数据；不更新 Unity 协议生成物。依赖版本不升级。包只允许当前 airnav_path 为空的 BMAP-only 配置。现有协议包含其它课程消息定义，descriptor 和 registry 保留完整统一合同，不截断或创建第二份协议源。

归档保留 server/ 与 shared/ 同级；白名单包含 Frame Battle/Gateway Lua 服务、实际依赖的凭据及调试开关模块、配置、Skynet Runtime、FlyWow Runtime、pb.so、Server descriptor、正式 BMAP/manifest。只携带调试开关模块是因为现有 Gateway 无条件 require；不交付 LuaPanda，运行环境不得启用 LUA_PANDA_ENABLE。

项目 Native 集中到 server/luaclib/：lesson_frame_native.so、libframe_core.so、flywow_gateway_crypto.so、flywow_logger.so。Skynet 原生服务/模块保留自己的 cservice/、luaclib/。Binding 的 RUNPATH 使用 $ORIGIN，解压后 Core 从相邻文件加载。排除 CMake 构建目录、对象、开发日志、临时文件、测试代码和 Unity。

清单 release_manifest.json 记录主仓库 HEAD、索引固定 FlyWow 指针与实际 FlyWow HEAD、实际源码 SHA256、平台架构、所有发布文件 SHA256（含地图及关键配置）。工作树可能有未提交修改；HEAD 不能代表实际发布内容，必须同时保留清单中的内容 hash。归档时间、属主、权限标准化；这保证归档过程稳定，不声称跨编译器或不同构建环境得到相同二进制。清单是完整性记录，未提供签名认证。

## 部署启动

从归档所在目录解压，然后在两个终端分别启动。先等 Battle 日志出现 FRAME_BATTLE_READY，再启动 Gateway：

```bash
tar -xzf lesson03-frame-server-2026.10.15.3-linux-x86_64.tar.gz
cd lesson03-frame-server-2026.10.15.3-linux-x86_64/server
./third_party/skynet/skynet config/frame_battle_process.lua
```

第二终端进入同一 server/ 目录：

```bash
./third_party/skynet/skynet config/frame_gateway_process.lua
```

各进程前台运行，按 Ctrl-C 停止。日志生成于 server/logs/。当前配置监听本机客户端 127.0.0.1:19021，Cluster 2537/2538；修改部署配置后应重新审核并记录其 hash。它不是已经开放外网的部署配置。运行机器须提供兼容 glibc、libstdc++、libgcc_s 与 OpenSSL 3；具体 ELF 解析结果见同名 dependencies.txt，尚未验证其它发行版的 ABI 兼容。

## 2026-10-15 实际验收

交付版本：2026.10.15.3，Linux x86_64，归档约 4.3 MiB。归档及 dependencies.txt、validation.json、tar.gz.sha256 位于 WSL 主仓库 releases/。

- Skynet、Lua Protobuf、FlyWow Logger/Gateway 和 Frame Native 构建成功；Logger CTest 与 Frame/Navigation CTest 4/4 通过。
- 重新生成并检查 Server descriptor；地图 BMAP hash 与正式 manifest 一致。
- 暂存和解压后逐文件清单及 ELF 依赖核对通过；未依赖源码构建树。
- 实际解压副本启动 Battle/Gateway，通过现有 frame_sync_integration.py，输出 FRAME_ONE_CLIENT_OK battle_id=2 frames=12；覆盖真实 P-256 握手、模拟版本拒绝、加入/Checkpoint、输入提交和连续 12 帧推送。当前用例只检查 hash 字段存在，不是跨端 hash 重演测试。
- 原端口已有用户 Battle，因此验收只在临时解压配置中改用 29021/3537/3538，现有测试客户端仅替换 PORT。validation.json 保存配置前后 hash。正式归档仍保留原配置；未验证原端口下同时启动新实例。
- 验收进程已全部回收；未停止已有用户实例。排除目录检查、篡改配置被清单拒绝检查通过。
- 未验证 Unity Editor/客户端交付、静态 AIRN、长期负载、完整网络故障矩阵、跨平台确定性、其它 Linux 发行版与跨机器部署。未运行新增 Benchmark 或并发专项测试。
- 未提交、推送或同步任何工作区。

重新验收使用 verify_frame_release.py；该脚本先核对解压内容与 ELF 依赖，再修改临时端口启动进程。它只用于可信的本仓库归档，测试代码从 WSL 开发源读取，测试代码不进入发布包。

## 发布脚本维护方式（2026-10-15 整理）

路径、文件清单集中在 `server/scripts/linux/package_frame_server.py` 顶部，验证脚本直接导入它，不再复制第二套路径。通常只维护下面两个区块。

| 要调整的内容 | 修改位置 | 会自动跟随的内容 |
| --- | --- | --- |
| 归档输出目录 | `PATHS["output"]` | tar.gz、依赖报告、校验和；验证报告写在所验收归档旁 |
| Frame Native 构建目录 | `PATHS["frame_build"]` | 传入已有构建脚本的目录、CTest 和 Native 收集来源 |
| 包内项目 Native 目录 | `PATHS["native_release"]` | 四个项目 .so 的目标、发布 Lua 搜索路径 |
| Lua 服务/模块等来源目录 | `PATHS` 对应项 | 白名单中引用该项的来源；通常保留仓库相对布局 |
| 新增/删除发布文件 | `RELEASE_FILES` | 复制、清单 hash 与依赖扫描 |
| 验证端口 | `VERIFY_PORTS` | 临时 Lua 配置及现有客户端 PORT |
| 启动顺序、配置或就绪标记 | `PROCESSES` 与 `PATHS` 对应项 | README、包内 runtime 合同和解压验证 |

### 修改路径

`PATHS` 的值相对仓库根目录。派生项使用 `{字段名}`，按依赖顺序写在被引用字段后面。脚本启动时统一展开；不写 WSL 用户目录或 Windows 绝对路径。

例如，修改两个值即可调整 Native 构建产物来源和包内集中目录：

```python
"frame_build":    "{server}/build/frame_sync_release",
"native_release": "{server}/runtime_native",
```

`frame_build` 会通过现有 `FRAME_SYNC_BUILD_DIR` 传给 Native 构建脚本；`native_release` 会同时用于复制目标和暂存配置的搜索路径。FlyWow 构建入口仍使用其本身约定的正式输出位置。

`DEVELOPMENT_NATIVE_SEARCHES` 表示开发 Lua 配置中已有的路径基线。仅改构建输出或发布目录时不改它；只有修改了开发进程配置本身，才同步这张基线表。替换基线缺失会直接失败，避免包中仍指向构建目录。

这些配置集中管理的是发布流程。移动真实源码模块、改变 Lua require 层级或正式地图位置时，还必须同步所属模块的 CMake、Lua 配置、地图准备脚本等真实调用合同。Server/shared 的同级关系不能仅作为普通复制目录随意打散。地图路径与白名单不一致会拒绝打包。

### 增删发布文件

`RELEASE_FILES` 每一项是 `(来源路径或glob, 包内目标路径)`。所有路径都相对仓库根或包根：

```python
# 递归收集该目录的 Lua 文件，包内保持原相对路径。
("{server}/lualib/example/**/*.lua", None),

# 只收集单个文件，包内保持原相对路径。
("{config}/example.lua", None),

# 从构建目录拿单个 .so，放到集中 Native 目录。
("{frame_build}/example.so", "{native_release}/example.so"),
```

`**/*.lua` 递归匹配，`*.so` 只匹配当前一层。指定目标的规则只用于单个来源文件；不拿它批量重命名整个目录。缺失来源、空匹配、重复目标、越界路径都会失败，新增必需文件不能静默漏掉。

删除文件时移除对应条目；若它来自整目录 glob，按实际需要缩小规则。先确认运行代码已不再 require/读取该文件，再打包和验收。新增 Native 的编译目标仍须先接入已有构建链；加入白名单不会凭空编译一个未定义目标。

### 注释与验证

两个脚本的模块说明、维护区块、函数说明和关键操作都有中文注释，覆盖参数/路径基准、输入输出、副作用、失败行为、归档临时文件、Git 索引字段来源，以及进程创建、等待和停止边界。普通直观赋值不逐行翻译。

每次修改清单或路径后执行：

```bash
python3 server/tests/frame_release_test.py
python3 server/scripts/linux/package_frame_server.py <新版本号>
python3 server/scripts/linux/verify_frame_release.py releases/lesson03-frame-server-<新版本号>-linux-x86_64.tar.gz
```

验收失败也会在归档旁保存 `.validation.json`，包含错误、日志及本次子进程停止结果。端口按配置键精确改写，不再对整份文件盲目替换相同数字。新包的清单保存 `runtime` 布局，后续验证优先使用包内布局，而非套用当前源码的目录；已交付 .3 旧包保留原布局兼容分支。

本次默认流程实际生成并验收 `2026.10.15.4`：Native CTest 4/4、双进程就绪和现有单客户端 12 帧流程通过。另用独立构建目录 `server/build/frame_sync_release_check`、发布 Native 目录 `server/runtime_native` 和隔离输出目录生成维护测试包，验证目录调整后的实际构建与运行。维护测试产物放在 `releases/maintenance-check/`，不是替换原交付包。
