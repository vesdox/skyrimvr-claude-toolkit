#Requires -RunAsAdministrator
param(
    [string]$Config = (Join-Path $PSScriptRoot 'config.json'),
    [string]$Wrapper = (Join-Path $PSScriptRoot 'invoke-ssh.ps1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ConfigDestination = 'C:\Program Files\SkyrimDeployBridge\config.json'
$WrapperDestination = 'C:\Program Files\SkyrimDeployBridge\invoke-ssh.ps1'
$WorkerDestination = 'C:\Program Files\SkyrimDeployBridge\bridge\bridge.js'
$Node = 'C:\Program Files\SkyrimDeployBridge\runtime\node.exe'
$BackupRoot = 'C:\ProgramData\SkyrimToolBridge\project-deploy\backups'
$ApplyLock = Join-Path $BackupRoot 'project-deploy.apply.lock'

$OldConfigHash = 'c1f14081c70aa8d7292f0a68b141d32fa6bb7b09c589a073ac406f49dedd1a61'
$OldWrapperHash = 'b0d4b3f6b16e7e1a82006b685f0053736e7b77f569b31d8891b9ef602ed329d4'
$NewConfigHash = '24305a2b886b51e98ced99f8f9e3409a5dcbd781aa34203f489119673fa09033'
$NewWrapperHash = '1e060e0ed4645bf9f14b8234822d967c4f56d45d1a2b6aa13bc7403522a17eb9'
$WorkerHash = '63f7e7ee30ef0c07fc7cd495d68ad5ea185d4a0b42a80141140368ca2f8e77ae'
$NodeHash = '3331e1ffe19874215472217c5e94f5a0c6d8e18c4ac7111d3937aa0ad5e9b4a5'

function Get-Sha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "required file is absent: $Path"
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-Hash([string]$Path, [string]$Expected) {
    $Actual = Get-Sha256 $Path
    if ($Actual -cne $Expected) {
        throw "SHA256 mismatch: path=$Path expected=$Expected actual=$Actual"
    }
}

function Get-BytesSha256([byte[]]$Bytes) {
    $Hasher = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($Hasher.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $Hasher.Dispose()
    }
}

function Assert-RegularNonReparseFile([string]$Path) {
    $Item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($Item.PSIsContainer -or ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "path is not a regular non-reparse file: $Path"
    }
}

function Assert-ProtectedAncestry([string]$Path) {
    $ProtectedRoot = [IO.Path]::GetFullPath('C:\Program Files\SkyrimDeployBridge').TrimEnd('\')
    $Current = (Get-Item -LiteralPath (Split-Path -Parent $Path) -Force -ErrorAction Stop)
    while ($true) {
        if (-not $Current.PSIsContainer -or ($Current.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "protected ancestry contains a non-directory or reparse point: $($Current.FullName)"
        }
        $Full = [IO.Path]::GetFullPath($Current.FullName).TrimEnd('\')
        if ($Full -ceq $ProtectedRoot) { break }
        if (-not $Full.StartsWith("$ProtectedRoot\", [StringComparison]::OrdinalIgnoreCase)) {
            throw "protected path escaped expected root: $Path"
        }
        $Current = Get-Item -LiteralPath $Current.Parent.FullName -Force -ErrorAction Stop
    }
}

function Set-ExactBytesCas(
    [string]$Path,
    [string]$ExpectedCurrentHash,
    [byte[]]$NewBytes,
    [string]$ExpectedNewHash
) {
    $Stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None
    )
    try {
        if ($Stream.Length -gt 1048576) { throw "protected maintenance file exceeds 1 MiB: $Path" }
        $CurrentBytes = [byte[]]::new([int]$Stream.Length)
        $Offset = 0
        while ($Offset -lt $CurrentBytes.Length) {
            $Read = $Stream.Read($CurrentBytes, $Offset, $CurrentBytes.Length - $Offset)
            if ($Read -le 0) { throw "short read while holding exclusive file handle: $Path" }
            $Offset += $Read
        }
        $CurrentHash = Get-BytesSha256 $CurrentBytes
        if ($CurrentHash -cne $ExpectedCurrentHash) {
            throw "write-time CAS refused: path=$Path expected=$ExpectedCurrentHash actual=$CurrentHash"
        }
        if ((Get-BytesSha256 $NewBytes) -cne $ExpectedNewHash) {
            throw "replacement bytes changed before write: $Path"
        }
        $Stream.Position = 0
        $Stream.SetLength(0)
        $Stream.Write($NewBytes, 0, $NewBytes.Length)
        $Stream.Flush($true)
    } finally {
        $Stream.Dispose()
    }
    Assert-Hash $Path $ExpectedNewHash
}

function Restore-ExactBytes(
    [string]$Path,
    [string]$OldHash,
    [byte[]]$OldBytes,
    [string]$NewHash
) {
    $CurrentHash = Get-Sha256 $Path
    if ($CurrentHash -ceq $OldHash) { return }
    if ($CurrentHash -cne $NewHash) {
        throw "rollback CAS refused unknown current state: path=$Path old=$OldHash new=$NewHash actual=$CurrentHash"
    }
    Set-ExactBytesCas $Path $NewHash $OldBytes $OldHash
}

foreach ($Path in @($Config,$Wrapper,$ConfigDestination,$WrapperDestination,$WorkerDestination,$Node)) {
    Assert-RegularNonReparseFile $Path
}
foreach ($Path in @($ConfigDestination,$WrapperDestination,$WorkerDestination,$Node)) {
    Assert-ProtectedAncestry $Path
}

Assert-Hash $Config $NewConfigHash
Assert-Hash $Wrapper $NewWrapperHash
Assert-Hash $WorkerDestination $WorkerHash
Assert-Hash $Node $NodeHash
[void](Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json)
[void][ScriptBlock]::Create((Get-Content -LiteralPath $Wrapper -Raw -Encoding UTF8))

$LockHandle = $null
try {
    try {
        $LockHandle = [IO.File]::Open(
            $ApplyLock,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
        $LockBody = [Text.Encoding]::UTF8.GetBytes((@{
            timestamp = (Get-Date).ToUniversalTime().ToString('o')
            pid = $PID
            operation = 'project-deploy-allowlist-maintenance'
        } | ConvertTo-Json -Compress))
        $LockHandle.Write($LockBody, 0, $LockBody.Length)
        $LockHandle.Flush($true)
    } catch {
        throw "could not atomically acquire deployment serialization lock ${ApplyLock}: $($_.Exception.Message)"
    }

    $ConfigCurrent = Get-Sha256 $ConfigDestination
    $WrapperCurrent = Get-Sha256 $WrapperDestination
    if ($ConfigCurrent -ceq $NewConfigHash -and $WrapperCurrent -ceq $NewWrapperHash) {
        Write-Host 'Project-deploy allowlist correction is already installed with exact hashes.'
        return
    }
    if ($ConfigCurrent -cne $OldConfigHash -or $WrapperCurrent -cne $OldWrapperHash) {
        throw "installed config/wrapper are not the exact accepted pre-update pair: config=$ConfigCurrent wrapper=$WrapperCurrent"
    }

    $ConfigAcl = (Get-Acl -LiteralPath $ConfigDestination).Sddl
    $WrapperAcl = (Get-Acl -LiteralPath $WrapperDestination).Sddl
    $Stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $BackupDirectory = Join-Path $BackupRoot "allowlist-maintenance-$Stamp"
    New-Item -ItemType Directory -Path $BackupDirectory -ErrorAction Stop | Out-Null
    $ConfigBackup = Join-Path $BackupDirectory 'config.json.pre-allowlist-update.bak'
    $WrapperBackup = Join-Path $BackupDirectory 'invoke-ssh.ps1.pre-allowlist-update.bak'
    Copy-Item -LiteralPath $ConfigDestination -Destination $ConfigBackup -ErrorAction Stop
    Copy-Item -LiteralPath $WrapperDestination -Destination $WrapperBackup -ErrorAction Stop
    Assert-Hash $ConfigBackup $OldConfigHash
    Assert-Hash $WrapperBackup $OldWrapperHash
    $ConfigOldBytes = [IO.File]::ReadAllBytes($ConfigBackup)
    $WrapperOldBytes = [IO.File]::ReadAllBytes($WrapperBackup)
    $ConfigNewBytes = [IO.File]::ReadAllBytes($Config)
    $WrapperNewBytes = [IO.File]::ReadAllBytes($Wrapper)

    $StartManifest = [ordered]@{
        timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
        operation = 'project-deploy-allowlist-maintenance-start'
        config_before_sha256 = $OldConfigHash
        config_after_sha256 = $NewConfigHash
        wrapper_before_sha256 = $OldWrapperHash
        wrapper_after_sha256 = $NewWrapperHash
        config_backup = $ConfigBackup
        wrapper_backup = $WrapperBackup
        config_acl_sddl = $ConfigAcl
        wrapper_acl_sddl = $WrapperAcl
    }
    $StartManifestBytes = [Text.Encoding]::UTF8.GetBytes(
        ($StartManifest | ConvertTo-Json -Compress))
    $StartManifestPath = Join-Path $BackupDirectory 'transaction-start.json'
    $StartManifestStream = [IO.File]::Open(
        $StartManifestPath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    try {
        $StartManifestStream.Write($StartManifestBytes, 0, $StartManifestBytes.Length)
        $StartManifestStream.Flush($true)
    } finally {
        $StartManifestStream.Dispose()
    }

    try {
        # Updating config first creates only a fail-closed interval: the old
        # wrapper refuses the new config until its exact paired bytes arrive.
        Set-ExactBytesCas $ConfigDestination $OldConfigHash $ConfigNewBytes $NewConfigHash
        Set-ExactBytesCas $WrapperDestination $OldWrapperHash $WrapperNewBytes $NewWrapperHash
        if ((Get-Acl -LiteralPath $ConfigDestination).Sddl -cne $ConfigAcl) {
            throw 'config ACL changed during bounded in-place update'
        }
        if ((Get-Acl -LiteralPath $WrapperDestination).Sddl -cne $WrapperAcl) {
            throw 'wrapper ACL changed during bounded in-place update'
        }
        [void](Get-Content -LiteralPath $ConfigDestination -Raw -Encoding UTF8 | ConvertFrom-Json)
        [void][ScriptBlock]::Create((Get-Content -LiteralPath $WrapperDestination -Raw -Encoding UTF8))

        $Evidence = [ordered]@{
            timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
            operation = 'project-deploy-allowlist-maintenance'
            config_before_sha256 = $OldConfigHash
            config_after_sha256 = $NewConfigHash
            wrapper_before_sha256 = $OldWrapperHash
            wrapper_after_sha256 = $NewWrapperHash
            config_backup = $ConfigBackup
            wrapper_backup = $WrapperBackup
            worker_sha256 = $WorkerHash
            node_sha256 = $NodeHash
            acl_sddl_unchanged = $true
            sshd_restarted = $false
            sshd_config_changed = $false
            deployment_targets_changed = $false
        }
        $EvidencePath = Join-Path $BackupDirectory 'result.json'
        $Evidence | ConvertTo-Json | Set-Content -LiteralPath $EvidencePath -Encoding UTF8
    } catch {
        $Failure = [string]$_.Exception.Message
        $RollbackErrors = [Collections.Generic.List[string]]::new()
        try {
            Restore-ExactBytes $ConfigDestination $OldConfigHash $ConfigOldBytes $NewConfigHash
            if ((Get-Acl -LiteralPath $ConfigDestination).Sddl -cne $ConfigAcl) {
                throw 'config ACL differs after rollback'
            }
        } catch {
            $RollbackErrors.Add("config rollback: $($_.Exception.Message)")
        }
        try {
            Restore-ExactBytes $WrapperDestination $OldWrapperHash $WrapperOldBytes $NewWrapperHash
            if ((Get-Acl -LiteralPath $WrapperDestination).Sddl -cne $WrapperAcl) {
                throw 'wrapper ACL differs after rollback'
            }
        } catch {
            $RollbackErrors.Add("wrapper rollback: $($_.Exception.Message)")
        }
        if ($RollbackErrors.Count -gt 0) {
            throw "bounded allowlist update failed and rollback was incomplete: original=$Failure; rollback=$($RollbackErrors -join '; ')"
        }
        throw "bounded allowlist update failed; exact old config/wrapper bytes and ACLs restored: $Failure"
    }

    Write-Host '=== Bounded project-deploy allowlist correction installed ==='
    Write-Host "Config SHA256: $NewConfigHash"
    Write-Host "Wrapper SHA256: $NewWrapperHash"
    Write-Host "Backup/evidence: $BackupDirectory"
    Write-Host 'sshd was not restarted; sshd_config, keys, identities, ACLs, and deployment targets were not changed.'
} finally {
    if ($null -ne $LockHandle) {
        $LockHandle.Dispose()
        $ReleasePath = "${ApplyLock}.release-$([Guid]::NewGuid())"
        Move-Item -LiteralPath $ApplyLock -Destination $ReleasePath -ErrorAction Stop
        Remove-Item -LiteralPath $ReleasePath -Force -ErrorAction Stop
    }
}
