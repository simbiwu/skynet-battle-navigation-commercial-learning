# Package Manifest

```text
README.md
AGENTS.md
PACKAGE_MANIFEST.md
SHA256SUMS.txt

docs/
  PROJECT_CONTEXT.md
  COURSE_ROADMAP.md
  TARGET_ARCHITECTURE.md
  ENGINEERING_DECISIONS.md
  NAVIGATION_ABSTRACTION.md
  BMAP_FORMAT.md
  NATIVE_NAV_API.md
  POLYGON_NAV_ASSET_FORMAT.md
  TEST_STRATEGY.md
  REFERENCES.md
  VS_CODE_GIT_FOR_SVN.md
  Skynet_BattleNavigation第一课_从Unity地图到Skynet查询_实操.md
  LESSON_02_PRACTICAL.md
  LESSON_03_PRACTICAL.md

codex/
  CODEX_START_HERE.md
  LESSON_01_SPEC.md
  LESSON_02_SPEC.md
  LESSON_03_SPEC.md
```

## V3 核心修改

V2 虽然架构可扩展，但第一课暴露了太多未来概念。

V3 固定：

```text
Lesson 1:
  只学地图生产和查询

Lesson 2:
  需求驱动引入 AgentProfile / Path / NavigationContext / A*
  后段再抽 Navigation Backend

Lesson 3:
  Recast / Detour 作为第二种 Backend
```

这样保留商业级可演进性，同时降低第一课认知成本。
