# 更新包使用方法

本包基于仓库 `main` 当前内容生成，第二课以仓库版本为准。

## 应用

把 ZIP 内容直接解压到：

```text
skynet-battle-navigation-commercial-learning/
```

允许覆盖同名文件，然后在仓库根目录执行：

```bash
chmod +x APPLY_UPDATE.sh
./APPLY_UPDATE.sh
```

不需要逐文件复制/替换。

`APPLY_UPDATE.sh` 只对教程和工程合同做锚点级修改；Server 源码/脚本已经按正常仓库目录放在更新包中，解压时直接覆盖。

## 验证与启动

```bash
cd server
./scripts/linux/run_server.sh doctor
./scripts/linux/run_server.sh start
./scripts/linux/run_server.sh status
tail -f logs/server.log
```

完整重编并启动：

```bash
./scripts/linux/run_server.sh restart --rebuild
```

安全停止：

```bash
./scripts/linux/stop_server.sh
```

详细修改内容见根目录 `CHANGELOG_UPDATE.md`。
