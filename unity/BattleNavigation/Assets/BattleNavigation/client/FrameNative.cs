// 职责：调用宿主FrameCore并将规范化State转换为Unity只读渲染视图。
// 边界：Unity Windows Native Adapter；不处理Socket、Skynet和客户端权威。
// 输入/输出：FrameInputs、Checkpoint bytes -> Native新状态或明确异常。
// ownership：一个FrameNative拥有一个SafeHandle；仅Unity主线程调用；Dispose显式释放。
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace BattleNavigation.FrameSync
{
    [StructLayout(LayoutKind.Sequential)]
    public struct FsPlayerInput
    {
        public uint SeatId;
        public uint UnitInstanceId;
        public int X;
        public int Z;
        public int Skill;

        public FsPlayerInput(uint seatId, uint unitInstanceId, int x, int z, int skill)
        {
            SeatId = seatId;
            UnitInstanceId = unitInstanceId;
            X = x;
            Z = z;
            Skill = skill;
        }
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    internal struct FsUnitProfile
    {
        public uint UnitId;
        public uint MovementMode;
        public uint MoveSpeedMmPerSec;
        public int MaxHp;
        public uint MinAirClearanceMm;
        public uint MaxAirAltitudeMm;
        public uint AirRadiusMm; // Air-body half-width on X/Z, millimetres; zero for ground units.
        public uint AirHalfHeightMm; // Air-body half-height on Y, millimetres; zero for ground units.
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    internal struct FsNavigationProfile
    {
        public uint UnitId;
        public int RadiusMm;
        public int MaxStepMm;
        public uint MaxSlopePermille;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)]
        public byte[] AreaAllowed;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)]
        public ushort[] AreaCostPermille;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    internal struct FsSkillProfile
    {
        public uint SkillId;
        public ulong RangeMm;
        public uint CooldownTicks;
        public int Damage;
        public uint TargetMask;
        public uint Effect;
    }

    public sealed class FrameNative : IDisposable
    {
        private const int MaxCheckpointBytes = 65535; // 必须与Native和协议最终帧预算一致。

        [DllImport("frame_core", CallingConvention = CallingConvention.Cdecl)]
        private static extern int fs_preload_map(
            [MarshalAs(UnmanagedType.LPUTF8Str)] string bmapPath,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string airnavPath);

        [DllImport("frame_core", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr fs_open(uint mapId);

        [DllImport("frame_core", CallingConvention = CallingConvention.Cdecl)]
        private static extern int fs_load_profiles(
            [In] FsUnitProfile[] units, uint unitCount,
            [In] FsNavigationProfile[] navigation, uint navigationCount,
            [In] FsSkillProfile[] skills, uint skillCount);

        [DllImport("frame_core", CallingConvention = CallingConvention.Cdecl)]
        private static extern void fs_close(IntPtr handle);

        [DllImport("frame_core", CallingConvention = CallingConvention.Cdecl)]
        private static extern int fs_step_frame(
            FrameHandle handle, uint frame,
            [In] FsPlayerInput[] inputs, uint count);

        [DllImport("frame_core", CallingConvention = CallingConvention.Cdecl)]
        private static extern int fs_save(FrameHandle handle, byte[] output, int capacity);

        [DllImport("frame_core", CallingConvention = CallingConvention.Cdecl)]
        private static extern int fs_restore(FrameHandle handle, byte[] bytes, int count);

        [DllImport("frame_core", CallingConvention = CallingConvention.Cdecl)]
        private static extern uint fs_map_id(FrameHandle handle);

        [DllImport("frame_core", CallingConvention = CallingConvention.Cdecl)]
        private static extern uint fs_map_version(FrameHandle handle);

        private sealed class FrameHandle : SafeHandleZeroOrMinusOneIsInvalid
        {
            public FrameHandle(IntPtr value) : base(true)
            {
                SetHandle(value);
            }

            protected override bool ReleaseHandle()
            {
                fs_close(handle);
                return true;
            }
        }

        private FrameHandle handle; // 唯一Native owner，生命周期不跨Unity对象销毁。

        public uint MapId => fs_map_id(RequireHandle());
        public uint MapVersion => fs_map_version(RequireHandle());

        /// <summary>启动时加载地图与Lua配置；Tick和Battle构造不读取文件。</summary>
        public static void Preload(string bmapPath, string airnavPath, FsUnitProfile[] units,
                                   FsNavigationProfile[] navigation, FsSkillProfile[] skills)
        {
            if (units == null || units.Length == 0 || navigation == null || skills == null ||
                skills.Length != 3 ||
                Marshal.SizeOf<FsUnitProfile>() != 32 ||
                fs_load_profiles(units, (uint)units.Length, navigation, (uint)navigation.Length,
                                skills, (uint)skills.Length) != 1)
                throw new InvalidDataException("UNIT_PROFILE_PRELOAD");
            if (string.IsNullOrWhiteSpace(bmapPath) ||
                fs_preload_map(bmapPath, string.IsNullOrWhiteSpace(airnavPath) ? null : airnavPath) != 1)
                throw new InvalidDataException("MAP_AIRNAV_PRELOAD");
        }

        /// <summary>获取当前MapRegistry已经加载的地图；本实例只拥有模拟状态。</summary>
        public FrameNative(uint mapId)
        {
            handle = new FrameHandle(fs_open(mapId));
            if (handle.IsInvalid)
            {
                handle.Dispose();
                handle = null;
                throw new InvalidDataException("NATIVE_OPEN");
            }
        }

        private FrameHandle RequireHandle()
        {
            if (handle == null || handle.IsClosed || handle.IsInvalid)
            {
                throw new ObjectDisposedException(nameof(FrameNative));
            }
            return handle;
        }

        /// <summary>同步推进一个1/60秒逻辑帧；唯一玩家输入由Core验证，AI状态由Core决定。</summary>
        public void StepFrame(uint frame, FsPlayerInput[] players)
        {
            if (players == null || players.Length != 1 ||
                players[0].SeatId != 1)
            {
                throw new ArgumentException("FRAME_SEATS", nameof(players));
            }
            if (fs_step_frame(RequireHandle(), frame, players, (uint)players.Length) != 1)
            {
                throw new InvalidOperationException("NATIVE_STEP");
            }
        }

        /// <summary>返回独立的规范化Checkpoint副本；容量不够即失败，不允许截断。</summary>
        public byte[] Save()
        {
            var buffer = new byte[MaxCheckpointBytes];
            int size = fs_save(RequireHandle(), buffer, buffer.Length);
            if (size <= 0)
            {
                throw new InvalidOperationException("NATIVE_SAVE");
            }
            Array.Resize(ref buffer, size);
            return buffer;
        }

        /// <summary>完整校验后原子恢复；失败不可部分修改State或Navigation。</summary>
        public void Restore(byte[] bytes)
        {
            if (bytes == null || bytes.Length == 0 || bytes.Length > MaxCheckpointBytes ||
                fs_restore(RequireHandle(), bytes, bytes.Length) != 1)
            {
                throw new InvalidDataException("NATIVE_RESTORE");
            }
        }

        /// <summary>诊断FNV32，跨平台对规范化Checkpoint bytes计算。</summary>
        public static uint Hash(byte[] bytes)
        {
            uint value = 2166136261;
            foreach (byte valueByte in bytes)
            {
                value = unchecked((value ^ valueByte) * 16777619);
            }
            return value;
        }

        public void Dispose()
        {
            handle?.Dispose();
            handle = null;
        }
    }

    public sealed class FrameUnit
    {
        public uint InstanceId;
        public uint UnitProfileId;
        public uint Camp;
        public uint MoveMode;
        public uint Ready1;
        public uint Ready2;
        public uint Ready3;
        public long X;
        public long Y;
        public long Z;
        public int Hp;
    }

    public sealed class FrameBolt
    {
        public uint Id;
        public long X;
        public long Y;
        public long Z;
    }

    public sealed class FrameState
    {
        public uint Frame;
        public uint Winner;
        public readonly List<FrameUnit> Units = new List<FrameUnit>();
        public readonly List<FrameBolt> Bolts = new List<FrameBolt>();

        /// <summary>读取V3完整字节布局；导航Route不用于渲染但必须验证边界。</summary>
        public static FrameState Decode(byte[] bytes)
        {
            if (bytes == null || bytes.Length > 65535)
            {
                throw new InvalidDataException("STATE_SIZE");
            }
            using (var reader = new BinaryReader(new MemoryStream(bytes, false)))
            {
                if (reader.ReadUInt32() != 3)
                {
                    throw new InvalidDataException("STATE_VERSION");
                }

                var result = new FrameState
                {
                    Frame = reader.ReadUInt32(),
                    Winner = reader.ReadUInt32(),
                };
                reader.ReadUInt32(); // next_bolt_id属于Core，渲染不使用。

                uint unitCount = reader.ReadUInt32();
                if (unitCount > 64)
                {
                    throw new InvalidDataException("UNIT_LIMIT");
                }
                uint previousInstanceId = 0;
                for (uint i = 0; i < unitCount; i++)
                {
                    var unit = new FrameUnit
                    {
                        InstanceId = reader.ReadUInt32(),
                        UnitProfileId = reader.ReadUInt32(),
                        Camp = reader.ReadUInt32(),
                        MoveMode = reader.ReadUInt32(),
                        X = reader.ReadInt64(),
                        Y = reader.ReadInt64(),
                        Z = reader.ReadInt64(),
                        Hp = reader.ReadInt32(),
                        Ready1 = reader.ReadUInt32(),
                        Ready2 = reader.ReadUInt32(),
                        Ready3 = reader.ReadUInt32(),
                    };
                    if (unit.InstanceId <= previousInstanceId)
                    {
                        throw new InvalidDataException("STATE_UNIT_ORDER");
                    }
                    previousInstanceId = unit.InstanceId;
                    result.Units.Add(unit);
                }

                uint boltCount = reader.ReadUInt32();
                if (boltCount > 128)
                {
                    throw new InvalidDataException("BOLT_LIMIT");
                }
                uint previousBoltId = 0;
                for (uint i = 0; i < boltCount; i++)
                {
                    var bolt = new FrameBolt();
                    bolt.Id = reader.ReadUInt32();
                    reader.ReadUInt32(); // caster
                    reader.ReadUInt32(); // target
                    reader.ReadUInt32(); // expires
                    reader.ReadInt32();  // damage
                    bolt.X = reader.ReadInt64();
                    bolt.Y = reader.ReadInt64();
                    bolt.Z = reader.ReadInt64();
                    if (bolt.Id <= previousBoltId)
                    {
                        throw new InvalidDataException("STATE_BOLT_ORDER");
                    }
                    previousBoltId = bolt.Id;
                    result.Bolts.Add(bolt);
                }

                uint routeCount = reader.ReadUInt32();
                if (routeCount > unitCount)
                {
                    throw new InvalidDataException("ROUTE_LIMIT");
                }
                uint previousRouteUnit = 0;
                for (uint i = 0; i < routeCount; i++)
                {
                    uint unitId = reader.ReadUInt32();
                    reader.ReadUInt32(); // target_unit_instance_id
                    reader.ReadInt64(); // planned_target_x
                    reader.ReadInt64(); // planned_target_y
                    reader.ReadInt64(); // planned_target_z
                    reader.ReadUInt32(); // next_repath
                    reader.ReadUInt32(); // blocked_frames
                    uint valid = reader.ReadUInt32();
                    uint pointCount = reader.ReadUInt32();
                    uint nextIndex = reader.ReadUInt32();
                    reader.ReadUInt64(); // segment_progress_mm
                    reader.ReadUInt64(); // length_mm
                    uint partial = reader.ReadUInt32();
                    if (unitId <= previousRouteUnit || valid > 1 || partial > 1 ||
                        pointCount > 1024 || nextIndex > pointCount)
                    {
                        throw new InvalidDataException("ROUTE_FORMAT");
                    }
                    previousRouteUnit = unitId;
                    for (uint point = 0; point < pointCount; point++)
                    {
                        reader.ReadInt64(); // 真实X；Native Restore负责地图合法性。
                        reader.ReadInt64(); // 真实Y。
                        reader.ReadInt64(); // 真实Z。
                    }
                }

                if (reader.BaseStream.Position != reader.BaseStream.Length)
                {
                    throw new InvalidDataException("STATE_TRAILING");
                }
                return result;
            }
        }
    }
}
