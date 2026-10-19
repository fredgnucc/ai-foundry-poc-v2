# Azure AI Foundry — Private AI Gateway

Deploys an AI Foundry agent whose **outbound traffic stays inside your virtual
network**, calling its model through an API Management **AI Gateway** over private
networking — on APIM **Standard v2**, no Premium v2 required.

The decisive piece is **agent network injection**: the Foundry account is created
with `networkInjections.scenario=agent` on a subnet delegated to
`Microsoft.App/environments`. That makes the agent runtime run in *your* subnet
instead of on the Microsoft-managed platform network, so a private gateway is
actually reachable. Everything else follows from that one choice.

Everything is Bicep, deployed in **three steps** with plain `az deployment sub
create`. There is no orchestrator script and no all-in-one template: the three
steps are the deployment.

| Step | Template | Creates | Bills |
|------|----------|---------|-------|
| 1 | `01-infra.bicep`   | Resource group, VNet + 4 subnets (2 delegated), NSGs, private DNS zones, jump host | ~nothing |
| 2 | `02-gateway.bicep` | Foundry account + injection + model + project + PE, APIM Standard v2 + PE, diagnostics, and the association wiring them together. With `separateModelAccount` the model goes into its own account (`aim-…`) | hourly (APIM) |
| 3 | `03-runtime.bicep` | Cosmos / AI Search / Storage (+ PEs), connections, RBAC, and the project **capability host** that provisions the in-VNet data proxy | hourly (Cosmos, Search) |

### The three layers people conflate

| Layer | Decides | Set where |
|-------|---------|-----------|
| **Account** | which subnet all agent infra uses | `networkInjections`, at creation (step 2) |
| **Project** | whether the data proxy is deployed + whose storage holds agent state | the **capability host** (step 3) |
| **Agent** | prompt vs hosted | the agent definition |

A **prompt** agent runs on Microsoft-managed compute and uses the single-tenant
data proxy for **all** its outbound calls. Setting the project capability host in
step 3 is what deploys that proxy into your delegated subnet — and is therefore
what moves the agent's egress from a public Microsoft IP to a `10.x` address in
your VNet.

## Prerequisites

- Azure CLI, logged in: `az login`
- Bicep CLI (`az bicep install`)
- PowerShell 7+ (for `connect.ps1`)
- An SSH key pair (`ssh-keygen -t ed25519`)
- Contributor + User Access Administrator (or Owner) on the subscription

## Configure

Structural settings live in `params/lab.json` — one source of truth, no defaults
in the templates. Review at least `location`, `resourceGroupName`, `nameSeed`,
`publisherEmail`, and the model (`modelName`, `modelVersion`, `modelSku`,
`separateModelAccount`).

### Choose a region

Two options. Set the three values in `params/lab.json`:

| Region | `location` | `resourceGroupName` | `nameSeed` | Notes |
|---|---|---|---|---|
| Sweden Central | `swedencentral` | `rg-ai-gateway-priv4` | `v2` | The first lab ran here. Busy: in Oct 2026 new **AI Search** services failed with `InsufficientResourcesAvailable` |
| Norway East | `norwayeast` | `rg-ai-gateway-priv5` | `v3` | Current `lab.json`. Hosted agents, `gpt-5.6-sol` DataZoneStandard, APIM Standard v2, the VM size and AI Search all checked available |

> **Capacity can be a problem.** A region can run out of capacity for one
> service (AI Search, a VM size, a model SKU) while the rest works. Step 3 then
> fails with `InsufficientResourcesAvailable`. Retry later, or move the **whole**
> lab: the Foundry resource must be in the same region as its VNet, and capability
> hosts can't be updated to add Search later. To test a region first, create a
> throwaway basic Search service there and delete it. Model quota for DataZone
> and Global SKUs is shared across regions — check it with
> `az cognitiveservices usage list -l <region>`.

> **Running more than one instance in the same subscription?** Foundry accounts
> and APIM soft-delete, and every resource name is derived from
> `resourceGroupName` + `nameSeed`. Give each instance a distinct
> `resourceGroupName` (or `nameSeed`) so they don't collide.

Two values are **not** committed — set them in your shell before step 1:

