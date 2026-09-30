# Codex Teaching Guide

本文件只在**编写/重写课程教程、逐阶段辅导学习者、解释首次出现的 Skynet/Unity/Native 概念**时读取。普通代码实现、修 Bug、补测试不需要默认加载。

## 1. 学习者基线

可以默认学习者：

- 熟悉 C++ / Lua；
- 有多年 MMO Server 经验；
- 已理解 Skynet Service / Lua State / call / send / dispatch 基本概念；
- 关注性能、并发、内存、部署和维护；
- 不需要 C++ / Lua 基础语法教学；
- 不默认熟悉 Unity/团结引擎 Authoring 工作流。

目标岗位是 Skynet SLG Server 主程或高级工程师。

教学产出要帮助学习者形成：

```text
可以运行的代码
可以复现的测试证据
可以说明的架构取舍
可以回答追问的失败路径
```

## 2. 教学主线

采用：

```text
当前真实问题
-> 为什么现在需要这个概念
-> 最小必要知识
-> 实现
-> build/run/debug/test
-> 观察结果
-> 失败路径
-> 再进入下一步
```

不要先展示最终架构所有类型，再倒过来解释为什么存在。

“商业级”来自：

```text
边界正确
ownership 清楚
错误显式
资源有界
数据可验证
测试真实
后续可演进
```

不是类、接口和目录数量。

## 3. 架构预留不等于提前教学

Lesson 概念必须按对应 Spec 的首次真实需求出现。

例如：

```text
Lesson 1 当前没有 A -> B 的寻路需求，就不要先讲完整 AgentProfile / Path / NavigationContext。
Lesson 2 只有 Grid 实现时，不为了未来 Detour 先建立双 Backend。
Lesson 3 没有 Recast/Detour 需求，就不把 Polygon NavMesh 塞进交互战斗主线。
```

教程可以用一句话说明未来演进方向，但不要让学习者提前承担未来模块的认知成本。

## 4. 每个文件出现前先回答职责

任何类名、文件名、工具链列表出现前，先用一句直白的话说明：

```text
它解决什么当前问题？
谁会直接使用它？
完成后可以观察到什么结果？
```

每个核心源码文件在完整代码前提供学习导航：

```text
本文件解决的问题
本节必须掌握的概念
必须精读的类型/字段/函数
可以略读的语法或样板
输入、输出和失败条件
如何运行和破坏验证
脱离代码后应能回答什么
```

代码注释解决局部 WHY；学习导航解决学习目标，两者不能互相替代。

## 5. Skynet 核心机制第一次出现时

不能只给可复制代码。第一次进入真实链路时必须就地说明：

```text
它解决的当前问题
属于哪个 Service / Lua State
调用者、接收者和状态 Owner
回调参数与返回值从哪里产生
消息经过 pack / unpack / dispatch 的顺序
哪里可能 yield
yield 前后哪些引用/身份需要重新验证
buffer / fd / queue / userdata / native object ownership
失败如何传播：回包、拒绝、断连还是终止启动
固定 Skynet 版本中可核对的源码/官方示例位置
如何用日志、断点、负向测试验证
```

课程实际使用到时至少覆盖：

```text
newservice / uniqueservice
Service handle 显式注入
require 与独立 Lua State 的区别
skynet.start
skynet.dispatch
skynet.call / skynet.send / skynet.retpack
skynet.register_protocol
session / source / command 参数来源
PTYPE_SOCKET
socketdriver / netpack
Service 消息协程与 yield
```

自定义协议必须解释稳定公式：

```text
dispatch 参数 = session + source + unpack(msg, sz) 的全部返回值
```

并分别说明 `unpack`、`dispatch`、可选 `pack` 的职责。

IDE 注解、命名函数和类型 stub 只提高开发效率，不能替代协议合同。

## 6. Unity/团结引擎概念桥接

学习者不是客户端转岗，因此 Unity 只学到资产生产、联调、Replay 和边界定位所需程度。

以下空间/Editor 概念第一次成为当前步骤的前置条件时，必须先解释：

```text
坐标轴
World / Local Space
Transform
Unity Unit
Inspector 序列化
Bounds
NavMesh Query / Sampling
SceneView
```

首次解释至少包含：

```text
是什么
在 Editor 哪里观察
与熟悉的 Server 概念如何类比
为什么当前步骤需要
属于 Authoring / Asset / Client Runtime / Server Runtime 哪个边界
一个具体数值例子
常见误解
```

不能要求学习者通读 C# 后自己反推 Unity 空间语义。

## 7. 空间概念的图和数值

坐标轴、World/Local、Bounds、Grid Cell、2.5D 限制、NavMesh Sampling 等第一次出现时，正文相邻位置必须有概念图。

图必须标注：

```text
方向
起点
单位
关键边界
```

并紧跟“读图要点”。

优先复用同一张底图逐步增加信息，不连续切换坐标、数值、视角和比喻。

坐标/offset/边界首次举例先用非负数建立模型；第一次必须使用负坐标前，先说明：

```text
坐标零点在哪里
负轴方向是什么
负坐标 != 非法坐标
```

再代入工程真实数值。

## 8. 教程文档操作说明

每次要求操作文件时明确标注：

```text
新建文件
完整替换
局部修改
只读
```

操作前先说明：

```text
为什么需要这个文件
哪个步骤直接使用
完成后能看到什么
```

不要连续让学习者机械创建未来才使用的文件。

工具代码不是当前学习重点时，可以提供可运行工具，但必须解释输入、输出、运行方式和验证结果；不要求为“教学完整”逐行手写所有工具样板。

## 9. 教程写作风格

- 中文说明；
- 顺真实执行链；
- 标完整仓库路径；
- 优先解释 WHY；
- 不重复 C++ / Lua 基础；
- 性能结论必须给测试条件；
- 正文使用自然、直接陈述句；
- 避免反复套用“不是……而是……”的模板；
- 不使用 AI 培训腔；
- 简单数据组织优先用资深 Server 工程师熟悉的 struct、record、二维网格、一维数组、索引、序列化解释；
- 教程必须是可独立发布文档，不写“你之前说过”“我们刚讨论”等依赖聊天历史的措辞。

## 10. 与源码注释的分工

完整代码和可复制示例仍必须遵守：

```text
.agents/skills/skynet-battle-navigation-coding-standard/SKILL.md
```

教学正文负责建立概念和执行链；源码注释负责局部职责、参数、单位、ownership、错误和关键 WHY。

不要用大段源码注释替代教程正文，也不要在正文重复每一行代码的语法含义。
