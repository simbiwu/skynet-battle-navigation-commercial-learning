// 职责：定义帧同步整数模拟、可恢复状态与稳定 C ABI；属于宿主 Battle，不属于 FlyWow。
// 输入/输出：已发布只读地图与单帧玩家意图 -> 逻辑状态；不读取网络、墙钟或 Unity 表现状态。
// ownership：Engine 共享持有不可变 GridMap，并独占 NavigationContext 与 State；C handle 由调用方成对 open/close。
#pragma once

#include "grid_map.h"
#include "navigation_context.h"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace lesson_frame
{
constexpr std::size_t   kMaxUnits  = 64;   // 每场允许持有的单位总数；超限时拒绝初始化或恢复。
constexpr std::size_t   kMaxBolts  = 128;  // 每场在途逻辑弹丸上限；满槽时拒绝逻辑弹丸施法。
constexpr std::uint32_t kMaxFrames = 3600; // 50ms/tick 下为 180 秒；到期时以平局结束。
constexpr std::uint32_t kTickMs    = 50;   // 固定逻辑步长；渲染帧率不改变它。

/// 单帧玩家意图；方向分量取 -1、0、1，skill 使用下方固定业务编号。
struct Input
{
    std::int32_t x     = 0; // 世界 X 方向；-1/0/1 表示负向/不动/正向，不是坐标。
    std::int32_t z     = 0; // 世界 Z 方向；-1/0/1 表示负向/不动/正向，不是坐标。
    std::int32_t y     = 0; // 飞行高度意图：-1 下降、0 保持、1 上升；地面单位忽略。
    std::int32_t skill = 0; // 0 不施法；1 近战；2 表现弹丸；3 逻辑火球。
};

/// Battle 单位的权威逻辑状态；位置为带符号 64 位世界毫米。
struct Unit
{
    std::uint32_t id        = 0;   // Battle 内稳定且唯一的实例 ID；单位按 ID 排序推进。
    std::uint32_t camp      = 0;   // 阵营编号：1 为玩家方，2 为敌方。
    std::uint32_t move_mode = 1;   // 移动规则：1 受地表约束，2 可主动升降的空中单位。
    std::int64_t  x         = 0;   // 世界 X 坐标，单位 mm。
    std::int64_t  y         = 0;   // 世界高度，单位 mm；地面单位由地图采样确定。
    std::int64_t  z         = 0;   // 世界 Z 坐标，单位 mm。
    std::int32_t  hp        = 100; // 当前生命值；0 表示死亡。
    std::uint32_t ready[3]  = {};  // 技能 1/2/3 最早可再次施放的逻辑帧号。
};

/// 在途逻辑弹丸；其 ID、位置和到期时间都是可恢复的 Battle 状态。
struct Bolt
{
    std::uint32_t id      = 0; // 本场单调递增的弹丸实例 ID。
    std::uint32_t caster  = 0; // 发射单位 ID；必须引用现存 Unit。
    std::uint32_t target  = 0; // 目标单位 ID；必须引用现存 Unit。
    std::uint32_t expires = 0; // 到期逻辑帧；到期或目标死亡后移除。
    std::int32_t  damage  = 0; // 0 仅供表现；20 在到达目标时提交逻辑伤害。
    std::int64_t  x       = 0; // 世界 X 坐标，单位 mm。
    std::int64_t  y       = 0; // 世界高度，单位 mm。
    std::int64_t  z       = 0; // 世界 Z 坐标，单位 mm。
};

/// 完整可恢复逻辑状态；不包含指针、渲染对象、墙钟、随机全局状态或 Socket。
struct State
{
    std::uint32_t     frame     = 0; // 已完成的逻辑帧；初始 Checkpoint 为 0。
    std::uint32_t     winner    = 0; // 0 进行中；1/2 对应胜方阵营；3 表示平局。
    std::uint32_t     next_bolt = 1; // 下一个弹丸 ID；恢复后继续单调递增。
    std::vector<Unit> units;         // 按稳定 ID 严格升序；数量不超过 kMaxUnits。
    std::vector<Bolt> bolts;         // 按实例 ID 严格升序；数量不超过 kMaxBolts。
};

/// 单场无锁、无 yield 的模拟 Engine；调用方必须串行调用其可变方法。
class Engine
{
  public:
    /// 创建本场模拟并共享持有不可变地图；地图无效或出生点不可用时抛出异常。
    /// @param map 已验证的只读地图；Engine 与调用方共同持有其生命周期。
    explicit Engine(std::shared_ptr<const flywow_navigation::GridMap> map);

    /// 按课程玩法初始化单位；失败时保留调用前状态并抛出异常。
    void reset();

    /// 推进一个固定逻辑帧；非法输入、结束状态或导航失败时不提交半帧状态。
    /// @param input 当前帧玩家意图；方向分量为 -1/0/1，skill 为 0..3。
    void step(Input input);

    /// 生成显式小端的规范化状态副本，可用于 Checkpoint 与确定性比较。
    /// @return 调用方拥有的序列化字节串。
    std::string save() const;

    /// 验证完整候选状态后一次性替换当前状态。
    /// @param bytes 借用的规范化状态字节；函数返回后不保留其引用。
    /// @throws 状态格式、版本或业务约束不合法时抛出异常，旧状态保持不变。
    void restore(const std::string &bytes);

    /// 只读借用当前状态；引用在 Engine 下一次成功变更或析构前有效。
    const State &state() const noexcept
    {
        return state_;
    }

    /// 返回当前地图身份；不执行 I/O。
    std::uint32_t mapId() const noexcept
    {
        return map_->metadata().map_id;
    }
    std::uint32_t mapVersion() const noexcept
    {
        return map_->metadata().map_version;
    }

  private:
    std::shared_ptr<const flywow_navigation::GridMap> map_;
    flywow_navigation::NavigationContext
          context_; // 当前 Engine 独占 A* scratch；不属于可恢复 State。
    State state_;

    void  stepUnchecked(Input input);
    void  chaseAir(const Unit &unit, const Unit &other, Input &input) const;
    void  chaseGround(const Unit &unit, const Unit &other, Input &input);
    bool  sample(std::int64_t x, std::int64_t z, std::int64_t from_y, std::int64_t &y) const;
    void  move(Unit &unit, Input input);
    bool  sampleAir(std::int64_t x, std::int64_t z, std::int64_t desired_y, std::int64_t &y) const;
    Input ai(const Unit &unit);
    void  cast(Unit &unit, std::int32_t skill, std::vector<std::int32_t> &damage);
    void  projectiles(std::vector<std::int32_t> &damage);
    std::size_t target(const Unit &unit, std::uint32_t target_modes = 3) const;
    void        finish(const std::vector<std::int32_t> &damage);
};
} // namespace lesson_frame

