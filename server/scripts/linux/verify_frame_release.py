#!/usr/bin/env python3
"""解压并验收可信的本仓库第三课帧同步发布包。

调用：
    python3 server/scripts/linux/verify_frame_release.py releases/<版本包>.tar.gz

路径与文件清单统一维护于同目录 package_frame_server.py；这里不再维护第二份目录表。
归档有 runtime 合同时优先使用包内合同，兼容以后源码路径调整后的旧包验证。
验收要求 Python 3.12+、ldd 与现有客户端 cryptography；无需在包内安装测试代码。
只修改临时解压副本的测试端口，不改正式包。失败也保存报告并回收本次进程。
"""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import tarfile
import tempfile
import time

# 正常导入同目录发布脚本，其 main 有入口保护；导入只读取配置，不构建或启动服务。
import package_frame_server as release


def runtime_contract(manifest):
    """读取包内启动合同；旧 .3 包没有 runtime 字段时使用当前统一路径定义。

    返回 server（包根相对路径）、executable/config（Server 相对路径）和启动顺序。
    该兼容分支仅适用于已交付的旧布局，不猜测未知归档的目录。
    """
    if "runtime" in manifest:
        return manifest["runtime"]
    return {
        "server": release.PATHS["server"],
        "executable": release.server_relative("{skynet_executable}"),
        "frame_config": release.server_relative("{frame_config}"),
        "processes": [
            {"role": role, "config": release.server_relative(template), "ready": marker}
            for role, template, marker in release.PROCESSES
        ],
    }


def log_files(work):
    """读取本次临时目录的 stdout 与 Logger 日志；在清理目录前保存到报告。

    仅用于短时集成验收，进程运行受固定超时约束；不是长期日志采集器。
    """
    return {
        p.relative_to(work).as_posix(): p.read_text(encoding="utf-8", errors="replace")
        for p in sorted(work.rglob("*.log"))
    }


def configure_test_ports(config):
    """按 Lua 配置键精确修改临时配置，返回修改前后 hash 与端口。

    gateway_port 是整数字段；两个 *_address 保留原 host，仅替换冒号后的端口。
    每个键必须唯一匹配；改名或结构变化时失败，避免宽泛字符串替换误伤其它数字。
    端口值仅来自发布脚本的 VERIFY_PORTS，不复制到此文件维护。
    """
    before = release.digest(config)
    text = config.read_text(encoding="utf-8")
    for key, port in release.VERIFY_PORTS.items():
        if not 1 <= port <= 65535:
            raise ValueError("测试端口超出 1..65535：" + key)
        if key.endswith("_address"):
            pattern = r'(^\s*' + re.escape(key) + r'\s*=\s*"[^"\n]+:)\d+(")'
        else:
            pattern = r"(^\s*" + re.escape(key) + r"\s*=\s*)\d+"
        # 用回调拼接，避免 replacement 中的数字被解释成 \1 后的组号。
        def replacement(match):
            suffix = match.group(2) if key.endswith("_address") else ""
            return match.group(1) + str(port) + suffix
        text, count = re.subn(pattern, replacement, text, flags=re.MULTILINE)
        if count != 1:
            raise RuntimeError("测试端口配置键必须唯一匹配：" + key)
    if len(set(release.VERIFY_PORTS.values())) != len(release.VERIFY_PORTS):
        raise ValueError("测试端口不能重复")
    config.write_text(text, encoding="utf-8")
    return {"before": before, "after": release.digest(config), "ports": release.VERIFY_PORTS}


def start_processes(server, runtime, work, processes, report):
    """按合同顺序启动 Battle/Gateway 并等待各自 READY。

    processes 由调用者持有；Popen 成功即登记，任何后续异常都由外层 finally 回收。
    每个进程独立 session，停止时只针对本次创建的进程组，不按名称查杀已有实例。
    """
    for entry in runtime["processes"]:
        role = entry["role"]
        stdout = work / (role + ".stdout.log")
        with stdout.open("w", encoding="utf-8") as stream:
            process = subprocess.Popen(
                ["./" + runtime["executable"], entry["config"]],
                cwd=server, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True,
            )
        processes.append(process)
        deadline = time.monotonic() + release.STARTUP_TIMEOUT_SECONDS
        while True:
            logs = "\n".join(log_files(work).values())
            # 先检查失败，再接受 READY；已退出的进程不能被历史 READY 判为健康。
            if process.poll() is not None or "lua loader error" in logs:
                raise RuntimeError(entry["ready"] + " 启动失败\n" + logs)
            if entry["ready"] in logs:
                break
            if time.monotonic() > deadline:
                raise TimeoutError(entry["ready"] + " 等待超时\n" + logs)
            time.sleep(0.1)
        report[role + "_ready"] = True


