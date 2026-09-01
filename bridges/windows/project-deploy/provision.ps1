param(
    [Parameter(Mandatory = $true)][string]$Worker,
    [Parameter(Mandatory = $true)][string]$Wrapper,
    [Parameter(Mandatory = $true)][string]$Config,
    [Parameter(Mandatory = $true)][string]$PublicKey,
    [Parameter(Mandatory = $true)][string]$NodeRuntime
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExpectedSid = 'S-1-5-21-3046562540-2879210194-691397096-1014'
$ExpectedWorkerHash = '63f7e7ee30ef0c07fc7cd495d68ad5ea185d4a0b42a80141140368ca2f8e77ae'
$ExpectedWrapperHash = 'c8b6c56d2ad0bd864e61fb49bf96f17140de600ababd47707d669a513e117023'
$ExpectedConfigHash = '3761b240a774a97b732548d535b715b8cf887f17079e1a71398372b2acdb579c'
$ExpectedPublicKeyHash = '91bd33e543bf43ef38683a630da7961e2a50a7060dec4e3a55fd79ac7c1bbb53'
$ExpectedNodeHash = '3331e1ffe19874215472217c5e94f5a0c6d8e18c4ac7111d3937aa0ad5e9b4a5'
$ExpectedNodeVersion = 'v24.15.0'
$ExpectedNodeFileVersion = '24.15.0'
$ExpectedNodeSignerThumbprint = '53EFB21DD2F03E171CFF88977C2B0B1E8DF7E2A2'
$AccountName = 'SkyrimDeploy'
$DeployAccount = "${env:COMPUTERNAME}\$AccountName"
$SharedToolkitRoot = 'C:\ProgramData\SkyrimToolBridge'
$BackupRoot = Join-Path $SharedToolkitRoot 'project-deploy\backups'
$ProtectedParent = 'C:\Program Files'
$ProtectedRoot = Join-Path $ProtectedParent 'SkyrimDeployBridge'
$BridgeDirectory = Join-Path $ProtectedRoot 'bridge'
$WorkerDestination = Join-Path $BridgeDirectory 'bridge.js'
$WrapperDestination = Join-Path $ProtectedRoot 'invoke-ssh.ps1'
$ConfigDestination = Join-Path $ProtectedRoot 'config.json'
$RuntimeDirectory = Join-Path $ProtectedRoot 'runtime'
$NodeDestination = Join-Path $RuntimeDirectory 'node.exe'
$KeyDirectory = Join-Path $ProtectedRoot 'openssh'
$AuthorizedKeys = Join-Path $KeyDirectory 'authorized_keys'
$SshDirectory = 'C:\ProgramData\ssh'
$SshConfig = Join-Path $SshDirectory 'sshd_config'
$Sshd = 'C:\Windows\System32\OpenSSH\sshd.exe'
$PowerShell = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$TaskName = 'SkyrimToolBridge-Project-Deploy'
$CandidateDll = 'D:\Games\Wabbajack\Modlists\ASSOS\mods\Hoarfrost - Development\SKSE\Plugins\Hoarfrost.dll'
$CandidatePdb = 'D:\Games\Wabbajack\Modlists\ASSOS\mods\Hoarfrost - Development\SKSE\Plugins\Hoarfrost.pdb'
$ForceCommandScript = "& 'C:\Program Files\SkyrimDeployBridge\invoke-ssh.ps1'"
$ForceCommandEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ForceCommandScript))
$ForceCommand = "C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $ForceCommandEncoded"

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

function Set-ProtectedDirectoryAcl {
    param([string]$Path)
    $Acl = New-Object System.Security.AccessControl.DirectorySecurity
    $Acl.SetAccessRuleProtection($true, $false)
    $Acl.SetOwner([Security.Principal.NTAccount]::new('BUILTIN\Administrators'))
    $Inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    Add-AllowRule $Acl 'BUILTIN\Administrators' ([System.Security.AccessControl.FileSystemRights]::FullControl) $Inheritance
    Add-AllowRule $Acl 'NT AUTHORITY\SYSTEM' ([System.Security.AccessControl.FileSystemRights]::FullControl) $Inheritance
    Add-AllowRule $Acl $DeployAccount ([System.Security.AccessControl.FileSystemRights]::ReadAndExecute) $Inheritance
    Set-Acl -LiteralPath $Path -AclObject $Acl
}

