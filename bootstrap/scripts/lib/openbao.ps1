# Helpers shared by the PowerShell OpenBao scripts (openbao-configure.ps1,
# openbao-seed.ps1). Dot-source it, do not run it. The same as
# lib/openbao.sh for bash. Works in Windows PowerShell 5.1 and
# PowerShell 7.
#
# Everything runs "bao" INSIDE an OpenBao pod with kubectl exec, so the
# operator's computer needs only kubectl and helm (no jq, no bao). Tokens
# and secret values are written to kubectl's standard input, never passed
# as command-line arguments (which would show up in process lists).
#
# OpenBao itself is a cluster prerequisite. Point these at its pods if they
# are not openbao/openbao-0:
#   $env:OPENBAO_NAMESPACE (default openbao), $env:OPENBAO_RELEASE (default openbao).
# $env:NO_COLOR = 1 turns the colours off (they are off anyway when the
# output is redirected).

$script:OpenBaoNamespace = if ($env:OPENBAO_NAMESPACE) { $env:OPENBAO_NAMESPACE } else { 'openbao' }
$script:OpenBaoRelease = if ($env:OPENBAO_RELEASE) { $env:OPENBAO_RELEASE } else { 'openbao' }
# Mount path of the KV version 2 engine (openbao.kvPath); set from the seed plan.
$script:OpenBaoKv = 'conservices'
$script:UseColor = (-not $env:NO_COLOR) -and (-not [Console]::IsOutputRedirected)
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)

# --- Output ---------------------------------------------------------------------
function Write-Line([string]$Text, [string]$Color) {
    if ($script:UseColor -and $Color) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
}
function Write-Header([string]$Text) { Write-Line '' ; Write-Line "== $Text ==" 'Cyan' }
function Write-Log([string]$Text) { Write-Line "==> $Text" }
function Write-Good([string]$Text) { Write-Line "  ok    $Text" 'Green' }
function Write-Warn([string]$Text) { Write-Line "  warn  $Text" 'Yellow' }
function Write-Bad([string]$Text) { Write-Line "  error $Text" 'Red' }
function Write-Note([string]$Text) { Write-Line "        $Text" }
function Stop-Script([string]$Text) { Write-Line "ERROR: $Text" 'Red'; exit 1 }

# --- Running programs -------------------------------------------------------------

