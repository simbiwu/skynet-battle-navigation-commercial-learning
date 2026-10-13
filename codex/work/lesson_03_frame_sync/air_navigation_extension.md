## 附录 A：将可选 AIRN V1 接入帧同步版

本附录是主实操完成后的可选扩展；要应用到课程源码，应在第 2.4 节构建之前按本附录修改隔离课程文件。本附录把 FlyWow 已验证的可选空中导航接到本课的 Frame Core。FlyWow 提供资产加载、固定高度八邻接寻路、动态 AABB、连续扫掠和原子移动；Frame Core 仍拥有单位位置、逐帧顺序与 AI 决策。这里不接入 Battle/Frame Core 以外的业务，也不改变玩家输入、技能或弹丸合同。

当前 `shared/navigation/battle_1001/` 只有 BMAP V1，没有 AIRN 文件。BMAP 描述地表，不能推导空中障碍。AIRN 是与同一 BMAP 的 map_id、map_version 和内容 SHA-256 配对的可选侧车文件；没有 AIRN 时，地图仍可加载，空中移动会受地表穿透、边界和 Battle 内动态空中单位限制。只有显式提供 AIRN 路径后，静态空中体积才生效；配置了路径但资产丢失、损坏或身份不匹配时，启动必须失败。

### A.1 在 Unity Authoring 中导出配对 AIRN

**操作：只读检查现有场景，然后在 Unity 编辑源局部修改 `Battle_1001_FrameSync` 场景。** Scene 中的 Air Volume 只声明静态世界障碍；动态单位仍由每场 Battle 的 Context 管理。

本步骤需要地图根对象在 Bake/Export 时同时找到地面 BMAP 数据与可选的 Air Navigation Authoring 配置。`Bounds` 是 Collider 在 World Space 的轴对齐包围盒，`LayerMask` 决定哪些 Collider 被当作静态空中障碍。查看 Inspector 中的中心、尺寸和 LayerMask；例如以毫米计的盒体 `center=(4000,3000,2000)`、`size=(2000,4000,1000)` 覆盖 X=[3000,5000]、Y=[1000,5000]、Z=[1500,2500]。AIRN 用闭区间保存保守盒体，所以接触边界也算阻挡。

```text
                    Y 高度 (mm)
                    ↑
      Y=5000  ┌──────────┐  ← Bounds 上边界
              │  Air    │
      Y=1000  └──────────┘  ← Bounds 下边界
             X=3000    X=5000 → X (mm)
            起点：地图世界原点 (0,0,0)
            深度：Z=[1500,2500] mm
```

读图要点：三个区间都以 Unity World 坐标换算成毫米，原点由已发布 BMAP 的 World origin 决定；图中的正向箭头给出数值增加方向。AIRN 不是 Unity NavMesh，也不修改 BMAP V1 的 Header、Cell 或版本。

在 FrameSync 场景唯一的 MapRoot Inspector 中启用 `exportAirNavigation`，把用于静态空中阻挡的启用 Collider 放入 `airObstacleLayers` 指定的 Layer；动态单位与不应阻挡飞行的 Collider 不放入。该采样使用 Collider 的 World Space AABB，旋转盒体和非 BoxCollider 会保守覆盖，可能封住模型原本可穿越的通道。`exportDirectory` 是相对 Unity 工程根目录的输出根；正式候选由 `Tools > FlyWow > Navigation > 00 一键执行：校验 -> 烘焙 -> 导出（推荐）` 生成，或在已完成 Bake 后调用 `03 导出当前场景 BMAP`。Exporter 会在输出根下创建 `map-<mapId>-v<mapVersion>-<packageHash>/`，包含 `map.bmap`、可选的 `map.airnav` 与 `map.manifest.json`，没有单独的 AIRN 文件名设置。把完整候选目录验证后发布到 `shared/navigation/battle_1001/`，再由 Server 与客户端消费同一内容；不要手工拼 AIRN 字节或把 Unity 工程绝对路径写进 Runtime。

### A.2 显式加载：保持 BMAP V1，空中资产按路径选择

