# Infrastructure

Infrastructure as Code (Bicep) for both applications in this repository, plus the one-time Azure and GitHub setup needed before the pipelines can deploy.

Every step is written twice: once for the **Azure Portal** and once for the **Azure CLI**. Use whichever you prefer. The CLI version is the one to keep in a runbook because it is repeatable.

```text
infrastructure/
├── blog-starter/
│   ├── main.bicep              Static Web App, Application Insights, availability test, alert
│   └── main.bicepparam
└── contoso-university/
    ├── main.bicep              Wires the modules together, adds alerts
    ├── main.bicepparam
    └── modules/
        ├── monitoring.bicep    Log Analytics, Application Insights, action group
        ├── network.bicep       VNet, subnets, private DNS zones
        ├── data.bicep          Azure SQL, Key Vault, Storage, private endpoints, RBAC
        ├── web.bicep           App Service plan, web + api apps, staging slots, autoscale
        └── frontdoor.bicep     Front Door Premium, WAF policy, routes, health probes
```

The pipeline for this folder is [`.github/workflows/infrastructure.yml`](../.github/workflows/infrastructure.yml). It runs whenever a file under `infrastructure/` changes:

| Trigger | What happens |
|---|---|
| Pull request | `bicep lint` and `bicep build` for both stacks, then a `what-if` against **dev** written to the job summary |
| Push to `main` | Lint and build, deploy **dev**, then wait for an approval and deploy **prod** (with a what-if first) |
| Manual (`workflow_dispatch`) | Same as a push to `main` |

