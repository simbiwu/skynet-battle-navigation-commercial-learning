# 职责：本机多连接响应、RSS/FD与连接释放 benchmark；仅启动并终止自己的 Skynet。
# 边界：WSL 测试客户端；复用真实握手与宿主协议，不修改生产配置，不做公网容量结论。
# 输入/输出：transport、连接档位、测量时长 -> JSONL 原始结果与资源采样。
# 生命周期：最多8192连接，每连接一个在途请求；延迟用有界直方图，失败不隐去。
import argparse
import asyncio
import base64
import hashlib
import json
import math
import os
from pathlib import Path
import struct
import subprocess
import time
from gateway_handshake_client import hello, respond
from gateway_async_integration import number, blob, fields

ROOT = Path(__file__).resolve().parents[1]

# 只读 runner 创建的进程资源；RSS单位KiB，CPU为累计秒。
def usage(pid):
    values = Path(f"/proc/{pid}/stat").read_text().split(") ", 1)[1].split()
    return dict(cpu_s=(int(values[11])+int(values[12]))/os.sysconf("SC_CLK_TCK"),
                rss_kib=int(values[21])*os.sysconf("SC_PAGE_SIZE")//1024,
                fd=len(list(Path(f"/proc/{pid}/fd").iterdir())))

# 有界0.1ms分桶，超2秒归入末桶；max仍保留实际值。
class Histogram:
    def __init__(self):
        self.bins = [0]*20001
        self.count = 0
        self.maximum = 0
    def add(self, ms):
        self.bins[min(20000, int(ms*10))] += 1
        self.count += 1
        self.maximum = max(self.maximum, ms)
    def percentile(self, p):
        if self.count == 0:
            return None
        target = math.ceil(self.count*p)
        current = 0
        for index, count in enumerate(self.bins):
            current += count
            if current >= target:
                return (index+1)/10
        return None
    def result(self):
        return dict(samples=self.count, p50_ms=self.percentile(.5), p95_ms=self.percentile(.95),
                    p99_ms=self.percentile(.99), max_ms=round(self.maximum, 3))

class Connection:
    def __init__(self, reader, writer, websocket):
        self.reader, self.writer, self.ws = reader, writer, websocket
    async def send(self, payload, opcode=2):
        if self.ws:
            mask = os.urandom(4)
            header = bytes([128|opcode, 128|len(payload)]) if len(payload)<126 else bytes([128|opcode,254])+struct.pack(">H",len(payload))
            payload = header+mask+bytes(value^mask[i%4] for i,value in enumerate(payload))
        else:
            payload = struct.pack(">H",len(payload))+payload
        self.writer.write(payload)
        await self.writer.drain()
    async def receive(self):
        head = await self.reader.readexactly(2)
        if self.ws:
            if head[0] == 0x88:
                assert head[1] <= 125, "invalid WS close frame"
                await self.reader.readexactly(head[1])
                raise EOFError("WebSocket close")
            assert head[0] == 130 and not head[1]&128, "unexpected WS frame"
            size = head[1]&127
            if size == 126:
                size = struct.unpack(">H",await self.reader.readexactly(2))[0]
            elif size == 127:
                size = struct.unpack(">Q",await self.reader.readexactly(8))[0]
        else:
            size = struct.unpack(">H",head)[0]
        assert size<=65535
        return await self.reader.readexactly(size)
    async def close(self):
        if self.writer.is_closing():
            return
        try:
            if self.ws and not self.reader.at_eof():
                # 正常释放需完成Close控制帧；直接关TCP会产生预期外的服务端读错误。
                await self.send(struct.pack(">H",1000), opcode=8)
                try:
                    await asyncio.wait_for(self.receive(),3)
                    raise AssertionError("unexpected data during WS close")
                except EOFError:
                    pass
                except asyncio.IncompleteReadError as error:
                    assert not error.partial, "truncated WS close frame"
        finally:
            self.writer.close()
            await self.writer.wait_closed()

