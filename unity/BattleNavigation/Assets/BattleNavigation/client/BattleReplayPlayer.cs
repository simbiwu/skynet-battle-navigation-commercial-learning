// 职责：按 Server 生成的 logic_ms/seq 回放第二课自动战斗事件。
// 边界：Unity Client Runtime Debug Presentation；Server Event 是权威输入。
// 输入/输出：离线 JSON 或在线 RunAutoBattle 的有序 Event -> 几何体移动、攻击日志和死亡显示。
// 生命周期：离线模式在 Start 解析；在线模式由 Play 接收新 Replay；Update 只推进表现时间。
// 不负责：不重新寻路、不计算命中/伤害、不把客户端位置回写 Server。
using System;
using System.Collections.Generic;
using UnityEngine;

namespace BattleNavigation.Client
{
    /// <summary>Replay 中一个 Server 世界坐标点；三个分量单位都是毫米。</summary>
    [Serializable]
    public sealed class ReplayPosition
    {
        public long x_mm; // Server 世界 X，int64 毫米。
        public long y_mm; // Server 权威地表 Y，int64 毫米。
        public long z_mm; // Server 世界 Z，int64 毫米。
    }

    /// <summary>一个按 seq/logic_ms 排序的 Server 逻辑事件；字段名与 JSON 合同一致。</summary>
    [Serializable]
    public sealed class ReplayEvent
    {
        public int seq;                         // Battle 内从 1 开始严格递增。
        public int logic_ms;                    // fixed-tick 逻辑时间，毫秒。
        public string type;                     // 稳定事件类型名。
        public int unit_id;                     // 事件主体；0 表示该类型不使用。
        public int target_id;                   // 目标单位；0 表示无。
        public int attacker_id;                 // 攻击者；0 表示无。
        public int killer_id;                   // 击杀者；0 表示无。
        public int damage;                      // 本次权威伤害；非攻击事件为 0。
        public int target_hp;                   // 伤害结算后的权威 HP。
        public int speed_mm_per_sec;             // MOVE_PATH 表现速度，毫米/秒。
        public string reason;                   // 停止/失败原因；无则空串。
        public string result;                   // BATTLE_END 结果；无则空串。
        public ReplayPosition position;         // 权威事件位置；可为 null。
        public ReplayPosition[] points;         // MOVE_PATH 世界点；其他事件为空数组。
    }

    /// <summary>一次完整离线 Replay 的身份、结束状态和有序事件数组。</summary>
    [Serializable]
    public sealed class ReplayDocument
    {
        public int battle_id;          // 本次 Battle 身份。
        public int battle_version;     // Battle 规则版本。
        public int map_id;             // BMAP 地图 ID。
        public int map_version;        // BMAP 地图版本。
        public long seed;              // 本次确定性输入 seed。
        public string result;          // FINISHED 或 TIMEOUT。
        public int end_logic_ms;        // 模拟结束逻辑时间，毫秒。
        public ReplayEvent[] events;    // 按 seq 保存的 Server 事件。
    }

    /// <summary>
    /// 第二课 Replay 播放器。离线与在线结果都只消费 Server Event，不拥有权威战斗规则。
    /// </summary>
    public sealed class BattleReplayPlayer : MonoBehaviour
    {
        // Server 输出并复制到 Unity Assets 的 JSON Replay；只读。
        [SerializeField] private TextAsset replayJson;
        // 播放倍速；1=按 logic_ms 实时播放，2=两倍速。
        [SerializeField, Min(0.1f)] private float playbackSpeed = 1f;

        private sealed class ActiveMove
        {
            public ReplayPosition[] points = Array.Empty<ReplayPosition>(); // Server Path 世界点，毫米。
            public int nextPoint = 1;       // 下一个目标点数组下标。
            public float speedMeters = 0f;  // 由 Server mm/s 转换，纯表现参数。
        }

