// 职责：按 Sample -> Clearance -> Validate -> Write -> Manifest 编排唯一正式导出入口。
// 边界：Unity Editor Tool；由菜单触发，不进入 Player Runtime。
// 输入/输出：当前 Battle Scene -> BMAP、Manifest 和 Overlay Snapshot。
// 不负责：各阶段算法由对应组件实现，本文件只负责顺序和失败传播。
using System;
using System.IO;
using UnityEditor;
using UnityEngine;

namespace BattleNavigation.Editor
{
    /// <summary>Unity 侧正式 BMAP 生产入口；只编排已经可独立验证的阶段。</summary>
    public static class BattleMapExporter
    {
        // 最近一次成功导出的内存结果；仅供当前 Editor Session 的 Overlay 使用。
        public static BattleMapSnapshot LastSnapshot { get; private set; }

        [MenuItem("Tools/Battle Navigation/Export BMAP")]
        public static void Export()
        {
            try
            {
                // roots 应且只能包含当前 Scene 的唯一地图合同。
                BattleMapRoot[] roots = UnityEngine.Object.FindObjectsByType<BattleMapRoot>(
                    FindObjectsSortMode.None);
                if (roots.Length != 1)
                {
                    throw new InvalidOperationException(
                        "BATTLE_MAP_ROOT_COUNT expected=1 actual=" + roots.Length);
                }

                // snapshot 是本次完整流水线共享的唯一内存数据源。
                BattleMapSnapshot snapshot = BattleMapSampler.Sample(roots[0]);
                BattleMapClearance.Compute(snapshot);
                BattleMapValidator.ValidateSnapshot(roots[0], snapshot);
                // outputDirectory 位于 Unity 工程的 BuildArtifacts，不进入 Assets 导入管线。
                string outputDirectory = Path.GetFullPath(Path.Combine(
                    Application.dataPath,
                    "..",
                    "BuildArtifacts",
                    "Navigation"));
                // bmapPath 是 mapId 决定的正式资产路径。
                string bmapPath = Path.Combine(
                    outputDirectory,
                    string.Format("battle_{0}.bmap", snapshot.mapId));

                BMapWriter.Write(snapshot, bmapPath);
                BMapManifestWriter.Write(snapshot, bmapPath);
                LastSnapshot = snapshot;
                SceneView.RepaintAll();

                Debug.Log(string.Format(
                    "BMAP_EXPORT_OK path={0} map={1} version={2} size={3}x{4}",
                    bmapPath,
                    snapshot.mapId,
                    snapshot.mapVersion,
                    snapshot.width,
                    snapshot.height));
            }
            catch (Exception exception)
            {
                Debug.LogError("BMAP_EXPORT_FAILED " + exception);
                throw;
            }
        }
    }
}
