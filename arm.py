"""Small Azure Resource Manager REST client: no `az` command lines.

Tokens come from azure-identity (AzureCliCredential, i.e. your `az login`), but every
call is plain HTTPS to management.azure.com, so az.cmd quoting on Windows can't break it.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

import requests
from azure.identity import AzureCliCredential

ARM = "https://management.azure.com"
DEPLOYMENTS_API = "2024-03-01"
TERMINAL = {"succeeded", "failed", "canceled"}


def default_subscription() -> str:
    """AZURE_SUBSCRIPTION_ID, else the default subscription of `az login` (no az call)."""
    if os.environ.get("AZURE_SUBSCRIPTION_ID"):
        return os.environ["AZURE_SUBSCRIPTION_ID"]
    profile = Path(os.environ.get("AZURE_CONFIG_DIR", Path.home() / ".azure")) / "azureProfile.json"
    try:
        subs = json.loads(profile.read_text(encoding="utf-8-sig"))["subscriptions"]
        return next(s["id"] for s in subs if s.get("isDefault"))
    except (OSError, KeyError, StopIteration, json.JSONDecodeError):
        sys.exit("No subscription: run `az login` (and `az account set`), or set AZURE_SUBSCRIPTION_ID.")


class Arm:
    def __init__(self, subscription_id: str | None = None) -> None:
        self.subscription_id = subscription_id or default_subscription()
        self.credential = AzureCliCredential()
        self.http = requests.Session()
        self.token = None

    def call(self, method: str, path: str, api_version: str, ok=(200, 201, 202, 204), **kwargs) -> requests.Response:
        if self.token is None or self.token.expires_on - time.time() < 300:
            self.token = self.credential.get_token(f"{ARM}/.default")
        sep = "&" if "?" in path else "?"
        response = self.http.request(
            method, f"{ARM}{path}{sep}api-version={api_version}",
            headers={"Authorization": f"Bearer {self.token.token}"}, timeout=120, **kwargs,
        )
        if response.status_code not in ok:
            sys.exit(f"{method} {path}\nHTTP {response.status_code}\n{response.text}")
        return response

    def deployment_path(self, name: str) -> str:
        return f"/subscriptions/{self.subscription_id}/providers/Microsoft.Resources/deployments/{name}"

    def deployment_outputs(self, name: str) -> dict:
        response = self.call("GET", self.deployment_path(name), DEPLOYMENTS_API, ok=(200, 404))
        if response.status_code == 404:
            sys.exit(f"Deployment '{name}' not found in subscription {self.subscription_id}.")
        outputs = response.json()["properties"].get("outputs") or {}
        return {key: value["value"] for key, value in outputs.items()}

    def deploy(self, name: str, location: str, compiled: dict, timeout: int = 1800) -> dict:
        """Subscription-scope deployment of a compiled .bicepparam; returns its outputs."""
        path = self.deployment_path(name)
        existing = self.call("GET", path, DEPLOYMENTS_API, ok=(200, 404))
        # ARM refuses to reuse a deployment name in another region (InvalidDeploymentLocation).
        if existing.status_code == 200 and existing.json().get("location") != location:
            print(f"  deleting old '{name}' record from {existing.json().get('location')}")
            self.call("DELETE", path, DEPLOYMENTS_API)
            while self.call("GET", path, DEPLOYMENTS_API, ok=(200, 404)).status_code == 200:
                time.sleep(5)

        body = {
            "location": location,
            "properties": {
                "mode": "Incremental",
                "template": json.loads(compiled["templateJson"]),
                "parameters": json.loads(compiled["parametersJson"])["parameters"],
            },
        }
        self.call("PUT", path, DEPLOYMENTS_API, json=body)
        start = time.time()
        while True:
            props = self.call("GET", path, DEPLOYMENTS_API).json()["properties"]
            state = str(props.get("provisioningState", "")).lower()
            if state in TERMINAL:
                break
            if time.time() - start > timeout:
                sys.exit(f"Deployment '{name}' still '{state}' after {timeout}s.")
            time.sleep(10)
        if state != "succeeded":
            sys.exit(f"Deployment '{name}' {state}:\n{json.dumps(props.get('error'), indent=2)}")
        print(f"  {name}: succeeded ({int(time.time() - start)}s)")
        return {key: value["value"] for key, value in (props.get("outputs") or {}).items()}

    def register_provider(self, namespace: str, timeout: int = 600) -> None:
        path = f"/subscriptions/{self.subscription_id}/providers/{namespace}"
        if self.call("GET", path, "2021-04-01").json().get("registrationState") == "Registered":
            return
        print(f"  registering {namespace}")
        self.call("POST", f"{path}/register", "2021-04-01")
        start = time.time()
        while self.call("GET", path, "2021-04-01").json().get("registrationState") != "Registered":
            if time.time() - start > timeout:
                sys.exit(f"{namespace} still not registered after {timeout}s.")
            time.sleep(10)

    def run_command_output(self, run_command_id: str) -> str:
        view = self.call("GET", f"{run_command_id}?$expand=instanceView", "2024-07-01").json()
        return view["properties"].get("instanceView", {}).get("output") or ""


def compile_params(param_file: Path, env: dict[str, str]) -> dict:
    """`bicep build-params --stdout` with extra variables for this process only."""
    exe = shutil.which("bicep") or str(Path.home() / ".azure" / "bin" / ("bicep.exe" if os.name == "nt" else "bicep"))
    if not Path(exe).exists() and not shutil.which(exe):
        sys.exit("Bicep CLI not found: install it with `az bicep install`.")
    result = subprocess.run(
        [exe, "build-params", str(param_file), "--stdout"],
        capture_output=True, text=True, env={**os.environ, **env},
    )
    if result.returncode != 0:
        sys.exit(f"bicep build-params {param_file.name} failed:\n{result.stderr}")
    return json.loads(result.stdout)


def host_key(run_command_output: str) -> str:
    """'ssh-ed25519 AAAA...' from the HOSTKEY line printed by the step-5 runCommand."""
    for line in run_command_output.splitlines():
        if line.startswith("HOSTKEY "):
            return line.removeprefix("HOSTKEY ").strip()
    sys.exit("The step-5 runCommand printed no HOSTKEY line. Re-run enable-shell.py.")
