// 职责：单席位帧同步的Unity输入、预测、权威确认、回滚和场景表现。
// 边界：Unity主线程Client Battle Adapter；业务规则只由共享Native Frame Core计算。
// 输入/输出：本地WASD/J/K/L与FramePush -> 本地预测画面、确认HP、Replay文件。
// ownership：Controller独占两个FrameNative、一个FrameConnection及创建的GameObject/Material。
// 不负责：Skynet Tick、授权、Gateway握手实现、Navigation/A*与服务端权威决定。
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Threading.Tasks;
using Battle.Navigation.V1;
using Google.Protobuf;
using UnityEngine;

namespace BattleNavigation.FrameSync
{
    public sealed class FrameBattleController : MonoBehaviour
    {
        public string Host = "127.0.0.1";
        public int Port = 19021;
        public uint JoinBattleId = 0;  // 0创建并立即开始单人Battle；非0请求连接已有Battle。
        public string ReplayPath = ""; // 非空时读取离线回放，不连接Server。

        private const uint SimulationVersion = 2; // 与Server配置一致；不兼容玩法合同必须递增。
        private const int MaxPredictionFrames = 24;
        private const int LeadFrames = 6;
        private const double TickSeconds = 1.0 / 60.0;

        private FrameConnection connection;
        private FrameNative confirmed;
        private FrameNative predicted;
        private FrameJoinResponse session;
        private FrameReplay replay;
        private int replay_index;

        private readonly SortedDictionary<uint, FrameCommand> pending =
            new SortedDictionary<uint, FrameCommand>(); // 未确认的本席位输入，由客户端主线程独占。
        private readonly Dictionary<uint, GameObject> actors =
            new Dictionary<uint, GameObject>();
        private readonly Dictionary<uint, GameObject> bolts =
            new Dictionary<uint, GameObject>();
        private readonly List<Material> owned_materials = new List<Material>();

        private uint confirmed_frame;
        private uint predicted_frame;
        private uint winner;
        private int rollback_count;
        private int queued_skill;
        private double clock_accumulator;
        private float preview_until;
        private string status = "initializing";
        private bool ready;
        private bool connecting;
        private bool destroyed;
        private bool saving_replay;

        private string MapPath => Path.Combine(
            Application.streamingAssetsPath, "navigation/battle_1001.bmap");

        private async void Start()
        {
            try
            {
                FrameLuaProfiles profiles = FrameLuaProfileLoader.Load();
                string airnavPath = string.IsNullOrWhiteSpace(profiles.ClientAirnavAsset)
                    ? null
                    : Path.Combine(Application.streamingAssetsPath, profiles.ClientAirnavAsset);
                FrameNative.Preload(MapPath, airnavPath,
                                    profiles.Units, profiles.Navigation, profiles.Skills);
                confirmed = new FrameNative(1001);
                predicted = new FrameNative(1001);

                if (!string.IsNullOrEmpty(ReplayPath))
                {
                    if (new FileInfo(ReplayPath).Length > 1024 * 1024)
                    {
                        throw new InvalidDataException("REPLAY_LIMIT");
                    }
                    replay = FrameReplay.Parser.ParseFrom(File.ReadAllBytes(ReplayPath));
                    if (replay.FormatVersion != 1 || replay.Initial == null ||
                        replay.Initial.SimulationVersion != SimulationVersion || replay.Initial.TickRateHz != 60 ||
                        replay.Records.Count == 0 || replay.Records.Count > 10800)
                    {
                        throw new InvalidDataException("REPLAY_FORMAT");
                    }
                    session = replay.Initial;
                    InstallCheckpoint(replay.Initial.Checkpoint.ToByteArray(), 0);
                    status = "offline replay";
                    return;
                }

                await Connect(false);
            }
            catch (Exception error)
            {
                StopWith(error.Message);
            }
        }