def stop_processes(processes):
    """停止并 wait 本次子进程；先 TERM，超过固定等待时间再 KILL。

    处理进程恰好自行退出的竞争条件；不会向旧 PID 文件或用户进程发信号。
    """
    for process in reversed(processes):
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
    for process in processes:
        try:
            process.wait(timeout=release.STOP_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()


def validate_archive(archive, report):
    """清单/依赖通过后才改临时端口并启动；成功失败均保存日志并回收进程。

    输入只接受本仓库生成的可信归档。filter=data 拒绝危险解压路径；要求单一包根。
    正式归档内容不变，临时端口修改的 hash 单独记录，不冒称为原配置验收。
    """
    processes = []
    with tempfile.TemporaryDirectory(prefix="frame-unpack-") as directory:
        work = Path(directory)
        try:
            with tarfile.open(archive) as tar:
                tar.extractall(work, filter="data")
            roots = list(work.iterdir())
            if len(roots) != 1 or not roots[0].is_dir():
                raise RuntimeError("归档必须只有一个发布根目录")
            stage = roots[0]
            report["dependencies"] = release.verify(stage)
            report["manifest_verified"] = True
            manifest = json.loads((stage / release.MANIFEST_NAME).read_text(encoding="utf-8"))
            runtime = runtime_contract(manifest)
            server = stage / runtime["server"]

            # 只检查空闲，不停止已监听的服务；检查与实际 listen 之间仍可能竞争，
            # 若有其它程序抢占，后面的启动检查会失败并回收本次进程。
            for port in release.VERIFY_PORTS.values():
                with socket.socket() as probe:
                    probe.bind(("127.0.0.1", port))
            report["validation_only_config"] = configure_test_ports(server / runtime["frame_config"])
            start_processes(server, runtime, work, processes, report)

            # 复用开发源现有客户端，仅注入测试端口；Runtime 全部从解压包读取。
            # 使用参数传递路径，避免拼接 Python 源码；测试源码本身不进入发布包。
            client = release.source_path("{integration_test}")
            code = (
                "import runpy,sys; from pathlib import Path; "
                "sys.path.insert(0,str(Path(sys.argv[1]).parent)); "
                "t=runpy.run_path(sys.argv[1]); "
                "t['main'].__globals__['PORT']=int(sys.argv[2]); t['main']()"
            )
            result = subprocess.run(
                [sys.executable, "-c", code, str(client), str(release.VERIFY_PORTS["gateway_port"])],
                cwd=server, text=True, capture_output=True, timeout=release.CLIENT_TIMEOUT_SECONDS,
            )
            report["integration"] = result.stdout + result.stderr
            if result.returncode:
                raise RuntimeError(report["integration"])
        finally:
            stop_processes(processes)
            report["processes_stopped"] = all(p.poll() is not None for p in processes)
            report["logs"] = log_files(work)


def main():
    """解析归档路径并始终写 validation.json；失败保留错误且以非零退出。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path, help="待验收 .tar.gz，路径相对当前调用目录")
    args = parser.parse_args()
    archive = args.archive.resolve()
    report = {"archive": str(archive), "passed": False}
    try:
        report["sha256"] = release.digest(archive)
        validate_archive(archive, report)
        report["passed"] = True
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        # 去掉 .tar.gz 后接报告后缀，报告写在归档旁；报告文件不会进入正式包。
        target = archive.with_suffix("").with_suffix(".validation.json")
        target.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(report["integration"])
    print("UNPACKED_RELEASE_VERIFIED")


if __name__ == "__main__":
    main()
