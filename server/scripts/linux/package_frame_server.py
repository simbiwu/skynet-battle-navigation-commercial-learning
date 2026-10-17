#!/usr/bin/env python3
"""第三课帧同步 Linux Server 发布入口（在 WSL 主工作区执行）。

调用：
    python3 server/scripts/linux/package_frame_server.py 2026.10.15.4

维护入口只有下面两个主要区块：
1. PATHS：仓库相对目录、输出目录、启动配置与构建入口。派生路径使用 {名称}，
   例如改 frame_build 后，构建输出读取位置和 CTest 路径会一起改变。
2. RELEASE_FILES：需要发布的文件/目录白名单；源路径与包内目标路径在同一行。
   增删普通运行文件只改此处，不改复制、清单、压缩或验证算法。

副作用：调用已有构建链，更新编译产物、Server 协议生成物和地图元数据；
创建 releases/ 下的归档、依赖报告和 SHA256。不会下载、运行 Git 或同步工作区。
边界：BMAP-only，不包含 Unity；已有固定依赖源码与 Linux 构建工具必须就绪。
路径表只负责发布编排；若移动真实源码模块，还必须遵守其现有 CMake/Lua 加载合同，
不能只搬文件而保留失效的 require、map_path 或构建脚本内部路径。
"""
import argparse
import gzip
import hashlib
import json
import os
import platform
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile


# ==================== 维护区 1：目录与现有入口 ====================
# 所有值相对仓库根目录，不写 /home/... 或 Windows 绝对路径。
# 字段按依赖顺序声明：模板只能引用它前面已声明的字段。
# server/shared 的包内同级布局是 Runtime 合同，通常不改这两个字段。
PATHS = {
    "server":             "server",
    "shared":             "shared",
    "output":             "releases",
    "skynet":             "{server}/third_party/skynet",
    "flywow":             "{server}/third_party/skynet-flywow",
    "protobuf_source":    "{server}/third_party/lua-protobuf",
    "protobuf_runtime":   "{server}/third_party/lua-protobuf-runtime",
    "frame_source":       "{server}/native/frame_sync",
    "frame_build":        "{server}/build/frame_sync",
    "flywow_native":      "{flywow}/build/native",
    "native_release":     "{server}/luaclib",
    "config":             "{server}/config",
    "battle_service":     "{server}/service/battle/frame_sync",
    "gateway_service":    "{server}/service/gateway/frame_sync",
    "frame_lualib":       "{server}/lualib/battle/frame_sync",
    "gateway_protocol":   "{server}/lualib/gateway/protocol",
    "frame_registry":     "{gateway_protocol}/protocol_registry_lesson_03_frame_sync.lua",
    "credentials":        "{server}/lualib/battle/session_credentials.lua",
    "debug_switch":       "{server}/lualib/shared/debug/luapanda_debug.lua",
    "map":                "{shared}/navigation/battle_1001/battle_1001.bmap",
    "map_manifest":       "{shared}/navigation/battle_1001/battle_1001.manifest.json",
    "protocol_root":      "{shared}/protocol",
    "protocol_generated": "{shared}/protocol/generated/server",
    "frame_config":       "{config}/frame_sync.lua",
    "battle_process":     "{config}/frame_battle_process.lua",
    "gateway_process":    "{config}/frame_gateway_process.lua",
    "skynet_executable":  "{skynet}/skynet",
    "logs":               "{server}/logs",
    "integration_test":   "{server}/tests/frame_sync_integration.py",
    "protocol_builder":   "{server}/protocol/build_protocol_lesson_03_frame_sync.sh",
    "skynet_builder":     "{server}/scripts/linux/build_skynet.sh",
    "protobuf_builder":   "{server}/scripts/linux/build_lua_protobuf.sh",
    "flywow_builder":     "{flywow}/scripts/build_flywow.sh",
    "frame_builder":      "{server}/scripts/lessons/lesson3_build_frame_sync_native.sh",
    "descriptor_check":   "{server}/scripts/linux/check_server_descriptor.sh",
    "map_prepare":        "{server}/scripts/lessons/prepare_frame_sync.py",
    # 发布包只带运行期入口与管理依赖，不带构建入口；入口会被安装到 server/run_server.sh。
    "release_runner":     "{server}/scripts/linux/run_frame_server.sh",
    "process_manager":    "{server}/scripts/lessons/manage_lesson_processes.sh",
    # stop/restart 通过这对现有 shutdownctl 配置和 Service 优雅关闭 Battle/Gateway。
    "shutdownctl_config": "{config}/shutdownctl_process.lua",
    "shutdownctl_service":"{server}/service/admin/shutdownctl.lua",
    "shutdown_coordinator":"{server}/service/admin/lesson3_shutdown_coordinator.lua",

}

