# 更新包使用方法

本包基于：

```text
main@73405415491dca3e4fbb1b3dd02627af63f9a799
```

生成。

把 ZIP 内容直接解压到仓库根目录并覆盖，然后执行：

```bash
chmod +x APPLY_LESSON1_SECTION31_UPDATE.sh
./APPLY_LESSON1_SECTION31_UPDATE.sh
```

第一课最终准备：

```bash
cd server
BUILD_TYPE=Debug \
./scripts/linux/lesson1_prepare.sh \
  --unity-output "$(git rev-parse --show-toplevel)/unity/BattleNavigation/BuildArtifacts/Navigation"
```

重复验收：

```bash
BUILD_TYPE=Debug ./scripts/linux/lesson1_prepare.sh --reuse-map
```

LuaPanda：

```bash
./scripts/linux/bootstrap_luapanda.sh
./scripts/linux/debug_luapanda.sh
```

LuaPanda + gdb：

```bash
./scripts/linux/debug_luapanda.sh --gdb
```

VS Code 配置模板：

```text
server/debug/luapanda/launch.json.example
```

详细修改见 `CHANGELOG_LESSON1_SECTION31.md`。
