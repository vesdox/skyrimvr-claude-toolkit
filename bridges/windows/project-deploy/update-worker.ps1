#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$WorkerSource = Join-Path $PSScriptRoot 'bridge.js'
$WrapperSource = Join-Path $PSScriptRoot 'invoke-ssh.ps1'
$WorkerDestination = 'C:\Program Files\SkyrimDeployBridge\bridge\bridge.js'
$WrapperDestination = 'C:\Program Files\SkyrimDeployBridge\invoke-ssh.ps1'
$Node = 'C:\Program Files\SkyrimDeployBridge\runtime\node.exe'
$BackupRoot = 'C:\ProgramData\SkyrimToolBridge\project-deploy\backups'
$ApplyLock = Join-Path $BackupRoot 'project-deploy.apply.lock'

$OldWorkerHash = '54c66da67ca4d2e1276a3f420ac3f6226e6a4572cca1e56553fe9168bc07d1a8'
$OldWrapperHash = '8f2485244d2bf3270bb01fe56e9490c1be6d7cdd2e8e1fb2a8931618f08cf30b'
$NewWorkerHash = '63f7e7ee30ef0c07fc7cd495d68ad5ea185d4a0b42a80141140368ca2f8e77ae'
$NewWrapperHash = 'da34282e5ce0eaff5f0c51973bc80145a1700ed2c2e8bd5a0d5ee8d7f209f907'
$NodeHash = '3331e1ffe19874215472217c5e94f5a0c6d8e18c4ac7111d3937aa0ad5e9b4a5'

function Get-Sha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "required file is absent: $Path" }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-Hash([string]$Path, [string]$Expected) {
    $Actual = Get-Sha256 $Path
    if ($Actual -cne $Expected) { throw "SHA256 mismatch: path=$Path expected=$Expected actual=$Actual" }
}

Assert-Hash $WorkerSource $NewWorkerHash
Assert-Hash $WrapperSource $NewWrapperHash
Assert-Hash $Node $NodeHash
& $Node '--check' $WorkerSource
if ($LASTEXITCODE -ne 0) { throw 'staged worker failed protected Node syntax validation' }
[void][ScriptBlock]::Create((Get-Content -LiteralPath $WrapperSource -Raw -Encoding UTF8))

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
            operation = 'project-deploy-smoke-correction-maintenance'
        } | ConvertTo-Json -Compress))
        $LockHandle.Write($LockBody, 0, $LockBody.Length)
        $LockHandle.Flush($true)
    } catch {
        throw "could not atomically acquire deployment serialization lock ${ApplyLock}: $($_.Exception.Message)"
    }

    $WorkerCurrent = Get-Sha256 $WorkerDestination
    $WrapperCurrent = Get-Sha256 $WrapperDestination
    if ($WorkerCurrent -ceq $NewWorkerHash -and $WrapperCurrent -ceq $NewWrapperHash) {
        Write-Host 'Project-deploy smoke worker correction is already installed with exact hashes.'
        return
    }
    if ($WorkerCurrent -cne $OldWorkerHash -or $WrapperCurrent -cne $OldWrapperHash) {
        throw "installed worker/wrapper are not the exact accepted pre-update pair: worker=$WorkerCurrent wrapper=$WrapperCurrent"
    }

    $WorkerAcl = (Get-Acl -LiteralPath $WorkerDestination).Sddl
    $WrapperAcl = (Get-Acl -LiteralPath $WrapperDestination).Sddl
    $Stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $BackupDirectory = Join-Path $BackupRoot "maintenance-$Stamp"
    New-Item -ItemType Directory -Path $BackupDirectory -ErrorAction Stop | Out-Null
    $WorkerBackup = Join-Path $BackupDirectory 'bridge.js.pre-smoke-correction.bak'
    $WrapperBackup = Join-Path $BackupDirectory 'invoke-ssh.ps1.pre-smoke-correction.bak'
    Copy-Item -LiteralPath $WorkerDestination -Destination $WorkerBackup -ErrorAction Stop
    Copy-Item -LiteralPath $WrapperDestination -Destination $WrapperBackup -ErrorAction Stop
    Assert-Hash $WorkerBackup $OldWorkerHash
    Assert-Hash $WrapperBackup $OldWrapperHash

    try {
        [IO.File]::WriteAllBytes($WorkerDestination, [IO.File]::ReadAllBytes($WorkerSource))
        [IO.File]::WriteAllBytes($WrapperDestination, [IO.File]::ReadAllBytes($WrapperSource))
        Assert-Hash $WorkerDestination $NewWorkerHash
        Assert-Hash $WrapperDestination $NewWrapperHash
        if ((Get-Acl -LiteralPath $WorkerDestination).Sddl -cne $WorkerAcl) {
            throw 'worker ACL changed during bounded in-place update'
        }
        if ((Get-Acl -LiteralPath $WrapperDestination).Sddl -cne $WrapperAcl) {
            throw 'wrapper ACL changed during bounded in-place update'
        }
        & $Node '--check' $WorkerDestination
        if ($LASTEXITCODE -ne 0) { throw 'installed worker failed protected Node syntax validation' }
        [void][ScriptBlock]::Create((Get-Content -LiteralPath $WrapperDestination -Raw -Encoding UTF8))

        $Evidence = [ordered]@{
            timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
            operation = 'project-deploy-smoke-correction-maintenance'
            worker_before_sha256 = $OldWorkerHash
            worker_after_sha256 = $NewWorkerHash
            wrapper_before_sha256 = $OldWrapperHash
            wrapper_after_sha256 = $NewWrapperHash
            worker_backup = $WorkerBackup
            wrapper_backup = $WrapperBackup
            acl_sddl_unchanged = $true
            sshd_restarted = $false
            sshd_config_changed = $false
        }
        $EvidencePath = Join-Path $BackupDirectory 'result.json'
        $Evidence | ConvertTo-Json | Set-Content -LiteralPath $EvidencePath -Encoding UTF8
    } catch {
        $Failure = [string]$_.Exception.Message
        $RollbackErrors = [Collections.Generic.List[string]]::new()
        try {
            [IO.File]::WriteAllBytes($WorkerDestination, [IO.File]::ReadAllBytes($WorkerBackup))
            Assert-Hash $WorkerDestination $OldWorkerHash
            if ((Get-Acl -LiteralPath $WorkerDestination).Sddl -cne $WorkerAcl) {
                throw 'worker ACL differs after rollback'
            }
        } catch {
            $RollbackErrors.Add("worker rollback: $($_.Exception.Message)")
        }
        try {
            [IO.File]::WriteAllBytes($WrapperDestination, [IO.File]::ReadAllBytes($WrapperBackup))
            Assert-Hash $WrapperDestination $OldWrapperHash
            if ((Get-Acl -LiteralPath $WrapperDestination).Sddl -cne $WrapperAcl) {
                throw 'wrapper ACL differs after rollback'
            }
        } catch {
            $RollbackErrors.Add("wrapper rollback: $($_.Exception.Message)")
        }
        if ($RollbackErrors.Count -gt 0) {
            throw "bounded update failed and rollback was incomplete: original=$Failure; rollback=$($RollbackErrors -join '; ')"
        }
        throw "bounded update failed; exact old worker/wrapper bytes and ACLs restored: $Failure"
    }

    Write-Host '=== Bounded project-deploy smoke correction installed ==='
    Write-Host "Worker SHA256: $NewWorkerHash"
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
