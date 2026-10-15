// 状态同步Unity入口：输入、移动预测、权威校正、远端插值、恢复及状态回放。
// 网络线程只产生Proto值；Unity对象只在主线程创建/更新/销毁。
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Threading.Tasks;
using Battle.Transport.V1;
using Battle.Lesson03.StateSync.V1;
using BattleNavigation.Client;
using BattleNavigation.FrameSync;
using Google.Protobuf;
using UnityEngine;
namespace BattleNavigation.StateSync
{
    public sealed class StateBattleController : MonoBehaviour
    {
        public string Host = "127.0.0.1";
        public int Port = 19031;
        public string ReplayPath = "";
        private GatewayConnection connection;
        private StateMovement movement;
        private StateJoinResponse session;
        private readonly StateReplica replica = new StateReplica();
        private readonly SortedDictionary<uint, StateInput> pending = new SortedDictionary<uint, StateInput>();
        private readonly List<StateSnapshot> timeline = new List<StateSnapshot>();
        private readonly Dictionary<uint, GameObject> actors = new Dictionary<uint, GameObject>();
        private readonly Dictionary<uint, GameObject> bolts = new Dictionary<uint, GameObject>();
        private readonly List<Material> materials = new List<Material>();
        private sealed class VisualShot
        {
            public GameObject Object;
            public Vector3 Start, End;
            public float Born;
        }
        private readonly List<VisualShot> visualShots = new List<VisualShot>();
        private StateReplay replay;
        private int replayIndex;
        private float replayClock;
        private uint nextInput, nextCast;
        private double accumulator;
        private float lastStateTime;
        private bool connecting, ready, destroyed, casting, resyncing, downloading;
        private string status = "initializing";
        private uint lastTick;
        private float correctionMm;
        private float previewUntil; // 150ms可撤销施法预备动作，不参与命中判定。
        private FrameLuaProfiles profiles;
        private string MapPath => Path.Combine(Application.streamingAssetsPath, "navigation/battle_1001.bmap");

