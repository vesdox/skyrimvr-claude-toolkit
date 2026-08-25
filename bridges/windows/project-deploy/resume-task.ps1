Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExpectedSid = 'S-1-5-21-3046562540-2879210194-691397096-1014'
$ExpectedBridgeHash = 'a3a023f2b400b898ac8ab485dc9c89cfe32810136af61dbfd85eccaf617478e5'
$ExpectedConfigHash = '8103009b73fb481c5a3ae631282bea412ae0aa4b7b95a57ed82a2863c2afac4a'
$ExpectedSmokeHash = '82de9d82f51fedb9d7554fe5dcdf9a614d2e40e25c504c0d2f20959765e72ed5'
$ExpectedBatchRightHash = 'c68303a99d2bc05d96c903a50d52adf5e8c2d101e6b24592676a04115070defb'
$Node = 'D:\Program Files\nodejs\node.exe'
$Stage = 'C:\ProgramData\SkyrimToolBridge\project-deploy'
$Destination = Join-Path $Stage 'bridge\bridge.js'
$ConfigDestination = Join-Path $Stage 'config.json'
$SmokeDestination = Join-Path $Stage 'acl-smoke.ps1'
$BackupRoot = Join-Path $Stage 'backups'
$BatchRightScript = Join-Path $PSScriptRoot 'batch-right.ps1'
$TaskName = 'SkyrimToolBridge-Project-Deploy'
$SmokeTaskName = 'SkyrimToolBridge-Project-Deploy-ACL-Smoke'
$AccountName = 'SkyrimDeploy'
$DeployAccount = "${env:COMPUTERNAME}\$AccountName"
$TargetRoot = 'D:\Games\Wabbajack\Modlists\ASSOS\mods\Hoarfrost - Development'
$ModsRoot = Split-Path -Parent $TargetRoot
$TargetPluginRoot = Join-Path $TargetRoot 'SKSE\Plugins'

function Assert-Hash {
    param([string]$Path, [string]$Expected)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "required file is absent: $Path" }
    $Actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Actual -ne $Expected) { throw "file hash mismatch for ${Path}: $Actual" }
}

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'resume-task.ps1 requires Administrator Windows PowerShell'
}
if (-not [Environment]::Is64BitProcess -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw 'resume-task.ps1 requires 64-bit Windows PowerShell 5.1'
}
if (Get-Process SkyrimSE -ErrorAction SilentlyContinue) { throw 'refusing recovery while SkyrimSE is running' }
$User = Get-LocalUser -Name $AccountName -ErrorAction Stop
if (-not $User.Enabled -or $User.SID.Value -ne $ExpectedSid) { throw 'SkyrimDeploy identity does not match diagnosed partial state' }
Assert-Hash $Destination $ExpectedBridgeHash
Assert-Hash $ConfigDestination $ExpectedConfigHash
Assert-Hash $SmokeDestination $ExpectedSmokeHash
Assert-Hash $BatchRightScript $ExpectedBatchRightHash
if (-not (Test-Path -LiteralPath $BackupRoot -PathType Container)) { throw 'protected backup root is absent' }
if (Get-ScheduledTask -TaskName $SmokeTaskName -ErrorAction SilentlyContinue) {
    throw 'refusing to replace pre-existing ACL smoke task'
}

Write-Host '=== Grant exact missing S4U prerequisite ==='
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $BatchRightScript -ExpectedSid $ExpectedSid
if ($LASTEXITCODE -ne 0) { throw "batch-right helper failed: $LASTEXITCODE" }

