using System;
using System.IO;
using XLua;

namespace BattleNavigation.FrameSync
{
    internal sealed class FrameLuaProfiles
    {
        public FsUnitProfile[] Units;
        public FsNavigationProfile[] Navigation;
        public FsSkillProfile[] Skills;
        public string ClientAirnavAsset; // Optional AIRN path relative to StreamingAssets.
    }

    internal sealed class FrameLuaProfileLoader : IDisposable
    {
        private readonly LuaEnv env = new LuaEnv();
        private readonly LuaEnv.CustomLoader loader;

        private FrameLuaProfileLoader()
        {
            loader = LoadModule;
            env.AddLoader(loader);
        }

        public static FrameLuaProfiles Load()
        {
            using (var loader = new FrameLuaProfileLoader())
                return loader.Read();
        }

        private byte[] LoadModule(ref string modulePath)
        {
            string relative = modulePath.Replace('.', Path.DirectorySeparatorChar) + ".lua";
            string path = Path.Combine(UnityEngine.Application.streamingAssetsPath, "config", relative);
            return File.Exists(path) ? File.ReadAllBytes(path) : null;
        }

        private FrameLuaProfiles Read()
        {
            object[] a = env.DoString("return require 'config.unit_profiles'");
            object[] b = env.DoString("return require 'config.navigation_profiles'");
            object[] c = env.DoString("return require 'config.frame_sync'");
            using (var units = (LuaTable)a[0])
            using (var navigation = (LuaTable)b[0])
            using (var frameSync = (LuaTable)c[0])
            using (var skills = frameSync.Get<string, LuaTable>("skills"))
            {
                var result = new FrameLuaProfiles
                {
                    Units = new FsUnitProfile[units.Length],
                    Navigation = new FsNavigationProfile[navigation.Length],
                    Skills = new FsSkillProfile[skills.Length],
                    ClientAirnavAsset = frameSync.Get<string, string>("client_airnav_asset"),
                };
                for (int i = 1; i <= units.Length; ++i)
                    result.Units[i - 1] = ReadUnit(units.Get<int, LuaTable>(i));
                for (int i = 1; i <= navigation.Length; ++i)
                    result.Navigation[i - 1] = ReadNavigation(navigation.Get<int, LuaTable>(i));
                Array.Sort(result.Units, (x, y) => x.UnitId.CompareTo(y.UnitId));
                for (int i = 1; i <= skills.Length; ++i)
                    result.Skills[i - 1] = ReadSkill(skills.Get<int, LuaTable>(i));
                Array.Sort(result.Navigation, (x, y) => x.UnitId.CompareTo(y.UnitId));
                Array.Sort(result.Skills, (x, y) => x.SkillId.CompareTo(y.SkillId));
                return result;
            }
        }

        private static FsUnitProfile ReadUnit(LuaTable row)
        {
            using (row)
            using (var movement = row.Get<string, LuaTable>("movement"))
            {
                string mode = movement.Get<string, string>("mode");
                var result = new FsUnitProfile
                {
                    UnitId = row.Get<string, uint>("unit_id"),
                    MovementMode = mode == "ground" ? 1u : mode == "air" ? 2u : 0u,
                    MoveSpeedMmPerSec = movement.Get<string, uint>("speed_mm_per_sec"),
                    MaxHp = row.Get<string, int>("max_hp"),
                };
                if (result.MovementMode == 2)
                {
                    using (var flight = row.Get<string, LuaTable>("flight"))
                    {
                        result.MinAirClearanceMm = flight.Get<string, uint>("min_air_clearance_mm");
                        result.MaxAirAltitudeMm = flight.Get<string, uint>("max_air_altitude_mm");
                        using (var airBody = flight.Get<string, LuaTable>("air_body"))
                        {
                            result.AirRadiusMm = airBody.Get<string, uint>("radius_mm");
                            result.AirHalfHeightMm = airBody.Get<string, uint>("half_height_mm");
                        }
                    }
                }
                if (result.UnitId == 0 || result.MovementMode == 0 ||
                    result.MoveSpeedMmPerSec == 0 || result.MaxHp <= 0 ||
                    (result.MovementMode == 2 &&
                     (result.MinAirClearanceMm == 0 || result.MaxAirAltitudeMm < result.MinAirClearanceMm ||
                      result.AirRadiusMm == 0 || result.AirHalfHeightMm == 0)) ||
                    (result.MovementMode == 1 &&
                     (result.MinAirClearanceMm != 0 || result.MaxAirAltitudeMm != 0 ||
                      result.AirRadiusMm != 0 || result.AirHalfHeightMm != 0)))
                    throw new InvalidDataException("UNIT_PROFILE");
                return result;
            }
        }

        private static FsNavigationProfile ReadNavigation(LuaTable row)
        {
            using (row)
            {
                var result = new FsNavigationProfile
                {
                    UnitId = row.Get<string, uint>("unit_id"),
                    RadiusMm = row.Get<string, int>("radius_mm"),
                    MaxStepMm = row.Get<string, int>("max_step_mm"),
                    MaxSlopePermille = row.Get<string, uint>("max_slope_permille"),
                    AreaAllowed = new byte[256],
                    AreaCostPermille = new ushort[256],
                };
                Array.Fill(result.AreaAllowed, (byte)1);
                Array.Fill(result.AreaCostPermille, (ushort)1000);
                if (row.ContainsKey("area_cost_permille"))
                {
                    using (var costs = row.Get<string, LuaTable>("area_cost_permille"))
                        for (int area = 0; area < 256; ++area)
                            if (costs.ContainsKey(area))
                                result.AreaCostPermille[area] = costs.Get<int, ushort>(area);
                }
                if (row.ContainsKey("area_allowed"))
                {
                    using (var allowed = row.Get<string, LuaTable>("area_allowed"))
                        for (int area = 0; area < 256; ++area)
                            if (allowed.ContainsKey(area))
                                result.AreaAllowed[area] = allowed.Get<int, bool>(area) ? (byte)1 : (byte)0;
                }
                if (result.UnitId == 0 || result.RadiusMm <= 0 || result.MaxStepMm <= 0)
                    throw new InvalidDataException("NAVIGATION_PROFILE");
                return result;
            }
        }

        private static FsSkillProfile ReadSkill(LuaTable row)
        {
            using (row)
            {
                var result = new FsSkillProfile
                {
                    SkillId = row.Get<string, uint>("skill_id"),
                    RangeMm = row.Get<string, ulong>("range_mm"),
                    CooldownTicks = row.Get<string, uint>("cooldown_ticks"),
                    Damage = row.Get<string, int>("damage"),
                    TargetMask = row.Get<string, uint>("target_mask"),
                    Effect = row.Get<string, uint>("effect"),
                };
                if (result.SkillId == 0 || result.CooldownTicks == 0 || result.Damage <= 0 ||
                    result.TargetMask < 1 || result.TargetMask > 3 || result.Effect < 1 ||
                    result.Effect > 3)
                    throw new InvalidDataException("SKILL_PROFILE");
                return result;
            }
        }

        public void Dispose()
        {
            env.Dispose();
        }
    }
}
