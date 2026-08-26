param(
    [Parameter(Mandatory = $true)][string]$Worker,
    [Parameter(Mandatory = $true)][string]$Wrapper,
    [Parameter(Mandatory = $true)][string]$Config,
    [Parameter(Mandatory = $true)][string]$PublicKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExpectedSid = 'S-1-5-21-3046562540-2879210194-691397096-1014'
$ExpectedWorkerHash = '99eabaafbd3e0b850ae0d3e8a891e4443d57dd2900a2423f5c9804a5e87e6442'
$ExpectedWrapperHash = '64ab744b89a2eb124db80b2081f46212a5c277d57262f7803d1f14b13601297e'
$ExpectedConfigHash = '8103009b73fb481c5a3ae631282bea412ae0aa4b7b95a57ed82a2863c2afac4a'
$ExpectedPublicKeyHash = '91bd33e543bf43ef38683a630da7961e2a50a7060dec4e3a55fd79ac7c1bbb53'
$AccountName = 'SkyrimDeploy'
$DeployAccount = "${env:COMPUTERNAME}\$AccountName"
$Stage = 'C:\ProgramData\SkyrimToolBridge\project-deploy'
$BridgeDirectory = Join-Path $Stage 'bridge'
$BackupRoot = Join-Path $Stage 'backups'
$WorkerDestination = Join-Path $BridgeDirectory 'bridge.js'
$WrapperDestination = Join-Path $Stage 'invoke-ssh.ps1'
$ConfigDestination = Join-Path $Stage 'config.json'
$SshDirectory = 'C:\ProgramData\ssh'
$SshConfig = Join-Path $SshDirectory 'sshd_config'
$KeyDirectory = 'C:\ProgramData\SkyrimToolBridge\openssh'
$AuthorizedKeys = Join-Path $KeyDirectory 'authorized_keys'
$Sshd = 'C:\Windows\System32\OpenSSH\sshd.exe'
$Node = 'D:\Program Files\nodejs\node.exe'
$TaskName = 'SkyrimToolBridge-Project-Deploy'
$CandidateDll = 'D:\Games\Wabbajack\Modlists\ASSOS\mods\Hoarfrost - Development\SKSE\Plugins\Hoarfrost.dll'
$CandidatePdb = 'D:\Games\Wabbajack\Modlists\ASSOS\mods\Hoarfrost - Development\SKSE\Plugins\Hoarfrost.pdb'
$ForceCommand = 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:/ProgramData/SkyrimToolBridge/project-deploy/invoke-ssh.ps1'

function Assert-Hash {
    param([string]$Path, [string]$Expected)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "required file is absent: $Path" }
    $Actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Actual -ne $Expected) { throw "SHA256 mismatch for ${Path}: expected=$Expected actual=$Actual" }
}

