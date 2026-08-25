param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Config,
    [Parameter(Mandatory = $true)][string]$SmokeScript
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExpectedBridgeHash = 'a3a023f2b400b898ac8ab485dc9c89cfe32810136af61dbfd85eccaf617478e5'
$ExpectedConfigHash = '8103009b73fb481c5a3ae631282bea412ae0aa4b7b95a57ed82a2863c2afac4a'
$ExpectedSmokeHash = 'd0864856b27e883542591503a0e48fd11bc0c14704f5ce97fdafc52966b3ad38'
$Node = 'D:\Program Files\nodejs\node.exe'
$Stage = 'C:\ProgramData\SkyrimToolBridge\project-deploy'
$BridgeDirectory = Join-Path $Stage 'bridge'
$Destination = Join-Path $BridgeDirectory 'bridge.js'
$ConfigDestination = Join-Path $Stage 'config.json'
$SmokeDestination = Join-Path $Stage 'acl-smoke.ps1'
$BackupRoot = Join-Path $Stage 'backups'
$TaskName = 'SkyrimToolBridge-Project-Deploy'
$SmokeTaskName = 'SkyrimToolBridge-Project-Deploy-ACL-Smoke'
$AccountName = 'SkyrimDeploy'
$DeployAccount = "$env:COMPUTERNAME\$AccountName"

function Invoke-Icacls {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    & icacls.exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "icacls failed with exit code $LASTEXITCODE: $($Arguments -join ' ')"
    }
}

function Add-AllowRule {
    param(
        [System.Security.AccessControl.FileSystemSecurity]$Acl,
        [string]$Identity,
        [System.Security.AccessControl.FileSystemRights]$Rights,
        [System.Security.AccessControl.InheritanceFlags]$Inheritance
    )
    $Rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $Identity, $Rights, $Inheritance,
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow)
    $Acl.AddAccessRule($Rule) | Out-Null
}

function Set-ExactDirectoryAcl {
    param([string]$Path, [System.Security.AccessControl.FileSystemRights]$DeployRights)
    $Acl = New-Object System.Security.AccessControl.DirectorySecurity
    $Acl.SetAccessRuleProtection($true, $false)
    $Inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    Add-AllowRule $Acl 'BUILTIN\Administrators' ([System.Security.AccessControl.FileSystemRights]::FullControl) $Inheritance
    Add-AllowRule $Acl 'NT AUTHORITY\SYSTEM' ([System.Security.AccessControl.FileSystemRights]::FullControl) $Inheritance
    Add-AllowRule $Acl $DeployAccount $DeployRights $Inheritance
    Set-Acl -LiteralPath $Path -AclObject $Acl
}

function Set-ExactFileAcl {
    param([string]$Path)
    $Acl = New-Object System.Security.AccessControl.FileSecurity
    $Acl.SetAccessRuleProtection($true, $false)
    $None = [System.Security.AccessControl.InheritanceFlags]::None
    Add-AllowRule $Acl 'BUILTIN\Administrators' ([System.Security.AccessControl.FileSystemRights]::FullControl) $None
    Add-AllowRule $Acl 'NT AUTHORITY\SYSTEM' ([System.Security.AccessControl.FileSystemRights]::FullControl) $None
    Add-AllowRule $Acl $DeployAccount ([System.Security.AccessControl.FileSystemRights]::ReadAndExecute) $None
    Set-Acl -LiteralPath $Path -AclObject $Acl
}

