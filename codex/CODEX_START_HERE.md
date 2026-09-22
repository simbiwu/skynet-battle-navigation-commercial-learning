# Codex Start Here

## 这是全新三课项目

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

Lesson 2 再完整读：

```text
docs/NAVIGATION_ABSTRACTION.md
docs/NATIVE_NAV_API.md
docs/LESSON_02_PRACTICAL.md
codex/LESSON_02_SPEC.md
```

Lesson 3：

```text
docs/POLYGON_NAV_ASSET_FORMAT.md
docs/LESSON_03_PRACTICAL.md
docs/REFERENCES.md
codex/LESSON_03_SPEC.md
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

Lesson 3：

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

不要为了第三课，第一课就创建最终架构所有空类。

## 工程目录也渐进

Lesson 1：

```text
native/grid_map/
service/nav/
```

Lesson 2 业务成熟后，再根据实际代码迁移/整理为：

```text
native/navigation/common/
native/navigation/grid/
```

这次迁移本身就是教学内容：

> 如何从一个工作实现抽出稳定接口。

Lesson 3 才加：

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
refactor: extract navigation backend contract
feat: add unity replay
perf: add grid benchmark
```

Lesson 3：

```text
feat: add nav source exporter
feat: add recast nav builder
feat: add detour backend
feat: add multilayer and off-mesh traversal
perf: compare navigation backends
```