# 配置名也用于启动命令/README/验证，不在验证脚本另存一份。
# 元组按启动顺序排列：Gateway 必须在 Battle READY 后启动。
PROCESSES = (
    ("battle", "{battle_process}", "FRAME_BATTLE_READY"),
    ("gateway", "{gateway_process}", "FRAME_GATEWAY_READY"),
)

# 仅解压验收副本使用这些端口；正式包端口配置保持不变。
# gateway_port 属于 gateway_frame_sync.lua；两个 *_address 属于 frame_sync.lua 的 Cluster。
# 验证器同时用 gateway_port 配置客户端 PORT，并在启动前检查所有测试端口空闲。
VERIFY_PORTS = {
    "gateway_port": 29021,
    "gateway_address": 3537,
    "battle_address": 3538,
}
# 临时解包验收还会启动两个 debug_console；使用独立端口，不碰开发/用户进程端口。
VERIFY_DEBUG_CONSOLE_PORTS = {
    "battle": 38003,
    "gateway": 38002,
}
STARTUP_TIMEOUT_SECONDS = 25
CLIENT_TIMEOUT_SECONDS = 30
STOP_TIMEOUT_SECONDS = 5


# 开发进程配置中已有的 Native 搜索项；它们描述源码配置基线，不是本次构建输出。
# 只改 frame_build 或 native_release 时不改此表；只有开发 Lua 配置自身迁移时才同步这里。
DEVELOPMENT_NATIVE_SEARCHES = {
    "frame": "./build/frame_sync/?.so;",
    "flywow": "./third_party/skynet-flywow/build/native/?.so",
    "project": "./luaclib/?.so",
}