function Assert-Hash {
    param([string]$Path, [string]$Expected)
    $Actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Actual -ne $Expected) { throw "SHA256 mismatch for $Path; expected=$Expected actual=$Actual" }
}

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'provision.ps1 must be run from an Administrator PowerShell'
}
if (-not [Environment]::Is64BitProcess -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw 'provision.ps1 requires 64-bit Windows PowerShell 5.1'
}
foreach ($Module in 'Microsoft.PowerShell.LocalAccounts','ScheduledTasks','NetTCPIP') {
    if (-not (Get-Module -ListAvailable -Name $Module)) { throw "required PowerShell module is unavailable: $Module" }
}
if (Get-Process SkyrimSE -ErrorAction SilentlyContinue) { throw 'refusing provisioning while SkyrimSE is running' }
if (Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue) { throw 'SkyrimDeploy already exists; initial provisioning refuses partial state' }
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { throw 'deployment task already exists; initial provisioning refuses partial state' }
if (Test-Path -LiteralPath $Stage) { throw 'deployment service stage already exists; initial provisioning refuses partial state' }
if (Get-NetTCPConnection -LocalPort 7347 -State Listen -ErrorAction SilentlyContinue) { throw 'port 7347 already has a listener' }
foreach ($Path in @($Source, $Config, $SmokeScript, $Node)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "required file does not exist: $Path" }
}
Assert-Hash $Source $ExpectedBridgeHash
Assert-Hash $Config $ExpectedConfigHash
Assert-Hash $SmokeScript $ExpectedSmokeHash
$NodeVersion = (& $Node --version)
if ($LASTEXITCODE -ne 0 -or $NodeVersion -notmatch '^v([2-9][0-9]|[1-9][0-9]{2,})\.') { throw "Node 20+ is required: $NodeVersion" }
& $Node --check $Source
if ($LASTEXITCODE -ne 0) { throw 'Node syntax check failed' }

$Parsed = Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json
$TargetProperties = @($Parsed.targets.PSObject.Properties)
$Registered = $Parsed.targets.'hoarfrost:development'
if (
    $Parsed.schema -ne 1 -or $Parsed.environment -ne 'assos' -or
    $TargetProperties.Count -ne 1 -or $TargetProperties[0].Name -ne 'hoarfrost:development' -or
    -not $Registered -or $Registered.project -ne 'hoarfrost' -or
    $Registered.environment -ne 'assos' -or $Registered.target -ne 'development' -or
    @($Registered.artifacts.PSObject.Properties).Count -ne 20 -or
    $Parsed.backup_root -ne $BackupRoot
) { throw 'generated config is not the exact pinned Hoarfrost/ASSOS/development allowlist' }
$TargetRoot = [string]$Registered.root
$ModsRoot = Split-Path -Parent $TargetRoot
$AssosRoot = Split-Path -Parent $ModsRoot
$TargetPluginRoot = Join-Path $TargetRoot 'SKSE\Plugins'
if (
    (Split-Path -Leaf $TargetRoot) -ne 'Hoarfrost - Development' -or
    (Split-Path -Leaf $ModsRoot) -ne 'mods' -or
    (Split-Path -Leaf $AssosRoot) -ne 'ASSOS'
) { throw 'registered target does not have the required ASSOS/mods/development shape' }
foreach ($Path in @($AssosRoot,$ModsRoot,$TargetRoot,$TargetPluginRoot)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "registered directory does not exist: $Path" }
}

Write-Host '=== Create isolated non-admin identity ==='
$Bytes = New-Object byte[] 48
$Rng = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $Rng.GetBytes($Bytes) } finally { $Rng.Dispose() }
$PasswordText = [Convert]::ToBase64String($Bytes) + '!aA7'
$Password = ConvertTo-SecureString $PasswordText -AsPlainText -Force
$User = New-LocalUser -Name $AccountName -Password $Password -AccountNeverExpires `
    -PasswordNeverExpires -UserMayNotChangePassword `
    -Description 'Bounded Skyrim Agent Toolkit deployment bridge identity'
$PasswordText = $null
$UnexpectedGroups = @()
foreach ($Group in Get-LocalGroup) {
    $Members = @(Get-LocalGroupMember -Group $Group.Name -ErrorAction Stop)
    if ($Members | Where-Object { $_.SID.Value -eq $User.SID.Value }) {
        if ($Group.Name -ne 'Users') { $UnexpectedGroups += $Group.Name }
    }
}
if ($UnexpectedGroups.Count -gt 0) { throw "unexpected SkyrimDeploy groups: $($UnexpectedGroups -join ', ')" }

Write-Host '=== Deny ASSOS writes, then isolate and allow only registered target ==='
$DenyWrites = "${DeployAccount}:(OI)(CI)(WD,AD,WEA,DC,WA,DE)"
$AllowTarget = "${DeployAccount}:(OI)(CI)(M)"
Invoke-Icacls $AssosRoot '/deny' $DenyWrites
Invoke-Icacls $TargetRoot '/inheritance:d'
Invoke-Icacls $TargetRoot '/remove:d' $DeployAccount '/T' '/C'
Invoke-Icacls $TargetRoot '/grant:r' $AllowTarget '/T' '/C'

