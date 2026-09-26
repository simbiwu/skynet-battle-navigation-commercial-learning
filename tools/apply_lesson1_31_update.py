#!/usr/bin/env python3
from pathlib import Path
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else '.').resolve()
if not (root / 'AGENTS.md').is_file() or not (root / 'server').is_dir() or not (root / 'docs').is_dir():
    raise SystemExit('UPDATE_ROOT_INVALID: run from skynet-battle-navigation-commercial-learning repository root')

payload_root = Path(__file__).resolve().parents[1]
section31 = (payload_root / 'patches' / 'lesson1_section31.md').read_text(encoding='utf-8')


def read(rel):
    return (root / rel).read_text(encoding='utf-8')


def write(rel, text):
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding='utf-8', newline='\n')


def replace_once(text, old, new, label):
    if new in text:
        return text
    count = text.count(old)
    if count == 0:
        raise SystemExit(f'PATCH_ANCHOR_MISSING: {label}')
    if count != 1:
        raise SystemExit(f'PATCH_ANCHOR_AMBIGUOUS: {label} count={count}')
    return text.replace(old, new, 1)

# 1) Lesson 1: section 31 becomes the final recap/debug/acceptance chapter.
lesson_rel = 'docs/Skynet_BattleNavigation第一课_从Unity地图到Skynet查询_实操.md'
lesson = read(lesson_rel)
marker = '\n## 31.'
pos = lesson.find(marker)
if pos < 0:
    raise SystemExit('PATCH_ANCHOR_MISSING: Lesson 1 section 31')
lesson = lesson[:pos + 1].rstrip() + '\n\n' + section31.rstrip() + '\n'
write(lesson_rel, lesson)

# 2) Gateway: debug module is always require-able, but does nothing unless env enables it.
gateway_rel = 'server/service/navigation_gateway.lua'
gateway = read(gateway_rel)
gateway = replace_once(
    gateway,
    'local codec = require "protocol.navigation_codec"\n',
    'local codec = require "protocol.navigation_codec"\nlocal luapanda_debug = require "debug.luapanda_debug"\n',
    'Gateway debug require')
gateway = replace_once(
    gateway,
    'skynet.start(function()\n    skynet.dispatch("lua", function(_session, _source, command, argument)\n',
    'skynet.start(function()\n    -- Debug-only: normal start does nothing; LUA_PANDA_ENABLE=1 enables this Lua State target.\n    luapanda_debug.start("gateway")\n\n    skynet.dispatch("lua", function(_session, _source, command, argument)\n',
    'Gateway debug start')
write(gateway_rel, gateway)

# 3) Query Service: a second LuaPanda target is required because this is another Lua State.
query_rel = 'server/service/navigation_query.lua'
query = read(query_rel)
query = replace_once(
    query,
    'local query_logic = require "navigation.query_logic"\n',
    'local query_logic = require "navigation.query_logic"\nlocal luapanda_debug = require "debug.luapanda_debug"\n',
    'Query debug require')
query = replace_once(
    query,
    'skynet.start(function()\n    query_logic.start(config)\n',
    'skynet.start(function()\n    -- Query 是独立 Lua State，使用与 Gateway 不同的 LuaPanda port。\n    luapanda_debug.start("query")\n    query_logic.start(config)\n',
    'Query debug start')
write(query_rel, query)

# 4) Debug third_party directories are local generated dependencies.
gitignore_rel = 'server/.gitignore'
gitignore = read(gitignore_rel)
for entry in [
    '/third_party/luapanda/',
    '/third_party/luasocket/',
    '/third_party/luasocket-runtime/',
]:
    if entry not in gitignore.splitlines():
        if not gitignore.endswith('\n'):
            gitignore += '\n'
        gitignore += entry + '\n'
write(gitignore_rel, gitignore)

# 5) Server README receives a concise operator entry; the full teaching is in Lesson 1 section 31.
readme_rel = 'server/README.md'
readme = read(readme_rel)
marker_text = '## 第一课最终准备与调试\n'
if marker_text not in readme:
    addition = r'''

## 第一课最终准备与调试

第一课最终验收不再手工串联构建命令。先从 Unity 导出 BMAP，然后：

```bash
BUILD_TYPE=Debug \
./scripts/linux/lesson1_prepare.sh \
  --unity-output "$(git rev-parse --show-toplevel)/unity/BattleNavigation/BuildArtifacts/Navigation"
```

重复验收可复用已导入地图：

```bash
BUILD_TYPE=Debug ./scripts/linux/lesson1_prepare.sh --reuse-map
```

LuaPanda 是 debug-only 工具链。安装/验证本地调试依赖：

```bash
./scripts/linux/bootstrap_luapanda.sh
```

VS Code 先启动 `server/debug/luapanda/launch.json.example` 中的 Gateway + Query 两个 target，然后：

```bash
./scripts/linux/debug_luapanda.sh
```

LuaPanda + gdb 同时跟踪：

```bash
./scripts/linux/debug_luapanda.sh --gdb
```

Gateway 使用 8818，Query 使用 8819。两个 Service 是两个独立 Lua State，因此必须是两个调试 target。正常 `run_server.sh start` 不设置 `LUA_PANDA_ENABLE`，不会加载 LuaPanda runtime。

完整断点顺序、故障排查和验收证据见第一课第 31 节。
'''
    readme = readme.rstrip() + addition.rstrip() + '\n'
write(readme_rel, readme)

print('LESSON1_SECTION31_UPDATE_OK')
