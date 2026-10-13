// 职责：维持一个长期TCP+Protobuf连接，区分控制回包与Server主动FramePush。
// 边界：Unity Client Transport；不执行Native模拟，不读取Transform。
// ownership：单个FrameConnection拥有Socket、读线程、写线程、出站与Push有界队列。
// 失败：任何网络/队列错误关闭Socket、解除等待，主线程自行重连。
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
using Battle.Navigation.V1;
using Google.Protobuf;
using FlyWow.Gateway;

namespace BattleNavigation.FrameSync
{
    public sealed class FrameConnection : IDisposable
    {
        private sealed class Waiting
        {
            public uint Command;
            public readonly TaskCompletionSource<Envelope> Result =
                new TaskCompletionSource<Envelope>(
                    TaskCreationOptions.RunContinuationsAsynchronously);
        }

        private readonly TcpClient socket = new TcpClient();
        private readonly BlockingCollection<byte[]> outgoing =
            new BlockingCollection<byte[]>(128);
        private readonly BlockingCollection<FramePushResponse> pushes =
            new BlockingCollection<FramePushResponse>(256);
        private readonly Dictionary<ulong, Waiting> waiting =
            new Dictionary<ulong, Waiting>();
        private readonly object gate = new object();

        private NetworkStream stream;
        private Thread reader;
        private Thread writer;
        private long nextRequest;
        private int closed;
        private volatile string fault;

        public string Fault => fault;
        public int PushDepth => pushes.Count;

        /// <summary>网络连接和握手在后台执行；成功后调用方负责Dispose。</summary>
        public static async Task<FrameConnection> Connect(string host, int port)
        {
            var value = new FrameConnection();
            try
            {
                await Task.Run(() => value.Open(host, port));
                return value;
            }
            catch
            {
                value.Dispose();
                throw;
            }
        }

        private void Open(string host, int port)
        {
            if (!socket.ConnectAsync(host, port).Wait(3000))
            {
                throw new TimeoutException("CONNECT_TIMEOUT");
            }
            socket.NoDelay = true; // 小输入不等待Nagle合并；TCP队头阻塞仍存在。
            stream = socket.GetStream();
            stream.ReadTimeout = 3000;
            stream.WriteTimeout = 3000;

            using (var handshake = new HandshakeClient())
            {
                WriteFrame(handshake.Begin());
                WriteFrame(handshake.Respond(ReadFrame(99)));
                handshake.Complete(ReadFrame(33));
            }
            stream.ReadTimeout = 10000;

            reader = new Thread(ReadLoop) { IsBackground = true, Name = "FrameRead" };
            writer = new Thread(WriteLoop) { IsBackground = true, Name = "FrameWrite" };
            reader.Start();
            writer.Start();
        }

        private byte[] Exact(int count)
        {
            var buffer = new byte[count];
            int offset = 0;
            while (offset < count)
            {
                int bytes = stream.Read(buffer, offset, count - offset);
                if (bytes == 0) throw new EndOfStreamException("DISCONNECTED");
                offset += bytes;
            }
            return buffer;
        }

        private byte[] ReadFrame(int expected = 0)
        {
            byte[] header = Exact(2);
            int size = (header[0] << 8) | header[1];
            if (size < 1 || (expected != 0 && size != expected))
            {
                throw new InvalidDataException("FRAME_LENGTH");
            }
            return Exact(size);
        }

        private void WriteFrame(byte[] bytes)
        {
            if (bytes == null || bytes.Length < 1 || bytes.Length > 65535)
            {
                throw new InvalidDataException("FRAME_SIZE");
            }
            var frame = new byte[bytes.Length + 2];
            frame[0] = (byte)(bytes.Length >> 8);
            frame[1] = (byte)bytes.Length;
            Buffer.BlockCopy(bytes, 0, frame, 2, bytes.Length);
            stream.Write(frame, 0, frame.Length);
        }

