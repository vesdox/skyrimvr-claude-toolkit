param(
    [Parameter(Mandatory = $true)]
    [string]$Source
)

$ErrorActionPreference = 'Stop'

$Node = 'D:\Program Files\nodejs\node.exe'
$Stage = 'C:\ProgramData\SkyrimToolBridge\housecarl-read'
$Destination = "$Stage\bridge\bridge.js"
$Logs = 'C:\ProgramData\SkyrimToolBridge\logs'
$InspectAccount = "$env:COMPUTERNAME\SkyrimInspect"

Write-Host '=== houseCARL read bridge deployment ==='

if (-not (
    [Security.Principal.WindowsPrincipal]
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    throw 'deploy.ps1 must be run from an Administrator PowerShell'
}

if (-not (Test-Path $Source -PathType Leaf)) {
    throw "source bridge does not exist: $Source"
}

if (-not (Test-Path $Node -PathType Leaf)) {
    throw "Node executable not found: $Node"
}

Write-Host "`n--- JavaScript syntax check ---"
& $Node --check $Source

if ($LASTEXITCODE -ne 0) {
    throw 'Node syntax check failed'
}

$SourceHash = (
    Get-FileHash $Source -Algorithm SHA256
).Hash

Write-Host "Source SHA256: $SourceHash"

Write-Host "`n--- Current listener ---"

$Listener = Get-NetTCPConnection `
    -LocalPort 7346 `
    -State Listen `
    -ErrorAction SilentlyContinue |
    Select-Object -First 1

if ($Listener) {
    if ($Listener.LocalAddress -ne '127.0.0.1') {
        throw (
            "refusing deployment: port 7346 is listening on " +
            "$($Listener.LocalAddress), not 127.0.0.1"
        )
    }

    $Process = Get-CimInstance Win32_Process `
        -Filter "ProcessId=$($Listener.OwningProcess)"

    $Owner = Invoke-CimMethod `
        -InputObject $Process `
        -MethodName GetOwner

    if (
        $Owner.Domain -ne $env:COMPUTERNAME -or
        $Owner.User -ne 'SkyrimInspect'
    ) {
        throw (
            "refusing deployment: current 7346 listener is owned by " +
            "$($Owner.Domain)\$($Owner.User)"
        )
    }

    Write-Host (
        "Stopping existing SkyrimInspect bridge PID " +
        "$($Listener.OwningProcess)"
    )

    Stop-Process `
        -Id $Listener.OwningProcess `
        -Force
}
else {
    Write-Host 'No existing 7346 listener.'
}

Write-Host "`n--- Deploy protected copy ---"

Copy-Item `
    $Source `
    $Destination `
    -Force

$DestinationHash = (
    Get-FileHash $Destination -Algorithm SHA256
).Hash

Write-Host "Deployed SHA256: $DestinationHash"

if ($SourceHash -ne $DestinationHash) {
    throw 'deployed bridge hash does not match source'
}

Write-Host "`n--- Launch as SkyrimInspect ---"

$Cred = Get-Credential $InspectAccount

Start-Process `
    powershell.exe `
    -Credential $Cred `
    -ArgumentList `
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        "`"$Stage\launch-bridge.ps1`"" `
    -RedirectStandardOutput "$Logs\bridge-out.txt" `
    -RedirectStandardError "$Logs\bridge-err.txt" `
    -WindowStyle Hidden

Start-Sleep 2

Write-Host "`n--- Verify listener ---"

$NewListener = Get-NetTCPConnection `
    -LocalPort 7346 `
    -State Listen `
    -ErrorAction Stop |
    Select-Object -First 1

if ($NewListener.LocalAddress -ne '127.0.0.1') {
    throw (
        "new bridge listener is unexpectedly bound to " +
        $NewListener.LocalAddress
    )
}

$NewProcess = Get-CimInstance Win32_Process `
    -Filter "ProcessId=$($NewListener.OwningProcess)"

$NewOwner = Invoke-CimMethod `
    -InputObject $NewProcess `
    -MethodName GetOwner

if (
    $NewOwner.Domain -ne $env:COMPUTERNAME -or
    $NewOwner.User -ne 'SkyrimInspect'
) {
    throw (
        "new bridge is owned by unexpected identity: " +
        "$($NewOwner.Domain)\$($NewOwner.User)"
    )
}

Write-Host (
    "Listener: $($NewListener.LocalAddress):" +
    "$($NewListener.LocalPort)"
)
Write-Host "Owner: $($NewOwner.Domain)\$($NewOwner.User)"

Write-Host "`n--- Health check ---"

$Health = Invoke-RestMethod `
    -Uri 'http://127.0.0.1:7346/health' `
    -Method Get

if ($Health.ok -ne $true) {
    throw 'bridge health check failed'
}

Write-Host 'Health: OK'
Write-Host "`nDeployment successful."
