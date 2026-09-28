// 职责：保存一场 Battle 的动态 footprint 事实，并提供无分配查询/提交基础能力。
// 边界：Server Runtime Battle-local Mutable State；绝不修改共享 GridMap。
// 输入/输出：NavigationAgentHandle + AgentProfile + GridPos -> footprint 查询和事实提交。
// 生命周期：随 NavigationContext/Battle 创建和销毁；不跨 Battle 共享。
// 不负责：不决定实体是否互相阻挡；是否允许进入由业务层回调解释本对象保存的事实。
#pragma once

#include "agent_profile.h"
#include "grid_map.h"
#include "navigation_agent.h"
#include "nav_result.h"

#include <cstddef>
#include <cstdint>
#include <limits>
#include <vector>

namespace battle_nav {

class DynamicOccupancy final {
public:
    // 按 map 的 cell_count 创建空事实索引；map 必须在本对象生命周期内保持存活。
    explicit DynamicOccupancy(const GridMap& map);

    // 返回该 Cell 是否有 handle 之外的动态实体。
    // 越界视为 blocked；这是便捷事实查询，不代表所有业务都必须采用独占规则。
    bool IsBlocked(
        const GridPos& grid,
        NavigationAgentHandle ignore_handle) const noexcept;

    // 使用“任意其他实体都阻挡”的默认规则检查整个 footprint。
    // GridPathfinder 不直接调用它；业务回调可以按需复用或实现自己的规则。
    bool IsFootprintBlocked(
        const AgentProfile& profile,
        const GridPos& center,
        NavigationAgentHandle ignore_handle) const noexcept;

    // 遍历某个 Cell 当前的所有动态实体句柄；callback 返回 false 时提前停止。
    // 不创建临时 ID vector；调用期间不得修改本 Occupancy。
    template <typename Callback>
    bool ForEachOccupant(
        const GridPos& grid,
        Callback callback) const {
        if (map_.TryCell(grid) == nullptr) {
            return false;
        }
        for (const NavigationAgentHandle handle : occupants_[IndexOf(grid)]) {
            if (!callback(handle)) {
                return false;
            }
        }
        return true;
    }

    // 根据 Agent 半径遍历保守 footprint；业务回调直接复用它，不重复计算半径覆盖范围。
    // callback 返回 false 时提前停止；不构造临时 Cell vector。
    template <typename Callback>
    bool ForEachFootprintCell(
        const AgentProfile& profile,
        const GridPos& center,
        Callback callback) const {
        const std::int64_t cell = map_.metadata().cell_size_mm;
        const std::int64_t threshold =
            static_cast<std::int64_t>(profile.radius_mm) + cell / 2;
        const std::int32_t max_offset = static_cast<std::int32_t>(
            (threshold + cell - 1) / cell);

        for (std::int32_t dz = -max_offset; dz <= max_offset; ++dz) {
            for (std::int32_t dx = -max_offset; dx <= max_offset; ++dx) {
                const std::int64_t world_dx =
                    static_cast<std::int64_t>(dx) * cell;
                const std::int64_t world_dz =
                    static_cast<std::int64_t>(dz) * cell;
                const std::uint64_t ax = static_cast<std::uint64_t>(
                    world_dx < 0 ? -world_dx : world_dx);
                const std::uint64_t az = static_cast<std::uint64_t>(
                    world_dz < 0 ? -world_dz : world_dz);
                const std::uint64_t r = static_cast<std::uint64_t>(threshold);
                if (ax > r || az > r) {
                    continue;
                }

                const std::uint64_t r2 = r * r;
                const std::uint64_t ax2 = ax * ax;
                const std::uint64_t az2 = az * az;
                if (ax2 > r2 || az2 > r2 - ax2) {
                    continue;
                }

                const std::int64_t grid_x =
                    static_cast<std::int64_t>(center.x) + dx;
                const std::int64_t grid_z =
                    static_cast<std::int64_t>(center.z) + dz;
                if (grid_x < std::numeric_limits<std::int32_t>::min() ||
                    grid_x > std::numeric_limits<std::int32_t>::max() ||
                    grid_z < std::numeric_limits<std::int32_t>::min() ||
                    grid_z > std::numeric_limits<std::int32_t>::max()) {
                    return false;
                }

                const GridPos grid{
                    static_cast<std::int32_t>(grid_x),
                    static_cast<std::int32_t>(grid_z)};
                if (map_.TryCell(grid) == nullptr || !callback(grid)) {
                    return false;
                }
            }
        }
        return true;
    }

    // 统一处理首次进入和后续移动：没有旧记录时写入，有旧记录时先清旧再写新。
    // 业务层必须先通过 DynamicNavigationPolicy 判断目标是否允许进入。
    NavResult<bool> Move(
        NavigationAgentHandle handle,
        const AgentProfile& profile,
        const GridPos& target);

    // 按 handle 释放当前已记录的 footprint；重复 Release 安全。
    NavResult<bool> Release(NavigationAgentHandle handle);

    // Debug/Test：返回第一个 occupant；多实体 Cell 应使用 ForEachOccupant。
    // 越界或空 Cell 返回无效句柄。
    NavigationAgentHandle FirstOccupantAt(
        const GridPos& grid) const noexcept;

private:
    struct AgentFootprint {
        NavigationAgentHandle handle;
        std::vector<GridPos> cells; // 该实体当前真实占用的 Cell；由本对象拥有。
    };

    // 合法 GridPos -> row-major occupants 数组下标；调用前必须已经确认在地图内。
    std::size_t IndexOf(const GridPos& grid) const noexcept;

    // 查找当前已经登记的 Agent；找不到返回 nullptr。
    AgentFootprint* FindFootprint(NavigationAgentHandle handle) noexcept;
    const AgentFootprint* FindFootprint(
        NavigationAgentHandle handle) const noexcept;

    // 从一个 Cell 删除 handle；只影响指定实体，不会误删其他实体。
    void RemoveHandleAt(
        const GridPos& grid,
        NavigationAgentHandle handle);

    // 向一个 Cell 添加 handle；同一实体重复添加时保持一份事实。
    void AddHandleAt(
        const GridPos& grid,
        NavigationAgentHandle handle);

    const GridMap& map_; // 非 owning immutable map 引用；由 Context 保证生命周期。
    std::vector<std::vector<NavigationAgentHandle>> occupants_;
    std::vector<AgentFootprint> footprints_;
};

} // namespace battle_nav