function Get-OptionalHash {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-CandidateState {
    $BackupFiles = @(Get-ChildItem -LiteralPath $BackupRoot -File -Recurse -Force -ErrorAction Stop)
    if ($BackupFiles.Count -gt 10000) { throw 'candidate backup snapshot exceeded 10000 files' }
    $CandidateBackups = @(
        $BackupFiles |
        Where-Object {
            $Name = $_.FullName.Replace('/', '\').ToLowerInvariant()
            $Name.EndsWith('\skse\plugins\hoarfrost.dll') -or
                $Name.EndsWith('\skse\plugins\hoarfrost.pdb')
        } |
        Sort-Object FullName |
        ForEach-Object {
            [ordered]@{
                path = $_.FullName.ToLowerInvariant()
                sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    )
    return ([ordered]@{
        dll_sha256 = Get-OptionalHash $CandidateDll
        pdb_sha256 = Get-OptionalHash $CandidatePdb
        backups = $CandidateBackups
    } | ConvertTo-Json -Depth 5 -Compress)
}

function Add-AllowRule {
    param(
        [System.Security.AccessControl.FileSystemSecurity]$Acl,
        [string]$Identity,
        [System.Security.AccessControl.FileSystemRights]$Rights,
        [System.Security.AccessControl.InheritanceFlags]$Inheritance = [System.Security.AccessControl.InheritanceFlags]::None
    )
    $Rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        $Identity,
        $Rights,
        $Inheritance,
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow)
    $Acl.AddAccessRule($Rule) | Out-Null
}

function Set-ProtectedFileAcl {
    param(
        [string]$Path,
        [System.Security.AccessControl.FileSystemRights]$DeployRights
    )
    $Acl = New-Object System.Security.AccessControl.FileSecurity
    $Acl.SetAccessRuleProtection($true, $false)
    $Acl.SetOwner([Security.Principal.NTAccount]::new('BUILTIN\Administrators'))
    Add-AllowRule $Acl 'BUILTIN\Administrators' ([System.Security.AccessControl.FileSystemRights]::FullControl)
    Add-AllowRule $Acl 'NT AUTHORITY\SYSTEM' ([System.Security.AccessControl.FileSystemRights]::FullControl)
    Add-AllowRule $Acl $DeployAccount $DeployRights
    Set-Acl -LiteralPath $Path -AclObject $Acl
}

function Set-KeyFileAcl {
    param([string]$Path)
    $Acl = New-Object System.Security.AccessControl.FileSecurity
    $Acl.SetAccessRuleProtection($true, $false)
    $Acl.SetOwner([Security.Principal.NTAccount]::new('BUILTIN\Administrators'))
    Add-AllowRule $Acl 'BUILTIN\Administrators' ([System.Security.AccessControl.FileSystemRights]::FullControl)
    Add-AllowRule $Acl 'NT AUTHORITY\SYSTEM' ([System.Security.AccessControl.FileSystemRights]::FullControl)
    Set-Acl -LiteralPath $Path -AclObject $Acl
}

function Set-KeyDirectoryAcl {
    param([string]$Path)
    $Acl = New-Object System.Security.AccessControl.DirectorySecurity
    $Acl.SetAccessRuleProtection($true, $false)
    $Acl.SetOwner([Security.Principal.NTAccount]::new('BUILTIN\Administrators'))
    $Inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    Add-AllowRule $Acl 'BUILTIN\Administrators' ([System.Security.AccessControl.FileSystemRights]::FullControl) $Inheritance
    Add-AllowRule $Acl 'NT AUTHORITY\SYSTEM' ([System.Security.AccessControl.FileSystemRights]::FullControl) $Inheritance
    Set-Acl -LiteralPath $Path -AclObject $Acl
}

function Assert-NoBroadWriteAcl {
    param([string]$Path)
    $Dangerous = [System.Security.AccessControl.FileSystemRights]'WriteData, AppendData, CreateFiles, CreateDirectories, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership, WriteAttributes, WriteExtendedAttributes'
    $BroadSids = @($ExpectedSid, 'S-1-1-0', 'S-1-5-11', 'S-1-5-32-545')
    $Acl = Get-Acl -LiteralPath $Path
    $OwnerSid = $Acl.Owner
    try { $OwnerSid = ([Security.Principal.NTAccount]$Acl.Owner).Translate([Security.Principal.SecurityIdentifier]).Value } catch {}
    if ($OwnerSid -in $BroadSids) { throw "runtime path has an untrusted owner: $Path owner=$OwnerSid" }
    foreach ($Rule in $Acl.Access) {
        if ($Rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
        $Sid = $Rule.IdentityReference.Value
        try { $Sid = $Rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch {}
        if ($Sid -in $BroadSids -and ($Rule.FileSystemRights -band $Dangerous)) {
            throw "runtime path grants broad write/replace rights: $Path sid=$Sid rights=$($Rule.FileSystemRights)"
        }
    }
}

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'forced-command provisioning requires Administrator Windows PowerShell'
}
if (-not [Environment]::Is64BitProcess -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw 'forced-command provisioning requires 64-bit Windows PowerShell 5.1'
}
if (Get-Process SkyrimSE -ErrorAction SilentlyContinue) { throw 'refusing provisioning while SkyrimSE is running' }
$User = Get-LocalUser -Name $AccountName -ErrorAction Stop
if (-not $User.Enabled -or $User.SID.Value -ne $ExpectedSid) { throw 'SkyrimDeploy does not match the diagnosed partial-provisioning SID' }
$AdminMembers = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop)
if ($AdminMembers.SID.Value -contains $ExpectedSid) { throw 'SkyrimDeploy must not be an Administrator' }
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { throw 'deployment Scheduled Task unexpectedly exists' }
if (Get-NetTCPConnection -LocalPort 7347 -State Listen -ErrorAction SilentlyContinue) { throw 'legacy deployment listener unexpectedly exists on port 7347' }
$SshService = Get-CimInstance Win32_Service -Filter "Name='sshd'"
if (-not $SshService -or $SshService.State -ne 'Running') { throw 'OpenSSH sshd service is not running' }
if ($SshService.StartName -notmatch '^(?i:LocalSystem|NT AUTHORITY\\SYSTEM)$') {
    throw "sshd is not running as LocalSystem: $($SshService.StartName)"
}
if ($SshService.PathName -notmatch [regex]::Escape($Sshd)) { throw "sshd service does not use pinned binary: $($SshService.PathName)" }
$SshVersion = (& $Sshd '-V' 2>&1 | Out-String).Trim()
if ($SshVersion -notmatch '(?i)OpenSSH_for_Windows_9\.5p2\b') { throw "expected OpenSSH_for_Windows_9.5p2: $SshVersion" }
foreach ($Path in @($Worker,$Wrapper,$Config,$PublicKey,$SshConfig,$Sshd,$Node,$Stage,$BridgeDirectory,$BackupRoot)) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "required path is absent: $Path" }
}
Assert-Hash $Worker $ExpectedWorkerHash
Assert-Hash $Wrapper $ExpectedWrapperHash
Assert-Hash $Config $ExpectedConfigHash
Assert-Hash $PublicKey $ExpectedPublicKeyHash
$NodeVersion = (& $Node '--version' 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $NodeVersion -notmatch '^v(?:2[0-9]|[3-9][0-9]|[1-9][0-9]{2,})\.[0-9]+\.[0-9]+$') {
    throw "expected a pinned-path Node.js 20+ runtime: $NodeVersion"
}
foreach ($RuntimePath in @($Node, (Split-Path -Parent $Node), (Split-Path -Parent (Split-Path -Parent $Node)), $Stage, $BridgeDirectory)) {
    Assert-NoBroadWriteAcl $RuntimePath
}
$NodeHash = (Get-FileHash -LiteralPath $Node -Algorithm SHA256).Hash.ToLowerInvariant()
& $Node '--check' $Worker
if ($LASTEXITCODE -ne 0) { throw 'deployment worker JavaScript syntax check failed' }
$CandidateStateBefore = Get-CandidateState
$KeyLines = @(Get-Content -LiteralPath $PublicKey | Where-Object { $_.Trim() })
if ($KeyLines.Count -ne 1 -or $KeyLines[0] -notmatch '^ssh-ed25519 [A-Za-z0-9+/]+={0,3}(?: .*)?$') {
    throw 'deployment public key must contain exactly one Ed25519 public key'
}
$BlockBegin = '# BEGIN SkyrimToolBridge project-deploy-v1'
$BlockEnd = '# END SkyrimToolBridge project-deploy-v1'
$ManagedLines = @(
    $BlockBegin,
    '# Bounded Skyrim project deployment forced command',
    'Match User skyrimdeploy',
    '    AuthenticationMethods publickey',
    '    PubkeyAuthentication yes',
    '    PasswordAuthentication no',
    '    KbdInteractiveAuthentication no',
    '    PermitEmptyPasswords no',
    '    AuthorizedKeysFile C:/ProgramData/SkyrimToolBridge/openssh/authorized_keys',
    "    ForceCommand $ForceCommand",
    '    DisableForwarding yes',
    '    AllowTcpForwarding no',
    '    AllowStreamLocalForwarding no',
    '    AllowAgentForwarding no',
    '    X11Forwarding no',
    '    GatewayPorts no',
    '    PermitTunnel no',
    '    PermitOpen none',
    '    PermitListen none',
    '    PermitTTY no',
    '    PermitUserEnvironment no',
    '    PermitUserRC no',
    '    MaxAuthTries 3',
    '    MaxSessions 1',
    '    ChannelTimeout session=600',
    $BlockEnd
)
$ManagedBlockText = ($ManagedLines -join "`r`n") + "`r`n"
$ManagedPattern = '(?ms)^' + [regex]::Escape($BlockBegin) + '\r?\n.*?^' + [regex]::Escape($BlockEnd) + '\r?\n?'

Write-Host '=== Validate byte-preserving candidate sshd_config before any service change ==='
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Candidate = Join-Path $SshDirectory "sshd_config.project-deploy.$Stamp.candidate"
$ConfigBackup = Join-Path $SshDirectory "sshd_config.project-deploy.$Stamp.bak"
& $Sshd '-t' '-f' $SshConfig
if ($LASTEXITCODE -ne 0) { throw 'baseline sshd_config failed syntax validation' }
$ExistingUsers = @(Get-LocalUser | Where-Object { $_.Name -ine $AccountName } | Select-Object -ExpandProperty Name)
foreach ($RequiredExisting in @('HoarfrostTransfer','HoarfrostBuild')) {
    if (-not ($ExistingUsers -icontains $RequiredExisting)) { throw "required bounded SSH identity is absent: $RequiredExisting" }
}

$LiveConfigBytes = [IO.File]::ReadAllBytes($SshConfig)
if (@($LiveConfigBytes | Where-Object { $_ -gt 127 }).Count -ne 0) {
    throw 'sshd_config contains non-ASCII bytes; refusing a byte-ambiguous managed-block update'
}
$Ascii = [Text.Encoding]::ASCII
$LiveConfigText = $Ascii.GetString($LiveConfigBytes)
$ManagedMatches = @([regex]::Matches($LiveConfigText, $ManagedPattern))
$BeginCount = ([regex]::Matches($LiveConfigText, '(?m)^' + [regex]::Escape($BlockBegin) + '\r?$')).Count
$EndCount = ([regex]::Matches($LiveConfigText, '(?m)^' + [regex]::Escape($BlockEnd) + '\r?$')).Count
if ($BeginCount -ne $EndCount -or $BeginCount -gt 1 -or $ManagedMatches.Count -ne $BeginCount) {
    throw 'managed SkyrimDeploy sshd block markers are ambiguous'
}
if ($ManagedMatches.Count -eq 1) {
    $ManagedMatch = $ManagedMatches[0]
    $Before = if ($ManagedMatch.Index -gt 0) { $LiveConfigBytes[0..($ManagedMatch.Index - 1)] } else { @() }
    $AfterIndex = $ManagedMatch.Index + $ManagedMatch.Length
    $After = if ($AfterIndex -lt $LiveConfigBytes.Length) { $LiveConfigBytes[$AfterIndex..($LiveConfigBytes.Length - 1)] } else { @() }
    $BaseConfigBytes = [byte[]]@($Before + $After)
} else {
    $BaseConfigBytes = [byte[]]$LiveConfigBytes.Clone()
}
$BaseConfigText = $Ascii.GetString($BaseConfigBytes)
$BaseActiveConfig = @($BaseConfigText -split '\r?\n' | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') })
if ($BaseActiveConfig -match '(?i)^\s*Match\s+User\s+.*\bskyrimdeploy\b') {
    throw 'an unmanaged SkyrimDeploy sshd Match block exists; refusing ambiguous provisioning'
}
$Separator = if ($BaseConfigBytes.Length -gt 0 -and $BaseConfigBytes[$BaseConfigBytes.Length - 1] -eq 10) { '' } else { "`r`n" }
$AppendBytes = $Ascii.GetBytes($Separator + $ManagedBlockText)
$CandidateBytes = [byte[]]@($BaseConfigBytes + $AppendBytes)
[IO.File]::WriteAllBytes($Candidate, $CandidateBytes)
for ($Index = 0; $Index -lt $BaseConfigBytes.Length; $Index++) {
    if ($CandidateBytes[$Index] -ne $BaseConfigBytes[$Index]) {
        throw "candidate changed pre-existing sshd_config byte at offset $Index"
    }
}
$CandidateText = $Ascii.GetString([IO.File]::ReadAllBytes($Candidate))
$CandidateManagedMatches = @([regex]::Matches($CandidateText, $ManagedPattern))
if ($CandidateManagedMatches.Count -ne 1 -or $CandidateManagedMatches[0].Value -cne $ManagedBlockText) {
    throw 'candidate does not contain exactly the canonical managed SkyrimDeploy block'
}
if (([regex]::Matches($CandidateText, '(?im)^\s*Match\s+User\s+skyrimdeploy\s*$')).Count -ne 1) {
    throw 'candidate does not contain exactly one structural SkyrimDeploy Match User line'
}
& $Sshd '-t' '-f' $Candidate
if ($LASTEXITCODE -ne 0) { throw 'candidate sshd_config failed syntax validation' }
Write-Host 'Candidate syntax, byte preservation, and exact managed-block validation passed; live SSH smoke remains required.'

Write-Host '=== Snapshot rollback state ==='
$RuntimeBackup = Join-Path $BackupRoot "provisioning-$Stamp"
New-Item -ItemType Directory -Path $RuntimeBackup -Force | Out-Null
$ManagedPaths = @($WorkerDestination,$WrapperDestination,$ConfigDestination,$AuthorizedKeys)
$ManagedState = @()
for ($Index = 0; $Index -lt $ManagedPaths.Count; $Index++) {
    $ManagedPath = $ManagedPaths[$Index]
    $Exists = Test-Path -LiteralPath $ManagedPath -PathType Leaf
    $BackupPath = Join-Path $RuntimeBackup "managed-$Index.bin"
    $Sddl = $null
    $PriorHash = $null
    if ($Exists) {
        Copy-Item -LiteralPath $ManagedPath -Destination $BackupPath
        $Sddl = (Get-Acl -LiteralPath $ManagedPath).Sddl
        $PriorHash = (Get-FileHash -LiteralPath $ManagedPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $ManagedState += [pscustomobject]@{
        Path = $ManagedPath
        Existed = $Exists
        Backup = $BackupPath
        Sddl = $Sddl
        PriorHash = $PriorHash
    }
}
$KeyDirectoryExisted = Test-Path -LiteralPath $KeyDirectory -PathType Container
$KeyDirectorySddl = if ($KeyDirectoryExisted) { (Get-Acl -LiteralPath $KeyDirectory).Sddl } else { $null }
Copy-Item -LiteralPath $SshConfig -Destination $ConfigBackup
$OriginalHash = (Get-FileHash -LiteralPath $ConfigBackup -Algorithm SHA256).Hash
$OriginalConfigSddl = (Get-Acl -LiteralPath $SshConfig).Sddl
$RestrictedKey = "restrict,command=`"$ForceCommand`" $($KeyLines[0])"
$RestrictedKeyBytes = [Text.UTF8Encoding]::new($false).GetBytes($RestrictedKey + "`n")
$Sha256 = [Security.Cryptography.SHA256]::Create()
try {
    $ExpectedAuthorizedKeyHash = ([BitConverter]::ToString($Sha256.ComputeHash($RestrictedKeyBytes))).Replace('-', '').ToLowerInvariant()
} finally {
    $Sha256.Dispose()
}
$ExpectedManagedHashes = @{}
$ExpectedManagedHashes[$WorkerDestination] = $ExpectedWorkerHash
$ExpectedManagedHashes[$WrapperDestination] = $ExpectedWrapperHash
$ExpectedManagedHashes[$ConfigDestination] = $ExpectedConfigHash
$ExpectedManagedHashes[$AuthorizedKeys] = $ExpectedAuthorizedKeyHash
$InstalledConfigHash = $null

Write-Host '=== Install protected runtime, key, and validated sshd config ==='
try {
    Copy-Item -LiteralPath $Worker -Destination $WorkerDestination -Force
    Copy-Item -LiteralPath $Wrapper -Destination $WrapperDestination -Force
    Copy-Item -LiteralPath $Config -Destination $ConfigDestination -Force
    New-Item -ItemType Directory -Path $KeyDirectory -Force | Out-Null
    Set-KeyDirectoryAcl $KeyDirectory
    [IO.File]::WriteAllText($AuthorizedKeys, $RestrictedKey + "`n", [Text.UTF8Encoding]::new($false))
    Set-ProtectedFileAcl $WorkerDestination ([System.Security.AccessControl.FileSystemRights]::ReadAndExecute)
    Set-ProtectedFileAcl $WrapperDestination ([System.Security.AccessControl.FileSystemRights]::ReadAndExecute)
    Set-ProtectedFileAcl $ConfigDestination ([System.Security.AccessControl.FileSystemRights]::ReadAndExecute)
    Set-KeyFileAcl $AuthorizedKeys
    Assert-Hash $WorkerDestination $ExpectedWorkerHash
    Assert-Hash $WrapperDestination $ExpectedWrapperHash
    Assert-Hash $ConfigDestination $ExpectedConfigHash
    if ((Get-Content -LiteralPath $AuthorizedKeys -Raw) -ne ($RestrictedKey + "`n")) {
        throw 'installed restricted authorized key content mismatch'
    }

    Copy-Item -LiteralPath $Candidate -Destination $SshConfig -Force
    $InstalledConfigHash = (Get-FileHash -LiteralPath $SshConfig -Algorithm SHA256).Hash.ToLowerInvariant()
    & $Sshd '-t' '-f' $SshConfig
    if ($LASTEXITCODE -ne 0) { throw 'installed sshd_config failed syntax validation' }
    Restart-Service sshd -ErrorAction Stop
    $Healthy = $false
    for ($Attempt = 0; $Attempt -lt 20; $Attempt++) {
        $Service = Get-Service sshd
        $Listener = Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($Service.Status -eq 'Running' -and $Listener) { $Healthy = $true; break }
        Start-Sleep 1
    }
    if (-not $Healthy) { throw 'sshd did not return healthy with a port 22 listener within 20 seconds' }
    Assert-Hash $SshConfig $InstalledConfigHash
    if ((Get-CandidateState) -cne $CandidateStateBefore) {
        throw 'ordinary-finger candidate destinations or candidate backups changed during provisioning'
    }
} catch {
    $Failure = $_
    $RollbackErrors = @()
    try {
        Stop-Service sshd -Force -ErrorAction Stop
        for ($Attempt = 0; $Attempt -lt 20 -and (Get-Service sshd).Status -ne 'Stopped'; $Attempt++) { Start-Sleep 1 }
        if ((Get-Service sshd).Status -ne 'Stopped') { throw 'sshd did not reach Stopped before rollback restore' }
    } catch { $RollbackErrors += "stop/wait sshd: $($_.Exception.Message)" }
    try {
        $CurrentConfigHash = (Get-FileHash -LiteralPath $SshConfig -Algorithm SHA256).Hash.ToLowerInvariant()
        $OriginalConfigHash = $OriginalHash.ToLowerInvariant()
        if ($CurrentConfigHash -ne $OriginalConfigHash -and
            (-not $InstalledConfigHash -or $CurrentConfigHash -ne $InstalledConfigHash)) {
            throw "sshd_config changed outside this provisioning transaction; refusing rollback overwrite: $CurrentConfigHash"
        }
        Copy-Item -LiteralPath $ConfigBackup -Destination $SshConfig -Force
        $Acl = Get-Acl -LiteralPath $SshConfig
        $Acl.SetSecurityDescriptorSddlForm($OriginalConfigSddl)
        Set-Acl -LiteralPath $SshConfig -AclObject $Acl
        & $Sshd '-t' '-f' $SshConfig
        if ($LASTEXITCODE -ne 0) { throw 'restored sshd_config failed syntax validation' }
    } catch { $RollbackErrors += "restore sshd_config: $($_.Exception.Message)" }
    foreach ($State in $ManagedState) {
        try {
            if (Test-Path -LiteralPath $State.Path -PathType Leaf) {
                $CurrentManagedHash = (Get-FileHash -LiteralPath $State.Path -Algorithm SHA256).Hash.ToLowerInvariant()
                $ExpectedManagedHash = $ExpectedManagedHashes[$State.Path]
                if ($CurrentManagedHash -ne $ExpectedManagedHash -and
                    (-not $State.PriorHash -or $CurrentManagedHash -ne $State.PriorHash)) {
                    throw "managed file changed outside this provisioning transaction; refusing rollback overwrite: $($State.Path) hash=$CurrentManagedHash"
                }
            }
            if ($State.Existed) {
                Copy-Item -LiteralPath $State.Backup -Destination $State.Path -Force
                $Acl = Get-Acl -LiteralPath $State.Path
                $Acl.SetSecurityDescriptorSddlForm($State.Sddl)
                Set-Acl -LiteralPath $State.Path -AclObject $Acl
            } else {
                Remove-Item -LiteralPath $State.Path -Force -ErrorAction SilentlyContinue
            }
        } catch { $RollbackErrors += "restore $($State.Path): $($_.Exception.Message)" }
    }
    if (-not $KeyDirectoryExisted) {
        try { Remove-Item -LiteralPath $KeyDirectory -Force -ErrorAction Stop } catch { $RollbackErrors += "remove key directory: $($_.Exception.Message)" }
    } elseif ($KeyDirectorySddl) {
        try {
            $Acl = Get-Acl -LiteralPath $KeyDirectory
            $Acl.SetSecurityDescriptorSddlForm($KeyDirectorySddl)
            Set-Acl -LiteralPath $KeyDirectory -AclObject $Acl
        } catch { $RollbackErrors += "restore key directory ACL: $($_.Exception.Message)" }
    }
    try {
        Start-Service sshd -ErrorAction Stop
        for ($Attempt = 0; $Attempt -lt 20 -and (Get-Service sshd).Status -ne 'Running'; $Attempt++) { Start-Sleep 1 }
        if ((Get-Service sshd).Status -ne 'Running') { throw 'restored sshd did not reach Running' }
        $RestoredListener = Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $RestoredListener) { throw 'restored sshd has no port 22 listener' }
        Assert-Hash $SshConfig $OriginalConfigHash
    } catch { $RollbackErrors += "restart/validate restored sshd: $($_.Exception.Message)" }
    try {
        if ((Get-CandidateState) -cne $CandidateStateBefore) {
            throw 'ordinary-finger candidate destinations or candidate backups changed during provisioning/rollback'
        }
    } catch { $RollbackErrors += "candidate-state validation: $($_.Exception.Message)" }
    if ($RollbackErrors.Count -gt 0) {
        throw "provisioning failed: $($Failure.Exception.Message); ROLLBACK FAILED: $($RollbackErrors -join '; ')"
    }
    throw "provisioning failed and all managed state was restored: $($Failure.Exception.Message)"
} finally {
    Remove-Item -LiteralPath $Candidate -Force -ErrorAction SilentlyContinue
}

$InstalledHash = (Get-FileHash -LiteralPath $SshConfig -Algorithm SHA256).Hash
Write-Host '=== Forced-command provisioning complete; remote smoke still required ==='
Write-Host "Original sshd_config SHA256: $OriginalHash"
Write-Host "Installed sshd_config SHA256: $InstalledHash"
Write-Host "Node.js runtime: $NodeVersion SHA256=$NodeHash"
Write-Host "Backup: $ConfigBackup"
Write-Host "Runtime backup: $RuntimeBackup"
Write-Host "Authorized key: $AuthorizedKeys"
Write-Host 'No Scheduled Task, port 7347 listener, Tailscale route, or candidate deployment was created.'