```powershell
# required: your SSH public key
$env:LAB_SSH_PUBKEY = (Get-Content "$env:USERPROFILE\.ssh\id_ed25519.pub" -Raw).Trim()

# optional: jump host admin user (defaults to azureuser)
# $env:LAB_ADMIN_USER = 'azureuser'

# optional: restrict who can SSH the jump host (defaults to "*", any address -
# access is gated by your key). Lock it to your IP if you prefer:
# $env:LAB_SSH_SOURCE = "$((Invoke-RestMethod https://api.ipify.org))/32"
```

## Deploy

```powershell
# Step 1 - infrastructure (~3 min)
az deployment sub create --name aigwp-infra `
  --location swedencentral --parameters 01-infra.bicepparam

# Step 2 - Foundry + AI Gateway (~3 min; APIM Standard v2 provisions fast)
az deployment sub create --name aigwp-gateway `
  --location swedencentral --parameters 02-gateway.bicepparam

# Step 3 - agent runtime / capability host (~10 min)
az deployment sub create --name aigwp-runtime `
  --location swedencentral --parameters 03-runtime.bicepparam
```

Preview any step first with `what-if` instead of `create`.

The commands are the same for both regions. `--location` is only where ARM stores
the deployment record; resources go to `location` in `lab.json` (see
[Choose a region](#choose-a-region)). Keep `swedencentral` here even when the lab
runs in Norway East — a deployment name can't change its record location.

## Create the agent

The account's public data plane is disabled, so `ai.azure.com`'s client-side
calls to `<account>.services.ai.azure.com` only resolve inside the VNet. Reach the
portal through the jump host:

```powershell
./connect.ps1        # opens a SOCKS tunnel and launches Edge through it
```

In the portal, open the project and create a **prompt** agent on the deployed
model. Chat with it to generate traffic.

### Or create it from the command line

`agent.py` does the same over the Foundry data-plane REST API — no portal clicks.
Because the data plane is private it has to run through the VNet: keep
`connect.ps1`'s SOCKS tunnel open (the script auto-detects it) or run it on the
jump host with `--no-tunnel`.

```powershell
pip install "requests[socks]" azure-identity
python agent.py                 # prompt agent routed through the AI Gateway
python agent.py --direct        # call the model directly, bypassing APIM
```

It reads the step-2 (`aigwp-gateway`) deployment outputs, mints an Entra token for
the data plane, and POSTs a prompt agent — then chat with it in the portal to
generate traffic.

## Prove it's private

Every model call passes through APIM, so the gateway log records the agent's
source address. Open the Log Analytics workspace (`log-…`) → **Logs**, disable the
Queries hub popup, set the range to the last 24 h, and run — see `queries.kql`:

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| extend Path = iff(CallerIpAddress startswith "10.", "PRIVATE (snet-agent)", "PUBLIC (internet)")
| project TimeGenerated, Path, CallerIpAddress, ResponseCode, BackendResponseCode
| order by TimeGenerated asc
```

Before the capability host exists the caller IP is a public Microsoft address;
after step 3 it is a `10.x` address from the delegated agent subnet. That single
column flip is the entire result. (Delegated-subnet IP usage is exposed nowhere
else in Azure, so this log is the only instrument.)

Because Azure only allows APIM to be created with public access **enabled**, this
instance ships with `allowPublicGatewayAccess: true`: the gateway keeps a public
inbound endpoint *and* a private endpoint. The agent still reaches it privately —
a `10.x` caller address over private DNS from inside the VNet — so the column flip
above holds regardless. To close the public inbound entirely, see the optional
section at the end. If instead the agent fails to reach the model, that points at the
data-proxy → private-endpoint DNS path rather than at public access.

## Gateway-only model access (`separateModelAccount`, option C)

Routing through APIM is only a choice in the agent's code: an agent's identity can
call the models of its **own project's account** through the project endpoint
without any role (see Step 5). Network rules can't block that path either, because
the hosting platform uses the same endpoint for sessions and state.

With `"separateModelAccount": true` in `lab.json`, step 2 moves the chat model out:

| Account | Holds | Who can call the model |
|---------|-------|------------------------|
| `aif-…` (project) | project, agents, embedding (step 4) | nobody: no chat model here |
| `aim-…` (model only) | the chat model; private endpoint only; `disableLocalAuth: true`; no projects | only APIM's managed identity (Cognitive Services OpenAI User) |

