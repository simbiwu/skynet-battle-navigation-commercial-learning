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
    std::uint32_t seat_id          = 0;  ///< Worker授权后生成的输入席位；本课固定为席位1。
    std::uint32_t unit_instance_id = 0;  ///< 该席位控制的Battle单位实例ID；不是静态UnitProfile配置键。
    std::int32_t  x                = 0;  ///< 本帧X轴方向意图，取-1/0/1；表示方向，不是坐标。
    std::int32_t  z                = 0;  ///< 本帧Z轴方向意图，取-1/0/1；表示方向，不是坐标。
    std::int32_t  skill            = 0;  ///< 本帧技能命令：0无技能，1近战，2表现弹丸，3逻辑弹丸。
};

struct UnitProfile
{
    std::uint32_t                        unit_id                 = 0;  ///< 静态配置键；不是Battle实例ID。
    std::uint32_t                        movement_mode           = 0;  ///< 移动模式：1地面，2空中；由Lua配置加载。
    std::uint32_t                        move_stride_mm_per_tick = 0;  ///< 每Tick基础移动量，单位mm。
    std::int32_t                         max_hp                  = 0;  ///< 静态最大HP；当前值存入Unit。
    std::uint32_t                        min_air_clearance_mm    = 0;  ///< 空中单位高于当前位置地表的最小间隙，单位mm。
    std::uint32_t                        max_air_altitude_mm     = 0;  ///< 空中单位高于当前位置地表的最大高度，单位mm。
    flywow_navigation::NavigationProfile navigation;                   ///< 该单位使用的地面导航规则；空中单位不使用。
};

using UnitProfileTable = std::vector<UnitProfile>;

struct Skill
{
    std::int64_t  range_mm    = 0;  ///< 技能中心点最大作用距离，单位mm；命中规则包含高度。
    std::uint32_t cooldown    = 0;  ///< 冷却时长，单位逻辑Tick；施放后换算为最早可用帧。
    std::int32_t  damage      = 0;  ///< 技能命中后扣除的HP数值。
    std::uint32_t target_mask = 0;  ///< 目标类别位：1地面、2空中、3两类均可。
    std::uint32_t effect      = 0;  ///< 效果类型：1瞬发，2立即结算的表现弹丸，3到达后结算的逻辑弹丸。
};

using SkillTable = std::array<Skill, 3>;

struct ProfileSnapshot
{
    UnitProfileTable units;   ///< 本Battle固定持有的只读单位静态配置表。
    SkillTable       skills;  ///< 本Battle固定持有的只读技能规则表。
};

struct Unit
{
    std::uint32_t instance_id     = 0;   ///< Battle内唯一单位实例ID；用于输入、目标、路径和动态占位。
    std::uint32_t unit_profile_id = 0;   ///< 静态UnitProfile查询键；所有单位都必须对应有效配置。
    std::uint32_t camp            = 0;   ///< 阵营：1玩家方，2敌方；用于敌我筛选。
    std::uint32_t movement_mode   = 0;   ///< 从UnitProfile复制的移动模式：1地面，2空中；恢复时校验。
    std::int64_t  x               = 0;   ///< 单位当前世界X坐标，单位mm。
    std::int64_t  y               = 0;   ///< 单位当前世界高度坐标，单位mm。
    std::int64_t  z               = 0;   ///< 单位当前世界Z坐标，单位mm。
    std::int32_t  hp              = 0;   ///< 单位当前HP；归零后进入死亡状态。
    std::uint32_t ready[3]        = {};  ///< 三个技能槽各自最早可施放的逻辑帧号；索引对应技能1至3。
};

struct Bolt
{
    std::uint32_t id                 = 0;  ///< Battle内弹丸实例ID；用于稳定排序和分配下一个弹丸ID。
    std::uint32_t caster_instance_id = 0;  ///< 创建该弹丸的单位实例ID。
    std::uint32_t target_instance_id = 0;  ///< 该弹丸锁定的目标单位实例ID。
    std::uint32_t expires            = 0;  ///< 弹丸失效的逻辑帧号；到期后从活动列表移除。
    std::int32_t  damage             = 0;  ///< 到达目标时结算的伤害；0表示仅供表现的弹丸。
    std::int64_t  x                  = 0;  ///< 弹丸当前世界X坐标，单位mm。
    std::int64_t  y                  = 0;  ///< 弹丸当前世界高度坐标，单位mm。
    std::int64_t  z                  = 0;  ///< 弹丸当前世界Z坐标，单位mm。
};