**操作：局部修改 `server/config/frame_sync.lua`、Native 预加载 Binding 和 Unity 的 `FrameNative.Preload`。** 显式路径把构建/部署拓扑交给 composition root，避免 Native 猜相邻文件名或当前工作目录。

在 `frame_sync.lua` 中增加两个运行时路径：Server 路径相对 `server/`；客户端路径相对 `Assets/StreamingAssets/`。空字符串表示本环境只使用 BMAP 与动态空中障碍。启用作者导出的 AIRN 时填写已发布文件的相对路径。

```lua
    map_path          = "../shared/navigation/battle_1001/battle_1001.bmap",
    airnav_path       = "../shared/navigation/battle_1001/battle_1001.airnav",
    client_airnav_asset = "navigation/battle_1001/battle_1001.airnav",
```

若当前发布包没有 AIRN，Server 的 `airnav_path` 和客户端的 `client_airnav_asset` 都设为空字符串。两端都必须选择同一资产身份：BMAP map_id/map_version/content hash 与 AIRN Header 配对，不允许 Server 有静态空中墙、客户端却静默退化为空地图。

在 `frame_core.h` 与 `frame_core.cpp` 中把预加载 ABI 从单路径改为双路径，并把第二路径传给现有 FlyWow `MapRegistry::Load`：

```cpp
LESSON_FRAME_API int fs_preload_map(const char *bmap_path, const char *airnav_path);
```

实现中只校验 `bmap_path` 非空；`airnav_path == nullptr` 或空串表示没有静态 AirAsset。其它值原样传给 `MapRegistry::Load(bmap_path, airnav_path)`。该函数在启动阶段同步读盘；Reader 负责验证 BMAP/AIRN 的版本、hash 和配对身份，不能在失败时只发布 BMAP。

`frame_binding.cpp::preloadAssets` 从 `config.frame_sync` 读取 `airnav_path`，把它与 BMAP 路径一起传入 `fs_preload_map`。配置缺字段按空字符串处理，以兼容没有 AIRN 的旧部署；显式配置的路径一旦打不开就返回 `MAP_PRELOAD`。Unity 的 `FrameLuaProfiles` 同样读取 `client_airnav_asset`，并将 `Path.Combine(Application.streamingAssetsPath, client_airnav_asset)` 传给 `FrameNative.Preload`。空字符串转成 `null`，C ABI 的可选语义一致。

**本步骤输出：** 两个进程通过相同 FlyWow Reader 取得同一 immutable `GridMap`，其中可选 `AirAsset` 随地图快照共同持有。`NavigationContext` 只引用该快照；替换 Registry 的地图不会改写已有 Battle 的静态数据。

### A.3 Profile：为飞行单位声明碰撞体，不创建第二张配置表

**操作：局部修改已有 UnitProfile 与其 Native/C# ABI record。** 飞行单位仍使用统一 `unit_id`；只有地面单位需要 NavigationProfile。`AirBody` 描述轴对齐盒体的 XZ 半宽与 Y 半高，单位为毫米；它不属于 Ground NavigationProfile。

在 `profile2.lua` 的 `flight` 下增加：

```lua
        air_body =
        {
            radius_mm      = 350, -- X/Z 各方向的盒体半宽；动态占位与扫掠共用。
            half_height_mm = 500, -- Y 方向半高；飞行中心高度仍由确定性 AI 改变。
        },
```

依次扩展 LuaDoc `UnitFlightProfile`、`FsUnitProfile` 和 C# `FsUnitProfile`，按相同字段顺序追加 `air_radius_mm`、`air_half_height_mm` 两个 `uint32`；`sizeof(FsUnitProfile)` 从 24 变为 32。Lua 与 xLua 的配置读取器都必须要求 Air Profile 提供两个正数；Ground Profile 必须将这两个字段保持为 0。Native 批次校验失败时不发布半张 Profile 表。这里的 ABI 只由同一次 Server/Unity 构建共同消费，不是新增长期网络 DTO。

`UnitProfile` 内保存 `flywow_navigation::AirBody`，从静态配置复制；Checkpoint 不重复序列化配置。Unit 的 X/Y/Z 是正式 Battle 事实，飞行动态盒完全由位置、Profile 尺寸和存活状态重建。

