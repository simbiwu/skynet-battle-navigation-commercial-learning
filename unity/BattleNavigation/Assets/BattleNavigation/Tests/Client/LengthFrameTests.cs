// 职责：锁定 Unity Client 与 Skynet netpack 共用的 uint16 Big Endian framing 合同。
// 边界：Unity EditMode Test；只验证纯字节计算，不打开 Socket 或启动 Server。
// 输入/输出：固定 payload、半包和粘包字节 -> NUnit 断言结果。
// 生命周期：每个测试独占输入 buffer，不共享连接状态。
// 不负责：不验证 Protobuf、request_id、Gateway 生命周期或业务响应。
using System;
using NUnit.Framework;
using BattleNavigation.Protocol;

namespace BattleNavigation.Tests
{
    /// <summary>防止客户端长度头回退到与 Skynet netpack 不兼容的 4-byte 实现。</summary>
    public sealed class LengthFrameTests
    {
        /// <summary>验证 Pack 使用 2-byte 网络大端长度头并原样保留 payload。</summary>
        [Test]
        public void PackUsesNetpackUInt16BigEndianHeader()
        {
            byte[] frame = LengthFrame.Pack(new byte[] { 0x11, 0x22, 0x33 });

            Assert.That(LengthFrame.HeaderSize, Is.EqualTo(2));
            Assert.That(frame, Is.EqualTo(new byte[] { 0x00, 0x03, 0x11, 0x22, 0x33 }));
        }

        /// <summary>验证半包不消费输入，粘包则一次只消费一个完整 frame。</summary>
        [Test]
        public void TryReadPreservesHalfPacketAndConsumesOneStickyPacket()
        {
            byte[] first = LengthFrame.Pack(new byte[] { 0x41, 0x42 });
            byte[] second = LengthFrame.Pack(new byte[] { 0x51 });

            // half 只有长度头和第一个 payload byte，不能提前消费。
            byte[] half = new byte[] { first[0], first[1], first[2] };
            byte[] originalHalf = (byte[])half.Clone();
            Assert.That(LengthFrame.TryRead(ref half, out byte[] missing), Is.False);
            Assert.That(missing, Is.Null);
            Assert.That(half, Is.EqualTo(originalHalf));

            // sticky 模拟一次 TCP Read 同时带回两个完整 frame。
            byte[] sticky = new byte[first.Length + second.Length];
            Buffer.BlockCopy(first, 0, sticky, 0, first.Length);
            Buffer.BlockCopy(second, 0, sticky, first.Length, second.Length);

            Assert.That(LengthFrame.TryRead(ref sticky, out byte[] firstPayload), Is.True);
            Assert.That(firstPayload, Is.EqualTo(new byte[] { 0x41, 0x42 }));
            Assert.That(sticky, Is.EqualTo(second));

            Assert.That(LengthFrame.TryRead(ref sticky, out byte[] secondPayload), Is.True);
            Assert.That(secondPayload, Is.EqualTo(new byte[] { 0x51 }));
            Assert.That(sticky, Is.Empty);
        }

        /// <summary>验证超过 uint16 能力的 payload 在分配 frame 前显式失败。</summary>
        [Test]
        public void PackRejectsPayloadLargerThanNetpackLimit()
        {
            byte[] oversized = new byte[LengthFrame.MaxFrameBytes + 1];
            Assert.Throws<ArgumentOutOfRangeException>(() => LengthFrame.Pack(oversized));
        }
    }
}
