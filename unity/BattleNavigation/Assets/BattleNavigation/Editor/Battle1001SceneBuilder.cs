// 职责：一次性生成课程 Battle_1001 的基础 Scene 内容和 Authoring 组件。
// 边界：Unity Editor Scaffolding；只用于课程样例场景，不是新地图日常导出入口。
// 输入/输出：空或待重建 Scene -> 可继续 Bake/Export 的课程场景。
// 不负责：不生成 BMAP、不替代通用 Validator 和 Exporter。
#if UNITY_EDITOR
using System.IO;
using BattleNavigation;
using Unity.AI.Navigation;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;

namespace BattleNavigation.Editor
{
    /// <summary>
    /// 只用于生成可重复的课程初始场景，不属于运行时地图生产链。
    /// 重新执行会覆盖 Battle_1001 中的手工修改，因此交互模式必须先确认。
    /// </summary>
    public static class Battle1001SceneBuilder
    {
        // 课程战斗场景在 Unity Assets 下的唯一保存路径。
        public const string ScenePath = "Assets/BattleNavigation/Scenes/Battle_1001.unity";

        [MenuItem("Tools/Battle Navigation/Create or Rebuild Battle_1001 Scene")]
        public static void CreateOrRebuild()
        {
            // CI/batch 模式不能弹窗；人工运行时必须明确确认覆盖行为。
            if (!Application.isBatchMode && File.Exists(ScenePath) &&
                !EditorUtility.DisplayDialog(
                    "Rebuild Battle_1001",
                    "这会重建 Battle_1001 场景。场景中的手工修改会被覆盖。",
                    "继续", "取消"))
            {
                return;
            }

            EnsureFolder("Assets/BattleNavigation/Scenes");
            // scene 是即将保存为 Battle_1001.unity 的全新空场景。
            var scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);

            // 层级按 Authoring 职责分组，不能把显示对象误当成 Server 数据边界。
            // root 保存地图身份与 Grid 范围，是场景中唯一 BattleMapRoot。
            var root = new GameObject("BattleMapRoot");
            root.AddComponent<BattleMapRoot>();

            // environment 是全部静态地图几何的父节点。
            var environment = NewChild(root.transform, "Environment");
            // ground 只包含基础地面。
            var ground = NewChild(environment.transform, "Ground");
            // obstacles 包含墙、柱和中央阻挡。
            var obstacles = NewChild(environment.transform, "StaticObstacles");
            // landmarks 包含坡道与台地等有高度的可走几何。
            var landmarks = NewChild(environment.transform, "Landmarks");
            // spawns 包含无 Collider 的出生点逻辑标记。
            var spawns = NewChild(root.transform, "SpawnPoints");
            // lighting 只包含客户端观察场景所需灯光，不进入 BMAP。
            var lighting = NewChild(root.transform, "Lighting");

            CreateBox(ground.transform, "MainGround", new Vector3(0f, -0.25f, 0f),
                new Vector3(30f, 0.5f, 20f), new Color(0.32f, 0.42f, 0.30f));

            CreateObstacle(obstacles.transform, "NorthWall", new Vector3(0f, 1f, 9.5f),
                new Vector3(30f, 2f, 1f), new Color(0.35f, 0.35f, 0.38f));
            CreateObstacle(obstacles.transform, "SouthWall", new Vector3(0f, 1f, -9.5f),
                new Vector3(30f, 2f, 1f), new Color(0.35f, 0.35f, 0.38f));
            CreateObstacle(obstacles.transform, "WestWall", new Vector3(-14.5f, 1f, 0f),
                new Vector3(1f, 2f, 20f), new Color(0.35f, 0.35f, 0.38f));
            CreateObstacle(obstacles.transform, "EastWall", new Vector3(14.5f, 1f, 0f),
                new Vector3(1f, 2f, 20f), new Color(0.35f, 0.35f, 0.38f));

