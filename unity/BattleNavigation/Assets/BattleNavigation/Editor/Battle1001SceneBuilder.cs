#if UNITY_EDITOR
using System.IO;
using BattleNavigation;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;

namespace BattleNavigation.Editor
{
    public static class Battle1001SceneBuilder
    {
        public const string ScenePath = "Assets/BattleNavigation/Scenes/Battle_1001.unity";

        [MenuItem("Tools/Battle Navigation/Create or Rebuild Battle_1001 Scene")]
        public static void CreateOrRebuild()
        {
            if (!Application.isBatchMode && File.Exists(ScenePath) &&
                !EditorUtility.DisplayDialog(
                    "Rebuild Battle_1001",
                    "这会重建 Battle_1001 场景。场景中的手工修改会被覆盖。",
                    "继续", "取消"))
            {
                return;
            }

            EnsureFolder("Assets/BattleNavigation/Scenes");
            var scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);

            var root = new GameObject("BattleMapRoot");
            root.AddComponent<BattleMapRoot>();

            var environment = NewChild(root.transform, "Environment");
            var ground = NewChild(environment.transform, "Ground");
            var obstacles = NewChild(environment.transform, "StaticObstacles");
            var landmarks = NewChild(environment.transform, "Landmarks");
            var spawns = NewChild(root.transform, "SpawnPoints");
            var lighting = NewChild(root.transform, "Lighting");

            CreateBox(ground.transform, "MainGround", new Vector3(0f, -0.25f, 0f),
                new Vector3(30f, 0.5f, 20f), new Color(0.32f, 0.42f, 0.30f));

            CreateBox(obstacles.transform, "NorthWall", new Vector3(0f, 1f, 9.5f),
                new Vector3(30f, 2f, 1f), new Color(0.35f, 0.35f, 0.38f));
            CreateBox(obstacles.transform, "SouthWall", new Vector3(0f, 1f, -9.5f),
                new Vector3(30f, 2f, 1f), new Color(0.35f, 0.35f, 0.38f));
            CreateBox(obstacles.transform, "WestWall", new Vector3(-14.5f, 1f, 0f),
                new Vector3(1f, 2f, 20f), new Color(0.35f, 0.35f, 0.38f));
            CreateBox(obstacles.transform, "EastWall", new Vector3(14.5f, 1f, 0f),
                new Vector3(1f, 2f, 20f), new Color(0.35f, 0.35f, 0.38f));

            CreateBox(obstacles.transform, "CenterBlock", new Vector3(0f, 1.25f, 0f),
                new Vector3(4f, 2.5f, 4f), new Color(0.45f, 0.30f, 0.22f));
            CreateBox(obstacles.transform, "WestPillar", new Vector3(-7f, 1f, 2.5f),
                new Vector3(2f, 2f, 2f), new Color(0.45f, 0.30f, 0.22f));
            CreateBox(obstacles.transform, "EastPillar", new Vector3(7f, 1f, -2.5f),
                new Vector3(2f, 2f, 2f), new Color(0.45f, 0.30f, 0.22f));

            CreateRamp(landmarks.transform, "WestRamp", new Vector3(-8f, 0.75f, -4f),
                new Vector3(6f, 0.5f, 4f), new Vector3(0f, 0f, -10f));
            CreateBox(landmarks.transform, "WestPlateau", new Vector3(-8f, 1.2f, -7f),
                new Vector3(7f, 0.5f, 3f), new Color(0.38f, 0.48f, 0.36f));

            CreateRamp(landmarks.transform, "EastRamp", new Vector3(8f, 0.75f, 4f),
                new Vector3(6f, 0.5f, 4f), new Vector3(0f, 180f, -10f));
            CreateBox(landmarks.transform, "EastPlateau", new Vector3(8f, 1.2f, 7f),
                new Vector3(7f, 0.5f, 3f), new Color(0.38f, 0.48f, 0.36f));

