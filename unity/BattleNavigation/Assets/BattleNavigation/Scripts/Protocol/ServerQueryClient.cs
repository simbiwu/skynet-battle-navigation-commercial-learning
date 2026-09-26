// 职责：供 Unity Editor 调试时同步发送一次 QueryCell 并校验对应响应。
// 边界：Client Runtime/Editor Debug；同步阻塞实现禁止放入每帧 Update。
// 输入/输出：Server 地址、地图身份和 WorldPosition(mm) -> QueryCellResponse。
// 生命周期：实例拥有一个 TcpClient/NetworkStream，由 Dispose 关闭。
// 不负责：不做连接池、自动重试、高频查询或战斗模拟。
using System;
using System.IO;
using System.Net.Sockets;
using Battle.Navigation.V1;
using Google.Protobuf;
using BattleNavigation.Protocol;

namespace BattleNavigation.Client
{
    /// <summary>
    /// 第一课 Editor 调试用同步短连接客户端；不放入战斗 Update，不承担高频查询。
    /// </summary>
    public sealed class ServerQueryClient : IDisposable
    {
        // Envelope 协议版本，必须与 Skynet Gateway 一致。
        private const uint ProtocolVersion = 1;
        // QueryCell 命令号，必须与 Lua dispatch 表一致。
        private const uint QueryCellCommand = 1001;
        // 当前 Editor 进程内递增的请求 ID；该调试客户端不并发共享实例。
        private static ulong nextRequestId = 1;
        // 当前连接的 TCP 客户端所有者。
        private readonly TcpClient client;
        // 与 client 绑定的同步读写流。
        private readonly NetworkStream stream;

        /// <param name="host">Skynet Gateway 主机名或 IP。</param>
        /// <param name="port">Skynet Gateway TCP 端口。</param>
        public ServerQueryClient(string host, int port)
        {
            client = new TcpClient();
            client.Connect(host, port);
            stream = client.GetStream();
            stream.ReadTimeout = 3000;
            stream.WriteTimeout = 3000;
        }

        /// <param name="mapId">服务端地图 ID。</param>
        /// <param name="mapVersion">期望查询的地图资产版本。</param>
        /// <param name="xMm">WorldPosition X，单位毫米。</param>
        /// <param name="yMm">WorldPosition Y，单位毫米。</param>
        /// <param name="zMm">WorldPosition Z，单位毫米。</param>
        public QueryCellResponse Query(uint mapId, uint mapVersion, long xMm, long yMm, long zMm)
        {
            // request 是业务 QueryCell 请求，位置始终使用毫米制 WorldPosition。
            var request = new QueryCellRequest
            {
                MapId = mapId,
                MapVersion = mapVersion,
                Position = new WorldPosition { XMm = xMm, YMm = yMm, ZMm = zMm },
            };
            // body 是 QueryCellRequest 的 Protobuf 字节，不包含命令和 request_id。
            var body = request.ToByteArray();
            // envelope 添加版本、命令和关联响应所需 request_id。
            var envelope = new Envelope
            {
                ProtocolVersion = ProtocolVersion,
                Command = QueryCellCommand,
                RequestId = nextRequestId++,
                Body = ByteString.CopyFrom(body),
            };
            // frame 添加 TCP 4-byte Big Endian 长度头。
            var frame = LengthFrame.Pack(envelope.ToByteArray());
            stream.Write(frame, 0, frame.Length);
            // responseEnvelope 是服务端返回并完成 framing 后的 Envelope。
            var responseEnvelope = Envelope.Parser.ParseFrom(ReadFrame());
            if (responseEnvelope.ProtocolVersion != ProtocolVersion)
                throw new InvalidDataException("protocol version mismatch");
            if (responseEnvelope.RequestId != envelope.RequestId)
                throw new InvalidDataException("request id mismatch");
            return QueryCellResponse.Parser.ParseFrom(responseEnvelope.Body);
        }

        private byte[] ReadFrame()
        {
            // header 是与 Skynet netpack 一致的固定 2-byte Big Endian payload 长度。
            var header = ReadExact(LengthFrame.HeaderSize);
            // length 是从网络字节序解码出的响应 Envelope 字节数。
            var length = (header[0] << 8) | header[1];
            if (length <= 0 || length > LengthFrame.MaxFrameBytes)
                throw new InvalidDataException("invalid frame length");
            return ReadExact(length);
        }

        /// <param name="count">必须从 TCP stream 读取的精确字节数。</param>
        private byte[] ReadExact(int count)
        {
            // result 是最终精确长度的返回缓冲区。
            var result = new byte[count];
            // offset 是已经成功读入 result 的字节数。
            var offset = 0;
            // TCP 可能短读，循环直到累计 count bytes。
            while (offset < count)
            {
                // read 是本次 stream.Read 实际返回的字节数；TCP 不保证一次读满。
                var read = stream.Read(result, offset, count - offset);
                if (read == 0) throw new EndOfStreamException();
                offset += read;
            }
            return result;
        }

        public void Dispose()
        {
            stream?.Dispose();
            client?.Close();
        }
    }
}
