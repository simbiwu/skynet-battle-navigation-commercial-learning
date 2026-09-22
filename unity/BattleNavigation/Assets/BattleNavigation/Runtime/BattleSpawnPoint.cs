using UnityEngine;

namespace BattleNavigation
{
    public sealed class BattleSpawnPoint : MonoBehaviour
    {
        [SerializeField] private int team;
        [SerializeField] private int index;

        public int Team => team;
        public int Index => index;

        public void Configure(int valueTeam, int valueIndex)
        {
            team = valueTeam;
            index = valueIndex;
        }

        private void OnDrawGizmos()
        {
            Gizmos.color = team == 1 ? Color.cyan : new Color(1f, 0.35f, 0.2f);
            Gizmos.DrawWireSphere(transform.position, 0.45f);
            Gizmos.DrawLine(transform.position, transform.position + Vector3.up * 1.5f);
        }
    }
}

