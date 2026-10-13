// 职责：用当前 BMAP 验证 Frame Core 所需的 AIR API 组合；只用于隔离课程验收。
// 输入：一个已发布 BMAP；覆盖动态注册、路径、只读扫掠、部分推进和原子移动。
#include "air_navigation.h"
#include "bmap_reader.h"
#include "navigation_context.h"

#include <cassert>
#include <cstdint>
#include <iostream>

int main(int argc, char **argv)
{
    assert(argc == 2);
    const auto loaded = flywow_navigation::BMapReader::Read(argv[1]);
    assert(loaded.ok());
    const auto &map = *loaded.value;
    const auto &metadata = map.metadata();
    assert(metadata.width >= 8 && metadata.height >= 8);

    const flywow_navigation::GridPos start_grid{
        static_cast<std::int32_t>(metadata.width / 4),
        static_cast<std::int32_t>(metadata.height / 2),
    };
    const flywow_navigation::GridPos goal_grid{
        static_cast<std::int32_t>((metadata.width * 3) / 4),
        static_cast<std::int32_t>(metadata.height / 2),
    };
    auto start_result = map.GridToWorldCenter(start_grid);
    auto goal_result = map.GridToWorldCenter(goal_grid);
    assert(start_result.ok() && goal_result.ok());
    auto start = start_result.value;
    auto goal = goal_result.value;
    start.y_mm = 5000;
    goal.y_mm = 5000;

    flywow_navigation::NavigationContext context(loaded.value);
    const flywow_navigation::AirBody body{100, 200};
    const flywow_navigation::NavigationAgentHandle mover{1001};
    const flywow_navigation::NavigationAgentHandle blocker{2001};
    const auto middle_x = (start.x_mm + goal.x_mm) / 2;
    const auto middle_z = start.z_mm;
    const auto cell = static_cast<std::int64_t>(metadata.cell_size_mm);
    const flywow_navigation::AirBox obstacle{
        {middle_x - cell, 4000, middle_z - cell},
        {middle_x + cell, 6000, middle_z + cell},
    };
    const auto blocked = flywow_navigation::setAirObstacle(context, blocker, obstacle);
    const auto placed = flywow_navigation::setAirObstacle(
        context, mover,
        {{start.x_mm - 100, start.y_mm - 200, start.z_mm - 100},
         {start.x_mm + 100, start.y_mm + 200, start.z_mm + 100}});
    assert(blocked.ok() && placed.ok());

    const auto direct = flywow_navigation::sweepAir(
        context, start, goal, body, mover, {true, 0});
    assert(direct.ok());
    assert(direct.value.kind == flywow_navigation::AirHitKind::kDynamic);

    const auto route = flywow_navigation::findAirPath(
        context, start, goal, start.y_mm, body, mover, {true, 0});
    assert(route.ok() && route.value.count() > 2);
    flywow_navigation::PathFollowCursor cursor;
    const auto advanced = flywow_navigation::advanceAirPath(
        context, mover, route.value, cursor, metadata.cell_size_mm, {true, 0});
    assert(advanced.ok() && advanced.value.moved);

    const auto rejected = flywow_navigation::moveAir(context, mover, goal, {true, 0});
    assert(!rejected.ok());
    const auto removed = flywow_navigation::removeAirObstacle(context, blocker);
    assert(removed.ok());
    const auto moved = flywow_navigation::moveAir(context, mover, goal, {true, 0});
    assert(moved.ok() && moved.value.x_mm == goal.x_mm && moved.value.z_mm == goal.z_mm);
    std::cout << "FRAME_AIR_ADAPTER_OK path_points=" << route.value.count() << '\n';
}
