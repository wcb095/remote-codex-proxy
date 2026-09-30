param(
    [switch]$SkipStart
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$ToolName = 'CodexRemoteSystemProxy'
$ExpectedVersion = '2.2.0'
$SourceScript = Join-Path $PSScriptRoot 'CodexRemoteProxy.ps1'
$SourceTunnel = Join-Path $PSScriptRoot 'tunnel.cjs'
$StateRoot = Join-Path $env:LOCALAPPDATA $ToolName
$InstallRoot = Join-Path $StateRoot 'app'
$BackupRoot = Join-Path $StateRoot 'backups'
$InstalledScript = Join-Path $InstallRoot 'CodexRemoteProxy.ps1'
$InstalledTunnel = Join-Path $InstallRoot 'tunnel.cjs'

function Get-ToolVersionLine([string]$Path) {
    return Select-String -LiteralPath $Path -Pattern '^\s*\$ToolVersion\s*=' | Select-Object -First 1
}

function Assert-UnifiedScript([string]$Path, [string]$Label) {
    $versionLine = Get-ToolVersionLine $Path
    if (-not $versionLine) {
        throw "$Label does not expose ToolVersion: $Path"
    }

    $versionPattern = '^\s*\$ToolVersion\s*=\s*''([^'']+)''\s*$'
    if ($versionLine.Line -notmatch $versionPattern) {
        throw "Cannot parse $Label version line: $($versionLine.Line)"
    }

    $actualVersion = $Matches[1]
    if ($actualVersion -ne $ExpectedVersion) {
        throw "Unexpected $Label version: $actualVersion (expected $ExpectedVersion)"
    }

    $unifiedAction = Select-String -LiteralPath $Path -SimpleMatch "'StartUnified'" | Select-Object -First 1
    if (-not $unifiedAction) {
        throw "$Label does not contain the StartUnified action: $Path"
    }

    return $versionLine
}

if (-not (Test-Path -LiteralPath $SourceScript)) { throw "Missing source file: $SourceScript" }
if (-not (Test-Path -LiteralPath $SourceTunnel)) { throw "Missing source file: $SourceTunnel" }

$sourceVersionLine = Assert-UnifiedScript $SourceScript 'Source script'
Write-Host "[Remote Codex Proxy] Source verified: $($sourceVersionLine.Line.Trim())"

New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (Test-Path -LiteralPath $InstalledScript) {
    Copy-Item -LiteralPath $InstalledScript -Destination (Join-Path $BackupRoot "CodexRemoteProxy.ps1.$stamp.bak") -Force
}
if (Test-Path -LiteralPath $InstalledTunnel) {
    Copy-Item -LiteralPath $InstalledTunnel -Destination (Join-Path $BackupRoot "tunnel.cjs.$stamp.bak") -Force
}

Copy-Item -LiteralPath $SourceScript -Destination $InstalledScript -Force
Copy-Item -LiteralPath $SourceTunnel -Destination $InstalledTunnel -Force

$installedVersionLine = Assert-UnifiedScript $InstalledScript 'Installed script'
Write-Host "[Remote Codex Proxy] Installed unified launcher: $($installedVersionLine.Line.Trim())"

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $InstalledScript -Action SelfTest
if ($LASTEXITCODE -ne 0) { throw "SelfTest failed with exit code $LASTEXITCODE." }

if (-not $SkipStart) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $InstalledScript -Action StartUnified
    if ($LASTEXITCODE -ne 0) { throw "StartUnified failed with exit code $LASTEXITCODE." }

    $listeners = Get-NetTCPConnection -State Listen -LocalAddress 127.0.0.1 -LocalPort 443,17841 -ErrorAction SilentlyContinue
    $ports = @($listeners | Select-Object -ExpandProperty LocalPort -Unique)
    foreach ($requiredPort in @(443, 17841)) {
        if ($ports -notcontains $requiredPort) {
            throw "Unified start completed without listener 127.0.0.1:$requiredPort."
        }
    }

    Write-Host '[Remote Codex Proxy] Unified remote-control stack verified on 127.0.0.1:443 and 127.0.0.1:17841.'
}
