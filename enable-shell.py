#!/usr/bin/env python3
"""Step 5 in one go: give the step-4 hosted agent a shell on the jump host.

  1. reads the agent identity (private data plane: tunnel up, or --no-tunnel on the jump host),
  2. generates an ed25519 key pair in memory (never written to disk),
  3. deploys 05-agent-shell.bicepparam over ARM REST: Key Vault + secret + roles, and a
     VM runCommand that creates 'foundrydiag' (key accepted only from the agent subnet),
  4. posts a new agent version with the run_command tool and sends a test message.

No az command lines: ARM is called over REST, Bicep is compiled with the bicep CLI.
Re-running rotates the key.

Usage:
    python enable-shell.py
    python enable-shell.py --allow-sudo     # PoC only: passwordless sudo on the jump host
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from arm import Arm, compile_params

HERE = Path(__file__).parent

# hosted-agent.py has a dash in its name, so it is loaded by path.
_spec = importlib.util.spec_from_file_location("hosted_agent", HERE / "hosted-agent.py")
hosted = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hosted)


def new_key_pair(comment: str) -> tuple[str, str]:
    key = Ed25519PrivateKey.generate()
    private = key.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.OpenSSH, serialization.NoEncryption()
    ).decode()
    public = key.public_key().public_bytes(serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH).decode()
    return private, f"{public} {comment}"


def main() -> int:
    sys.stdout.reconfigure(errors="replace")
    parser = argparse.ArgumentParser(description="Step 5: give the hosted agent a shell on the jump host.")
    parser.add_argument("--name", default="hosted-agent", help="Hosted agent name (step 4).")
    parser.add_argument("--allow-sudo", action="store_true", help="PoC only: passwordless sudo for foundrydiag.")
    parser.add_argument("--message", default="Run hostname; id; ip -br a on the jump host", help="Test message.")
    parser.add_argument("--deployment", default="aigwp-gateway", help="Step-2 deployment name.")
    parser.add_argument("--gateway-deployment", default="aigwp-hosted-agent", help="Step-4 deployment name.")
    parser.add_argument("--shell-deployment", default="aigwp-agent-shell", help="Step-5 deployment name.")
    parser.add_argument("--timeout", type=int, default=900, help="Seconds to wait for the agent build.")
    parser.add_argument("--no-tunnel", action="store_true", help="Run on the jump host, without the SOCKS tunnel.")
    parser.add_argument("--proxy-port", type=int, default=None, help="SOCKS port (default: lab.json socksPort).")
    args = parser.parse_args()

    lab = json.loads((HERE / "params" / "lab.json").read_text())
    arm = Arm()
    out = arm.deployment_outputs(args.deployment)
    proxies = hosted.tunnel_proxies(args)
    if proxies is None and not args.no_tunnel:
        sys.exit("Open the tunnel first: ./connect.ps1 -TunnelOnly")
    endpoint = f"https://{out['accountName']}.services.ai.azure.com/api/projects/{out['projectName']}"
    api = hosted.DataPlane(endpoint, proxies)

    print("1/4 Agent identity")
    principal_id = hosted.agent_identity(api, args.name)
    print(f"    {principal_id}")

    print("2/4 New SSH key pair (in memory)")
    private_key, public_key = new_key_pair("foundrydiag")

    print(f"3/4 Deploy step 5: Key Vault + foundrydiag user (sudo: {args.allow_sudo})")
    compiled = compile_params(HERE / "05-agent-shell.bicepparam", {
        "AGENT_PRINCIPAL_ID": principal_id,
        "JUMP_SSH_PRIVATE_KEY": private_key,
        "JUMP_SSH_PUBLIC_KEY": public_key,
        "JUMP_ALLOW_SUDO": str(args.allow_sudo).lower(),
    })
    arm.deploy(args.shell_deployment, lab["location"], compiled)
    del private_key, compiled

    print("4/4 New agent version with run_command")
    gateway_url = arm.deployment_outputs(args.gateway_deployment).get("gatewayUrl")
    if not gateway_url:
        sys.exit(f"Deployment '{args.gateway_deployment}' has no gatewayUrl output. Deploy step 4 first.")
    env = hosted.shell_env(args.shell_deployment, args.allow_sudo)
    version = hosted.deploy(api, args.name, out["deploymentName"], gateway_url, env)
    hosted.wait_active(api, args.name, version, args.timeout)
    return hosted.invoke(api, args.name, args.message)


if __name__ == "__main__":
    raise SystemExit(main())