        // 恢复只携带本席位Token；不会创建另一场Battle或踢掉另一名玩家。
        private async Task Connect(bool recover)
        {
            connecting = true;
            ready = false;
            connection?.Dispose();
            var next = await FrameConnection.Connect(Host, Port);
            if (destroyed)
            {
                next.Dispose();
                return;
            }
            connection = next;

            FrameJoinResponse response;
            if (recover)
            {
                if (session == null) throw new IOException("NO_SESSION");
                var envelope = await connection.Request(CommandId.FrameRecover,
                    new FrameRecoverRequest
                    {
                        BattleId = session.BattleId,
                        ResumeToken = session.ResumeToken,
                    });
                response = FrameRecoverResponse.Parser.ParseFrom(envelope.Body).State;
            }
            else
            {
                var envelope = await connection.Request(CommandId.FrameJoin,
                    new FrameJoinRequest
                    {
                        ScenarioId = 1001,
                        BattleId = JoinBattleId,
                        SimulationVersion = SimulationVersion,
                    });
                response = FrameJoinResponse.Parser.ParseFrom(envelope.Body);
            }

            if (destroyed) return;
            if (response == null || response.Code != "OK")
            {
                throw new IOException(response?.Code ?? "EMPTY_SESSION");
            }
            if (response.SeatId != 1 || response.SimulationVersion != SimulationVersion ||
                response.FutureWindow != MaxPredictionFrames || response.TickRateHz != 60)
            {
                throw new InvalidDataException("FRAME_CONTRACT");
            }

            ValidateMapIdentity(response);
            session = response;
            status = "joined";
            connecting = false;
            if (response.Code == "OK")
            {
                InstallCheckpoint(response.Checkpoint.ToByteArray(), response.Frame);
            }
        }

