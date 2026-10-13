# 职责：验证发布 BMAP 的 SHA256，生成课程所需的只读地图元数据。
# 调用：在 server 目录执行 python3 scripts/lessons/prepare_frame_sync.py。
# 不负责：Native源码版本Hash、Skynet启动、Git操作。
from pathlib import Path
import hashlib
import json

root     = Path(__file__).resolve().parents[3]
asset    = root / "shared/navigation/battle_1001"
manifest = json.loads((asset / "battle_1001.manifest.json").read_text(encoding="utf-8"))
digest   = hashlib.sha256((asset / "battle_1001.bmap").read_bytes()).hexdigest()

if digest != manifest["content_sha256"]:
    raise SystemExit("MAP_HASH_MISMATCH")

target = root / "server/config/frame_sync_asset.lua"
target.write_text(
    "--- 构建生成的已验证地图身份；不要手改。\n"
    'return { map_id = %d, map_version = %d, map_hash = "%s" }\n' %
    (manifest["map_id"], manifest["map_version"], digest),
    encoding="utf-8",
)
print("FRAME_ASSET_OK", digest)