Write-Host '=== Create exact protected service/config ACLs ==='
New-Item -ItemType Directory -Path $BridgeDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
Set-ExactDirectoryAcl $Stage ([System.Security.AccessControl.FileSystemRights]::ReadAndExecute)
Set-ExactDirectoryAcl $BridgeDirectory ([System.Security.AccessControl.FileSystemRights]::ReadAndExecute)
Set-ExactDirectoryAcl $BackupRoot ([System.Security.AccessControl.FileSystemRights]::Modify)
Copy-Item -LiteralPath $Source -Destination $Destination
Copy-Item -LiteralPath $Config -Destination $ConfigDestination
Copy-Item -LiteralPath $SmokeScript -Destination $SmokeDestination
foreach ($Pair in @(@($Destination,$ExpectedBridgeHash),@($ConfigDestination,$ExpectedConfigHash),@($SmokeDestination,$ExpectedSmokeHash))) {
    Set-ExactFileAcl $Pair[0]
    Assert-Hash $Pair[0] $Pair[1]
}

Write-Host '=== Register exact loopback bridge S4U task ==='
$Action = New-ScheduledTaskAction -Execute $Node -Argument "`"$Destination`"" -WorkingDirectory $Stage
$TaskPrincipal = New-ScheduledTaskPrincipal -UserId $DeployAccount -LogonType S4U -RunLevel Limited
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName $TaskName -Action $Action -Principal $TaskPrincipal `
    -Settings $Settings -Description 'Bounded Hoarfrost ASSOS deployment bridge' | Out-Null
$Task = Get-ScheduledTask -TaskName $TaskName
if (
    $Task.Principal.UserId -ne $DeployAccount -or $Task.Principal.LogonType -ne 'S4U' -or
    $Task.Principal.RunLevel -ne 'Limited' -or $Task.Actions.Count -ne 1 -or
    $Task.Actions[0].Execute -ne $Node -or $Task.Actions[0].Arguments -ne "`"$Destination`""
) { throw 'registered service task does not match pinned identity/action' }
Start-ScheduledTask -TaskName $TaskName
$Listener = $null
for ($Attempt=0; $Attempt -lt 20; $Attempt++) {
    $Listener = Get-NetTCPConnection -LocalPort 7347 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($Listener) { break }
    Start-Sleep 1
}
if (-not $Listener -or $Listener.LocalAddress -ne '127.0.0.1') { throw 'bridge did not become loopback-only within 20 seconds' }
$Process = Get-CimInstance Win32_Process -Filter "ProcessId=$($Listener.OwningProcess)"
$Owner = Invoke-CimMethod -InputObject $Process -MethodName GetOwner
if ($Owner.User -ne $AccountName -or $Owner.Domain -ne $env:COMPUTERNAME -or
    $Process.ExecutablePath -ne $Node -or $Process.CommandLine -notlike "*`"$Destination`"*") {
    throw 'listener process identity/executable/command line is not pinned'
}
if ((Invoke-RestMethod 'http://127.0.0.1:7347/health').ok -ne $true) { throw 'local bridge health failed' }

Write-Host '=== Run target/all-unrelated/protected-file effective ACL smoke ==='
$SmokeToken = [Guid]::NewGuid().ToString('N')
$SmokeResult = Join-Path $BackupRoot "acl-smoke-$SmokeToken.json"
$PowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
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
        $SmokeState = (Get-ScheduledTask -TaskName $SmokeTaskName).State
        if ($SmokeState -ne 'Running' -and (Test-Path -LiteralPath $SmokeResult -PathType Leaf)) { break }
        Start-Sleep 1
    }
    $SmokeInfo = Get-ScheduledTaskInfo -TaskName $SmokeTaskName
    if ($SmokeInfo.LastTaskResult -ne 0 -or -not (Test-Path -LiteralPath $SmokeResult -PathType Leaf)) {
        throw "ACL smoke task failed: result=$($SmokeInfo.LastTaskResult)"
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

Write-Host '=== Local provisioning successful; Tailscale remains unchanged ==='
Write-Host "Listener: 127.0.0.1:7347 owner=$DeployAccount"
Write-Host "Registered target smoke: write/hash/remove passed at $TargetPluginRoot"
Write-Host "All unrelated mod roots refused: $($Smoke.unrelated_count)"
Write-Host 'Protected config and bridge write-open attempts refused'
Write-Host "ACL smoke evidence: $SmokeResult"
