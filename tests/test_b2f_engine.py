#!/usr/bin/env python3
"""
Unit and integration tests for b2f_engine.py.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ENGINE_PATH = (
    Path(__file__).resolve().parent.parent / "scripts" / "b2f_engine.py"
)


class TestB2FEngine(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.tmppath = Path(self.tmpdir.name)
        self.env = os.environ.copy()
        if (
            sys.platform == "darwin"
            and os.path.isdir("/Library/Developer/CommandLineTools")
            and "DEVELOPER_DIR" not in self.env
        ):
            self.env["DEVELOPER_DIR"] = "/Library/Developer/CommandLineTools"

    def tearDown(self):
        self.tmpdir.cleanup()

    def run_engine(self, *args, input_data=None, cwd=None):
        cmd = [sys.executable, str(ENGINE_PATH), *args]
        return subprocess.run(
            cmd,
            input=input_data,
            capture_output=True,
            text=True,
            cwd=str(cwd or self.tmppath),
            env=self.env,
        )

    def test_template_generation(self):
        res = self.run_engine("template", "test_anchor", "Feature Implementation")
        self.assertEqual(res.returncode, 0)
        self.assertIn("b2f Re-execution Directive: Feature Implementation", res.stdout)
        self.assertIn('anchor_node: "test_anchor"', res.stdout)
        self.assertIn("## 1. 优化后的重做指令", res.stdout)

    def test_persist_and_restore_cycle(self):
        target = self.tmppath / "persisted_file.md"
        content = "# Test Directive\nInitial Content"
        res = self.run_engine(
            "persist", "node1", str(target), input_data=content
        )
        self.assertEqual(res.returncode, 0)
        self.assertTrue(target.is_file())
        self.assertEqual(target.read_text(encoding="utf-8"), content)

        # Backup file
        res_bak = self.run_engine("backup", "node1", str(target))
        self.assertEqual(res_bak.returncode, 0)

        # Mutate
        target.write_text("Mutated State", encoding="utf-8")

        # Restore
        res_rest = self.run_engine("restore", "--cleanup")
        self.assertEqual(res_rest.returncode, 0)
        self.assertEqual(target.read_text(encoding="utf-8"), content)

    def test_max_file_size_skipped(self):
        big_file = self.tmppath / "big.bin"
        with open(big_file, "wb") as f:
            f.seek(11 * 1024 * 1024)
            f.write(b"0")

        res = self.run_engine("backup", "big_node", str(big_file))
        self.assertEqual(res.returncode, 0)
        self.assertIn("exceeds 10MB limit", res.stderr)

    def test_archive_subcommand(self):
        b2f_dir = self.tmppath / "b2f"
        b2f_dir.mkdir()
        f1 = b2f_dir / "b2f_test1.md"
        f2 = b2f_dir / "b2f_test2.md"
        f_all = b2f_dir / "b2f_all_20260917.md"

        f1.write_text("frag1", encoding="utf-8")
        f2.write_text("frag2", encoding="utf-8")
        f_all.write_text("master", encoding="utf-8")

        res = self.run_engine("archive", "20260917", cwd=self.tmppath)
        self.assertEqual(res.returncode, 0)

        arch_dir = b2f_dir / ".archive" / "20260917"
        self.assertTrue((arch_dir / "b2f_test1.md").is_file())
        self.assertTrue((arch_dir / "b2f_test2.md").is_file())
        # Master file must not be archived
        self.assertTrue(f_all.is_file())

    def test_purge_subcommand(self):
        res = self.run_engine("purge")
        self.assertEqual(res.returncode, 0)
        self.assertIn("Purged active recovery directory", res.stdout)


if __name__ == "__main__":
    unittest.main()
