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
from gateway_handshake_client import perform, hello, respond

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


# 构造当前Envelope；map_id仅在测试夹具中作为标记，真实Query使用1001。
def envelope(map_id=1001, command=1001, version=3):
    body = number(1, map_id)
    if command == 1001:
        body += number(2, 1) + blob(3, b"")
    return number(1, version) + number(2, command) + blob(3, body)


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
    def __init__(self, port, websocket=False, handshake=True):
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

        if handshake:
            try:
                perform(self.send, self.receive_bytes)
            except BaseException:
                self.close()
                raise

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
    def receive_bytes(self):
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
        return exact(self.sock, size)

    # 握手已完成后解析业务Envelope，不把握手包误解释为Protobuf。
    def receive(self):
        result = fields(self.receive_bytes())
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
        self.active_logs = []
        self.env["LUA_PANDA_ENABLE"] = "0"
        self.logs = ROOT / "logs/gateway_async_tests"
        self.logs.mkdir(parents=True, exist_ok=True)
        # 独立测试使用独立路径配置，不覆盖正常启动的 server/run 产物。
        paths_config = self.logs / "flywow_paths.lua"
        subprocess.run([
            "python3", str(flywow / "tools/module_paths.py"),
            "--root", str(flywow), "--modules", "gateway", "navigation",
            "--native", str(ROOT / "build/flywow_navigation/lua"),
            "--output", str(paths_config),
        ], check=True, timeout=10)
        self.env["FLYWOW_PATHS_CONFIG"] = str(paths_config)

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
        self.active_logs.append(log)
        until = time.monotonic() + 15
        while time.monotonic() < until:
            self.assert_clean(wait=False)
            text = log.read_text()
            if ready in text:
                return
            assert child.poll() is None, text
            time.sleep(0.05)
        raise AssertionError("READY timeout: " + log.read_text())

    # 客户端成功不能掩盖Service异常；编码拒绝等预期结构化日志不含Lua调用堆栈。
    def assert_clean(self, wait=True):
        if wait:
            time.sleep(0.1)
        for log in self.active_logs:
            text = log.read_text()
            assert "stack traceback:" not in text and "lua call [" not in text, text
        for child, _ in self.children:
            assert child.poll() is None, "test server exited"

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
        self.active_logs.clear()


# 验证同连接异步乱序、广播、业务/编码失败、主动关闭与跨断线迟到回包。
def response(client, marker=None, result=1):
    value = client.receive()
    assert value[2] == 1001, value
    body = fields(value[3])
    assert body[1] == result, body
    if marker is not None:
        assert body[3] == marker, body
    return body


def smoke(websocket):
    port = 19022 if websocket else 19021
    client = Client(port, websocket)
    try:
        client.send(envelope(1), fragment=True)
        client.send(envelope(2))
        response(client, 2)
        response(client, 1)
        client.send(envelope(0xFFFFFFFF))
        response(client, 0xFFFFFFFF)
        client.send(envelope(5))
        client.send(envelope(6))
        response(client, 5, result=7)
        response(client, 6)
        # 编码失败不会产生回包，也不能阻止下一条健康请求。
        client.send(envelope(3))
        client.send(envelope(7))
        response(client, 7)
        client.sock.settimeout(.1)
        try:
            client.receive()
            raise AssertionError("encoding failure must not produce a response")
        except socket.timeout:
            pass
    finally:
        client.close()
    first, second = Client(port, websocket), Client(port, websocket)
    try:
        first.send(envelope(4))
        response(first, 4)
        response(first, 400)
        response(second, 400)
    finally:
        first.close()
        second.close()
    old = Client(port, websocket)
    old.send(envelope(1))
    old.close()
    client = Client(port, websocket)
    try:
        client.send(envelope(2))
        response(client, 2)
        client.sock.settimeout(.65)
        try:
            client.receive()
            raise AssertionError("old connection reply leaked")
        except socket.timeout:
            pass
    finally:
        client.close()
    # 只断言close终止连接；先send_data再close不保证最后响应被客户端收到。
    for marker in (600, 601):
        client = Client(port, websocket)
        try:
            client.send(envelope(marker))
            for _ in range(2):
                try:
                    value = client.receive()
                    assert marker == 601 and fields(value[3])[3] == 601
                except (EOFError, ConnectionResetError):
                    break
            else:
                raise AssertionError("business close must disconnect client")
        finally:
            client.close()
    # 当前协议允许无业务标记的请求；不再把旧request_id=0当协议错误。
    for payload in (envelope(7, command=9999), envelope(7, version=99), b"\xff"):
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
    # ready六连接+pending二连接达到max_clients=8；pending=2另外在握手测试覆盖。
    ready, held = [], []
    try:
        for _ in range(6):
            ready.append(Client(19022, True))
        for _ in range(2):
            held.append(socket.create_connection(("127.0.0.1", 19022), timeout=3))
        with socket.create_connection(("127.0.0.1", 19022), timeout=3) as rejected:
            assert rejected.recv(1) == b"", "pending WS connections must count toward max_clients"
    finally:
        for client in ready:
            client.close()
        for sock in held:
            sock.close()
    print("REAL_NETWORK_LIMITS_OK")