Write-Host '=== Register or validate exact S4U task ==='
$Action = New-ScheduledTaskAction -Execute $Node -Argument "`"$Destination`"" -WorkingDirectory $Stage
$TaskPrincipal = New-ScheduledTaskPrincipal -UserId $DeployAccount -LogonType S4U -RunLevel Limited
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero)
$Task = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
$Listener = Get-NetTCPConnection -LocalPort 7347 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $Task) {
    if ($Listener) { throw 'refusing task registration while port 7347 already has a listener' }
    Register-ScheduledTask -TaskName $TaskName -TaskPath '\' -Action $Action -Principal $TaskPrincipal `
        -Settings $Settings -Description 'Bounded Hoarfrost ASSOS deployment bridge' | Out-Null
    $Task = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction Stop
}
if (
    $Task.TaskPath -ne '\' -or -not $Task.Settings.Enabled -or $Task.Triggers.Count -ne 0 -or
    $Task.Principal.UserId -notin @($AccountName, $DeployAccount) -or $Task.Principal.LogonType -ne 'S4U' -or
    $Task.Principal.RunLevel -ne 'Limited' -or $Task.Actions.Count -ne 1 -or
    $Task.Actions[0].Execute -ne $Node -or $Task.Actions[0].Arguments -ne "`"$Destination`"" -or
    $Task.Actions[0].WorkingDirectory -ne $Stage -or $Task.Settings.ExecutionTimeLimit -ne 'PT0S' -or
    $Task.Settings.DisallowStartIfOnBatteries -or $Task.Settings.StopIfGoingOnBatteries
) { throw 'registered service task does not match exact bounded definition' }

$Listener = Get-NetTCPConnection -LocalPort 7347 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $Listener) {
    Start-ScheduledTask -TaskName $TaskName
    for ($Attempt=0; $Attempt -lt 20; $Attempt++) {
        $Listener = Get-NetTCPConnection -LocalPort 7347 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($Listener) { break }
        Start-Sleep 1
    }
}
if (-not $Listener -or $Listener.LocalAddress -ne '127.0.0.1') { throw 'bridge did not become loopback-only within 20 seconds' }
$Process = Get-CimInstance Win32_Process -Filter "ProcessId=$($Listener.OwningProcess)"
$Owner = Invoke-CimMethod -InputObject $Process -MethodName GetOwner
if ($Owner.User -ne $AccountName -or $Owner.Domain -ne ${env:COMPUTERNAME} -or
    $Process.ExecutablePath -ne $Node -or $Process.CommandLine -notlike "*`"$Destination`"*") {
    throw 'listener process identity/executable/command line is not exact'
}
if ((Invoke-RestMethod 'http://127.0.0.1:7347/health').ok -ne $true) { throw 'local bridge health failed' }

Write-Host '=== Run existing fixed ACL smoke ==='
$SmokeToken = [Guid]::NewGuid().ToString('N')
$SmokeResult = Join-Path $BackupRoot "acl-smoke-$SmokeToken.json"
$PowerShell = "${env:SystemRoot}\System32\WindowsPowerShell\v1.0\powershell.exe"
$SmokeArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$SmokeDestination`" " +
    "-TargetPluginRoot `"$TargetPluginRoot`" -ModsRoot `"$ModsRoot`" -TargetRoot `"$TargetRoot`" " +
    "-ConfigPath `"$ConfigDestination`" -BridgePath `"$Destination`" -Result `"$SmokeResult`""
$SmokeAction = New-ScheduledTaskAction -Execute $PowerShell -Argument $SmokeArguments
try {
    Register-ScheduledTask -TaskName $SmokeTaskName -Action $SmokeAction -Principal $TaskPrincipal `
        -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 10)) `
        -Description 'One-shot bounded SkyrimDeploy ACL smoke' | Out-Null
    Start-ScheduledTask -TaskName $SmokeTaskName
    for ($Attempt=0; $Attempt -lt 120; $Attempt++) {
        $State = (Get-ScheduledTask -TaskName $SmokeTaskName).State
        if ($State -ne 'Running' -and (Test-Path -LiteralPath $SmokeResult -PathType Leaf)) { break }
        Start-Sleep 1
    }
    $Info = Get-ScheduledTaskInfo -TaskName $SmokeTaskName
    if ($Info.LastTaskResult -ne 0 -or -not (Test-Path -LiteralPath $SmokeResult -PathType Leaf)) {
        throw "ACL smoke task failed: result=$($Info.LastTaskResult)"
    }
    $Smoke = Get-Content -LiteralPath $SmokeResult -Raw | ConvertFrom-Json
    $Smoke | ConvertTo-Json -Depth 4
    if ($Smoke.identity -ne $DeployAccount -or -not $Smoke.target_write -or -not $Smoke.target_removed -or
        $Smoke.unrelated_count -lt 1 -or -not $Smoke.unrelated_refused -or
        -not $Smoke.config_write_open_refused -or -not $Smoke.bridge_write_open_refused) {
        throw 'effective ACL smoke report failed'
    }
} finally {
    Unregister-ScheduledTask -TaskName $SmokeTaskName -Confirm:$false -ErrorAction SilentlyContinue
}

Write-Host '=== Partial provisioning recovery successful; Tailscale remains unchanged ==='
Write-Host "Listener: 127.0.0.1:7347 owner=$DeployAccount"
Write-Host "Registered target smoke: write/hash/remove passed at $TargetPluginRoot"
Write-Host "All unrelated mod roots refused: $($Smoke.unrelated_count)"
Write-Host 'Protected config and bridge write-open attempts refused'
Write-Host "ACL smoke evidence: $SmokeResult"
