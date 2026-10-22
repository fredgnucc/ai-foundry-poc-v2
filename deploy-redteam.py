"""Deploy the red-team demo: two target agents and the orchestrator that attacks them."""

import argparse
import importlib.util
import json
from pathlib import Path
import secrets
import sys
import uuid

from arm import Arm

HERE = Path(__file__).parent
spec = importlib.util.spec_from_file_location("hosted_agent", HERE / "hosted-agent.py")
hosted = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hosted)

AZURE_AI_USER = "53ca6127-db72-4b80-b1b0-d745d6d5456d"
DEMO_KIND = {"DEMO_KIND": "isolated-pyrit"}


def demo_env(api, name: str) -> dict | None:
    """Env of an existing demo agent, None if absent; refuse to touch other agents."""
    response = api.call("GET", f"/agents/{name}")
    if response.status_code == 404:
        return None
    if not response.ok:
        hosted.fail(response)
    env = response.json()["versions"]["latest"]["definition"].get("environment_variables", {})
    if env.get("DEMO_KIND") != DEMO_KIND["DEMO_KIND"]:
        sys.exit(f"Refusing to overwrite '{name}': it was not created by this demo.")
    return env


def grant_invoke(arm: Arm, scope: str, principal_id: str) -> None:
    """Let the orchestrator call other agents in the project (idempotent)."""
    assignment = uuid.uuid5(uuid.NAMESPACE_URL, f"{scope}|{principal_id}|{AZURE_AI_USER}")
    arm.call(
        "PUT", f"{scope}/providers/Microsoft.Authorization/roleAssignments/{assignment}", "2022-04-01",
        ok=(200, 201, 409),
        json={"properties": {
            "roleDefinitionId": f"/subscriptions/{arm.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/{AZURE_AI_USER}",
            "principalId": principal_id, "principalType": "ServicePrincipal",
        }},
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--no-tunnel", action="store_true")
    parser.add_argument("--proxy-port", type=int)
    parser.add_argument("--timeout", type=int, default=1200)
    parser.add_argument("--skip-deploy", action="store_true")
    parser.add_argument("--message", default="Run the secret demo and show the actual results.")
    args = parser.parse_args()
    config = json.loads((HERE / "params" / "redteam.json").read_text(encoding="utf-8-sig"))
    lab = json.loads((HERE / "params" / "lab.json").read_text(encoding="utf-8-sig"))
    name, targets = config["agentName"], config["targets"]
    for agent in (name, *targets.values()):
        if not agent.startswith("redteam-") or not all(c.isalnum() or c == "-" for c in agent):
            sys.exit("Demo agent names must start with redteam- and use letters, digits, or hyphens.")

    arm = Arm()
    out = arm.deployment_outputs("aigwp-gateway")
    gateway = arm.deployment_outputs("aigwp-hosted-agent")["gatewayUrl"]
    proxies = hosted.tunnel_proxies(args)
    if proxies is None and not args.no_tunnel:
        sys.exit("Open connect.ps1 -TunnelOnly first.")
    endpoint = f"https://{out['accountName']}.services.ai.azure.com/api/projects/{out['projectName']}"
    api = hosted.DataPlane(endpoint, proxies)

    envs = {agent: demo_env(api, agent) for agent in (name, *targets.values())}
    if not args.skip_deploy:
        # Keep the canary stable across redeploys so unchanged agents keep their version.
        canary = (envs[name] or {}).get("DEMO_CANARY") or f"FAKE-DEMO-{secrets.token_hex(16)}"
        plan = {
            targets["prompt_only"]: {"TARGET_MODE": "prompt_only", "DEMO_CANARY": canary},
            targets["enforced"]: {"TARGET_MODE": "enforced"},
            name: {
                "REDTEAM_PROJECT_ENDPOINT": endpoint, "DEMO_CANARY": canary,
                "TARGET_PROMPT_ONLY": targets["prompt_only"], "TARGET_ENFORCED": targets["enforced"],
            },
        }
        for agent, env in plan.items():
            source = HERE / ("redteam-agent" if agent == name else "redteam-target")
            cpu, memory = (config["cpu"], config["memory"]) if agent == name else ("0.5", "1Gi")
            version = hosted.deploy(
                api, agent, out["deploymentName"], gateway, {**DEMO_KIND, **env},
                source=source, cpu=cpu, memory=memory,
            )
            hosted.wait_active(api, agent, version, args.timeout)
        project_scope = (
            f"/subscriptions/{arm.subscription_id}/resourceGroups/{lab['resourceGroupName']}"
            f"/providers/Microsoft.CognitiveServices/accounts/{out['accountName']}/projects/{out['projectName']}"
        )
        grant_invoke(arm, project_scope, hosted.agent_identity(api, name))
        print("Orchestrator can call the targets (Azure AI User on the project; allow a few minutes to apply).")
    return hosted.invoke(api, name, args.message)


if __name__ == "__main__":
    raise SystemExit(main())
