# 无request_id合同迁移后的帧同步真实双进程回归；仅回收本runner创建的进程。
from pathlib import Path
import subprocess
import time
import os
ROOT = Path(__file__).resolve().parents[1]
def main():
    os.chdir(ROOT)
    children, streams = [], []
    try:
        for role in ("battle", "gateway"):
            log = ROOT / "logs" / ("frame_migration_" + role + ".log")
            daily = ROOT / ("logs/frame_" + role) / (time.strftime("%Y-%m-%d") + ".log")
            offset = daily.stat().st_size if daily.exists() else 0
            stream = log.open("w"); streams.append(stream)
            child = subprocess.Popen(["third_party/skynet/skynet", "config/frame_" + role + "_process.lua"], stdout=stream, stderr=stream)
            children.append(child)
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if child.poll() is not None: raise RuntimeError(log.read_text())
                if daily.exists() and ("FRAME_" + role.upper() + "_READY") in daily.read_text()[offset:]: break
                time.sleep(.1)
            else: raise TimeoutError(role)
        subprocess.run(["python3", "tests/frame_sync_integration.py"], check=True, timeout=30)
    finally:
        for child in reversed(children):
            if child.poll() is None:
                child.terminate()
                try: child.wait(timeout=5)
                except subprocess.TimeoutExpired: child.kill(); child.wait()
        for stream in streams: stream.close()
if __name__ == "__main__": main()
