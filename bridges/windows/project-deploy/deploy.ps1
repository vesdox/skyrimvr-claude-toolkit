param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Config
)

$ErrorActionPreference = 'Stop'
$Node = 'D:\Program Files\nodejs\node.exe'
$Stage = 'C:\ProgramData\SkyrimToolBridge\project-deploy'
$Destination = "$Stage\bridge\bridge.js"
$ConfigDestination = "$Stage\config.json"
$TaskName = 'SkyrimToolBridge-Project-Deploy'

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'deploy.ps1 must be run from an Administrator PowerShell'
}
foreach ($Path in @($Source, $Config, $Node, $Stage, (Split-Path $Destination -Parent))) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "required path does not exist: $Path" }
}

& $Node --check $Source
if ($LASTEXITCODE -ne 0) { throw 'Node syntax check failed' }
$Parsed = Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json
if ($Parsed.schema -ne 1 -or -not $Parsed.targets -or -not $Parsed.backup_root) {
    throw 'generated deployment config has an unsupported schema'
}

$Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
if ($Task.Principal.LogonType -ne 'S4U' -or $Task.Principal.UserId -notmatch '(^|\\)SkyrimDeploy$') {
    throw "$TaskName must be an S4U task owned by the dedicated SkyrimDeploy identity"
}

$Listener = Get-NetTCPConnection -LocalPort 7347 -State Listen -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($Listener) {
    if ($Listener.LocalAddress -ne '127.0.0.1') { throw 'port 7347 is not loopback-only' }
    $Process = Get-CimInstance Win32_Process -Filter "ProcessId=$($Listener.OwningProcess)"
    $Owner = Invoke-CimMethod -InputObject $Process -MethodName GetOwner
    if ($Owner.User -ne 'SkyrimDeploy') {
        throw "port 7347 listener has unexpected owner $($Owner.Domain)\$($Owner.User)"
    }
    Stop-Process -Id $Listener.OwningProcess -Force
}

$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
foreach ($Pair in @(@($Destination, "$Destination.$Stamp.bak"), @($ConfigDestination, "$ConfigDestination.$Stamp.bak"))) {
    if (Test-Path -LiteralPath $Pair[0] -PathType Leaf) {
        Copy-Item -LiteralPath $Pair[0] -Destination $Pair[1]
    }
}
Copy-Item -LiteralPath $Source -Destination $Destination -Force
Copy-Item -LiteralPath $Config -Destination $ConfigDestination -Force

foreach ($Pair in @(@($Source, $Destination), @($Config, $ConfigDestination))) {
    $A = (Get-FileHash -LiteralPath $Pair[0] -Algorithm SHA256).Hash
    $B = (Get-FileHash -LiteralPath $Pair[1] -Algorithm SHA256).Hash
    if ($A -ne $B) { throw "deployed hash mismatch: $($Pair[1])" }
    Write-Host "$($Pair[1]) SHA256: $B"
}

Start-ScheduledTask -TaskName $TaskName
Start-Sleep 2
$NewListener = Get-NetTCPConnection -LocalPort 7347 -State Listen -ErrorAction Stop |
    Select-Object -First 1
if ($NewListener.LocalAddress -ne '127.0.0.1') { throw 'new listener is not loopback-only' }
$Health = Invoke-RestMethod -Uri 'http://127.0.0.1:7347/health' -Method Get
if ($Health.ok -ne $true) { throw 'deployment bridge health check failed' }
Write-Host 'Bounded project deployment bridge is healthy.'
