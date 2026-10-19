#!/usr/bin/env python3
"""Deploy and test a Foundry hosted agent (private data plane).

A hosted agent is your own code that Foundry runs for you, one sandbox per session.
Like a prompt agent it lives only on the project data plane, so Bicep cannot create
it - step 4 (04-hosted-agent.bicep) only adds the gateway API it calls. This script:

  1. zips hosted-agent/ flat (main.py + requirements.txt - no Dockerfile, no registry),
  2. creates the agent with AI_GATEWAY_URL from step 4's outputs, or posts a new
     version if it exists (same zip and settings = same version),
  3. waits while Foundry installs requirements.txt (remote build) until it's active,
  4. sends one message to the agent's Responses endpoint and prints the reply.

Same network rules as agent.py: the data plane is private, so run it with the
connect.ps1 SOCKS tunnel open (auto-detected), or on the jump host with --no-tunnel.

Usage:
    python hosted-agent.py
    python hosted-agent.py --skip-deploy --message "Hello"
    python hosted-agent.py --enable-shell   # + run_command tool (step 5 for SSH)
    python hosted-agent.py --delete
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import sys
import time
import zipfile
from pathlib import Path

import requests
from azure.identity import AzureCliCredential

from agent import SCOPE, deployment_outputs, listening, socks_port

API_VERSION = "v1"
SOURCE = Path(__file__).parent / "hosted-agent"


class DataPlane:
    """Calls to the project data plane. Refreshes the token when it's close to expiry."""

    def __init__(self, endpoint: str, proxies: dict[str, str] | None) -> None:
        self.endpoint = endpoint
        self.http = requests.Session()
        self.http.proxies.update(proxies or {})
        self.credential = AzureCliCredential()
        self.token = None

    def call(self, method: str, path: str, *, query: str = "", headers: dict[str, str] | None = None, timeout=120, **kwargs) -> requests.Response:
        if self.token is None or self.token.expires_on - time.time() < 300:
            self.token = self.credential.get_token(SCOPE)
        url = f"{self.endpoint}{path}?api-version={API_VERSION}{query}"
        headers = {"Authorization": f"Bearer {self.token.token}", "Accept": "application/json", **(headers or {})}
        try:
            return self.http.request(method, url, headers=headers, timeout=timeout, **kwargs)
        except requests.exceptions.RequestException as exc:
            sys.exit(f"{method} {url} failed: {exc}\nAre you still on the private network (tunnel up, or on the jump host)?")


def fail(response: requests.Response) -> None:
    sys.exit(f"{response.request.method} {response.url}\nHTTP {response.status_code}\n{response.text}")


