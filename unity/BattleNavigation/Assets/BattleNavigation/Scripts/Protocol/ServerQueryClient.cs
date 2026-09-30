// 职责：把一次地图静态查询编码为 QueryCell，并解析强类型响应。
// 边界：Unity Client Runtime/Editor Debug；传输由 GatewayEnvelopeClient 独占。
// 输入/输出：Server 地址、地图身份和 WorldPosition(mm) -> QueryCellResponse。
// 生命周期：实例拥有 GatewayEnvelopeClient，由 Dispose 关闭。
// 不负责：不做连接池、自动重试、高频查询或战斗模拟。
using System;
using Battle.Navigation.V1;

namespace BattleNavigation.Client
{
    /// <summary>第一课 QueryCell 调试调用面；第二课复用传输而不改变查询合同。</summary>
    public sealed class ServerQueryClient : IDisposable
    {
        private const uint QueryCellCommand = 1001; // 与生成 registry 一致。
        private readonly GatewayEnvelopeClient gateway; // 本实例独占短连接。

        /// <summary>连接指定 Gateway；连接失败抛异常。</summary>
        /// <param name="host">Skynet Gateway 主机名或 IP。</param>
        /// <param name="port">Skynet Gateway TCP 端口。</param>
        public ServerQueryClient(string host, int port)
        {
            gateway = new GatewayEnvelopeClient(host, port);
        }

        /// <summary>同步查询一个毫米世界点；业务错误保留在 Result。</summary>
        /// <param name="mapId">已发布地图 ID。</param>
        /// <param name="mapVersion">期望查询的地图资产版本。</param>
        /// <param name="xMm">地图内 WorldPosition X，单位毫米，业务接口为 int64。</param>
        /// <param name="yMm">WorldPosition Y，单位毫米，业务接口为 int64。</param>
        /// <param name="zMm">地图内 WorldPosition Z，单位毫米，业务接口为 int64。</param>
        /// <returns>本次请求新解析的 QueryCellResponse；协议/连接失败抛异常。</returns>
        public QueryCellResponse Query(uint mapId, uint mapVersion, long xMm, long yMm, long zMm)
        {
            // request 是业务 QueryCell 请求，位置始终使用毫米制 WorldPosition。
            var request = new QueryCellRequest
            {
                MapId = mapId,
                MapVersion = mapVersion,
                Position = new WorldPosition { XMm = xMm, YMm = yMm, ZMm = zMm },
            };
            var envelope = gateway.RoundTrip(QueryCellCommand, request);
            return QueryCellResponse.Parser.ParseFrom(envelope.Body);
        }

        /// <summary>关闭当前短连接。</summary>
        public void Dispose()
        {
            gateway.Dispose();
        }
    }
}
