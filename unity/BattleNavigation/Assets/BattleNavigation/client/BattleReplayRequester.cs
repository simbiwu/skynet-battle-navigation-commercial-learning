// 职责：从独立 Gateway 请求 Battle_1001，并把权威 Event 交给 ReplayPlayer。
// 边界：Unity Client Runtime Adapter；后台线程仅执行 TCP/Protobuf，主线程操作场景。
// 输入/输出：Gateway 地址和 scenario_id -> BattleReplayPlayer.Play(ordered events)。
// 生命周期：Play Mode Start 发起一次请求；完成后关闭短连接。
// 不负责：不提交 Snapshot、不重新计算寻路/伤害、不实现在线增量同步。
using System;
using System.Collections;
using System.Threading.Tasks;
using Battle.Navigation.V1;
using UnityEngine;

namespace BattleNavigation.Client
{
    /// <summary>第二课一次性自动战斗的 Unity 请求入口。</summary>
    public sealed class BattleReplayRequester : MonoBehaviour
    {
        [SerializeField] private string host = "127.0.0.1"; // 独立 Gateway 地址。
        [SerializeField, Min(1)] private int port = 19011; // 双进程 Gateway TCP 端口。
        [SerializeField, Min(1)] private int scenarioId = 1001; // 只选择 Server 已发布场景。
        [SerializeField] private BattleReplayPlayer replayPlayer; // 当前 Scene 的表现播放器。

        /// <summary>在后台做一次阻塞短连接，完成后返回 Unity 主线程开始回放。</summary>
        /// <returns>Unity 协程；失败记录日志并结束，不修改现有 Replay。</returns>
        private IEnumerator Start()
        {
            if (replayPlayer == null)
            {
                Debug.LogError("BattleReplayPlayer is not assigned");
                yield break;
            }
            if (scenarioId < 1)
            {
                Debug.LogError("scenarioId must be positive");
                yield break;
            }
            var selectedScenario = checked((uint)scenarioId);
            var selectedHost = host;
            var selectedPort = port;
            // Task 内不读取 Unity 对象；Socket 和 Proto 结果仅由后台调用拥有。
            var pending = Task.Run(() =>
            {
                using (var client = new ServerBattleClient(selectedHost, selectedPort))
                    return client.Run(selectedScenario);
            });
            while (!pending.IsCompleted) yield return null;
            if (pending.IsCanceled)
            {
                Debug.LogError("RunAutoBattle request was canceled");
                yield break;
            }
            if (pending.IsFaulted)
            {
                Debug.LogException(pending.Exception.GetBaseException());
                yield break;
            }
            var response = pending.Result;
            if (response.Result != RunAutoBattleResponse.Types.ResultCode.Ok)
            {
                Debug.LogError($"RunAutoBattle rejected: {response.Result} {response.Message}");
                yield break;
            }
            try
            {
                replayPlayer.Play(ConvertResult(response));
                Debug.Log("BATTLE_GATEWAY_RESULT_LOADED events=" + response.Events.Count);
            }
            catch (Exception exception)
            {
                Debug.LogException(exception);
            }
        }

        /// <summary>把 Proto Event 按原 seq/logic_ms 顺序复制到 Replay DTO。</summary>
        /// <param name="response">Server 已成功返回的强类型结果；只读借用。</param>
        /// <returns>新分配的 ReplayDocument；字段越界抛 OverflowException。</returns>
        private static ReplayDocument ConvertResult(RunAutoBattleResponse response)
        {
            var events = new ReplayEvent[response.Events.Count];
            for (var i = 0; i < events.Length; ++i)
            {
                var source = response.Events[i];
                var points = new ReplayPosition[source.Points.Count];
                for (var point = 0; point < points.Length; ++point)
                    points[point] = ConvertPosition(source.Points[point]);
                events[i] = new ReplayEvent
                {
                    seq = checked((int)source.Seq),
                    logic_ms = checked((int)source.LogicMs),
                    type = source.Type,
                    unit_id = checked((int)source.UnitId),
                    target_id = checked((int)source.TargetId),
                    attacker_id = checked((int)source.AttackerId),
                    killer_id = checked((int)source.KillerId),
                    damage = checked((int)source.Damage),
                    target_hp = checked((int)source.TargetHp),
                    speed_mm_per_sec = checked((int)source.SpeedMmPerSec),
                    reason = source.Reason,
                    result = source.Result,
                    position = source.Position == null ? null : ConvertPosition(source.Position),
                    points = points,
                };
            }
            return new ReplayDocument
            {
                battle_id = checked((int)response.BattleId),
                battle_version = checked((int)response.BattleVersion),
                map_id = checked((int)response.MapId),
                map_version = checked((int)response.MapVersion),
                seed = response.Seed,
                result = response.BattleResult,
                end_logic_ms = checked((int)response.EndLogicMs),
                events = events,
            };
        }

        /// <summary>复制 Proto 的 sint64 毫米坐标，不缩窄位宽或转换坐标轴。</summary>
        /// <param name="position">Server 权威世界坐标；本函数不保存引用。</param>
        /// <returns>新 ReplayPosition；三轴单位均为毫米。</returns>
        private static ReplayPosition ConvertPosition(WorldPosition position)
        {
            return new ReplayPosition
            {
                x_mm = position.XMm,
                y_mm = position.YMm,
                z_mm = position.ZMm,
            };
        }
    }
}
