param(
    [switch]$SkipStart
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$ToolName = 'CodexRemoteSystemProxy'
$SourceScript = Join-Path $PSScriptRoot 'CodexRemoteProxy.ps1'
$SourceTunnel = Join-Path $PSScriptRoot 'tunnel.cjs'
$StateRoot = Join-Path $env:LOCALAPPDATA $ToolName
$InstallRoot = Join-Path $StateRoot 'app'
$BackupRoot = Join-Path $StateRoot 'backups'
$InstalledScript = Join-Path $InstallRoot 'CodexRemoteProxy.ps1'
$InstalledTunnel = Join-Path $InstallRoot 'tunnel.cjs'

if (-not (Test-Path -LiteralPath $SourceScript)) { throw "Missing source file: $SourceScript" }
if (-not (Test-Path -LiteralPath $SourceTunnel)) { throw "Missing source file: $SourceTunnel" }

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

$versionLine = Select-String -LiteralPath $InstalledScript -Pattern "\$ToolVersion\s*=\s*'([^']+)'" | Select-Object -First 1
if (-not $versionLine) { throw 'Installed script does not expose ToolVersion.' }
if ($versionLine.Line -notmatch "'2\.2\.0'") {
    throw "Unexpected installed version: $($versionLine.Line)"
}

Write-Host "[Remote Codex Proxy] Installed unified launcher: $($versionLine.Line.Trim())"

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
