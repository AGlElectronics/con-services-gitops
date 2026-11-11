<#
.SYNOPSIS
Enter the secrets only you know (provider credentials) into OpenBao.

.DESCRIPTION
The PowerShell version of openbao-seed.sh, for Windows PowerShell 5.1 and
PowerShell 7. One way of several: the OpenBao web UI or "bao kv put" work
just as well. The random values (database passwords, tokens, client
secrets) are not here: External Secrets Operator creates them.

It reads cluster.yaml (through the root chart, so helm is needed) and asks
for every entry the enabled modules and options need, below the KV mount
openbao.kvPath (default "conservices"):

  conservices/infra/postgres/backup-s3   access_key, secret_key
  conservices/modules/den/s3             access_key, secret_key
  conservices/modules/den/files-s3       access_key, secret_key (read only)
  conservices/modules/den/backup-s3      access_key, secret_key
  conservices/modules/<module>/s3        access_key, secret_key (stash rally
                                         learn wiki tasks, when enabled)
  conservices/modules/stash/telegram     token (optional, when Stash is on)
  conservices/modules/stash/smtp         password (optional, when Stash is on)
  conservices/infra/keycloak/smtp        host, port, from, username, password
  conservices/infra/cloudflare           api-token
  conservices/infra/ghcr                 username, token

Every S3 entry gets its own access key, limited to its own bucket. Existing
entries are kept (and checked); -Overwrite or -Reenter asks again. Hidden
answers are read with Read-Host -AsSecureString and only their length and
first and last four characters are shown. Values are written to kubectl's
standard input, never passed as arguments.

Authentication: $env:BAO_TOKEN, or $env:INIT_FILE (the init file of a fresh
OpenBao, root token), or the script asks. Needs kubectl and helm on PATH.
If OpenBao does not run as pods openbao/openbao-N, set
$env:OPENBAO_NAMESPACE and $env:OPENBAO_RELEASE. $env:NO_COLOR = 1 turns
colours off.

Guide: https://aglelectronics.github.io/con-services/deploy/secrets-openbao/

.PARAMETER NoPrompt
Ask nothing; list what exists and what is missing, with the Applications
that stay Degraded.

.PARAMETER Overwrite
Ask again for these entries even if they exist, and replace them, e.g.
-Overwrite conservices/infra/cloudflare. Several: separate with commas.

.PARAMETER Reenter
Ask again for every entry, existing or not.

.PARAMETER Modules
Check exactly these modules (e.g. -Modules stash,wiki) instead of the
modules.<name>.enabled settings of cluster.yaml.

.PARAMETER ClusterFile
Settings file (default: cluster.yaml in the repository root).

.EXAMPLE
$env:BAO_TOKEN = Read-Host; .\bootstrap\scripts\openbao-seed.ps1

.EXAMPLE
.\bootstrap\scripts\openbao-seed.ps1 -NoPrompt

.EXAMPLE
.\bootstrap\scripts\openbao-seed.ps1 -Overwrite conservices/infra/cloudflare
#>
[CmdletBinding()]
param(
    [switch]$NoPrompt,
    [string[]]$Overwrite = @(),
    [switch]$Reenter,
    [string[]]$Modules = @(),
    [string]$ClusterFile
)
Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/openbao.ps1')

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $ClusterFile) { $ClusterFile = Join-Path $RepoRoot 'cluster.yaml' }
$AllModules = @('stash', 'hr', 'rally', 'finance', 'learn', 'wiki', 'desk', 'tasks')
$script:Kubectl = Get-Tool 'kubectl'