def build_zip(source: Path) -> bytes:
    """Flat, deterministic zip: the same files give the same bytes, so no new version."""
    files = sorted(
        path for path in source.rglob("*")
        if path.is_file() and not any(part.startswith(".") or part == "__pycache__" for part in path.relative_to(source).parts)
    )
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for path in files:
            info = zipfile.ZipInfo(path.relative_to(source).as_posix(), date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            # Unix regular file, rw-r--r--, like `zip -r`. Without the file-type bits the
            # remote build doesn't see the files ("No Python dependency manifest found").
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            archive.writestr(info, path.read_bytes())
    return buffer.getvalue()


def deploy(api: DataPlane, name: str, model: str, gateway_url: str, extra_env: dict[str, str]) -> str:
    code = build_zip(SOURCE)
    sha = hashlib.sha256(code).hexdigest()
    metadata = {
        "description": "Created by hosted-agent.py",
        "definition": {
            "kind": "hosted",
            "protocol_versions": [{"protocol": "responses", "version": "2.0.0"}],
            "cpu": "0.5",
            "memory": "1Gi",
            "code_configuration": {
                "runtime": "python_3_13",
                "entry_point": ["python", "main.py"],
                # Foundry runs pip install -r requirements.txt in the cloud.
                "dependency_resolution": "remote_build",
            },
            "environment_variables": {"AZURE_AI_MODEL_DEPLOYMENT_NAME": model, "AI_GATEWAY_URL": gateway_url, **extra_env},
        },
    }
    files = {
        "metadata": ("metadata.json", json.dumps(metadata), "application/json"),
        "code": (f"{name}.zip", code, "application/zip"),
    }
    print(f"Zip: {len(code)} bytes, sha256 {sha[:12]}...")

    existing = api.call("GET", f"/agents/{name}")
    if existing.status_code == 200:
        print(f"Agent '{name}' exists - posting a new version (an unchanged zip returns the current one).")
        response = api.call("POST", f"/agents/{name}", headers={"x-ms-code-zip-sha256": sha}, files=files, timeout=300)
    elif existing.status_code == 404:
        print(f"Creating agent '{name}'.")
        headers = {"x-ms-code-zip-sha256": sha, "x-ms-agent-name": name}
        response = api.call("POST", "/agents", headers=headers, files=files, timeout=300)
    else:
        fail(existing)
    if not response.ok:
        fail(response)
    body = response.json()
    latest = body.get("versions", {}).get("latest") or body
    return str(latest["version"])


def shell_env(shell_deployment: str) -> dict[str, str]:
    """Settings for run_command: sandbox always, jump host when step 5 is deployed."""
    env = {"ENABLE_SHELL": "true"}
    if shell_deployment:
        out = deployment_outputs(shell_deployment)
        env |= {
            "SSH_HOST": out["sshHost"],
            "SSH_PORT": str(out["sshPort"]),
            "SSH_USER": out["sshUser"],
            "SSH_KNOWN_HOST": out["sshKnownHost"],
            "SSH_VAULT_URL": out["vaultUri"],
            "SSH_SECRET_NAME": out["secretName"],
        }
    return env


def wait_active(api: DataPlane, name: str, version: str, timeout: int) -> None:
    start, last = time.time(), None
    while True:
        response = api.call("GET", f"/agents/{name}/versions/{version}")
        if not response.ok:
            fail(response)
        body = response.json()
        status = body.get("status")
        if status != last:
            print(f"  v{version}: {status} ({int(time.time() - start)}s)")
            last = status
        if status == "active":
            return
        if status == "failed":
            sys.exit(f"Build failed:\n{json.dumps(body.get('error'), indent=2)}")
        if time.time() - start > timeout:
            sys.exit(f"Still '{status}' after {timeout}s. Check the version in the portal, or rerun with a longer --timeout.")
        time.sleep(10)


def stream_logs(api: DataPlane, name: str, session_id: str, seconds: int = 30) -> None:
    """Print the session's container logs for a short while (startup errors, 424 session_not_ready)."""
    print(f"\nContainer logs (up to {seconds}s):", file=sys.stderr)
    response = api.call(
        "GET", f"/agents/{name}/sessions/{session_id}:logstream",
        headers={"Accept": "text/event-stream"}, stream=True, timeout=(10, seconds),
    )
    deadline = time.time() + seconds
    try:
        for line in response.iter_lines(decode_unicode=True):
            if line:
                print(f"  {line}", file=sys.stderr)
            if time.time() > deadline:
                break
    except requests.exceptions.RequestException:
        pass
    finally:
        response.close()


def invoke(api: DataPlane, name: str, message: str) -> int:
    print(f"\nYou  : {message}")
    response = api.call(
        "POST", f"/agents/{name}/endpoint/protocols/openai/responses",
        json={"input": message, "stream": False}, timeout=300,
    )
    session_id = response.headers.get("x-agent-session-id")
    print(f"(session {session_id}, region {response.headers.get('x-ms-region')})")
    if not response.ok:
        print(f"HTTP {response.status_code}\n{response.text}", file=sys.stderr)
        if session_id:
            stream_logs(api, name, session_id)
        return 1
    for item in response.json().get("output", []):
        kind = item.get("type")
        if kind == "function_call":
            print(f"Tool : {item.get('name')}({item.get('arguments')})")
        elif kind == "function_call_output":
            print(f"     -> {item.get('output')}")
        elif kind == "message":
            print("Agent: " + "".join(part.get("text", "") for part in item.get("content", [])))
    return 0


def delete(api: DataPlane, name: str) -> int:
    # force=true also ends open sessions, which would otherwise block the delete (409).
    response = api.call("DELETE", f"/agents/{name}", query="&force=true")
    if response.status_code == 404:
        print(f"No agent named '{name}'.")
    elif response.ok:
        print(f"Deleted agent '{name}' with all its versions and sessions.")
    else:
        fail(response)
    return 0


def tunnel_proxies(args: argparse.Namespace) -> dict[str, str] | None:
    if args.no_tunnel:
        return None
    port = args.proxy_port or socks_port()
    if not listening(port):
        print(
            f"No SOCKS tunnel on 127.0.0.1:{port}. Foundry's data plane is private, so calls\n"
            "will be refused (HTTP 403). Run connect.ps1 first, or run this on the jump host\n"
            "with --no-tunnel.\n"
        )
        return None
    print(f"Routing through the SOCKS tunnel on 127.0.0.1:{port}.")
    url = f"socks5h://127.0.0.1:{port}"
    return {"https": url, "http": url}


def main() -> int:
    sys.stdout.reconfigure(errors="replace")
    parser = argparse.ArgumentParser(description="Deploy and test a Foundry hosted agent.")
    parser.add_argument("--deployment", default="aigwp-gateway", help="Step-2 Bicep deployment name.")
    parser.add_argument(
        "--gateway-deployment",
        default="aigwp-hosted-agent",
        help="Step-4 Bicep deployment name (its gatewayUrl output becomes AI_GATEWAY_URL).",
    )
    parser.add_argument("--name", default="hosted-agent", help="Agent name.")
    parser.add_argument(
        "--message",
        default="Where do you run? Use your tool, then give the hostname, the source IP and the gateway IP.",
        help="Message to send once the agent is active.",
    )
    parser.add_argument("--skip-deploy", action="store_true", help="Only send the message to the existing agent.")
    parser.add_argument(
        "--enable-shell",
        action="store_true",
        help="Give the agent the run_command tool (Linux commands in its sandbox). Trusted lab use only.",
    )
    parser.add_argument(
        "--allow-sudo",
        action="store_true",
        help="With --enable-shell: tell the agent it may use sudo on the jump host (needs the sudoers file, README Step 5).",
    )
    parser.add_argument(
        "--shell-deployment",
        default="aigwp-agent-shell",
        help="Step-5 deployment whose outputs let run_command SSH to the jump host. '' = sandbox only.",
    )
    parser.add_argument("--delete", action="store_true", help="Delete the agent with all its versions and sessions.")
    parser.add_argument("--timeout", type=int, default=900, help="Seconds to wait for the build (default 900).")
    parser.add_argument(
        "--no-tunnel",
        action="store_true",
        help="Do not route through the SOCKS tunnel (use when running on the jump host).",
    )
    parser.add_argument("--proxy-port", type=int, default=None, help="SOCKS port (default: lab.json socksPort).")
    args = parser.parse_args()

    out = deployment_outputs(args.deployment)
    endpoint = f"https://{out['accountName']}.services.ai.azure.com/api/projects/{out['projectName']}"
    api = DataPlane(endpoint, tunnel_proxies(args))

    if args.delete:
        return delete(api, args.name)
    if not args.skip_deploy:
        # The agent reaches the model only through the step-4 gateway API.
        gateway_url = deployment_outputs(args.gateway_deployment).get("gatewayUrl")
        if not gateway_url:
            sys.exit(f"Deployment '{args.gateway_deployment}' has no gatewayUrl output. Deploy step 4 first.")
        print(f"AI gateway: {gateway_url}")
        extra_env = shell_env(args.shell_deployment) if args.enable_shell else {}
        if args.enable_shell and args.allow_sudo:
            extra_env["JUMP_ALLOW_SUDO"] = "true"
        version = deploy(api, args.name, out["deploymentName"], gateway_url, extra_env)
        wait_active(api, args.name, version, args.timeout)
    return invoke(api, args.name, args.message)


if __name__ == "__main__":
    raise SystemExit(main())
