using UnityEngine;

namespace BattleNavigation
{
    /// <summary>
    /// 第一课地图 Authoring 的唯一根配置。
    /// 世界坐标对外统一使用毫米；Unity Transform 仍使用米。
    /// </summary>
    public sealed class BattleMapRoot : MonoBehaviour
    {
        [Header("Identity")]
        [SerializeField] private string mapId = "battle_1001";
        [SerializeField, Min(1)] private int mapVersion = 1;

        [Header("Grid Sampling")]
        [SerializeField, Min(100)] private int cellSizeMm = 500;
        [SerializeField] private Vector3Int originMm = new Vector3Int(-15000, 0, -10000);
        [SerializeField, Min(1)] private int width = 60;
        [SerializeField, Min(1)] private int height = 40;
        [SerializeField, Min(100)] private int sampleTopMm = 10000;
        [SerializeField, Min(100)] private int sampleBottomMm = -2000;

        public string MapId => mapId;
        public int MapVersion => mapVersion;
        public int CellSizeMm => cellSizeMm;
        public Vector3Int OriginMm => originMm;
        public int Width => width;
        public int Height => height;
        public int SampleTopMm => sampleTopMm;
        public int SampleBottomMm => sampleBottomMm;

        private void OnValidate()
        {
            mapId = string.IsNullOrWhiteSpace(mapId) ? "battle_1001" : mapId.Trim();
            mapVersion = Mathf.Max(1, mapVersion);
            cellSizeMm = Mathf.Max(100, cellSizeMm);
            width = Mathf.Max(1, width);
            height = Mathf.Max(1, height);
            sampleTopMm = Mathf.Max(100, sampleTopMm);
            sampleBottomMm = Mathf.Min(sampleTopMm - 100, sampleBottomMm);
        }

        private void OnDrawGizmosSelected()
        {
            var origin = new Vector3(originMm.x, originMm.y, originMm.z) / 1000f;
            var size = new Vector3(width * cellSizeMm / 1000f, 0.05f,
                height * cellSizeMm / 1000f);
            Gizmos.color = new Color(0.1f, 0.8f, 1f, 0.8f);
            Gizmos.DrawWireCube(origin + new Vector3(size.x, 0f, size.z) * 0.5f, size);
        }
    }
}

