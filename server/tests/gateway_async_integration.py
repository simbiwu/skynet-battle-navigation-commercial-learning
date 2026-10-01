# 职责：在真实 pinned Skynet、Protobuf、TCP/WS 和 Cluster 中回归异步 Gateway。
# 边界：Integration Test；只启动并终止本 runner 创建的进程，不接管已有 Server。
# 输入/输出：FLYWOW_ROOT -> 延迟/乱序/推送/协议错误/断线及实际课程请求断言。
# 生命周期：日志写 server/logs/gateway_async_tests；每个进程 finally 中 TERM/等待，超时仅 KILL 自己的子进程。
# 不负责：不下载依赖、不生成地图，不把此聚焦回归宣称为容量或长期稳定性测试。
import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
import os
from pathlib import Path
import socket
import struct
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


# 编码正整数 varint；测试只构造本协议中的有限编号，不依赖额外 Python protobuf 包。
def varint(value):
    out = bytearray()
    while value > 127:
        out.append((value & 127) | 128)
        value >>= 7
    out.append(value)
    return bytes(out)


# 构造 varint 字段；字段编号和值由测试用例提供，返回新 bytes。
def number(field, value):
    return varint(field << 3) + varint(value)


# 构造 length-delimited 字段；body 为调用方拥有的 bytes。
def blob(field, body):
    return varint((field << 3) | 2) + varint(len(body)) + body


# 解析测试关心的 protobuf 字段；不支持的 wire type 显式失败，不用于 Runtime。
def fields(data):
    offset = 0
    result = {}

    # 从局部游标读取一个有界 varint；损坏字节显式断言失败。
    def read_integer():
        nonlocal offset
        value = 0
        for shift in range(0, 70, 7):
            assert offset < len(data), "truncated varint"
            byte = data[offset]
            offset += 1
            value |= (byte & 127) << shift
            if byte < 128:
                return value
        raise AssertionError("oversized varint")

    while offset < len(data):
        key = read_integer()
        field, wire = key >> 3, key & 7
        if wire == 0:
            result[field] = read_integer()
        elif wire == 2:
            size = read_integer()
            assert offset + size <= len(data), "truncated bytes"
            result[field] = data[offset:offset + size]
            offset += size
        else:
            raise AssertionError("unexpected wire type")
    return result


# 构造 QueryCell 或 RunAutoBattle Envelope，request_id 与协议版本均显式可覆盖。
def envelope(request_id, command=1001, version=3):
    body = number(1, 1001)
    if command == 1001:
        body += number(2, 1) + blob(3, b"")
    return number(1, version) + number(2, command) + number(3, request_id) + blob(4, body)


# 从当前 Socket 读满指定字节；EOF 是失败，不把短读当成完整帧。
def exact(sock, size):
    out = bytearray()
    while len(out) < size:
        part = sock.recv(size - len(out))
        if not part:
            raise EOFError("socket closed")
        out.extend(part)
    return bytes(out)


class Client:
    # 建立专用测试连接；WS 使用真实 HTTP Upgrade 和 mask，TCP 使用 uint16 长度头。
    def __init__(self, port, websocket=False):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=3)
        self.ws = websocket
        if websocket:
            key = base64.b64encode(b"0123456789abcdef").decode()
            request = (f"GET / HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\n"
                       f"Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\n\r\n")
            self.sock.sendall(request.encode())
            header = bytearray()
            while not header.endswith(b"\r\n\r\n"):
                header.extend(exact(self.sock, 1))
                assert len(header) < 8192
            accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
            assert b"101" in header.split(b"\r\n")[0] and accept in header

    # 发送一条完整协议消息；fragment=True 模拟 TCP 半包或 WS binary continuation。
    def send(self, payload, fragment=False):
        if not self.ws:
            frame = struct.pack(">H", len(payload)) + payload
            if fragment:
                self.sock.sendall(frame[:1])
                time.sleep(0.01)
                self.sock.sendall(frame[1:3])
                time.sleep(0.01)
                self.sock.sendall(frame[3:])
            else:
                self.sock.sendall(frame)
            return
        if fragment:
            self.send_ws(payload[:3], opcode=2, final=False)
            self.send_ws(payload[3:], opcode=0)
        else:
            self.send_ws(payload)

    # 发送客户端 mask frame；长度最大 uint16，测试无需超大分配。
    def send_ws(self, payload, opcode=2, final=True):
        mask = b"abcd"
        header = bytes([(128 if final else 0) | opcode])
        if len(payload) < 126:
            header += bytes([128 | len(payload)])
        else:
            header += bytes([128 | 126]) + struct.pack(">H", len(payload))
        masked = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
        self.sock.sendall(header + mask + masked)

    # 读取并解析一个服务端 Envelope；close frame 转为 EOF。
    def receive(self):
        if self.ws:
            first, second = exact(self.sock, 2)
            if first & 15 == 8:
                raise EOFError("websocket closed")
            assert first == 130 and second & 128 == 0
            size = second & 127
            if size == 126:
                size = struct.unpack(">H", exact(self.sock, 2))[0]
            if size == 127:
                size = struct.unpack(">Q", exact(self.sock, 8))[0]
        else:
            size = struct.unpack(">H", exact(self.sock, 2))[0]
        result = fields(exact(self.sock, size))
        assert result[1] == 3
        return result

    # 释放调用方独占的测试连接。
    def close(self):
        self.sock.close()


