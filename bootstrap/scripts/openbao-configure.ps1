<#
.SYNOPSIS
The OpenBao administrator's one-time step for Con Services.

.DESCRIPTION
The PowerShell version of openbao-configure.sh, for Windows PowerShell 5.1
and PowerShell 7. OpenBao must already be initialised and unsealed. Run
once, from the root of your copy of this repository, with a token that may
manage auth methods and policies (for a fresh OpenBao: the root token).
Safe to run again.

It reads cluster.yaml (openbao.*, externalSecrets.*) through the root chart,
so helm is needed, and then:
  1. Enables the Kubernetes auth method at openbao.auth.mountPath (default
     kubernetes/) if missing and points it at the cluster's API server.
  2. Writes policy "conservices-external-secrets": read every entry of the
     KV mount openbao.kvPath (default conservices/), and create and update
     entries below modules/, infra/postgres/ and infra/keycloak/.
  With openbao.setup.enabled (the default):
  3. Writes policy "conservices-setup" and the role openbao.setup.role for
     the setup Job's service account.
  With openbao.setup.enabled: false:
  3. Enables the KV version 2 engine at openbao.kvPath.
  4. Writes the role openbao.auth.role for External Secrets.

Authentication: $env:BAO_TOKEN, or $env:INIT_FILE (init file of a fresh
OpenBao), or the script asks (hidden). Needs kubectl and helm on PATH; jq
is not needed. If OpenBao does not run as pods openbao/openbao-N, set
$env:OPENBAO_NAMESPACE and $env:OPENBAO_RELEASE.

Guide: https://aglelectronics.github.io/con-services/deploy/secrets-openbao/

.PARAMETER ClusterFile
Settings file (default: cluster.yaml in the repository root).

.EXAMPLE
.\bootstrap\scripts\openbao-configure.ps1
#>
[CmdletBinding()]
param(
    [string]$ClusterFile
)
Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/openbao.ps1')

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $ClusterFile) { $ClusterFile = Join-Path $RepoRoot 'cluster.yaml' }
if (-not (Test-Path -LiteralPath $ClusterFile)) {
    Stop-Script "cannot read $ClusterFile (run from your copy of the repository or pass -ClusterFile)"
}
$script:Kubectl = Get-Tool 'kubectl'

$plan = Get-SeedPlan -RepoRoot $RepoRoot -ClusterFile $ClusterFile
$Kv = $plan.kvPath
$script:OpenBaoKv = $Kv
$AuthMount = $plan.authMount
$AuthRole = $plan.authRole
$EsoNamespace = $plan.esoNamespace
$EsoSa = $plan.esoServiceAccount
$SetupEnabled = [bool]$plan.setup.enabled
$SetupRole = $plan.setup.role
$SetupSa = $plan.setup.serviceAccount
$SetupNamespace = $plan.setupNamespace
$EsoPolicy = 'conservices-external-secrets'
$SetupPolicy = 'conservices-setup'

function Invoke-BaoChecked([string[]]$BaoArgs, [string]$InputText = '', [string]$What) {
    $r = Invoke-Bao -Token $Token -BaoArgs $BaoArgs -InputText $InputText
    if ($r.ExitCode -ne 0) {
        Write-Line $r.StdErr.Trim() 'Red'
        Stop-Script "$What failed"
    }
    return $r.StdOut
}

Write-Header 'OpenBao'
Test-OpenBaoPod
Write-Log "Pod $($script:OpenBaoNamespace)/$($script:OpenBaoRelease)-0, KV mount $Kv/"
$Token = Get-BaoToken
Assert-BaoToken $Token

# --- 1. Kubernetes auth --------------------------------------------------------------
Write-Header '1. Kubernetes auth method'
$auths = (Invoke-BaoChecked @('auth', 'list', '-format=json') -What 'bao auth list') | ConvertFrom-Json
if ((Get-PropertyNames $auths) -contains "$AuthMount/") {
    Write-Good "Kubernetes auth $AuthMount/ already enabled"
} else {
    [void](Invoke-BaoChecked @('auth', 'enable', "-path=$AuthMount", 'kubernetes') -What 'enabling Kubernetes auth')
    Write-Good "Enabled Kubernetes auth at $AuthMount/"
}
# OpenBao checks service account tokens against the API server with its own
# service account (the upstream chart grants it system:auth-delegator).
[void](Invoke-BaoChecked @('write', "auth/$AuthMount/config", 'kubernetes_host=https://kubernetes.default.svc:443') -What 'configuring Kubernetes auth')
Write-Good 'Configured Kubernetes auth'

