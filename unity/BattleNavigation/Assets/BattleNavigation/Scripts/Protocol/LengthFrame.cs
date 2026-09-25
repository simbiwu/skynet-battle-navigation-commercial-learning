// 职责：实现 Unity 侧 4-byte Big Endian TCP 长度帧的打包与增量拆包。
// 边界：Client Runtime Transport；payload 对本文件是不透明 Protobuf bytes。
// 输入/输出：payload 或累计接收 buffer -> frame，或一个 payload + 剩余 bytes。
// 不负责：不连接 Socket、不解析业务消息、不执行地图查询。
using System;
using System.Buffers.Binary;

namespace BattleNavigation.Protocol
{
    /// <summary>4-byte Big Endian 长度头的 TCP framing；不解释 Protobuf 内容。</summary>
    public static class LengthFrame
    {
        // 每个 frame 的固定长度头字节数。
        public const int HeaderSize = 4;
        // 单个 Protobuf Envelope 允许的最大字节数，防止无界分配。
        public const int MaxFrameBytes = 64 * 1024;

        /// <param name="payload">一个完整 Envelope 的序列化字节。</param>
        /// <returns>长度头与 payload 拼接后的完整 frame。</returns>
        public static byte[] Pack(byte[] payload)
        {
            if (payload == null) throw new ArgumentNullException(nameof(payload));
            if (payload.Length > MaxFrameBytes) throw new ArgumentOutOfRangeException(nameof(payload));
            // output 是本次发送拥有的连续 frame 缓冲区。
            var output = new byte[HeaderSize + payload.Length];
            BinaryPrimitives.WriteUInt32BigEndian(output.AsSpan(0, HeaderSize), (uint)payload.Length);
            Buffer.BlockCopy(payload, 0, output, HeaderSize, payload.Length);
            return output;
        }

        /// <param name="buffer">连接当前累计的未消费接收字节；成功后移除一个 frame。</param>
        /// <param name="payload">成功时返回一个完整 payload；数据不足时为 null。</param>
        public static bool TryRead(ref byte[] buffer, out byte[] payload)
        {
            payload = null;
            if (buffer == null || buffer.Length < HeaderSize) return false;
            // length 是网络大端长度头声明的 payload 字节数。
            var length = BinaryPrimitives.ReadUInt32BigEndian(buffer.AsSpan(0, HeaderSize));
            if (length > MaxFrameBytes) throw new InvalidOperationException("frame too large");
            if (buffer.Length < HeaderSize + length) return false;
            payload = new byte[length];
            Buffer.BlockCopy(buffer, HeaderSize, payload, 0, (int)length);
            // remaining 是消费一个完整 frame 后尚未解析的尾部字节数。
            var remaining = buffer.Length - HeaderSize - (int)length;
            // next 保存粘包情况下后续 frame 的未消费字节。
            var next = new byte[remaining];
            Buffer.BlockCopy(buffer, HeaderSize + (int)length, next, 0, remaining);
            buffer = next;
            return true;
        }
    }
}