### A.4 Context：恢复与移动都按稳定实例顺序重建动态障碍

**操作：局部修改 `Engine::buildContext` 和空中移动/AI。** 每个 Engine 独占一份 NavigationContext；静态 AirAsset 由地图快照共享，动态空中 AABB 由当前 Battle 的 Unit 状态生成。

`buildContext(candidate)` 保留现有地面 occupancy 注册，再按 `instance_id` 升序处理存活飞行单位。句柄用单位的非零 `instance_id`；盒体由中心和 AirBody 计算：

```cpp
const flywow_navigation::WorldPosition center{unit.x, unit.y, unit.z};
const auto radius = static_cast<std::int64_t>(profile.air_body.radius_mm);
const auto half_height = static_cast<std::int64_t>(profile.air_body.half_height_mm);
const flywow_navigation::AirBox box{
    {center.x_mm - radius, center.y_mm - half_height, center.z_mm - radius},
    {center.x_mm + radius, center.y_mm + half_height, center.z_mm + radius},
};
const auto placed = flywow_navigation::setAirObstacle(
    *next_context, {unit.instance_id}, box);
if (!placed.ok())
    throw std::runtime_error(flywow_navigation::NavErrorName(placed.error));
```

实际代码需要在构造 `center` 前用既有 `position(unit)` helper，且在这个分支结束后 `continue`，避免给飞行单位申请地面占位。出生体积还要用 `sweepAir(center, center, body, handle, terrain_policy)` 检查静态 AIRN 与地表；命中时以 `SPAWN_BLOCKED` 拒绝 Engine 创建。地面单位不进入 AirState，空中单位也不占 ground occupancy。

空中 AI 每帧从当前 XZ 到目标 XZ 调用 `findAirPath`，`flight_y_mm` 取当前单位中心高度，body 和自身 handle 来自 Profile/instance_id。此 API 只规划固定高度；本课升降意图继续由现有整数追击公式产生。取路径的第一个待达点作为水平目标，再把本 Tick 的升降步长合入目标 Y，最后调用 `moveAir`。`moveAir` 会重新扫掠整段并只在通过时原子更新 AABB；如果同帧前序单位改变了动态占位，移动仍会重新验证。

```cpp
const auto route = flywow_navigation::findAirPath(
    *context_, position(unit), position(target), unit.y, profile.air_body,
    {unit.instance_id}, {true, 0});
if (!route.ok())
{
    if (route.error == flywow_navigation::NavError::kNoPath)
        return; // 可达性变化时停住；下一帧重新查询。
    throw std::runtime_error(flywow_navigation::NavErrorName(route.error));
}
if (route.value.count() > 1)
{
    const auto &next = route.value.WorldPoint(1);
    const flywow_navigation::WorldPosition target_position{
        next.x_mm, unit.y + vertical_intent * stride_mm, next.z_mm};
    const auto moved = flywow_navigation::moveAir(
        *context_, {unit.instance_id}, target_position, {true, 0});
    if (!moved.ok() && moved.error != flywow_navigation::NavError::kBlocked)
        throw std::runtime_error(flywow_navigation::NavErrorName(moved.error));
    if (moved.ok())
    {
        unit.x = moved.value.x_mm;
        unit.y = moved.value.y_mm;
        unit.z = moved.value.z_mm;
    }
}
```

其中 `vertical_intent` 是现有 AI 规则输出的 -1/0/1，`stride_mm` 仍按活动轴数做整数归一化。地面策略明确开启，`clearance_mm=0` 表示盒体不能穿过 BMAP 地表；单位中心到地面的最小/最大距离仍由 UnitFlightProfile 的 `sampleAir` 检查。`kNoPath` 是普通本帧停步，预算、容量或参数失败不能伪装成无路。

### A.5 扫掠、同帧顺序和 Checkpoint

`moveAir` 已经提供 sweep-then-commit 原子合同；Frame Core 不应先调用 `sweepAir`，再把位置直接写进 Unit，那会绕开动态索引提交。`sweepAir` 用在只读预测、命中诊断和测试；正式移动用 `moveAir`。两者使用整数毫米与有理数接触参数，不把连续碰撞近似成逐帧端点检查。

