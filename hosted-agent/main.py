"""Hosted agent for the private lab: Microsoft Agent Framework on the Responses protocol.

hosted-agent.py zips this folder and Foundry builds it (code deploy, remote_build):
no Dockerfile, no registry. Each session runs in its own sandbox. The platform
injects FOUNDRY_PROJECT_ENDPOINT; hosted-agent.py sets AZURE_AI_MODEL_DEPLOYMENT_NAME.
"""

import json
import os
import socket
from urllib.parse import urlparse

from agent_framework import Agent, tool
from agent_framework.foundry import FoundryChatClient
from agent_framework_foundry_hosting import ResponsesHostServer
from azure.identity import DefaultAzureCredential


@tool(approval_mode="never_require")
def where_am_i() -> str:
    """Report where this agent runs: sandbox hostname, the IP the Foundry endpoint resolves to, and the local source IP used to reach it."""
    foundry = urlparse(os.environ["FOUNDRY_PROJECT_ENDPOINT"]).hostname
    facts = {"hostname": socket.gethostname(), "foundry_endpoint": foundry}
    try:
        facts["foundry_endpoint_ip"] = socket.gethostbyname(foundry)
        # A UDP "connect" only picks the route (nothing is sent) and reveals the local source IP.
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.connect((facts["foundry_endpoint_ip"], 443))
            facts["source_ip"] = probe.getsockname()[0]
    except OSError as exc:
        facts["error"] = str(exc)
    return json.dumps(facts)


def main() -> None:
    client = FoundryChatClient(
        project_endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
        model=os.environ["AZURE_AI_MODEL_DEPLOYMENT_NAME"],
        credential=DefaultAzureCredential(),
    )
    agent = Agent(
        client=client,
        instructions=(
            "You are a concise assistant running as a Foundry hosted agent in a private lab. "
            "Answer in one or two short sentences. Use where_am_i when asked where you run."
        ),
        tools=[where_am_i],
        # The hosting platform keeps the conversation history, so the model service doesn't store it.
        default_options={"store": False},
    )
    ResponsesHostServer(agent).run()


if __name__ == "__main__":
    main()
