[CmdletBinding()]
param(
    [ValidateSet('windows')]
    [string]$Device = 'windows',

    [switch]$BuildOnly,

    [switch]$Release,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraFlutterArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

$scriptPath = $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptPath

if (-not (Test-IsAdministrator)) {
    Write-Host "Admin privileges are required. Requesting UAC elevation..." -ForegroundColor Yellow

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

    foreach ($arg in $ExtraFlutterArgs) {
        $relaunchArgs += $arg
    }

    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $relaunchArgs
    exit 0
}

$flutterCommand = Get-FlutterCommand

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

Write-Host "Administrator privileges granted." -ForegroundColor Green
Write-Host "Project root: $projectRoot" -ForegroundColor Cyan
Write-Host "Running command: $flutterCommand $($flutterArgs -join ' ')" -ForegroundColor Cyan

Push-Location $projectRoot
try {
    & $flutterCommand @flutterArgs
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
