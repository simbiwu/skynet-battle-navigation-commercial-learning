# 职责：通过真实P-256握手/TCP/Proto/Gateway/Cluster/BattleWorker验证玩家输入与权威帧。
# 边界：第三课聚焦集成测试；手写wire读写仅为避免在测试机器另装Python Protobuf。
# 输入：已启动的frame_battle和frame_gateway；输出FRAME_ONE_CLIENT_OK或异常退出。
# 运行：server/目录执行 python3 tests/frame_sync_integration.py。
# 不负责：代替Unity Editor Play、客户端Native Golden或安全压测。
import socket
import struct
from gateway_handshake_client import perform

HOST = "127.0.0.1"
PORT = 19021
PROTO_VERSION = 4
JOIN, INPUT, PUSH = 1101, 1102, 1103


def varint(n):
    out = bytearray()
    while n > 127:
        out.append((n & 127) | 128)
        n >>= 7
    out.append(n)
    return bytes(out)


def number(tag, value):
    return varint(tag * 8) + varint(value)


def signed(tag, value):
    return number(tag, (value << 1) ^ (value >> 31))


def binary(tag, payload):
    return varint(tag * 8 + 2) + varint(len(payload)) + payload


def decode_varint(data, offset):
    value, shift = 0, 0
    while offset < len(data) and shift <= 63:
        byte = data[offset]
        offset += 1
        value |= (byte & 127) << shift
        if not (byte & 128):
            return value, offset
        shift += 7
    raise ValueError("BAD_VARINT")


def parse(data):
    fields = {}
    offset = 0
    while offset < len(data):
        key, offset = decode_varint(data, offset)
        field, kind = key >> 3, key & 7
        if kind == 0:
            value, offset = decode_varint(data, offset)
        elif kind == 2:
            size, offset = decode_varint(data, offset)
            value = data[offset:offset + size]
            offset += size
            if len(value) != size:
                raise ValueError("TRUNCATED_BYTES")
        elif kind == 5:
            value = struct.unpack_from("<I", data, offset)[0]
            offset += 4
        else:
            raise ValueError("UNEXPECTED_WIRE_KIND")
        fields.setdefault(field, []).append(value)
    return fields


def first(fields, field, default=None):
    return fields.get(field, [default])[0]


class Client:
    def __init__(self):
        self.socket = socket.create_connection((HOST, PORT), timeout=3)
        self.socket.settimeout(4)
        perform(self.write_frame, self.read_frame)
        self.request_id = 0
        self.pushes = []

    def read_exact(self, size):
        result = bytearray()
        while len(result) < size:
            chunk = self.socket.recv(size - len(result))
            if not chunk:
                raise ConnectionError("DISCONNECTED")
            result += chunk
        return bytes(result)

    def read_frame(self):
        size = struct.unpack(">H", self.read_exact(2))[0]
        assert 0 < size <= 65535
        return self.read_exact(size)

    def write_frame(self, body):
        assert 0 < len(body) <= 65535
        self.socket.sendall(struct.pack(">H", len(body)) + body)

    def send(self, command, body):
        self.request_id += 1
        envelope = number(1, PROTO_VERSION) + number(2, command) + \
            binary(3, body)
        self.write_frame(envelope)
        return self.request_id

    def recv_envelope(self):
        envelope = parse(self.read_frame())
        assert first(envelope, 1) == PROTO_VERSION
        return first(envelope, 2), 0, first(envelope, 3)

    def request(self, command, body):
        request_id = self.send(command, body)
        while True:
            got_command, got_id, payload = self.recv_envelope()
            if got_command == command:
                return parse(payload)
            assert got_id == 0 and got_command == PUSH
            self.pushes.append(parse(payload))

    def next_push(self):
        if self.pushes:
            return self.pushes.pop(0)
        command, request_id, payload = self.recv_envelope()
        assert command == PUSH and request_id == 0
        return parse(payload)

    def close(self):
        self.socket.close()


def command(frame, direction):
    return number(1, frame) + signed(2, direction) + signed(3, 0) + number(4, 0)


def send_input(client, battle_id, generation, frame, direction):
    body = number(1, battle_id) + number(2, generation) + binary(3, command(frame, direction))
    client.send(INPUT, body)


def records_from(push):
    return [parse(record) for record in push.get(3, [])]


def record_view(record):
    players = []
    for wire in record.get(2, []):
        player = parse(wire)
        inp = parse(first(player, 2))
        players.append((first(player, 1), first(inp, 1), first(player, 3, 0),
                        first(inp, 2, 0), first(inp, 3, 0), first(inp, 4, 0)))
    return first(record, 1), tuple(players), first(record, 3)


def main():
    left = Client()
    try:
        mismatch = left.request(JOIN, number(1, 1001) + number(3, 999))
        assert first(mismatch, 1).decode() == "SIMULATION_VERSION"
        first_join = left.request(JOIN, number(1, 1001) + number(3, 2))
        assert first(first_join, 1).decode() == "OK"
        battle_id = first(first_join, 2)
        assert first(first_join, 3) == 1
        assert first(first_join, 5) == 1  # 初始generation。
        assert first(first_join, 9, 0) == 0
        assert first(first_join, 11) == 60  # 逻辑频率。
        assert first(first_join, 14) == 2  # 模拟合同版本。
        assert first(first_join, 10)  # 创建即开战；初始Checkpoint在Join响应中返回。
        for frame in (4, 5):
            send_input(left, battle_id, first(first_join, 5), frame, 1)
        records = []
        while len(records) < 12:
            push = left.next_push()
            code = first(push, 4, b"OK").decode()
            if code not in ("OK", "LATE", "CONFLICT", "INPUT_WINDOW"):
                raise RuntimeError("Unexpected push " + code)
            records.extend(record_view(record) for record in records_from(push))
        records = records[:12]
        assert [record[0] for record in records] == list(range(1, 13))
        for frame, players, state_hash in records:
            assert len(players) == 1 and players[0][0] == 1
            assert players[0][1] == frame
            assert isinstance(state_hash, int)
        print("FRAME_ONE_CLIENT_OK", "battle_id=", battle_id, "frames=12")
    finally:
        left.close()

if __name__ == "__main__":
    main()
