// 职责：检查当前 Battle Scene 的通用 Authoring 组件、Layer、Collider 和 NavMesh 前置条件。
// 边界：Unity Editor Authoring Check；可用于新增或导入的 Battle Scene。
// 输入/输出：当前 Scene -> 通过日志或带错误码的明确异常。
// 不负责：不自动修改 Scene、不 Bake、不导出 BMAP。
#if UNITY_EDITOR
using System.Linq;
using BattleNavigation;
using UnityEditor;
using UnityEngine;

namespace BattleNavigation.Editor
{
    /// <summary>
    /// 检查当前 Battle Scene 是否具备地图导出前的基础配置。
    /// 检查对象始终是当前打开的场景，不绑定场景名或固定 mapId，因此可供不同 Battle Scene 复用。
    /// 这是课程提供的编辑器工具，不属于学习者需要编写或理解的核心代码。
    /// </summary>
    public static class BattleMapAuthoringValidator
    {
        /// <summary>
        /// 验证当前打开的场景。
        /// 本方法只做快速检查，不执行 NavMesh Bake、Grid Sampling 或 BMAP Export。
        /// </summary>
        [MenuItem("Tools/Battle Navigation/Validate Current Battle Scene")]
        public static void Validate()
        {
            // 每个 Battle Scene 必须只有一个 BattleMapRoot，它保存该地图的导出配置。
            BattleMapRoot[] roots = UnityEngine.Object.FindObjectsOfType<BattleMapRoot>();
            if (roots.Length != 1)
            {
                throw new System.InvalidOperationException(
                    $"BATTLE_MAP_ROOT_COUNT expected=1 actual={roots.Length}");
            }

            BattleMapRoot root = roots[0];
            root.ValidateOrThrow();

            // NavMesh 构建需要从场景几何收集 Collider；完全没有 Collider 通常表示场景尚未配置好。
            Collider[] colliders = UnityEngine.Object.FindObjectsOfType<Collider>();
            if (colliders.Length == 0)
            {
                throw new System.InvalidOperationException("AUTHORING_COLLIDER_MISSING");
            }

            // 示例战斗至少需要双方各有一个出生点。
            BattleSpawnPoint[] spawns = UnityEngine.Object.FindObjectsOfType<BattleSpawnPoint>();
            if (spawns.Count(spawn => spawn.Team == 1) == 0 ||
                spawns.Count(spawn => spawn.Team == 2) == 0)
            {
                throw new System.InvalidOperationException("AUTHORING_SPAWN_TEAM_MISSING");
            }

            Debug.Log(
                $"BATTLE_MAP_AUTHORING_OK map={root.mapId} version={root.mapVersion} " +
                $"grid={root.Width}x{root.Height} cell_mm={root.CellSizeMm} " +
                $"colliders={colliders.Length} spawns={spawns.Length}");
        }
    }
}
#endif