class Processes:
    # 保存显式框架路径和自己创建的子进程；不读写部署 PID 文件。
    def __init__(self, flywow):
        self.env = dict(os.environ, FLYWOW_ROOT=str(flywow))
        self.children = []
        self.logs = ROOT / "logs/gateway_async_tests"
        self.logs.mkdir(parents=True, exist_ok=True)

    # 启动一个专用配置并等待 READY；日志/进程归本 runner，不覆盖正常 Server 日志。
    def start(self, name, config, ready, ports):
        for port in ports:
            with socket.socket() as probe:
                probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                probe.bind(("127.0.0.1", port))
                probe.listen(1)
        log = self.logs / (name + ".log")
        handle = log.open("w")
        child = subprocess.Popen([str(ROOT / "third_party/skynet/skynet"), str(ROOT / "config" / config)],
                                 cwd=ROOT, env=self.env, stdout=handle, stderr=subprocess.STDOUT)
        self.children.append((child, handle))
        until = time.monotonic() + 15
        while time.monotonic() < until:
            text = log.read_text()
            if ready in text:
                return
            assert child.poll() is None, text
            time.sleep(0.05)
        raise AssertionError("READY timeout: " + log.read_text())

    # 仅终止自己创建的进程；TERM 超时后 KILL 并等待，保证测试无遗留。
    def close(self):
        for child, handle in reversed(self.children):
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=5)
            handle.close()
        self.children.clear()


# 覆盖真实同连接延迟、乱序、业务失败、推送、编码失败和半包/fragment。
def smoke(websocket):
    port = 19022 if websocket else 19021
    client = Client(port, websocket)
    try:
        started = time.monotonic()
        client.send(envelope(1), fragment=True)
        client.send(envelope(2))
        second = client.receive()
        assert second[3] == 2, second
        assert client.receive()[3] == 1
        # uint64 高位在 Lua 中是负整数，协议位模式必须保持不变。
        client.send(envelope(0xFFFFFFFFFFFFFFFF))
        assert client.receive()[3] == 0xFFFFFFFFFFFFFFFF
        client.send(envelope(5))
        client.send(envelope(6))
        assert fields(client.receive()[4])[1] == 7
        assert client.receive()[3] == 6, "business failure must not stop next frame"
        client.send(envelope(3))
        client.send(envelope(4))
        assert client.receive()[3] == 4, "encoding failure must not close connection"
        assert client.receive().get(3, 0) == 0, "push must use reserved request_id=0"
    finally:
        client.close()
    old = Client(port, websocket)
    old.send(envelope(1))
    old.close()
    client = Client(port, websocket)
    try:
        client.send(envelope(2))
        assert client.receive()[3] == 2
        client.sock.settimeout(0.65)
        try:
            extra = client.receive()
            raise AssertionError("old connection reply leaked: " + str(extra))
        except socket.timeout:
            pass
    finally:
        client.close()
    # 业务主动断开；Gateway 关闭后新连接仍可查询。
    for request_id in (600, 601):
        client = Client(port, websocket)
        try:
            client.send(envelope(request_id))
            if request_id == 601:
                assert client.receive()[3] == 601
            try:
                client.receive()
                raise AssertionError("business close must disconnect client")
            except (EOFError, ConnectionResetError):
                pass
        finally:
            client.close()
    for payload in (envelope(7, command=9999), envelope(7, version=99), b"\xff", envelope(0)):
        client = Client(port, websocket)
        try:
            client.send(payload)
            try:
                client.receive()
                raise AssertionError("bad protocol must close")
            except (EOFError, ConnectionResetError):
                pass
        finally:
            client.close()
    print("REAL_WS_ASYNC_OK" if websocket else "REAL_TCP_ASYNC_OK")