# ==================== 维护区 2：发布文件白名单 ====================
# 每项是 (源码路径或 glob, 包内目标路径)：
# - 目标为 None：保留仓库相对路径；**/*.lua 递归收集 Lua，*.so 只取一层。
# - 目标为字符串：复制单个文件并改放置位置，不能用于 glob。
# - 新增一个模块时，将它的 Lua/配置/Native 各自加入；不复制整个 build/。
# 任一规则没有匹配、来源缺失、目标冲突或逃出包目录都会失败，避免漏包仍报成功。
RELEASE_FILES = (
    # 宿主当前帧同步服务及普通模块；不带状态同步或其它课的服务入口。
    ("{battle_service}/**/*.lua", None),
    ("{gateway_service}/**/*.lua", None),
    ("{frame_lualib}/**/*.lua", None),
    ("{frame_registry}", None),
    ("{credentials}", None),  # Worker 无条件加载的会话凭据模块。
    ("{debug_switch}", None),  # Gateway 无条件 require；不交付 LuaPanda 本体。

    # 配置只列出运行需要的文件；Profile 子目录保留已有配置加载关系。
    ("{battle_process}", None),
    ("{gateway_process}", None),
    ("{frame_config}", None),
    # 运行期关闭依赖：包内入口复用项目统一 manager 与 shutdownctl，不另实现进程控制。
    ("{shutdownctl_config}", None),
    ("{shutdownctl_service}", None),
    ("{shutdown_coordinator}", None),
    ("{process_manager}", None),
    # 独立用户入口安装在 Server 根目录，方便从发布包根目录执行 ./server/run_server.sh。
    ("{release_runner}", "{server}/run_server.sh"),
    ("{config}/gateway_frame_sync.lua", None),
    ("{config}/frame_sync_asset.lua", None),
    ("{config}/unit_profiles.lua", None),
    ("{config}/navigation_profiles.lua", None),
    ("{config}/unit_profiles/**/*.lua", None),
    ("{config}/navigation_profiles/**/*.lua", None),

    # Skynet 框架 Runtime；其自带 C Service 与 Lua Native 不迁到项目目录。
    ("{skynet}/service/**/*.lua", None),
    ("{skynet}/lualib/**/*.lua", None),
    ("{skynet}/cservice/*.so", None),
    ("{skynet}/luaclib/*.so", None),
    ("{skynet_executable}", None),
    ("{skynet}/LICENSE", None),
    ("{protobuf_runtime}/pb.so", None),

    # FlyWow 运行 Lua；保留公开 require 路径，不复制 Native 中间目录。
    ("{flywow}/gateway/service/**/*.lua", None),
    ("{flywow}/gateway/lualib/**/*.lua", None),
    ("{flywow}/logger/lualib/**/*.lua", None),
    ("{flywow}/navigation/lualib/**/*.lua", None),

    # 项目 Native 的来源与发布目的地明确配对；Core 必须与 Binding 相邻。
    ("{frame_build}/lesson_frame_native.so", "{native_release}/lesson_frame_native.so"),
    ("{frame_build}/libframe_core.so", "{native_release}/libframe_core.so"),
    ("{flywow_native}/flywow_gateway_crypto.so", "{native_release}/flywow_gateway_crypto.so"),
    ("{flywow_native}/flywow_logger.so", "{native_release}/flywow_logger.so"),

    # 正式地图与完整统一协议；不使用无后缀过滤的目录复制。
    ("{map}", None),
    ("{map_manifest}", None),
    ("{protocol_generated}/lesson_03_frame_sync.pb", None),
    ("{protocol_generated}/lesson_03_frame_sync.pb.sha256", None),
    ("{protocol_generated}/lesson_03_frame_sync.source.sha256", None),
)

# 只用于来源追踪，不会把这些源码放进包；实际发布文件另外逐个计算 hash。
SOURCE_TREES = ("{frame_source}", "{flywow}", "{skynet}", "{protobuf_source}")
SOURCE_SUFFIXES = (".cpp", ".h", ".hpp", ".c", ".lua", ".txt", ".sh", ".mk")
EXCLUDED_PARTS = {"build", ".git", "__pycache__"}
MANIFEST_NAME = "release_manifest.json"


def repository_root():
    """从脚本向上找主仓库，不依赖 cwd；找不到显式失败，不误用另一个工作区。"""
    for parent in Path(__file__).resolve().parents:
        if (parent / "AGENTS.md").is_file() and (parent / ".git").is_dir():
            return parent
    raise RuntimeError("找不到含 AGENTS.md 与 .git/ 的主仓库")


ROOT = repository_root()
# 模板只在这里展开一次，后续打包/验证共用同一组路径。
for key, value in PATHS.items():
    PATHS[key] = value.format_map(PATHS)


def relative_path(template):
    """展开仓库相对路径；禁止绝对路径和 ..，同一规则也用于包内目标。"""
    path = Path(template.format_map(PATHS))
    if path.is_absolute() or ".." in path.parts:
        raise ValueError("路径必须位于仓库或发布包内：" + str(path))
    return path


def source_path(template):
    """得到 WSL 编辑源中的绝对路径；不读取 Windows 工作区。"""
    return ROOT / relative_path(template)


def server_relative(template):
    """转换成以包内 server/ 为 cwd 的 POSIX 路径，供命令与 Lua 搜索路径使用。"""
    return relative_path(template).relative_to(relative_path("{server}")).as_posix()


def run(*args, env=None):
    """同步调用现有工具，cwd 固定为 Server；非零退出立即停止后续打包。

    env 为该子进程的完整环境；None 表示继承。这里只编排已安装工具，不下载或调用 Git。
    """
    subprocess.run(args, cwd=source_path("{server}"), env=env, check=True)