The Azure jobs are skipped until the repository variables in [step 5](#5-configure-the-github-repository) exist. Validation always runs, so the workflow stays green before Azure is connected.

---

## Contents

1. [Install the tools](#1-install-the-tools)
2. [Sign in and register resource providers](#2-sign-in-and-register-resource-providers)
3. [Create the resource groups](#3-create-the-resource-groups)
4. [Let GitHub Actions sign in to Azure without secrets (OIDC)](#4-let-github-actions-sign-in-to-azure-without-secrets-oidc)
5. [Configure the GitHub repository](#5-configure-the-github-repository)
6. [Create the SQL administrators group](#6-create-the-sql-administrators-group)
7. [Deploy the infrastructure](#7-deploy-the-infrastructure)
8. [Contoso: one-time database user for the managed identity](#8-contoso-one-time-database-user-for-the-managed-identity)
9. [Contoso: add application secrets to Key Vault](#9-contoso-add-application-secrets-to-key-vault)
10. [Deploy the applications](#10-deploy-the-applications)
11. [Day-2 operations](#11-day-2-operations)
12. [Cost guide](#12-cost-guide)
13. [Tear down](#13-tear-down)

---

## 1. Install the tools

| Tool | Why |
|---|---|
| Azure CLI 2.60 or newer | Everything in this guide, and what the pipelines use |
| Bicep CLI | Installed and updated by the Azure CLI |
| GitHub CLI (optional) | Set repository variables and environments from the terminal |
| go-sqlcmd (optional) | Run the one-time T-SQL in step 8 from the terminal instead of the Portal |

### Azure CLI

**Windows** (pick one):

```powershell
winget install --exact --id Microsoft.AzureCLI
# or download and run the MSI: https://aka.ms/installazurecliwindowsx64
```

Close and reopen the terminal afterwards so `az` is on the PATH.

**macOS:**

```bash
brew update && brew install azure-cli
```

**Linux (Ubuntu/Debian):**

```bash
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
```

**No install at all:** open [Azure Cloud Shell](https://shell.azure.com) from the Portal toolbar (the `>_` icon). The Azure CLI, Bicep, `gh`, `git` and `sqlcmd` are already installed and you are already signed in.

Check the install and add Bicep:

```bash
az version
az bicep install     # or: az bicep upgrade
az bicep version
```

### Optional tools

```powershell
winget install --exact --id GitHub.cli
winget install --exact --id Microsoft.Sqlcmd
```

```bash
brew install gh sqlcmd    # macOS
```

---

## 2. Sign in and register resource providers

**Portal:** sign in at <https://portal.azure.com>. Open **Subscriptions** > your subscription > **Settings** > **Resource providers**, and register any of these that are not already `Registered`:
`Microsoft.Web`, `Microsoft.Cdn`, `Microsoft.Network`, `Microsoft.Sql`, `Microsoft.KeyVault`, `Microsoft.Storage`, `Microsoft.ManagedIdentity`, `Microsoft.Insights`, `Microsoft.OperationalInsights`, `Microsoft.AlertsManagement`.

**CLI:**

```bash
az login
az account set --subscription "<subscription name or id>"
az account show --query "{name:name, id:id, tenant:tenantId}" -o table

for p in Microsoft.Web Microsoft.Cdn Microsoft.Network Microsoft.Sql Microsoft.KeyVault \
         Microsoft.Storage Microsoft.ManagedIdentity Microsoft.Insights \
         Microsoft.OperationalInsights Microsoft.AlertsManagement; do
  az provider register --namespace "$p"
done
```

> PowerShell users: run the loop as `foreach ($p in 'Microsoft.Web','Microsoft.Cdn', ...) { az provider register --namespace $p }`.

---

## 3. Create the resource groups

One resource group per application per environment keeps access control, cost reporting and clean-up simple. In a real landing zone, dev and prod would also be in **separate subscriptions**; the templates work the same way.

| Resource group | Used by |
|---|---|
| `rg-blog-dev`, `rg-blog-prod` | Blog Starter |
| `rg-contoso-dev`, `rg-contoso-prod` | Contoso University |

**Portal:** **Resource groups** > **Create**. Choose the subscription, enter the name, region **West US 2** (or your standard region), add tags `application` and `environment`, then **Review + create**. Repeat for all four.

**CLI:**

```bash
LOCATION=westus2
for env in dev prod; do
  az group create -n rg-blog-$env    -l $LOCATION --tags application=blog-starter       environment=$env
  az group create -n rg-contoso-$env -l $LOCATION --tags application=contoso-university environment=$env
done
```

---

## 4. Let GitHub Actions sign in to Azure without secrets (OIDC)

The workflows use **workload identity federation**: GitHub issues a short-lived token, and Entra ID trusts it only for this repository and only for the named GitHub environments. There is no client secret to store, leak or rotate.

### 4a. Create the app registration

**Portal:**

1. **Microsoft Entra ID** > **App registrations** > **New registration**.
2. Name: `github-upgraded-palm-tree`. Supported account types: *this organizational directory only*. **Register**.
3. On the overview page, copy the **Application (client) ID** and the **Directory (tenant) ID**.

**CLI:**

```bash
APP_ID=$(az ad app create --display-name github-upgraded-palm-tree --query appId -o tsv)
az ad sp create --id $APP_ID
TENANT_ID=$(az account show --query tenantId -o tsv)
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
echo "AZURE_CLIENT_ID=$APP_ID  AZURE_TENANT_ID=$TENANT_ID  AZURE_SUBSCRIPTION_ID=$SUBSCRIPTION_ID"
```

### 4b. Add federated credentials

Every job that signs in to Azure runs in a GitHub environment (`dev` or `prod`), so two credentials are enough. Replace `<owner>` with the GitHub account that owns the repository.

**Portal:** in the app registration, **Certificates & secrets** > **Federated credentials** > **Add credential**:

| Field | Value |
|---|---|
| Federated credential scenario | GitHub Actions deploying Azure resources |
| Organization | `<owner>` |
| Repository | `upgraded-palm-tree` |
| Entity type | Environment |
| GitHub environment name | `dev` (then repeat with `prod`) |
| Name | `github-env-dev` / `github-env-prod` |

**CLI:**

```bash
OWNER=<owner>
for env in dev prod; do
  az ad app federated-credential create --id $APP_ID --parameters "{
    \"name\": \"github-env-$env\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:$OWNER/upgraded-palm-tree:environment:$env\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"
done
```

### 4c. Grant the pipeline access to the resource groups

The pipeline needs **Contributor** to create resources and **Role Based Access Control Administrator** because the templates grant the apps' managed identity access to Key Vault and Storage. Both are scoped to the four resource groups only, not the subscription.

**Portal:** for each resource group, **Access control (IAM)** > **Add** > **Add role assignment**:

1. Role **Contributor** > Members: *User, group, or service principal* > select `github-upgraded-palm-tree` > **Review + assign**.
2. Repeat with **Role Based Access Control Administrator**. On the *Conditions* tab choose *Allow user to only assign selected roles* and pick **Key Vault Secrets User**, **Key Vault Crypto User** and **Storage Blob Data Contributor**. That limits what the pipeline itself can hand out.

**CLI:**

```bash
SP_ID=$(az ad sp show --id $APP_ID --query id -o tsv)
for rg in rg-blog-dev rg-blog-prod rg-contoso-dev rg-contoso-prod; do
  SCOPE=$(az group show -n $rg --query id -o tsv)
  az role assignment create --assignee-object-id $SP_ID --assignee-principal-type ServicePrincipal \
    --role Contributor --scope $SCOPE
  az role assignment create --assignee-object-id $SP_ID --assignee-principal-type ServicePrincipal \
    --role "Role Based Access Control Administrator" --scope $SCOPE \
    --condition "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {4633458b-17de-408a-b874-0445c86b69e6, 12338af0-0e69-4776-bea7-57ae8d297424, ba92f5b4-2d11-453d-a403-e96b0029c9fe}))" \
    --condition-version "2.0"
done
```

---

## 5. Configure the GitHub repository

### 5a. Environments

**GitHub web:** repository **Settings** > **Environments** > **New environment**:

- `dev`: no protection rules.
- `prod`: tick **Required reviewers** and add yourself (and the on-call lead). Optionally restrict **Deployment branches** to `main`.

### 5b. Variables

These are identifiers, not secrets, so they are stored as **variables** (Settings > Secrets and variables > Actions > *Variables* tab).

| Variable | Level | Example |
|---|---|---|
| `AZURE_CLIENT_ID` | Repository | from step 4a |
| `AZURE_TENANT_ID` | Repository | from step 4a |
| `AZURE_SUBSCRIPTION_ID` | Repository | from step 4a |
| `ALERT_EMAIL` | Repository | `cloudops@yourcompany.com` |
| `BLOG_SITE_URL` | Repository | Production address of the blog, e.g. `https://blog.yourcompany.com` (used for link-preview images; optional until the site is live) |
| `SQL_ADMIN_GROUP_OBJECT_ID` | Repository | from step 6 |
| `SQL_ADMIN_GROUP_NAME` | Repository | `sg-contoso-sql-admins` |
| `BLOG_RESOURCE_GROUP` | Environment **dev** / **prod** | `rg-blog-dev` / `rg-blog-prod` |
| `CONTOSO_RESOURCE_GROUP` | Environment **dev** / **prod** | `rg-contoso-dev` / `rg-contoso-prod` |

**GitHub CLI:**

```bash
REPO=<owner>/upgraded-palm-tree
gh variable set AZURE_CLIENT_ID       -R $REPO -b "$APP_ID"
gh variable set AZURE_TENANT_ID       -R $REPO -b "$TENANT_ID"
gh variable set AZURE_SUBSCRIPTION_ID -R $REPO -b "$SUBSCRIPTION_ID"
gh variable set ALERT_EMAIL           -R $REPO -b "cloudops@yourcompany.com"
gh variable set BLOG_SITE_URL         -R $REPO -b "https://<your blog address>"

for env in dev prod; do
  gh api -X PUT "repos/$REPO/environments/$env" >/dev/null     # creates the environment
  gh variable set BLOG_RESOURCE_GROUP    -R $REPO -e $env -b "rg-blog-$env"
  gh variable set CONTOSO_RESOURCE_GROUP -R $REPO -e $env -b "rg-contoso-$env"
done
# Add required reviewers to "prod" in the web UI (Settings > Environments > prod).
```

---

## 6. Create the SQL administrators group

Azure SQL is deployed with **Microsoft Entra-only authentication**. There is no `sa` login and no SQL password anywhere. Administration is granted to an Entra group so people can be added and removed without touching the server.

**Portal:** **Microsoft Entra ID** > **Groups** > **New group**. Type *Security*, name `sg-contoso-sql-admins`, add yourself as owner and member, **Create**. Open the group and copy its **Object ID**.

**CLI:**

```bash
GROUP_ID=$(az ad group create --display-name sg-contoso-sql-admins --mail-nickname sg-contoso-sql-admins --query id -o tsv)
az ad group member add --group $GROUP_ID --member-id $(az ad signed-in-user show --query id -o tsv)
gh variable set SQL_ADMIN_GROUP_OBJECT_ID -R $REPO -b "$GROUP_ID"
gh variable set SQL_ADMIN_GROUP_NAME      -R $REPO -b "sg-contoso-sql-admins"
```

---

## 7. Deploy the infrastructure

### Option A: let the pipeline do it (recommended)

Push any change under `infrastructure/` to `main`, or run **Actions** > **Infrastructure** > **Run workflow**. Dev deploys first; prod waits for approval.

### Option B: deploy from your machine

Preview first with `what-if`, then deploy. The `.bicepparam` files read their values from environment variables, so export them first.

**Bash:**

```bash
export ENVIRONMENT_NAME=dev
export ALERT_EMAIL=cloudops@yourcompany.com
export SQL_ADMIN_GROUP_OBJECT_ID=$GROUP_ID
export SQL_ADMIN_GROUP_NAME=sg-contoso-sql-admins

# Blog Starter
az deployment group what-if -g rg-blog-dev    -n blog-starter       -f blog-starter/main.bicep       -p blog-starter/main.bicepparam
az deployment group create  -g rg-blog-dev    -n blog-starter       -f blog-starter/main.bicep       -p blog-starter/main.bicepparam

# Contoso University (about 15-25 minutes the first time; Front Door and SQL take the longest)
az deployment group what-if -g rg-contoso-dev -n contoso-university -f contoso-university/main.bicep -p contoso-university/main.bicepparam
az deployment group create  -g rg-contoso-dev -n contoso-university -f contoso-university/main.bicep -p contoso-university/main.bicepparam
```

**PowerShell:** the same commands work; set the variables with `$env:ENVIRONMENT_NAME = 'dev'` and so on, and use a backtick `` ` `` for line continuation if you split the commands.

> Keep the deployment names `blog-starter` and `contoso-university`. The application pipelines read resource names from those deployments' outputs, so nothing is hard-coded.

### What gets created

**Blog Starter:** Static Web App (Standard), Log Analytics workspace, Application Insights, a standard availability test from five regions, an alert rule and an action group.

**Contoso University:** user-assigned managed identity; VNet with an App Service integration subnet and a private endpoint subnet; private DNS zones; Azure SQL server and database (Entra-only, no public access); Key Vault (RBAC mode, purge protection) with a Data Protection key; Storage account (no shared keys, no public access) for the Data Protection key ring; three private endpoints; App Service plan (Linux); web and API apps on .NET 10, each with a `staging` slot; Front Door Premium with a WAF policy; Log Analytics, Application Insights, availability test, HTTP 5xx and latency alerts, and an action group. Production adds zone redundancy, autoscale (2 to 6 instances), a provisioned SQL tier and geo-redundant backups.

**Portal check:** open the resource group > **Deployments** to see each deployment's status, inputs and outputs. The `webUrl` output is the public address through Front Door.

---

## 8. Contoso: one-time database user for the managed identity

The apps connect to SQL as their managed identity (`id-contoso-dev`). Entra ID authenticates it, but the database still needs a user mapped to it with the right roles. This T-SQL must be run once per environment by a member of `sg-contoso-sql-admins`:

```sql
CREATE USER [id-contoso-dev] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [id-contoso-dev];
ALTER ROLE db_datawriter ADD MEMBER [id-contoso-dev];
ALTER ROLE db_ddladmin  ADD MEMBER [id-contoso-dev];   -- needed while the app creates its own schema; remove once migrations run from the pipeline
```

(Use `id-contoso-prod` in production.)

The SQL server has **no public endpoint**, so you need temporary network access for this step. The simplest way is to open the firewall to your IP for a few minutes, then close it again.

**Portal:**

1. **SQL servers** > `sql-contoso-dev-xxxxxx` > **Security** > **Networking**. Set *Public network access* to **Selected networks**, click **Add your client IPv4 address**, **Save**.
2. Open the **SQL database** `sqldb-contoso` > **Query editor (preview)** > *Continue as* your Entra account.
3. Paste the T-SQL above and **Run**.
4. Back in **Networking**, remove your IP and set *Public network access* to **Disable**. **Save**.

**CLI:**

```bash
MY_IP=$(curl -s https://api.ipify.org)
SQL_SERVER=$(az deployment group show -g rg-contoso-dev -n contoso-university --query properties.outputs.sqlServerName.value -o tsv)

# open, run, close
az sql server update -g rg-contoso-dev -n $SQL_SERVER --enable-public-network true
az sql server firewall-rule create -g rg-contoso-dev -s $SQL_SERVER -n one-time-setup --start-ip-address $MY_IP --end-ip-address $MY_IP

sqlcmd -S $SQL_SERVER.database.windows.net -d sqldb-contoso --authentication-method ActiveDirectoryDefault -Q "
CREATE USER [id-contoso-dev] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [id-contoso-dev];
ALTER ROLE db_datawriter ADD MEMBER [id-contoso-dev];
ALTER ROLE db_ddladmin  ADD MEMBER [id-contoso-dev];"

az sql server firewall-rule delete -g rg-contoso-dev -s $SQL_SERVER -n one-time-setup
az sql server update -g rg-contoso-dev -n $SQL_SERVER --enable-public-network false
```

> In an enterprise landing zone you would do this from a jump box or Azure Bastion inside the VNet (or a self-hosted runner) and never open the firewall at all.

---

## 9. Contoso: add application secrets to Key Vault

The apps load configuration from Key Vault at startup through their managed identity. Secret names use `--` where the .NET configuration key uses `:`.

| Secret name | Purpose | Required |
|---|---|---|
| `Administrator--Password` | Password for the seeded admin account (`admin@contoso.edu` by default) | Yes |
| `Authentication--Tokens--Key` | Signing key for the JWTs issued by `/api/token` (32+ random characters) | Yes, for the API |
| `Authentication--Tokens--Issuer` | JWT issuer, e.g. the web `webUrl` output | Yes, for the API |
| `Authentication--Tokens--Audience` | JWT audience, e.g. the API `apiUrl` output | Yes, for the API |
| `Authentication--Tokens--Audiences--0` | Audience written into issued tokens (same as above) | Yes, for the API |
| `SendGridUser`, `SendGridKey` | Email confirmation | For email sign-up |
| `SMSAccountIdentification`, `SMSAccountPassword`, `SMSAccountFrom` | Twilio SMS for two-factor | For 2FA |
| `Authentication--Google--ClientId`, `Authentication--Google--ClientSecret` | Google sign-in | Optional |
| `Authentication--Facebook--AppId`, `Authentication--Facebook--AppSecret` | Facebook sign-in | Optional |

Key Vault uses **RBAC**, so you first need the **Key Vault Secrets Officer** role on the vault, and its firewall only allows private traffic, so add your IP while you work.

**Portal:**

1. **Key vaults** > `kv-contoso-dev-xxxxxx` > **Access control (IAM)** > **Add role assignment** > **Key Vault Secrets Officer** > yourself.
2. **Networking** > *Firewall* > **Add your client IP address** > **Apply**.
3. **Objects** > **Secrets** > **Generate/Import** for each row in the table.
4. **Networking**: remove your IP > **Apply**.
5. Restart both web apps (**App Services** > app > **Restart**) so they reload configuration.

**CLI:**

```bash
KV=$(az deployment group show -g rg-contoso-dev -n contoso-university --query properties.outputs.keyVaultName.value -o tsv)
KV_ID=$(az keyvault show -n $KV --query id -o tsv)
az role assignment create --assignee $(az ad signed-in-user show --query id -o tsv) --role "Key Vault Secrets Officer" --scope $KV_ID
az keyvault network-rule add -n $KV --ip-address $MY_IP

az keyvault secret set --vault-name $KV -n Administrator--Password       --value "$(openssl rand -base64 24)"
az keyvault secret set --vault-name $KV -n Authentication--Tokens--Key  --value "$(openssl rand -base64 48)"
WEB_URL=$(az deployment group show -g rg-contoso-dev -n contoso-university --query properties.outputs.webUrl.value -o tsv)
API_URL=$(az deployment group show -g rg-contoso-dev -n contoso-university --query properties.outputs.apiUrl.value -o tsv)
az keyvault secret set --vault-name $KV -n Authentication--Tokens--Issuer       --value "$WEB_URL/"
az keyvault secret set --vault-name $KV -n Authentication--Tokens--Audience     --value "$API_URL/"
az keyvault secret set --vault-name $KV -n Authentication--Tokens--Audiences--0 --value "$API_URL/"
# ...SendGrid / Twilio / OAuth secrets the same way

az keyvault network-rule remove -n $KV --ip-address $MY_IP/32
for app in $(az webapp list -g rg-contoso-dev --query "[].name" -o tsv); do az webapp restart -g rg-contoso-dev -n $app; done
```

---

## 10. Deploy the applications

Once the infrastructure exists, the application pipelines take over. Each one builds once and promotes the same artifact from dev to prod.

| Workflow | Trigger | Target |
|---|---|---|
| [`blog-starter.yml`](../.github/workflows/blog-starter.yml) | changes in `modified/blog-starter/` | Static Web App: PR preview environments, then dev, then prod |
| [`contoso-university.yml`](../.github/workflows/contoso-university.yml) | changes in `modified/contoso-university/` | App Service `staging` slot, swap, smoke test, auto rollback |

**Manual deployment from a workstation** (useful for a first test, not for routine releases):

```bash
# Blog: build locally and upload with the SWA CLI
cd modified/blog-starter && npm ci && npm run build
SWA=$(az deployment group show -g rg-blog-dev -n blog-starter --query properties.outputs.staticWebAppName.value -o tsv)
TOKEN=$(az staticwebapp secrets list -n $SWA --query properties.apiKey -o tsv)
npx @azure/static-web-apps-cli deploy ./out --deployment-token $TOKEN --env production

# Contoso: publish, zip, deploy to staging, swap
cd modified/contoso-university
dotnet publish ContosoUniversity.Web/ContosoUniversity.Web.csproj -c Release -o out/web
(cd out/web && zip -r ../web.zip .)
WEB_APP=$(az deployment group show -g rg-contoso-dev -n contoso-university --query properties.outputs.webAppName.value -o tsv)
az webapp deploy -g rg-contoso-dev -n $WEB_APP --slot staging --src-path out/web.zip --type zip
az webapp deployment slot swap -g rg-contoso-dev -n $WEB_APP --slot staging --target-slot production
```

---

## 11. Day-2 operations

| Task | Portal | CLI |
|---|---|---|
| Roll back a Contoso release | App Service > **Deployment slots** > **Swap** (staging and production) | `az webapp deployment slot swap -g <rg> -n <app> --slot staging --target-slot production` |
| Roll back the blog | Re-run the last good **Blog Starter** workflow run | `gh run rerun <run-id>` |
| Live logs | App Service > **Log stream** | `az webapp log tail -g <rg> -n <app>` |
| Query errors | Application Insights > **Failures**, or Log Analytics > **Logs** | `az monitor app-insights query --app <appi> --analytics-query "exceptions \| take 50"` |
| WAF blocks | Front Door > **Security** > WAF logs, or Log Analytics table `AzureDiagnostics` | `az monitor log-analytics query -w <workspace-id> --analytics-query "AzureDiagnostics \| where Category == 'FrontDoorWebApplicationFirewallLog' \| take 50"` |
| Scale out manually | App Service plan > **Scale out** | `az appservice plan update -g <rg> -n <plan> --number-of-workers 3` |
| Point-in-time restore | SQL database > **Restore** | `az sql db restore -g <rg> -s <server> -n sqldb-contoso --dest-name sqldb-contoso-restored --time "2026-10-01T15:00:00Z"` |
| Rotate a secret | Key Vault > Secrets > **New version**, then restart the apps | `az keyvault secret set ...` then `az webapp restart ...` |
| Certificates | Managed by Front Door and Static Web Apps, renewed automatically. The availability tests alert 14 days before expiry if anything goes wrong. | |

---

## 12. Cost guide

Approximate list prices in US regions at the time of writing; confirm with the [Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/) for your region and agreement.

| Stack | Dev | Prod | Biggest cost driver |
|---|---|---|---|
| Blog Starter | ~$10/month | ~$10/month | Static Web Apps Standard plan (flat fee) |
| Contoso University | ~$450/month | ~$900+/month | Front Door Premium base fee (~$330), App Service plan, SQL tier |

Ways to cut dev cost: use Front Door **Standard** (custom WAF rules only) or skip Front Door in dev; drop the plan to **B1** (loses slots and zone redundancy); keep SQL serverless with auto-pause; stop the plan outside working hours.

Every resource is tagged with `application`, `environment` and `managedBy`, so **Cost Management** > **Cost analysis** can be grouped by tag. Add a **Budget** with an alert on each resource group:

```bash
az consumption budget create --budget-name contoso-dev --amount 500 --time-grain Monthly \
  --start-date 2026-10-01 --end-date 2027-09-30 --resource-group rg-contoso-dev \
  --category cost
```

---

## 13. Tear down

**Portal:** **Resource groups** > select the group > **Delete resource group** > type the name to confirm.

**CLI:**

```bash
az group delete -n rg-blog-dev    --yes --no-wait
az group delete -n rg-contoso-dev --yes --no-wait
```

Key Vault has purge protection on, so a deleted vault stays in a soft-deleted state for 90 days and its name cannot be reused during that time. The templates add a unique suffix to every name, so redeploying into a new resource group is not blocked.
