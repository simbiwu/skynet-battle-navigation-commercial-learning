// 职责：在 Scene 中标记并编号需要接受静态地图验证的出生点。
// 边界：Unity Authoring；自身无 Collider，不参与 NavMesh Bake。
// 输入/输出：Inspector Team/Index + Transform -> Validator 使用的出生点数据。
// 不负责：不生成角色、不进入 BMAP Cell Payload。
using UnityEngine;

namespace BattleNavigation
{
    /// <summary>
    /// Unity 场景中的出生点 Authoring 标记；没有 Collider，不参与 NavMesh Bake。
    /// Team/Index 用于校验唯一性，MonoBehaviour 本身不会被 Server 加载。
    /// </summary>
    [DisallowMultipleComponent]
    public sealed class BattleSpawnPoint : MonoBehaviour
    {
        // 队伍编号，从 1 开始；0 保留为非法值。
        [SerializeField, Min(1)] private int team = 1;
        // 同队出生点序号，从 1 开始。
        [SerializeField, Min(1)] private int index = 1;

        // 对外只读的队伍编号，避免 Validator 修改 Authoring 数据。
        public int Team => team;
        // 对外只读的同队序号。
        public int Index => index;
        // 派生稳定 ID，避免再序列化一份可能与 Team/Index 冲突的数据。
        public uint SpawnId => checked((uint)(team * 1000 + index));

        /// <param name="valueTeam">队伍编号，从 1 开始。</param>
        /// <param name="valueIndex">同队出生点序号，从 1 开始。</param>
        public void Configure(int valueTeam, int valueIndex)
        {
            // 仅供 SceneBuilder 创建确定性的初始场景；日常调整可直接使用 Inspector。
            team = valueTeam;
            index = valueIndex;
        }

        private void OnDrawGizmos()
        {
            // Gizmo 只提供编辑器观察证据，不改变导出的静态导航数据。
            Gizmos.color = team == 1 ? Color.cyan : new Color(1f, 0.35f, 0.2f);
            Gizmos.DrawWireSphere(transform.position, 0.45f);
            Gizmos.DrawLine(transform.position, transform.position + Vector3.up * 1.5f);
        }
    }
}
