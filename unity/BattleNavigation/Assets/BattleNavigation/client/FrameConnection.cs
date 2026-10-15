// 帧同步业务适配；网络握手、读写、容量与释放由共用GatewayConnection负责。
using System;
using System.Threading.Tasks;
using Battle.Transport.V1;
using Battle.Lesson03.FrameSync.V1;
using BattleNavigation.Client;
using Google.Protobuf;
namespace BattleNavigation.FrameSync
{
    public sealed class FrameConnection : IDisposable
    {
        private readonly GatewayConnection connection;
        private FrameConnection(GatewayConnection value) { connection = value; }
        public string Fault => connection.Fault;
        public int PushDepth => connection.PushDepth;
        public static async Task<FrameConnection> Connect(string host, int port)
        {
            return new FrameConnection(await GatewayConnection.Connect(host, port, (uint)CommandId.FramePush));
        }
        public void SendInputs(FrameInputRequest body) { connection.Send((uint)CommandId.FrameInput, body); }
        public Task<Envelope> Request(CommandId command, IMessage body) { return connection.Request((uint)command, body); }
        public bool TryPush(out FramePushResponse message)
        {
            Envelope envelope;
            if (!connection.TryPush(out envelope)) { message = null; return false; }
            if (envelope.Command != (uint)CommandId.FramePush) throw new System.IO.InvalidDataException("FRAME_PUSH_COMMAND");
            message = FramePushResponse.Parser.ParseFrom(envelope.Body);
            return true;
        }
        public void Dispose() { connection.Dispose(); }
    }
}
