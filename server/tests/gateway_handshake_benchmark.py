# 职责：测量本机真实Gateway握手开销，提供可复现的有限样本。
# 边界：Benchmark；只使用测试夹具和公开握手协议，不把结果外推为商业容量。
# 生命周期：64次串行连接，每次完成即关闭；finally仅回收本runner的Skynet。
# 不负责：不做压测、长期soak、网络攻击测试或Unity平台性能评估。
import argparse
import json
import os
from pathlib import Path
import statistics
import time
from gateway_async_integration import Client, Processes


# 从自己启动的Linux子进程读取CPU/RSS；不读取其他服务秘密，不修改进程。
def usage(pid):
    values = Path(f'/proc/{pid}/stat').read_text().split(') ', 1)[1].split()
    ticks = int(values[11]) + int(values[12])
    return ticks / os.sysconf('SC_CLK_TCK'), int(values[21]) * os.sysconf('SC_PAGE_SIZE') // 1024


# 固定样本TCP/WS握手，报告包含客户端密钥计算及本机调度的端到端耗时。
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--flywow-root', required=True)
    args = parser.parse_args()
    processes = Processes(Path(args.flywow_root).resolve())
    try:
        processes.start('handshake_benchmark', 'skynet_gateway_async_smoke.lua', 'GATEWAY_ASYNC_SMOKE_READY', [19021, 19022])
        pid = processes.children[0][0].pid
        for websocket in (False, True):
            samples = []
            cpu_before, rss_before = usage(pid)
            for _ in range(64):
                start = time.perf_counter()
                client = Client(19022 if websocket else 19021, websocket)
                try:
                    samples.append((time.perf_counter() - start) * 1000)
                finally:
                    client.close()
            cpu_after, rss_after = usage(pid)
            samples.sort()
            print(json.dumps(dict(transport='ws' if websocket else 'tcp', samples=64,
                                  median_ms=round(statistics.median(samples), 3),
                                  p95_ms=round(samples[60], 3), max_ms=round(max(samples), 3),
                                  server_cpu_ms=round((cpu_after-cpu_before)*1000, 3),
                                  rss_before_kib=rss_before, rss_after_kib=rss_after)))
    finally:
        processes.close()


if __name__ == '__main__':
    main()