struct Route
{
    std::uint32_t           unit_instance_id   = 0;      ///< 拥有该路径的Battle实例ID；也用作Navigation占位句柄。
    std::uint32_t           target_instance_id = 0;      ///< 当前追击目标单位实例ID；目标改变时当前路径失效。

    std::int64_t            planned_target_x   = 0;      ///< 最近一次寻路采用的目标X坐标，单位mm；用于检测目标移动。
    std::int64_t            planned_target_y   = 0;      ///< 最近一次寻路采用的目标高度坐标，单位mm；用于检测目标移动。
    std::int64_t            planned_target_z   = 0;      ///< 最近一次寻路采用的目标Z坐标，单位mm；用于检测目标移动。

    std::uint32_t           repath_at          = 0;      ///< 下一次允许发起路径查询的逻辑帧号；用于控制重规划时机。
    std::uint32_t           blocked_frames     = 0;      ///< 自上次重规划以来路径被动态占位阻挡的帧数。

    std::uint32_t           next_point         = 1;      ///< 下一个待跟随路径点索引。
    std::uint64_t           progress_mm        = 0;      ///< 当前路径线段已推进的距离，单位mm；对应游标线段进度。

    bool                    valid              = false;  ///< 缓存路径当前可继续推进；被阻挡、到达终点或目标切换后失效。
    flywow_navigation::Path path;                        ///< FlyWow路径对象；各Tick复用。
};

struct State
{
    std::uint32_t      frame     = 0;  ///< 当前已提交的逻辑帧号；新Engine从0开始。
    std::uint32_t      winner    = 0;  ///< Battle结果：0进行中，1/2为胜方阵营，3为平局。
    std::uint32_t      next_bolt = 1;  ///< 下一个可分配的弹丸实例ID。

    std::vector<Unit>  units;          ///< Battle单位状态表；始终按instance_id严格升序。
    std::vector<Bolt>  bolts;          ///< 活动弹丸状态表；始终按弹丸id严格升序。
    std::vector<Route> routes;         ///< 地面追击路径状态表；始终按unit_instance_id严格升序。
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
    std::uint32_t seat_id;           ///< 由Worker授权的输入席位ID；本课固定为1。
    std::uint32_t unit_instance_id;  ///< 该席位控制的Battle单位实例ID。
    std::int32_t  x;                 ///< 本帧X轴方向意图，取-1/0/1；不是世界坐标。
    std::int32_t  z;                 ///< 本帧Z轴方向意图，取-1/0/1；不是世界坐标。
    std::int32_t  skill;             ///< 技能命令：0无技能，1近战，2表现弹丸，3逻辑弹丸。
};

struct FsUnitProfile
{
    std::uint32_t unit_id;                  ///< 静态UnitProfile配置查询键。
    std::uint32_t movement_mode;            ///< 移动模式：1地面，2空中。
    std::uint32_t move_stride_mm_per_tick;  ///< 每逻辑Tick基础位移，单位mm。
    std::int32_t  max_hp;                   ///< 单位静态最大HP。
    std::uint32_t min_air_clearance_mm;     ///< 空中单位离当前地表的最小间隙，单位mm。
    std::uint32_t max_air_altitude_mm;      ///< 空中单位相对当前地表的最高高度，单位mm。
};

struct FsNavigationProfile
{
    std::uint32_t unit_id;                  ///< 与同一UnitProfile配置记录关联的静态查询键。
    std::int32_t  radius_mm;                ///< 地面单位导航碰撞半径，单位mm。
    std::int32_t  max_step_mm;              ///< 允许跨越的最大地面台阶高度，单位mm。
    std::uint32_t max_slope_permille;       ///< 允许的最大地面坡度，单位千分比。
    std::uint8_t  area_allowed[256];        ///< 每个Area是否允许通行；已应用Lua配置默认值。
    std::uint16_t area_cost_permille[256];  ///< 每个Area的相对寻路代价，单位千分比；已应用Lua默认值。
};

struct FsSkillProfile
{
    std::uint32_t skill_id;        ///< 技能槽ID：1近战，2表现弹丸，3逻辑弹丸。
    std::uint64_t range_mm;        ///< 技能最大作用距离，单位mm。
    std::uint32_t cooldown_ticks;  ///< 技能冷却时长，单位逻辑Tick。
    std::int32_t  damage;          ///< 技能命中后扣除的HP数值。
    std::uint32_t target_mask;     ///< 目标类别位：1地面、2空中、3两类均可。
    std::uint32_t effect;          ///< 效果类型：1瞬发，2表现弹丸，3逻辑弹丸。
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