        private async void Start()
        {
            try
            {
                if (!string.IsNullOrWhiteSpace(ReplayPath))
                {
                    if (new FileInfo(ReplayPath).Length > 8 * 1024 * 1024) throw new InvalidDataException("REPLAY_SIZE");
                    replay = StateReplay.Parser.ParseFrom(File.ReadAllBytes(ReplayPath));
                    if (replay.FormatVersion != 1 || replay.Initial == null || replay.Records.Count > 10800)
                        throw new InvalidDataException("REPLAY_FORMAT");
                    ValidateIdentity(replay.Initial);
                    session = replay.Initial;
                    ApplySnapshot(session.Snapshot, true);
                    status = "offline state replay";
                    return;
                }
                profiles = FrameLuaProfileLoader.LoadMovementData();
                await Connect(false);
            }
            catch (Exception e) { Stop(e.Message); }
        }
        private void ValidateIdentity(StateJoinResponse value)
        {
            if (value.SimulationVersion != 1 || value.TickRateHz != 60 || value.SnapshotRateHz != 20 ||
                value.MapId != 1001 || value.InputWindow != 24) throw new InvalidDataException("STATE_CONTRACT");
            using (var sha = SHA256.Create())
            {
                string hash = BitConverter.ToString(sha.ComputeHash(File.ReadAllBytes(MapPath))).Replace("-", "").ToLowerInvariant();
                if (hash != value.MapHash) throw new InvalidDataException("MAP_HASH");
            }
            string expected = File.ReadAllText(Path.Combine(Application.streamingAssetsPath, "state_sync_config.sha256")).Trim();
            if (expected != value.ConfigHash) throw new InvalidDataException("CONFIG_HASH");
        }
        private async Task Connect(bool recover)
        {
            if (connecting || destroyed) return;
            connecting = true;
            ready = false;
            try
            {
                connection?.Dispose();
                var next = await GatewayConnection.Connect(Host, Port, (uint)CommandId.StatePush);
                if (destroyed) { next.Dispose(); return; }
                connection = next;
                StateJoinResponse value;
                if (recover)
                {
                    if (session == null) throw new IOException("NO_SESSION");
                    var envelope = await connection.Request((uint)CommandId.StateRecover,
                        new StateRecoverRequest { BattleId = session.BattleId, ResumeToken = session.ResumeToken });
                    value = StateRecoverResponse.Parser.ParseFrom(envelope.Body).State;
                }
                else
                {
                    var envelope = await connection.Request((uint)CommandId.StateJoin,
                        new StateJoinRequest { ScenarioId = 1001, SimulationVersion = 1 });
                    value = StateJoinResponse.Parser.ParseFrom(envelope.Body);
                }
                if (destroyed) return;
                if (value == null || value.Code != "OK") throw new IOException(value?.Code ?? "EMPTY_JOIN");
                ValidateIdentity(value);
                var profile = profiles.Navigation.Single(v => v.UnitId == value.NavigationProfileId);
                if (profiles.Units.Single(v => v.UnitId == value.NavigationProfileId).MoveSpeedMmPerSec != value.SpeedMmPerSec)
                    throw new InvalidDataException("SPEED_CONFIG");
                movement?.Dispose();
                movement = new StateMovement(MapPath, profile);
                session = value;
                replica.Clear();
                pending.Clear();
                timeline.Clear();
                nextInput = value.Snapshot.ConsumedInputSeq;
                nextCast = value.NextCastSeq - 1;
                // 施法序号在同一Battle内连续，重连保留本地已提交序号。
                ApplySnapshot(value.Snapshot, true);
                ready = true;
                accumulator = 0;
                status = "connected";
            }
            finally { connecting = false; }
        }
        private void ApplySnapshot(StateSnapshot incoming, bool reset)
        {
            var state = replica.Install(incoming);
            if (state == null) return;
            lastTick = state.ServerTick;
            lastStateTime = Time.unscaledTime;
            timeline.Add(state);
            if (timeline.Count > 64) timeline.RemoveAt(0);
            var player = state.Units.Single(v => v.InstanceId == 1001);
            if (movement != null)
            {
                var before = movement.Position;
                foreach (uint id in pending.Keys.Where(v => v <= state.ConsumedInputSeq).ToArray()) pending.Remove(id);
                movement.Reset(player.Position);
                foreach (var input in pending.Values) movement.Step(input, session.SpeedMmPerSec);
                correctionMm = before == null ? 0 : Vector3.Distance(World(before), World(movement.Position)) * 1000;
            }
            // 全量恢复覆盖历史效果；常态先消费events，再覆盖该快照的事件水位。
            if (reset) replica.CoverEvents(state.EventWatermark);
            if (reset) Render(state.ServerTick, true);
            if (state.Winner != 0) { ready = false; status = "battle ended: " + state.Winner; }
        }
        private async Task Resync()
        {
            if (resyncing || destroyed || session == null) return;
            resyncing = true;
            try
            {
                var envelope = await connection.Request((uint)CommandId.StateResync,
                    new StateResyncRequest { BattleId = session.BattleId, Generation = session.Generation });
                var result = StateResyncResponse.Parser.ParseFrom(envelope.Body);
                if (destroyed) return;
                if (result.Code != "OK") throw new IOException(result.Code);
                replica.CoverEvents(result.Snapshot.EventWatermark);
                ApplySnapshot(result.Snapshot, false);
            }
            catch (Exception e) { Stop(e.Message); }
            finally { resyncing = false; }
        }
        private async Task Cast(uint skill)
        {
            if (casting || !ready) return;
            var player = replica.Current.Units.Single(v => v.InstanceId == 1001);
            var target = replica.Current.Units.Where(v => v.Camp != player.Camp && v.Hp > 0)
                .OrderBy(v => (World(v.Position) - World(player.Position)).sqrMagnitude).ThenBy(v => v.InstanceId).FirstOrDefault();
            if (target == null) return;
            casting = true;
            uint seq = ++nextCast;
            previewUntil = Time.unscaledTime + 0.15f;
            status = "cast preview " + skill; // 可撤销本地反馈；不修改HP。
            try
            {
                var envelope = await connection.Request((uint)CommandId.StateCast, new StateCastRequest
                {
                    BattleId = session.BattleId, Generation = session.Generation,
                    CastSeq = seq, SkillId = skill, TargetId = target.InstanceId,
                });
                var result = StateCastResponse.Parser.ParseFrom(envelope.Body);
                if (destroyed) return;
                if (result.CastSeq != seq) throw new InvalidDataException("CAST_IDENTITY");
                status = "cast " + result.Code;
                if (result.Code != "QUEUED" && result.Code != "OK") previewUntil = 0;
                // QUEUED只是接纳；正式执行结果来自带cast_seq的Event。
            }
            catch (Exception e) { Stop(e.Message); }
            finally { casting = false; }
        }
        private void Update()
        {
            try
            {
                AdvanceVisualShots();
                if (replay != null) { AdvanceReplay(); return; }
                if (connection == null || connecting) return;
                if (connection.Fault != null) { Stop(connection.Fault); return; }
                Envelope envelope;
                int received = 0;
                while (received++ < 64 && connection.TryPush(out envelope))
                {
                    if (envelope.Command != (uint)CommandId.StatePush) throw new InvalidDataException("STATE_PUSH_COMMAND");
                    var push = StatePushResponse.Parser.ParseFrom(envelope.Body);
                    if (push.BattleId != session.BattleId || push.Generation != session.Generation) continue;
                    if (push.Code != "OK" && push.Code != "EVENT_GAP") throw new IOException(push.Code);
                    if (push.Code == "EVENT_GAP")
                    {
                        if (push.Snapshot == null || push.Snapshot.BaseSeq != 0) throw new InvalidDataException("GAP_FULL_STATE");
                        replica.CoverEvents(push.Snapshot.EventWatermark);
                    }
                    else foreach (var e in push.Events)
                    {
                        if (replica.Consume(e)) PresentEvent(e);
                    }
                    ApplySnapshot(push.Snapshot, false);
                }
                if (ready)
                {
                    if (Time.unscaledTime - lastStateTime > 0.5f) { Stop("STATE_STALL: press Recover"); return; }
                    if (Input.GetKeyDown(KeyCode.J)) _ = Cast(1);
                    if (Input.GetKeyDown(KeyCode.K)) _ = Cast(2);
                    if (Input.GetKeyDown(KeyCode.L)) _ = Cast(3);
                    accumulator += Time.unscaledDeltaTime;
                    int steps = 0;
                    while (accumulator >= 1.0 / 60.0 && steps++ < 4 && pending.Count < 24)
                    {
                        accumulator -= 1.0 / 60.0;
                        var input = new StateInput
                        {
                            InputSeq = ++nextInput,
                            X = (Input.GetKey(KeyCode.D) ? 1 : 0) - (Input.GetKey(KeyCode.A) ? 1 : 0),
                            Z = (Input.GetKey(KeyCode.W) ? 1 : 0) - (Input.GetKey(KeyCode.S) ? 1 : 0),
                        };
                        pending.Add(input.InputSeq, input);
                        movement.Step(input, session.SpeedMmPerSec);
                        var req = new StateInputRequest
                        {
                            BattleId = session.BattleId, Generation = session.Generation,
                            AckSnapshotSeq = replica.Current.SnapshotSeq, AckEventSeq = replica.EventSequence,
                        };
                        req.Inputs.Add(input);
                        connection.Send((uint)CommandId.StateInput, req);
                    }
                    if (steps >= 4 || pending.Count == 24) accumulator = Math.Min(accumulator, 1.0 / 60.0);
                }
                Render(lastTick + (Time.unscaledTime - lastStateTime) * 60 - 6, false);
            }
            catch (InvalidDataException e)
            {
                if (e.Message == "BASE_GAP" || e.Message == "EVENT_GAP") _ = Resync();
                else Stop(e.Message);
            }
            catch (Exception e) { Stop(e.Message); }
        }
        private void AdvanceReplay()
        {
            replayClock += Time.unscaledDeltaTime * 60;
            while (replayIndex < replay.Records.Count)
            {
                var record = replay.Records[replayIndex];
                uint tick = record.Snapshot?.ServerTick ?? (record.Events.Count > 0 ? record.Events[0].ServerTick : 0);
                if (tick > replayClock) break;
                foreach (var e in record.Events) if (replica.Consume(e)) PresentEvent(e);
                ApplySnapshot(record.Snapshot, false);
                replayIndex++;
            }
            Render(replayClock - 6, false);
        }
        private static Vector3 World(WorldPosition p) => new Vector3(p.XMm / 1000f, p.YMm / 1000f, p.ZMm / 1000f);
        private GameObject Actor(uint id, bool bolt)
        {
            var objects = bolt ? bolts : actors;
            GameObject result;
            if (objects.TryGetValue(id, out result)) return result;
            result = GameObject.CreatePrimitive(bolt ? PrimitiveType.Sphere : PrimitiveType.Capsule);
            result.name = (bolt ? "StateBolt_" : "StateUnit_") + id;
            result.transform.localScale = bolt ? Vector3.one * 0.15f : new Vector3(0.4f, 0.5f, 0.4f);
            Destroy(result.GetComponent<Collider>());
            var material = new Material(Shader.Find("Standard"));
            material.color = bolt ? Color.yellow : id == 1001 ? Color.cyan : Color.red;
            materials.Add(material);
            result.GetComponent<Renderer>().sharedMaterial = material;
            objects.Add(id, result);
            return result;
        }
        private void Render(float tick, bool snap)
        {
            if (replica.Current == null || timeline.Count == 0) return;
            StateSnapshot left = timeline[0], right = timeline[timeline.Count - 1];
            foreach (var item in timeline)
            {
                if (item.ServerTick <= tick) left = item;
                if (item.ServerTick >= tick) { right = item; break; }
            }
            float alpha = right.ServerTick == left.ServerTick ? 1 : Mathf.Clamp01((tick - left.ServerTick) / (right.ServerTick - left.ServerTick));
            foreach (var unit in right.Units)
            {
                var actor = Actor(unit.InstanceId, false);
                var previous = left.Units.FirstOrDefault(v => v.InstanceId == unit.InstanceId);
                Vector3 pos = World(unit.Position);
                if (previous != null && unit.Hp > 0 && previous.Hp > 0 && Vector3.Distance(World(previous.Position), pos) < 2)
                    pos = Vector3.Lerp(World(previous.Position), pos, alpha);
                if (tick > right.ServerTick && unit.Hp > 0 && timeline.Count >= 2)
                {
                    var older = timeline[timeline.Count - 2];
                    var oldUnit = older.Units.FirstOrDefault(v => v.InstanceId == unit.InstanceId);
                    uint interval = right.ServerTick - older.ServerTick;
                    if (oldUnit != null && oldUnit.Hp > 0 && interval > 0 &&
                        Vector3.Distance(World(oldUnit.Position), World(unit.Position)) < 2)
                        pos = World(unit.Position) + (World(unit.Position) - World(oldUnit.Position)) *
                            (Mathf.Min(tick - right.ServerTick, 3) / interval);
                }
                if (replay == null && unit.InstanceId == 1001 && movement != null)
                    pos = World(movement.Position);
                pos.y += 0.5f;
                actor.transform.position = snap || correctionMm > 1000 ? pos : Vector3.Lerp(actor.transform.position, pos, 1 - Mathf.Exp(-30 * Time.unscaledDeltaTime));
                if (unit.InstanceId == 1001)
                    actor.transform.localRotation = Time.unscaledTime < previewUntil ? Quaternion.Euler(0, 0, -15) : Quaternion.identity;
                actor.SetActive(unit.Hp > 0);
            }
            foreach (uint id in actors.Keys.Where(id => !right.Units.Any(v => v.InstanceId == id)).ToArray())
            { Destroy(actors[id]); actors.Remove(id); }
            foreach (var bolt in right.Bolts)
            {
                var obj = Actor(bolt.InstanceId, true);
                var previous = left.Bolts.FirstOrDefault(v => v.InstanceId == bolt.InstanceId);
                obj.transform.position = previous == null ? World(bolt.Position) : Vector3.Lerp(World(previous.Position), World(bolt.Position), alpha);
            }
            foreach (uint id in bolts.Keys.Where(id => !right.Bolts.Any(v => v.InstanceId == id)).ToArray())
            { Destroy(bolts[id]); bolts.Remove(id); }
        }
        private async Task DownloadReplay()
        {
            if (downloading || session == null || connection == null) return;
            downloading = true;
            try
            {
                var value = new StateReplay { FormatVersion = 1 };
                uint offset = 0;
                while (true)
                {
                    var envelope = await connection.Request((uint)CommandId.StateReplay, new StateReplayRequest
                    { BattleId = session.BattleId, ResumeToken = session.ResumeToken, Offset = offset });
                    var page = StateReplayResponse.Parser.ParseFrom(envelope.Body);
                    if (page.Code != "OK") throw new IOException(page.Code);
                    if (offset == 0) value.Initial = page.Initial;
                    value.Records.Add(page.Records);
                    offset += (uint)page.Records.Count;
                    if (offset >= page.Total) break;
                    if (page.Records.Count == 0 || offset > 10800) throw new InvalidDataException("REPLAY_PAGE");
                }
                string path = Path.Combine(Application.persistentDataPath, "state_battle.replay");
                byte[] bytes = value.ToByteArray();
                if (bytes.Length > 8 * 1024 * 1024) throw new InvalidDataException("REPLAY_SIZE");
                File.WriteAllBytes(path, bytes);
                status = "Replay saved: " + path;
            }
            catch (Exception e) { status = e.Message; }
            finally { downloading = false; }
        }
        private void PresentEvent(StateEvent value)
        {
            status = value.Kind + " " + value.Code;
            // 表现弹丸只展示已接受的施法；不写HP、不触发命中或服务器回包。
            if (value.Kind != "CAST" || value.Code != "OK" || value.SkillId != 2 || replica.Current == null) return;
            var source = replica.Current.Units.FirstOrDefault(v => v.InstanceId == value.ActorId);
            var target = replica.Current.Units.FirstOrDefault(v => v.InstanceId == value.TargetId);
            if (source == null || target == null || visualShots.Count >= 64) return;
            var obj = GameObject.CreatePrimitive(PrimitiveType.Sphere);
            Destroy(obj.GetComponent<Collider>());
            obj.name = "StateVisualShot";
            obj.transform.localScale = Vector3.one * 0.12f;
            visualShots.Add(new VisualShot
            {
                Object = obj, Start = World(source.Position) + Vector3.up * 0.5f,
                End = World(target.Position) + Vector3.up * 0.5f, Born = Time.unscaledTime,
            });
        }
        private void AdvanceVisualShots()
        {
            for (int i = visualShots.Count - 1; i >= 0; --i)
            {
                var shot = visualShots[i];
                float fraction = (Time.unscaledTime - shot.Born) / 0.3f;
                if (fraction >= 1) { Destroy(shot.Object); visualShots.RemoveAt(i); }
                else shot.Object.transform.position = Vector3.Lerp(shot.Start, shot.End, fraction);
            }
        }

