// 职责：实现 GridMap 的构造校验、坐标换算、索引计算和单格查询。
// 边界：Server Runtime 纯内存查询；所有公开查询只读且不共享 scratch。
// 输入/输出：WorldPosition 或 GridPos -> NavResult；失败显式返回越界或溢出。
// 不负责：不加载 BMAP、不判断动态占位、不计算路径。
#include "grid_map.h"

#include <limits>
#include <stdexcept>
#include <utility>

namespace battle_nav {

GridMap::GridMap(BMapMetadata metadata, std::vector<NavCell> cells)
    : metadata_(metadata), cells_(std::move(cells)) {
    const std::uint64_t expected =
        static_cast<std::uint64_t>(metadata_.width) * metadata_.height;
    if (metadata_.cell_size_mm == 0 || expected != cells_.size()) {
        throw std::invalid_argument("GridMap metadata/cell mismatch");
    }
}

std::size_t GridMap::memory_bytes() const noexcept {
    return sizeof(*this) + cells_.capacity() * sizeof(NavCell);
}

NavResult<GridPos> GridMap::WorldToGrid(const WorldPosition& world) const {
    const std::int64_t relative_x = // 相对 Grid 起点的世界 X 偏移，毫米；允许负数。
        static_cast<std::int64_t>(world.x_mm) - metadata_.origin_x_mm;
    const std::int64_t relative_z = // 相对 Grid 起点的世界 Z 偏移，毫米；允许负数。
        static_cast<std::int64_t>(world.z_mm) - metadata_.origin_z_mm;

    const std::int64_t grid_x = FloorDiv(relative_x, metadata_.cell_size_mm);
    const std::int64_t grid_z = FloorDiv(relative_z, metadata_.cell_size_mm);
    if (grid_x < std::numeric_limits<std::int32_t>::min() ||
        grid_x > std::numeric_limits<std::int32_t>::max() ||
        grid_z < std::numeric_limits<std::int32_t>::min() ||
        grid_z > std::numeric_limits<std::int32_t>::max()) {
        return NavResult<GridPos>::Failure(
            NavError::kOutOfBounds,
            "world coordinate cannot be represented as GridPos");
    }

    GridPos grid{
        static_cast<std::int32_t>(grid_x),
        static_cast<std::int32_t>(grid_z),
    };
    if (!Contains(grid)) {
        return NavResult<GridPos>::Failure(
            NavError::kOutOfBounds,
            "world position outside map bounds");
    }
    return NavResult<GridPos>::Success(grid);
}

NavResult<WorldPosition> GridMap::GridToWorldCenter(const GridPos& grid) const {
    if (!Contains(grid)) {
        return NavResult<WorldPosition>::Failure(
            NavError::kOutOfBounds,
            "grid position outside map bounds");
    }

    const NavCell& cell = cells_[IndexOf(grid)];
    const std::int64_t x = static_cast<std::int64_t>(metadata_.origin_x_mm) +
        static_cast<std::int64_t>(grid.x) * metadata_.cell_size_mm +
        metadata_.cell_size_mm / 2;
    const std::int64_t z = static_cast<std::int64_t>(metadata_.origin_z_mm) +
        static_cast<std::int64_t>(grid.z) * metadata_.cell_size_mm +
        metadata_.cell_size_mm / 2;
    if (x < std::numeric_limits<std::int32_t>::min() ||
        x > std::numeric_limits<std::int32_t>::max() ||
        z < std::numeric_limits<std::int32_t>::min() ||
        z > std::numeric_limits<std::int32_t>::max()) {
        return NavResult<WorldPosition>::Failure(
            NavError::kSizeOverflow,
            "grid center overflow");
    }

    return NavResult<WorldPosition>::Success(WorldPosition{
        static_cast<std::int32_t>(x),
        cell.height_mm,
        static_cast<std::int32_t>(z),
    });
}

NavResult<NavCell> GridMap::QueryWorld(const WorldPosition& world) const {
    NavResult<GridPos> grid = WorldToGrid(world);
    if (!grid.ok()) {
        return NavResult<NavCell>::Failure(grid.error, grid.detail);
    }
    return NavResult<NavCell>::Success(cells_[IndexOf(grid.value)]);
}

bool GridMap::Contains(const GridPos& grid) const noexcept {
    return grid.x >= 0 && grid.z >= 0 &&
        static_cast<std::uint32_t>(grid.x) < metadata_.width &&
        static_cast<std::uint32_t>(grid.z) < metadata_.height;
}

std::size_t GridMap::IndexOf(const GridPos& grid) const noexcept {
    return static_cast<std::size_t>(grid.z) * metadata_.width +
        static_cast<std::size_t>(grid.x);
}

std::int64_t GridMap::FloorDiv(std::int64_t value, std::int64_t divisor) {
    if (divisor <= 0) {
        throw std::invalid_argument("divisor must be positive");
    }
    std::int64_t quotient = value / divisor;
    const std::int64_t remainder = value % divisor;
    if (remainder != 0 && value < 0) {
        --quotient;
    }
    return quotient;
}

}  // namespace battle_nav