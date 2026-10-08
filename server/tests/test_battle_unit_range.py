# 职责：固定 Skynet Lua + 真实 Native 模块的 Battle 边缘距离回归。
from pathlib import Path
import os
import struct
import subprocess
import tempfile
import unittest
import zlib


class BattleUnitRangeTests(unittest.TestCase):
    def test_real_native_battle(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as directory:
            payload = struct.pack('<iHBB', 0, 1, 0, 10) * 25
            header = bytearray(64)
            header[:4] = b'BMAP'
            struct.pack_into('<HHIIIII', header, 4, 1, 64, 17, 2, 5, 5, 500)
            struct.pack_into('<H', header, 40, 8)
            struct.pack_into('<III', header, 44, len(payload), zlib.crc32(payload), 0)
            struct.pack_into('<I', header, 52, zlib.crc32(header))
            bmap = Path(directory) / 'map.bmap'
            bmap.write_bytes(header + payload)
            environment = dict(os.environ)
            environment['LD_PRELOAD'] = str(root / 'third_party/skynet/3rd/jemalloc/lib/libjemalloc.so')
            result = subprocess.run([str(root / 'third_party/skynet/3rd/lua/lua'),
                str(root / 'tests/battle_unit_range_test.lua'), str(root), str(bmap)],
                env=environment, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('BATTLE_UNIT_RANGE_OK', result.stdout)
