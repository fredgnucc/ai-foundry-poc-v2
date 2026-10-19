#!/usr/bin/env python3
"""Query a Foundry IQ knowledge base over the private network (agentic retrieval).

Foundry IQ builds on Azure AI Search: a knowledge base orchestrates agentic
retrieval over one or more knowledge sources and, in the preview API, synthesises a
grounded answer with citations. This script runs the *retrieve* action against that
knowledge base - the one part of the loop that is a clean, documented single call.

The knowledge base itself (index, vectorizer, knowledge source, semantic config) is
created with the portal wizard - see README "Step 6". This script assumes it exists.

The Search service is private (publicNetworkAccess: disabled), reached over its
private endpoint, so this only works from inside the VNet. Run it either:
  * from your laptop with connect.ps1's SOCKS tunnel open - it is auto-detected, or
  * on the jump host itself (pass --no-tunnel).

It reads the step-3 (aigwp-runtime) outputs for the Search service name, so there
is nothing to copy by hand.

Usage:
    python foundry-iq-test.py --question "What does the sample doc say about X?"
    python foundry-iq-test.py --no-tunnel        # on the jump host
"""

from __future__ import annotations

import argparse
import json
import socket
import subprocess
import sys
from pathlib import Path

import requests
from azure.identity import AzureCliCredential

# Preview version: query planning + answer synthesis. Use 2026-04-01 for the GA,
# extractive-only path (which takes "intents" instead of "messages").
API_VERSION = "2026-08-01-preview"
SCOPE = "https://search.azure.com/.default"


def deployment_outputs(name: str) -> dict[str, str]:
    """Read outputs from a subscription deployment (defaults to step 3)."""
    result = subprocess.run(
        ["az", "deployment", "sub", "show", "--name", name, "--query", "properties.outputs", "-o", "json"],
        capture_output=True,
        text=True,
        shell=(sys.platform == "win32"),
    )
    if result.returncode != 0:
        sys.exit(f"Could not read deployment '{name}'.\n{result.stderr.strip()}")
    return {k: v["value"] for k, v in json.loads(result.stdout).items()}


def lab_config() -> dict:
    return json.loads((Path(__file__).parent / "params" / "lab.json").read_text())


def socks_port() -> int:
    """SOCKS port from lab.json, matching connect.ps1 (falls back to 1080)."""
    try:
        return int(lab_config().get("socksPort", 1080))
    except Exception:
        return 1080


def listening(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.5)
        return s.connect_ex(("127.0.0.1", port)) == 0


def main() -> int:
    lab = lab_config()
    parser = argparse.ArgumentParser(description="Query a Foundry IQ knowledge base.")
    parser.add_argument("--deployment", default="aigwp-runtime", help="Step-3 Bicep deployment name.")
    parser.add_argument(
        "--knowledge-base",
        default=lab.get("knowledgeBaseName", "lab-knowledge"),
        help="Knowledge base name (default: lab.json knowledgeBaseName).",
    )
    parser.add_argument(
        "--question",
        default="Summarise what the sample document says.",
        help="The question to ask the knowledge base.",
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

    search = deployment_outputs(args.deployment)["searchName"]

    # The Search data plane is private, so you must reach it from inside the VNet -
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
                f"No SOCKS tunnel on 127.0.0.1:{port}. The Search data plane is private,\n"
                "so this direct call will be refused (HTTP 403). Reach it either way:\n"
                "  * run connect.ps1 to open the SOCKS5 proxy, then re-run this, or\n"
                "  * connect to the jump host and run this there (--no-tunnel).\n"
            )

    token = AzureCliCredential().get_token(SCOPE).token
    url = f"https://{search}.search.windows.net/knowledgebases/{args.knowledge_base}/retrieve?api-version={API_VERSION}"

    # An assistant turn grounds the model; the user turn is the actual question.
    body = {
        "messages": [
            {
                "role": "assistant",
                "content": [
                    {
                        "type": "text",
                        "text": (
                            "Answer only from the retrieved sources and cite the ref_id for each. "
                            "If the sources do not contain the answer, respond with 'I do not know'."
                        ),
                    }
                ],
            },
            {"role": "user", "content": [{"type": "text", "text": args.question}]},
        ]
    }

    print(f"POST {url}")
    print(f'Question: "{args.question}"')

    try:
        response = requests.post(
            url,
            headers={"Authorization": f"******", "Content-Type": "application/json"},
            json=body,
            proxies=proxies,
            timeout=120,
        )
    except requests.exceptions.RequestException as exc:
        sys.exit(f"Request failed: {exc}\nAre you still on the private network (tunnel up, or on the jump host)?")

    if not response.ok:
        print(f"\nHTTP {response.status_code}\n{response.text}", file=sys.stderr)
        if response.status_code == 404:
            print(
                f"\nKnowledge base '{args.knowledge_base}' not found. Create it with the "
                "portal wizard first (README Step 6), or pass --knowledge-base.",
                file=sys.stderr,
            )
        return 1

    result = response.json()

    # The synthesised answer is the assistant message; activity/references detail the
    # grounding. Shapes vary across preview versions, so read defensively.
    answer = ""
    for message in result.get("response", []):
        for part in message.get("content", []):
            if part.get("type") == "text":
                answer += part.get("text", "")
    print("\nAnswer:\n" + (answer or "(no synthesised answer - check 'references' below)"))

    references = result.get("references")
    if references:
        print(f"\nReferences ({len(references)}):")
        for ref in references:
            print(f"  - {ref.get('id', ref.get('refId', '?'))}: {ref.get('sourceData', ref.get('title', ''))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
