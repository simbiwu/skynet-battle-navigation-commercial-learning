// 职责：实现地图加载、去重、冻结和线程安全查找。
// 边界：Server Runtime 资产注册层；文件校验委托给 BMapReader。
// 输入/输出：路径或地图键 -> immutable GridMap shared_ptr 或 NavError。
// 不负责：锁不覆盖 GridMap 查询；不在运行期热改静态地图。
#include "map_registry.h"

#include <sstream>
#include <utility>

namespace battle_nav {

MapRegistry& MapRegistry::Instance() {
    static MapRegistry registry;
    return registry;
}

NavResult<std::shared_ptr<const GridMap>> MapRegistry::Load(
    const std::string& path) {
    // 文件 I/O 和 CRC 不占用 Registry Lock。
    NavResult<std::shared_ptr<const GridMap>> loaded = BMapReader::Read(path);
    if (!loaded.ok()) {
        return loaded;
    }

    const BMapMetadata& metadata = loaded.value->metadata();
    const Key key{metadata.map_id, metadata.map_version};
    std::lock_guard<std::mutex> lock(mutex_);
    if (frozen_) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kRegistryFrozen,
            "load attempted after freeze");
    }
    if (maps_.find(key) != maps_.end()) {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kDuplicateMap,
            "duplicate map/version");
    }

    maps_.emplace(key, loaded.value);
    return loaded;
}

NavResult<bool> MapRegistry::Freeze() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (frozen_) {
        return NavResult<bool>::Success(false);
    }
    frozen_ = true;
    return NavResult<bool>::Success(true);
}

NavResult<std::shared_ptr<const GridMap>> MapRegistry::Find(
    std::uint32_t map_id,
    std::uint32_t map_version) const {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto iterator = maps_.find(Key{map_id, map_version});
    if (iterator == maps_.end()) {
        std::ostringstream detail;
        detail << "map_id=" << map_id << " map_version=" << map_version;
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kMapNotFound,
            detail.str());
    }
    return NavResult<std::shared_ptr<const GridMap>>::Success(iterator->second);
}

std::size_t MapRegistry::map_count() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return maps_.size();
}

}  // namespace battle_nav