So every chat call has to go through the gateway. In the portal, pick the
gateway connection's model (`<account>/<model>`), not a bare deployment.
`false` keeps the old layout (model in the project's account).

`modelSku` sets the deployment SKU. `GlobalStandard` and `DataZoneStandard` have
separate quotas; the default here is `DataZoneStandard` (EU data zone).

Check it after step 2 (tunnel open):

| Test | Expected with option C |
|------|------------------------|
| `python agent.py` | works, through APIM |
| `python agent.py --direct` (bare deployment, no gateway) | fails: the project's account has no such deployment |
| Hosted agent (step 5) | works, through APIM |
| From the hosted agent's shell (step 6): call `https://aim-….services.ai.azure.com/openai/v1/responses` with its own token | `401`/`403`: no role on `aim-…` |

Not covered: the embedding model stays in the project's account (step 4 needs it
there), so agents can still call embeddings directly.

## Step 4 — Foundry IQ knowledge test (optional)

This step is **optional** and **additive**: it does not redeploy or modify steps
1–3. It proves that *knowledge retrieval* also stays on the private network. Foundry
IQ is a knowledge layer built on Azure AI Search — a **knowledge base** orchestrates
*agentic retrieval* over your data and returns a grounded, cited answer. The lab
already ships the private AI Search from step 3; three small additions complete it.

**1. Add an embedding model** (a new deployment on the existing account — the chat
model is untouched). Foundry IQ needs it to vectorize content:

```powershell
az deployment sub create --name aigwp-foundry-iq `
  --location swedencentral --parameters 04-foundry-iq.bicepparam
```

**2. Enable the free semantic ranker** on the Search service — agentic retrieval
uses it to rerank. Non-destructive and reversible; it recreates nothing. Portal:
Search service → **Settings → Semantic ranker → Free**. Or from the CLI:

```powershell
$search = az deployment sub show --name aigwp-foundry-iq `
  --query properties.outputs.searchName.value -o tsv
$rg = (Get-Content params\lab.json -Raw | ConvertFrom-Json).resourceGroupName
$id = az search service show --name $search -g $rg --query id -o tsv
$body = New-TemporaryFile
'{"properties":{"semanticSearch":"free"}}' | Set-Content $body -Encoding ascii
az rest --method patch `
  --url ('https://management.azure.com{0}?api-version=2024-06-01-preview' -f $id.Trim()) `
  --body "@$body"
Remove-Item $body
```

**3. Create the knowledge base** with the portal wizard (over the tunnel, so the
private Search is reachable):

```powershell
./connect.ps1        # SOCKS tunnel + Edge, as in step "Create the agent"
```

In the portal use **Foundry IQ** (or AI Search → *Import and vectorize data*) to
build a knowledge base named as in `lab.json` (`knowledgeBaseName`, default
`lab-knowledge`): upload a couple of small documents, pick the existing Search
service and the `text-embedding-3-large` deployment, and let the wizard create the
index, vectorizer, semantic config and knowledge source. The wizard is the robust
path for this fast-moving preview surface, so the template does not script it.

**4. Query it privately** with the retrieve API — like `agent.py`, it auto-detects
the tunnel and reads the Search name from the step-3 outputs. You need the **Search
Index Data Reader** role on the Search service:

```powershell
pip install "requests[socks]" azure-identity      # once
python foundry-iq-test.py --question "What does the sample document say about ...?"
```

The retrieve call goes to `<search>.search.windows.net`, which resolves to a
private endpoint over the VNet's private DNS — so, exactly like the agent's model
calls, knowledge retrieval never leaves your network. The knowledge base is also
exposed as an **MCP** endpoint, which is how a Foundry agent consumes it over that
same private path.

> One honest gap: at **ingestion** time the Search → Foundry embedding call still
> uses the Foundry trusted-service bypass rather than pure Private Link. Query-time
> retrieval (what this test exercises) is fully private.

Teardown needs nothing extra — the embedding deployment and the knowledge base live
in the resource group, so the `az group delete` below removes them.

## Step 5 — Foundry hosted agent through the AI gateway (optional)

Also **optional** and **additive**. A **hosted** agent is your own code — here
Microsoft Agent Framework in `hosted-agent/main.py` — that Foundry builds and runs
for you. Each session gets its own sandbox, and because the account was created
with `networkInjections`, the sandboxes run inside this VNet. No Dockerfile and no
registry: you upload a zip of the source and Foundry runs `pip install` for you.

