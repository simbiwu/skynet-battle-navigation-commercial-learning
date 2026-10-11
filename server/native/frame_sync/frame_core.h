// 职责：第三课跨 Unity/Skynet 的确定性帧模拟及唯一 C ABI。
// 边界：宿主 Battle Native；不使用 Lua、Unity、Skynet、Socket 或墙钟。
// 输入/输出：已预热 immutable BMAP + 完整席位输入 -> State/Checkpoint。
// ownership：每个 Engine 独占 State 与 NavigationContext；地图由 FlyWow
// Registry 共享。
#pragma once

#include "grid_pathfinder.h"
#include "map_registry.h"
#include "navigation_profile.h"
#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace lesson_frame
{
constexpr std::uint32_t kTickMs    = 50;   // 固定模拟时间；不随真实调度时间改变。
constexpr std::uint32_t kMaxFrames = 3600; // 180秒；限制每场Replay长度。
constexpr std::uint32_t kMaxUnits  = 16;   // 当前课例单位/AI数量上限。
constexpr std::uint32_t kMaxBolts  = 128;  // 当前课例弹丸上限。
constexpr std::uint32_t kMaxRoutes = 16;   // 最多为每个单位保持一条路径。
constexpr std::size_t   kMaxState  = 65535;

struct PlayerInput
{
    std::uint32_t seat_id          = 0; // 固定为1；由Worker会话授权后生成。
    std::uint32_t unit_instance_id = 0; // 固定席位1控制1001；这是Battle实例ID。
    std::int32_t  x       = 0; // -1/0/1，向X轴移动。
    std::int32_t  z       = 0; // -1/0/1，向Z轴移动。
    std::int32_t  skill   = 0; // 0空，1近战，2表现弹丸，3逻辑弹丸。
};

struct UnitProfile
{
    std::uint32_t unit_id                  = 0;
    std::uint32_t movement_mode            = 0;       // 1地面，2空中；所有单位从配置读取。
    std::uint32_t move_stride_mm_per_tick = 0;       // 基础每Tick位移；对角方向按整数比例归一化。
    std::int32_t  max_hp                  = 0;       // 单位静态最大生命值；当前HP属于战斗状态。
    std::uint32_t min_air_clearance_mm    = 0;       // 空中单位离当前地表的最小间隙。
    std::uint32_t max_air_altitude_mm     = 0;       // 空中单位相对当前地表的最高高度。
    flywow_navigation::NavigationProfile navigation; // 地面参数视图；源自本行配置。
};

using UnitProfileTable = std::vector<UnitProfile>;

struct Skill
{
    std::int64_t  range_mm    = 0;
    std::uint32_t cooldown    = 0;
    std::int32_t  damage      = 0;
    std::uint32_t target_mask = 0; // 1地面、2空中、3均可。
    std::uint32_t effect      = 0; // 1即时、2表现弹丸、3逻辑弹丸。
};

using SkillTable = std::array<Skill, 3>;

struct ProfileSnapshot
{
    UnitProfileTable units;
    SkillTable       skills;
};

struct Unit
{
    std::uint32_t instance_id     = 0; // Battle内唯一实例ID；用于输入、目标和动态占位。
    std::uint32_t unit_profile_id = 0; // 静态UnitProfile查询键；所有单位都必须引用有效记录。
    std::uint32_t camp          = 0; // 1玩家阵营，2敌方阵营。
    std::uint32_t movement_mode = 0; // 从Profile派生并随Checkpoint校验的运行时缓存。
    std::int64_t  x             = 0; // 整数毫米世界坐标。
    std::int64_t  y             = 0;
    std::int64_t  z             = 0;
    std::int32_t  hp            = 0;
    std::uint32_t ready[3]      = {}; // 下一次允许施放的逻辑帧。
};

struct Bolt
{
    std::uint32_t id      = 0;
    std::uint32_t caster_instance_id = 0;
    std::uint32_t target_instance_id = 0;
    std::uint32_t expires = 0;
    std::int32_t  damage  = 0; // 0表示纯表现弹丸。
    std::int64_t  x       = 0;
    std::int64_t  y       = 0;
    std::int64_t  z       = 0;
};

struct Route
{
    std::uint32_t           unit_instance_id = 0; // 当前路径唯一跟随者；不借用其他Unit的cursor。
    std::uint32_t           target_instance_id = 0; // 当前追击目标；变化触发重新规划。
    std::int64_t            planned_target_x = 0; // 上次A*看到的目标坐标；决定是否重规划。
    std::int64_t            planned_target_y = 0;
    std::int64_t            planned_target_z = 0;
    std::uint32_t           repath_at        = 0;     // 允许再次A*的逻辑帧；防重复/失败刷查询。
    std::uint32_t           blocked_frames   = 0;     // 路线动态阻挡持续Tick数。
    std::uint32_t           next_point       = 1;     // 对应PathFollowCursor::next_point_index。
    std::uint64_t           progress_mm      = 0;     // 当前路径线段已消费的整数毫米。
    bool                    valid            = false; // 路线已规划且包含合法跟随点。
    flywow_navigation::Path path; // FlyWow原始Path；帧间复用，Checkpoint只编码其值。
};

struct State
{
    std::uint32_t      frame     = 0;
    std::uint32_t      winner    = 0; // 0继续，1/2胜方，3平局。
    std::uint32_t      next_bolt = 1;
    std::vector<Unit>  units;  // 始终按instance_id严格升序。
    std::vector<Bolt>  bolts;  // 始终按id严格升序。
    std::vector<Route> routes; // 始终按unit_instance_id严格升序。
};

class Engine final
{
  public:
    explicit Engine(std::shared_ptr<const flywow_navigation::GridMap> map);
    /// 每帧包含唯一玩家席位的正式输入；AI由Core推进，失败不发布半帧。
    void         stepFrame(std::uint32_t frame, const PlayerInput *inputs, std::size_t count);
    /// 规范化Checkpoint V3，小端逐字段编码，不序列化指针或A* scratch。
    std::string  save() const;
    /// 验证后原子替换 State 与 Occupancy；失败旧状态不变。
    void         restore(const std::string &bytes);
    const State &state() const noexcept
    {
        return state_;
    }
    std::uint32_t mapId() const noexcept
    {
        return map_->metadata().map_id;
    }
    std::uint32_t mapVersion() const noexcept
    {
        return map_->metadata().map_version;
    }

  private:
    std::shared_ptr<const flywow_navigation::GridMap>     map_;
    // Engine创建时固定同一批Unit、Navigation、Skill配置；Tick不读文件。
    std::shared_ptr<const ProfileSnapshot>               profiles_;
    std::unique_ptr<flywow_navigation::NavigationContext> context_; // Battle-local scratch/占位。
    State                                                 state_;
    bool poisoned_ = false; // 异常补偿失败时拒绝继续推进。

    void        reset();
    void        runFrame(const PlayerInput *inputs);
    bool        sampleGround(const Unit &unit, std::int64_t x, std::int64_t z, std::int64_t from_y,
                             std::int64_t &new_y) const;
    bool        sampleAir(const Unit &unit, std::int64_t x, std::int64_t z, std::int64_t target_y,
                          std::int64_t &new_y) const;
    bool        moveGround(Unit &unit, std::int32_t x, std::int32_t z);
    void        moveAir(Unit &unit, std::int32_t x, std::int32_t z, std::int32_t y);
    void        chaseGround(Unit &unit, const Unit &target);
    void        chaseAir(Unit &unit, const Unit &target);
    void        cast(Unit &unit, std::int32_t skill_id, std::vector<std::int32_t> &damage);
    void        moveBolts(std::vector<std::int32_t> &damage);
    void        finish(const std::vector<std::int32_t> &damage);
    std::size_t targetOf(const Unit &unit, std::uint32_t move_mask) const;
    Route      &routeFor(std::uint32_t unit_instance_id);
    std::unique_ptr<flywow_navigation::NavigationContext> buildContext(const State &state) const;
};
} // namespace lesson_frame

