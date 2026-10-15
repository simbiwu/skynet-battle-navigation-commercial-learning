# 真实TCP握手/Gateway/Cluster/多Worker状态同步回归；仅终止本runner创建的子进程。
from pathlib import Path
import os
import socket
import subprocess
import time
from frame_sync_integration import Client as FrameClient, number, signed, binary, parse, first
from gateway_handshake_client import perform
ROOT = Path(__file__).resolve().parents[1]
JOIN, INPUT, CAST, PUSH, RECOVER, RESYNC, LEAVE, REPLAY = range(1201, 1209)
class Client(FrameClient):
    def __init__(self):
        self.socket = socket.create_connection(("127.0.0.1", 19031), timeout=3)
        self.socket.settimeout(4)
        perform(self.write_frame, self.read_frame)
        self.pushes = []
    def send(self, command, body):
        self.write_frame(number(1, 4) + number(2, command) + binary(3, body))
    def recv_envelope(self):
        value = parse(self.read_frame())
        assert first(value, 1) == 4 and 3 in value and 4 not in value
        return first(value, 2), parse(first(value, 3))
    def request(self, command, body):
        self.send(command, body)
        for _ in range(100):
            got, data = self.recv_envelope()
            if got == command: return data
            if got == PUSH: self.pushes.append(data)
        raise AssertionError("CONTROL_RESPONSE_LIMIT")
    def next_push(self):
        if self.pushes: return self.pushes.pop(0)
        while True:
            command, value = self.recv_envelope()
            if command == PUSH: return value

def wait_ready(path, marker, child):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if child.poll() is not None: raise RuntimeError(path.read_text(errors="replace"))
        if path.exists() and marker in path.read_text(errors="replace"): return
        time.sleep(.05)
    raise TimeoutError(marker)

def main():
    os.chdir(ROOT)
    logs = ROOT / "logs/state_sync_tests"
    logs.mkdir(parents=True, exist_ok=True)
    processes, streams, clients = [], [], []
    try:
        for role in ("battle", "gateway"):
            log = logs / (role + ".log")
            stream = log.open("w")
            streams.append(stream)
            marker_path = ROOT / ("logs/state_" + role) / (time.strftime("%Y-%m-%d") + ".log")
            marker_offset = marker_path.stat().st_size if marker_path.exists() else 0
            child = subprocess.Popen(["third_party/skynet/skynet", "config/state_" + role + "_process.lua"],
                stdout=stream, stderr=stream)
            processes.append(child)
            # Logger自身文件记录READY，stdout仅作为启动崩溃诊断。
            marker_path = ROOT / ("logs/state_" + role) / (time.strftime("%Y-%m-%d") + ".log")
            started = time.monotonic()
            while time.monotonic() - started < 10:
                if child.poll() is not None: raise RuntimeError(log.read_text(errors="replace"))
                if marker_path.exists() and ("STATE_" + role.upper() + "_READY") in marker_path.read_text(errors="replace")[marker_offset:]:
                    break
                time.sleep(.1)
            else: raise TimeoutError("STATE_" + role.upper() + "_READY")
        a = Client(); clients.append(a)
        join = a.request(JOIN, number(1, 1001) + number(2, 1))
        assert first(join, 1) == b"OK", join
        battle, generation, token = first(join, 2), first(join, 3), first(join, 4)
        assert first(join, 9) == 60 and first(join, 10) == 20
        initial = parse(first(join, 12))
        first_tick = first(initial, 3, 0)
        b = Client(); clients.append(b)
        other = b.request(JOIN, number(1, 1001) + number(2, 1))
        assert first(other, 2) != battle
        bad = b.request(RECOVER, number(1, battle) + binary(2, b"invalid"))
        assert first(parse(first(bad, 1)), 1) == b"NOT_FOUND"
        for seq in range(1, 9):
            inp = number(1, seq) + signed(2, 1) + signed(3, 0)
            result = a.request(INPUT, number(1, battle) + number(2, generation) + binary(3, inp))
            assert first(result, 1) == b"OK", result
        state = None
        for _ in range(40):
            push = a.next_push()
            assert first(push, 1) == battle and first(push, 2) == generation
            if 4 in push:
                state = parse(first(push, 4))
                if first(state, 4, 0) == 8: break
        assert state and first(state, 4, 0) == 8
        assert first(state, 3) > first_tick
        cast_body = number(1, battle) + number(2, generation) + number(3, 1) + number(4, 1) + number(5, 2001)
        cast = a.request(CAST, cast_body)
        assert first(cast, 1) == b"QUEUED" and first(cast, 2) == 1
        conflict = a.request(CAST, number(1, battle) + number(2, generation) + number(3, 1) + number(4, 2) + number(5, 2001))
        assert first(conflict, 1) == b"CONFLICT"
        restored = b.request(RECOVER, number(1, battle) + binary(2, token))
        restored = parse(first(restored, 1))
        assert first(restored, 1) == b"OK" and first(restored, 3) == generation + 1
        old = a.request(RESYNC, number(1, battle) + number(2, generation))
        assert first(old, 2) == b"NOT_FOUND"
        full = b.request(RESYNC, number(1, battle) + number(2, generation + 1))
        assert first(full, 2) == b"OK" and first(parse(first(full, 1)), 2, 0) == 0
        replay = b.request(REPLAY, number(1, battle) + binary(2, first(restored, 4)) + number(3, 0))
        assert first(replay, 1) == b"OK" and first(replay, 2, 0) > 0
        initial_record = parse(first(replay, 3))
        assert not first(initial_record, 4, b""), "Replay must never include resume credential"
        leave = b.request(LEAVE, number(1, battle) + number(2, generation + 1))
        assert first(leave, 1) == b"OK"
        print("STATE_TCP_INTEGRATION_OK battle=%d consumed=8 generation=%d" % (battle, generation + 1))
        if "--network" in __import__("sys").argv:
            subprocess.run(["python3", "tests/state_sync_network.py"], check=True, timeout=45)
    finally:
        for client in clients: client.close()
        for child in reversed(processes):
            if child.poll() is None:
                child.terminate()
                try: child.wait(timeout=5)
                except subprocess.TimeoutExpired: child.kill(); child.wait()
        for stream in streams: stream.close()
if __name__ == "__main__": main()