# 验证真实 TCP 半包超时与入站超限；网络策略可以关闭该连接。
def limits():
    with socket.create_connection(("127.0.0.1", 19021), timeout=3) as sock:
        sock.sendall(b"\0")
        assert sock.recv(1) == b"", "partial header must time out"
    client = Client(19021)
    try:
        payload = envelope(8)
        packet = struct.pack(">H", len(payload)) + payload
        client.sock.sendall(packet * 220)
        try:
            while True:
                client.receive()
        except (EOFError, ConnectionResetError):
            pass
    finally:
        client.close()
    # 未握手 WS 连接也计入容量，不能通过慢握手绕过 max_clients。
    held = []
    try:
        for _ in range(8):
            held.append(socket.create_connection(("127.0.0.1", 19022), timeout=3))
        with socket.create_connection(("127.0.0.1", 19022), timeout=3) as rejected:
            assert rejected.recv(1) == b"", "pending WS handshake capacity must be bounded"
    finally:
        for sock in held:
            sock.close()
    print("REAL_NETWORK_LIMITS_OK")


# 实际课程 Query/RunAutoBattle 往返及同连接连续请求；不依赖测试 handler。
def course(port, battle):
    client = Client(port)
    try:
        for request_id in range(10, 20):
            client.send(envelope(request_id))
        responses = [client.receive() for _ in range(10)]
        assert {value[3] for value in responses} == set(range(10, 20))
        assert all(fields(value[4])[1] in (1, 4, 5) for value in responses), responses
        if battle:
            client.send(envelope(30, command=1002))
            client.send(envelope(31))
            responses = [client.receive(), client.receive()]
            assert {value[3] for value in responses} == {30, 31}
            result = next(value for value in responses if value[3] == 30)
            assert fields(result[4])[1] == 1, result
    finally:
        client.close()
    # 多连接同时查询，验证各连接的返回编号和归属。
    def query(index):
        connection = Client(port)
        try:
            connection.send(envelope(100 + index))
            assert connection.receive()[3] == 100 + index
        finally:
            connection.close()
    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(query, range(16)))
    print("REAL_CLUSTER_COURSE_OK" if battle else "REAL_LOCAL_COURSE_OK")


# 显式选择框架根目录；在每个场景 finally 回收子进程，任何失败返回非零退出码。
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--flywow-root", default=os.environ.get("FLYWOW_ROOT"))
    args = parser.parse_args()
    assert args.flywow_root, "显式提供 --flywow-root 或 FLYWOW_ROOT"
    processes = Processes(Path(args.flywow_root).resolve())
    try:
        processes.start("smoke", "skynet_gateway_async_smoke.lua", "GATEWAY_ASYNC_SMOKE_READY", [19021, 19022])
        smoke(False)
        smoke(True)
        limits()
        processes.close()
        processes.start("local", "skynet.lua", "NAV_SERVER_READY", [19001])
        course(19001, False)
        processes.close()
        processes.start("battle", "skynet_battle.lua", "LESSON2_BATTLE_PROCESS_READY", [2528])
        processes.start("gateway", "skynet_gateway.lua", "LESSON2_GATEWAY_PROCESS_READY", [19011, 2527])
        course(19011, True)
        # 终止自己创建的 Battle，验证两个请求均返回业务失败且 Gateway 保持可读。
        battle = processes.children[0][0]
        battle.terminate()
        battle.wait(timeout=5)
        client = Client(19011)
        try:
            client.sock.settimeout(12)
            started = time.monotonic()
            client.send(envelope(801))
            client.send(envelope(802))
            responses = [client.receive(), client.receive()]
            assert {value[3] for value in responses} == {801, 802}
            assert all(fields(value[4])[1] == 7 for value in responses)
            assert time.monotonic() - started < 12, "requests must expire independently"
        finally:
            client.close()
        print("REAL_CLUSTER_FAILURE_OK")
        processes.close()
        processes.start("close_battle", "skynet_gateway_close_battle_smoke.lua", "GATEWAY_CLOSE_BATTLE_SMOKE_READY", [2528])
        processes.start("close_gateway", "skynet_gateway.lua", "LESSON2_GATEWAY_PROCESS_READY", [19011, 2527])
        client = Client(19011)
        try:
            client.send(envelope(600))
            try:
                client.receive()
                raise AssertionError("remote business close must disconnect client")
            except (EOFError, ConnectionResetError):
                pass
        finally:
            client.close()
        client = Client(19011)
        try:
            client.send(envelope(602))
            assert client.receive()[3] == 602
        finally:
            client.close()
        print("REAL_CLUSTER_CLOSE_OK")
        print("GATEWAY_ASYNC_INTEGRATION_OK")
    finally:
        processes.close()


if __name__ == "__main__":
    main()