Like the prompt agent, it reaches the model **through APIM**, so the gateway sees
every call. It uses a second, **keyless** API on the step-2 gateway:

| Piece | Created by | Why |
|-------|------------|-----|
| API `<account>-entra` on the gateway — `POST /v1/responses` only | `05-hosted-agent.bicep` | The agent signs in with its own Microsoft Entra identity (token audience `https://ai.azure.com`), so there's no key to store. APIM checks the token, removes it, and calls the model with its own managed identity (the step-2 backend). |
| The agent (zip → remote build → version), with `AI_GATEWAY_URL` | `hosted-agent.py` | Agents are data-plane objects, so Bicep can't create them — same reason as `agent.py`. |

```powershell
# 1. The gateway API (once)
az deployment sub create --name aigwp-hosted-agent `
  --location swedencentral --parameters 05-hosted-agent.bicepparam

# 2. Deploy + test - tunnel open, like agent.py (or on the jump host with --no-tunnel)
pip install "requests[socks]" azure-identity      # once
python hosted-agent.py
```

The script reads the API address from step 5's `gatewayUrl` output, zips
`hosted-agent/` flat (`main.py` + `requirements.txt`), creates the agent — or posts a
new version when the code or settings changed (same zip and settings = same version,
so re-runs are safe) — waits about a minute for the build to become `active`, then
sends one message to the agent's Responses endpoint:

```text
AI gateway: https://apim-aigwp-<suffix>.azure-api.net/aif-aigwp-<suffix>-entra/v1
  v4: active (52s)
Tool : where_am_i(...)
     -> {"hostname": "adc-sandbox", ..., "ai_gateway_ip": "10.20.2.7", "source_ip": "169.254.0.2"}
Agent: I run on hostname `adc-sandbox`, with source IP `169.254.0.2` and gateway IP `10.20.2.7`.
```

The sandbox resolved APIM's private endpoint (`10.20.2.7`) over the VNet's private
DNS. `169.254.0.2` is the sandbox's own NAT'd address; its subnet IP isn't visible
from inside — but APIM sees it. The proof is in the gateway log (`queries.kql` #7):

| TimeGenerated (UTC) | CallerIpAddress | ResponseCode | BackendResponseCode |
|---------------------|-----------------|--------------|---------------------|
| 2026-10-15 13:45:19 | `10.20.1.87` | 200 | 200 |
| 2026-10-15 13:45:22 | `10.20.1.87` | 200 | 200 |

`10.20.1.87` is in `snet-agent`. One question = two calls: the tool call, then the
final answer.

The API's sign-in check, tested with curl from the jump host:

| Call | Result |
|------|--------|
| No token | `401` Azure AD JWT not present |
| Token for another audience (`https://cognitiveservices.azure.com`) | `401` Invalid Azure AD JWT |
| Another path (`GET /v1/models`) | `404` |
| Token for `https://ai.azure.com` | `200` |

```powershell
python hosted-agent.py --skip-deploy --message "Hello"   # just chat
python hosted-agent.py --delete                          # agent + versions + sessions
```

- **The code does the routing, not RBAC.** Learn: *"The agent identity can access
  model inferencing through the project endpoint and session storage by default"*
  ([Hosted agents](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agents)).
  Tested: with no role on the account, the previous version (direct calls through
  the project endpoint) kept answering. So whoever deploys agent code can skip the
  gateway. To make APIM the only way, the model must live in an account the project
  can't reach (not built here).
- Only model calls go through APIM. The hosting layer still uses the project
  endpoint for its own state (sessions, stored responses).
- The check accepts **any** identity in the tenant that can reach APIM privately.
  To allow only this agent, list its identity in `<client-application-ids>` in
  `modules/policy-entra.xml` (not tested here).
- No token limit on this API: step 2's `llm-token-limit` lives in the step-2 API
  policy and product. Add one to `policy-entra.xml` if you need it.
- A call on a new session takes up to ~30 s while the sandbox starts.
- A failed build prints the version's `error` (with the pip line); a failed call
  prints the session's container logs.
- To see it in the portal, open the project's **Agents** page through `connect.ps1`.

Teardown needs nothing extra — the agent lives in the project and the API in APIM,
and both go with the resource group.

## Step 6 — let the hosted agent run Linux commands (optional, trusted lab only)

