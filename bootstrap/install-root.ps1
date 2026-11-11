<#
.SYNOPSIS
Apply the root Application of Con Services (Windows PowerShell 5.1 or newer).

.DESCRIPTION
Applies the root Application (rootApplication.name in cluster.yaml, default
conservices-stack): the one object that makes Argo CD install everything
else from your copy of this repository. Run it from the root of your copy,
after Argo CD is installed and cluster.yaml is complete AND pushed (Argo CD
reads cluster.yaml from Git, not from this computer).

The root chart checks cluster.yaml first and stops with a list of the values
still set to "change-me". Then the script checks the cluster prerequisites
the template uses but does not install (cert-manager, trust-manager,
External Secrets Operator, CloudNativePG with the Barman Cloud plugin, the
OpenBao CA bundle, Argo CD's Application health check).
Same behaviour as bootstrap/install-root.sh. Needs kubectl and helm.
Guide: https://aglelectronics.github.io/con-services/deploy/argocd/

.PARAMETER DryRun
Print the root Application, check nothing in the cluster, apply nothing.

.PARAMETER SkipPreflight
Skip the prerequisite check.

.PARAMETER ClusterFile
The settings file. Default: cluster.yaml at the root of the repository.

.EXAMPLE
.\bootstrap\install-root.ps1

.EXAMPLE
.\bootstrap\install-root.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$SkipPreflight,
    [string]$ClusterFile = ""
)

# Native commands report failures through $LASTEXITCODE. "Stop" would turn
# every redirected stderr line of kubectl into an exception on PowerShell 5.1.
$ErrorActionPreference = "Continue"
$OutputEncoding = New-Object System.Text.UTF8Encoding $false

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ClusterFile) { $ClusterFile = Join-Path $RepoRoot "cluster.yaml" }
$Docs = "https://aglelectronics.github.io/con-services/deploy"
$HealthKey = "resource.customizations.health.argoproj.io_Application"

function Write-Step([string]$Text) { Write-Host "==> " -ForegroundColor Cyan -NoNewline; Write-Host $Text }
function Write-Ok([string]$Text) { Write-Host "==> " -ForegroundColor Green -NoNewline; Write-Host $Text }
function Write-Warn([string]$Text) { Write-Host "WARNING: " -ForegroundColor Yellow -NoNewline; Write-Host $Text }
function Stop-Script([string]$Text) {
    Write-Host "ERROR: " -ForegroundColor Red -NoNewline
    Write-Host $Text
    exit 1
}