function Get-UntrustedSids {
    return @(
        $ExpectedSid,
        (Get-LocalUser -Name 'HoarfrostTransfer' -ErrorAction Stop).SID.Value,
        (Get-LocalUser -Name 'HoarfrostBuild' -ErrorAction Stop).SID.Value,
        'S-1-1-0',
        'S-1-5-11',
        'S-1-5-32-545'
    )
}

function Get-OwnerSid {
    param([System.Security.AccessControl.FileSystemSecurity]$Acl)
    try { return ([Security.Principal.NTAccount]$Acl.Owner).Translate([Security.Principal.SecurityIdentifier]).Value } catch { return $Acl.Owner }
}

function Test-AceAppliesToObject {
    param([System.Security.AccessControl.FileSystemAccessRule]$Rule)
    return -not ($Rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly)
}

function Get-RawFileSystemRights {
    param([System.Security.AccessControl.FileSystemRights]$Rights)
    return [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$Rights), 0)
}

function Test-MutationRights {
    param([System.Security.AccessControl.FileSystemRights]$Rights)
    $Dangerous = [System.Security.AccessControl.FileSystemRights]'WriteData, AppendData, CreateFiles, CreateDirectories, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership, WriteAttributes, WriteExtendedAttributes'
    $RawRights = Get-RawFileSystemRights $Rights
    return [bool](($Rights -band $Dangerous) -or ($RawRights -band [uint32]1073741824) -or ($RawRights -band [uint32]268435456))
}

function Test-AclControlRights {
    param([System.Security.AccessControl.FileSystemRights]$Rights)
    $Control = [System.Security.AccessControl.FileSystemRights]'ChangePermissions, TakeOwnership'
    $RawRights = Get-RawFileSystemRights $Rights
    return [bool](($Rights -band $Control) -or ($RawRights -band [uint32]268435456))
}

function Test-AncestorReplacementRights {
    param([System.Security.AccessControl.FileSystemRights]$Rights)
    $Replacement = [System.Security.AccessControl.FileSystemRights]'Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership'
    $RawRights = Get-RawFileSystemRights $Rights
    return [bool](($Rights -band $Replacement) -or ($RawRights -band [uint32]268435456))
}

