// 职责：把第二课一次性 Battle 请求与回放组件接入已有 Battle_1001 Scene。
// 边界：Unity Client Editor 工具；只改场景中的客户端表现对象，不改 Authoring/BMAP。
// 输入/输出：已存在的 Battle_1001 Scene -> 一个连好引用的 BattleReplayRuntime。
// 生命周期：由菜单或 batchmode 显式运行；重复执行复用对象和组件。
// 不负责：不重建场景、不 Bake、不启动 Server、不在编辑器里请求战斗。
#if UNITY_EDITOR
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;

namespace BattleNavigation.Client.Editor
{
    /// <summary>在不重建地图的前提下，给已有示例场景挂载客户端回放入口。</summary>
    public static class BattleReplaySceneSetup
    {
        private const string ScenePath = "Assets/BattleNavigation/Scenes/Battle_1001.unity";

        /// <summary>幂等接线并保存场景；场景不存在时显式报错。</summary>
        /// <remarks>交互模式先询问当前未保存场景；batchmode 由调用方保证没有另一编辑器占用工程。</remarks>
        [MenuItem("Tools/战斗导航/示例/91 接入 Battle_1001 回放", false, 191)]
        public static void AttachReplay()
        {
            if (AssetDatabase.LoadAssetAtPath<SceneAsset>(ScenePath) == null)
                throw new System.IO.FileNotFoundException("先创建 Battle_1001 场景", ScenePath);
            if (!Application.isBatchMode && !EditorSceneManager.SaveCurrentModifiedScenesIfUserWantsTo())
                return;

            // 只打开已有场景；绝不能调用 CreateOrRebuild 覆盖作者已完成的静态地图。
            var scene = EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);
            GameObject runtime = null;
            foreach (var rootObject in scene.GetRootGameObjects())
            {
                if (rootObject.name == "BattleReplayRuntime")
                {
                    runtime = rootObject;
                    break;
                }
            }
            if (runtime == null)
                runtime = new GameObject("BattleReplayRuntime");

            var player = runtime.GetComponent<BattleReplayPlayer>();
            if (player == null)
                player = runtime.AddComponent<BattleReplayPlayer>();
            var requester = runtime.GetComponent<BattleReplayRequester>();
            if (requester == null)
                requester = runtime.AddComponent<BattleReplayRequester>();

            // 私有序列化字段由 Editor 显式连线；运行时不会按名称猜测组件所有权。
            var serializedRequester = new SerializedObject(requester);
            serializedRequester.FindProperty("replayPlayer").objectReferenceValue = player;
            serializedRequester.ApplyModifiedPropertiesWithoutUndo();
            EditorSceneManager.MarkSceneDirty(scene);
            EditorSceneManager.SaveScene(scene, ScenePath);
            Debug.Log("BATTLE_1001_REPLAY_READY " + ScenePath);
        }
    }
}
#endif