def digest(path):
    """流式计算文件 SHA256；异常向上传播，避免对缺失文件生成假 hash。"""
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()


def head(git_dir):
    """只读 SHA1 Git 元数据解析 HEAD，支持 detached、松散及 packed refs。

    不执行 Git 命令；本脚本面向当前普通 checkout，不支持 .git 为文件的 linked worktree。
    返回值仅作版本追踪；未提交文件由 source_files/files 的实际内容 hash 记录。
    """
    value = (git_dir / "HEAD").read_text(encoding="utf-8").strip()
    if not value.startswith("ref: "):
        return value
    ref = value[5:]
    if (git_dir / ref).exists():
        return (git_dir / ref).read_text(encoding="utf-8").strip()
    packed = git_dir / "packed-refs"
    if packed.is_file():
        for line in packed.read_text(encoding="utf-8").splitlines():
            if line.endswith(" " + ref):
                return line.split()[0]
    raise RuntimeError("无法解析 HEAD：" + str(git_dir))


def pinned_flywow():
    """读取主仓库索引中的 FlyWow gitlink，区别于子模块实际 HEAD。

    当前仓库使用 SHA1 index v2/v3；其它格式显式拒绝，不推测固定版本。
    该函数只读 index，不修改暂存区，也不执行 Git。
    """
    data = (ROOT / ".git/index").read_bytes()
    magic, version, count = struct.unpack_from(">4sII", data)
    if magic != b"DIRC" or version not in (2, 3):
        raise RuntimeError("需要 SHA1 Git index v2/v3")
    offset = 12  # Header：4 字节签名、4 字节版本、4 字节条目数。
    for _ in range(count):
        start = offset
        # 标准条目固定区：mode 位于 24，SHA1 位于 40..59，flags 位于 60..61。
        mode = struct.unpack_from(">I", data, offset + 24)[0]
        oid = data[offset + 40:offset + 60].hex()
        flags = struct.unpack_from(">H", data, offset + 60)[0]
        # v3 extended flag 表示另有 2 字节扩展标记；它不属于文件名。
        offset += 62 + (2 if flags & 0x4000 else 0)
        end = data.index(0, offset)
        name = data[offset:end].decode("utf-8")
        # 文件名以 NUL 结束，整个条目从 start 起补齐到 8 字节边界。
        offset = start + ((end + 1 - start + 7) // 8) * 8
        if name == relative_path("{flywow}").as_posix() and mode == 0o160000:
            return oid  # 160000 是 gitlink 类型，oid 是子模块固定提交。
    raise RuntimeError("索引中缺少 FlyWow gitlink")


def build_runtime():
    """串行复用现有构建链并验证协议；失败不会生成新归档。

    PATHS 中 frame_build/frame_source 是发布流程选定值，通过已有 FRAME_SYNC_*
    覆盖项传给 Native 构建入口，避免改了复制路径却仍从旧目录构建。
    其它构建入口内部仍遵循所属模块合同；移动真实模块时须同步其自身路径。
    """
    # 显式调用帧同步专属协议入口；它只生成帧同步 descriptor 与 Registry。
    run("bash", str(source_path("{protocol_builder}")))
    generated = source_path("{protocol_generated}")
    descriptor = generated / "lesson_03_frame_sync.pb"
    checksum = generated / "lesson_03_frame_sync.pb.sha256"
    if not descriptor.is_file() or digest(descriptor) != checksum.read_text(
        encoding="utf-8"
    ).split()[0]:
        raise RuntimeError("帧同步 descriptor hash 不匹配：" + str(descriptor))

    run("bash", str(source_path("{skynet_builder}")))
    run("bash", str(source_path("{protobuf_builder}")))
    run("bash", str(source_path("{flywow_builder}")), str(source_path("{skynet}")), "logger")
    build_env = dict(os.environ)
    build_env.update({
        "FRAME_SYNC_SOURCE_DIR": str(source_path("{frame_source}")),
        "FRAME_SYNC_BUILD_DIR": str(source_path("{frame_build}")),
        "FRAME_SYNC_BUILD_TYPE": "Release",
        "FRAME_SYNC_LUA": "ON",
    })
    run("bash", str(source_path("{frame_builder}")), env=build_env)
    run("ctest", "--test-dir", str(source_path("{frame_build}")), "--output-on-failure")
    run("bash", str(source_path("{descriptor_check}")), "lesson_03_frame_sync")
    run(sys.executable, str(source_path("{map_prepare}")))
    # Registry 与 descriptor 已由同一个课程协议构建脚本生成；此处只验证输出存在。
    if not source_path("{frame_registry}").is_file():
        raise RuntimeError("帧同步 Registry 缺失：" + str(source_path("{frame_registry}")) )


def stage_files(stage):
    """按白名单复制文件到临时包根，返回实际来源文件的 hash 映射。

    每条 glob 必须至少匹配一个文件；不允许隐式覆盖、符号链接或开发缓存。
    stage 由 main 创建并持有；临时目录退出时清理，源码从不移动或删除。
    """
    copied = set()
    source_hashes = {}
    for source_template, destination_template in RELEASE_FILES:
        pattern = relative_path(source_template)
        matches = sorted(p for p in ROOT.glob(pattern.as_posix()) if p.is_file())
        if not matches:
            raise RuntimeError("发布规则没有匹配文件：" + str(pattern))
        if destination_template is not None and len(matches) != 1:
            raise RuntimeError("指定目标的规则必须是单文件：" + str(pattern))
        for source in matches:
            relative = source.relative_to(ROOT)
            if source.is_symlink() or EXCLUDED_PARTS.intersection(relative.parts):
                # build 是 Native 明确列出的合法来源，不能出现在保留原路径的复制规则中。
                if source.is_symlink() or destination_template is None:
                    raise RuntimeError("禁止发布链接/缓存目录：" + str(relative))
            destination = relative_path(destination_template) if destination_template else relative
            if destination in copied:
                raise RuntimeError("发布目标重复：" + str(destination))
            target = stage / destination
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
            copied.add(destination)
            source_hashes[relative.as_posix()] = digest(source)
    return source_hashes


def configure_release(stage):
    """只修改暂存副本的 Native 搜索路径，并生成部署 README。

    Lua 搜索路径以 Server cwd 为基准；保留原有 Lua/Skynet 路径，只替换两个
    开发 Native 目录。替换源来自当前开发配置的固定基线，目标来自 PATHS。
    若配置基线变化则失败，要求维护者核对，不能静默发布未生效的路径。
    """
    native_path = "./" + server_relative("{native_release}") + "/?.so"
    for role, template, _ in PROCESSES:
        config = stage / relative_path(template)
        text = config.read_text(encoding="utf-8")
        old_flywow = DEVELOPMENT_NATIVE_SEARCHES["flywow"]
        if old_flywow not in text:
            raise RuntimeError("进程配置 Native 路径基线已变化：" + role)
        text = text.replace(old_flywow, native_path)
        old_frame = DEVELOPMENT_NATIVE_SEARCHES["frame"]
        if role == "battle":
            if old_frame not in text:
                raise RuntimeError("Battle Native 路径基线已变化")
            text = text.replace(old_frame, "")
        # Native 目标目录可调整；同时更新配置已有的项目 luaclib 搜索项。
        text = text.replace(DEVELOPMENT_NATIVE_SEARCHES["project"], native_path)
        config.write_text(text, encoding="utf-8")

    conf = (stage / relative_path("{frame_config}")).read_text(encoding="utf-8")
    if not re.search(r'^\s*airnav_path\s*=\s*""\s*[,;]', conf, re.MULTILINE):
        raise RuntimeError("本入口仅支持明确 BMAP-only 配置")
    # 地图路径若被改动，要求正式配置与白名单一致；不改写玩法配置以掩盖错误。
    expected_map = os.path.relpath(relative_path("{map}"), relative_path("{server}"))
    if not re.search(r'map_path\s*=\s*"' + re.escape(expected_map) + r'"', conf):
        raise RuntimeError("frame_sync.lua 的 map_path 与 PATHS[map] 不一致")
    (stage / relative_path("{logs}")).mkdir(parents=True, exist_ok=True)
    (stage / "README.txt").write_text(
        "第三课帧同步 Linux Server；BMAP-only，Unity 单独交付。\n\n"
        "从解压目录执行以下命令（需要在 Linux/WSL 中运行）：\n"
        "  ./server/run_server.sh start    后台启动 Battle；READY 后再启动 Gateway\n"
        "  ./server/run_server.sh status   查看 Battle/Gateway 状态\n"
        "  ./server/run_server.sh stop     通过 shutdownctl 优雅停止 Gateway，再停止 Battle\n"
        "  ./server/run_server.sh restart  按上述顺序停止并重新启动\n"
        "  ./server/run_server.sh doctor   检查 Skynet、配置和关闭控制依赖\n\n"
        "首次部署不需要执行 prepare 或 build：打包时已经准备发布资产并构建 Native 运行依赖。\n"
        "进程 PID 文件位于 server/run/lesson3_frame_sync/；标准输出诊断日志位于 "
        "server/logs/lesson3_frame_sync/；FlyWow 业务日志分别位于 server/logs/frame_battle/ 与 server/logs/frame_gateway/。\n"
        "Battle/Cluster 配置见 " + server_relative("{frame_config}") + "；Gateway 监听配置见 "
        + server_relative("{config}/gateway_frame_sync.lua") + "。\n"
        "系统依赖见 release_manifest.json；不包含编译工具、LuaPanda或测试客户端。\n",
        encoding="utf-8",
    )


def verify(stage):
    """精确比较包内文件集合/hash，然后检查每个 ELF 的动态依赖。

    返回可写入 dependencies.txt 的 ldd 报告；缺失文件、多余文件、内容变化、
    未解析依赖或包外非系统库均抛出 RuntimeError。不启动 Server。
    仅用于可信的本仓库产物；清单是完整性记录，不是数字签名。
    """
    manifest_path = stage / MANIFEST_NAME
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    actual = {
        p.relative_to(stage).as_posix(): digest(p)
        for p in sorted(stage.rglob("*")) if p.is_file() and p != manifest_path
    }
    if actual != manifest["files"]:
        raise RuntimeError("发布清单不匹配")
    report = []
    for path in sorted(stage.rglob("*")):
        if not path.is_file():
            continue
        with path.open("rb") as stream:
            is_elf = stream.read(4) == b"\x7fELF"
        if not is_elf:
            continue
        result = subprocess.run(["ldd", str(path)], text=True, capture_output=True)
        output = result.stdout + result.stderr
        if result.returncode or "not found" in output:
            raise RuntimeError(str(path) + "\n" + output)
        for resolved in re.findall(r"=> (/\S+)", output):
            if not (resolved.startswith(str(stage) + "/") or
                    resolved.startswith(("/lib/", "/lib64/", "/usr/lib/"))):
                raise RuntimeError("包外非系统依赖：" + resolved)
        report.append(str(path.relative_to(stage)) + "\n" + output)
    return "\n".join(report)


def write_manifest(stage, version, source_hashes):
    """保存版本、实际来源与发布内容 hash，同时记录发布时使用的 Runtime 路径合同。

    source_hashes 先包含复制源，再补 Native/第三方源码与发布工具；源码只记录 hash，
    不进入 Runtime。runtime 字段随归档保存，验证旧包时不套用当前源码的新目录布局。
    """
    for template in SOURCE_TREES:
        for path in sorted(source_path(template).rglob("*")):
            relative = path.relative_to(ROOT)
            if (path.is_file() and not EXCLUDED_PARTS.intersection(relative.parts)
                    and path.suffix in SOURCE_SUFFIXES):
                source_hashes[relative.as_posix()] = digest(path)
    for path in (
        Path(__file__),
        Path(__file__).with_name("verify_frame_release.py"),
        source_path("{release_runner}"),
        source_path("{process_manager}"),
        source_path("{shutdownctl_config}"),
        source_path("{shutdownctl_service}"),
        source_path("{shutdown_coordinator}"),
        *sorted(source_path("{protocol_root}").glob("*.proto")),
    ):
        source_hashes[path.relative_to(ROOT).as_posix()] = digest(path)
    runtime = {
        "server": PATHS["server"],
        "executable": server_relative("{skynet_executable}"),
        "frame_config": server_relative("{frame_config}"),
        "gateway_config": server_relative("{config}/gateway_frame_sync.lua"),
        "manager": "run_server.sh",
        "run_directory": "run/lesson3_frame_sync",
        "capture_directory": "logs/lesson3_frame_sync",
        "processes": [
            {"role": role, "config": server_relative(template), "ready": marker}
            for role, template, marker in PROCESSES
        ],
    }
    manifest = {
        "version": version, "platform": platform.platform(), "architecture": platform.machine(),
        "source_head": head(ROOT / ".git"),
        "flywow_pinned_index": pinned_flywow(),
        "flywow_head": head(ROOT / ".git/modules" / relative_path("{flywow}")),
        "source_note": "工作树构建；HEAD 不代表未提交改动，以源码及发布文件 SHA256 为准",
        "source_files": dict(sorted(source_hashes.items())),
        "navigation": "BMAP-only",
        "system_dependencies": ["glibc", "libstdc++", "libgcc_s", "OpenSSL 3 (libcrypto.so.3)"],
        "runtime": runtime,
        "files": {
            p.relative_to(stage).as_posix(): digest(p)
            for p in sorted(stage.rglob("*")) if p.is_file()
        },
    }
    (stage / MANIFEST_NAME).write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8",
    )