#if defined(_WIN32)
#define SKYNET_BATTLE_NAV_FRAME_API __declspec(dllexport)
#else
#define SKYNET_BATTLE_NAV_FRAME_API __attribute__((visibility("default")))
#endif

extern "C"
{
    /// 加载已发布地图并创建独占 Engine；不保存调用方传入的路径指针。
    /// @param path UTF-8 BMAP 文件路径；必须以 NUL 结尾。
    /// @return 成功时返回调用方独占的 handle；失败时返回 nullptr。
    SKYNET_BATTLE_NAV_FRAME_API void *fs_open(const char *path);

    /// 释放由 fs_open 返回的 Engine handle；空指针可安全传入。
    /// @param handle fs_open 返回且尚未关闭的 handle；重复关闭非空 handle 属于调用方错误。
    SKYNET_BATTLE_NAV_FRAME_API void fs_close(void *handle);

    /// 校验意图并推进一帧；不成功时返回 0 且不提交半帧结果。
    /// @param handle 当前 Battle 独占的 Engine handle。
    /// @param x 世界 X 方向分量，取 -1、0、1。
    /// @param z 世界 Z 方向分量，取 -1、0、1。
    /// @param skill 0 不施法、1 近战、2 表现弹丸、3 逻辑火球。
    /// @return 成功返回 1；参数、状态或领域操作失败返回 0。
    SKYNET_BATTLE_NAV_FRAME_API int fs_step(void *handle, int x, int z, int skill);

    /// 将当前状态写入调用方缓冲；不会保存缓冲指针。
    /// @param handle 当前 Battle 独占的 Engine handle。
    /// @param out 调用方提供的输出缓冲区。
    /// @param capacity out 的字节容量；小于完整状态长度时失败。
    /// @return 成功返回写入字节数；失败返回 0。
    SKYNET_BATTLE_NAV_FRAME_API int fs_save(void *handle, unsigned char *out, int capacity);

    /// 验证候选 Checkpoint 后恢复 Engine；失败时保留旧状态。
    /// @param handle 当前 Battle 独占的 Engine handle。
    /// @param bytes 借用的规范化状态字节，仅在本次调用期间读取。
    /// @param count bytes 的有效字节数。
    /// @return 成功返回 1；无效 handle、长度或状态返回 0。
    SKYNET_BATTLE_NAV_FRAME_API int fs_restore(void *handle, const unsigned char *bytes, int count);

    /// 返回地图身份；空 handle 返回 0。该值不是运行时版本握手。
    /// @param handle 当前 Battle 的 Engine handle。
    SKYNET_BATTLE_NAV_FRAME_API std::uint32_t fs_map_version(void *handle);
    SKYNET_BATTLE_NAV_FRAME_API std::uint32_t fs_map_id(void *handle);
} // extern "C"