Frame Core 先按 `instance_id` 排序移动，后处理技能/伤害；本帧后序飞行单位看到前序单位已经提交的新盒体，执行顺序固定且两端一致。死亡单位在本帧统一伤害结算后，由下一帧的 Context 重建剔除；Checkpoint restore 则从候选 State 重建 Context。AIRN 静态体积和动态 AABB 都不单独写入 Checkpoint：前者随已校验地图身份固定，后者由 Unit 位置、生命状态和固定 Profile 派生。现有 Checkpoint V3 字节布局不变。

### A.6 验证加载、寻路、动态阻挡和扫掠

**操作：扩展 `frame_test.cpp`，完整保留已有 Golden 与回滚断言。** 加一个聚焦 AIR 查询：从 `MapRegistry::Find(1001)` 取同一地图快照，创建独立 `NavigationContext`，在空旷飞行高度注册一个挡路 AABB；断言 `findAirPath` 找到绕行路线，`advanceAirPath` 沿路线前进，`sweepAir` 对穿过盒体的直线返回 `kDynamic`，`moveAir` 遇到该盒体返回 `kBlocked` 并保留原盒与原中心。移除 blocker 后重复查询应成功。每个 request 都显式提供 body、handle 和 terrain policy。

另加启动负向测试：传入损坏 AIRN 路径或与 BMAP 不匹配的 AIRN，`fs_preload_map` 返回失败；之前已发布 Registry 快照仍可由已有 Engine 使用。纯 BMAP 模式仍跑原 Golden；启用 AIRN 时 Server 与 Windows Native 必须使用字节相同的已发布侧车文件，再逐帧比较 Golden。

按项目现有统一入口先验证 FlyWow，然后验证本课隔离 Core：

```bash
cd server/third_party/skynet-flywow
./scripts/build_flywow.sh ../skynet navigation
ctest --test-dir build/cmake/navigation --output-on-failure
./build/native/air_navigation_benchmark

cd ../../
cmake -S native/frame_sync -B build/frame_sync -DCMAKE_BUILD_TYPE=Release -DLESSON_FRAME_LUA=ON
cmake --build build/frame_sync --parallel 4
ctest --test-dir build/frame_sync --output-on-failure
./third_party/skynet/3rd/lua/lua tests/frame_binding_test.lua
```

Benchmark 必须保留 FlyWow AIR 场景、地图尺寸、墙体长度、4096 动态对象及成功/无路/预算耗尽预期，不得降低次数或提高默认预算让门禁变绿。Frame 测试另记录每帧 AIR 查询次数、扩展数与 p50/p95/p99；若超预算，应优化重规划与空间查询实现，不能吞掉 `QUERY_BUDGET_EXCEEDED`。测试期间不要同时运行其它 Benchmark。

本仓库当前没有 `battle_1001.airnav`，所以现有发布样例只能验证 BMAP-only 兼容模式和 Context 动态盒；AIRN 配对读写和固定高度几何由 FlyWow 的真实 Writer/Native/Unity EditMode 测试覆盖。学习者完成 Unity Authoring 导出后，需再执行显式双路径加载与跨平台 AIRN Golden。这项限制必须如实记录，不能把未存在的静态地图资产描述为已端到端运行。

### A.7 可直接应用的调用点修改

本小节是对第 A.2–A.6 节标注文件的局部修改清单；先读每条输入字段和 owner，再逐个修改，避免只更新 Server 或只更新 Unity。

在 `server/config/frame_sync.lua` 添加：

```lua
    airnav_path         = "", -- 空串表示只加载 BMAP；有 AIRN 时填 Server 工作目录下的明确相对路径。
    client_airnav_asset = "", -- 空串表示客户端同样不加载 AIRN；填写 StreamingAssets 下的相对路径。
```

`server/native/frame_sync/frame_core.h` 中将声明改为：

```cpp
LESSON_FRAME_API int fs_preload_map(const char *bmap_path, const char *airnav_path);
```

`frame_core.cpp` 的实现必须完整调用现有 Registry：

