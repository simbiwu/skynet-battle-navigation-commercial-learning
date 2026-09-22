# v3 -> 团结引擎 1.10.0 补丁

将本补丁目录中的文件按相同相对路径覆盖到：

```text
skynet-battle-navigation-commercial-course-pack-v3/
```

需要覆盖：

```text
README.md
docs/REFERENCES.md
docs/ENGINEERING_DECISIONS.md
docs/TARGET_ARCHITECTURE.md
SHA256SUMS.txt
```

这次不重新生成整套资料。

主要变化：

```text
Unity 6.0 / 6000.x
AI Navigation 2.0.9
```

改为：

```text
团结引擎 1.10.0
Unity 2022.3 LTS 技术基线
com.unity.ai.navigation@1.1
```

同时修正 v3 中 `ENGINEERING_DECISIONS.md` 里 D002 与教学顺序的矛盾：
Lesson 1 不再提前实现 INavigationBackend。

其它 Lesson 文档中的 `Unity Scene / Unity API / Unity Replay` 作为技术体系通用术语保留，不代表要求安装全球版 Unity 6000.x。
