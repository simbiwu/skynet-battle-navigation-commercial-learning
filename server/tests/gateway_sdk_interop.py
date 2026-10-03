# 职责：真实Skynet中验收H5 Web Crypto SDK与可选Unity C#宿主。
# 边界：Integration Runner；参数为框架根、dotnet命令和C#程序集，进程finally关闭。
# 生命周期：专用19021/19022及可选本机19023端口和日志，不接管部署PID，不打印握手secret。
# 不负责：Node的Web Crypto不能代替浏览器验收，.NET不能代替IL2CPP验收。
import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
from gateway_async_integration import Processes


# 启动专用服务，顺序执行SDK；命令失败明确传播，并回收自己启动的进程。
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--flywow-root', required=True)
    parser.add_argument('--dotnet')
    parser.add_argument('--unity-runner')
    parser.add_argument('--serve-browser', action='store_true')
    args = parser.parse_args()
    assert bool(args.dotnet) == bool(args.unity_runner)
    framework = Path(args.flywow_root).resolve()
    processes = Processes(framework)
    try:
        processes.start('sdk', 'skynet_gateway_async_smoke.lua', 'GATEWAY_ASYNC_SMOKE_READY', [19021, 19022])
        subprocess.run(['node', str(framework / 'gateway/h5/example.mjs'), 'ws://127.0.0.1:19022'], check=True, timeout=20)
        if args.dotnet:
            subprocess.run([args.dotnet, args.unity_runner, '19021'], check=True, timeout=20)
        print('GATEWAY_SDK_INTEROP_OK')
        if args.serve_browser:
            # 仅本机验收；阻塞到调用者Ctrl+C，finally回收HTTP和Skynet进程。
            handler = partial(SimpleHTTPRequestHandler, directory=str(framework / 'gateway/h5'))
            with ThreadingHTTPServer(('127.0.0.1', 19023), handler) as server:
                print('BROWSER_INTEROP_READY http://localhost:19023/example.html', flush=True)
                try:
                    server.serve_forever()
                except KeyboardInterrupt:
                    print("BROWSER_INTEROP_STOPPED")
    finally:
        processes.close()


if __name__ == '__main__':
    main()