#if defined(_WIN32)
#define LESSON_FRAME_API __declspec(dllexport)
#else
#define LESSON_FRAME_API __attribute__((visibility("default")))
#endif

// C ABI不传std::vector或std::string，不让C++异常穿过P/Invoke/Lua。
struct FsPlayerInput
{
    std::uint32_t seat_id;
    std::uint32_t unit_instance_id;
    std::int32_t  x;
    std::int32_t  z;
    std::int32_t  skill;
};

// C ABI配置记录是从现有Lua UnitProfile/NavigationProfile复制出的值，
// 不包含Lua对象、指针或平台相关容器；宿主负责读取Lua和初步类型检查。
struct FsUnitProfile
{
    std::uint32_t unit_id;
    std::uint32_t movement_mode; // 1地面，2空中。
    std::uint32_t move_stride_mm_per_tick;
    std::int32_t  max_hp;
    std::uint32_t min_air_clearance_mm;
    std::uint32_t max_air_altitude_mm;
};
struct FsNavigationProfile
{
    std::uint32_t unit_id;
    std::int32_t  radius_mm;
    std::int32_t  max_step_mm;
    std::uint32_t max_slope_permille;
    std::uint8_t  area_allowed[256];       // 已应用Lua默认值。
    std::uint16_t area_cost_permille[256]; // 已应用Lua默认值。
};
struct FsSkillProfile
{
    std::uint32_t skill_id;
    std::uint64_t range_mm;
    std::uint32_t cooldown_ticks;
    std::int32_t  damage;
    std::uint32_t target_mask;
    std::uint32_t effect;
};
static_assert(sizeof(FsUnitProfile) == 24, "Unit profile ABI changed");
static_assert(sizeof(FsNavigationProfile) == 784, "Navigation profile ABI changed");
static_assert(sizeof(FsSkillProfile) == 32, "Skill profile ABI changed");
static_assert(sizeof(FsPlayerInput) == 20, "Frame ABI struct size must remain 20 bytes");

