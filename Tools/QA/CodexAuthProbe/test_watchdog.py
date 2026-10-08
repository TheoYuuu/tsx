"""Test forced cleanup with sleeping owned processes; never use Rust or Keychain."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("auth_verify", HERE / "verify.py")
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


class WatchdogTest(unittest.TestCase):
    def test_timeout_stops_helper_session_and_its_worker(self):
        verify.common.directory(verify.WORK / "watchdog-tests")
        with tempfile.TemporaryDirectory(dir=verify.WORK / "watchdog-tests") as location:
            root = Path(location)
            child = root / "child.py"
            child.write_text("""import json, os, subprocess, sys, time
from pathlib import Path
worker = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
Path(sys.argv[1]).write_text(json.dumps([os.getpid(), worker.pid]))
time.sleep(60)
""")
            harness = root / "harness.py"
            harness.write_text("""import signal, subprocess, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
subprocess.Popen([sys.executable, sys.argv[1], sys.argv[2]], start_new_session=True)
time.sleep(60)
""")
            inventory = root / "processes.json"
            with self.assertRaises(subprocess.TimeoutExpired):
                verify.fixture_run([sys.executable, "-I", str(harness), str(child), str(inventory)],
                                   {"PATH": "/usr/bin:/bin"}, root / "watchdog.log",
                                   timeout=1, cleanup_timeout=0.1)
            pids = json.loads(inventory.read_text())
            self.assertEqual(len(pids), 2)
            deadline = time.monotonic() + 3
            while True:
                live = []
                for pid in pids:
                    status = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "stat="],
                                            capture_output=True, timeout=1).stdout.strip()
                    if status and not status.startswith(b"Z"):
                        live.append(pid)
                if not live or time.monotonic() >= deadline:
                    break
                time.sleep(0.05)
            self.assertEqual(live, [], "An owned helper or worker survived the forced deadline.")


if __name__ == "__main__":
    unittest.main()
