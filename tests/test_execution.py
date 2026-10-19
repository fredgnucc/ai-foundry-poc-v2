import os
from pathlib import Path
import sys
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "hosted-agent"))

from execution import OUTPUT_LIMIT, run_local, validate_command


class ExecutionTests(unittest.TestCase):
    def test_combines_output_and_preserves_failure_exit_code(self):
        result = run_local("printf hello; printf problem >&2; exit 7", 5)
        self.assertEqual(result["output"], "helloproblem")
        self.assertEqual(result["exit_code"], 7)
        self.assertEqual(result["status"], "completed")

    def test_timeout_kills_command_group(self):
        start = time.monotonic()
        result = run_local("sleep 20 & wait", 1)
        self.assertEqual(result["status"], "timeout")
        self.assertLess(time.monotonic() - start, 4)

    def test_output_is_bounded_even_when_command_never_finishes(self):
        result = run_local("yes x", 5)
        self.assertEqual(result["status"], "output_limit")
        self.assertLessEqual(len(result["output"].encode()), OUTPUT_LIMIT)
        self.assertTrue(result["truncated"])

    def test_closed_stdout_does_not_bypass_timeout(self):
        start = time.monotonic()
        result = run_local("exec 1>&- 2>&-; sleep 20", 1)
        self.assertEqual(result["status"], "timeout")
        self.assertLess(time.monotonic() - start, 4)

    def test_rejects_invalid_requests(self):
        for command, target, timeout in [
            ("", "sandbox", 5), ("x\0y", "sandbox", 5),
            ("x" * 8193, "sandbox", 5), ("id", "other", 5),
            ("id", "jump", 0), ("id", "jump", 61),
        ]:
            with self.subTest(command=command[:10], target=target, timeout=timeout):
                with self.assertRaises(ValueError):
                    validate_command(command, target, timeout)


if __name__ == "__main__":
    if os.name != "posix":
        raise SystemExit("Run on Linux (WSL or the jump host), matching the hosted runtime.")
    unittest.main()