            CreateSpawn(spawns.transform, "Team1_Spawn_01", 1, 1, new Vector3(-11f, 0.05f, -6f));
            CreateSpawn(spawns.transform, "Team1_Spawn_02", 1, 2, new Vector3(-11f, 0.05f, -3f));
            CreateSpawn(spawns.transform, "Team2_Spawn_01", 2, 1, new Vector3(11f, 0.05f, 6f));
            CreateSpawn(spawns.transform, "Team2_Spawn_02", 2, 2, new Vector3(11f, 0.05f, 3f));

            CreateLighting(lighting.transform);
            CreateCamera(root.transform);

            SceneManager.SetActiveScene(scene);
            EditorSceneManager.SaveScene(scene, ScenePath);
            EditorBuildSettings.scenes = new[] { new EditorBuildSettingsScene(ScenePath, true) };
            AssetDatabase.SaveAssets();
            AssetDatabase.Refresh();
            Selection.activeGameObject = root;

            Debug.Log("BATTLE_1001_SCENE_READY " + ScenePath +
                      "。下一步由学习者在 Unity 中检查场景、Bake NavMesh、运行 Validator，最后亲自执行 BMAP Export。");
        }

        private static GameObject NewChild(Transform parent, string name)
        {
            var value = new GameObject(name);
            value.transform.SetParent(parent, false);
            return value;
        }

        private static GameObject CreateBox(Transform parent, string name, Vector3 position,
            Vector3 scale, Color color)
        {
            var value = GameObject.CreatePrimitive(PrimitiveType.Cube);
            value.name = name;
            value.transform.SetParent(parent, false);
            value.transform.position = position;
            value.transform.localScale = scale;
            ApplyColor(value, color);
            GameObjectUtility.SetStaticEditorFlags(value,
                StaticEditorFlags.NavigationStatic | StaticEditorFlags.BatchingStatic);
            return value;
        }

        private static void CreateRamp(Transform parent, string name, Vector3 position,
            Vector3 scale, Vector3 rotation)
        {
            var value = CreateBox(parent, name, position, scale, new Color(0.40f, 0.52f, 0.38f));
            value.transform.eulerAngles = rotation;
        }

        private static void CreateSpawn(Transform parent, string name, int team, int index,
            Vector3 position)
        {
            var value = NewChild(parent, name);
            value.transform.position = position;
            value.AddComponent<BattleSpawnPoint>().Configure(team, index);
        }

        private static void CreateLighting(Transform parent)
        {
            var lightObject = NewChild(parent, "Directional Light");
            lightObject.transform.rotation = Quaternion.Euler(48f, -35f, 0f);
            var light = lightObject.AddComponent<Light>();
            light.type = LightType.Directional;
            light.intensity = 1.1f;
            RenderSettings.ambientLight = new Color(0.42f, 0.45f, 0.50f);
        }

        private static void CreateCamera(Transform parent)
        {
            var cameraObject = NewChild(parent, "Authoring Camera");
            cameraObject.transform.position = new Vector3(0f, 25f, -24f);
            cameraObject.transform.rotation = Quaternion.Euler(45f, 0f, 0f);
            var camera = cameraObject.AddComponent<Camera>();
            camera.fieldOfView = 55f;
            camera.clearFlags = CameraClearFlags.Skybox;
            camera.tag = "MainCamera";
        }

        private static void ApplyColor(GameObject value, Color color)
        {
            var renderer = value.GetComponent<Renderer>();
            var shader = Shader.Find("Standard") ?? Shader.Find("Diffuse");
            var material = new Material(shader) { color = color };
            material.name = value.name + "_AuthoringMaterial";
            renderer.sharedMaterial = material;
        }

        private static void EnsureFolder(string path)
        {
            var parts = path.Split('/');
            var current = parts[0];
            for (var i = 1; i < parts.Length; ++i)
            {
                var next = current + "/" + parts[i];
                if (!AssetDatabase.IsValidFolder(next))
                {
                    AssetDatabase.CreateFolder(current, parts[i]);
                }
                current = next;
            }
        }
    }
}
#endif