        private void EnqueueEnvelope(uint command, IMessage body, ulong id)
        {
            var payload = new Envelope
            {
                ProtocolVersion = 3,
                Command = command,
                RequestId = id,
                Body = ByteString.CopyFrom(body.ToByteArray()),
            }.ToByteArray();

            if (!outgoing.TryAdd(payload))
            {
                Fail("OUTGOING_LIMIT");
                throw new IOException("OUTGOING_LIMIT");
            }
        }

        /// <summary>单向发送当前Seat未来输入；有界队列满时显式失败。</summary>
        public void SendInputs(FrameInputRequest body)
        {
            if (Volatile.Read(ref closed) != 0) throw new IOException(fault ?? "CLOSED");
            ulong id = checked((ulong)Interlocked.Increment(ref nextRequest));
            EnqueueEnvelope((uint)CommandId.FrameInput, body, id);
        }

        /// <summary>控制请求最多8个在途，超时3秒；网络线程不访问Unity对象。</summary>
        public async Task<Envelope> Request(CommandId command, IMessage body)
        {
            var item = new Waiting { Command = (uint)command };
            ulong id = checked((ulong)Interlocked.Increment(ref nextRequest));
            lock (gate)
            {
                if (closed != 0) throw new IOException(fault ?? "CLOSED");
                if (waiting.Count >= 8) throw new IOException("CONTROL_LIMIT");
                waiting.Add(id, item);
            }

            try
            {
                EnqueueEnvelope((uint)command, body, id);
                if (await Task.WhenAny(item.Result.Task, Task.Delay(3000)) != item.Result.Task)
                {
                    throw new TimeoutException("CONTROL_TIMEOUT");
                }
                return await item.Result.Task;
            }
            finally
            {
                lock (gate) waiting.Remove(id);
            }
        }

        public bool TryPush(out FramePushResponse message)
        {
            return pushes.TryTake(out message);
        }

        private void ReadLoop()
        {
            try
            {
                while (Volatile.Read(ref closed) == 0)
                {
                    var envelope = Envelope.Parser.ParseFrom(ReadFrame());
                    if (envelope.ProtocolVersion != 3)
                    {
                        throw new InvalidDataException("PROTOCOL_VERSION");
                    }
                    if (envelope.RequestId == 0)
                    {
                        if (envelope.Command != (uint)CommandId.FramePush)
                        {
                            throw new InvalidDataException("PUSH_COMMAND");
                        }
                        if (!pushes.TryAdd(FramePushResponse.Parser.ParseFrom(envelope.Body)))
                        {
                            throw new IOException("PUSH_LIMIT");
                        }
                        continue;
                    }

                    Waiting target;
                    lock (gate) waiting.TryGetValue(envelope.RequestId, out target);
                    if (target == null) continue; // 超时旧回复不污染新的request_id。
                    if (target.Command != envelope.Command)
                    {
                        throw new InvalidDataException("RESPONSE_COMMAND");
                    }
                    target.Result.TrySetResult(envelope);
                }
            }
            catch (Exception error)
            {
                Fail(error.Message);
            }
        }

        private void WriteLoop()
        {
            try
            {
                foreach (byte[] bytes in outgoing.GetConsumingEnumerable())
                {
                    WriteFrame(bytes);
                }
            }
            catch (Exception error)
            {
                Fail(error.Message);
            }
        }

        private void Fail(string code)
        {
            if (Interlocked.Exchange(ref closed, 1) != 0) return;
            fault = code;
            outgoing.CompleteAdding();
            socket.Close(); // 中断阻塞的Read/Write；不使用Thread.Abort。
            lock (gate)
            {
                foreach (Waiting item in waiting.Values)
                {
                    item.Result.TrySetException(new IOException(code));
                }
                waiting.Clear();
            }
        }

        public void Dispose()
        {
            Fail("CLOSED");
            if (reader != null && reader != Thread.CurrentThread) reader.Join(1000);
            if (writer != null && writer != Thread.CurrentThread) writer.Join(1000);
        }
    }
}