            CreateObstacle(obstacles.transform, "CenterBlock", new Vector3(0f, 1.25f, 0f),
                new Vector3(4f, 2.5f, 4f), new Color(0.45f, 0.30f, 0.22f));
            CreateObstacle(obstacles.transform, "WestPillar", new Vector3(-7f, 1f, 2.5f),
                new Vector3(2f, 2f, 2f), new Color(0.45f, 0.30f, 0.22f));
            CreateObstacle(obstacles.transform, "EastPillar", new Vector3(7f, 1f, -2.5f),
                new Vector3(2f, 2f, 2f), new Color(0.45f, 0.30f, 0.22f));

            CreateRamp(landmarks.transform, "WestRamp", new Vector3(-8f, 0.75f, -4f),
                new Vector3(6f, 0.5f, 4f), new Vector3(0f, 0f, -10f));
            CreateBox(landmarks.transform, "WestPlateau", new Vector3(-8f, 1.2f, -7f),
                new Vector3(7f, 0.5f, 3f), new Color(0.38f, 0.48f, 0.36f));

            CreateRamp(landmarks.transform, "EastRamp", new Vector3(8f, 0.75f, 4f),
                new Vector3(6f, 0.5f, 4f), new Vector3(0f, 180f, -10f));
            CreateBox(landmarks.transform, "EastPlateau", new Vector3(8f, 1.2f, 7f),
                new Vector3(7f, 0.5f, 3f), new Color(0.38f, 0.48f, 0.36f));

            CreateSpawn(spawns.transform, "Team1_Spawn_01", 1, 1, new Vector3(-11f, 0.05f, 4f));
            CreateSpawn(spawns.transform, "Team1_Spawn_02", 1, 2, new Vector3(-11f, 0.05f, 6f));
            CreateSpawn(spawns.transform, "Team2_Spawn_01", 2, 1, new Vector3(11f, 0.05f, -4f));
            CreateSpawn(spawns.transform, "Team2_Spawn_02", 2, 2, new Vector3(11f, 0.05f, -6f));

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

        /// <param name="parent">新对象要挂接的父 Transform。</param>
        /// <param name="name">新 GameObject 的稳定场景名称。</param>
        private static GameObject NewChild(Transform parent, string name)
        {
            // value 是新建的空 GameObject；SetParent(false) 保持局部 Transform 为默认值。
            var value = new GameObject(name);
            value.transform.SetParent(parent, false);
            return value;
        }

        /// <param name="parent">静态几何所属的场景分组。</param>
        /// <param name="name">几何对象名称。</param>
        /// <param name="position">Unity 世界坐标，单位米。</param>
        /// <param name="scale">Cube 的世界尺寸，单位米。</param>
        /// <param name="color">仅用于 Authoring 观察的显示颜色。</param>
        private static GameObject CreateBox(Transform parent, string name, Vector3 position,
            Vector3 scale, Color color)
        {
            // Primitive Cube 自带 BoxCollider；本课 Bake 读取 Physics Colliders，而非视觉 Mesh。
            // value 同时提供可见 Mesh 和用于 Bake 的 BoxCollider。
            var value = GameObject.CreatePrimitive(PrimitiveType.Cube);
            value.name = name;
            value.transform.SetParent(parent, false);
            value.transform.position = position;
            value.transform.localScale = scale;
            ApplyColor(value, color);
            GameObjectUtility.SetStaticEditorFlags(value, StaticEditorFlags.BatchingStatic);
            return value;
        }

        /// <param name="parent">障碍物所属的场景分组。</param>
        /// <param name="name">障碍物的稳定场景名称。</param>
        /// <param name="position">Unity 世界坐标，单位米。</param>
        /// <param name="scale">Cube 的世界尺寸，单位米。</param>
        /// <param name="color">仅用于 Authoring 观察的显示颜色。</param>
        private static void CreateObstacle(Transform parent, string name, Vector3 position,
            Vector3 scale, Color color)
        {
            // 障碍物保留 Collider 作为 Bake 输入，但其顶面不能成为可走平台。
            GameObject value = CreateBox(parent, name, position, scale, color);
            // NavMeshModifier 把该 Collider 的整个构建源标记为 Not Walkable（Area 1）。
            NavMeshModifier modifier = value.AddComponent<NavMeshModifier>();
            modifier.overrideArea = true;
            modifier.area = 1;
        }

