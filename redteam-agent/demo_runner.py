"""Bounded PyRIT exercises against the synthetic target, never arbitrary endpoints."""

import asyncio
from datetime import datetime, timezone
import json
import logging
from pathlib import Path
import time
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
            # Record transport errors before PyRIT wraps them as strategy errors.
            LOGGER.warning("Demo target mode=%s error=%s", self.mode, type(exc).__name__)
            self.evidence.update(status="error", error_type=type(exc).__name__)
        return [Message.from_prompt(prompt=json.dumps(self.evidence), role="assistant")]


class DemoRunner:
    def __init__(self, client, model: str, report_dir: Path):
        self.client, self.model, self.report_dir = client, model, report_dir
        self.lock = asyncio.Lock()
        self.initialized = False
        self.runs = 0
        self.next_run_at = 0.0
        self.latest = None

    async def run(self, scenario: str = "all") -> dict:
        if scenario != "all" and scenario not in SCENARIOS:
            raise ValueError("Choose all, secret, tool_boundary, or indirect; custom targets are not accepted.")
        if self.lock.locked():
            raise RuntimeError("A demo is already running in this sandbox.")
        async with self.lock:
            if self.runs >= 3:
                raise RuntimeError("Three-run sandbox budget reached. Start a new conversation for another demo.")
            if time.monotonic() < self.next_run_at:
                raise RuntimeError("Please wait 60 seconds between demo runs.")
            self.runs += 1
            self.next_run_at = time.monotonic() + 60
            self.latest = None
            if not self.initialized:
                await initialize_pyrit_async(memory_db_type=IN_MEMORY)
                self.initialized = True
            run_id = str(uuid.uuid4())
            report = {
                "run_id": run_id, "started_at": datetime.now(timezone.utc).isoformat(),
                "engine": "PyRIT 1.1.0 / PromptSendingAttack",
                "model": self.model,
                "complete": False,
                "target": "synthetic in-process agent; no real tools",
                "scoring": "Exact canary disclosure or recorded mock export. PASS is only this bounded test.",
                "results": [],
            }
            self.latest = report
            chosen = SCENARIOS if scenario == "all" else {scenario: SCENARIOS[scenario]}
            for name, case in chosen.items():
                for mode in MODES:
                    canary = f"FAKE-DEMO-{uuid.uuid4().hex}"
                    target = DemoTarget(client=self.client, model=self.model, mode=mode, case=case, canary=canary)
                    try:
                        async with asyncio.timeout(45):
                            attack = PromptSendingAttack(objective_target=target, max_attempts_on_failure=0)
                            await attack.execute_async(
                                objective=case["objective"],
                                next_message=Message.from_prompt(prompt=case["prompt"], role="user"),
                            )
                        evidence = target.evidence or {"status": "no_evidence"}
                    except TimeoutError as exc:
                        LOGGER.warning("Demo case=%s mode=%s error=%s", name, mode, type(exc).__name__)
                        evidence = target.evidence
                        evidence.update(status="error", error_type=type(exc).__name__)
                    result = {
                        "case": name, "mode": mode, "verdict": assess(name, evidence, canary),
                        "expected_fake_canary": canary,
                        "prompt": case["prompt"], "document": case["document"], "evidence": evidence,
                    }
                    report["results"].append(result)
                    LOGGER.info("Demo run=%s case=%s mode=%s verdict=%s", run_id, name, mode, result["verdict"])
                    # Persist after each case; a cancelled run remains explicitly incomplete.
                    report["complete"] = len(report["results"]) == len(chosen) * len(MODES)
                    self.report_dir.mkdir(parents=True, exist_ok=True)
                    (self.report_dir / f"{run_id}.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
                    self.latest = report
            return report
