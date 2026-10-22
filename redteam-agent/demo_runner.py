"""PyRIT exercises against the synthetic target only."""

import asyncio
from datetime import datetime, timezone
import json
import logging
from pathlib import Path
import uuid

from openai import APIError
from pyrit.executor.attack import PromptSendingAttack
from pyrit.models import Message
from pyrit.prompt_target import PromptTarget
from pyrit.setup import IN_MEMORY, initialize_pyrit_async
import yaml

from demo_target import MODES, assess, exercise

SCENARIOS = yaml.safe_load((Path(__file__).parent / "scenarios.yaml").read_text(encoding="utf-8"))
LOGGER = logging.getLogger(__name__)


class DemoTarget(PromptTarget):
    def __init__(self, *, client, model: str, mode: str, case: dict, canary: str):
        super().__init__()
        self.client, self.model, self.mode = client, model, mode
        self.case, self.canary = case, canary
        self.evidence = {}

    async def _send_prompt_to_target_async(self, *, normalized_conversation: list[Message]) -> list[Message]:
        prompt = normalized_conversation[-1].get_piece().converted_value
        try:
            self.evidence = await exercise(
                self.client, self.model, self.mode, prompt, self.case["document"], self.canary,
                evidence=self.evidence,
            )
        except APIError as exc:
            self.evidence.update(status="error", error_type=type(exc).__name__)
        return [Message.from_prompt(prompt=json.dumps(self.evidence), role="assistant")]


class DemoRunner:
    def __init__(self, client, model: str, report_dir: Path):
        self.client, self.model, self.report_dir = client, model, report_dir
        self.initialized = False
        self.latest = None

    async def run(self, scenario: str = "all") -> dict:
        if scenario != "all" and scenario not in SCENARIOS:
            raise ValueError("Choose all, secret, tool_boundary, or indirect.")
        if not self.initialized:
            await initialize_pyrit_async(memory_db_type=IN_MEMORY)
            self.initialized = True
        report = {
            "run_id": str(uuid.uuid4()), "started_at": datetime.now(timezone.utc).isoformat(),
            "engine": "PyRIT / PromptSendingAttack", "model": self.model, "results": [],
        }
        chosen = SCENARIOS if scenario == "all" else {scenario: SCENARIOS[scenario]}
        for name, case in chosen.items():
            for mode in MODES:
                canary = f"FAKE-DEMO-{uuid.uuid4().hex}"
                target = DemoTarget(client=self.client, model=self.model, mode=mode, case=case, canary=canary)
                try:
                    async with asyncio.timeout(45):
                        await PromptSendingAttack(objective_target=target, max_attempts_on_failure=0).execute_async(
                            objective=case["objective"],
                            next_message=Message.from_prompt(prompt=case["prompt"], role="user"),
                        )
                except TimeoutError:
                    target.evidence.update(status="error", error_type="TimeoutError")
                evidence = target.evidence or {"status": "no_evidence"}
                verdict = assess(name, evidence, canary)
                report["results"].append({"case": name, "mode": mode, "verdict": verdict, "evidence": evidence})
                LOGGER.info("Demo run=%s case=%s mode=%s verdict=%s", report["run_id"], name, mode, verdict)
        self.report_dir.mkdir(parents=True, exist_ok=True)
        (self.report_dir / f"{report['run_id']}.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
        self.latest = report
        return report
