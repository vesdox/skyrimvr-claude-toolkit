#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$WorkerSource = Join-Path $PSScriptRoot 'bridge.js'
$WrapperSource = Join-Path $PSScriptRoot 'invoke-ssh.ps1'
$WorkerDestination = 'C:\Program Files\SkyrimDeployBridge\bridge\bridge.js'
$WrapperDestination = 'C:\Program Files\SkyrimDeployBridge\invoke-ssh.ps1'
$Config = 'C:\Program Files\SkyrimDeployBridge\config.json'
$Node = 'C:\Program Files\SkyrimDeployBridge\runtime\node.exe'
$BackupRoot = 'C:\ProgramData\SkyrimToolBridge\project-deploy\backups'
$ApplyLock = Join-Path $BackupRoot 'project-deploy.apply.lock'

$OldWorkerHash = '63f7e7ee30ef0c07fc7cd495d68ad5ea185d4a0b42a80141140368ca2f8e77ae'
$OldWrapperHash = '909b7dc6ab86b2f719cbb9cd626e4089b56ee5f79d36e400a948418a892cb3ab'
$NewWorkerHash = '11e00d9f224e94a4d290178a97a68862c20f7a15e6c25b7c0363f1b1a0e2e6a3'
$NewWrapperHash = '09657a4fe4ba0e63f8ba6453bd1828a73bd73e612b9f5dc2fe430e890893db80'
$ConfigHash = '4ecdc351f552c5128deb5f5c9e2190f8d6fe7375126e2a1d6c03452f52b63617'
$NodeHash = '3331e1ffe19874215472217c5e94f5a0c6d8e18c4ac7111d3937aa0ad5e9b4a5'
$NodeVersion = 'v24.15.0'

function Get-Sha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "required file is absent: $Path" }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-BytesSha256([byte[]]$Bytes) {
    $Hasher = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($Hasher.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $Hasher.Dispose()
    }
}

