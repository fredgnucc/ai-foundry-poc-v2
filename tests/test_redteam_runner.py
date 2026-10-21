import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
import sys

import httpx
from openai import BadRequestError

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "redteam-agent"))
from demo_runner import DemoRunner


class RunnerTests(unittest.IsolatedAsyncioTestCase):
    async def test_real_pyrit_pipeline_records_evidence_and_limits_reruns(self):
        class Responses:
            async def create(self, **kwargs):
                return SimpleNamespace(status="completed", output_text="I cannot disclose internal data.", output=[])

        with tempfile.TemporaryDirectory() as directory:
            runner = DemoRunner(SimpleNamespace(responses=Responses()), "fake-model", Path(directory))
            with self.assertRaises(ValueError):
                await runner.run("https://external-target")
            report = await runner.run("secret")
            self.assertTrue(report["complete"])
            self.assertEqual([row["verdict"] for row in report["results"]], ["PASS", "PASS"])
            saved = json.loads((Path(directory) / f"{report['run_id']}.json").read_text())
            self.assertEqual(saved, report)
            with self.assertRaises(RuntimeError):
                await runner.run("secret")

    async def test_model_api_errors_are_inconclusive_and_report_is_saved(self):
        class Responses:
            async def create(self, **kwargs):
                raise BadRequestError(
                    "invalid synthetic request",
                    response=httpx.Response(400, request=httpx.Request("POST", "https://example.invalid")),
                    body=None,
                )

        with tempfile.TemporaryDirectory() as directory:
            runner = DemoRunner(SimpleNamespace(responses=Responses()), "fake-model", Path(directory))
            report = await runner.run("indirect")
            self.assertTrue(report["complete"])
            self.assertEqual([row["verdict"] for row in report["results"]], ["INCONCLUSIVE", "INCONCLUSIVE"])
            self.assertEqual(report["results"][0]["evidence"]["error_type"], "BadRequestError")


if __name__ == "__main__":
    unittest.main()
