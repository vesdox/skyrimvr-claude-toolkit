Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExpectedSid = 'S-1-5-21-3046562540-2879210194-691397096-1014'
$ExpectedCommand = 'project-deploy-v1'
$Node = 'D:\Program Files\nodejs\node.exe'
$Worker = 'C:\ProgramData\SkyrimToolBridge\project-deploy\bridge\bridge.js'
$Config = 'C:\ProgramData\SkyrimToolBridge\project-deploy\config.json'
$ExpectedWorkerHash = '99eabaafbd3e0b850ae0d3e8a891e4443d57dd2900a2423f5c9804a5e87e6442'
$ExpectedConfigHash = '8103009b73fb481c5a3ae631282bea412ae0aa4b7b95a57ed82a2863c2afac4a'

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
    $NodeVersion = (& $Node '--version' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $NodeVersion -notmatch '^v(?:2[0-9]|[3-9][0-9]|[1-9][0-9]{2,})\.[0-9]+\.[0-9]+$') {
        throw "unexpected Node.js runtime version: $NodeVersion"
    }
    $WorkerHash = (Get-FileHash -LiteralPath $Worker -Algorithm SHA256).Hash.ToLowerInvariant()
    $ConfigHash = (Get-FileHash -LiteralPath $Config -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($WorkerHash -ne $ExpectedWorkerHash) { throw "protected worker hash mismatch: $WorkerHash" }
    if ($ConfigHash -ne $ExpectedConfigHash) { throw "protected config hash mismatch: $ConfigHash" }
    $env:SKYRIM_DEPLOY_SID = $Identity.User.Value
    $env:NODE_OPTIONS = $null
    $env:NODE_PATH = $null
    & $Node $Worker '--stdio'
    exit $LASTEXITCODE
} catch {
    Write-Failure ([string]$_.Exception.Message)
    exit 1
}