        // unit_id -> Client Runtime 显示对象；由本组件创建和销毁。
        private readonly Dictionary<int, GameObject> units =
            new Dictionary<int, GameObject>();
        // unit_id -> 当前表现 Path；新 MOVE_PATH 会覆盖旧值。
        private readonly Dictionary<int, ActiveMove> moves =
            new Dictionary<int, ActiveMove>();
        private ReplayDocument replay; // 当前只读 Replay 文档。
        private int nextEvent;          // 下一个尚未消费的 events 数组下标。
        private float logicMs;          // 客户端表现时间，毫秒；不回写 Server。

        /// <summary>有离线 TextAsset 时自动加载；联网模式留空等待 Play。</summary>
        private void Start()
        {
            if (replayJson != null)
                Play(JsonUtility.FromJson<ReplayDocument>(replayJson.text));
        }

        /// <summary>验证并开始一份完整 Server Event Log 的纯表现回放。</summary>
        /// <param name="document">调用方拥有的 ReplayDocument；调用后不得修改事件数组。</param>
        /// <exception cref="InvalidOperationException">文档为空、时间或 seq 顺序非法。</exception>
        public void Play(ReplayDocument document)
        {
            if (document == null || document.events == null ||
                document.end_logic_ms < 0 || document.events.Length == 0 ||
                document.events[0] == null || document.events[0].seq != 1)
                throw new InvalidOperationException("Replay document is invalid");
            for (var i = 0; i < document.events.Length; ++i)
            {
                if (document.events[i] == null ||
                    document.events[i].logic_ms < 0 ||
                    document.events[i].logic_ms > document.end_logic_ms ||
                    (i > 0 &&
                     (document.events[i].seq != document.events[i - 1].seq + 1 ||
                      document.events[i].logic_ms < document.events[i - 1].logic_ms)))
                    throw new InvalidOperationException("Replay event order is invalid");
            }

            // 验证通过后才清理上一场显示对象，避免无效输入破坏正在播放的回放。
            foreach (var unit in units.Values) Destroy(unit);
            units.Clear();
            moves.Clear();
            replay = document;
            nextEvent = 0;
            logicMs = 0f;
        }

        /// <summary>
        /// 把本帧切成事件前后的小段：先播放旧 Path 到事件时刻，再应用权威事件。
        /// 输入是 Unity 帧时长；只修改显示状态，不重新计算 Server 的移动或伤害。
        /// </summary>
        private void Update()
        {
            if (replay == null) return;
            var frameEndMs = Mathf.Min(
                logicMs + Time.deltaTime * 1000f * playbackSpeed,
                replay.end_logic_ms);
            while (nextEvent < replay.events.Length &&
                   replay.events[nextEvent].logic_ms <= frameEndMs)
            {
                // 同一帧可能跨过多个事件；旧 Path 只播放到下一事件的逻辑时间。
                var eventMs = replay.events[nextEvent].logic_ms;
                AdvanceMoves(Mathf.Max(0f, eventMs - logicMs) / 1000f);
                logicMs = eventMs;
                Apply(replay.events[nextEvent]);
                ++nextEvent;
            }
            // 新 MOVE_PATH 从自己的事件时刻以后才开始移动；BATTLE_END 后不再推进。
            AdvanceMoves(Mathf.Max(0f, frameEndMs - logicMs) / 1000f);
            logicMs = frameEndMs;
        }

        /// <summary>应用一个权威事件；只改变显示对象和本地表现状态。</summary>
        private void Apply(ReplayEvent value)
        {
            switch (value.type)
            {
                case "BATTLE_BEGIN":
                    Debug.Log($"Battle {replay.battle_id} begin seed={replay.seed}");
                    break;
                case "UNIT_SPAWN":
                    if (value.position != null)
                        GetOrCreate(value.unit_id, value.position);
                    break;
                case "MOVE_PATH":
                    BeginMove(value);
                    break;
                case "MOVE_STOPPED":
                    StopMove(value);
                    break;
                case "ATTACK":
                    Debug.Log($"ATTACK {value.attacker_id}->{value.target_id} " +
                              $"damage={value.damage} hp={value.target_hp}");
                    break;
                case "UNIT_DEAD":
                    Kill(value.unit_id);
                    break;
                case "TARGET_CHANGED":
                    break; // 第二课只保留调试语义，不要求视觉效果。
                case "BATTLE_END":
                    moves.Clear(); // 结束事件终止所有纯表现插值，不能越过权威结束时间继续移动。
                    Debug.Log($"Battle end result={value.result}");
                    break;
                default:
                    Debug.LogError("Unknown replay event: " + value.type);
                    break;
            }
        }