# --- 2. External Secrets Operator's policy ---------------------------------------------
Write-Header "2. Policy $EsoPolicy"
$esoHcl = @"
# External Secrets Operator: read every Con Services entry in $Kv/,
# and create the random ones (PushSecret, updatePolicy IfNotExists) below
# modules/, infra/postgres/ and infra/keycloak/. It never deletes:
# PushSecrets use deletionPolicy None. Entries only a person enters
# (infra/cloudflare, infra/ghcr) stay read-only for it.
path "$Kv/data/*" {
  capabilities = ["read"]
}
path "$Kv/metadata/*" {
  capabilities = ["read"]
}
path "$Kv/data/modules/*" {
  capabilities = ["read", "create", "update"]
}
path "$Kv/metadata/modules/*" {
  capabilities = ["read", "create", "update"]
}
path "$Kv/data/infra/postgres/*" {
  capabilities = ["read", "create", "update"]
}
path "$Kv/metadata/infra/postgres/*" {
  capabilities = ["read", "create", "update"]
}
path "$Kv/data/infra/keycloak/*" {
  capabilities = ["read", "create", "update"]
}
path "$Kv/metadata/infra/keycloak/*" {
  capabilities = ["read", "create", "update"]
}
"@ -replace "`r`n", "`n"
[void](Invoke-BaoChecked @('policy', 'write', $EsoPolicy, '-') -InputText $esoHcl -What "writing policy $EsoPolicy")
Write-Good "Wrote policy $EsoPolicy (read $Kv/*, write modules/*, infra/postgres/*, infra/keycloak/*)"

if ($SetupEnabled) {
    # --- 3. The setup Job's policy and role ---------------------------------------------
    Write-Header "3. Setup Job: policy $SetupPolicy and role $SetupRole"
    $setupHcl = @"
# Con Services' openbao-setup Job (Argo CD Application openbao-setup).
# Enable the KV engine Con Services uses. No delete: it cannot remove it.
path "sys/mounts/$Kv" {
  capabilities = ["create", "read", "update"]
}
# Write External Secrets' role, with exactly these values.
path "auth/$AuthMount/role/$AuthRole" {
  capabilities = ["create", "read", "update"]
  allowed_parameters = {
    "bound_service_account_names"      = ["$EsoSa"]
    "bound_service_account_namespaces" = ["$EsoNamespace"]
    "token_policies"                   = ["$EsoPolicy"]
    "token_ttl"                        = ["1h"]
  }
}
"@ -replace "`r`n", "`n"
    [void](Invoke-BaoChecked @('policy', 'write', $SetupPolicy, '-') -InputText $setupHcl -What "writing policy $SetupPolicy")
    Write-Good "Wrote policy $SetupPolicy"
    [void](Invoke-BaoChecked @('write', "auth/$AuthMount/role/$SetupRole",
            "bound_service_account_names=$SetupSa", "bound_service_account_namespaces=$SetupNamespace",
            "token_policies=$SetupPolicy", 'token_ttl=10m', 'token_max_ttl=10m') -What "writing role $SetupRole")
    Write-Good "Wrote role $SetupRole for $SetupNamespace/$SetupSa"
    Write-Line ''
    Write-Line 'Done. Next: Argo CD stops at the Application "openbao-setup". Review its'
    Write-Line 'diff, then press Sync (or: argocd app sync openbao-setup). It enables'
    Write-Line "$Kv/ and writes the role $AuthRole."
    exit 0
}

# --- 3. KV engine (openbao.setup.enabled: false) ----------------------------------------
Write-Header "3. KV version 2 engine $Kv/"
$mounts = (Invoke-BaoChecked @('secrets', 'list', '-format=json') -What 'bao secrets list') | ConvertFrom-Json
$m = $mounts.PSObject.Properties["$Kv/"]
if ($m) {
    $version = '1'
    if ($m.Value.options -and $m.Value.options.version) { $version = [string]$m.Value.options.version }
    if ($version -ne '2') { Stop-Script "$Kv/ exists but is KV version $version; Con Services needs version 2" }
    Write-Good "KV v2 engine $Kv/ already enabled"
} else {
    [void](Invoke-BaoChecked @('secrets', 'enable', "-path=$Kv", '-version=2', 'kv') -What "enabling $Kv/")
    Write-Good "Enabled KV v2 at $Kv/"
}

# --- 4. External Secrets' role --------------------------------------------------------------
Write-Header "4. Role $AuthRole"
[void](Invoke-BaoChecked @('write', "auth/$AuthMount/role/$AuthRole",
        "bound_service_account_names=$EsoSa", "bound_service_account_namespaces=$EsoNamespace",
        "token_policies=$EsoPolicy", 'token_ttl=1h') -What "writing role $AuthRole")
Write-Good "Wrote role $AuthRole for $EsoNamespace/$EsoSa"
Write-Line ''
Write-Line 'Done. OpenBao is ready for External Secrets Operator.'
