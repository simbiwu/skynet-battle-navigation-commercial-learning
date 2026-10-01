// 职责：在.NET宿主运行真实Unity TCP接入源码，验证框架握手后可查询。
// 边界：Integration Tool；输入专用测试端口，不启动Server，不代表IL2CPP发布验证。
// 生命周期：每次运行建立并Dispose一个连接；输出仅结果，不输出密钥。
// 不负责：不模拟加密、不替代H5浏览器或Unity平台验证。
using System;
using Battle.Navigation.V1;
using BattleNavigation.Client;

internal static class GatewayHandshakeInterop
{
    /// <summary>调用真实客户端构造与RoundTrip；错误传播为非零退出。</summary>
    private static void Main(string[] args)
    {
        int port = int.Parse(args[0]);
        using (var client = new GatewayEnvelopeClient("127.0.0.1", port))
        {
            var response = client.RoundTrip(1001, new QueryCellRequest { MapId = 1001, MapVersion = 1 });
            if (response.Command != 1001 || response.RequestId == 0) throw new Exception("RESPONSE_MISMATCH");
        }
        Console.WriteLine("UNITY_CSHARP_SKYNET_HANDSHAKE_OK");
    }
}
