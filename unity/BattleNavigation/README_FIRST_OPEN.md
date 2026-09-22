# BattleNavigation Unity 工程第一次打开

1. 用 `G:\Tuanjie\Editors\2022.3.62t12\Editor\Tuanjie.exe` 打开本目录。
2. 等待右下角脚本编译完成，Console 不应有红色错误。
3. 打开 `Assets/BattleNavigation/Scenes/Battle_1001.unity`。
4. 执行 `Tools > Battle Navigation > Validate Battle_1001 Authoring`。
5. 在 Scene 窗口查看地面、围墙、中央障碍、坡道、高台和双方出生点。

AI Navigation 没有预先写入 Package 依赖，NavMeshSurface 也没有替学习者配置或 Bake。完整的名词解释和点击步骤见仓库根目录：

```text
docs/Skynet_BattleNavigation第一课_从Unity地图到Skynet查询_实操.md
```

## 必须由学习者亲自完成

下面这条生产链不会被自动脚本替你执行：

```text
检查 Unity 场景
-> Bake NavMesh
-> 检查 2.5D 限制
-> Grid Sampling / Validator
-> Export BMAP
-> 核对 manifest 和 CRC
-> 导入 Server assets/maps
```

场景可以通过菜单 `Tools > Battle Navigation > Create or Rebuild Battle_1001 Scene` 重建。
该菜单会覆盖场景内的手工调整，使用前会弹出确认框。
