#!/usr/bin/env python3
"""Step 7: publish a lab agent to Microsoft Teams and Microsoft 365 Copilot.

The project has public network access off, so the portal's Publish button can't be used
(https://learn.microsoft.com/azure/foundry/agents/how-to/publish-copilot-virtual-network):

  1. reads the agent identity (private data plane: tunnel up, or --no-tunnel on the jump host),
  2. deploys 07-teams.bicepparam over ARM REST: an Azure Bot Service with the Teams channel,
  3. turns on the Activity Protocol with enable_m365_public_endpoint - only that route is
     reachable from Microsoft 365 / Bot Service IP ranges, and callers still need a valid
     token (BotServiceRbac or BotServiceTenant); every other project API stays private,
  4. calls the Microsoft 365 publish API.

Usage:
    python publish-teams.py --agent private-agent
    python publish-teams.py --agent private-agent --scope Tenant --app-version 1.0.1
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path

from arm import Arm, compile_params

HERE = Path(__file__).parent

# hosted-agent.py has a dash in its name, so it is loaded by path.
_spec = importlib.util.spec_from_file_location("hosted_agent", HERE / "hosted-agent.py")
hosted = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hosted)

# publishScope -> the authorization scheme Foundry pairs with it.
SCHEMES = {"Shared": "BotServiceRbac", "Tenant": "BotServiceTenant"}


def get_agent(api, name: str) -> dict:
    response = api.call("GET", f"/agents/{name}")
    if response.status_code == 404:
        sys.exit(f"No agent named '{name}'.")
    if not response.ok:
        hosted.fail(response)
    return response.json()


def enable_activity(api, agent: dict, scheme: str) -> None:
    """PATCH replaces both lists, so keep what the endpoint already has (responses, Entra)."""
    endpoint = agent.get("agent_endpoint") or {}
    protocols = {**(endpoint.get("protocol_configuration") or {"responses": {}}),
                 "activity": {"enable_m365_public_endpoint": True}}
    schemes = [s for s in endpoint.get("authorization_schemes") or [{"type": "Entra"}]
               if not s.get("type", "").startswith("BotService")]
    schemes.append({"type": scheme})
    body = {"agent_endpoint": {"protocol_configuration": protocols, "authorization_schemes": schemes}}
    response = api.call("PATCH", f"/agents/{agent['name']}", json=body,
                        headers={"Content-Type": "application/merge-patch+json"})
    if not response.ok:
        hosted.fail(response)


def main() -> int:
    sys.stdout.reconfigure(errors="replace")
    parser = argparse.ArgumentParser(description="Step 7: publish an agent to Teams and Microsoft 365 Copilot.")
    parser.add_argument("--agent", required=True, help="Agent name, e.g. private-agent or hosted-agent.")
    parser.add_argument("--scope", choices=sorted(SCHEMES), default="Shared",
                        help="Shared: only you, no approval. Tenant: whole org, after M365 admin approval.")
    parser.add_argument("--display-name", default=None, help="Name in Teams/Copilot (default: agent name).")
    parser.add_argument("--app-version", default="1.0.0", help="Bump it to republish metadata changes.")
    parser.add_argument("--description", default="Private Foundry agent from the ai-gateway-private-3step lab.")
    parser.add_argument("--developer", default="AI gateway private lab")
    parser.add_argument("--deployment", default="aigwp-gateway", help="Step-2 deployment name.")
    parser.add_argument("--teams-deployment", default=None, help="Step-7 deployment name (default: aigwp-teams-<agent>).")
    parser.add_argument("--no-tunnel", action="store_true", help="Run on the jump host, without the SOCKS tunnel.")
    parser.add_argument("--proxy-port", type=int, default=None, help="SOCKS port (default: lab.json socksPort).")
    args = parser.parse_args()

    lab = json.loads((HERE / "params" / "lab.json").read_text())
    arm = Arm()
    out = arm.deployment_outputs(args.deployment)
    proxies = hosted.tunnel_proxies(args)
    if proxies is None and not args.no_tunnel:
        sys.exit("Open the tunnel first: ./connect.ps1 -TunnelOnly")
    api = hosted.DataPlane(f"https://{out['accountName']}.services.ai.azure.com/api/projects/{out['projectName']}", proxies)
    display_name = args.display_name or args.agent

    print("1/4 Agent identity")
    agent = get_agent(api, args.agent)
    client_id = agent["instance_identity"]["client_id"]
    print(f"    {client_id}")

    print("2/4 Azure Bot Service + Teams channel")
    arm.register_provider("Microsoft.BotService")
    compiled = compile_params(HERE / "07-teams.bicepparam", {
        "TEAMS_AGENT_NAME": args.agent,
        "TEAMS_AGENT_CLIENT_ID": client_id,
        "TEAMS_DISPLAY_NAME": display_name,
    })
    bot_id = arm.deploy(args.teams_deployment or f"aigwp-teams-{args.agent}", lab["location"], compiled)["botId"]

    scheme = SCHEMES[args.scope]
    print(f"3/4 Activity Protocol, Microsoft 365 route only ({scheme})")
    enable_activity(api, agent, scheme)

    print(f"4/4 Publish to Microsoft 365 (scope {args.scope}, app {args.app_version})")
    body = {
        "agentDisplayName": display_name,
        "botServiceArmId": bot_id,
        "publishScope": args.scope,
        "publishAsAutopilot": False,
        "appVersion": args.app_version,
        "shortDescription": args.description[:80],
        "fullDescription": args.description,
        "developerName": args.developer,
        "developerWebsiteUrl": "https://azure.microsoft.com",
        "privacyUrl": "https://privacy.microsoft.com",
        "termsOfUseUrl": "https://www.microsoft.com/legal/terms-of-use",
    }
    response = api.call("POST", f"/agents/{args.agent}/microsoft365/publish", json=body, timeout=300)
    if response.status_code == 409 or "already exists" in response.text:
        sys.exit(f"App version {args.app_version} is already published. Use --app-version with a higher number.\n{response.text}")
    if not response.ok:
        hosted.fail(response)
    print(f"    {response.text}")
    where = "Your agents" if args.scope == "Shared" else "Built by your org, after admin approval (admin.cloud.microsoft > Agents > Requests)"
    print(f"\nPublished. In Teams or Copilot: Apps / Agent store > {where} > '{display_name}'.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
