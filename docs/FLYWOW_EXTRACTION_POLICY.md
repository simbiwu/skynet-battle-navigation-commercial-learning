# FlyWow Extraction Policy

本文件只在**修改 Skynet-FlyWow、从课程抽取通用模块、更新 FlyWow submodule、讨论跨项目复用边界**时读取。

## 1. 两个仓库保持独立

本项目使用的 FlyWow 唯一开发源：

```text
~/workspace/skynet-battle-navigation-commercial-learning/server/third_party/skynet-flywow
```

远端：

```text
https://github.com/simbiwu/Skynet-FlyWow.git
```

课程仓库通过：

```text
server/third_party/skynet-flywow
```

Git submodule 固定一个已经验证的 FlyWow 提交。

主仓库提交的是 submodule gitlink，不复制 FlyWow 源码历史。

正常克隆和构建必须依赖：

```bash
git clone --recurse-submodules ...
# 或
git submodule update --init --recursive
```

不要直接修改或使用 `/home/simbi/workspace/skynet-flywow` 作为本项目开发源。

## 1.1 功能模块目录

FlyWow 根目录按功能模块组织，模块之间同级：

```text
gateway/
navigation/
```

模块自己的运行时、Native、客户端、Unity、测试、工具和构建脚本都放在模块目录内，例如 `gateway/lualib/`、`gateway/native/`、`navigation/unity/`。FlyWow 根目录不直接放模块级的 `lualib/`、`native/`、`service/`、`unity/`、`clients/`、`tools/` 或测试目录；根级 `scripts/ci/` 只属于仓库质量门禁。

## 2. 产品目标、时点与抽取原则

FlyWow 是面向 MMO/SLG 的 Skynet Server 框架，目标包含可配套使用的地图、导航、Battle、技能与客户端接入模块。“业务无关”指不写死某个游戏的地图、兵种、技能公式和表现资源，不排斥框架提供通用战斗与技能机制。

第三课完成在线指令、自动战斗和 Unity 表现闭环后，集中评估并抽取已验证的通用能力；不增设第 3.5 课，不把 FlyWow 抽取列为第三课通关条件，也不要求先完成可选第四课 Recast 或未来 H5 2D 项目。用户已明确授权本次地图/导航抽取及旧 Gateway 目录整理，实施范围限于已验证的 Unity 地图生产与 Native 导航；Battle、Skill 和 Replay 业务继续留在课程宿主。当前实施与开发接入见 [Navigation 抽取记录](FLYWOW_NAVIGATION.md)。

课程先解决真实业务问题，再判断是否值得抽取：

```text
课程中的真实问题
-> 在课程链路中实现、运行、调试、测试
-> 证明边界稳定且与具体业务无关
-> 在 FlyWow 中整理公开合同、独立测试和接入示例
-> 课程/其他项目通过公开边界重新接入
```

禁止为了“未来可能复用”提前创建空框架。

只有同时满足以下条件才考虑抽取：

- 已有真实调用者；
- 实现已工作；
- 边界能由测试证明；
- 与某个项目的具体 SLG/MMO 战斗规则无关；
- 不需要让网络、地图、导航、热更等模块互相反向依赖；
- 抽取后课程仓库仍可独立运行和验证。

## 3. 配套模块与预期可复用方向

第三课后抽取时，按真实代码划分并验证以下模块；同处 FlyWow 仓库不代表必须一起安装或运行：

| 模块 | FlyWow 提供 | 游戏项目提供 |
| --- | --- | --- |
| Unity Package | Editor 侧 Bake、BMAP 导出/校验/发布；Runtime 侧坐标转换及服务端地图、路径、事件的接收和表现适配；测试与示例 | 具体场景、地图资产、模型、动画和特效 |
| Server Map / Navigation | 地图格式与版本校验、只读加载、Native Grid 寻路、动态占位、Lua/Skynet 接入与业务规则接入点 | 地图发布资产、AgentProfile 数值、单位通行规则 |
| Server Battle / Skill | 已验证的战斗实例与固定 Tick 机制、权威移动、事件输出、常见目标选择及技能效果的组合能力 | 阵营关系、伤害公式、特殊技能与项目配置 |
| H5 2D 接入 | 预留版本化坐标、地图和事件合同；真实 H5 消费者出现后再提供对应实现 | 2D 地图输入、渲染和产品表现 |

实际 Bake 出的地图及其发布版本属于游戏资产；FlyWow Package 可以携带测试或接入示例，不把某个游戏的地图内置为框架数据。Server Runtime 只消费已发布并校验的资产，不直接读取 Unity/H5 工程目录。各模块分别提供公开 API、版本兼容说明、独立测试与最小接入示例；整套方案另提供前后端联调示例。

候选包括但不限于：

```text
网络接入与连接生命周期
协议 framing / codec / dispatch
配置、日志、指标和错误合同
Service 启停与依赖注入
代码/配置热更、状态迁移与回滚
静态地图资产加载与查询
导航查询运行时
测试、诊断和部署工具
```

“候选”不代表必须现在抽取。

## 4. 模块依赖

FlyWow 模块保持单向依赖：

