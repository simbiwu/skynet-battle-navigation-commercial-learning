// 状态同步场景接线：从已发布地图场景另存，不改动原Authoring场景。
#if UNITY_EDITOR
using BattleNavigation.StateSync;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
namespace BattleNavigation.Client.Editor
{
    public static class StateBattleSceneSetup
    {
        [MenuItem("Tools/战斗导航/状态同步/创建运行场景")]
        public static void Create()
        {
            const string target = "Assets/BattleNavigation/Scenes/State_Battle_1001.unity";
            if (System.IO.File.Exists(target))
            {
                EditorSceneManager.OpenScene(target);
                return;
            }
            var scene = EditorSceneManager.OpenScene("Assets/BattleNavigation/Scenes/Battle_1001.unity");
            foreach (var root in scene.GetRootGameObjects())
            {
                // 示例回放客户端不得与新状态同步客户端同时接管显示。
                foreach (var behavior in root.GetComponentsInChildren<MonoBehaviour>(true))
                {
                    if (behavior != null && (behavior.GetType().Namespace == "BattleNavigation.FrameSync" ||
                        behavior.GetType().Name == "BattleReplayRequester" || behavior.GetType().Name == "BattleReplayPlayer"))
                        behavior.enabled = false;
                }
            }
            var runtime = new GameObject("StateBattleRuntime");
            runtime.AddComponent<StateBattleController>();
            if (Camera.main == null)
            {
                var camera = new GameObject("StateCamera").AddComponent<Camera>();
                camera.tag = "MainCamera";
                camera.transform.position = new Vector3(0, 28, -22);
                camera.transform.LookAt(Vector3.zero);
            }
            EditorSceneManager.SaveScene(scene, target);
            AssetDatabase.SaveAssets();
            Debug.Log("STATE_SCENE_READY " + target);
        }
    }
}
#endif
