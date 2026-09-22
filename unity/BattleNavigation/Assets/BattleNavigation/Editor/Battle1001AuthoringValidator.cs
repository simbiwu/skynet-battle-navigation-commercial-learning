#if UNITY_EDITOR
using System.Linq;
using BattleNavigation;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;

namespace BattleNavigation.Editor
{
    public static class Battle1001AuthoringValidator
    {
        [MenuItem("Tools/Battle Navigation/Validate Battle_1001 Authoring")]
        public static void Validate()
        {
            var root = Object.FindObjectOfType<BattleMapRoot>();
            if (root == null) throw new System.InvalidOperationException("BattleMapRoot not found");
            if (root.MapId != "battle_1001")
                throw new System.InvalidOperationException("mapId must be battle_1001");
            if (root.MapVersion <= 0) throw new System.InvalidOperationException("mapVersion must be positive");
            if (root.CellSizeMm <= 0) throw new System.InvalidOperationException("cellSizeMm must be positive");

            var colliders = Object.FindObjectsOfType<Collider>();
            if (colliders.Length == 0) throw new System.InvalidOperationException("No authoring collider found");
            var spawns = Object.FindObjectsOfType<BattleSpawnPoint>();
            if (spawns.Count(x => x.Team == 1) < 1 || spawns.Count(x => x.Team == 2) < 1)
                throw new System.InvalidOperationException("Both teams need spawn points");

            Debug.Log($"BATTLE_1001_AUTHORING_OK map={root.MapId} version={root.MapVersion} " +
                      $"grid={root.Width}x{root.Height} cell_mm={root.CellSizeMm} " +
                      $"colliders={colliders.Length} spawns={spawns.Length}");
        }

        // 仅用于 CI/命令行检查 Authoring 场景，不执行 NavMesh Bake、Grid Sampling 或 BMAP Export。
        public static void ValidateGeneratedScene()
        {
            EditorSceneManager.OpenScene(Battle1001SceneBuilder.ScenePath);
            Validate();
        }
    }
}
#endif