        /// <param name="parent">坡道所属的场景分组。</param>
        /// <param name="name">坡道对象名称。</param>
        /// <param name="position">Unity 世界坐标，单位米。</param>
        /// <param name="scale">坡道 Cube 尺寸，单位米。</param>
        /// <param name="rotation">Unity Euler 旋转角，单位度。</param>
        private static void CreateRamp(Transform parent, string name, Vector3 position,
            Vector3 scale, Vector3 rotation)
        {
            // value 是由 Cube/BoxCollider 构成并按 rotation 倾斜的坡道。
            var value = CreateBox(parent, name, position, scale, new Color(0.40f, 0.52f, 0.38f));
            value.transform.eulerAngles = rotation;
        }

        /// <param name="parent">出生点分组 Transform。</param>
        /// <param name="name">出生点对象名称。</param>
        /// <param name="team">队伍编号，从 1 开始。</param>
        /// <param name="index">同队出生点序号，从 1 开始。</param>
        /// <param name="position">出生点 Unity 世界坐标，单位米。</param>
        private static void CreateSpawn(Transform parent, string name, int team, int index,
            Vector3 position)
        {
            // 出生点是无 Collider 的逻辑标记，不能污染静态可走面。
            // value 是只含 Transform 与 BattleSpawnPoint 的空 GameObject。
            var value = NewChild(parent, name);
            value.transform.position = position;
            value.AddComponent<BattleSpawnPoint>().Configure(team, index);
        }

        /// <param name="parent">Lighting 分组 Transform。</param>
        private static void CreateLighting(Transform parent)
        {
            // lightObject 是编辑器观察用方向光载体。
            var lightObject = NewChild(parent, "Directional Light");
            lightObject.transform.rotation = Quaternion.Euler(48f, -35f, 0f);
            // light 控制显示亮度，不参与 NavMesh 或 BMAP。
            var light = lightObject.AddComponent<Light>();
            light.type = LightType.Directional;
            light.intensity = 1.1f;
            RenderSettings.ambientLight = new Color(0.42f, 0.45f, 0.50f);
        }

        /// <param name="parent">地图根 Transform；相机不属于静态几何分组。</param>
        private static void CreateCamera(Transform parent)
        {
            // cameraObject 是 Authoring 观察相机载体，不含 Collider。
            var cameraObject = NewChild(parent, "Authoring Camera");
            cameraObject.transform.position = new Vector3(0f, 25f, -24f);
            cameraObject.transform.rotation = Quaternion.Euler(45f, 0f, 0f);
            // camera 只用于查看场景，不参与 Bake 或 Server 地图。
            var camera = cameraObject.AddComponent<Camera>();
            camera.fieldOfView = 55f;
            camera.clearFlags = CameraClearFlags.Skybox;
            camera.tag = "MainCamera";
        }

        /// <param name="value">需要设置 Authoring 材质的几何对象。</param>
        /// <param name="color">仅用于显示的材质颜色。</param>
        private static void ApplyColor(GameObject value, Color color)
        {
            // Material 只帮助观察场景；颜色不会进入 BMAP。
            // renderer 是 Primitive Cube 自带的视觉渲染组件。
            var renderer = value.GetComponent<Renderer>();
            // shader 优先使用 Standard，兼容环境缺失时退回 Diffuse。
            var shader = Shader.Find("Standard") ?? Shader.Find("Diffuse");
            // material 是当前 Authoring 物体的独立颜色材质。
            var material = new Material(shader) { color = color };
            material.name = value.name + "_AuthoringMaterial";
            renderer.sharedMaterial = material;
        }

        /// <param name="path">以 Assets 开头、使用 '/' 分隔的 Unity Asset 目录。</param>
        private static void EnsureFolder(string path)
        {
            // parts 是 Unity Asset 相对路径按 '/' 拆分后的各级目录名。
            var parts = path.Split('/');
            // current 是已经确认存在的父目录路径。
            var current = parts[0];
            // i 指向即将检查/创建的下一层目录名。
            for (var i = 1; i < parts.Length; ++i)
            {
                // next 是当前父目录与下一层名称组成的完整 Asset 路径。
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
