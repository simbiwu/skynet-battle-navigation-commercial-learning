# Navigation Abstraction：何时引入，怎么引入

这份文档主要给 Codex 和 Lesson 2 后段 / Lesson 3 使用。

**不要在 Lesson 1 把它完整讲给学习者。**

## Lesson 1 只保留两个事实

### 事实 1：业务位置用 WorldPosition

```cpp
struct WorldPositionMm
{
    int32_t x;
    int32_t y;
    int32_t z;
};
```

GridPos 是 GridMap 内部或 Debug 数据。

### 事实 2：不要让 Lua 业务依赖 GridPos

Lesson 1 可以：

```lua
nav.is_walkable_world(...)
nav.height_world(...)
```

也可以保留：

```lua
nav.debug_world_to_grid(...)
```

但 Debug API 不进入 Battle 业务。

这已经足够。

---

# Lesson 2 后段才正式整理公共导航 API

学习者已经写过：

```text
AgentProfile
A*
Path
NavigationContext
DynamicOccupancy
```

以后，再观察哪些概念不应属于 Grid：

```text
WorldPosition
AgentProfile
Path
NavigationContext
FindPath
Project
Raycast
```

此时再抽：

```cpp
class INavigationBackend
{
public:
    virtual ~INavigationBackend() = default;
    virtual ProjectResult Project(...) const = 0;
    virtual PathResult FindPath(...) const = 0;
    virtual RaycastResult Raycast(...) const = 0;
};
```

学习者能看到：

> 这个 Interface 是从已经工作的 Grid 实现中抽出来的，不是凭空设计。

---

# 公共 Path

第二课第一次出现。

Lua：

```lua
path:count()
path:world_point(i)
path:length_mm()
path:segment_type(i)
path:encode_v1()
```

Grid Backend 也返回 World Point。

不要正式返回：

```lua
{x=grid_x,z=grid_z}
```

这样 Lesson 3 不需要改 Replay。

---

# NavigationContext

第二课第一次出现。

它解决：

```text
同一 Static Map
+
每场 Battle 不同 Dynamic Occupancy
```

含义：

> 一场战斗自己的导航运行上下文。

第一课没有 Battle，就不需要它。

---

# AgentProfile

第二课第一次出现。

它解决：

```text
Small
Large
坡度
Area Cost
```

第一课只有地图数据，没有“谁来走”，不需要它。

---

# Lesson 3

此时学习者已经熟悉：

```text
NavigationContext
AgentProfile
Path
FindPath
```

只新增：

```text
DetourNavigationBackend
```

Grid：

```text
World -> Grid -> A*
```

Detour：

```text
World -> Poly -> Corridor -> StraightPath
```

上层 API 不变。

---

# 抽象失败信号

如果 Lesson 3 必须修改：

```text
BattleWorker 主状态机
TargetSelector
Attack Range 基本接口
EventWriter 主结构
```

才能接 Detour，先停下来修第二课抽象。

合理变化应主要发生：

```text
native/navigation/detour/
tools/nav_builder/
Unity NavSource Exporter
Detour tests
```