# ConvertTo-WinArg: one argument quoted for the Windows command line (the
# rules kubectl and helm use to split it again).
function ConvertTo-WinArg([string]$Arg) {
    if ($Arg -ne '' -and $Arg -notmatch '[\s"]') { return $Arg }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($c in $Arg.ToCharArray()) {
        if ($c -eq '\') { $slashes++; continue }
        if ($c -eq '"') {
            [void]$sb.Append('\' * ($slashes * 2 + 1)); [void]$sb.Append('"')
        } else {
            [void]$sb.Append('\' * $slashes); [void]$sb.Append($c)
        }
        $slashes = 0
    }
    [void]$sb.Append('\' * ($slashes * 2)); [void]$sb.Append('"')
    return $sb.ToString()
}

# Invoke-Native: runs a program with exact UTF-8 bytes (LF line ends) on its
# standard input. Returns ExitCode, StdOut, StdErr.
function Invoke-Native {
    param([string]$FilePath, [string[]]$Arguments, [string]$InputText = '')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = (($Arguments | ForEach-Object { ConvertTo-WinArg $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8
    $psi.StandardErrorEncoding = $script:Utf8
    # The stdin writer must not start with a byte order mark (it would end up
    # in front of the token). PowerShell 7 has StandardInputEncoding; Windows
    # PowerShell 5.1 takes the console's input encoding, so set that briefly.
    $savedInput = $null
    if ($psi.PSObject.Properties['StandardInputEncoding']) {
        $psi.StandardInputEncoding = $script:Utf8
    } else {
        try { $savedInput = [Console]::InputEncoding; [Console]::InputEncoding = $script:Utf8 } catch { $savedInput = $null }
    }
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
    } finally {
        if ($savedInput) { try { [Console]::InputEncoding = $savedInput } catch { } }
    }
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    $bytes = $script:Utf8.GetBytes($InputText)
    try {
        $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $p.StandardInput.BaseStream.Flush()
    } catch { }
    $p.StandardInput.Close()
    $p.WaitForExit()
    [pscustomobject]@{ ExitCode = $p.ExitCode; StdOut = $out.Result; StdErr = $err.Result }
}

function Get-Tool([string]$Name) {
    $c = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $c) { Stop-Script "'$Name' is required but not installed (or not on PATH)" }
    return $c.Source
}

# Get-SeedPlan: the root chart's seed plan for that settings file, as an
# object. Stops with the chart's message if the file is invalid.
function Get-SeedPlan {
    param([string]$RepoRoot, [string]$ClusterFile, [string[]]$HelmArgs = @())
    $helm = Get-Tool 'helm'
    $a = @('template', 'root', (Join-Path $RepoRoot 'charts/root'), '-f', $ClusterFile,
        '--set', 'global.seedPlan=true', '--show-only', 'templates/seed-plan.yaml') + $HelmArgs
    $r = Invoke-Native -FilePath $helm -Arguments $a
    if ($r.ExitCode -ne 0) {
        Write-Line $r.StdErr.Trim() 'Red'
        Stop-Script "the root chart rejected $ClusterFile (fix the message above first)"
    }
    $line = ($r.StdOut -split "`r?`n") | Where-Object { $_.StartsWith('{') } | Select-Object -First 1
    if (-not $line) { Stop-Script 'could not read the seed plan from charts/root' }
    return ($line | ConvertFrom-Json)
}

# Invoke-Bao: runs a bao command in the first OpenBao pod with the token.
# InputText follows the token on stdin, e.g. JSON for "bao kv put <path> -".
function Invoke-Bao {
    param([string]$Token, [string[]]$BaoArgs, [string]$InputText = '')
    $a = @('exec', '-i', '-n', $script:OpenBaoNamespace, "$($script:OpenBaoRelease)-0", '--',
        'sh', '-c', 'read -r BAO_TOKEN; export BAO_TOKEN; exec "$@"', 'sh', 'bao') + $BaoArgs
    Invoke-Native -FilePath $script:Kubectl -Arguments $a -InputText ($Token + "`n" + $InputText)
}

function Test-OpenBaoPod {
    $pod = "$($script:OpenBaoRelease)-0"
    $r = Invoke-Native -FilePath $script:Kubectl -Arguments @('get', 'pod', '-n', $script:OpenBaoNamespace, $pod)
    if ($r.ExitCode -ne 0) {
        Stop-Script "pod $($script:OpenBaoNamespace)/$pod not found; set `$env:OPENBAO_NAMESPACE and `$env:OPENBAO_RELEASE"
    }
}

# --- Input ------------------------------------------------------------------------

function Get-CleanValue([string]$Value) {
    if ($null -eq $Value) { return '' }
    return ($Value -replace "`r", '').Trim()
}

function Get-MaskedValue([string]$Value) {
    $n = $Value.Length
    if ($n -ge 16) { return ('{0} characters, {1}...{2}' -f $n, $Value.Substring(0, 4), $Value.Substring($n - 4)) }
    return "$n characters"
}

# Test-ConValue: $null if the value can be right, else the reason. Warnings
# for unusual but possible values are printed. Kinds: s3-access, s3-secret,
# smtp-password, cloudflare, ghcr-token, bao-token, text.
function Test-ConValue([string]$Kind, [string]$Value) {
    $n = $Value.Length
    if ($n -eq 0) { return 'is empty' }
    if ($Value -match '[\x00-\x1F\x7F]') { return 'contains control characters (the paste did not arrive as text)' }
    if ($Kind -ne 'smtp-password' -and $Kind -ne 'text') {
        if ($Value.Contains('\')) { return 'contains a backslash (\); no key or token has one, the paste probably failed' }
        if ($Value -match '\s') { return 'contains whitespace' }
    }
    switch ($Kind) {
        's3-access' { if ($n -lt 3) { return "is only $n characters long; S3 access key IDs are longer" } }
        's3-secret' { if ($n -lt 8) { return "is only $n characters long; S3 secret keys are longer" } }
        'cloudflare' {
            if ($Value -cnotmatch '^[A-Za-z0-9_-]+$') { return 'has characters a Cloudflare API token never has (only letters, digits, _ and -)' }
            if ($Value.StartsWith('cfk_')) { return 'is a Global API Key (cfk_...), not an API token; create an API token instead' }
            if ($n -lt 32 -or $n -gt 120) { return "is $n characters long; Cloudflare API tokens have 40 (older) or 53 (cfut_/cfat_) characters" }
            if ($n -ne 40 -and $Value -cnotmatch '^cf(ut|at)_') {
                Write-Warn "unusual for a Cloudflare API token ($n characters, expected 40 or cfut_/cfat_ + 48); keeping it"
            }
        }
        'ghcr-token' {
            if ($Value -cnotmatch '^[A-Za-z0-9_]+$') { return 'has characters a GitHub token never has (only letters, digits and _)' }
            if ($n -lt 20) { return "is only $n characters long; GitHub tokens are 40 or more" }
            if (-not $Value.StartsWith('ghp_')) { Write-Warn 'not a classic token (ghp_...); ghcr.io needs a classic token with read:packages' }
        }
        'bao-token' { if ($n -lt 8) { return "is only $n characters long; OpenBao tokens are longer" } }
        'smtp-password' {
            if ($Value -eq '\') { return 'is a single backslash; the paste probably failed' }
            if ($Value.Contains('\') -or $Value -match '\s') { Write-Warn 'contains a backslash or a space; fine if your password really has one' }
        }
    }
    return $null
}

# Read-ConValue: asks, cleans and checks the answer; three attempts. Hidden
# answers are read as SecureString and confirmed by their masked form only.
# Returns '' for an empty optional answer, $null after three bad answers.
function Read-ConValue {
    param([string]$Prompt, [string]$Kind, [switch]$Hidden, [switch]$Optional)
    for ($try = 1; $try -le 3; $try++) {
        if ($Hidden) {
            $sec = Read-Host -Prompt $Prompt -AsSecureString
            $v = Get-CleanValue ([System.Net.NetworkCredential]::new('', $sec).Password)
            $sec.Dispose()
        } else {
            $v = Get-CleanValue (Read-Host -Prompt $Prompt)
        }
        if ($v -eq '' -and $Optional) { return '' }
        $why = Test-ConValue $Kind $v
        if (-not $why) {
            if ($Hidden) { Write-Good "received: $(Get-MaskedValue $v)" }
            return $v
        }
        Write-Bad "That value $why. Try again ($try of 3)."
    }
    Write-Bad 'No usable value after 3 attempts.'
    return $null
}

# Get-BaoToken: $env:BAO_TOKEN, or the root token in $env:INIT_FILE, or asked
# for without echoing.
function Get-BaoToken([switch]$NoPrompt) {
    if ($env:BAO_TOKEN) { return (Get-CleanValue $env:BAO_TOKEN) }
    if ($env:INIT_FILE -and (Test-Path -LiteralPath $env:INIT_FILE)) {
        $t = (Get-Content -Raw -LiteralPath $env:INIT_FILE | ConvertFrom-Json).root_token
        if (-not $t) { Stop-Script "$($env:INIT_FILE) has no root_token" }
        return (Get-CleanValue $t)
    }
    if ($NoPrompt -or [Console]::IsInputRedirected) {
        Stop-Script 'set $env:BAO_TOKEN or $env:INIT_FILE (path to the OpenBao init file) to authenticate'
    }
    $t = Read-ConValue -Prompt 'OpenBao token' -Kind 'bao-token' -Hidden
    if (-not $t) { Stop-Script 'no usable token given' }
    return $t
}

function Assert-BaoToken([string]$Token, [string]$Hint = 'is OpenBao unsealed? is the token valid?') {
    $r = Invoke-Bao -Token $Token -BaoArgs @('token', 'lookup', '-format=json')
    if ($r.ExitCode -ne 0) { Stop-Script "token rejected ($Hint)" }
}

# --- KV version 2 -------------------------------------------------------------------

# Get-KvEntry: the values of <kv mount>/<path> as an object, $null if missing.
function Get-KvEntry([string]$Token, [string]$Path) {
    $r = Invoke-Bao -Token $Token -BaoArgs @('kv', 'get', '-format=json', "$($script:OpenBaoKv)/$Path")
    if ($r.ExitCode -ne 0) { return $null }
    try { $d = ($r.StdOut | ConvertFrom-Json).data.data } catch { return $null }
    return $d
}

function Test-KvEntry([string]$Token, [string]$Path) {
    $r = Invoke-Bao -Token $Token -BaoArgs @('kv', 'get', '-format=json', "$($script:OpenBaoKv)/$Path")
    return ($r.ExitCode -eq 0)
}

# Set-KvEntry: writes the fields (an ordered hashtable) to <kv mount>/<path>,
# as JSON on stdin.
function Set-KvEntry([string]$Token, [string]$Path, $Fields) {
    $json = $Fields | ConvertTo-Json -Compress -Depth 5
    $r = Invoke-Bao -Token $Token -BaoArgs @('kv', 'put', "$($script:OpenBaoKv)/$Path", '-') -InputText $json
    $json = $null
    if ($r.ExitCode -ne 0) {
        Write-Line $r.StdErr.Trim() 'Red'
        Stop-Script "could not write $($script:OpenBaoKv)/$Path (may the token write there?)"
    }
}

# Get-FieldValue: one field of an entry object as a string ('' if absent).
function Get-FieldValue($Entry, [string]$Field) {
    if ($null -eq $Entry) { return '' }
    $p = $Entry.PSObject.Properties[$Field]
    if ($null -eq $p -or $null -eq $p.Value) { return '' }
    return [string]$p.Value
}

function Get-PropertyNames($Object) {
    if ($null -eq $Object) { return @() }
    return @($Object.PSObject.Properties | ForEach-Object { $_.Name })
}
