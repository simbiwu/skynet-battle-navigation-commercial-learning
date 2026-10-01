// 职责：为 QueryCell 和自动战斗共用 TCP 长度帧与 Envelope 往返。
// 边界：Unity Client Runtime Transport；不解析地图或战斗业务字段。
// 输入/输出：command + Protobuf 请求 -> 同 request_id 的响应 Envelope。
// 生命周期：一个实例独占 TcpClient/NetworkStream，调用方负责 Dispose。
// 不负责：不重试、不连接池化、不在 Update 执行同步 I/O。
using System;
using System.IO;
using System.Net.Sockets;
using System.Threading;
using Battle.Navigation.V1;
using BattleNavigation.Protocol;
using Google.Protobuf;
using FlyWow.Gateway;

namespace BattleNavigation.Client
{
    /// <summary>一个调用线程独占的短连接 Gateway 客户端。</summary>
    public sealed class GatewayEnvelopeClient : IDisposable
    {
        private const uint ProtocolVersion = 3; // 与 Gateway 及 sint64 WorldPosition 合同一致。
        private static long nextRequestId;       // 当前进程内单调递增。
        private readonly TcpClient client;       // 当前实例独占 Socket。
        private readonly NetworkStream stream;   // 对应的同步读写流。

        /// <summary>建立短连接，失败抛异常；不得在每帧 Update 调用。</summary>
        /// <param name="host">Gateway 主机名或 IP。</param>
        /// <param name="port">Gateway TCP 端口，1..65535。</param>
        public GatewayEnvelopeClient(string host, int port)
        {
            if (string.IsNullOrWhiteSpace(host)) throw new ArgumentException("empty host", nameof(host));
            if (port < 1 || port > ushort.MaxValue) throw new ArgumentOutOfRangeException(nameof(port));
            client = new TcpClient();
            try
            {
                if (!client.ConnectAsync(host, port).Wait(3000))
                    throw new TimeoutException("Gateway connect timeout");
                stream = client.GetStream();
                stream.ReadTimeout = 3000;
                stream.WriteTimeout = 3000;
                // SDK封装连接握手；业务调用方不接触密钥、挑战或HMAC。
                // 只有服务端证明验证通过，构造才成功返回；失败统一关闭当前Socket。
                using (var handshake = new HandshakeClient())
                {
                    WriteHandshake(handshake.Begin());
                    WriteHandshake(handshake.Respond(ReadHandshake(99)));
                    handshake.Complete(ReadHandshake(33));
                }
            }
            catch
            {
                client.Dispose();
                throw;
            }
        }

        /// <summary>发送SDK生成的握手消息；复用现有长度帧，不进入业务Envelope。</summary>
        private void WriteHandshake(byte[] payload)
        {
            var frame = LengthFrame.Pack(payload);
            stream.Write(frame, 0, frame.Length);
        }

        /// <summary>先验证握手阶段的精确长度，再分配读取；错误消息抛异常并由构造关闭。</summary>
        /// <param name="expectedSize">当前阶段固定的字节数，99或33。</param>
        private byte[] ReadHandshake(int expectedSize)
        {
            var header = ReadExact(LengthFrame.HeaderSize);
            var size = (header[0] << 8) | header[1];
            if (size != expectedSize) throw new InvalidDataException("HANDSHAKE_FRAME");
            return ReadExact(size);
        }

        /// <summary>发送一个请求并验证响应版本、命令和请求身份。</summary>
        /// <param name="command">生成 registry 中的 command ID，例如 1001/1002。</param>
        /// <param name="request">调用方拥有的 Protobuf 请求；不保存引用。</param>
        /// <returns>新解析的响应 Envelope；业务 body 由调用方解析。</returns>
        public Envelope RoundTrip(uint command, IMessage request)
        {
            if (request == null) throw new ArgumentNullException(nameof(request));
            var requestId = checked((ulong)Interlocked.Increment(ref nextRequestId));
            var envelope = new Envelope
            {
                ProtocolVersion = ProtocolVersion,
                Command = command,
                RequestId = requestId,
                Body = ByteString.CopyFrom(request.ToByteArray()),
            };
            var frame = LengthFrame.Pack(envelope.ToByteArray());
            stream.Write(frame, 0, frame.Length);
            var response = Envelope.Parser.ParseFrom(ReadFrame());
            if (response.ProtocolVersion != ProtocolVersion ||
                response.Command != command || response.RequestId != requestId)
                throw new InvalidDataException("Gateway response identity mismatch");
            return response;
        }

        /// <summary>按 uint16 大端长度读一个完整帧；空帧、短读和 EOF 显式失败。</summary>
        /// <returns>新分配的 Envelope 字节数组。</returns>
        private byte[] ReadFrame()
        {
            var header = ReadExact(LengthFrame.HeaderSize);
            var size = (header[0] << 8) | header[1];
            if (size < 1 || size > LengthFrame.MaxFrameBytes)
                throw new InvalidDataException("invalid Gateway frame length");
            return ReadExact(size);
        }

        /// <summary>循环读满字节数，避免把 TCP 短读误当成完整消息。</summary>
        /// <param name="count">需要的精确 byte 数，必须大于零。</param>
        /// <returns>新分配的缓冲区；EOF 抛 EndOfStreamException。</returns>
        private byte[] ReadExact(int count)
        {
            if (count < 1) throw new ArgumentOutOfRangeException(nameof(count));
            var bytes = new byte[count];
            var offset = 0;
            while (offset < count)
            {
                var read = stream.Read(bytes, offset, count - offset);
                if (read == 0) throw new EndOfStreamException();
                offset += read;
            }
            return bytes;
        }

        /// <summary>关闭本实例的流和 Socket。</summary>
        public void Dispose()
        {
            stream?.Dispose();
            client.Dispose();
        }
    }
}
