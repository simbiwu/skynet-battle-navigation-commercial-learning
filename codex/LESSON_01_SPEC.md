# Lesson 01 Spec

主文档：

```text
docs/Skynet_BattleNavigation第一课_从Unity地图到Skynet查询_实操.md
```

## 本课只教

```text
WorldPosition
GridPos
NavCell
BMAP
GridMap
MapRegistry
Lua C Binding
Skynet Query
Protobuf Query Contract
Unity -> Skynet End-to-End Query
```

## 本课不教

```text
AgentProfile
Path
NavigationContext
A*
BattleWorker
INavigationBackend
Detour
```

可以在文档结尾用一句话说明：

> 后面会有第二种导航实现，所以业务位置不长期绑定 GridPos。

不能展开未来接口。

## 完成

```text
[ ] Unity scene
[ ] navigation authoring
[ ] BattleMapRoot
[ ] exporter
[ ] height
[ ] area
[ ] clearance
[ ] single-layer validation
[ ] BMAP
[ ] manifest
[ ] overlay
[ ] C++ reader
[ ] immutable GridMap
[ ] MapRegistry
[ ] Lua binding
[ ] multi-service query
[ ] pinned lua-protobuf / protoc / C# runtime
[ ] generated server descriptor and Unity C# types
[ ] TCP length framing and malformed packet tests
[ ] Unity real Protobuf query against Skynet
[ ] corruption tests
[ ] golden coordinate test
[ ] ALL_TESTS_OK
```

## 教学文档门禁

学习者默认熟悉 C++ / Lua / Server 工程，但不默认理解 Unity 空间和 Editor 术语。

坐标计算首次举例时先使用非负数；在真实地图数值中使用负坐标前，先说明世界零点、负轴方向和 Bounds 才是合法性判断依据。

空间概念首次成为实操前置时，在相邻正文提供带方向、单位、起点和边界标注的概念图，并说明学习者应从图中读出什么。

同一组空间概念复用一张底图逐层讲解；在学习者能指图说明 Grid、origin、Cell、Bounds 和 Cell Center 前，不展开坐标公式。

文档过渡到新文件或新类之前，先解释它的职责、它所需的输入以及后续谁使用它。`BattleMapRoot` 在进入代码前必须先被解释为“当前 Scene 的 Server Grid 导出配置”。

课程正文不得引用与某个学习者的历史对话、反馈过程或修改经过；必须保持独立、自洽，可直接提供给任何具有课程预设背景的学习者。

在对应代码首次出现前必须解释：

```text
Unity X/Y/Z 与 XZ 地面
World Space / Local Space
Transform 与父子层级
Unity Unit = 1 meter 的项目约定
Vector2 / Vector3 在当前字段中的语义
Origin / Size / Bounds / Cell Center
Inspector 序列化与运行时校验的区别
NavMesh Triangulation / SamplePosition / Area Mask
SceneView / Gizmo / Handles 只负责观察
```

每个核心文件必须标出“精读 / 略读 / 输入 / 输出 / 失败 / 自测”。只有完整代码和行内注释，不算完成教学文档。

每个文件步骤还必须明确标注操作类型：新建文件、完整替换已有文件、局部修改或只阅读。只写“完整路径”再跟代码块，视为未完成的实操步骤。

每节围绕一个当前实际问题推进，并按“为什么现在需要、最小必要概念、实际操作、后续使用者、验证结果”组织。每次要求新建、替换或修改文件前，先说明为什么需要该文件、哪个步骤会直接使用它、完成后会观察到什么结果。只要求学习者新增或修改当前执行链马上要用的文件；未来阶段的类型、格式常量和辅助工具必须延后到第一次真实使用处。不得按最终文件清单连续安排机械建文件步骤。若工具实现不是学习目标，应提供可运行工具并教清楚其输入、输出和验证方法。

使用自然直接的中文陈述，少用模板化对照句，尤其避免反复写“不是……而是……”。需要区分概念时，直接分别说明各自含义和用途。

学习者有资深 C++/Lua Server 背景。解释数据时优先使用 record/struct、数组、索引和序列化等程序员熟悉的概念；像“每格一条记录、整图按索引存入数组”这类简单结构用几句话和具体尺寸说明，不扩写成术语导览。

## 面试讲解验收

完成代码不等于完成第一课。学习者还需要脱离文档讲清：

```text
[ ] Unity Scene、NavMesh、BMAP 和运行时 Protobuf 的边界
[ ] WorldPosition / GridPos 的职责与负坐标换算
[ ] 2.5D one XZ -> one walkable height 的能力和限制
[ ] BMAP header、payload、CRC、字节序与拒绝策略
[ ] GridMap immutable 和 MapRegistry 启动期 ownership
[ ] Lua C Binding 为什么保持薄，不持有业务状态
[ ] 多 Skynet Service / 多 OS Thread 查询的安全条件
[ ] MapService 为什么不做所有高频查询的永久代理
[ ] malformed frame、错误版本、错误地图和越界怎样失败
[ ] Unity / Native / Skynet golden result 怎样互相证明
```

面试陈述结构：

```text
当前问题
-> 约束
-> 设计选择
-> 真实执行链
-> 测试证据
-> 已知限制
-> 何时进入 Lesson 2
```
