// 本地移动预测只调用FlyWow Navigation薄C ABI；实例仅在Unity主线程使用。
using System;
using System.Runtime.InteropServices;
using Battle.Navigation.V1;
using BattleNavigation.FrameSync;
namespace BattleNavigation.StateSync
{
    internal sealed class StateMovement : IDisposable
    {
        [DllImport("state_navigation", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr ss_open([MarshalAs(UnmanagedType.LPUTF8Str)] string path,
            int radius, int step, uint slope, byte[] allowed, ushort[] cost);
        [DllImport("state_navigation", CallingConvention = CallingConvention.Cdecl)]
        private static extern int ss_reset(IntPtr handle, long[] position, long[] output);
        [DllImport("state_navigation", CallingConvention = CallingConvention.Cdecl)]
        private static extern int ss_step(IntPtr handle, uint sequence, int x, int z, uint speed, long[] output);
        [DllImport("state_navigation", CallingConvention = CallingConvention.Cdecl)]
        private static extern void ss_close(IntPtr handle);
        private IntPtr handle;
        private readonly long[] output = new long[3];
        public WorldPosition Position { get; private set; }
        public StateMovement(string path, FsNavigationProfile profile)
        {
            handle = ss_open(path, profile.RadiusMm, profile.MaxStepMm, profile.MaxSlopePermille,
                profile.AreaAllowed, profile.AreaCostPermille);
            if (handle == IntPtr.Zero) throw new System.IO.InvalidDataException("PREDICTION_OPEN");
        }
        public void Reset(WorldPosition position)
        {
            if (handle == IntPtr.Zero) throw new ObjectDisposedException(nameof(StateMovement));
            if (ss_reset(handle, new[] { position.XMm, position.YMm, position.ZMm }, output) < 0)
                throw new System.IO.InvalidDataException("PREDICTION_RESET");
            Position = new WorldPosition { XMm = output[0], YMm = output[1], ZMm = output[2] };
        }
        public void Step(StateInput input, uint speed)
        {
            if (handle == IntPtr.Zero) throw new ObjectDisposedException(nameof(StateMovement));
            if (ss_step(handle, input.InputSeq, input.X, input.Z, speed, output) < 0)
                throw new System.IO.InvalidDataException("PREDICTION_STEP");
            Position = new WorldPosition { XMm = output[0], YMm = output[1], ZMm = output[2] };
        }
        public void Dispose()
        {
            if (handle == IntPtr.Zero) return;
            ss_close(handle);
            handle = IntPtr.Zero;
        }
    }
}