```text
Gateway -X-> 地图实现
Gateway -X-> Battle 业务
地图/导航 -X-> 网络
基础模块 -X-> Battle/SLG 具体 DTO
Battle Core -X-> Unity/H5/Protobuf DTO
Navigation -> 地图查询
Skill Core -X-> 具体 GridMap / A* 实现
```

技能核心负责施放、冷却、目标与效果结算。指定单位回血或施加状态只需要 Battle 单位状态；范围技能需要 Battle 的位置和空间目标查询；遮挡判断按需使用地图查询，冲刺或瞬移按需使用导航通行/落点查询。由 Battle 组装这些可选能力，不要求所有技能先加载 Map 和 Navigation。FlyWow 可提供 Map + Navigation + Battle + Skill 的整套接入示例，也允许单独使用其中的模块。

常见技能的目标能力包括单体和范围（AOE），效果能力包括伤害、治疗与状态；业务通过配置与受控扩展实现特殊规则。抽取时只发布第三课或后续真实案例验证过的组合，不能把目标设计清单当作已完成功能。第三课只要求瞬发、表现型弹丸和逻辑型弹丸案例，不要求完整 Buff 系统；治疗、AOE 及 Buff 的持续时间、周期、叠加、刷新和驱散等尚未验证的行为，须有真实案例与测试后才作为框架能力发布。

业务工程通过 composition root 注入：

```text
地图资产
导航 profile / runtime
Battle Service
客户端 Adapter
配置与外部依赖
```

`common` 只放真正稳定、多个模块共同需要的最小合同，例如：

```text
错误结构
版本标识
少量值类型
```

禁止把 `common` 变成无归属代码、业务 DTO、全局状态或循环依赖的收容目录。

## 5. 多地图/多空间演进

当前课程真实消费者是 2.5D Ground Grid，但公共边界不能把 Unity 或 `X/Z + 高度` 写死到长期业务层。

未来至少区分：

```text
2.5D ground：逻辑 X/Z 网格，可查询地表高度、Area、Clearance
top-down 2D：逻辑二维平面，通常固定高度或无高度字段
side-view 2D：平台、重力、跳跃语义；不能伪装成 top-down 2D
```

共同业务合同使用：

```text
整数世界/逻辑坐标
map_id
map_version
内容 hash
```

地图 manifest 至少声明：

```text
space_type
坐标轴
原点
Cell 尺寸
资产格式版本
hash
```

长期 `Path`、`BattleEvent` 和业务位置不得直接暴露 `GridPos`、`grid_z` 或某客户端坐标轴。

Unity BMAP、H5/Tiled/JSON 等只是离线输入来源；Server Runtime 不读取客户端工程目录。

现在即可定义并验证跨端的整数坐标、`map_id`、`map_version`、内容 hash 和资产发布合同；第三课后也可抽取已验证的 2.5D Grid 实现。只有第二个真实地图消费者出现并通过测试后，才从两个实现的共同调用面提取新的多空间抽象，不能把单个 Grid 实现包装成已经支持全部 2D/2.5D 地图的通用 Backend。

## 6. 每个准备抽取的模块必须回答

```text
公开 API 和版本合同是什么？
允许依赖什么，禁止依赖什么？
Service / Lua State / native object / buffer / fd / state 由谁拥有？
配置如何注入？是否依赖全局名字或固定路径？
怎样启动、停止、重载、回滚并报告失败？
怎样单独 build / test / benchmark / diagnose？
怎样从课程仓库迁移到 FlyWow 并保留历史与测试？
业务仓库需要保留什么 Adapter？
Unity Editor/Runtime Package、Server Native/Lua 模块与协议/资产版本怎样兼容？
技能的通用效果、可选空间查询和项目专属规则如何分界？
```

不能回答这些问题时，不应急着抽取。

## 7. 修改两个仓库时

禁止：

```text
用一个仓库目录直接覆盖另一个仓库
在课程仓库维护 FlyWow 源码副本
为了方便联调把两个仓库历史混在一起
未经用户明确要求自动 Push
```

正确流程：

```text
1. 分别修改和验证两个仓库。
2. FlyWow 先形成可独立验证的提交。
3. 课程仓库更新 submodule gitlink。
4. 在课程仓库重新做集成验证。
5. 两边分别保留自己的提交历史和版本边界。
```

## 8. Gateway 当前合同

当前课程运行时 Gateway 由 FlyWow 提供。业务仓库维护：

```text
.proto
config/gateway.lua
构建调用和生成物目标位置
```

FlyWow 负责 Gateway transport 与 registry 生成基础设施。

当前约束：

```text
Gateway 拥有 listen/client fd、connection、transport 生命周期
TCP/WebSocket 共用协议合同和业务 handler
Query/Battle Service handle 由 composition root 显式注入
Gateway 不拥有地图或 Battle 状态
Map/Battle Process 不接触客户端 fd、frame buffer 或 Protobuf codec
```

Gateway 入站按帧顺序解码后用本地 `skynet.send` 投递，不等待业务响应；出站通过独立 `gateway_response` 接收响应并编码发送。Gateway 不保存业务请求等待表，也不依赖 Cluster；项目 Proxy 负责跨进程转发与有界返回路由。业务接入使用可选的 `gateway.endpoint` 薄模块。

协议、Gateway 和进程拆分的详细已确认决策以 `docs/ENGINEERING_DECISIONS.md` 中 D029、D030、D033、D039 为准。
