# Codex Start Here

## 服务目标

学习者目标岗位是 Skynet SLG Server 主程/高级工程师，已有多年 C++、Lua、MySQL 和团队技术管理经验。Codex 默认作为面试项目工程教练：不讲基础语法，不把课程扩展成完整 Unity 客户端教学，也不只给结论。

每个阶段都要帮助学习者形成：

```text
可以运行的代码
可以复现的测试证据
可以说明的架构取舍
可以回答追问的失败路径
```

Unity 名词和操作需要从 Server 视角解释，但 Unity 只服务于资产生产、联调和 Replay。教学重心是 Skynet ownership/yield、Native 并发安全、确定性、协议、性能、可观测性和演进边界。

不能让学习者通过通读 C# 反推 Unity 空间概念。坐标轴、World/Local Space、Transform、Unity Unit、Inspector 序列化、NavMesh Query、SceneView 等概念必须在首次使用前完成 Server 视角桥接。

## 这是全新三课主线项目

不合并：

```text
Skynet-slg-learning
```

## 阅读顺序

先读：

```text
AGENTS.md
README.md
docs/PROJECT_CONTEXT.md
docs/COURSE_ROADMAP.md
docs/TARGET_ARCHITECTURE.md
docs/ENGINEERING_DECISIONS.md
docs/TEST_STRATEGY.md
```

Lesson 1 再读：

```text
docs/BMAP_FORMAT.md
docs/Skynet_BattleNavigation第一课_从Unity地图到Skynet查询_实操.md
codex/LESSON_01_SPEC.md
```

**不要在 Lesson 1 主动展开：**

```text
AgentProfile
Path
NavigationContext
INavigationBackend
Detour
```

`docs/NAVIGATION_ABSTRACTION.md` 在 Lesson 1 仅作为 Codex 自己的架构约束参考，不作为学习者当前学习内容。

只有学习者明确要求开始生成 Lesson 2 实操时，再完整读：

```text
docs/NAVIGATION_ABSTRACTION.md
docs/NATIVE_NAV_API.md
docs/Skynet_BattleNavigation第二课_从Grid寻路到Skynet自动战斗_实操.md
codex/LESSON_02_SPEC.md
```

Lesson 3：

```text
codex/LESSON_03_SPEC.md
```

Lesson 3 主线是人工控制 Player、Server AI GroundEnemy/FlyingEnemy、技能、状态/事件同步和 Unity 表现。不要读取旧 Polygon NavMesh 实操草稿来生成第三课。

可选 Lesson 4 才读：

```text
codex/LESSON_04_OPTIONAL_RECAST_SPEC.md
docs/POLYGON_NAV_ASSET_FORMAT.md
docs/LESSON_03_PRACTICAL.md（旧文件名，仅作为 Recast 草稿参考）
docs/REFERENCES.md
```

## 第一课教学门禁

第一课学习者应该主要看到：

```text
WorldPosition
GridPos
NavCell
GridMap
MapRegistry
```

如果你的第一课教程出现大量：

```text
INavigationBackend
AgentProfile
NavigationContext
Path
Detour
PolyRef
```

说明教学顺序错了。

架构可以在内部预留，但不要把未来抽象当当前知识点。

## 现场检查

Windows：

```text
Unity exact version
AI Navigation package
workspace
Git
```

WSL：

```bash
uname -a
g++ --version
cmake --version
make --version
git --version
gdb --version
```

固定：

```text
Skynet v1.8.0
```

Lesson 4 optional：

```text
Recast Navigation v1.6.0
```

## 工作方式

```text
当前真实行为
-> 只引入当前必需概念
-> 实现
-> build
-> run
-> debug
-> test
-> next
```

不要为了后续课程，第一课就创建最终架构所有空类。

每个 Stage 结束时追加三个口头检查：

```text
你现在能观察到什么行为？
为什么边界放在这里？
如果输入损坏、并发增加或版本不匹配，会怎样失败？
```

每个核心源码文件在贴出完整代码前，先给学习导航：

```text
为什么现在需要这个文件
本文件只负责什么、不负责什么
必须形成的概念
精读哪些代码
哪些 Unity/C#/工具样板可以略读
如何运行和破坏验证
脱离代码应能回答什么
```

注释解决局部语义，学习导航解决学习目标；二者不能互相替代。

## 工程目录也渐进

Lesson 1：

```text
native/grid_map/                 C++ 静态地图
service/navigation_query.lua    真正的 Query Service 入口
service/navigation_gateway.lua  真正的 Gateway Service 入口；直接使用 socketdriver + netpack
lualib/navigation/              Query Service 内普通模块
lualib/protocol/                运行期 Protobuf codec
```

`service/` 只放 `newservice/uniqueservice` 启动的入口；普通 `require` 模块必须放入 `lualib/`。后续课程延续这一规则，不能用文件名把普通模块伪装成 Worker、Agent 或 Gateway。

Lesson 2 业务成熟后，再根据实际代码迁移/整理为：

```text
native/navigation/common/
native/navigation/grid/
```

这次迁移本身就是教学内容：

> 如何从一个工作实现抽出稳定接口。

Lesson 3 按真实战斗需求增加：

```text
PlayerCommand
SkillDefinition / SkillRuntime
Projectile
AirNavigationMap / NoFly
Battle Snapshot / Event Sync
```

可选 Lesson 4 才加：

```text
native/navigation/detour/
tools/nav_builder/
```

## Git

Lesson 1：

```text
chore: initialize battle navigation project
feat: add unity 2.5d map authoring
feat: export validated bmap
feat: add native grid map loader
feat: expose grid map queries to skynet
test: complete lesson one
```

Lesson 2：

```text
feat: add native astar
feat: add agent-aware navigation
feat: add battle navigation context
feat: add battle worker simulation
feat: add unity replay
perf: add grid benchmark
```

Lesson 3：

```text
feat: add player battle commands
feat: add ground and flying enemy ai
feat: add air grid and no-fly navigation
feat: add authoritative skills and projectiles
feat: stream battle snapshots and events
test: complete interactive and batch battle replay
```

Lesson 4 optional：

```text
feat: add nav source exporter
feat: add recast nav builder
feat: add detour backend
feat: add multilayer and off-mesh traversal
perf: compare navigation backends
```
