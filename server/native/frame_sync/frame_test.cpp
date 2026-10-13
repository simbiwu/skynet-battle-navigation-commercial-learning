// 职责：跨平台Frame Core
// Golden、正式输入与Checkpoint恢复、Checkpoint恢复及坏状态回归。 边界：Native
// CTest；不依赖Skynet和Unity；输出逐帧GOLDEN供Windows/Linux逐行比较。
// 输入：唯一已发布BMAP绝对或相对路径；失败返回非零退出码。
#include "frame_core.h"
#include <cassert>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>

namespace
{
std::uint32_t hashBytes(const std::string &s)
{
    std::uint32_t hash = 2166136261u;
    for (unsigned char byte : s)
        hash = (hash ^ byte) * 16777619u;
    return hash;
}
void testAirNavigation(const std::shared_ptr<const flywow_navigation::GridMap> &map)
{
    using namespace flywow_navigation;
    NavigationContext context(map);
    const AirBody body{200, 200};
    const NavigationAgentHandle mover{9001};
    const NavigationAgentHandle blocker{9002};
    const WorldPosition start{-5000, 3000, 0};
    const WorldPosition goal{5000, 3000, 0};
    const AirBox mover_box{{start.x_mm - 200, start.y_mm - 200, start.z_mm - 200},
                           {start.x_mm + 200, start.y_mm + 200, start.z_mm + 200}};
    const AirBox blocker_box{{-500, 2800, -500}, {500, 3200, 500}};

    assert(setAirObstacle(context, mover, mover_box).ok());
    assert(setAirObstacle(context, blocker, blocker_box).ok());
    const auto route = findAirPath(context, start, goal, start.y_mm, body, mover, {true, 0});
    assert(route.ok() && route.value.count() > 1);

    PathFollowCursor cursor;
    cursor.next_point_index = 1;
    const auto advanced = advanceAirPath(context, mover, route.value, cursor, 500, {true, 0});
    assert(advanced.ok() &&
           (advanced.value.position.x_mm != start.x_mm ||
            advanced.value.position.y_mm != start.y_mm ||
            advanced.value.position.z_mm != start.z_mm));

    const auto sweep = sweepAir(context, start, goal, body, mover, {true, 0});
    assert(sweep.ok() && sweep.value.kind == AirHitKind::kDynamic);
    const auto blocked_move = moveAir(context, mover, goal, {true, 0});
    assert(!blocked_move.ok() && blocked_move.error == NavError::kBlocked);

    assert(removeAirObstacle(context, blocker).ok());
    const auto clear_sweep = sweepAir(context, start, goal, body, mover, {true, 0});
    assert(clear_sweep.ok() && clear_sweep.value.kind == AirHitKind::kClear);
}
} // namespace

int main(int argc, char **argv)
{
    if ((argc != 2 && argc != 3) ||
        fs_preload_map(argv[1], argc == 3 ? argv[2] : nullptr) != 1)
        return 2;
    const FsUnitProfile units[] = {
        {1, 1, 3000, 100, 0, 0, 0, 0},
        {2, 2, 20000, 100, 200, 10000, 350, 500},
    };
    FsNavigationProfile navigation[1]{};
    navigation[0].unit_id = 1;
    navigation[0].radius_mm = 200;
    navigation[0].max_step_mm = 600;
    navigation[0].max_slope_permille = 1000;
    for (std::size_t area = 0; area < 256; ++area)
    {
        navigation[0].area_allowed[area] = 1;
        navigation[0].area_cost_permille[area] = 1000;
    }
    navigation[0].area_cost_permille[1] = 3000;
    navigation[0].area_cost_permille[3] = 1500;
    const FsSkillProfile skills[] = {
        {1, 900, 36, 14, 1, 1},
        {2, 9000, 72, 12, 3, 2},
        {3, 9000, 72, 20, 3, 3},
    };
    if (fs_load_profiles(units, 2, navigation, 1, skills, 3) != 1)
        return 2;
    const auto meta = flywow_navigation::MapRegistry::Instance().Find(1001);
    if (!meta.ok() || !meta.value)
        return 3;
    const auto stable_map = meta.value;
    assert(fs_preload_map(argv[1], "./missing-frame-test.airnav") == 0);
    const auto still_published = flywow_navigation::MapRegistry::Instance().Find(1001);
    assert(still_published.ok() && still_published.value == stable_map);
    testAirNavigation(meta.value);
    lesson_frame::Engine first(meta.value), second(meta.value);
    const auto           initial = first.save();
    assert(first.state().units.size() == 3);
    bool has_route = false;
    for (std::uint32_t frame = 1; frame <= 200 && first.state().winner == 0; ++frame)
    {
        lesson_frame::PlayerInput inputs[1] = {
            {1, 1001, static_cast<int>((frame / 25) % 3) - 1,
             static_cast<int>((frame / 30) % 3) - 1, frame % 15 == 0 ? 1 : 0},
        };
        const auto prior = first.save();
        first.stepFrame(frame, inputs, 1);
        second.stepFrame(frame, inputs, 1);
        assert(first.save() == second.save());
        second.restore(prior);
        second.stepFrame(frame, inputs, 1);
        assert(first.save() == second.save());
        has_route |= !first.state().routes.empty();
        std::cout << "GOLDEN " << frame << " " << hashBytes(first.save()) << "\n";
    }
    const auto saved = first.save();
    try
    {
        first.restore(saved + "x");
        assert(false);
    }
    catch (...)
    {
    }
    assert(first.save() == saved);
    try
    {
        first.stepFrame(first.state().frame + 1, nullptr, 2);
        assert(false);
    }
    catch (...)
    {
    }
    assert(first.save() == saved);
    first.restore(initial);
    assert(first.save() == initial);
    std::cout << "FRAME_NATIVE_OK route_seen=" << has_route << "\n";
    return 0;
}
