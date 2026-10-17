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


def configure_test_ports(server, runtime):
    """只改临时包的 Gateway 监听端口与 Battle/Gateway Cluster 地址。

    gateway_port 属于 gateway_frame_sync.lua；gateway_address 和 battle_address
    属于 frame_sync.lua。每项只允许匹配一次，避免此前把 Gateway 端口改进 Battle 配置。
    正式归档不变；返回每个文件的修改前后 hash 和实际测试端口。
    """
    targets = {
        "gateway_port": server / runtime.get(
            "gateway_config", release.server_relative("{config}/gateway_frame_sync.lua")
        ),
        "gateway_address": server / runtime["frame_config"],
        "battle_address": server / runtime["frame_config"],
    }
    before = {}
    for config in set(targets.values()):
        before[config] = release.digest(config)
    for key, port in release.VERIFY_PORTS.items():
        if not 1 <= port <= 65535:
            raise ValueError("测试端口超出 1..65535：" + key)
        config = targets[key]
        config_key = "port" if key == "gateway_port" else key
        text = config.read_text(encoding="utf-8")
        if key.endswith("_address"):
            pattern = r'(^\s*' + re.escape(config_key) + r'\s*=\s*"[^"\n]+:)\d+(")'
        else:
            pattern = r"(^\s*" + re.escape(config_key) + r"\s*=\s*)\d+"
        def replacement(match):
            suffix = match.group(2) if key.endswith("_address") else ""
            return match.group(1) + str(port) + suffix
        text, count = re.subn(pattern, replacement, text, flags=re.MULTILINE)
        if count != 1:
            raise RuntimeError("测试端口配置键必须唯一匹配：" + config_key + " in " + str(config))
        config.write_text(text, encoding="utf-8")
    if len(set(release.VERIFY_PORTS.values())) != len(release.VERIFY_PORTS):
        raise ValueError("测试端口不能重复")
    return {
        config.relative_to(server.parent).as_posix(): {
            "before": old_hash, "after": release.digest(config),
        }
        for config, old_hash in before.items()
    } | {"ports": release.VERIFY_PORTS}


def configure_debug_console_ports(server, runtime):
    """只修改临时包 Battle/Gateway 的 debug_console 端口，返回修改前后 hash。

    配置文件和进程角色来自归档 runtime 合同；每个进程配置必须恰好有一个
    debug_console_port。测试端口由 package_frame_server.py 集中维护，正式包不改。
    """
    report = {}
    process_by_role = {entry["role"]: entry for entry in runtime["processes"]}
    for role, port in release.VERIFY_DEBUG_CONSOLE_PORTS.items():
        if role not in process_by_role or not 1 <= port <= 65535:
            raise ValueError("debug_console 测试配置无效：" + role)
        config = server / process_by_role[role]["config"]
        before = release.digest(config)
        text = config.read_text(encoding="utf-8")
        pattern = r"(^\s*debug_console_port\s*=\s*)\d+"
        text, count = re.subn(
            pattern, lambda match: match.group(1) + str(port), text, flags=re.MULTILINE
        )
        if count != 1:
            raise RuntimeError(role + " 配置必须恰有一个 debug_console_port")
        config.write_text(text, encoding="utf-8")
        report[role] = {
            "before": before, "after": release.digest(config), "port": port,
        }
    return report


def run_manager(server, runtime, action, work, timeout):
    """调用解压包自己的生命周期入口，并保存该命令的输出供验收报告使用。

    发布包入口负责选择 frame-sync profile；运行目录和配置均来自本次临时解压目录。
    timeout 只限制验证器等待命令，不改变发布包正式运行时的停止策略。
    """
    manager = server / runtime["manager"]
    result = subprocess.run(
        [str(manager), action],
        cwd=server,
        text=True,
        capture_output=True,
        timeout=timeout,
        env={**os.environ, "LESSON_STARTUP_TIMEOUT_SEC": str(release.STARTUP_TIMEOUT_SECONDS),
             "LESSON_STOP_TIMEOUT_SEC": str(release.STOP_TIMEOUT_SECONDS)},
    )
    return result.stdout + result.stderr, result.returncode


