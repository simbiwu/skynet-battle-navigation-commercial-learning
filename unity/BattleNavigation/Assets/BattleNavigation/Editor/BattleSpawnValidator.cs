// 职责：在通用导航导出前验证课程战斗出生点，规则由课程拥有。
// 边界：Editor Adapter；不修改导航算法或资产格式。
using System;
using System.Collections.Generic;
using System.Linq;
using FlyWow.Navigation;
using FlyWow.Navigation.Editor;
using UnityEditor;
using UnityEngine;

namespace BattleNavigation.Editor
{
    [InitializeOnLoad]
    public static class BattleSpawnValidator
    {
        /// <summary>域加载时注册一次同步校验；域重载会清除旧的静态订阅。</summary>
        static BattleSpawnValidator()
        {
            NavigationMapExporter.ValidateCandidate += Validate;
        }

        /// <summary>校验宿主出生点；root 只读、snapshot 为本次候选，不执行 I/O。</summary>
        private static void Validate(NavigationMapRoot root, NavigationMapSnapshot snapshot)
        {
            ValidateSpawnPoints(root, snapshot);
        }
        /// <param name="snapshot">出生点将映射到的静态 Grid 快照。</param>
        private static void ValidateSpawnPoints(NavigationMapRoot root, NavigationMapSnapshot snapshot)
        {
            // 当前 Scene 的全部出生点 Authoring 标记。
            BattleSpawnPoint[] points = UnityEngine.Object.FindObjectsByType<BattleSpawnPoint>(
                FindObjectsSortMode.None).Where(point => point.gameObject.scene == root.gameObject.scene).ToArray();
            if (points.Length < 2)
            {
                throw new InvalidOperationException("SPAWN_POINT_MISSING expected>=2");
            }

            // Battle_1001 固定两队；这是宿主规则，通用包的新地图无需满足该规则。
            if (root.mapId == 1001 &&
                (points.Count(point => point.Team == 1) < 2 ||
                 points.Count(point => point.Team == 2) < 2))
            {
                throw new InvalidOperationException("SPAWN_TEAM_COUNT expected>=2 per team");
            }

            // 已见 SpawnId 集合，用于拒绝 Team/Index 重复。
            var ids = new HashSet<uint>();
            // point 是当前待映射到 Grid 并验证的 Scene 出生点。
            foreach (BattleSpawnPoint point in points)
            {
                // 从 Team/Index 派生的稳定出生点 ID。
                uint spawnId = point.SpawnId;
                if (spawnId == 0 || !ids.Add(spawnId))
                {
                    throw new InvalidOperationException(
                        "SPAWN_ID_INVALID_OR_DUPLICATE id=" + spawnId);
                }

                // 出生点世界 X 转成毫米后再映射 Grid，避免 float 除法两端不一致。
                int worldXMm = NavigationMapRoot.MetersToMillimeters(
                    point.transform.position.x,
                    "spawnX");
                // 出生点世界 Z，单位毫米。
                int worldZMm = NavigationMapRoot.MetersToMillimeters(
                    point.transform.position.z,
                    "spawnZ");
                // 出生点相对 Grid 原点的 X Cell 下标；负数必须使用 floor division。
                int gridX = NavigationMapValidator.FloorDiv(worldXMm - snapshot.originXMm, snapshot.cellSizeMm);
                // 出生点相对 Grid 原点的 Z Cell 下标。
                int gridZ = NavigationMapValidator.FloorDiv(worldZMm - snapshot.originZMm, snapshot.cellSizeMm);

                if (gridX < 0 || gridX >= snapshot.width ||
                    gridZ < 0 || gridZ >= snapshot.height)
                {
                    throw new InvalidOperationException(
                        "SPAWN_OUT_OF_BOUNDS id=" + spawnId);
                }

                if (!snapshot.CellAt(gridX, gridZ).IsWalkable)
                {
                    throw new InvalidOperationException(
                        "SPAWN_NOT_WALKABLE id=" + spawnId);
                }
            }
        }

    }
}