# Runs a native command. Returns @{ Ok; Out (stdout lines); Err (stderr text) }.
function Invoke-Native([string]$Command, [string[]]$Arguments) {
    $all = & $Command @Arguments 2>&1
    $ok = ($LASTEXITCODE -eq 0)
    $out = @($all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
    $err = (@($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object {
                if ($_.TargetObject -is [string]) { $_.TargetObject } else { $_.Exception.Message }
            }) -join "`n")
    return @{ Ok = $ok; Out = $out; Err = $err }
}

function Test-Kube([string[]]$Arguments) { return (Invoke-Native "kubectl" $Arguments).Ok }

# The root chart's seed plan (JSON) for the settings file.
function Get-SeedPlan {
    $r = Invoke-Native "helm" @("template", "root", (Join-Path $RepoRoot "charts/root"), "-f", $ClusterFile,
        "--set", "global.seedPlan=true", "--show-only", "templates/seed-plan.yaml")
    if (-not $r.Ok) { Write-Host $r.Err; Stop-Script "the root chart rejected $ClusterFile (fix the message above first)" }
    $json = $r.Out | Where-Object { $_.StartsWith("{") } | Select-Object -First 1
    if (-not $json) { Stop-Script "could not read the seed plan from charts/root" }
    return ($json | ConvertFrom-Json)
}

foreach ($c in @("helm", "kubectl")) {
    if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { Stop-Script "'$c' is required but not installed (see $Docs/prerequisites/#10-tools-on-your-computer)" }
}
if (-not (Test-Path -LiteralPath $ClusterFile)) { Stop-Script "cannot read $ClusterFile" }

Write-Step "Checking $ClusterFile"
$r = Invoke-Native "helm" @("template", "root", (Join-Path $RepoRoot "charts/root"), "-f", $ClusterFile,
    "--show-only", "templates/root-application.yaml")
if (-not $r.Ok) {
    Write-Host $r.Err
    Stop-Script "fix cluster.yaml as described above, push it, and run this again"
}
$manifest = $r.Out -join "`n"
$name = ($r.Out | Where-Object { $_ -match '^  name: ' } | Select-Object -First 1) -replace '^  name: ', ''
$repo = ($r.Out | Where-Object { $_ -match '^ *- repoURL: ' } | Select-Object -First 1) -replace '^ *- repoURL: ', ''

if ($DryRun) {
    Write-Output $manifest
    exit 0
}

if (-not (Test-Kube @("get", "crd", "applications.argoproj.io"))) {
    Stop-Script "Argo CD is not installed in this cluster (it is a prerequisite: $Docs/prerequisites/#9-argo-cd)"
}

if (-not $SkipPreflight) {
    Write-Step "Checking the cluster prerequisites"
    $missing = @()
    $crds = [ordered]@{
        "certificates.cert-manager.io"            = "cert-manager"
        "bundles.trust.cert-manager.io"           = "trust-manager"
        "clustersecretstores.external-secrets.io" = "External Secrets Operator"
        "clusters.postgresql.cnpg.io"             = "CloudNativePG operator"
        "objectstores.barmancloud.cnpg.io"        = "Barman Cloud plugin"
    }
    foreach ($crd in $crds.Keys) {
        if (-not (Test-Kube @("get", "crd", $crd))) { $missing += "$($crds[$crd]) (CRD $crd not found)" }
    }
    $plan = Get-SeedPlan
    if (-not (Test-Kube @("get", "serviceaccount", "-n", $plan.esoNamespace, $plan.esoServiceAccount))) {
        $missing += "External Secrets service account $($plan.esoNamespace)/$($plan.esoServiceAccount) (cluster.yaml externalSecrets.*)"
    }
    $ca = $plan.caBundle
    if ($ca.name) {
        if (-not (Test-Kube @("get", $ca.kind.ToLower(), "-n", $ca.namespace, $ca.name))) {
            $missing += "OpenBao CA $($ca.kind) $($ca.namespace)/$($ca.name) (cluster.yaml openbao.caBundle)"
        }
    }
    if ($missing.Count -gt 0) {
        foreach ($m in $missing) { Write-Host "  missing: " -ForegroundColor Red -NoNewline; Write-Host $m }
        Stop-Script "install the cluster prerequisites first (guide: deploy/prerequisites), or rerun with -SkipPreflight"
    }
    $hasHealth = $false
    $cm = Invoke-Native "kubectl" @("get", "cm", "argocd-cm", "-n", "argocd", "-o", "json")
    if ($cm.Ok) {
        $prop = ($cm.Out -join "`n" | ConvertFrom-Json).data.PSObject.Properties | Where-Object { $_.Name -eq $HealthKey }
        $hasHealth = [bool]($prop -and $prop.Value)
    }
    if (-not $hasHealth) {
        Write-Host ""
        @(
            "argocd-cm has no $HealthKey.",
            "Without this health check Argo CD does not wait for one sync wave to be",
            "Healthy before the next: every component starts at once and the first",
            "install fails in confusing ways (Keycloak before its operator, apps",
            "before the database). Add the block from",
            "$Docs/prerequisites/#9-argo-cd",
            "to argocd-cm (Helm chart: configs.cm) before you continue."
        ) | ForEach-Object { Write-Host "!!! $_" -ForegroundColor Yellow }
        Write-Host ""
        Write-Warn "continuing in 10 seconds; press Ctrl+C to stop"
        Start-Sleep -Seconds 10
    }
    Write-Ok "Prerequisites found"
}

Write-Step "Argo CD will read $repo"
if (Get-Command git -ErrorAction SilentlyContinue) {
    $null = & git -C $RepoRoot diff --quiet -- cluster.yaml 2>&1
    if ($LASTEXITCODE -eq 1) { Write-Warn "cluster.yaml has changes that are not committed; Argo CD only sees what is pushed" }
}

$manifest | kubectl apply -f -
if ($LASTEXITCODE -ne 0) { Stop-Script "kubectl apply failed (see above)" }
$setup = (Get-SeedPlan).setup.enabled

Write-Ok "Root Application `"$name`" applied."
$script:n = 0
function Write-NextStep([string[]]$Lines) {
    $script:n++
    Write-Host ("  {0}. " -f $script:n) -ForegroundColor Cyan -NoNewline
    Write-Host $Lines[0]
    $Lines | Select-Object -Skip 1 | ForEach-Object { Write-Host "     $_" }
}
Write-Host ""
Write-Host "Next steps:"
Write-Host ""
Write-NextStep @("Follow the sync waves:", "  kubectl get applications -n argocd -w")
if ($setup) {
    Write-NextStep @(
        "Sync `"openbao-setup`" by hand. Argo CD never syncs it automatically and",
        "the later waves wait for it: review its diff in Argo CD, then press Sync",
        "(or: argocd app sync openbao-setup). The OpenBao administrator must have",
        "run bootstrap\scripts\openbao-configure.ps1 once before.")
}
Write-NextStep @(
    "Enter your provider credentials (S3, SMTP, Cloudflare) in OpenBao:",
    "  .\bootstrap\scripts\openbao-seed.ps1",
    "Applications that read them stay Degraded until they exist.",
    "Guide: $Docs/secrets-openbao/")
Write-NextStep @("Create the DNS records and the S3 buckets:", "$Docs/dns-and-certificates/")