def start_processes(server, runtime, work, processes, report):
    """通过发布包自己的 manager 启动服务；旧归档没有 manager 时兼容直接启动。

    新归档的 manager 在 Battle/Gateway READY 后返回。传统分支保留对早期发布包的
    验证支持；其 Popen 进程组由调用者登记，并在 finally 中精确回收。
    """
    if runtime.get("manager"):
        output, code = run_manager(
            server, runtime, "start", work, release.STARTUP_TIMEOUT_SECONDS + 10
        )
        report["manager_start"] = output
        if code:
            raise RuntimeError("发布包 start 失败：\n" + output)
        status_output, status_code = run_manager(server, runtime, "status", work, 5)
        report["manager_status"] = status_output
        if status_code or "battle RUNNING" not in status_output or "gateway RUNNING" not in status_output:
            raise RuntimeError("发布包 status 未报告 Battle/Gateway 均运行：\n" + status_output)
        return
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


def stop_managed(server, runtime, report):
    """停止并核验临时包中的服务；超时兜底只向该临时包 PID 文件指向的进程发信号。

    正常路径由发布脚本调用 Cluster shutdownctl 优雅关闭。若管理命令卡住或报告失败，
    验证器读取本次临时目录内 lesson3_frame_sync/*.pid，并要求 /proc 命令行同时包含
    本次解压包绝对路径和对应配置名，确认目标后才发送 SIGTERM；绝不按名称扫描进程。
    """
    try:
        output, code = run_manager(
            server, runtime, "stop", server.parent, release.STOP_TIMEOUT_SECONDS + 20
        )
        report["manager_stop"] = output
        if code == 0:
            status_output, status_code = run_manager(
                server, runtime, "status", server.parent, 5
            )
            report["manager_status_after_stop"] = status_output
            if (status_code == 0 and "RUNNING" not in status_output
                    and "GRACEFUL_STOPPED" in output):
                return True
    except (subprocess.TimeoutExpired, OSError) as error:
        report["manager_stop_error"] = str(error)

    # 这里的 PID 文件由本次校验中的 manager 创建，目录处于 TemporaryDirectory 下。
    run_dir = server / runtime.get("run_directory", "run/lesson3_frame_sync")
    package_root = str(server.resolve())
    for pid_file in sorted(run_dir.glob("*.pid")):
        try:
            pid = int(pid_file.read_text(encoding="ascii").strip())
            command = Path("/proc") / str(pid) / "cmdline"
            command_line = command.read_bytes().replace(b"\0", b" ").decode("utf-8", "replace")
            role = pid_file.stem
            expected_config = next(
                entry["config"] for entry in runtime["processes"] if entry["role"] == role
            )
            if package_root not in command_line or expected_config not in command_line:
                continue
            os.kill(pid, signal.SIGTERM)
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline and Path("/proc", str(pid)).exists():
                time.sleep(0.1)
            if Path("/proc", str(pid)).exists():
                os.kill(pid, signal.SIGKILL)
        except (OSError, ValueError, StopIteration):
            continue
    return False


def validate_archive(archive, report):
    """清单/依赖通过后才改临时端口并启动；成功失败均保存日志并回收进程。

    输入只接受本仓库生成的可信归档。filter=data 拒绝危险解压路径；要求单一包根。
    正式归档内容不变，临时端口修改的 hash 单独记录，不冒称为原配置验收。
    """
    processes = []
    runtime = {}
    server = None
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
            if runtime.get("manager"):
                doctor_output, doctor_code = run_manager(server, runtime, "doctor", work, 10)
                report["manager_doctor"] = doctor_output
                if doctor_code:
                    raise RuntimeError("发布包 doctor 失败：\n" + doctor_output)

            # 只检查空闲，不停止已监听的服务；检查与实际 listen 之间仍可能竞争，
            # 若有其它程序抢占，后面的启动检查会失败并回收本次进程。
            validation_ports = [
                *release.VERIFY_PORTS.values(),
                *release.VERIFY_DEBUG_CONSOLE_PORTS.values(),
            ]
            if len(set(validation_ports)) != len(validation_ports):
                raise ValueError("验收端口必须互不重复")
            for port in validation_ports:
                with socket.socket() as probe:
                    probe.bind(("127.0.0.1", port))
            report["validation_only_config"] = configure_test_ports(server, runtime)
            report["validation_only_debug_console_config"] = configure_debug_console_ports(
                server, runtime
            )
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
            if runtime.get("manager") and server is not None:
                report["processes_stopped"] = stop_managed(server, runtime, report)
            else:
                stop_processes(processes)
                report["processes_stopped"] = all(p.poll() is not None for p in processes)
            report["logs"] = log_files(work)
            if not report["processes_stopped"]:
                raise RuntimeError("发布包进程停止验证失败；详细信息见 validation.json")


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