        private void OnGUI()
        {
            GUI.Label(new Rect(10, 10, 1000, 30), "State Sync 60Hz | WASD / J K L | " + status);
            GUI.Label(new Rect(10, 40, 900, 30), "tick=" + lastTick + " pending=" + pending.Count + " correction=" + correctionMm.ToString("F1") + "mm");
            if (replica.Current != null)
                GUI.Label(new Rect(10, 70, 1000, 30), string.Join(" | ", replica.Current.Units.Select(v => v.InstanceId + " HP=" + v.Hp)));
            if (session != null && !connecting && replay == null && GUI.Button(new Rect(10, 105, 140, 30), "Recover")) _ = Recover();
            if (session != null && replay == null && GUI.Button(new Rect(160, 105, 150, 30), "Save Replay")) _ = DownloadReplay();
        }
        private async Task Recover()
        {
            try { await Connect(true); }
            catch (Exception e) { Stop(e.Message); }
        }
        private void Stop(string code) { ready = false; status = code; }
        private void OnDestroy()
        {
            destroyed = true;
            connection?.Dispose();
            movement?.Dispose();
            foreach (var shot in visualShots) Destroy(shot.Object);
            foreach (var value in actors.Values) Destroy(value);
            foreach (var value in bolts.Values) Destroy(value);
            foreach (var value in materials) Destroy(value);
        }
    }
}
