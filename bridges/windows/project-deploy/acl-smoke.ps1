param(
    [Parameter(Mandatory = $true)][string]$TargetPluginRoot,
    [Parameter(Mandatory = $true)][string]$ModsRoot,
    [Parameter(Mandatory = $true)][string]$TargetRoot,
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$BridgePath,
    [Parameter(Mandatory = $true)][string]$Result
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Token = [Guid]::NewGuid().ToString('N')
$Payload = [Text.Encoding]::UTF8.GetBytes("SkyrimDeploy ACL smoke $Token")
$TargetProbe = Join-Path $TargetPluginRoot ".skyrim-agent-acl-smoke-$Token.tmp"

function Test-WriteOpenRefused {
    param([string]$Path)
    try {
        $Stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $Stream.Dispose()
        return $false
    } catch {
        return ($_.Exception.ToString() -match 'UnauthorizedAccess|Access.*denied')
    }
}

$Report = [ordered]@{
    identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    target = $TargetProbe
    target_write = $false
    target_sha256 = $null
    target_removed = $false
    unrelated_count = 0
    unrelated_refused = $true
    unrelated_failures = @()
    config_write_open_refused = $false
    bridge_write_open_refused = $false
}

try {
    [IO.File]::WriteAllBytes($TargetProbe, $Payload)
    $Report.target_sha256 = (Get-FileHash -LiteralPath $TargetProbe -Algorithm SHA256).Hash
    $Report.target_write = $true
} finally {
    Remove-Item -LiteralPath $TargetProbe -Force -ErrorAction SilentlyContinue
    $Report.target_removed = -not (Test-Path -LiteralPath $TargetProbe)
}

$Unrelated = Get-ChildItem -LiteralPath $ModsRoot -Directory |
    Where-Object { $_.FullName -ne $TargetRoot }
foreach ($Directory in $Unrelated) {
    $Report.unrelated_count++
    $Probe = Join-Path $Directory.FullName ".skyrim-agent-must-refuse-$Token.tmp"
    $Refused = $false
    try {
        [IO.File]::WriteAllBytes($Probe, $Payload)
    } catch {
        $Refused = ($_.Exception.ToString() -match 'UnauthorizedAccess|Access.*denied')
    } finally {
        Remove-Item -LiteralPath $Probe -Force -ErrorAction SilentlyContinue
    }
    if (-not $Refused -or (Test-Path -LiteralPath $Probe)) {
        $Report.unrelated_refused = $false
        $Report.unrelated_failures += $Directory.FullName
    }
}

$Report.config_write_open_refused = Test-WriteOpenRefused -Path $ConfigPath
$Report.bridge_write_open_refused = Test-WriteOpenRefused -Path $BridgePath
$Report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Result -Encoding UTF8

if (
    -not $Report.target_write -or
    -not $Report.target_removed -or
    $Report.unrelated_count -lt 1 -or
    -not $Report.unrelated_refused -or
    -not $Report.config_write_open_refused -or
    -not $Report.bridge_write_open_refused
) {
    exit 1
}