extern "C"
{
    /// 加载验证过的BMAP并发布到进程MapRegistry；启动/部署阶段调用，有同步磁盘I/O。
    LESSON_FRAME_API int   fs_preload_map(const char *path);
    /// 接收宿主从Lua读取的Unit、Navigation、Skill记录，校验后一次替换进程配置表。
    /// 失败返回0且旧表不变；已创建Engine继续持有旧表，新Engine固定完整新表。
    LESSON_FRAME_API int   fs_load_profiles(const FsUnitProfile *units, std::uint32_t unit_count,
                                                const FsNavigationProfile *navigation,
                                                std::uint32_t navigation_count,
                                                const FsSkillProfile *skills,
                                                std::uint32_t skill_count);
    /// 按已加载map_id创建独占Engine，并固定完整配置表；无磁盘I/O。
    LESSON_FRAME_API void *fs_open(std::uint32_t map_id);
    /// 仅同一owner调用；nullptr安全，重复释放非空handle非法。
    LESSON_FRAME_API void  fs_close(void *handle);
    /// 校验连续帧、seat/unit映射和输入值；成功1，失败0且旧状态不变。
    LESSON_FRAME_API int   fs_step_frame(void *handle, std::uint32_t frame,
                                         const FsPlayerInput *players, std::uint32_t count);
    /// 缓冲由调用方拥有，成功返回字节数，失败0，最大65535字节。
    LESSON_FRAME_API int   fs_save(void *handle, unsigned char *output, int capacity);
    /// 恢复候选Checkpoint；失败0，不产生半步提交。
    LESSON_FRAME_API int   fs_restore(void *handle, const unsigned char *bytes, int count);
    LESSON_FRAME_API std::uint32_t fs_map_id(void *handle);
    LESSON_FRAME_API std::uint32_t fs_map_version(void *handle);
}