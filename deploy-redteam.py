"""Deploy the isolated demo without granting access to the existing shell or Key Vault."""

import argparse
import importlib.util
import json
from pathlib import Path
import sys

from arm import Arm

HERE = Path(__file__).parent
spec = importlib.util.spec_from_file_location("hosted_agent", HERE / "hosted-agent.py")
hosted = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hosted)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--no-tunnel", action="store_true")
    parser.add_argument("--proxy-port", type=int)
    parser.add_argument("--timeout", type=int, default=1200)
    parser.add_argument("--skip-deploy", action="store_true")
    parser.add_argument("--message", default="Run the secret demo and show the actual results.")
    args = parser.parse_args()
    config = json.loads((HERE / "params" / "redteam.json").read_text())
    name = config["agentName"]
    if not name.startswith("redteam-") or not all(c.isalnum() or c == "-" for c in name):
        sys.exit("The isolated demo name must start with redteam- and use letters, digits, or hyphens.")
    arm = Arm()
    out = arm.deployment_outputs("aigwp-gateway")
    gateway = arm.deployment_outputs("aigwp-hosted-agent")["gatewayUrl"]
    proxies = hosted.tunnel_proxies(args)
    if proxies is None and not args.no_tunnel:
        sys.exit("Open connect.ps1 -TunnelOnly first.")
    api = hosted.DataPlane(
        f"https://{out['accountName']}.services.ai.azure.com/api/projects/{out['projectName']}", proxies,
    )
    existing = api.call("GET", f"/agents/{name}")
    if existing.status_code == 200:
        env = existing.json()["versions"]["latest"]["definition"].get("environment_variables", {})
        if env.get("DEMO_KIND") != "isolated-pyrit":
            sys.exit("Refusing to overwrite an agent that was not created by this demo.")
    elif existing.status_code != 404:
        hosted.fail(existing)
    if not args.skip_deploy:
        version = hosted.deploy(
            api, name, out["deploymentName"], gateway, {"DEMO_KIND": "isolated-pyrit"},
            source=HERE / "redteam-agent", cpu=config["cpu"], memory=config["memory"],
        )
        hosted.wait_active(api, name, version, args.timeout)
    return hosted.invoke(api, name, args.message)


if __name__ == "__main__":
    raise SystemExit(main())