# 完整HTTP Upgrade与密码握手；每次生成独立密钥，调用者独占连接。
async def connect(websocket):
    reader, writer = await asyncio.open_connection("127.0.0.1",19131)
    connection = Connection(reader,writer,websocket)
    try:
        if websocket:
            key = base64.b64encode(os.urandom(16)).decode()
            writer.write((f"GET / HTTP/1.1\r\nHost: localhost:19131\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\n\r\n").encode())
            await writer.drain()
            header = await reader.readuntil(b"\r\n\r\n")
            expected = base64.b64encode(hashlib.sha1((key+"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
            assert b"101" in header.split(b"\r\n")[0] and expected in header
        private, message = hello()
        await connection.send(message)
        proof, expected = respond(private,message,await connection.receive())
        await connection.send(proof)
        assert await connection.receive() == expected
        return connection
    except BaseException:
        await connection.close()
        raise

# 固定到达时间，每连接一个在途；记录实际RTT与计划到达延迟，防止闭环掩盖积压。
async def workload(connections, rate, duration):
    rtt, scheduled = Histogram(), Histogram()
    result = dict(target_qps=rate, errors=0, late_over_10ms=0, error_examples=[])
    period = len(connections)/rate
    start = time.perf_counter()+.2
    end = start+duration
    cpu_start = time.process_time()
    async def worker(index, connection):
        due = start+index/rate
        seq = 0
        while due<end:
            await asyncio.sleep(max(0,due-time.perf_counter()))
            actual = time.perf_counter()
            if actual-due>.01:
                result["late_over_10ms"] += 1
            seq += 1
            marker = index+1+seq*8192
            payload = number(1,3)+number(2,1001)+blob(3,number(1,marker)+number(2,1))
            try:
                await connection.send(payload)
                data = fields(await asyncio.wait_for(connection.receive(),3))
                body = fields(data[3])
                assert data[1]==3 and data[2]==1001 and body[1]==1 and body[3]==marker, "response mismatch"
                now = time.perf_counter()
                rtt.add((now-actual)*1000)
                scheduled.add((now-due)*1000)
            except Exception as error:
                result["errors"] += 1
                if len(result["error_examples"])<5:
                    result["error_examples"].append(type(error).__name__+":"+str(error))
                raise RuntimeError("benchmark response error: "+str(error)) from error
            due += period
    tasks = [asyncio.create_task(worker(i,c)) for i,c in enumerate(connections)]
    try:
        await asyncio.gather(*tasks)
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
    elapsed = max(duration, time.perf_counter()-start)
    result.update(rtt=rtt.result(), scheduled_latency=scheduled.result(),
                  planned_window_qps=round(rtt.count/duration,2),
                  successful_qps=round(rtt.count/elapsed,2),
                  measured_elapsed_s=round(elapsed,3),
                  client_cpu_s=round(time.process_time()-cpu_start,3),
                  drain_s=round(max(0,elapsed-duration),3))
    return result

# 每秒检查自己启动的Service；任何日志堆栈、结构化错误或进程退出均立即终止当前阶段。
async def guarded(operation, log, child, samples=None):
    async def monitor():
        while True:
            assert child.poll() is None, "benchmark server exited"
            text = log.read_text()
            lines = text.splitlines()
            bad = next((line for line in lines if "stack traceback:" in line or "lua call [" in line
                        or "Maybe forgot response" in line or "FLYWOW_GATEWAY_ERROR" in line or "FLYWOW_GATEWAY_WARNING" in line), None)
            assert bad is None, "Service error: " + str(bad)
            if samples is not None:
                samples.append(dict(server=usage(child.pid), client=usage(os.getpid())))
            await asyncio.sleep(1)
    work = asyncio.ensure_future(operation)
    watcher = asyncio.create_task(monitor())
    try:
        done, _ = await asyncio.wait((work, watcher), return_when=asyncio.FIRST_COMPLETED)
        if watcher in done:
            await watcher
            raise RuntimeError("monitor unexpectedly ended")
        result = await work
        # 阶段结束后仍核对日志，不能吞掉最后一条响应后的Service异常。
        assert child.poll() is None, "benchmark server exited"
        text = log.read_text()
        assert not any(token in text for token in ("stack traceback:", "lua call [", "Maybe forgot response", "FLYWOW_GATEWAY_ERROR", "FLYWOW_GATEWAY_WARNING")), text[-2000:]
        return result
    finally:
        work.cancel()
        watcher.cancel()
        await asyncio.gather(work, watcher, return_exceptions=True)


# 批量建立真实连接；connections由外层runner拥有，部分失败也保留已成功连接供finally释放。
async def connect_clients(connections, count, websocket, log, child, handshake=None):
    for offset in range(0, count, 32):
        async def timed_connect():
            before = time.perf_counter()
            connection = await asyncio.wait_for(connect(websocket), 10)
            if handshake is not None:
                handshake.add((time.perf_counter()-before)*1000)
            return connection
        batch = await guarded(
            asyncio.gather(*(timed_connect() for _ in range(min(32,count-offset))),
                           return_exceptions=True),
            log, child)
        connections.extend(c for c in batch if isinstance(c, Connection))
        failures = [str(c) for c in batch if not isinstance(c, Connection)]
        assert not failures, "connection establishment failed: " + str(failures[:5])


# 单个负载段的响应与资源统计；不强制GC，返回独立record，CPU按实际含排空时长换算。
async def measure_load(connections, rate, seconds, log, child):
    before = usage(child.pid)
    samples = []
    result = await guarded(workload(connections, rate, seconds), log, child, samples)
    after = usage(child.pid)
    return dict(
        kind="load", connections=len(connections), seconds=seconds, **result,
        server_cpu_percent=round(100*(after["cpu_s"]-before["cpu_s"])/result["measured_elapsed_s"],2),
        server=after, peak_rss_kib=max(s["server"]["rss_kib"] for s in samples),
        client=usage(os.getpid()),
        peak_client_rss_kib=max(s["client"]["rss_kib"] for s in samples))


# 同进程自然周转；每轮完成收发、正常关闭与6秒清理，不重启、不强制GC。
async def churn_clients(args, count, connections, log, child, emit):
    for cycle in range(args.churn if count == 4096 else 0):
        before_cycle = usage(child.pid)
        await connect_clients(connections, count, args.transport == "ws", log, child)
        cycle_samples = []
        result = await guarded(workload(connections, count, 10), log, child, cycle_samples)
        active_cycle = usage(child.pid)
        await guarded(asyncio.gather(*(c.close() for c in connections)), log, child)
        connections.clear()
        await guarded(asyncio.sleep(6), log, child)
        tail = [line for line in log.read_text().splitlines() if "BENCH_STATS" in line][-1]
        assert "clients=0 " in tail and "dropped=0 " in tail, tail
        emit(dict(kind="churn", cycle=cycle+1, connections=count, before=before_cycle,
                  active=active_cycle, released=usage(child.pid), stats_tail=tail, **result))


# 所有自然阶段完成后的独立GC审计；控制连接也由本函数释放，不把强制回收混入性能评分。
async def gc_diagnostic(websocket, log, child):
    before_gc = usage(child.pid)
    audit = await guarded(asyncio.wait_for(connect(websocket), 10), log, child)
    try:
        payload = number(1,3)+number(2,1001)+blob(3,number(1,0xFFFFFFFE)+number(2,1))
        await audit.send(payload)
        try:
            await asyncio.wait_for(audit.receive(), 3)
            raise AssertionError("diagnostic must close its connection")
        except EOFError:
            pass
        except asyncio.IncompleteReadError as error:
            assert not error.partial, "truncated diagnostic close"
    finally:
        audit.writer.close()
        await audit.writer.wait_closed()
    await guarded(asyncio.sleep(3), log, child)
    diagnostic = [line for line in log.read_text().splitlines() if "BENCH_GC_DIAGNOSTIC" in line][-1]
    assert "clients=0 " in diagnostic, diagnostic
    return dict(kind="gc_diagnostic", before=before_gc, after=usage(child.pid),
                diagnostic=diagnostic)


# 一个连接档位的原子进程生命周期；异常时只终止本函数创建的Skynet并关闭自己建立的连接。
async def run_instance(args, count, output, emit):
    skynet_transport = "websocket" if args.transport == "ws" else "tcp"
    config = output/f"launch_{args.transport}_{count}_{args.tag}.lua"
    log = output/f"server_{args.transport}_{count}_{args.tag}.log"
    connections = []
    with log.open("w") as handle:
        # 配置include按当前配置目录解析，启动文件放config目录会污染正式配置；
        # 使用绝对include路径使日志目录成为测试产物边界。
        config.write_text(f'include "{ROOT}/config/skynet_gateway_benchmark.lua"\nbench_transport = "{skynet_transport}"\n')
        import socket
        with socket.socket() as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            probe.bind(("127.0.0.1",19131))
        environment = dict(os.environ, LUA_PANDA_ENABLE="0")
        child = subprocess.Popen([str(ROOT/"third_party/skynet/skynet"),str(config)],cwd=ROOT,env=environment,stdout=handle,stderr=subprocess.STDOUT)
        try:
            for _ in range(200):
                startup_log = log.read_text()
                assert not any(token in startup_log for token in ("stack traceback:", "lua call [", "Maybe forgot response", "FLYWOW_GATEWAY_ERROR", "FLYWOW_GATEWAY_WARNING")), startup_log
                if "GATEWAY_BENCHMARK_READY" in startup_log:
                    break
                assert child.poll() is None,log.read_text()
                await asyncio.sleep(.1)
            else:
                raise RuntimeError("ready timeout:"+log.read_text())
            await guarded(asyncio.sleep(2), log, child)
            baseline = usage(child.pid)
            handshake = Histogram()
            started = time.perf_counter()
            await connect_clients(connections, count, args.transport == "ws", log, child, handshake)
            connected = usage(child.pid)
            emit(dict(kind="connected",connections=count,ready=len(connections),connect_s=round(time.perf_counter()-started,3),
                      handshake=handshake.result(),baseline=baseline,server=connected,
                      per_connection_rss_kib=round((connected["rss_kib"]-baseline["rss_kib"])/count,3)))
            warmup = await guarded(workload(connections,min(2000,count),5), log, child)
            emit(dict(kind="warmup",connections=count,seconds=5,**warmup))
            for rate in sorted(set(args.rates or [2000,count,count*2])):
                emit(await measure_load(connections, rate, args.seconds, log, child))
            if args.soak and count==4096:
                for minute in range(args.soak):
                    before = usage(child.pid)
                    result = await guarded(workload(connections,4096,60), log, child)
                    after = usage(child.pid)
                    emit(dict(kind="soak",minute=minute+1,connections=count,**result,server=after,
                              server_cpu_percent=round(100*(after["cpu_s"]-before["cpu_s"])/result["measured_elapsed_s"],2)))
            await guarded(asyncio.gather(*(c.close() for c in connections)), log, child)
            connections.clear()
            await guarded(asyncio.sleep(6), log, child)
            tail = [line for line in log.read_text().splitlines() if "BENCH_STATS" in line][-1]
            assert "clients=0 " in tail and "dropped=0 " in tail, tail
            emit(dict(kind="released",connections=count,baseline=baseline,server=usage(child.pid),
                      stats_tail=[line for line in log.read_text().splitlines() if "BENCH_STATS" in line][-2:]))
            await churn_clients(args, count, connections, log, child, emit)
            if args.gc_diagnostic and count == args.connections[-1]:
                emit(dict(connections=count, **await gc_diagnostic(args.transport == "ws", log, child)))
        except BaseException as error:
            emit(dict(kind="failure",connections=count,error=type(error).__name__+":"+str(error)))
            raise
        finally:
            await asyncio.gather(*(c.close() for c in connections),return_exceptions=True)
            child.terminate()
            try:
                await asyncio.to_thread(child.wait,5)
            except subprocess.TimeoutExpired:
                child.kill()
                await asyncio.to_thread(child.wait)


# 独占端口探测与独立启动配置；finally只回收自己创建的进程。
async def run(args):
    output = ROOT/"logs/gateway_benchmark"
    output.mkdir(parents=True,exist_ok=True)
    result_path = output/f"{args.transport}_{args.tag}.jsonl"
    def emit(record):
        record["utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime())
        with result_path.open("a") as handle:
            handle.write(json.dumps(record)+"\n")
        print(json.dumps(record),flush=True)
    assert not result_path.exists(), "result already exists"
    emit(dict(kind="environment",transport=args.transport,host=os.uname().release,
              cpu=Path("/proc/cpuinfo").read_text().split("model name")[1].split("\n")[0],
              main_commit=subprocess.check_output(["git","rev-parse","HEAD"],cwd=ROOT.parent,text=True).strip(),
              flywow_commit=subprocess.check_output(["git","rev-parse","HEAD"],cwd=ROOT/"third_party/skynet-flywow",text=True).strip(),
              descriptor_sha256=hashlib.sha256((ROOT.parent/"shared/protocol/generated/server/navigation_query.pb").read_bytes()).hexdigest(),
              max_clients=8192,max_total_requests_per_second=30000,worker_threads=4))
    for count in args.connections:
        await run_instance(args, count, output, emit)
    emit(dict(kind="complete"))

if __name__=="__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--transport",choices=["tcp","ws"],required=True)
    parser.add_argument("--connections",type=int,nargs="+",default=[256,1024,2048,4096,8192])
    parser.add_argument("--seconds",type=int,default=30)
    parser.add_argument("--churn",type=int,default=3,help="4096连接同进程周转轮数")
    parser.add_argument("--rates",type=int,nargs="+",help="显式覆盖负载档位，每秒请求数")
    parser.add_argument("--gc-diagnostic",action="store_true",help="最终自然释放后额外强制GC，仅作内存诊断")
    parser.add_argument("--soak",type=int,default=0,help="4096连接持续测试分钟数")
    parser.add_argument("--tag",default=time.strftime("%Y%m%d_%H%M%S"))
    args = parser.parse_args()
    assert all(1<=count<=8192 for count in args.connections)
    assert 1<=args.seconds<=3600 and 0<=args.soak<=120 and 0<=args.churn<=10
    assert args.rates is None or all(1<=rate<=30000 for rate in args.rates)
    asyncio.run(run(args))
