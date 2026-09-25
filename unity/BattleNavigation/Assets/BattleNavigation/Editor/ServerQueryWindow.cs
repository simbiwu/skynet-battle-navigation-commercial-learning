// 职责：提供人工输入 WorldPosition 并观察 Skynet QueryCell 响应的 Editor 窗口。
// 边界：Unity Editor Debug；不会进入 Player 构建或修改地图资产。
// 输入/输出：Inspector 风格表单 -> 一次响应摘要或异常文字。
// 不负责：不持续轮询、不缓存查询结果、不覆盖 Server 判定。
#if UNITY_EDITOR
using UnityEditor;
using UnityEngine;
using BattleNavigation.Client;

namespace BattleNavigation.Editor
{
    /// <summary>人工输入 WorldPosition 并观察 Skynet QueryCell 响应的 Editor 调试窗口。</summary>
    public sealed class ServerQueryWindow : EditorWindow
    {
        // Skynet Gateway 地址；默认只连接本机。
        private string host = "127.0.0.1";
        // Skynet Gateway TCP 端口。
        private int port = 19001;
        // 待查询地图 ID。
        private uint mapId = 1001; // BMAP Header 和 QueryCell 协议共用的地图 ID。
        // 客户端期望的地图资产版本。
        private uint mapVersion = 1;
        // 查询 WorldPosition X，单位毫米。
        private long xMm;
        // 查询 WorldPosition Y，单位毫米。
        private long yMm;
        // 查询 WorldPosition Z，单位毫米。
        private long zMm;
        // 最近一次响应或异常的可读显示文本。
        private string result = "not queried";

        [MenuItem("Tools/Battle Navigation/Server Query")]
        private static void Open() => GetWindow<ServerQueryWindow>("Server Query");

        private void OnGUI()
        {
            host = EditorGUILayout.TextField("Host", host);
            port = EditorGUILayout.IntField("Port", port);
            mapId = (uint)Mathf.Max(1, EditorGUILayout.IntField("Map Id", (int)mapId));
            mapVersion = (uint)EditorGUILayout.IntField("Map Version", (int)mapVersion);
            xMm = EditorGUILayout.LongField("X mm", xMm);
            yMm = EditorGUILayout.LongField("Y mm", yMm);
            zMm = EditorGUILayout.LongField("Z mm", zMm);
            if (GUILayout.Button("Query Server"))
            {
                try
                {
                    // client 仅服务本次按钮查询，using 保证异常时也关闭连接。
                    using (var client = new ServerQueryClient(host, port))
                    {
                        // response 是与本次 request_id 对应的 QueryCellResponse。
                        var response = client.Query(mapId, mapVersion, xMm, yMm, zMm);
                        result = $"{response.Result}: grid=({response.GridX},{response.GridZ}) " +
                                 $"height={response.CellHeightMm} area={response.Area} " +
                                 $"clearance={response.Clearance} message={response.Message}";
                    }
                }
                catch (System.Exception ex)
                {
                    result = ex.GetType().Name + ": " + ex.Message;
                }
            }
            EditorGUILayout.HelpBox(result, MessageType.Info);
        }
    }
}
#endif