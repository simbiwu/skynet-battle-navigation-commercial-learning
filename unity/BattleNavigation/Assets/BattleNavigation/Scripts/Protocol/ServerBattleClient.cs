// 职责：请求一次固定场景自动战斗并解析强类型 Server 结果。
// 边界：Unity Client Runtime RPC Adapter；共享 GatewayEnvelopeClient 传输。
// 输入/输出：scenario_id -> RunAutoBattleResponse，包括业务 ResultCode。
// 生命周期：实例独占短连接，调用方负责 Dispose。
// 不负责：不上传 Snapshot、不计算战斗、不更新 Unity 场景。
using System;
using Battle.Navigation.V1;

namespace BattleNavigation.Client
{
    /// <summary>一次性自动战斗 RPC；业务拒绝仍返回可解析响应。</summary>
    public sealed class ServerBattleClient : IDisposable
    {
        private const uint RunAutoBattleCommand = 1002; // 与生成 registry 一致。
        private readonly GatewayEnvelopeClient gateway; // 当前请求独占连接。

        /// <summary>连接指定 Gateway；失败抛异常。</summary>
        /// <param name="host">Gateway 主机名或 IP。</param>
        /// <param name="port">Gateway TCP 端口。</param>
        public ServerBattleClient(string host, int port)
        {
            gateway = new GatewayEnvelopeClient(host, port);
        }

        /// <summary>运行 Server 已发布场景；网络错误抛异常，业务错误读取 Result。</summary>
        /// <param name="scenarioId">本课只允许 1001；不上传单位位置或 HP。</param>
        /// <returns>新解析的完整战斗响应。</returns>
        public RunAutoBattleResponse Run(uint scenarioId)
        {
            var request = new RunAutoBattleRequest { ScenarioId = scenarioId };
            var envelope = gateway.RoundTrip(RunAutoBattleCommand, request);
            return RunAutoBattleResponse.Parser.ParseFrom(envelope.Body);
        }

        /// <summary>关闭当前短连接。</summary>
        public void Dispose() { gateway.Dispose(); }
    }
}
