# BattleNavigation Unity 工程第一次打开

1. 在 Tuanjie Hub 中选择固定版本 2022.3.62t12，并打开本目录；Editor 实际安装路径由当前机器决定。
2. 等待右下角脚本编译完成，Console 不应有红色错误。
3. 打开 `Assets/BattleNavigation/Scenes/Battle_1001.unity`。
4. 推荐执行 `Tools > 战斗导航 > 00 一键执行：校验 -> 烘焙 -> 导出（推荐）`。
5. 在 Scene 窗口查看地面、围墙、中央障碍、坡道、高台和双方出生点。

先在 Package Manager 确认 AI Navigation 1.1.7；若项目尚未解析该依赖，再按教程安装。NavMeshSurface 不会替学习者配置或 Bake。完整的名词解释和点击步骤见仓库根目录：

```text
docs/Skynet_BattleNavigation第一课_从Unity地图到Skynet查询_实操.md
```

## 必须由学习者亲自完成

推荐菜单会按下面的顺序调用同一组正式工具：

```text
校验 Unity Authoring
-> Bake NavMesh 并保存 Scene
-> 检查 2.5D 限制
-> Grid Sampling / Validator
-> Export BMAP
-> 核对 manifest 和 CRC
-> 提交 shared/navigation 发布资产
-> Server 机器拉取同一 Git 提交
```

`01 校验当前战斗场景`、`02 烘焙当前场景 NavMesh`、`03 导出当前场景 BMAP` 仍然保留，用于定位具体失败阶段。Exporter 只更新当前仓库 `shared/navigation/battle_<mapId>/` 的候选文件；它不提交 Git、不访问另一台机器，也不会让运行中的 Server 自动重载。WSL 的 `lesson1_prepare.sh` 只验证已经拉取的发布版本并构建 Server。

场景可以通过菜单 `Tools > 战斗导航 > 示例 > 90 重建 Battle_1001 示例场景` 重建。
该菜单会覆盖场景内的手工调整，使用前会弹出确认框。
