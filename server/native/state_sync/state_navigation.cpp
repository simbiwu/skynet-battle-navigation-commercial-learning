// 职责：给Unity本地移动预测提供FlyWow导航薄C ABI；不运行Battle/AI/Skill。
// 单个句柄拥有私有Context和只读Profile，主线程顺序使用；任何异常不穿越C ABI。
#include "grid_pathfinder.h"
#include "map_registry.h"
#include "navigation_context.h"
#include <algorithm>
#include <memory>
#ifdef _WIN32
#define STATE_API extern "C" __declspec(dllexport)
#else
#define STATE_API extern "C" __attribute__((visibility("default")))
#endif
namespace
{
class Predictor final
{
  public:
    std::unique_ptr<flywow_navigation::NavigationContext> context;
    flywow_navigation::NavigationProfile                  profile;
    flywow_navigation::WorldPosition                      position{};
    bool                                                  ready = false;
};
} // namespace
/// 启动加载已由宿主校验hash的BMAP和typed导航配置；失败返回nullptr。
/// allow/cost数组均精确256项，只借用至返回；调用者拥有返回句柄并必须close。
STATE_API void *ss_open(const char *path, int radius, int step, unsigned slope,
                        const unsigned char *allow, const unsigned short *cost) noexcept
{
    try
    {
        if (!path || !allow || !cost)
        {
            return nullptr;
        }
        auto map = flywow_navigation::MapRegistry::Instance().Load(path);
        if (!map.ok())
        {
            return nullptr;
        }
        auto value     = std::make_unique<Predictor>();
        value->context = std::make_unique<flywow_navigation::NavigationContext>(map.value);
        value->profile = flywow_navigation::MakeDefaultNavigationProfile(1);
        value->profile.radius_mm          = radius;
        value->profile.max_step_mm        = step;
        value->profile.max_slope_permille = slope;
        std::copy_n(allow, 256, value->profile.area_allowed.begin());
        std::copy_n(cost, 256, value->profile.area_cost_permille.begin());
        if (!flywow_navigation::ValidateNavigationProfile(value->profile).ok())
        {
            return nullptr;
        }
        return value.release();
    }
    catch (...)
    {
        return nullptr;
    }
}
/// 权威校正后重建本地占位；out为3项int64，依次世界X/Y/Z毫米。
STATE_API int ss_reset(void *handle, const long long *pos, long long *out) noexcept
{
    try
    {
        if (!handle || !pos || !out)
        {
            return -1;
        }
        auto                                  &value = *static_cast<Predictor *>(handle);
        const flywow_navigation::WorldPosition p{pos[0], pos[1], pos[2]};
        const auto                             cell = value.context->map()->QueryWorld(p);
        if (!cell.ok())
        {
            return -2;
        }
        const auto grid   = value.context->map()->WorldToGrid(p);
        const auto placed = value.context->occupancy().Move({1001}, value.profile, grid.value);
        if (!placed.ok())
        {
            return -3;
        }
        value.position = {p.x_mm, cell.value.height_mm, p.z_mm};
        value.ready    = true;
        out[0]         = value.position.x_mm;
        out[1]         = value.position.y_mm;
        out[2]         = value.position.z_mm;
        return 1;
    }
    catch (...)
    {
        return -4;
    }
}
/// 每条input_seq对应一个1/60秒采样；不使用渲染dt；成功/阻挡均返回合法位置。
STATE_API int ss_step(void *handle, unsigned seq, int x, int z, unsigned speed,
                      long long *out) noexcept
{
    try
    {
        if (!handle || !out || !seq || seq > 0x7fffffff || x < -1 || x > 1 || z < -1 || z > 1 ||
            speed == 0 || speed > 30000)
        {
            return -1;
        }
        auto &value = *static_cast<Predictor *>(handle);
        if (!value.ready)
        {
            return -2;
        }
        const unsigned scale    = x != 0 && z != 0 ? 707 : 1000;
        // 累计距离差分与Server移动合同一致；3000mm/s轴向每Tick50mm。
        const auto     distance = static_cast<std::uint64_t>(seq) * speed * scale / 60000 -
                              static_cast<std::uint64_t>(seq - 1) * speed * scale / 60000;
        auto target = value.position;
        target.x_mm += x * static_cast<std::int64_t>(distance);
        target.z_mm += z * static_cast<std::int64_t>(distance);
        const auto cell  = value.context->map()->QueryWorld(target);
        bool       moved = false;
        if (cell.ok())
        {
            target.y_mm = cell.value.height_mm;
            const flywow_navigation::NavigationAgent agent{{1001}, &value.profile};
            const auto result = flywow_navigation::GridPathfinder::MoveUnit(
                *value.context, agent, value.position, target, {});
            moved = result.ok() && result.value;
            if (moved)
            {
                value.position = target;
            }
        }
        out[0] = value.position.x_mm;
        out[1] = value.position.y_mm;
        out[2] = value.position.z_mm;
        return moved ? 1 : 0;
    }
    catch (...)
    {
        return -3;
    }
}
/// 必须与open配对；nullptr安全；不可在仍有调用期间关闭。
STATE_API void ss_close(void *handle) noexcept
{
    delete static_cast<Predictor *>(handle);
}
