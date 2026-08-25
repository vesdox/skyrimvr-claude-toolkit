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
$DeployAccount = "$env:COMPUTERNAME\SkyrimDeploy"
$ExpectedBridgeHash = 'a3a023f2b400b898ac8ab485dc9c89cfe32810136af61dbfd85eccaf617478e5'
$ExpectedConfigHash = '8103009b73fb481c5a3ae631282bea412ae0aa4b7b95a57ed82a2863c2afac4a'
$ExpectedTarget = 'D:\Games\Wabbajack\Modlists\ASSOS\mods\Hoarfrost - Development'
$ExpectedBackup = 'C:\ProgramData\SkyrimToolBridge\project-deploy\backups'

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'deploy.ps1 must be run from an Administrator PowerShell'
}
foreach ($Path in @($Source, $Config, $Node, $Stage, (Split-Path $Destination -Parent))) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "required path does not exist: $Path" }
}

$SourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash.ToLowerInvariant()
$ConfigHash = (Get-FileHash -LiteralPath $Config -Algorithm SHA256).Hash.ToLowerInvariant()
if ($SourceHash -ne $ExpectedBridgeHash) { throw "bridge source is not pinned: $SourceHash" }
if ($ConfigHash -ne $ExpectedConfigHash) { throw "deployment config is not pinned: $ConfigHash" }
& $Node --check $Source
if ($LASTEXITCODE -ne 0) { throw 'Node syntax check failed' }
$Parsed = Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json
$Properties = @($Parsed.targets.PSObject.Properties)
$Registered = $Parsed.targets.'hoarfrost:development'
if (
    $Parsed.schema -ne 1 -or $Parsed.environment -ne 'assos' -or
    $Properties.Count -ne 1 -or $Properties[0].Name -ne 'hoarfrost:development' -or
    -not $Registered -or $Registered.project -ne 'hoarfrost' -or
    $Registered.environment -ne 'assos' -or $Registered.target -ne 'development' -or
    $Registered.root -ne $ExpectedTarget -or
    @($Registered.artifacts.PSObject.Properties).Count -ne 20 -or
    $Parsed.backup_root -ne $ExpectedBackup
) { throw 'deployment config is not the exact pinned Hoarfrost/ASSOS allowlist' }

$Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
if ($Task.Principal.LogonType -ne 'S4U' -or $Task.Principal.UserId -ne $DeployAccount) {
    throw "$TaskName must be an S4U task owned by the dedicated SkyrimDeploy identity"
}

$Listener = Get-NetTCPConnection -LocalPort 7347 -State Listen -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($Listener) {
    if ($Listener.LocalAddress -ne '127.0.0.1') { throw 'port 7347 is not loopback-only' }
    $Process = Get-CimInstance Win32_Process -Filter "ProcessId=$($Listener.OwningProcess)"
    $Owner = Invoke-CimMethod -InputObject $Process -MethodName GetOwner
    if ($Owner.Domain -ne $env:COMPUTERNAME -or $Owner.User -ne 'SkyrimDeploy') {
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
$NewListener = $null
for ($Attempt = 0; $Attempt -lt 20; $Attempt++) {
    $NewListener = Get-NetTCPConnection -LocalPort 7347 -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($NewListener) { break }
    Start-Sleep -Seconds 1
}
if (-not $NewListener) { throw 'deployment bridge did not listen within 20 seconds' }
if ($NewListener.LocalAddress -ne '127.0.0.1') { throw 'new listener is not loopback-only' }
$NewProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$($NewListener.OwningProcess)"
$NewOwner = Invoke-CimMethod -InputObject $NewProcess -MethodName GetOwner
if ($NewOwner.Domain -ne $env:COMPUTERNAME -or $NewOwner.User -ne 'SkyrimDeploy') {
    throw "new listener has unexpected owner: $($NewOwner.Domain)\$($NewOwner.User)"
}
$Health = Invoke-RestMethod -Uri 'http://127.0.0.1:7347/health' -Method Get
if ($Health.ok -ne $true) { throw 'deployment bridge health check failed' }
Write-Host 'Bounded project deployment bridge is healthy.'