`python hosted-agent.py --enable-shell` gives the agent one tool, `run_command`.
The model picks the command; it runs either:

| `target` | Where | As |
|----------|-------|----|
| `sandbox` | The agent's own sandbox (`/bin/sh`) | root of the sandbox |
| `jump` | The jump host over SSH (`10.20.3.4:2222`, private) | `foundrydiag` — no sudo |

Limits (`hosted-agent/execution.py`): 60 s per command (whole process group
killed), 16 KiB of output, one command at a time, host key pinned (an unknown
key is refused). The tool is only added when `ENABLE_SHELL=true`.

What step 6 adds:

| Piece | Where | Why |
|-------|-------|-----|
| Key Vault `kv-<prefix>-<suffix>` — RBAC, public access off, private endpoint in `snet-pe` + `privatelink.vaultcore.azure.net` zone | `06-agent-shell.bicep` | Holds the SSH private key. The secret is written through ARM, so you need no network path to the vault. |
| **Key Vault Secrets User** on that one secret for the agent identity and the project identity | `modules/agent-shell.bicep` | The sandbox reads the key with `DefaultAzureCredential`. |
| User `foundrydiag` on the jump host, key only from `10.20.1.0/24`, no forwarding | over SSH (below) | Bicep doesn't manage users inside the VM. |

```powershell
# 1. Key pair (temp folder, never the repo) + jump-host user
$d = "$env:TEMP\agentkey"; mkdir $d -Force | Out-Null
ssh-keygen -q -t ed25519 -N '' -C foundrydiag -f "$d\id"   # -N '' = no passphrase (not '""')
$pub = (Get-Content "$d\id.pub" -Raw).Trim()
ssh -p 2222 azureuser@<jump-public-ip> "id foundrydiag || sudo useradd -m -s /bin/bash foundrydiag; sudo install -d -m 700 -o foundrydiag -g foundrydiag /home/foundrydiag/.ssh; echo 'from=""10.20.1.0/24"",no-port-forwarding,no-agent-forwarding,no-X11-forwarding $pub' | sudo tee /home/foundrydiag/.ssh/authorized_keys; sudo chown foundrydiag: /home/foundrydiag/.ssh/authorized_keys; sudo chmod 600 /home/foundrydiag/.ssh/authorized_keys"

# 2. Vault + secret + roles. AGENT_PRINCIPAL_ID = instance_identity.principal_id of the agent
$env:AGENT_PRINCIPAL_ID   = '<agent identity>'
$env:JUMP_HOST_KEY        = (ssh -p 2222 azureuser@<jump-public-ip> 'cut -d" " -f1,2 /etc/ssh/ssh_host_ed25519_key.pub')
$env:JUMP_SSH_PRIVATE_KEY = Get-Content "$d\id" -Raw
az deployment sub create --name aigwp-agent-shell `
  --location swedencentral --parameters 06-agent-shell.bicepparam
Remove-Item -Recurse -Force $d; Remove-Item Env:JUMP_SSH_PRIVATE_KEY

# 3. New agent version with the tool + SSH_* settings from step 6's outputs
python hosted-agent.py --enable-shell --message "Run hostname; id; ip -br a on the jump host"
# sandbox only, without step 6:  --enable-shell --shell-deployment ''
```

Tested (2026-10-16):

```text
Tool : run_command({"command":"hostname; id; uptime; ip -br a","target":"jump"})
     -> {"status": "completed", "exit_code": 0, "output": "vm-aigwp-jump\nuid=1001(foundrydiag) ..."}
