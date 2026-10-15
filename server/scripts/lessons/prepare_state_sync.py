# 验证唯一配置源与发布资产，生成状态同步身份及协议产物。
# --unity-output仅写Unity所属产物；源码留在WSL，禁止复制完整工作区。
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import subprocess
root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument("--unity-output", type=Path)
args = parser.parse_args()
config = root / "server/config"
paths = [config / "state_sync.lua", config / "unit_profiles.lua", config / "navigation_profiles.lua"]
for directory in ("unit_profiles", "navigation_profiles"):
    paths.extend(sorted((config / directory).glob("*.lua")))
digest = hashlib.sha256()
for path in paths:
    digest.update(str(path.relative_to(root)).encode() + b"\0" + path.read_bytes())
asset = root / "shared/navigation/battle_1001"
manifest = json.loads((asset / "battle_1001.manifest.json").read_text())
map_hash = hashlib.sha256((asset / "battle_1001.bmap").read_bytes()).hexdigest()
if manifest["content_sha256"] != map_hash:
    raise SystemExit("MAP_HASH_MISMATCH")
(config / "state_sync_asset.lua").write_text(
    '--- 构建验证的资产与配置身份；禁止手工修改。\nreturn\n{\n'
    f'    map_id = {manifest["map_id"]},\n    map_version = {manifest["map_version"]},\n'
    f'    map_hash = "{map_hash}",\n    config_hash = "{digest.hexdigest()}",\n}}\n')
protocol_root = root / "shared/protocol"
# 状态同步 Unity 源码只从公共 Envelope 和第三课状态同步 schema 生成。
proto_files = [
    protocol_root / "wire_header.proto",
    protocol_root / "lesson_03/state_sync.proto",
]
protoc = root / "server/third_party/protoc-36.2/bin/protoc"
if subprocess.check_output([str(protoc), "--version"], text=True).strip() != "libprotoc 36.2":
    raise SystemExit("PROTOC_VERSION")
# 协议构建入口一次只写状态同步 descriptor 与 Registry。
subprocess.run([str(root / "server/protocol/build_protocol_lesson_03_state_sync.sh")], check=True)
subprocess.run([str(root / "server/scripts/linux/check_server_descriptor.sh"),
    "lesson_03_state_sync"], check=True)
if args.unity_output:
    assets = args.unity_output.resolve()
    if assets.name != "Assets" or assets.parent.name != "BattleNavigation":
        raise SystemExit("UNITY_OUTPUT_MUST_BE_PROJECT_ASSETS")
    target = assets / "BattleNavigation/Scripts/Protocol"
    target.mkdir(parents=True, exist_ok=True)
    subprocess.run([str(protoc), "-I" + str(protocol_root), "--csharp_out=" + str(target),
        *map(str, proto_files)], check=True)
    streaming = assets / "StreamingAssets"
    for path in paths:
        if path.name == "state_sync.lua":
            continue  # Client只读移动配置，不加载Server运行配置。
        destination = streaming / "config/config" / path.relative_to(config)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, destination)
    (streaming / "state_sync_config.sha256").write_text(digest.hexdigest() + "\n")
    destination = streaming / "navigation/battle_1001.bmap"
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.exists() or hashlib.sha256(destination.read_bytes()).hexdigest() != map_hash:
        raise SystemExit("UNITY_MAP_REQUIRES_EXISTING_MATCHING_PUBLISHED_ASSET")
    checksum_dir = assets.parents[2] / "shared/protocol/generated/unity"
    checksum_dir.mkdir(parents=True, exist_ok=True)
    for proto_file in proto_files:
        name = "".join(part[:1].upper() + part[1:] for part in proto_file.stem.split("_")) + ".cs"
        generated = target / name
        checksum = hashlib.sha256(generated.read_bytes()).hexdigest()
        (checksum_dir / (name + ".sha256")).write_text(f"{checksum}  {name}\n")
    legacy = target / "NavigationQuery.cs"
    if legacy.exists():
        legacy.unlink()
    old_checksum = checksum_dir / "NavigationQuery.cs.sha256"
    if old_checksum.exists():
        old_checksum.unlink()
print("STATE_PREPARE_OK", map_hash, digest.hexdigest())