```cpp
extern "C" LESSON_FRAME_API int fs_preload_map(const char *bmap_path,
                                                const char *airnav_path)
{
    try
    {
        if (!bmap_path || !*bmap_path)
            return 0;
        const std::string air_path = airnav_path ? airnav_path : "";
        const auto result = flywow_navigation::MapRegistry::Instance().Load(bmap_path, air_path);
        return result.ok() && static_cast<bool>(result.value) ? 1 : 0;
    }
    catch (...)
    {
        return 0;
    }
}
```

`frame_binding.cpp::preloadAssets` 在既有输入后增加空中路径字符串参数，参数顺序固定为：`bmap_path, airnav_path, unit_profiles, navigation_profiles, skills`。允许第二参数为 nil/空串；Native 收到非空路径但 AIRN 无法读取时回 `MAP_PRELOAD`。更新 `server/service/battle/frame_sync/main.lua` 的启动调用为 `native.preload(conf.map_path, conf.airnav_path, conf.unit_profiles, conf.navigation_profiles, conf.skills)`，禁止在每个 Battle Tick 读文件。

Windows `FrameNative.cs` 的 `fs_preload_map` P/Invoke 增加 nullable UTF-8 字符串参数；`FrameNative.Preload` 加入 `airnav_path` 参数并传给 Native。`FrameLuaProfiles` 保存 `client_airnav_asset`，`FrameLuaProfileLoader.Read` 从同一 `config.frame_sync` record 读取它；Controller 以 `Application.streamingAssetsPath` 为根构造路径，空串传 null。`frame_test.cpp` 的入口允许 `frame_test <bmap>` 或 `frame_test <bmap> <airnav>`，其余参数数量直接失败。

`FsUnitProfile` 的字段声明末尾加上：

```cpp
    std::uint32_t air_radius_mm      = 0; ///< 飞行单位 X/Z 盒半宽；0 只允许地面 Profile。
    std::uint32_t air_half_height_mm = 0; ///< 飞行单位 Y 盒半高；0 只允许地面 Profile。
```

Profile 读取时，`movement.mode == "air"` 必须读取 `flight.air_body.radius_mm` 与 `flight.air_body.half_height_mm`。Native 校验这两个值都大于 0；`movement.mode == "ground"` 校验这两个值均为 0。UnitProfile 转换后赋给 `profile.air_body = {source.air_radius_mm, source.air_half_height_mm}`。C# `FsUnitProfile` 按相同顺序增加两个 `uint` 并把 `Marshal.SizeOf<FsUnitProfile>() == 32` 加入桥接测试。新旧二进制不可混用，必须由同一次课程源码构建 Server `.so` 和 Unity `.dll`。

### A.8 `buildContext` 与空中追击的完整函数

**操作：局部修改 `frame_core.cpp` 中两个函数；保留地面分支及固定排序。** 这段函数展示本课所有存活单位如何在 reset/restore 时重建动态事实。

```cpp
std::unique_ptr<flywow_navigation::NavigationContext>
Engine::buildContext(const State &candidate) const
{
    auto next_context = std::make_unique<flywow_navigation::NavigationContext>(map_);
    for (const auto &unit : candidate.units)
    {
        if (unit.hp <= 0)
            continue;

        const auto &profile = profileFor(profiles_->units, unit.unit_profile_id);
        if (unit.movement_mode == 2)
        {
            const auto center = position(unit);
            const auto radius = static_cast<std::int64_t>(profile.air_body.radius_mm);
            const auto half_height =
                static_cast<std::int64_t>(profile.air_body.half_height_mm);
            const flywow_navigation::AirBox box{
                {center.x_mm - radius, center.y_mm - half_height, center.z_mm - radius},
                {center.x_mm + radius, center.y_mm + half_height, center.z_mm + radius},
            };
            const flywow_navigation::NavigationAgentHandle handle{unit.instance_id};
            const auto placed = flywow_navigation::setAirObstacle(
                *next_context, handle, box);
            if (!placed.ok())
                throw std::runtime_error(flywow_navigation::NavErrorName(placed.error));

            const auto spawn = flywow_navigation::sweepAir(
                *next_context, center, center, profile.air_body, handle, {true, 0});
            if (!spawn.ok() || spawn.value.kind != flywow_navigation::AirHitKind::kClear)
                throw std::runtime_error("SPAWN_BLOCKED");
            continue;
        }
        if (unit.movement_mode != 1)
            throw std::runtime_error("STATE_MOVE_MODE");

        const auto &navigation = profile.navigation;
        const auto grid = map_->WorldToGrid(position(unit));
        if (!grid.ok() || next_context->occupancy().IsFootprintBlocked(
                navigation, grid.value, {unit.instance_id}))
            throw std::runtime_error("STATE_OCCUPANCY_CONFLICT");
        const auto placed = next_context->occupancy().Move(
            {unit.instance_id}, navigation, grid.value);
        if (!placed.ok() || !placed.value)
            throw std::runtime_error("STATE_OCCUPANCY_COMMIT");
    }
    return next_context;
}
```

