#!/usr/bin/env python3
"""bin/apple and the AppleTools proxy, offline, with stub binaries.

Exit 250 from the proxy means the app did not answer, so bin/apple must run
the real tool. Any other status belongs to the tool, and bin/apple exits with
it. Nothing here talks to the app or reads any user data.

    /usr/bin/python3 tests/test-apple-proxy.py
"""
import os
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APPLE = os.path.join(ROOT, "bin", "apple")


def stub(path, body):
    with open(path, "w") as f:
        f.write("#!/bin/sh\n" + body + "\n")
    os.chmod(path, 0o755)


class ProxyStatus(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.bin = os.path.join(self.tmp.name, "bin")
        os.mkdir(self.bin)
        stub(os.path.join(self.bin, "reminders"), 'echo "tool $*"')

    def tearDown(self):
        self.tmp.cleanup()

    def apple(self, proxy_body):
        proxy = os.path.join(self.tmp.name, "apple-proxy")
        stub(proxy, proxy_body)
        env = dict(
            os.environ,
            APPLE_TOOLS_BIN=self.bin,
            APPLE_TOOLS_PROXY="always",
            APPLE_TOOLS_PROXY_CLIENT=proxy,
        )
        return subprocess.run(
            [APPLE, "reminders", "show-lists"],
            env=env, capture_output=True, text=True, timeout=30,
        )

    def test_250_runs_the_tool(self):
        r = self.apple('echo "proxy $*"; exit 250')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, "proxy reminders show-lists\ntool show-lists\n")

    def test_other_status_is_kept(self):
        r = self.apple('echo "proxy $*"; exit 3')
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertEqual(r.stdout, "proxy reminders show-lists\n")

    def test_success_does_not_run_the_tool(self):
        r = self.apple('echo "proxy $*"')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, "proxy reminders show-lists\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
