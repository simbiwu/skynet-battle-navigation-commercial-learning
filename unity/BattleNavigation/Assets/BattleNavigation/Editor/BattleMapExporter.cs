// 职责：按 Sample -> Clearance -> Validate -> Write -> Manifest 编排唯一正式导出入口。
// 边界：Unity Editor Tool；由菜单触发，不进入 Player Runtime。
// 输入/输出：当前 Battle Scene -> 仓库 shared/navigation 下的 BMAP、Manifest 和 Overlay Snapshot。
// 生命周期：开发者在 Editor 菜单显式触发；输出只是待验证、待提交的发布候选资产。
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

        /// <summary>
        /// 采样并验证当前场景，把地图资产写入仓库共享发布目录。
        /// </summary>
        /// <exception cref="InvalidOperationException">
        /// 当前场景没有唯一 BattleMapRoot，或 Unity 工程不位于 Git 仓库中时抛出。
        /// </exception>
        /// <remarks>
        /// 执行磁盘 I/O 并更新 Editor Session 内的 Overlay Snapshot；不提交 Git，也不通知运行中的 Server。
        /// </remarks>
        [MenuItem("Tools/战斗导航/03 导出当前场景 BMAP", false, 103)]
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
                // shared/ 是跨机器发布合同。Bake 只更新本地候选文件，提交并拉取后 Server 才会消费。
                string repositoryRoot = ResolveRepositoryRoot();
                string outputDirectory = Path.Combine(
                    repositoryRoot,
                    "shared",
                    "navigation",
                    string.Format("battle_{0}", snapshot.mapId));
                // bmapPath 的目录和文件名都由 mapId 决定，避免多张地图互相覆盖。
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

        /// <summary>
        /// 从 Unity 工程根目录向上定位包含 <c>.git</c> 的仓库根目录。
        /// </summary>
        /// <returns>规范化绝对路径；调用方只在其下写入 <c>shared/</c>。</returns>
        /// <exception cref="InvalidOperationException">
        /// 当前 Unity 工程不在 Git 仓库内，无法确定共享发布边界时抛出。
        /// </exception>
        /// <remarks>只访问文件系统，不修改目录，不分配长期资源。</remarks>
        private static string ResolveRepositoryRoot()
        {
            DirectoryInfo directory = new DirectoryInfo(Path.GetFullPath(Path.Combine(
                Application.dataPath,
                "..")));
            while (directory != null)
            {
                // 普通 clone 的 .git 是目录；Git worktree 的 .git 是指向主仓库的文本文件。
                string marker = Path.Combine(directory.FullName, ".git");
                if (Directory.Exists(marker) || File.Exists(marker))
                {
                    return directory.FullName;
                }

                directory = directory.Parent;
            }

            throw new InvalidOperationException(
                "REPOSITORY_ROOT_NOT_FOUND Unity 工程必须位于包含 .git 的课程仓库中");
        }
    }
}
