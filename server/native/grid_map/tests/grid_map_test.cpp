// 职责：用最小 2x2 地图锁定 GridMap 的坐标、越界和 Cell 查询合同。
// 边界：Native 单元测试；不读取真实 BMAP，也不启动 Skynet。
// 输入/输出：进程内构造的 metadata/cells -> assert 结果和成功标记。
// 不负责：不替代 BMapReader 损坏文件测试和真实资产联调。
#include "grid_map.h"

#include <cassert>
#include <cstdint>
#include <iostream>
#include <vector>

using battle_nav::BMapMetadata;
using battle_nav::GridMap;
using battle_nav::NavCell;
using battle_nav::WorldPosition;

int main() {
    BMapMetadata metadata;
    metadata.map_id = 1001;
    metadata.map_version = 1;
    metadata.width = 2;
    metadata.height = 2;
    metadata.cell_size_mm = 500;
    metadata.origin_x_mm = -500;
    metadata.origin_z_mm = 1000;

    std::vector<NavCell> cells(4);
    cells[0].flags = battle_nav::kWalkableFlag;
    cells[0].height_mm = 100;
    cells[0].clearance_cells = 1;

    const GridMap map(metadata, std::move(cells));

    const auto first = map.WorldToGrid(WorldPosition{-250, 0, 1250});
    assert(first.ok());
    assert(first.value.x == 0 && first.value.z == 0);

    const auto before_origin = map.WorldToGrid(WorldPosition{-501, 0, 1250});
    assert(!before_origin.ok());
    assert(before_origin.error == battle_nav::NavError::kOutOfBounds);

    const auto query = map.QueryWorld(WorldPosition{-250, 9999, 1250});
    assert(query.ok());
    assert(query.value.IsWalkable());
    assert(query.value.height_mm == 100);

    std::cout << "GRID_MAP_TEST_OK\n";
    return 0;
}