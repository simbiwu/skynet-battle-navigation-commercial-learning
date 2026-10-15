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
proto = root / "shared/protocol/navigation_query.proto"
protoc = root / "server/third_party/protoc-36.2/bin/protoc"
if subprocess.check_output([str(protoc), "--version"], text=True).strip() != "libprotoc 36.2":
    raise SystemExit("PROTOC_VERSION")
subprocess.run([str(protoc), "-I" + str(proto.parent), "--include_imports",
    "--descriptor_set_out=" + str(proto.parent / "generated/server/navigation_query.pb"), str(proto)], check=True)
subprocess.run(["python3", str(root / "server/third_party/skynet-flywow/gateway/tools/generate_gateway_registry.py"),
    "--proto", str(proto), "--output", str(root / "server/lualib/gateway/protocol/navigation_registry.lua")], check=True)
if args.unity_output:
    assets = args.unity_output.resolve()
    if assets.name != "Assets" or assets.parent.name != "BattleNavigation":
        raise SystemExit("UNITY_OUTPUT_MUST_BE_PROJECT_ASSETS")
    target = assets / "BattleNavigation/Scripts/Protocol"
    target.mkdir(parents=True, exist_ok=True)
    subprocess.run([str(protoc), "-I" + str(proto.parent), "--csharp_out=" + str(target), str(proto)], check=True)
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
    checksum = hashlib.sha256((target / "NavigationQuery.cs").read_bytes()).hexdigest()
    out = assets.parents[2] / "shared/protocol/generated/unity/NavigationQuery.cs.sha256"
    # Windows Unity生成物校验属于Windows编辑源；不写Windows协议源码。
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(checksum + "\n")
print("STATE_PREPARE_OK", map_hash, digest.hexdigest())
