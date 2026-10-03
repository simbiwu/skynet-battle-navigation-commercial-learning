// 职责：验证课程原场景迁入 UPM 后仍能解析原 GUID、地图参数和出生点。
// 边界：宿主 EditMode Test；只读 Scene，结束恢复原编辑器场景布局。
// 不负责：不重建课程场景、不重新导出正式资产、不运行客户端网络回放。
using NUnit.Framework;
using UnityEditor.SceneManagement;
using UnityEngine;
using FlyWow.Navigation;

namespace BattleNavigation.Tests
{
    public sealed class NavigationPackageSceneTests
    {
        /// <summary>原 Scene 引用包中同 GUID 组件，迁移不丢失序列化配置。</summary>
        [Test]
        public void Battle1001KeepsMapIdentityAndSceneReferences()
        {
            SceneSetup[] previous = EditorSceneManager.GetSceneManagerSetup();
            try
            {
                var scene = EditorSceneManager.OpenScene(
                    "Assets/BattleNavigation/Scenes/Battle_1001.unity",
                    OpenSceneMode.Single);
                NavigationMapRoot map = Object.FindObjectOfType<NavigationMapRoot>();
                Assert.That(map, Is.Not.Null);
                Assert.That(map.mapId, Is.EqualTo(1001));
                Assert.That(map.mapVersion, Is.EqualTo(1));
                Assert.That(map.originMeters, Is.EqualTo(new Vector2(-15f, -10f)));
                Assert.That(map.cellSizeMeters, Is.EqualTo(0.5f));
                Assert.That(map.Width, Is.EqualTo(60));
                Assert.That(map.Height, Is.EqualTo(40));
                Assert.That(Object.FindObjectsOfType<BattleSpawnPoint>().Length, Is.GreaterThanOrEqualTo(4));
                foreach (GameObject root in scene.GetRootGameObjects())
                {
                    foreach (Transform child in root.GetComponentsInChildren<Transform>(true))
                    {
                        foreach (Component component in child.GetComponents<Component>())
                        {
                            Assert.That(component, Is.Not.Null, "Missing script: " + child.name);
                        }
                    }
                }
            }
            finally
            {
                // Batch Test Runner 起始可能没有任何已保存 Scene，空 setup 不能直接恢复。
                if (System.Array.Exists(previous, setup => setup.isLoaded && !string.IsNullOrEmpty(setup.path)))
                {
                    EditorSceneManager.RestoreSceneManagerSetup(previous);
                }
                else
                {
                    EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
                }
            }
        }
    }
}
