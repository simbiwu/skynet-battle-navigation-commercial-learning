# TCP流延迟/抖动/500ms下行停顿测试；不把流停顿冒称OS层真实丢包。
import select
import socket
import threading
import time
from collections import deque
from state_sync_integration import Client, JOIN, INPUT, PUSH, number, signed, binary, parse, first
class Relay:
    def __init__(self, rtt_ms, jitter_ms=10):
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.port = self.listener.getsockname()[1]
        self.delay = rtt_ms / 2000
        self.jitter = jitter_ms / 1000
        self.pause_until = 0
        self.closed = threading.Event()
        self.sockets = []
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()
    def run(self):
        try:
            incoming, _ = self.listener.accept()
            outgoing = socket.create_connection(("127.0.0.1", 19031), timeout=3)
            self.sockets = [incoming, outgoing]
            for stream in self.sockets: stream.setblocking(False)
            queues = [deque(), deque()]
            serial = 0
            while not self.closed.is_set():
                readable, _, _ = select.select(self.sockets, [], [], .001)
                for source in readable:
                    data = source.recv(65536)
                    if not data: return
                    index = self.sockets.index(source)
                    serial += 1
                    due = time.monotonic() + self.delay + (serial % 3) * self.jitter / 2
                    if queues[index]: due = max(due, queues[index][-1][0])
                    queues[index].append((due, data))
                    if sum(len(v[1]) for v in queues[index]) > 2 * 1024 * 1024:
                        raise RuntimeError("RELAY_LIMIT")
                for index, queue in enumerate(queues):
                    if index == 1 and time.monotonic() < self.pause_until: continue
                    if queue and queue[0][0] <= time.monotonic():
                        due, data = queue[0]
                        try: sent = self.sockets[1 - index].send(data)
                        except BlockingIOError: continue
                        if sent == len(data): queue.popleft()
                        else: queue[0] = (due, data[sent:])
        except (OSError, ValueError):
            if not self.closed.is_set(): raise
        finally:
            for stream in self.sockets: stream.close()
    def close(self):
        self.closed.set()
        self.listener.close()
        for stream in self.sockets:
            try: stream.shutdown(socket.SHUT_RDWR)
            except OSError: pass
        self.thread.join(2)
class RelayClient(Client):
    def __init__(self, port):
        from gateway_handshake_client import perform
        self.socket = socket.create_connection(("127.0.0.1", port), timeout=4)
        self.socket.settimeout(5)
        perform(self.write_frame, self.read_frame)
        self.pushes = []
def verify(rtt_ms, pause=False):
    relay = Relay(rtt_ms)
    client = RelayClient(relay.port)
    stopped = threading.Event()
    observed = { "consumed": 0, "snapshot": 0, "event": 0, "error": None, "bytes": 0 }
    mutex = threading.Lock()
    thread = None
    try:
        join = client.request(JOIN, number(1, 1001) + number(2, 1))
        assert first(join, 1) == b"OK"
        battle, generation = first(join, 2), first(join, 3)
        initial = parse(first(join, 12))
        observed["snapshot"] = first(initial, 1)
        seen = deque([observed["snapshot"]], maxlen=64)
        def receive():
            try:
                while not stopped.is_set():
                    command, value = client.recv_envelope()
                    if command != PUSH: continue
                    assert first(value, 3) in (b"OK", b"EVENT_GAP"), value
                    state_wire = first(value, 4)
                    with mutex:
                        if state_wire:
                            observed["bytes"] += len(state_wire)
                            state = parse(state_wire)
                            base = first(state, 2, 0)
                            assert base == 0 or base in seen, "Delta must reference received baseline"
                            observed["snapshot"] = first(state, 1)
                            seen.append(observed["snapshot"])
                            observed["consumed"] = first(state, 4, 0)
                            observed["event"] = first(state, 5, 0)
            except Exception as error:
                if not stopped.is_set(): observed["error"] = str(error)
        thread = threading.Thread(target=receive, daemon=True)
        thread.start()
        started = time.monotonic()
        seq = 0
        peak = 0
        did_pause = False
        blocked = 0
        while seq < 120 and time.monotonic() - started < 8:
            with mutex:
                consumed, snapshot, event = observed["consumed"], observed["snapshot"], observed["event"]
            pending = seq - consumed
            peak = max(peak, pending)
            if pause and seq >= 30 and not did_pause:
                relay.pause_until = time.monotonic() + .5
                did_pause = True
            if pending >= 24:
                blocked += 1
                time.sleep(.01)
                continue
            count = min(6, 24 - pending, 120 - seq)
            body = number(1, battle) + number(2, generation) + number(4, snapshot) + number(5, event)
            for _ in range(count):
                seq += 1
                body += binary(3, number(1, seq) + signed(2, 1) + signed(3, 0))
            client.send(INPUT, body)
            time.sleep(count / 60)
        deadline = time.monotonic() + 3
        while observed["consumed"] < 120 and time.monotonic() < deadline and not observed["error"]:
            time.sleep(.02)
        assert observed["error"] is None, observed
        assert observed["consumed"] == 120 and peak <= 24, observed
        if pause: assert blocked > 0, "blackout must exercise bounded prediction window"
        print("STATE_TCP_NETWORK_OK rtt_ms=%d jitter_ms=10 blackout_ms=%d peak_pending=%d blocked=%d snapshot_bytes=%d" %
              (rtt_ms, 500 if pause else 0, peak, blocked, observed["bytes"]))
    finally:
        stopped.set()
        client.close()
        relay.close()
        if thread: thread.join(2)
def main():
    for rtt in (40, 80, 120, 200): verify(rtt)
    verify(80, pause=True)
if __name__ == "__main__": main()