$Prompt = -not $NoPrompt
if ($Prompt -and [Console]::IsInputRedirected) {
    Write-Warn 'standard input is redirected: asking nothing (as with -NoPrompt)'
    $Prompt = $false
}
$Overwrite = @($Overwrite | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
if (-not $Prompt -and ($Overwrite.Count -gt 0 -or $Reenter)) {
    Stop-Script '-Overwrite and -Reenter need a console to ask on (not with -NoPrompt)'
}
if (-not (Test-Path -LiteralPath $ClusterFile)) {
    Stop-Script "cannot read $ClusterFile (run from your copy of the repository or pass -ClusterFile)"
}

# --- What this cluster needs ----------------------------------------------------
Write-Header 'Cluster'
$helmArgs = @()
$Modules = @($Modules | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Modules.Count -gt 0) {
    foreach ($m in $Modules) {
        if ($AllModules -notcontains $m) { Stop-Script "unknown module '$m' (one of: $($AllModules -join ' '))" }
    }
    foreach ($m in $AllModules) {
        $on = if ($Modules -contains $m) { 'true' } else { 'false' }
        $helmArgs += @('--set', "modules.$m.enabled=$on")
    }
}
$plan = Get-SeedPlan -RepoRoot $RepoRoot -ClusterFile $ClusterFile -HelmArgs $helmArgs
$script:OpenBaoKv = $plan.kvPath
$Kv = $plan.kvPath
$mods = @($plan.modules)
Write-Log "Settings: $ClusterFile"
Write-Log ('Modules:  ' + $(if ($mods.Count) { $mods -join ', ' } else { 'none (Den only)' }))
Write-Log "Mount:    $Kv/ (KV version 2)"

$entries = @($plan.manual)
$generated = @($plan.generated | ForEach-Object { $_.path })
$manualPaths = @($entries | ForEach-Object { $_.path })

function Get-RelPath([string]$Path) {
    $p = $Path.Trim().TrimStart('/').TrimEnd('/')
    if ($p.StartsWith("$Kv/")) { $p = $p.Substring($Kv.Length + 1) }
    return $p
}
$force = @()
foreach ($o in $Overwrite) {
    $r = Get-RelPath $o
    if ($manualPaths -contains $r) { $force += $r }
    elseif ($generated -contains $r) {
        Stop-Script "$Kv/$r is generated by External Secrets, not entered here. To get a new value, see 'Rotate a generated value' in the guide."
    } else {
        Stop-Script "$Kv/$r is not an entry this cluster.yaml needs. One of: $(($manualPaths | ForEach-Object { "$Kv/$_" }) -join ' ')"
    }
}
function Test-Forced([string]$Path) { return ($Reenter -or ($force -contains $Path)) }

$Token = Get-BaoToken -NoPrompt:(-not $Prompt)
Assert-BaoToken $Token "is OpenBao unsealed? is the token valid? does $Kv/ exist?"

# --- Values only you know ------------------------------------------------------------
$written = New-Object System.Collections.ArrayList
$kept = New-Object System.Collections.ArrayList
$missing = New-Object System.Collections.ArrayList
$broken = New-Object System.Collections.ArrayList
$s3Keys = [ordered]@{}   # path -> access key of every S3 entry seen so far

function Test-S3Reuse([string]$Path, [string]$AccessKey) {
    foreach ($other in @($s3Keys.Keys)) {
        if ($other -ne $Path -and $s3Keys[$other] -ceq $AccessKey) {
            Write-Warn "$Kv/$Path uses the same access key as $Kv/$other."
            Write-Note 'Give every bucket its own key, limited to that bucket: a leaked or'
            Write-Note 'compromised key then exposes one bucket, not all of them.'
        }
    }
}

function Add-Missing($e) {
    [void]$missing.Add("$Kv/$($e.path) ($($e.fields -join ', ')): Application(s) $($e.apps -join ', ') stay Degraded")
}

$checks = @{
    s3         = @(@('access_key', 's3-access', $false), @('secret_key', 's3-secret', $false))
    smtp       = @(@('host', 'text', $false), @('from', 'text', $false), @('password', 'smtp-password', $true))
    telegram   = @(, @('token', 'bot-token', $false))
    password   = @(, @('password', 'smtp-password', $false))
    cloudflare = @(, @('api-token', 'cloudflare', $false))
    ghcr       = @(@('username', 'text', $false), @('token', 'ghcr-token', $false))
}
# Checks an existing entry the same way as typed answers, so a broken value
# (a failed paste stored as "\") shows up. Only the reason is printed.
function Test-Existing($e, $data) {
    foreach ($c in $checks[$e.kind]) {
        $v = Get-FieldValue $data $c[0]
        if ($v -eq '' -and $c[2]) { continue }
        $why = Test-ConValue $c[1] $v
        if ($why) {
            Write-Bad "$Kv/$($e.path): $($c[0]) $why"
            Write-Note "Replace it: -Overwrite $Kv/$($e.path) (or edit it in the OpenBao web UI)"
            [void]$broken.Add("$Kv/$($e.path) ($($c[0]) $why)")
        }
    }
    if ($e.kind -eq 's3') {
        $ak = Get-FieldValue $data 'access_key'
        if ($ak) { Test-S3Reuse $e.path $ak; $s3Keys[$e.path] = $ak }
    }
}

# Request-<kind>: asks for an entry and writes it; $false if skipped.
function Request-S3($e) {
    $ak = Read-ConValue -Prompt '  Access key ID (empty = skip)' -Kind 's3-access' -Optional
    if (-not $ak) { return $false }
    Test-S3Reuse $e.path $ak
    $sk = Read-ConValue -Prompt '  Secret access key (hidden)' -Kind 's3-secret' -Hidden
    if (-not $sk) { return $false }
    Set-KvEntry $Token $e.path ([ordered]@{ access_key = $ak; secret_key = $sk })
    $sk = $null
    $s3Keys[$e.path] = $ak
    return $true
}

function Request-Smtp($e) {
    $h = Read-ConValue -Prompt '  SMTP host, e.g. smtp.example.org (empty = skip)' -Kind 'text' -Optional
    if (-not $h) { return $false }
    for ($try = 1; ; $try++) {
        $port = Read-ConValue -Prompt '  Port [587]' -Kind 'text' -Optional
        if ($null -eq $port) { return $false }
        if (-not $port) { $port = '587' }
        if ($port -match '^\d{1,5}$' -and [int]$port -gt 0 -and [int]$port -lt 65536) { break }
        Write-Bad "The port must be a number such as 587 or 465 ($try of 3)."
        if ($try -ge 3) { return $false }
    }
    for ($try = 1; ; $try++) {
        $from = Read-ConValue -Prompt '  From address, e.g. no-reply@example.org' -Kind 'text'
        if ($null -eq $from) { return $false }
        if ($from -match '^[^\s@]+@[^\s@]+\.[^\s@]+$') { break }
        Write-Bad "That is not an e-mail address ($try of 3)."
        if ($try -ge 3) { return $false }
    }
    $user = Read-ConValue -Prompt '  Username (empty = no login)' -Kind 'text' -Optional
    if ($null -eq $user) { return $false }
    $pass = ''
    if ($user) {
        $pass = Read-ConValue -Prompt '  Password (hidden)' -Kind 'smtp-password' -Hidden
        if (-not $pass) { return $false }
    }
    Set-KvEntry $Token $e.path ([ordered]@{ host = $h; port = $port; from = $from; username = $user; password = $pass })
    $pass = $null
    return $true
}

function Request-Telegram($e) {
    $t = Read-ConValue -Prompt '  Bot token from @BotFather (hidden, empty = no Telegram)' -Kind 'bot-token' -Hidden -Optional
    if (-not $t) { return $false }
    Set-KvEntry $Token $e.path ([ordered]@{ token = $t })
    $t = $null
    return $true
}

function Request-Password($e) {
    $pass = Read-ConValue -Prompt '  Password (hidden, empty = no SMTP login)' -Kind 'smtp-password' -Hidden -Optional
    if (-not $pass) { return $false }
    Set-KvEntry $Token $e.path ([ordered]@{ password = $pass })
    $pass = $null
    return $true
}

function Request-Cloudflare($e) {
    $t = Read-ConValue -Prompt '  API token (hidden, empty = skip)' -Kind 'cloudflare' -Hidden -Optional
    if (-not $t) { return $false }
    Set-KvEntry $Token $e.path ([ordered]@{ 'api-token' = $t })
    $t = $null
    return $true
}

function Request-Ghcr($e) {
    $user = Read-ConValue -Prompt '  GitHub user name (empty = skip)' -Kind 'text' -Optional
    if (-not $user) { return $false }
    $t = Read-ConValue -Prompt '  Classic token with only read:packages (hidden)' -Kind 'ghcr-token' -Hidden
    if (-not $t) { return $false }
    Set-KvEntry $Token $e.path ([ordered]@{ username = $user; token = $t })
    $t = $null
    return $true
}

$sections = @{
    s3         = 'S3 keys (one per bucket, limited to that bucket)'
    smtp       = 'Mail server for Keycloak (SMTP)'
    telegram   = 'Telegram bot token (optional, one bot per module)'
    password   = 'Stash SMTP password (optional)'
    cloudflare = "Cloudflare API token (Let's Encrypt DNS-01)"
    ghcr       = 'GitHub Container Registry (private images)'
}
$current = ''
foreach ($e in $entries) {
    $p = $e.path
    if ($sections[$e.kind] -ne $current) { $current = $sections[$e.kind]; Write-Header $current }

    $data = Get-KvEntry $Token $p
    $exists = ($null -ne $data)
    if ($exists -and -not (Test-Forced $p)) {
        Write-Good "$Kv/$p exists, keeping it"
        [void]$kept.Add($p)
        Test-Existing $e $data
        $data = $null
        continue
    }
    $data = $null
    if (-not $Prompt) {
        if ($e.optional) {
            Write-Warn "$Kv/$p is not set ($($e.fields -join ', ')); optional, so the feature stays off"
        } else {
            Write-Bad "$Kv/$p is missing ($($e.fields -join ', ')); Application(s) $($e.apps -join ', ') stay Degraded"
            Add-Missing $e
        }
        continue
    }
    if ($exists) { Write-Log "$Kv/${p}: replacing it (empty answer = keep the current value)" } else { Write-Log "$Kv/$p" }
    Write-Note $e.what
    $ok = switch ($e.kind) {
        's3' { Request-S3 $e }
        'smtp' { Request-Smtp $e }
        'telegram' { Request-Telegram $e }
        'password' { Request-Password $e }
        'cloudflare' { Request-Cloudflare $e }
        'ghcr' { Request-Ghcr $e }
    }
    if ($ok) {
        Write-Good "$Kv/$p written"
        [void]$written.Add("$Kv/$p")
    } elseif ($exists) {
        Write-Warn "$Kv/${p}: nothing entered, keeping the current value"
        [void]$kept.Add($p)
    } elseif ($e.optional) {
        Write-Warn "$Kv/$p skipped; the feature stays off until the entry exists"
    } else {
        Write-Warn "$Kv/$p skipped; Application(s) $($e.apps -join ', ') stay Degraded until it exists"
        Add-Missing $e
    }
}

# Generated entries: only listed with -NoPrompt (External Secrets makes them).
if (-not $Prompt) {
    Write-Header 'Generated by External Secrets'
    foreach ($p in $generated) {
        if (Test-KvEntry $Token $p) { Write-Good "$Kv/$p exists" }
        else { Write-Warn "$Kv/$p not created yet (kubectl get pushsecret -n $($plan.esoNamespace))" }
    }
}

# --- Summary ----------------------------------------------------------------------------
Write-Header 'Summary'
Write-Good "$($written.Count) written, $($kept.Count) kept"
if ($missing.Count) {
    Write-Bad "$($missing.Count) missing:"
    foreach ($m in $missing) { Write-Line "        $m" 'Red' }
    Write-Note 'Run this script again (without -NoPrompt) to enter them; the Applications'
    Write-Note 'continue on their own a few minutes after the entry exists.'
} else {
    Write-Good 'Nothing missing.'
}
if ($broken.Count) {
    Write-Bad "$($broken.Count) existing value(s) cannot be right:"
    foreach ($m in $broken) { Write-Line "        $m" 'Red' }
    Write-Note 'Replace them: -Overwrite <path>[,<path>...], or edit them in the OpenBao web UI.'
}
if ($written.Count) {
    Write-Warn "Check the values you just entered in the OpenBao web UI (Secrets, $Kv):"
    foreach ($p in $written) { Write-Note $p }
}
if ($Prompt) {
    Write-Warn 'Hidden values (S3 secret keys, SMTP password, tokens) are only checked for their'
    Write-Note 'form here. A wrong one fails later (for example cert-manager: "Invalid format for'
    Write-Note 'Authorization header"). Compare them in the OpenBao web UI; to replace one:'
    Write-Note '-Overwrite <path>, or edit it there.'
}
Write-Log 'Check with: kubectl get externalsecret,pushsecret -A'