        private void ValidateMapIdentity(FrameJoinResponse state)
        {
            if (state.MapId != confirmed.MapId || state.MapVersion != confirmed.MapVersion)
            {
                throw new InvalidDataException("MAP_VERSION");
            }
            using (var sha = SHA256.Create())
            {
                var bytes = File.ReadAllBytes(MapPath);
                string digest = BitConverter.ToString(sha.ComputeHash(bytes))
                    .Replace("-", "").ToLowerInvariant();
                if (!string.Equals(digest, state.MapHash, StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidDataException("MAP_HASH_MISMATCH");
                }
            }
        }

        // 回滚入口：覆盖两个Native实例，清除旧代数未确认输入。
        private void InstallCheckpoint(byte[] bytes, uint expected_frame)
        {
            if (bytes == null || bytes.Length == 0) throw new InvalidDataException("CHECKPOINT_EMPTY");
            confirmed.Restore(bytes);
            predicted.Restore(bytes);
            var view = FrameState.Decode(confirmed.Save());
            if (view.Frame != expected_frame) throw new InvalidDataException("CHECKPOINT_FRAME");

            confirmed_frame = view.Frame;
            predicted_frame = view.Frame;
            winner = view.Winner;
            pending.Clear();
            queued_skill = 0;
            clock_accumulator = 0;
            ready = true;
            status = "running";

            // 离线Replay必须严格从输入日志下一帧开始，不应用在线输入提前量。
            if (replay == null && winner == 0)
            {
                for (int i = 0; i < LeadFrames; ++i)
                {
                    Predict(new FrameCommand { Frame = predicted_frame + 1 }, false);
                }
            }
        }

        private const uint LocalUnitInstanceId = 1001;

        private FsPlayerInput[] BuildInputs(FrameCommand local)
        {
            return new[] { new FsPlayerInput(1, LocalUnitInstanceId, local.X, local.Z, (int)local.Skill) };
        }

        private static FsPlayerInput[] AuthoritativeInputs(FrameRecord record)
        {
            if (record.Players.Count != 1 || record.Players[0].SeatId != 1)
            {
                throw new InvalidDataException("FRAME_PLAYER_ORDER");
            }
            var values = new FsPlayerInput[1];
            for (int i = 0; i < 1; ++i)
            {
                var player = record.Players[i];
                if (player.Input == null || player.Input.Frame != record.Frame)
                {
                    throw new InvalidDataException("FRAME_INPUT");
                }
                values[i] = new FsPlayerInput(player.SeatId,
                    1001u,
                    player.Input.X, player.Input.Z, (int)player.Input.Skill);
            }
            return values;
        }

        private void Predict(FrameCommand input, bool send)
        {
            if (input.Frame != predicted_frame + 1)
            {
                throw new InvalidOperationException("PREDICTION_SEQUENCE");
            }
            predicted.StepFrame(input.Frame, BuildInputs(input));
            predicted_frame = input.Frame;
            if (send)
            {
                pending[input.Frame] = input;
                connection.SendInputs(new FrameInputRequest
                {
                    BattleId = session.BattleId,
                    Generation = session.Generation,
                    Inputs = { input },
                });
            }
        }

        private void Receive(FramePushResponse push)
        {
            if (session == null || push.BattleId != session.BattleId ||
                push.Generation != session.Generation) return;

            if (push.Code != "OK")
            {
                status = push.Code;
                if (push.Code == "OVERLOAD" || push.Code == "INTERNAL")
                {
                    throw new IOException(push.Code);
                }
                return; // LATE/CONFLICT等待正式输入帧校正，不重写权威历史。
            }
            if (!ready) throw new IOException("FRAME_BEFORE_START");

            foreach (FrameRecord record in push.Records)
            {
                if (record.Frame <= confirmed_frame) continue;
                if (record.Frame != confirmed_frame + 1)
                {
                    throw new InvalidDataException("FRAME_GAP");
                }

                confirmed.StepFrame(record.Frame, AuthoritativeInputs(record));
                if (FrameNative.Hash(confirmed.Save()) != record.Hash)
                {
                    throw new InvalidDataException("STATE_DIVERGENCE");
                }
                confirmed_frame = record.Frame;
                pending.Remove(confirmed_frame);
            }
            winner = FrameState.Decode(confirmed.Save()).Winner;
            if (winner == 0)
            {
                Reconcile();
            }
            else
            {
                predicted.Restore(confirmed.Save());
                predicted_frame = confirmed_frame; // 已正式结束时停止预测未来帧。
                pending.Clear();
            }
        }

        private void Reconcile()
        {
            uint old_frame = predicted_frame;
            var old_hash = FrameNative.Hash(predicted.Save());
            uint target = Math.Max(old_frame, confirmed_frame + LeadFrames);
            if (target - confirmed_frame > MaxPredictionFrames)
            {
                throw new IOException("PREDICTION_WINDOW");
            }

            predicted.Restore(confirmed.Save());
            predicted_frame = confirmed_frame;
            while (predicted_frame < target && winner == 0)
            {
                uint frame = predicted_frame + 1;
                if (!pending.TryGetValue(frame, out var local))
                {
                    local = new FrameCommand { Frame = frame };
                }
                predicted.StepFrame(frame, BuildInputs(local));
                predicted_frame = frame;
                if (FrameState.Decode(predicted.Save()).Winner != 0) break;
            }
            if (old_frame == predicted_frame && old_hash != FrameNative.Hash(predicted.Save()))
            {
                ++rollback_count;
            }
        }

        private void CaptureInput()
        {
            if (Input.GetKeyDown(KeyCode.J)) queued_skill = 1;
            else if (Input.GetKeyDown(KeyCode.K)) queued_skill = 2;
            else if (Input.GetKeyDown(KeyCode.L)) queued_skill = 3;
            if (queued_skill != 0) preview_until = Time.unscaledTime + 0.12f;
        }

        private void LocalStep()
        {
            if (predicted_frame - confirmed_frame >= MaxPredictionFrames)
            {
                throw new IOException("PREDICTION_WINDOW");
            }
            int x = (Input.GetKey(KeyCode.D) ? 1 : 0) - (Input.GetKey(KeyCode.A) ? 1 : 0);
            int z = (Input.GetKey(KeyCode.W) ? 1 : 0) - (Input.GetKey(KeyCode.S) ? 1 : 0);
            var input = new FrameCommand
            {
                Frame = predicted_frame + 1,
                X = x,
                Z = z,
                Skill = (uint)queued_skill,
            };
            queued_skill = 0;
            Predict(input, true);
        }

        private void ReplayStep()
        {
            if (replay_index >= replay.Records.Count)
            {
                throw new InvalidDataException("REPLAY_END");
            }
            FrameRecord record = replay.Records[replay_index++];
            if (record.Frame != predicted_frame + 1)
            {
                throw new InvalidDataException("REPLAY_FRAME_GAP");
            }
            predicted.StepFrame(record.Frame, AuthoritativeInputs(record));
            if (FrameNative.Hash(predicted.Save()) != record.Hash)
            {
                throw new InvalidDataException("REPLAY_DIVERGENCE");
            }
            predicted_frame = confirmed_frame = record.Frame;
            winner = FrameState.Decode(predicted.Save()).Winner;
        }

        private void Update()
        {
            if (destroyed || connecting) return;
            try
            {
                if (connection != null)
                {
                    if (connection.Fault != null) throw new IOException(connection.Fault);
                    int processed = 0;
                    while (connection.TryPush(out var push))
                    {
                        if (++processed > 256) throw new IOException("PUSH_BUDGET");
                        Receive(push);
                    }
                }

                if (!ready) return;
                if (replay == null) CaptureInput();
                clock_accumulator += Time.unscaledDeltaTime;
                int executed = 0;
                while (clock_accumulator >= TickSeconds && winner == 0)
                {
                    if (++executed > 4) throw new IOException("CLIENT_OVERLOAD");
                    clock_accumulator -= TickSeconds;
                    if (replay != null) ReplayStep();
                    else LocalStep();
                }
                Render(FrameState.Decode(predicted.Save()));
            }
            catch (Exception error)
            {
                StopWith(error.Message);
            }
        }

        private static Vector3 World(long x, long y, long z)
        {
            return new Vector3(x / 1000f, y / 1000f, z / 1000f);
        }

        private GameObject GetActor(uint id, bool projectile)
        {
            var index = projectile ? bolts : actors;
            if (index.TryGetValue(id, out var value)) return value;

            var actor = GameObject.CreatePrimitive(projectile ? PrimitiveType.Sphere : PrimitiveType.Capsule);
            actor.name = (projectile ? "Bolt_" : "Unit_") + id;
            Destroy(actor.GetComponent<Collider>()); // Unity碰撞不能进入Native权威模拟。
            actor.transform.localScale = projectile ? Vector3.one * .25f :
                new Vector3(.4f, 1f, .4f);
            owned_materials.Add(actor.GetComponent<Renderer>().material);
            index.Add(id, actor);
            return actor;
        }

        private void DestroyActor(GameObject actor)
        {
            var renderer = actor.GetComponent<Renderer>();
            if (renderer != null)
            {
                var material = renderer.material;
                owned_materials.Remove(material);
                Destroy(material);
            }
            Destroy(actor);
        }

        private void Render(FrameState view)
        {
            var official = replay == null ? FrameState.Decode(confirmed.Save()) : view;
            foreach (FrameUnit unit in view.Units)
            {
                var actor = GetActor(unit.InstanceId, false);
                var confirmed_unit = official.Units.First(u => u.InstanceId == unit.InstanceId);
                actor.SetActive(confirmed_unit.Hp > 0);
                Vector3 target = World(unit.X, unit.Y, unit.Z) + Vector3.up;
                float distance = Vector3.Distance(actor.transform.position, target);
                actor.transform.position = distance > 2f ? target :
                    Vector3.Lerp(actor.transform.position, target,
                        1f - Mathf.Exp(-Time.unscaledDeltaTime * 30f));
                Color color = unit.Camp == 1 ? Color.green : Color.red;
                if (unit.InstanceId == LocalUnitInstanceId && Time.unscaledTime < preview_until)
                {
                    color = Color.yellow;
                }
                actor.GetComponent<Renderer>().material.color = color;
            }

            var present = new HashSet<uint>();
            foreach (FrameBolt bolt in view.Bolts)
            {
                present.Add(bolt.Id);
                var actor = GetActor(bolt.Id, true);
                actor.transform.position = World(bolt.X, bolt.Y, bolt.Z) + Vector3.up;
                actor.GetComponent<Renderer>().material.color = Color.cyan;
            }
            foreach (uint id in bolts.Keys.ToArray())
            {
                if (!present.Contains(id))
                {
                    DestroyActor(bolts[id]);
                    bolts.Remove(id);
                }
            }
        }

        private async void Recover()
        {
            if (connecting || session == null || replay != null) return;
            try { await Connect(true); }
            catch (Exception error) { connecting = false; StopWith(error.Message); }
        }

        private async void SaveReplay()
        {
            if (saving_replay || destroyed || replay != null || session == null) return;
            saving_replay = true;
            try
            {
                if (winner == 0) throw new IOException("REPLAY_REQUIRES_FINISHED");
                var file = new FrameReplay { FormatVersion = 1 };
                uint offset = 0;
                uint total;
                do
                {
                    var envelope = await connection.Request(CommandId.FrameReplay,
                        new FrameReplayRequest
                        {
                            BattleId = session.BattleId,
                            ResumeToken = session.ResumeToken,
                            Offset = offset,
                        });
                    var page = FrameReplayResponse.Parser.ParseFrom(envelope.Body);
                    if (page.Code != "OK") throw new IOException(page.Code);
                    if (offset == 0) file.Initial = page.Initial;
                    file.Records.Add(page.Records);
                    offset += (uint)page.Records.Count;
                    total = page.Total;
                    if (total > 10800 || (page.Records.Count == 0 && offset < total))
                    {
                        throw new InvalidDataException("REPLAY_PAGE");
                    }
                } while (offset < total);

                string path = Path.Combine(Application.persistentDataPath, "frame_last.pb");
                File.WriteAllBytes(path, file.ToByteArray());
                status = "saved " + path;
            }
            catch (Exception error) { if (!destroyed) status = error.Message; }
            finally { saving_replay = false; }
        }

        private void StopWith(string code)
        {
            ready = false;
            connecting = false;
            status = code;
            connection?.Dispose();
        }

        private void OnGUI()
        {
            GUILayout.BeginArea(new Rect(10, 10, 570, 240), GUI.skin.box);
            GUILayout.Label("FrameSync " + status + " battle=" +
                (session != null ? session.BattleId.ToString() : "?") +
                " seat=" + (session != null ? session.SeatId.ToString() : "?") +
                " confirmed=" + confirmed_frame + " predicted=" + predicted_frame +
                " rollback=" + rollback_count);
            GUILayout.Label("WASD移动 J近战 K表现弹丸 L逻辑弹丸；黄色预备反馈可回滚");
            if (GUILayout.Button("重连并恢复本席位")) Recover();
            if (GUILayout.Button("保存结束战斗的正式输入回放")) SaveReplay();
            GUILayout.EndArea();
        }

        private void OnDestroy()
        {
            destroyed = true;
            ready = false;
            connection?.Dispose();
            confirmed?.Dispose();
            predicted?.Dispose();
            foreach (var actor in actors.Values) DestroyActor(actor);
            foreach (var bolt in bolts.Values) DestroyActor(bolt);
            foreach (var material in owned_materials) Destroy(material);
            actors.Clear(); bolts.Clear(); owned_materials.Clear();
        }
    }
}
