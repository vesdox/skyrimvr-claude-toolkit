Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExpectedSid = 'S-1-5-21-3046562540-2879210194-691397096-1014'
$ExpectedCommand = 'project-deploy-v1'
$Node = 'C:\Program Files\SkyrimDeployBridge\runtime\node.exe'
$Worker = 'C:\Program Files\SkyrimDeployBridge\bridge\bridge.js'
$Config = 'C:\Program Files\SkyrimDeployBridge\config.json'
$ExpectedWorkerHash = '11e00d9f224e94a4d290178a97a68862c20f7a15e6c25b7c0363f1b1a0e2e6a3'
$ExpectedConfigHash = '1db4886207222b798b4958813fa6805697091c5a68f3c25bd7d08a27d83613ab'
$ExpectedNodeHash = '3331e1ffe19874215472217c5e94f5a0c6d8e18c4ac7111d3937aa0ad5e9b4a5'
$ExpectedNodeVersion = 'v24.15.0'

function Write-Failure {
    param([string]$Message)
    [Console]::Error.WriteLine("project-deploy forced command refused: $Message")
}

try {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($Identity.User.Value -ne $ExpectedSid) { throw 'forced command is not running as the pinned SkyrimDeploy SID' }
    if ($env:SSH_ORIGINAL_COMMAND -cne $ExpectedCommand) { throw 'unsupported SSH original command' }
    if (-not $env:SSH_CONNECTION) { throw 'forced command requires an SSH connection' }
    if ($env:SSH_TTY) { throw 'PTY execution is forbidden' }
    if (Get-Process SkyrimSE -ErrorAction SilentlyContinue) { throw 'deployment requests are refused while SkyrimSE is running' }
    foreach ($Path in @($Node, $Worker, $Config)) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "required protected runtime file is absent: $Path" }
    }
    $NodeHash = (Get-FileHash -LiteralPath $Node -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($NodeHash -ne $ExpectedNodeHash) { throw "protected Node runtime hash mismatch: $NodeHash" }
    $WorkerHash = (Get-FileHash -LiteralPath $Worker -Algorithm SHA256).Hash.ToLowerInvariant()
    $ConfigHash = (Get-FileHash -LiteralPath $Config -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($WorkerHash -ne $ExpectedWorkerHash) { throw "protected worker hash mismatch: $WorkerHash" }
    if ($ConfigHash -ne $ExpectedConfigHash) { throw "protected config hash mismatch: $ConfigHash" }
    $NodeVersion = (& $Node '--version' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $NodeVersion -cne $ExpectedNodeVersion) {
        throw "protected Node runtime version mismatch: expected=$ExpectedNodeVersion actual=$NodeVersion"
    }
    $env:SKYRIM_DEPLOY_SID = $Identity.User.Value
    $env:NODE_OPTIONS = $null
    $env:NODE_PATH = $null
    & $Node $Worker '--stdio'
    exit $LASTEXITCODE
} catch {
    Write-Failure ([string]$_.Exception.Message)
    exit 1
}
