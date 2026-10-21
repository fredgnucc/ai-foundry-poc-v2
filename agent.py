#!/usr/bin/env python3
"""Create a prompt agent in Azure AI Foundry (private data plane).

Agents are not ARM resources - they live only on the Foundry project data plane, so
Bicep cannot create them. This is the one piece the template cannot cover.

The account's data plane is private (publicNetworkAccess: Disabled), so the call to
<account>.services.ai.azure.com only works from inside the VNet. Run this either:
  * from your laptop with connect.ps1's SOCKS tunnel open - it is auto-detected, or
  * on the jump host itself (pass --no-tunnel).

It reads the step-2 deployment outputs, so there is nothing to copy by hand.

Usage:
    python agent.py
    python agent.py --name my-agent --direct
"""

from __future__ import annotations

import argparse
import json
import socket
import sys
from pathlib import Path

import requests
from azure.identity import AzureCliCredential

from arm import Arm

API_VERSION = "v1"
SCOPE = "https://ai.azure.com/.default"


def socks_port() -> int:
    """SOCKS port from lab.json, matching connect.ps1 (falls back to 1080)."""
    try:
        lab = json.loads((Path(__file__).parent / "params" / "lab.json").read_text())
        return int(lab.get("socksPort", 1080))
    except Exception:
        return 1080


def listening(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.5)
        return s.connect_ex(("127.0.0.1", port)) == 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Create a Foundry prompt agent.")
    parser.add_argument("--deployment", default="aigwp-gateway", help="Step-2 Bicep deployment name.")
    parser.add_argument("--name", default="private-agent", help="Agent name.")
    parser.add_argument(
        "--instructions",
        default="You are a concise assistant. Answer in one short sentence.",
        help="System instructions for the agent.",
    )
    parser.add_argument(
        "--direct",
        action="store_true",
        help="Call the model deployment directly, bypassing the AI Gateway.",
    )
    parser.add_argument(
        "--no-tunnel",
        action="store_true",
        help="Do not route through the SOCKS tunnel (use when running on the jump host).",
    )
    parser.add_argument(
        "--proxy-port",
        type=int,
        default=None,
        help="SOCKS port to route through (default: lab.json socksPort).",
    )
    args = parser.parse_args()

    out = Arm().deployment_outputs(args.deployment)
    account = out["accountName"]
    project = out["projectName"]
    deployment_name = out["deploymentName"]
    connection = out["connectionName"]

    # "<connection>/<deployment>" routes through the AI Gateway.
    # A bare "<deployment>" calls the model directly.
    model = deployment_name if args.direct else f"{connection}/{deployment_name}"

    # Foundry's data plane is private, so you must reach it from inside the VNet -
    # either run connect.ps1 to open the SOCKS5 proxy (auto-detected here), or run
    # this on the jump host with --no-tunnel. Off-VNet the call is refused (403).
    proxies = None
    if not args.no_tunnel:
        port = args.proxy_port or socks_port()
        if listening(port):
            url_proxy = f"socks5h://127.0.0.1:{port}"
            proxies = {"https": url_proxy, "http": url_proxy}
            print(f"Routing through the SOCKS tunnel on 127.0.0.1:{port}.")
        else:
            print(
                f"No SOCKS tunnel on 127.0.0.1:{port}. Foundry's data plane is private,\n"
                "so this direct call will be refused (HTTP 403). Reach it either way:\n"
                "  * run connect.ps1 to open the SOCKS5 proxy, then re-run this, or\n"
                "  * connect to the jump host and run this there (--no-tunnel).\n"
            )

    token = AzureCliCredential().get_token(SCOPE).token
    url = f"https://{account}.services.ai.azure.com/api/projects/{project}/agents?api-version={API_VERSION}"
    body = {
        "name": args.name,
        "description": "Created by agent.py",
        "definition": {
            "kind": "prompt",
            "model": model,
            "instructions": args.instructions,
            "tools": [],
        },
    }

    print(f"POST {url}")
    print(json.dumps(body, indent=2))

    try:
        # Create is POST to the collection with the name in the body.
        # PUT to /agents/<name> returns 405 Method Not Allowed.
        response = requests.post(
            url,
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
            json=body,
            proxies=proxies,
            timeout=60,
        )
    except requests.exceptions.RequestException as exc:
        sys.exit(f"Request failed: {exc}\nAre you still on the private network (tunnel up, or on the jump host)?")

    if not response.ok:
        print(f"\nHTTP {response.status_code}\n{response.text}", file=sys.stderr)
        return 1

    agent = response.json()
    latest = agent["versions"]["latest"]
    print(f"\nCreated '{agent['name']}' v{latest['version']}")
    print(f"  model    : {latest['definition']['model']}")
    print(f"  identity : {latest['instance_identity']['principal_id']}")
    print("\nOpen the project in https://ai.azure.com to chat with it.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