function Assert-NoBroadMutationAcl {
    param([string]$Path)
    $BroadSids = Get-UntrustedSids
    $Acl = Get-Acl -LiteralPath $Path
    $OwnerSid = Get-OwnerSid $Acl
    if ($OwnerSid -in $BroadSids) { throw "trusted path has an untrusted owner: $Path owner=$OwnerSid" }
    foreach ($Rule in $Acl.Access) {
        if ($Rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or -not (Test-AceAppliesToObject $Rule)) { continue }
        $Sid = $Rule.IdentityReference.Value
        try { $Sid = $Rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch {}
        if ($Sid -in $BroadSids -and (Test-MutationRights $Rule.FileSystemRights)) {
            throw "trusted path grants broad mutation rights: $Path sid=$Sid rights=$($Rule.FileSystemRights)"
        }
    }
}

function Assert-NoBroadAncestorReplacementAcl {
    param([string]$Path)
    $BroadSids = Get-UntrustedSids
    $Acl = Get-Acl -LiteralPath $Path
    $OwnerSid = Get-OwnerSid $Acl
    if ($OwnerSid -in $BroadSids) { throw "trusted ancestor has an untrusted owner: $Path owner=$OwnerSid" }
    foreach ($Rule in $Acl.Access) {
        if ($Rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or -not (Test-AceAppliesToObject $Rule)) { continue }
        $Sid = $Rule.IdentityReference.Value
        try { $Sid = $Rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch {}
        if ($Sid -in $BroadSids -and (Test-AncestorReplacementRights $Rule.FileSystemRights)) {
            throw "trusted ancestor grants broad child-replacement/control rights: $Path sid=$Sid rights=$($Rule.FileSystemRights)"
        }
    }
}

function Assert-Ed25519PublicKeyLine {
    param([string]$Line)
    $Parts = @($Line -split '\s+', 3)
    if ($Parts.Count -lt 2 -or $Parts[0] -cne 'ssh-ed25519') { throw 'deployment public key is not Ed25519' }
    try { $Blob = [Convert]::FromBase64String($Parts[1]) } catch { throw 'deployment public key has invalid base64' }
    if ($Blob.Length -ne 51) { throw "deployment Ed25519 public-key blob has unexpected length: $($Blob.Length)" }
    $AlgorithmLength = [Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($Blob, 0))
    $Algorithm = [Text.Encoding]::ASCII.GetString($Blob, 4, $AlgorithmLength)
    $KeyLengthOffset = 4 + $AlgorithmLength
    $KeyLength = [Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($Blob, $KeyLengthOffset))
    if ($AlgorithmLength -ne 11 -or $Algorithm -cne 'ssh-ed25519' -or $KeyLength -ne 32 -or ($KeyLengthOffset + 4 + $KeyLength) -ne $Blob.Length) {
        throw 'deployment public key has an invalid Ed25519 wire encoding'
    }
}

function Assert-WritableStateRootIntegrity {
    param([string]$Path)
    $FullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ((Get-Item -LiteralPath $FullPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "writable state root is a reparse point: $FullPath"
    }
    $Acl = Get-Acl -LiteralPath $FullPath
    $OwnerSid = Get-OwnerSid $Acl
    if ($OwnerSid -in (Get-UntrustedSids)) { throw "writable state root has an untrusted owner: $FullPath owner=$OwnerSid" }
    $NonDeploySids = @(Get-UntrustedSids | Where-Object { $_ -ne $ExpectedSid })
    foreach ($Rule in $Acl.Access) {
        if ($Rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or -not (Test-AceAppliesToObject $Rule)) { continue }
        $Sid = $Rule.IdentityReference.Value
        try { $Sid = $Rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch {}
        if ($Sid -in $NonDeploySids -and (Test-MutationRights $Rule.FileSystemRights)) {
            throw "writable state root grants unrelated broad mutation rights: $FullPath sid=$Sid rights=$($Rule.FileSystemRights)"
        }
        if ($Sid -eq $ExpectedSid -and (Test-AclControlRights $Rule.FileSystemRights)) {
            throw "deployment identity controls writable state-root ACL: $FullPath rights=$($Rule.FileSystemRights)"
        }
    }
    $Ancestor = Split-Path -Parent $FullPath
    while ($Ancestor) {
        if ((Get-Item -LiteralPath $Ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "writable state ancestor is a reparse point: $Ancestor"
        }
        Assert-NoBroadAncestorReplacementAcl $Ancestor
        $Next = Split-Path -Parent $Ancestor
        if (-not $Next -or $Next -ieq $Ancestor) { break }
        $Ancestor = $Next
    }
}

function Assert-ProtectedPathIntegrity {
    param([string]$Path, [string]$Anchor)
    $FullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $FullAnchor = [IO.Path]::GetFullPath($Anchor).TrimEnd('\')
    if ($FullPath -ine $FullAnchor -and -not $FullPath.StartsWith($FullAnchor + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "trusted path escaped its integrity anchor: path=$FullPath anchor=$FullAnchor"
    }
    $Current = $FullPath
    while ($true) {
        if ((Get-Item -LiteralPath $Current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "trusted path chain contains a reparse point: $Current"
        }
        Assert-NoBroadMutationAcl $Current
        if ($Current -ieq $FullAnchor) { break }
        $Current = Split-Path -Parent $Current
    }
    $Ancestor = Split-Path -Parent $FullAnchor
    while ($Ancestor) {
        if ((Get-Item -LiteralPath $Ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "trusted ancestor chain contains a reparse point: $Ancestor"
        }
        Assert-NoBroadAncestorReplacementAcl $Ancestor
        $Next = Split-Path -Parent $Ancestor
        if (-not $Next -or $Next -ieq $Ancestor) { break }
        $Ancestor = $Next
    }
}

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'forced-command provisioning requires Administrator Windows PowerShell'
}
if (-not [Environment]::Is64BitProcess -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
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
foreach ($Path in @($Worker,$Wrapper,$Config,$PublicKey,$NodeRuntime,$SshConfig,$Sshd,$PowerShell,$SharedToolkitRoot,$BackupRoot,$ProtectedParent,$SshDirectory)) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "required path is absent: $Path" }
}
Assert-Hash $Worker $ExpectedWorkerHash
Assert-Hash $Wrapper $ExpectedWrapperHash
Assert-Hash $Config $ExpectedConfigHash
Assert-Hash $PublicKey $ExpectedPublicKeyHash
Assert-Hash $NodeRuntime $ExpectedNodeHash
if ((Get-Item -LiteralPath $NodeRuntime).Length -ne 91694408) { throw 'staged Node runtime length mismatch' }
$NodeFileVersion = (Get-Item -LiteralPath $NodeRuntime).VersionInfo.FileVersion
if ($NodeFileVersion -ne $ExpectedNodeFileVersion) {
    throw "staged Node file version mismatch: expected=$ExpectedNodeFileVersion actual=$NodeFileVersion"
}
$NodeSignature = Get-AuthenticodeSignature -LiteralPath $NodeRuntime
$ActualNodeSignerThumbprint = if ($NodeSignature.SignerCertificate) { $NodeSignature.SignerCertificate.Thumbprint } else { $null }
if ($NodeSignature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
    $ActualNodeSignerThumbprint -ine $ExpectedNodeSignerThumbprint) {
    throw "staged Node Authenticode provenance mismatch: status=$($NodeSignature.Status) signer=$ActualNodeSignerThumbprint"
}
Assert-ProtectedPathIntegrity $ProtectedParent $ProtectedParent
Assert-WritableStateRootIntegrity $BackupRoot
Assert-ProtectedPathIntegrity $SshConfig $SshDirectory
Assert-ProtectedPathIntegrity $Sshd 'C:\Windows'
Assert-ProtectedPathIntegrity $PowerShell 'C:\Windows'
$SavedErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $SshVersionOutput = @(& $Sshd '-V' 2>&1)
    $SshVersionExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $SavedErrorActionPreference
}
if ($SshVersionExit -ne 0) { throw "sshd -V failed with exit code $SshVersionExit" }
$SshVersion = ($SshVersionOutput | ForEach-Object { [string]$_ } | Out-String).Trim()
if ($SshVersion -notmatch '(?i)OpenSSH_for_Windows_9\.5p2\b') { throw "expected OpenSSH_for_Windows_9.5p2: $SshVersion" }
if ((Test-Path -LiteralPath $ProtectedRoot) -and -not (Test-Path -LiteralPath $ProtectedRoot -PathType Container)) {
    throw 'protected deployment root exists but is not a directory'
}
if (Test-Path -LiteralPath $ProtectedRoot -PathType Container) {
    foreach ($ExpectedDirectory in @($ProtectedRoot,$BridgeDirectory,$RuntimeDirectory,$KeyDirectory)) {
        if ((Test-Path -LiteralPath $ExpectedDirectory) -and -not (Test-Path -LiteralPath $ExpectedDirectory -PathType Container)) {
            throw "protected directory slot has the wrong object type: $ExpectedDirectory"
        }
    }
    foreach ($ExpectedFile in @($WorkerDestination,$WrapperDestination,$ConfigDestination,$NodeDestination,$AuthorizedKeys)) {
        if ((Test-Path -LiteralPath $ExpectedFile) -and -not (Test-Path -LiteralPath $ExpectedFile -PathType Leaf)) {
            throw "protected file slot has the wrong object type: $ExpectedFile"
        }
    }
    if ((Get-Item -LiteralPath $ProtectedRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'protected deployment root is a reparse point'
    }
    $AllowedProtectedPaths = @(
        $ProtectedRoot,$BridgeDirectory,$WorkerDestination,$WrapperDestination,$ConfigDestination,
        $RuntimeDirectory,$NodeDestination,$KeyDirectory,$AuthorizedKeys
    ) | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') }
    $UnexpectedProtectedEntries = @(
        Get-ChildItem -LiteralPath $ProtectedRoot -Recurse -Force |
        Where-Object { ([IO.Path]::GetFullPath($_.FullName).TrimEnd('\')) -notin $AllowedProtectedPaths }
    )
    if ($UnexpectedProtectedEntries.Count -ne 0) { throw 'protected deployment root contains unmanaged entries' }
    if (@(Get-ChildItem -LiteralPath $ProtectedRoot -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -ne 0) {
        throw 'protected deployment root contains a reparse point'
    }
    foreach ($ExistingProtectedPath in $AllowedProtectedPaths) {
        if (Test-Path -LiteralPath $ExistingProtectedPath) {
            Assert-ProtectedPathIntegrity $ExistingProtectedPath $ProtectedRoot
        }
    }
    if (Test-Path -LiteralPath $NodeDestination -PathType Leaf) { Assert-Hash $NodeDestination $ExpectedNodeHash }
}
$CandidateStateBefore = Get-CandidateState
$PublicKeyBytes = [IO.File]::ReadAllBytes($PublicKey)
$PublicKeyDigest = [Security.Cryptography.SHA256]::Create()
try {
    $PublicKeyBytesHash = ([BitConverter]::ToString($PublicKeyDigest.ComputeHash($PublicKeyBytes))).Replace('-', '').ToLowerInvariant()
} finally {
    $PublicKeyDigest.Dispose()
}
if ($PublicKeyBytesHash -ne $ExpectedPublicKeyHash) { throw "deployment public-key bytes changed after preflight: $PublicKeyBytesHash" }
try { $PublicKeyText = [Text.UTF8Encoding]::new($false, $true).GetString($PublicKeyBytes) } catch { throw 'deployment public key is not valid UTF-8' }
$KeyLines = @($PublicKeyText -split '\r?\n' | Where-Object { $_.Trim() })
if ($KeyLines.Count -ne 1) { throw 'deployment public key must contain exactly one non-empty line' }
Assert-Ed25519PublicKeyLine $KeyLines[0]
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
    '    AuthorizedKeysFile "C:/Program Files/SkyrimDeployBridge/openssh/authorized_keys"',
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
$GlobalPermitUserEnvironment = @()
foreach ($ConfigLine in ($BaseConfigText -split '\r?\n')) {
    $ActiveLine = ($ConfigLine -replace '\s+#.*$', '').Trim()
    if (-not $ActiveLine -or $ActiveLine.StartsWith('#')) { continue }
    if ($ActiveLine -match '(?i)^Match(?:\s|$)') { break }
    if ($ActiveLine -match '(?i)^Include(?:\s|$)') {
        throw 'global sshd Include prevents static PermitUserEnvironment policy inspection'
    }
    if ($ActiveLine -match '(?i)^PermitUserEnvironment\s+(\S+)\s*$') {
        $GlobalPermitUserEnvironment += $Matches[1].ToLowerInvariant()
    }
}
if ($GlobalPermitUserEnvironment -contains 'yes') {
    throw 'active global PermitUserEnvironment yes is incompatible with the SkyrimDeploy boundary'
}
if (@($GlobalPermitUserEnvironment | Where-Object { $_ -ne 'no' }).Count -ne 0) {
    throw 'active global PermitUserEnvironment has an unsupported value'
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
if ($LASTEXITCODE -ne 0) {
    try { Remove-Item -LiteralPath $Candidate -Force -ErrorAction Stop } catch {
        throw "candidate sshd_config failed syntax validation and cleanup failed: $($_.Exception.Message)"
    }
    throw 'candidate sshd_config failed syntax validation; candidate was removed'
}
Write-Host 'Candidate syntax, byte preservation, and exact managed-block validation passed; live SSH smoke remains required.'

Write-Host '=== Snapshot rollback state ==='
$RuntimeBackup = Join-Path $BackupRoot "provisioning-$Stamp"
New-Item -ItemType Directory -Path $RuntimeBackup -Force | Out-Null
$ManagedPaths = @($WorkerDestination,$WrapperDestination,$ConfigDestination,$AuthorizedKeys,$NodeDestination)
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
$ManagedDirectories = @($ProtectedRoot,$BridgeDirectory,$RuntimeDirectory,$KeyDirectory)
$DirectoryState = @()
foreach ($ManagedDirectory in $ManagedDirectories) {
    $Exists = Test-Path -LiteralPath $ManagedDirectory -PathType Container
    $DirectoryState += [pscustomobject]@{
        Path = $ManagedDirectory
        Existed = $Exists
        Sddl = if ($Exists) { (Get-Acl -LiteralPath $ManagedDirectory).Sddl } else { $null }
    }
}
Copy-Item -LiteralPath $SshConfig -Destination $ConfigBackup
$OriginalHash = (Get-FileHash -LiteralPath $ConfigBackup -Algorithm SHA256).Hash
$OriginalConfigSddl = (Get-Acl -LiteralPath $SshConfig).Sddl
$RestrictedKey = "restrict,command=`"$ForceCommand`" $($KeyLines[0])"
if ($RestrictedKey -match '(?i)(?:^|,)environment=') { throw 'dedicated authorized key must not contain an environment option' }
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
$ExpectedManagedHashes[$NodeDestination] = $ExpectedNodeHash
$InstalledConfigHash = $null

Write-Host '=== Install protected runtime, key, and validated sshd config ==='
try {
    New-Item -ItemType Directory -Path $ProtectedRoot -Force | Out-Null
    Set-ProtectedDirectoryAcl $ProtectedRoot
    New-Item -ItemType Directory -Path $BridgeDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $RuntimeDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $KeyDirectory -Force | Out-Null
    Set-ProtectedDirectoryAcl $BridgeDirectory
    Set-ProtectedDirectoryAcl $RuntimeDirectory
    Set-KeyDirectoryAcl $KeyDirectory

    Copy-Item -LiteralPath $NodeRuntime -Destination $NodeDestination -Force
    Copy-Item -LiteralPath $Worker -Destination $WorkerDestination -Force
    Copy-Item -LiteralPath $Wrapper -Destination $WrapperDestination -Force
    Copy-Item -LiteralPath $Config -Destination $ConfigDestination -Force
    Set-ProtectedFileAcl $NodeDestination ([System.Security.AccessControl.FileSystemRights]::ReadAndExecute)
    Assert-Hash $NodeDestination $ExpectedNodeHash
    $NodeHash = $ExpectedNodeHash
    [IO.File]::WriteAllText($AuthorizedKeys, $RestrictedKey + "`n", [Text.UTF8Encoding]::new($false))
    Set-ProtectedFileAcl $WorkerDestination ([System.Security.AccessControl.FileSystemRights]::Read)
    Set-ProtectedFileAcl $WrapperDestination ([System.Security.AccessControl.FileSystemRights]::ReadAndExecute)
    Set-ProtectedFileAcl $ConfigDestination ([System.Security.AccessControl.FileSystemRights]::Read)
    Set-KeyFileAcl $AuthorizedKeys
    Assert-Hash $WorkerDestination $ExpectedWorkerHash
    Assert-Hash $WrapperDestination $ExpectedWrapperHash
    Assert-Hash $ConfigDestination $ExpectedConfigHash
    foreach ($TrustedPath in @(
        $ProtectedRoot,$BridgeDirectory,$WorkerDestination,$WrapperDestination,$ConfigDestination,
        $RuntimeDirectory,$NodeDestination,$KeyDirectory,$AuthorizedKeys
    )) {
        Assert-ProtectedPathIntegrity $TrustedPath $ProtectedRoot
    }
    Assert-ProtectedPathIntegrity $SshConfig $SshDirectory
    Assert-ProtectedPathIntegrity $Sshd 'C:\Windows'
    Assert-ProtectedPathIntegrity $PowerShell 'C:\Windows'
    $NodeVersion = (& $NodeDestination '--version' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $NodeVersion -cne $ExpectedNodeVersion) {
        throw "protected Node runtime version mismatch: expected=$ExpectedNodeVersion actual=$NodeVersion"
    }
    & $NodeDestination '--check' $WorkerDestination
    if ($LASTEXITCODE -ne 0) { throw 'protected Node runtime JavaScript syntax check failed' }
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
                if (-not (Test-Path -LiteralPath $State.Path -PathType Leaf)) {
                    throw "managed file was removed outside this provisioning transaction: $($State.Path)"
                }
                Copy-Item -LiteralPath $State.Backup -Destination $State.Path -Force
                $Acl = Get-Acl -LiteralPath $State.Path
                $Acl.SetSecurityDescriptorSddlForm($State.Sddl)
                Set-Acl -LiteralPath $State.Path -AclObject $Acl
            } elseif (Test-Path -LiteralPath $State.Path) {
                Remove-Item -LiteralPath $State.Path -Force -ErrorAction Stop
            }
        } catch { $RollbackErrors += "restore $($State.Path): $($_.Exception.Message)" }
    }
    for ($Index = $DirectoryState.Count - 1; $Index -ge 0; $Index--) {
        $State = $DirectoryState[$Index]
        try {
            if ($State.Existed) {
                $Acl = Get-Acl -LiteralPath $State.Path
                $Acl.SetSecurityDescriptorSddlForm($State.Sddl)
                Set-Acl -LiteralPath $State.Path -AclObject $Acl
            } elseif (Test-Path -LiteralPath $State.Path -PathType Container) {
                Remove-Item -LiteralPath $State.Path -Force -ErrorAction Stop
            }
        } catch { $RollbackErrors += "restore directory $($State.Path): $($_.Exception.Message)" }
    }
    foreach ($State in $ManagedState) {
        try {
            if ($State.Existed) {
                if (-not (Test-Path -LiteralPath $State.Path -PathType Leaf)) { throw 'restored file is absent or has the wrong type' }
                $RestoredHash = (Get-FileHash -LiteralPath $State.Path -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($RestoredHash -ne $State.PriorHash) { throw "restored file hash mismatch: $RestoredHash" }
                if ((Get-Acl -LiteralPath $State.Path).Sddl -cne $State.Sddl) { throw 'restored file ACL mismatch' }
            } elseif (Test-Path -LiteralPath $State.Path) {
                throw 'new managed file remains after rollback'
            }
        } catch { $RollbackErrors += "verify restored $($State.Path): $($_.Exception.Message)" }
    }
    foreach ($State in $DirectoryState) {
        try {
            if ($State.Existed) {
                if (-not (Test-Path -LiteralPath $State.Path -PathType Container)) { throw 'restored directory is absent or has the wrong type' }
                if ((Get-Acl -LiteralPath $State.Path).Sddl -cne $State.Sddl) { throw 'restored directory ACL mismatch' }
            } elseif (Test-Path -LiteralPath $State.Path) {
                throw 'new managed directory remains after rollback'
            }
        } catch { $RollbackErrors += "verify restored directory $($State.Path): $($_.Exception.Message)" }
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
    try {
        if (Test-Path -LiteralPath $Candidate) { Remove-Item -LiteralPath $Candidate -Force -ErrorAction Stop }
    } catch {
        Write-Warning "candidate cleanup failed and requires Administrator removal: $Candidate error=$($_.Exception.Message)"
    }
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