        /// <summary>开始/覆盖某单位当前移动表现；新 MOVE_PATH 权威替换旧表现路径。</summary>
        private void BeginMove(ReplayEvent value)
        {
            if (value.points == null || value.points.Length == 0) return;
            if (!units.TryGetValue(value.unit_id, out var unit))
            {
                Debug.LogError("MOVE_PATH for unknown unit: " + value.unit_id);
                return;
            }
            unit.transform.position = ToUnity(value.points[0]);
            moves[value.unit_id] = new ActiveMove
            {
                points = value.points,
                nextPoint = value.points.Length > 1 ? 1 : value.points.Length,
                speedMeters = value.speed_mm_per_sec / 1000f,
            };
        }

        /// <summary>按 MOVE_STOPPED 的 Server 最终位置停止本地插值。</summary>
        private void StopMove(ReplayEvent value)
        {
            moves.Remove(value.unit_id);
            if (value.position != null)
            {
                if (units.TryGetValue(value.unit_id, out var unit))
                    unit.transform.position = ToUnity(value.position);
                else
                    Debug.LogError("MOVE_STOPPED for unknown unit: " + value.unit_id);
            }
        }

        /// <summary>仅做路径折线插值；不会使用 NavMeshAgent 重新求路。</summary>
        private void AdvanceMoves(float deltaSeconds)
        {
            foreach (var pair in moves)
            {
                if (!units.TryGetValue(pair.Key, out var unit)) continue;
                var move = pair.Value;
                var remaining = move.speedMeters * deltaSeconds;
                while (remaining > 0f && move.nextPoint < move.points.Length)
                {
                    var target = ToUnity(move.points[move.nextPoint]);
                    var distance = Vector3.Distance(unit.transform.position, target);
                    if (distance <= remaining || distance <= 0.0001f)
                    {
                        unit.transform.position = target;
                        remaining -= distance;
                        ++move.nextPoint;
                    }
                    else
                    {
                        unit.transform.position = Vector3.MoveTowards(
                            unit.transform.position, target, remaining);
                        remaining = 0f;
                    }
                }
            }
        }

        /// <summary>返回现有显示对象；不存在时创建一个 Capsule 作为课程观察对象。</summary>
        private GameObject GetOrCreate(int unitId, ReplayPosition position)
        {
            if (units.TryGetValue(unitId, out var value)) return value;
            value = GameObject.CreatePrimitive(PrimitiveType.Capsule);
            value.name = "ReplayUnit_" + unitId;
            value.transform.position = ToUnity(position);
            units.Add(unitId, value);
            return value;
        }

        /// <summary>把 Server 整数毫米世界坐标转换为 Unity 世界米；轴保持 X/Y/Z 不变。</summary>
        private static Vector3 ToUnity(ReplayPosition p)
        {
            return new Vector3(p.x_mm / 1000f, p.y_mm / 1000f, p.z_mm / 1000f);
        }

        /// <summary>按 Server UNIT_DEAD 事件销毁显示对象；不在客户端重新判定 HP。</summary>
        private void Kill(int unitId)
        {
            moves.Remove(unitId);
            if (units.TryGetValue(unitId, out var value))
            {
                Destroy(value);
                units.Remove(unitId);
            }
            else
            {
                Debug.LogError("UNIT_DEAD for unknown unit: " + unitId);
            }
        }
    }
}