def write_archive(stage, archive):
    """固定 tar/gzip 元数据并原子发布归档，失败清理本次 .tmp 文件。

    只给 Skynet 可执行文件与发布包 run_server.sh 入口保留执行权限，
    普通文件 0644、目录 0755；避免归档解压后入口无法直接运行。
    相同文件输入可稳定归档；不承诺跨编译器/系统得到相同 Native 二进制。
    """
    executable = relative_path("{skynet_executable}").as_posix()
    runtime_entry = (relative_path("{server}") / "run_server.sh").as_posix()
    executable_paths = {
        stage.name + "/" + executable,
        stage.name + "/" + runtime_entry,
    }
    def normalize(info):
        info.uid = info.gid = info.mtime = 0
        info.uname = info.gname = ""
        info.mode = 0o755 if info.isdir() or info.name in executable_paths else 0o644
        return info

    temporary = archive.with_suffix(".tmp")
    try:
        with temporary.open("xb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as zipped:
                with tarfile.open(fileobj=zipped, mode="w") as tar:
                    tar.add(stage, arcname=stage.name, filter=normalize)
        temporary.replace(archive)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    """校验参数 -> 构建 -> 白名单暂存 -> 配置/清单 -> 依赖检查 -> 归档；不启动服务。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", help="新版本号；字母/数字开头，仅允许字母数字、点、横线、下划线")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}", args.version):
        parser.error("非法版本")
    if platform.system() != "Linux":
        parser.error("必须在 Linux/WSL 编辑源执行")
    name = "lesson03-frame-server-" + args.version + "-linux-" + platform.machine()
    output = source_path("{output}")
    output.mkdir(parents=True, exist_ok=True)
    archive = output / (name + ".tar.gz")
    if archive.exists():
        raise SystemExit("版本包已存在，请使用新版本：" + str(archive))

    build_runtime()
    with tempfile.TemporaryDirectory(prefix="frame-release-") as work:
        stage = Path(work) / name
        stage.mkdir()
        source_hashes = stage_files(stage)
        configure_release(stage)
        write_manifest(stage, args.version, source_hashes)
        dependencies = verify(stage)
        (output / (name + ".dependencies.txt")).write_text(dependencies, encoding="utf-8")
        write_archive(stage, archive)
    checksum = digest(archive)
    archive.with_suffix(archive.suffix + ".sha256").write_text(
        checksum + "  " + archive.name + "\n", encoding="utf-8",
    )
    print("FRAME_RELEASE_OK", archive, checksum)


if __name__ == "__main__":
    main()
