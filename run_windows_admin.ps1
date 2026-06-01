[CmdletBinding()]
param(
    [ValidateSet('windows')]
    [string]$Device = 'windows',

    [switch]$BuildOnly,

    [switch]$Release,

    [switch]$NoPause,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraFlutterArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptPath
$logDirectory = Join-Path $projectRoot 'logs'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$eventLogFile = Join-Path $logDirectory "run_windows_admin-$timestamp.log"
$transcriptFile = Join-Path $logDirectory "run_windows_admin-$timestamp.transcript.log"
$scriptExitCode = 0
$transcriptStarted = $false

function Ensure-LogDirectory {
    if (-not (Test-Path -LiteralPath $logDirectory)) {
        New-Item -ItemType Directory -Path $logDirectory | Out-Null
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    Add-Content -LiteralPath $eventLogFile -Value $line

    switch ($Level) {
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line -ForegroundColor Gray }
    }
}

function Pause-BeforeExit {
    if (-not $NoPause) {
        Write-Host ''
        Write-Host "Press Enter to close this PowerShell window..." -ForegroundColor Yellow
        [void](Read-Host)
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FlutterCommand {
    $flutter = Get-Command flutter -ErrorAction SilentlyContinue
    if ($null -eq $flutter) {
        throw "Flutter command was not found. Ensure Flutter is available in PATH."
    }
    return $flutter.Source
}

Ensure-LogDirectory
Set-Content -LiteralPath $eventLogFile -Value ''
Start-Transcript -Path $transcriptFile | Out-Null
$transcriptStarted = $true

try {
    Write-Log "Script started. PID=$PID User=$env:USERNAME Computer=$env:COMPUTERNAME"
    Write-Log "Script path: $scriptPath"
    Write-Log "Project root: $projectRoot"
    Write-Log "Event log file: $eventLogFile"
    Write-Log "Transcript log file: $transcriptFile"
    Write-Log "Parameters => Device=$Device BuildOnly=$BuildOnly Release=$Release NoPause=$NoPause ExtraArgs=$($ExtraFlutterArgs -join ' ')"

    if (-not (Test-IsAdministrator)) {
        Write-Log 'Administrator privileges not detected. Requesting UAC elevation...' 'WARN'

        $relaunchArgs = @(
            '-NoProfile'
            '-ExecutionPolicy'
            'Bypass'
            '-File'
            $scriptPath
            '-Device'
            $Device
        )

        if ($BuildOnly) {
            $relaunchArgs += '-BuildOnly'
        }

        if ($Release) {
            $relaunchArgs += '-Release'
        }

        if ($NoPause) {
            $relaunchArgs += '-NoPause'
        }

        foreach ($arg in $ExtraFlutterArgs) {
            $relaunchArgs += $arg
        }

        Write-Log "Elevation relaunch command: powershell.exe $($relaunchArgs -join ' ')"
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $relaunchArgs | Out-Null
        Write-Log 'Elevation request submitted successfully. Current process will exit with code 0.'
        $scriptExitCode = 0
        return
    }

    Write-Log 'Administrator privileges granted.'
    $flutterCommand = Get-FlutterCommand
    Write-Log "Resolved flutter command: $flutterCommand"

    $flutterArgs = @()
    if ($BuildOnly) {
        $flutterArgs += 'build'
        $flutterArgs += $Device
    }
    else {
        $flutterArgs += 'run'
        $flutterArgs += '-d'
        $flutterArgs += $Device
    }

    if ($Release) {
        $flutterArgs += '--release'
    }

    foreach ($arg in $ExtraFlutterArgs) {
        $flutterArgs += $arg
    }

    Write-Log "Running command: $flutterCommand $($flutterArgs -join ' ')"
    Write-Host "Administrator privileges granted." -ForegroundColor Green
    Write-Host "Project root: $projectRoot" -ForegroundColor Cyan
    Write-Host "Event log file: $eventLogFile" -ForegroundColor Cyan
    Write-Host "Transcript log file: $transcriptFile" -ForegroundColor Cyan
    Write-Host "Running command: $flutterCommand $($flutterArgs -join ' ')" -ForegroundColor Cyan

    Push-Location $projectRoot
    try {
        & $flutterCommand @flutterArgs
        if ($null -ne $LASTEXITCODE) {
            $scriptExitCode = $LASTEXITCODE
        }
        Write-Log "Flutter command completed. LASTEXITCODE=$scriptExitCode"
    }
    finally {
        Pop-Location
        Write-Log 'Working directory restored.'
    }
}
catch {
    $scriptExitCode = 1
    Write-Log "Unhandled exception type: $($_.Exception.GetType().FullName)" 'ERROR'
    Write-Log "Unhandled exception message: $($_.Exception.Message)" 'ERROR'
    if ($_.InvocationInfo) {
        Write-Log "Failure location: $($_.InvocationInfo.PositionMessage.Trim())" 'ERROR'
    }
    if ($_.ScriptStackTrace) {
        Write-Log "Script stack trace: $($_.ScriptStackTrace)" 'ERROR'
    }
    throw
}
finally {
    Write-Log "Script finished with exit code $scriptExitCode"
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
    }
    Pause-BeforeExit
    exit $scriptExitCode
}