# 验证握手拒绝、不复用旧证明、半包/粘包、容量释放和总期限。
def handshake_contract(websocket):
    port = 19022 if websocket else 19021
    for bad in (envelope(2), b"\x01\x02" + b"x" * 65,
                b"\x01\x01\x04" + b"\0" * 64, b"\x03" + b"\0" * 32):
        client = Client(port, websocket, handshake=False)
        try:
            client.send(bad)
            try:
                client.receive_bytes()
                raise AssertionError("bad handshake accepted")
            except (EOFError, ConnectionResetError):
                pass
        finally:
            client.close()
    client = Client(port, websocket, handshake=False)
    private, message = hello()
    try:
        client.send(message, fragment=True)
        challenge = client.receive_bytes()
        proof, expected = respond(private, message, challenge)
        client.send(proof)
        assert client.receive_bytes() == expected
        client.send(envelope(2))
        response(client, 2)
    finally:
        client.close()
    client = Client(port, websocket, handshake=False)
    try:
        client.send(message)
        assert client.receive_bytes() != challenge, "reconnect challenge must be fresh"
        client.send(proof)
        try:
            client.receive_bytes()
            raise AssertionError("old proof accepted")
        except (EOFError, ConnectionResetError):
            pass
    finally:
        client.close()
    client = Client(port, websocket, handshake=False)
    try:
        client.send(message)
        client.receive_bytes()
        # 完整hello不能刷新期限；该测试配置期限为1秒。
        assert client.sock.recv(1) in (b"", b"\x88"), "handshake deadline must close"
    finally:
        client.close()
    held = []
    try:
        for _ in range(2):
            held.append(Client(port, websocket, handshake=False))
        rejected = None
        try:
            try:
                rejected = Client(port, websocket, handshake=False)
                rejected.send(message)
                rejected.receive_bytes()
                raise AssertionError("handshake capacity not enforced")
            except (EOFError, ConnectionResetError, BrokenPipeError):
                pass
        finally:
            if rejected:
                rejected.close()
    finally:
        for client in held:
            client.close()
    time.sleep(0.15)
    client = Client(port, websocket)
    client.close()
    print("REAL_WS_HANDSHAKE_OK" if websocket else "REAL_TCP_HANDSHAKE_OK")


# 真实业务按当前command/body关联；同命令串行，不假造协议外request_id。
def course(port, battle):
    client = Client(port)
    try:
        for _ in range(10):
            client.send(envelope(1001))
            value = client.receive()
            assert value[2] == 1001
            assert fields(value[3])[1] in (1, 4, 5), value
        if battle:
            client.send(envelope(1001, command=1002))
            client.send(envelope(1001))
            responses = [client.receive(), client.receive()]
            assert {value[2] for value in responses} == {1001, 1002}
            result = next(value for value in responses if value[2] == 1002)
            assert fields(result[3])[1] == 1, result
    finally:
        client.close()
    # 不同地图标记产生明确拒绝，检查多连接响应未串线。
    def query(index):
        connection = Client(port)
        try:
            connection.send(envelope(2000+index))
            value = connection.receive()
            assert value[2] == 1001 and fields(value[3])[1] == 2, value
        finally:
            connection.close()
    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(query, range(16)))
    print("REAL_CLUSTER_COURSE_OK" if battle else "REAL_LOCAL_COURSE_OK")


# 独立业务进程close/回包；不启动真实Battle计算。
def cluster_close(processes):
    processes.start("close_battle", "skynet_gateway_close_battle_smoke.lua",
                    "GATEWAY_CLOSE_BATTLE_SMOKE_READY", [2528])
    processes.start("close_gateway", "gateway_process.lua",
                    "LESSON2_GATEWAY_PROCESS_READY", [19011, 2527])
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
    # 每个步骤检查Service异常，出现错误即终止，不能只看客户端响应。
    processes.assert_clean()
    client = Client(19011)
    try:
        client.send(envelope(602))
        response(client, 602)
    finally:
        client.close()
    processes.assert_clean()
    print("REAL_CLUSTER_CLOSE_OK")


# 默认覆盖全部合同；可用scope执行聚焦验证。任何错误传播，finally回收所有子进程。
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--flywow-root", default=str(ROOT / "third_party/skynet-flywow"))
    parser.add_argument("--scope", choices=["all", "smoke", "local", "course", "close"], default="all")
    args = parser.parse_args()
    framework = Path(args.flywow_root).resolve()
    assert (framework / "tools/module_paths.py").is_file(), "需要支持模块布局的 FlyWow；开发时显式传 --flywow-root"
    processes = Processes(framework)
    try:
        if args.scope in ("all", "smoke"):
            processes.start("smoke", "skynet_gateway_async_smoke.lua", "GATEWAY_ASYNC_SMOKE_READY", [19021, 19022])
            for websocket in (False, True):
                handshake_contract(websocket)
                processes.assert_clean()
                smoke(websocket)
                processes.assert_clean()
            limits()
            processes.assert_clean()
            processes.close()
        if args.scope in ("all", "local"):
            processes.start("local", "skynet.lua", "NAV_SERVER_READY", [19011])
            course(19011, False)
            processes.assert_clean()
            processes.close()
        if args.scope in ("all", "course"):
            processes.start("battle", "battle_process.lua", "LESSON2_BATTLE_PROCESS_READY", [2528])
            processes.start("gateway", "gateway_process.lua", "LESSON2_GATEWAY_PROCESS_READY", [19011, 2527])
            course(19011, True)
            processes.assert_clean()
            processes.close()
        if args.scope in ("all", "close"):
            cluster_close(processes)
        print("GATEWAY_ASYNC_INTEGRATION_OK scope=" + args.scope)
    finally:
        processes.close()


if __name__ == "__main__":
    main()