```cpp
void Engine::chaseAir(Unit &unit, const Unit &target)
{
    const auto &profile = profileFor(profiles_->units, unit.unit_profile_id);
    if (distance2(unit, target) <= 800 * 800)
        return; // 沿用既有三维追击停止半径。
    const auto horizontal = std::max(absolute(target.x - unit.x),
                                     absolute(target.z - unit.z));
    const auto desired_y = target.y + 400 + std::min<std::int64_t>(2400, horizontal / 2);
    const auto vertical_intent =
        absolute(desired_y - unit.y) >= profile.move_stride_mm_per_tick
            ? sign(desired_y - unit.y)
            : 0;
    const auto handle = flywow_navigation::NavigationAgentHandle{unit.instance_id};
    const auto route = flywow_navigation::findAirPath(
        *context_, position(unit), position(target), unit.y, profile.air_body,
        handle, {true, 0});
    if (!route.ok())
    {
        if (route.error == flywow_navigation::NavError::kNoPath)
            return;
        throw std::runtime_error(flywow_navigation::NavErrorName(route.error));
    }
    if (route.value.count() <= 1)
        return;

    const auto &next = route.value.WorldPoint(1);
    const auto x = sign(next.x_mm - unit.x);
    const auto z = sign(next.z_mm - unit.z);
    const auto axes = static_cast<std::uint32_t>((x != 0) + (z != 0) +
                                                  (vertical_intent != 0));
    const auto stride = strideForAxes(profile.move_stride_mm_per_tick, axes);
    const flywow_navigation::WorldPosition destination{
        unit.x + x * stride,
        unit.y + vertical_intent * stride,
        unit.z + z * stride,
    };
    std::int64_t checked_y = destination.y_mm;
    if (!sampleAir(unit, destination.x_mm, destination.z_mm, destination.y_mm, checked_y))
        return;
    destination.y_mm = checked_y;

    const auto moved = flywow_navigation::moveAir(
        *context_, handle, destination, {true, 0});
    if (!moved.ok())
    {
        if (moved.error == flywow_navigation::NavError::kBlocked)
            return;
        throw std::runtime_error(flywow_navigation::NavErrorName(moved.error));
    }
    unit.x = moved.value.x_mm;
    unit.y = moved.value.y_mm;
    unit.z = moved.value.z_mm;
}
```

`moveAir` 的全段连续扫掠和 AABB 原子提交使 `chaseAir` 无需自行写 `setAirObstacle` 更新位置；手工更新会重复所有权并引入“位置已变、动态索引未变”的半提交状态。每帧重查路径是本课当前一名飞行 AI 的简单确定性规则；实际多空中单位地图应以新增 Frame AIR 查询 Benchmark 测量，并在超时之前优化路径复用/重规划，不得提高 AIR 硬预算或吞错误。

### A.9 本节验收结果边界

AIRN 文件由 Unity Editor 侧真实导出；本仓库现有 `battle_1001` 没有空中体积配置或 AIRN 资产，所以此处不伪造已跑过静态障碍的端到端结果。可先用 BMAP-only 配置完成 Frame Runtime 编译、动态对象测试和旧回归；随后在 Windows Authoring 场景配置一个可观察的盒体，发布配对 AIRN，将其同步后用两个显式路径跑 Server/Unity Native Golden。失败时优先核对 `(map_id,map_version,bmap_sha256)`，不要修改 BMAP V1 或关闭配对校验。
