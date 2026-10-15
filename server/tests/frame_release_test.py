#!/usr/bin/env python3
"""发布规则与端口改写回归测试；不构建、不启动 Server、不读写用户发布目录。

从仓库根目录执行 python3 server/tests/frame_release_test.py。
所有候选文件在临时目录创建；patch 仅在当前测试期间替换发布脚本的路径/规则。
真实 ELF 与双进程验证仍由 verify_frame_release.py 单独执行。
"""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/linux"))
import package_frame_server as package
import verify_frame_release as verifier


class ReleaseRulesTest(unittest.TestCase):
    """验证维护者改白名单/路径后最容易发生的漏包、覆盖及错误替换。"""

    def test_glob_filter_and_native_destination(self):
        """一条目录规则只取 Lua；一条单文件规则能把 Native 移到新发布目录。"""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "source").mkdir()
            (root / "source/run.lua").write_text("return true\n", encoding="utf-8")
            (root / "source/dev.tmp").write_text("not runtime", encoding="utf-8")
            (root / "core.so").write_bytes(b"native fixture")
            stage = root / "stage"
            stage.mkdir()
            rules = (("source/**/*.lua", None), ("core.so", "{native_release}/core.so"))
            with patch.object(package, "ROOT", root), \
                    patch.object(package, "RELEASE_FILES", rules), \
                    patch.dict(package.PATHS, {"native_release": "server/new_native"}):
                hashes = package.stage_files(stage)
            self.assertTrue((stage / "source/run.lua").is_file())
            self.assertFalse((stage / "source/dev.tmp").exists())
            self.assertEqual((stage / "server/new_native/core.so").read_bytes(), b"native fixture")
            self.assertEqual(set(hashes), {"source/run.lua", "core.so"})

    def test_missing_rule_and_duplicate_destination_fail(self):
        """新增规则路径拼错或两个来源覆盖同一目标时必须失败。"""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "a.lua").write_text("return 1", encoding="utf-8")
            (root / "b.lua").write_text("return 2", encoding="utf-8")
            for rules, message in (
                ((("missing/**/*.lua", None),), "没有匹配"),
                ((("a.lua", "same.lua"), ("b.lua", "same.lua")), "目标重复"),
            ):
                with self.subTest(message=message):
                    stage = root / message
                    stage.mkdir()
                    with patch.object(package, "ROOT", root), \
                            patch.object(package, "RELEASE_FILES", rules):
                        with self.assertRaisesRegex(RuntimeError, message):
                            package.stage_files(stage)

    def test_destination_cannot_escape_stage(self):
        """维护清单中的目标路径不能通过 .. 写到包根之外。"""
        with self.assertRaises(ValueError):
            package.relative_path("../outside.lua")

    def test_port_rewrite_preserves_unrelated_values(self):
        """改测试端口不能改注释、其它数字或地址 host；失败不写回半成品配置。"""
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "frame.lua"
            config.write_text(
                '-- 保留说明19021\n'
                'gateway_port = 19021,\n'
                'gateway_address = "127.0.0.1:2537",\n'
                'battle_address = "localhost:2538",\n'
                'other = 19021,\n',
                encoding="utf-8",
            )
            verifier.configure_test_ports(config)
            text = config.read_text(encoding="utf-8")
            self.assertIn("gateway_port = 29021", text)
            self.assertIn('"localhost:3538"', text)
            self.assertIn("other = 19021", text)
            self.assertIn("-- 保留说明19021", text)
            config.write_text("gateway_port = 19021,\n", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "唯一匹配"):
                verifier.configure_test_ports(config)
            self.assertEqual(config.read_text(encoding="utf-8"), "gateway_port = 19021,\n")

    def test_manifest_detects_nested_manifest_tampering(self):
        """只有包根清单免于自 hash；同名嵌套文件仍必须参与完整性检查。"""
        with tempfile.TemporaryDirectory() as directory:
            stage = Path(directory)
            (stage / "nested").mkdir()
            nested = stage / "nested" / package.MANIFEST_NAME
            nested.write_text("fixture", encoding="utf-8")
            manifest = {"files": {"nested/" + package.MANIFEST_NAME: package.digest(nested)}}
            (stage / package.MANIFEST_NAME).write_text(json.dumps(manifest), encoding="utf-8")
            package.verify(stage)
            nested.write_text("changed", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "清单不匹配"):
                package.verify(stage)


    def test_failure_report_is_written_without_starting_processes(self):
        """归档损坏也必须留下失败报告；进程阶段尚未开始，不应触碰现有实例。"""
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "broken.tar.gz"
            archive.write_bytes(b"not a tar archive")
            with patch.object(sys, "argv", ["verify_frame_release.py", str(archive)]), \
                    patch.object(verifier.subprocess, "Popen") as popen:
                with self.assertRaises(Exception):
                    verifier.main()
                popen.assert_not_called()
            report = json.loads((Path(directory) / "broken.validation.json").read_text(encoding="utf-8"))
            self.assertFalse(report["passed"])
            self.assertTrue(report["error"])
            self.assertTrue(report["processes_stopped"])

    def test_archive_runtime_wins_over_current_paths(self):
        """验证旧归档时，以归档记录的布局为准，不套用当前源码的路径。"""
        contract = {"server": "old_server", "executable": "old/skynet", "processes": []}
        self.assertIs(verifier.runtime_contract({"runtime": contract}), contract)


if __name__ == "__main__":
    unittest.main()
