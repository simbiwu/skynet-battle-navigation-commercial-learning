# 同时启动本次专属Server并调用Windows团结引擎真实Play；仅回收自己创建的进程。
from pathlib import Path
import argparse
import subprocess
import time
import os
ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--editor", required=True)
parser.add_argument("--project", required=True)
parser.add_argument("--log", required=True)
args = parser.parse_args()
def windows_path(value):
    return subprocess.check_output(["wslpath", "-w", str(Path(value).resolve())], text=True).strip()
os.chdir(ROOT)
processes, streams = [], []
try:
    run = str(time.time_ns())
    for role in ("battle", "gateway"):
        directory = ROOT / "logs" / ("state_unity_" + role + "_" + run)
        directory.mkdir(parents=True)
        source = (ROOT / ("config/state_" + role + "_process.lua")).read_text()
        source = source.replace("./logs/state_" + role, str(directory))
        config = directory / "process.lua"
        config.write_text(source)
        stream = (directory / "stdout.log").open("w")
        streams.append(stream)
        process = subprocess.Popen(["third_party/skynet/skynet", str(config)], stdout=stream, stderr=stream)
        processes.append(process)
        until = time.monotonic() + 10
        while time.monotonic() < until:
            if process.poll() is not None: raise RuntimeError((directory / "stdout.log").read_text())
            if any(("STATE_" + role.upper() + "_READY") in p.read_text() for p in directory.glob("20*.log")): break
            time.sleep(.1)
        else: raise TimeoutError(role)
    result = subprocess.run([args.editor, "-batchmode", "-nographics", "-projectPath", windows_path(args.project),
        "-executeMethod", "BattleNavigation.Client.Editor.StateBattlePlayVerification.Run", "-logFile", windows_path(args.log)], timeout=120)
    print("UNITY_PLAY_EXIT", result.returncode)
    raise SystemExit(result.returncode)
finally:
    for process in reversed(processes):
        if process.poll() is None:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
    for stream in streams: stream.close()