```

The jump host's sshd log shows the login came from the agent subnet:
`Accepted publickey for foundrydiag from 10.20.1.124`.

**Risks — this is a remote shell driven by a model:**

- Anyone who can chat with the agent can run commands. Sandbox commands can read
  its environment and get tokens for the agent identity (Key Vault secret
  included). The instructions forbid it (the model refused when asked), but
  instructions are not a security boundary.
- Command output goes back into the model, so a file or web page can carry a
  prompt injection.
- No sudo is not read-only: `foundrydiag` can still write its home, use the
  network, and use CPU.
- To turn it off: redeploy without `--enable-shell`, and/or delete the
  `jump-ssh-key` secret or `foundrydiag`'s `authorized_keys`.

Teardown: goes with the resource group. The vault soft-deletes for 7 days; run
`az keyvault purge --name kv-<prefix>-<suffix>` before redeploying the same name.

**Full sudo ("yolo" mode, PoC only).** Give `foundrydiag` passwordless sudo and
tell the agent it may use it:

```powershell
ssh -p 2222 azureuser@<jump-public-ip> "echo 'foundrydiag ALL=(ALL) NOPASSWD:ALL' > /tmp/fd && sudo visudo -cf /tmp/fd && sudo install -m 440 /tmp/fd /etc/sudoers.d/90-foundrydiag && rm /tmp/fd"
python hosted-agent.py --enable-shell --allow-sudo --message "Install cowsay on the jump host and make it say hello"
# undo: sudo rm /etc/sudoers.d/90-foundrydiag, then redeploy without --allow-sudo
```

Tested: the agent ran `sudo -n apt-get install -y cowsay` and printed the cow.
With sudo the model is root on the jump host, which is also your SOCKS
entry point: it can change sshd, firewall or keys and lock you out. Fix from the
portal (Run command / Serial console) or redeploy the VM.

## Cost

This stack bills continuously whether or not you call it — APIM Standard v2,
Cosmos DB and AI Search are all hourly. `searchSku: basic` keeps the largest line
item down. **Tear it down when you are not using it.**

## Teardown

```powershell
az group delete --name (Get-Content params\lab.json -Raw | ConvertFrom-Json).resourceGroupName --yes --no-wait
# Foundry accounts and APIM soft-delete; purge them if you will redeploy the same names:
#   az cognitiveservices account purge ...
#   az apim deletedservice purge ...
```

## Caveats

- **The capability host is a one-way door.** It cannot be updated once created; to
  change it you delete and recreate the project.
- **No data migration.** Agents and threads created before step 3 live in
  Microsoft-managed storage and are not moved to your Cosmos/Storage. Recreate any
  agent after step 3.
- **Injection is set at account creation only** — it cannot be added to an existing
  account.

## Optional — close public gateway exposure

This step is **optional**. Everything above already works with APIM's public
inbound left enabled: the agent reaches the gateway privately regardless. Do this
only if you also want the gateway's inbound endpoint closed to the internet.

APIM must be **created** with public access enabled, so step 2 ships with
`allowPublicGatewayAccess: true` — the gateway has both a public inbound endpoint
and a private endpoint, and the agent always uses the private endpoint.

Once step 2 has created APIM **and its private endpoint**, close the public
inbound path with a single targeted update — no full redeploy needed:

```powershell
# Disable public inbound; the private endpoint becomes the only way in.
$rg   = (Get-Content params\lab.json -Raw | ConvertFrom-Json).resourceGroupName
$apim = az apim list -g $rg --query "[0].name" -o tsv
$id   = az apim show -g $rg -n $apim --query id -o tsv

# 'az apim update' pins an API version the StandardV2 SKU rejects, so PATCH the
# resource directly at a supported api-version. -f keeps the '?api-version' query
# string intact; a body file avoids az.cmd stripping the JSON quotes on Windows.
$url = 'https://management.azure.com{0}?api-version=2024-05-01' -f $id
'{"properties":{"publicNetworkAccess":"Disabled"}}' | Set-Content body.json -Encoding ascii
az rest --method patch --url $url --body '@body.json'; Remove-Item body.json

# Verify (the update is async - allow a few minutes to commit)
az apim show -g $rg -n $apim --query publicNetworkAccess -o tsv   # -> Disabled
```

The same operation — with live APIM discovery, idempotency, and an `-Access`
switch to choose the direction — is wrapped in `apim-public-access.ps1`:

```powershell
pwsh -File .\apim-public-access.ps1                    # close public inbound (default)
pwsh -File .\apim-public-access.ps1 -Access Enabled    # reopen it
pwsh -File .\apim-public-access.ps1 -NoWait            # fire the update, check back later
```

Disabling public access is rejected at *creation* (it fails with
`ActivateServiceWithPrivateEndpointAccessNotAllowed`) but accepted as an *update*
once the private endpoint exists. The template equivalent is to set
`allowPublicGatewayAccess: false` in `lab.json` and re-apply step 2; the CLI
above is faster for a single property (and sidesteps the StandardV2 api-version
quirk that breaks `az apim update`). Either way the agent path is
unaffected — administer and test the closed gateway from the step-1 jump host
(`connect.ps1`).