function Assert-Hash([string]$Path, [string]$Expected) {
    $Actual = Get-Sha256 $Path
    if ($Actual -cne $Expected) { throw "SHA256 mismatch: path=$Path expected=$Expected actual=$Actual" }
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
        $CurrentBytes = New-Object byte[] $Stream.Length
        $Offset = 0
        while ($Offset -lt $CurrentBytes.Length) {
            $Read = $Stream.Read($CurrentBytes, $Offset, $CurrentBytes.Length - $Offset)
            if ($Read -eq 0) { throw "unexpected EOF while validating $Path" }
            $Offset += $Read
        }
        $CurrentHash = Get-BytesSha256 $CurrentBytes
        if ($CurrentHash -cne $ExpectedCurrentHash) {
            throw "write-time CAS refused: path=$Path expected=$ExpectedCurrentHash actual=$CurrentHash"
        }
        if ((Get-BytesSha256 $NewBytes) -cne $ExpectedNewHash) {
            throw "staged bytes changed before write: $Path"
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

function Restore-ExactBytesCas(
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

foreach ($Name in @('SkyrimSE', 'skse64_loader', 'ModOrganizer')) {
    if (Get-Process $Name -ErrorAction SilentlyContinue) {
        throw "bounded worker maintenance is refused while $Name is running"
    }
}
Assert-Hash $WorkerSource $NewWorkerHash
Assert-Hash $WrapperSource $NewWrapperHash
Assert-Hash $Config $ConfigHash
Assert-Hash $Node $NodeHash
& $Node '--check' $WorkerSource
if ($LASTEXITCODE -ne 0) { throw 'staged worker failed protected Node syntax validation' }
[void][ScriptBlock]::Create((Get-Content -LiteralPath $WrapperSource -Raw -Encoding UTF8))
$ActualNodeVersion = (& $Node '--version' 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $ActualNodeVersion -cne $NodeVersion) {
    throw "protected Node runtime version mismatch: expected=$NodeVersion actual=$ActualNodeVersion"
}

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
            operation = 'project-deploy-parent-directory-capability-maintenance'
        } | ConvertTo-Json -Compress))
        $LockHandle.Write($LockBody, 0, $LockBody.Length)
        $LockHandle.Flush($true)
    } catch {
        throw "could not atomically acquire deployment serialization lock ${ApplyLock}: $($_.Exception.Message)"
    }

    $WorkerCurrent = Get-Sha256 $WorkerDestination
    $WrapperCurrent = Get-Sha256 $WrapperDestination
    Assert-Hash $Config $ConfigHash
    Assert-Hash $Node $NodeHash
    if ($WorkerCurrent -ceq $NewWorkerHash -and $WrapperCurrent -ceq $NewWrapperHash) {
        Write-Host 'Project-deploy registered-parent capability is already installed with exact hashes.'
        return
    }
    if ($WorkerCurrent -cne $OldWorkerHash -or $WrapperCurrent -cne $OldWrapperHash) {
        throw "installed worker/wrapper are not the exact accepted pre-update pair: worker=$WorkerCurrent wrapper=$WrapperCurrent"
    }

    $WorkerAcl = (Get-Acl -LiteralPath $WorkerDestination).Sddl
    $WrapperAcl = (Get-Acl -LiteralPath $WrapperDestination).Sddl
    $ConfigAcl = (Get-Acl -LiteralPath $Config).Sddl
    $NodeAcl = (Get-Acl -LiteralPath $Node).Sddl
    $WorkerOldBytes = [IO.File]::ReadAllBytes($WorkerDestination)
    $WrapperOldBytes = [IO.File]::ReadAllBytes($WrapperDestination)
    $WorkerNewBytes = [IO.File]::ReadAllBytes($WorkerSource)
    $WrapperNewBytes = [IO.File]::ReadAllBytes($WrapperSource)
    if ((Get-BytesSha256 $WorkerOldBytes) -cne $OldWorkerHash -or
        (Get-BytesSha256 $WrapperOldBytes) -cne $OldWrapperHash) {
        throw 'protected worker/wrapper changed while capturing exact backup bytes'
    }

    $Stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $BackupDirectory = Join-Path $BackupRoot "maintenance-parent-capability-$Stamp"
    New-Item -ItemType Directory -Path $BackupDirectory -ErrorAction Stop | Out-Null
    $WorkerBackup = Join-Path $BackupDirectory 'bridge.js.pre-parent-capability.bak'
    $WrapperBackup = Join-Path $BackupDirectory 'invoke-ssh.ps1.pre-parent-capability.bak'
    [IO.File]::WriteAllBytes($WorkerBackup, $WorkerOldBytes)
    [IO.File]::WriteAllBytes($WrapperBackup, $WrapperOldBytes)
    Assert-Hash $WorkerBackup $OldWorkerHash
    Assert-Hash $WrapperBackup $OldWrapperHash
    $TransactionStart = [ordered]@{
        timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
        operation = 'project-deploy-parent-directory-capability-maintenance'
        worker_before_sha256 = $OldWorkerHash
        wrapper_before_sha256 = $OldWrapperHash
        worker_candidate_sha256 = $NewWorkerHash
        wrapper_candidate_sha256 = $NewWrapperHash
        config_sha256 = $ConfigHash
        node_sha256 = $NodeHash
        worker_backup = $WorkerBackup
        wrapper_backup = $WrapperBackup
    }
    $TransactionStart | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $BackupDirectory 'transaction-start.json') -Encoding UTF8

    try {
        Set-ExactBytesCas $WorkerDestination $OldWorkerHash $WorkerNewBytes $NewWorkerHash
        Set-ExactBytesCas $WrapperDestination $OldWrapperHash $WrapperNewBytes $NewWrapperHash
        Assert-Hash $Config $ConfigHash
        Assert-Hash $Node $NodeHash
        if ((Get-Acl -LiteralPath $WorkerDestination).Sddl -cne $WorkerAcl) { throw 'worker ACL changed during bounded in-place update' }
        if ((Get-Acl -LiteralPath $WrapperDestination).Sddl -cne $WrapperAcl) { throw 'wrapper ACL changed during bounded in-place update' }
        if ((Get-Acl -LiteralPath $Config).Sddl -cne $ConfigAcl) { throw 'config ACL changed during bounded worker update' }
        if ((Get-Acl -LiteralPath $Node).Sddl -cne $NodeAcl) { throw 'Node ACL changed during bounded worker update' }
        & $Node '--check' $WorkerDestination
        if ($LASTEXITCODE -ne 0) { throw 'installed worker failed protected Node syntax validation' }
        [void][ScriptBlock]::Create((Get-Content -LiteralPath $WrapperDestination -Raw -Encoding UTF8))
        $InstalledNodeVersion = (& $Node '--version' 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $InstalledNodeVersion -cne $NodeVersion) {
            throw "installed Node runtime version mismatch: expected=$NodeVersion actual=$InstalledNodeVersion"
        }

        $Evidence = [ordered]@{
            timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
            operation = 'project-deploy-parent-directory-capability-maintenance'
            worker_before_sha256 = $OldWorkerHash
            worker_after_sha256 = $NewWorkerHash
            wrapper_before_sha256 = $OldWrapperHash
            wrapper_after_sha256 = $NewWrapperHash
            config_before_sha256 = $ConfigHash
            config_after_sha256 = (Get-Sha256 $Config)
            node_before_sha256 = $NodeHash
            node_after_sha256 = (Get-Sha256 $Node)
            node_version = $InstalledNodeVersion
            worker_backup = $WorkerBackup
            wrapper_backup = $WrapperBackup
            acl_sddl_unchanged = $true
            sshd_restarted = $false
            sshd_config_changed = $false
            keys_or_identity_changed = $false
            deployment_targets_changed = $false
            mod_content_touched = $false
        }
        $EvidencePath = Join-Path $BackupDirectory 'result.json'
        $Evidence | ConvertTo-Json | Set-Content -LiteralPath $EvidencePath -Encoding UTF8
    } catch {
        $Failure = [string]$_.Exception.Message
        $RollbackErrors = [Collections.Generic.List[string]]::new()
        try {
            Restore-ExactBytesCas $WorkerDestination $OldWorkerHash $WorkerOldBytes $NewWorkerHash
            if ((Get-Acl -LiteralPath $WorkerDestination).Sddl -cne $WorkerAcl) { throw 'worker ACL differs after rollback' }
        } catch { $RollbackErrors.Add("worker rollback: $($_.Exception.Message)") }
        try {
            Restore-ExactBytesCas $WrapperDestination $OldWrapperHash $WrapperOldBytes $NewWrapperHash
            if ((Get-Acl -LiteralPath $WrapperDestination).Sddl -cne $WrapperAcl) { throw 'wrapper ACL differs after rollback' }
        } catch { $RollbackErrors.Add("wrapper rollback: $($_.Exception.Message)") }
        try { Assert-Hash $Config $ConfigHash } catch { $RollbackErrors.Add("config integrity: $($_.Exception.Message)") }
        try { Assert-Hash $Node $NodeHash } catch { $RollbackErrors.Add("Node integrity: $($_.Exception.Message)") }
        $FailureEvidence = [ordered]@{
            timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
            operation = 'project-deploy-parent-directory-capability-maintenance'
            failure = $Failure
            rollback_ok = ($RollbackErrors.Count -eq 0)
            rollback_errors = @($RollbackErrors)
        }
        $FailureEvidence | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $BackupDirectory 'failure.json') -Encoding UTF8
        if ($RollbackErrors.Count -gt 0) {
            throw "bounded update failed and rollback was incomplete: original=$Failure; rollback=$($RollbackErrors -join '; ')"
        }
        throw "bounded update failed; exact old worker/wrapper bytes and ACLs restored: $Failure"
    }

    Write-Host '=== Bounded registered-parent project-deploy capability installed ==='
    Write-Host "Worker SHA256: $NewWorkerHash"
    Write-Host "Wrapper SHA256: $NewWrapperHash"
    Write-Host "Config SHA256: $(Get-Sha256 $Config)"
    Write-Host "Backup/evidence: $BackupDirectory"
    Write-Host 'sshd was not restarted; sshd_config, keys, identities, ACLs, config, targets, and mod content were not changed.'
} finally {
    if ($null -ne $LockHandle) {
        $LockHandle.Dispose()
        $ReleasePath = "${ApplyLock}.release-$([Guid]::NewGuid())"
        Move-Item -LiteralPath $ApplyLock -Destination $ReleasePath -ErrorAction Stop
        Remove-Item -LiteralPath $ReleasePath -Force -ErrorAction Stop
    }
}
