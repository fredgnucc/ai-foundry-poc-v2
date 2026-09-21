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
| 2 | `02-gateway.bicep` | Foundry account + injection + model + project + PE, APIM Standard v2 + PE, diagnostics, and the association wiring them together | hourly (APIM) |
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
in the templates. Review at least `location`, `resourceGroupName`, `nameSeed` and
`publisherEmail`.

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

## Cost

This stack bills continuously whether or not you call it — APIM Standard v2,
Cosmos DB and AI Search are all hourly. `searchSku: basic` keeps the largest line
item down. **Tear it down when you are not using it.**

## Teardown

```powershell
az group delete --name rg-ai-gateway-priv3 --yes --no-wait
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
$rg   = 'rg-ai-gateway-priv3'
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
