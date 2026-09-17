param(
    [ValidateSet('EnableController', 'DisableController', 'EnableHost', 'DisableHost', 'Status', 'Start', 'Stop', 'SelfTest')]
    [string]$Action = 'Status',
    [switch]$Interactive,
    [switch]$Elevated
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$ToolVersion = '2.0.0'
$ToolName = 'CodexRemoteSystemProxy'
$TargetHost = 'chatgpt.com'
$TargetPort = 443
$ListenHost = '127.0.0.1'
$ListenPort = 443
$StateRoot = Join-Path $env:LOCALAPPDATA $ToolName
$InstallRoot = Join-Path $StateRoot 'app'
$BackupRoot = Join-Path $StateRoot 'backups'
$ControllerStateFile = Join-Path $StateRoot 'state.json'
$HostStateFile = Join-Path $StateRoot 'light-state.json'
$PidFile = Join-Path $StateRoot 'tunnel.pid'
$StdoutLog = Join-Path $StateRoot 'tunnel.stdout.log'
$StderrLog = Join-Path $StateRoot 'tunnel.stderr.log'
$HostsPath = Join-Path $env:WINDIR 'System32\drivers\etc\hosts'
$ConfigPath = Join-Path $env:USERPROFILE '.codex\config.toml'
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunName = $ToolName
$HostsMarker = '# CodexRemoteProxyTool'
$LegacyHostsMarker = '# Codex remote via Clash system proxy'
$ConfigMarker = '# CodexRemoteProxyTool'
$ManagedFeatureLine = "respect_system_proxy = true $ConfigMarker"
$Utf8NoBom = New-Object Text.UTF8Encoding($false)

function Write-Step([string]$Message) {
    Write-Host "[Remote Codex Proxy] $Message"
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-Administrator {
    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Action $Action -Elevated"
    if ($Interactive) { $arguments += ' -Interactive' }
    try {
        $process = Start-Process -FilePath $powershell -ArgumentList $arguments -Verb RunAs -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw "Elevated process exited with code $($process.ExitCode)." }
    } catch {
        throw "Administrator elevation was cancelled or failed: $($_.Exception.Message)"
    }
}

function ConvertFrom-ProxyAddress([string]$Address) {
    if ([string]::IsNullOrWhiteSpace($Address)) { throw 'The system proxy address is empty.' }
    $value = $Address.Trim()
    $value = [regex]::Replace($value, '^[A-Za-z][A-Za-z0-9+.-]*://', '')
    if ($value.Contains('@')) { throw 'Authenticated system proxies are not supported.' }

    if ($value -match '^\[([^\]]+)\]:(\d{1,5})$') {
        $hostName = $matches[1]
        $portNumber = [int]$matches[2]
    } elseif ($value -match '^([^:]+):(\d{1,5})$') {
        $hostName = $matches[1]
        $portNumber = [int]$matches[2]
    } else {
        throw "Cannot parse proxy endpoint: $Address"
    }

    if ($portNumber -lt 1 -or $portNumber -gt 65535) { throw "Invalid proxy port: $portNumber" }
    if ($hostName -notmatch '^[A-Za-z0-9._:-]+$') { throw "Invalid proxy host: $hostName" }
    return [pscustomobject]@{ Host = $hostName; Port = $portNumber }
}

function Get-SystemProxyEndpoint {
    $settings = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if ([int]$settings.ProxyEnable -ne 1) {
        throw 'Windows System Proxy is disabled. Enable it in Clash first.'
    }

    $raw = [string]$settings.ProxyServer
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'Windows System Proxy has no proxy server.' }
    if ($raw -notmatch '[=;]') { return ConvertFrom-ProxyAddress $raw }

    $entries = @{}
    foreach ($part in $raw.Split(';')) {
        if ($part -match '^\s*([^=]+)=(.+)\s*$') {
            $entries[$matches[1].Trim().ToLowerInvariant()] = $matches[2].Trim()
        }
    }
    if ($entries.ContainsKey('https')) { return ConvertFrom-ProxyAddress $entries['https'] }
    if ($entries.ContainsKey('http')) { return ConvertFrom-ProxyAddress $entries['http'] }
    throw 'System Proxy exposes only SOCKS or an unsupported proxy type. HTTP CONNECT is required.'
}

function Test-TcpEndpoint([string]$HostName, [int]$Port, [int]$TimeoutMs = 3000) {
    $client = New-Object Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($HostName, $Port)
        if (-not $task.Wait($TimeoutMs)) { return $false }
        return $client.Connected
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Find-NodeRuntime {
    $candidates = New-Object Collections.Generic.List[string]
    $command = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($command) { $candidates.Add($command.Source) }

    foreach ($candidate in @(
        (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'),
        (Join-Path $env:ProgramFiles 'nodejs\node.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe')
    )) {
        if ($candidate) { $candidates.Add($candidate) }
    }

    $runtimeRoot = Join-Path $env:USERPROFILE '.cache\codex-runtimes'
    if (Test-Path -LiteralPath $runtimeRoot) {
        Get-ChildItem -Path (Join-Path $runtimeRoot '*\dependencies\node\bin\node.exe') -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            ForEach-Object { $candidates.Add($_.FullName) }
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        try {
            $version = & $candidate --version 2>$null
            if ($LASTEXITCODE -eq 0 -and $version -match '^v\d+') { return $candidate }
        } catch { }
    }
    throw 'Node.js was not found. Open Codex once so its bundled runtime is installed, or install Node.js 18+.'
}

function Read-JsonState([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "State file is missing: $Path" }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Save-JsonState([string]$Path, $State) {
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($Path, ($State | ConvertTo-Json -Depth 6), $Utf8NoBom)
}

function Get-Listener {
    return Get-NetTCPConnection -State Listen -LocalAddress $ListenHost -LocalPort $ListenPort -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Get-ProcessRecord([int]$ProcessId) {
    return Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
}

function Test-ManagedProcess($ProcessRecord) {
    if (-not $ProcessRecord) { return $false }
    if (-not [string]::IsNullOrWhiteSpace([string]$ProcessRecord.CommandLine)) {
        return [string]$ProcessRecord.CommandLine -match '(?i)(CodexRemoteSystemProxy.*tunnel\.cjs|codex-remote-connect-tunnel\.cjs)'
    }
    if ([string]$ProcessRecord.Name -ne 'node.exe' -or -not (Test-Path -LiteralPath $PidFile)) { return $false }
    try {
        return [int](Get-Content -LiteralPath $PidFile -Raw).Trim() -eq [int]$ProcessRecord.ProcessId
    } catch {
        return $false
    }
}

function Stop-Tunnel {
    $candidatePids = New-Object Collections.Generic.List[int]
    if (Test-Path -LiteralPath $PidFile) {
        try { $candidatePids.Add([int](Get-Content -LiteralPath $PidFile -Raw).Trim()) } catch { }
    }
    $listener = Get-Listener
    if ($listener) { $candidatePids.Add([int]$listener.OwningProcess) }

    foreach ($candidatePid in ($candidatePids | Select-Object -Unique)) {
        $processRecord = Get-ProcessRecord $candidatePid
        if (Test-ManagedProcess $processRecord) {
            Stop-Process -Id $candidatePid -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
}

function Start-Tunnel {
    $state = Read-JsonState $ControllerStateFile
    $listener = Get-Listener
    if ($listener) {
        $processRecord = Get-ProcessRecord ([int]$listener.OwningProcess)
        if (Test-ManagedProcess $processRecord) {
            Set-Content -LiteralPath $PidFile -Value $listener.OwningProcess -Encoding ASCII
            return
        }
        throw "$ListenHost`:$ListenPort is already used by PID $($listener.OwningProcess)."
    }

    if (-not (Test-TcpEndpoint ([string]$state.ProxyHost) ([int]$state.ProxyPort))) {
        throw "The system proxy is not reachable at $($state.ProxyHost):$($state.ProxyPort). Start Clash first."
    }
    if (-not (Test-Path -LiteralPath ([string]$state.NodePath))) { throw "Node.js is missing: $($state.NodePath)" }
    $installedTunnel = Join-Path $InstallRoot 'tunnel.cjs'
    if (-not (Test-Path -LiteralPath $installedTunnel)) { throw "Tunnel script is missing: $installedTunnel" }

    $names = @('CODEX_REMOTE_LISTEN_HOST','CODEX_REMOTE_LISTEN_PORT','CODEX_REMOTE_PROXY_HOST','CODEX_REMOTE_PROXY_PORT','CODEX_REMOTE_TARGET_HOST','CODEX_REMOTE_TARGET_PORT')
    $oldEnvironment = @{}
    foreach ($name in $names) { $oldEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    try {
        $env:CODEX_REMOTE_LISTEN_HOST = [string]$state.ListenHost
        $env:CODEX_REMOTE_LISTEN_PORT = [string]$state.ListenPort
        $env:CODEX_REMOTE_PROXY_HOST = [string]$state.ProxyHost
        $env:CODEX_REMOTE_PROXY_PORT = [string]$state.ProxyPort
        $env:CODEX_REMOTE_TARGET_HOST = [string]$state.TargetHost
        $env:CODEX_REMOTE_TARGET_PORT = [string]$state.TargetPort
        $process = Start-Process -FilePath ([string]$state.NodePath) -ArgumentList @($installedTunnel) -WindowStyle Hidden -RedirectStandardOutput $StdoutLog -RedirectStandardError $StderrLog -PassThru
    } finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $oldEnvironment[$name], 'Process') }
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(6)
    do {
        Start-Sleep -Milliseconds 200
        if ($process.HasExited) {
            $details = if (Test-Path -LiteralPath $StderrLog) { Get-Content -LiteralPath $StderrLog -Raw } else { 'No error log was produced.' }
            throw "The tunnel exited during startup. $details"
        }
        $listener = Get-Listener
    } while (-not $listener -and [DateTime]::UtcNow -lt $deadline)

    if (-not $listener) { throw 'The tunnel did not start listening within six seconds.' }
    Set-Content -LiteralPath $PidFile -Value $process.Id -Encoding ASCII
}

function Test-TlsTunnel {
    $client = New-Object Net.Sockets.TcpClient
    try {
        $connectTask = $client.ConnectAsync($ListenHost, $ListenPort)
        if (-not $connectTask.Wait(8000)) { throw 'TCP timeout' }
        $ssl = New-Object Net.Security.SslStream($client.GetStream(), $false)
        try {
            $ssl.ReadTimeout = 12000
            $ssl.WriteTimeout = 12000
            $ssl.AuthenticateAsClient($TargetHost)
            return $ssl.IsAuthenticated -and $ssl.IsEncrypted
        } finally {
            $ssl.Dispose()
        }
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Get-HostsText {
    $oneByte = [Text.Encoding]::GetEncoding(28591)
    return $oneByte.GetString([IO.File]::ReadAllBytes($HostsPath))
}

function Test-ManagedHostsEntry {
    $text = Get-HostsText
    return $text.Contains($HostsMarker) -or $text.Contains($LegacyHostsMarker)
}

function Remove-ManagedMappings([string]$Text) {
    foreach ($ownedMarker in @($HostsMarker, $LegacyHostsMarker)) {
        $pattern = '127\.0\.0\.1[ \t]+chatgpt\.com[ \t]+' + [regex]::Escape($ownedMarker) + '[^\r\n]*(?:\r?\n|$)'
        $Text = [regex]::Replace($Text, $pattern, '')
    }
    return $Text
}

function Set-HostsMapping([bool]$Enabled) {
    $bytes = [IO.File]::ReadAllBytes($HostsPath)
    $oneByte = [Text.Encoding]::GetEncoding(28591)
    $original = $oneByte.GetString($bytes)
    $updated = Remove-ManagedMappings $original

    if ($Enabled) {
        if ($updated.Length -gt 0 -and -not $updated.EndsWith("`n")) { $updated += "`r`n" }
        $updated += "127.0.0.1`t$TargetHost`t$HostsMarker`r`n"
    }
    if ($updated -eq $original) { return }

    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    $backup = Join-Path $BackupRoot ("hosts.{0}.bak" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    [IO.File]::WriteAllBytes($backup, $bytes)
    [IO.File]::WriteAllBytes($HostsPath, $oneByte.GetBytes($updated))
}

function Get-StartupValue {
    $item = Get-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue
    if (-not $item) { return $null }
    $property = $item.PSObject.Properties[$RunName]
    if (-not $property) { return $null }
    return [string]$property.Value
}

function Set-StartupValue([string]$Value) {
    New-Item -Path $RunKey -Force | Out-Null
    Set-ItemProperty -Path $RunKey -Name $RunName -Value $Value
}

function Remove-StartupValue {
    Remove-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue
}

function Install-ProgramFiles {
    $sourceTunnel = Join-Path $PSScriptRoot 'tunnel.cjs'
    if (-not (Test-Path -LiteralPath $sourceTunnel)) { throw "Missing tunnel.cjs beside the launcher: $sourceTunnel" }
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null

    $installedScript = Join-Path $InstallRoot 'CodexRemoteProxy.ps1'
    $installedTunnel = Join-Path $InstallRoot 'tunnel.cjs'
    if ([IO.Path]::GetFullPath($PSCommandPath) -ne [IO.Path]::GetFullPath($installedScript)) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $installedScript -Force
    }
    if ([IO.Path]::GetFullPath($sourceTunnel) -ne [IO.Path]::GetFullPath($installedTunnel)) {
        Copy-Item -LiteralPath $sourceTunnel -Destination $installedTunnel -Force
    }
}

function Get-InstalledStartupCommand {
    $installedScript = Join-Path $InstallRoot 'CodexRemoteProxy.ps1'
    return "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$installedScript`" -Action Start"
}

function Test-ControllerConfigured {
    if (Test-Path -LiteralPath $ControllerStateFile) { return $true }
    if (Test-ManagedHostsEntry) { return $true }
    if (Get-StartupValue) { return $true }
    $listener = Get-Listener
    if ($listener -and (Test-ManagedProcess (Get-ProcessRecord ([int]$listener.OwningProcess)))) { return $true }
    return $false
}

function Get-ConfigAnalysis([string]$Text) {
    $newLine = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    [string[]]$lines = [regex]::Split($Text, '\r\n|\n|\r')
    $featureSections = New-Object Collections.Generic.List[int]
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^\s*\[features\]\s*(?:#.*)?$') { $featureSections.Add($index) }
    }

    $keyIndexes = New-Object Collections.Generic.List[int]
    if ($featureSections.Count -eq 1) {
        $start = $featureSections[0] + 1
        $end = $lines.Count
        for ($index = $start; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -match '^\s*\[[^\]]+\]') { $end = $index; break }
        }
        for ($index = $start; $index -lt $end; $index++) {
            if ($lines[$index] -match '^\s*respect_system_proxy\s*=') { $keyIndexes.Add($index) }
        }
    }

    return [pscustomobject]@{
        Lines = $lines
        NewLine = $newLine
        FeatureSectionCount = $featureSections.Count
        FeatureSectionIndex = if ($featureSections.Count -eq 1) { $featureSections[0] } else { -1 }
        KeyCount = $keyIndexes.Count
        KeyIndex = if ($keyIndexes.Count -eq 1) { $keyIndexes[0] } else { -1 }
        KeyLine = if ($keyIndexes.Count -eq 1) { $lines[$keyIndexes[0]] } else { $null }
    }
}

function Assert-ConfigIsUnambiguous($Analysis) {
    if ($Analysis.FeatureSectionCount -gt 1) { throw 'config.toml contains multiple [features] sections. Resolve them manually first.' }
    if ($Analysis.KeyCount -gt 1) { throw 'config.toml contains multiple respect_system_proxy keys. Resolve them manually first.' }
}

function Set-LightConfigText([string]$Text) {
    $analysis = Get-ConfigAnalysis $Text
    Assert-ConfigIsUnambiguous $analysis
    $lines = New-Object Collections.Generic.List[string]
    foreach ($line in $analysis.Lines) { $lines.Add([string]$line) }
    $changed = $false
    $previousPresent = $analysis.KeyCount -eq 1
    $previousLine = if ($previousPresent) { [string]$analysis.KeyLine } else { $null }
    $addedSection = $false

    if ($previousPresent) {
        if ($previousLine -notmatch '^\s*respect_system_proxy\s*=\s*(true|false)\s*(?:#.*)?$') {
            throw 'respect_system_proxy has an unsupported value. Expected true or false.'
        }
        if ($matches[1] -eq 'false') {
            $lines[$analysis.KeyIndex] = $ManagedFeatureLine
            $changed = $true
        }
    } elseif ($analysis.FeatureSectionCount -eq 1) {
        $lines.Insert($analysis.FeatureSectionIndex + 1, $ManagedFeatureLine)
        $changed = $true
    } else {
        if ($lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) { $lines.Add('') }
        $lines.Add('[features]')
        $lines.Add($ManagedFeatureLine)
        $changed = $true
        $addedSection = $true
    }

    $updated = [string]::Join($analysis.NewLine, $lines)
    if (-not $updated.EndsWith($analysis.NewLine)) { $updated += $analysis.NewLine }
    return [pscustomobject]@{
        Text = $updated
        Changed = $changed
        FeaturePreviouslyPresent = $previousPresent
        PreviousFeatureLine = $previousLine
        AddedFeaturesSection = $addedSection
    }
}

function Get-RestoredLightConfigText([string]$Text, $State) {
    if (-not [bool]$State.ConfigChanged) {
        return [pscustomobject]@{ Text = $Text; Conflict = $false; Reason = $null }
    }

    $analysis = Get-ConfigAnalysis $Text
    try { Assert-ConfigIsUnambiguous $analysis } catch {
        return [pscustomobject]@{ Text = $Text; Conflict = $true; Reason = $_.Exception.Message }
    }
    if ($analysis.KeyCount -ne 1 -or ([string]$analysis.KeyLine).Trim() -ne $ManagedFeatureLine) {
        return [pscustomobject]@{ Text = $Text; Conflict = $true; Reason = 'The managed respect_system_proxy line was changed or removed after enablement.' }
    }

    $lines = New-Object Collections.Generic.List[string]
    foreach ($line in $analysis.Lines) { $lines.Add([string]$line) }
    if ([bool]$State.FeaturePreviouslyPresent) {
        $lines[$analysis.KeyIndex] = [string]$State.PreviousFeatureLine
    } else {
        $lines.RemoveAt($analysis.KeyIndex)
        if ([bool]$State.AddedFeaturesSection) {
            $sectionIndex = $analysis.FeatureSectionIndex
            $nextSection = $lines.Count
            for ($index = $sectionIndex + 1; $index -lt $lines.Count; $index++) {
                if ($lines[$index] -match '^\s*\[[^\]]+\]') { $nextSection = $index; break }
            }
            $hasContent = $false
            for ($index = $sectionIndex + 1; $index -lt $nextSection; $index++) {
                if (-not [string]::IsNullOrWhiteSpace($lines[$index])) { $hasContent = $true; break }
            }
            if (-not $hasContent) { $lines.RemoveAt($sectionIndex) }
        }
    }

    $updated = [string]::Join($analysis.NewLine, $lines)
    if ($updated.Length -gt 0 -and -not $updated.EndsWith($analysis.NewLine)) { $updated += $analysis.NewLine }
    return [pscustomobject]@{ Text = $updated; Conflict = $false; Reason = $null }
}

function Test-ManagedFeatureLine {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $false }
    $analysis = Get-ConfigAnalysis ([IO.File]::ReadAllText($ConfigPath))
    return $analysis.KeyCount -eq 1 -and ([string]$analysis.KeyLine).Trim() -eq $ManagedFeatureLine
}

function Test-HostConfigured {
    if (Test-Path -LiteralPath $HostStateFile) { return $true }
    try { return Test-ManagedFeatureLine } catch { return $false }
}

function Broadcast-EnvironmentChange {
    if (-not ('RemoteCodexProxy.NativeMethods' -as [type])) {
        Add-Type -Namespace RemoteCodexProxy -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    }
    $result = [UIntPtr]::Zero
    [void][RemoteCodexProxy.NativeMethods]::SendMessageTimeout(
        [IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
}

function Get-EnvironmentRestoreDecision {
    param(
        [AllowNull()][string]$CurrentProxy,
        $State
    )
    if ($CurrentProxy -ne [string]$State.ProxyUrl) {
        return [pscustomobject]@{
            Conflict = $true
            ValuePresent = $false
            Value = $null
            Reason = 'User HTTPS_PROXY changed after enablement; the newer value was preserved.'
        }
    }
    return [pscustomobject]@{
        Conflict = $false
        ValuePresent = [bool]$State.PreviousHttpsProxyPresent
        Value = if ([bool]$State.PreviousHttpsProxyPresent) { [string]$State.PreviousHttpsProxy } else { $null }
        Reason = $null
    }
}

function Enable-ControllerMode {
    if (Test-HostConfigured) { throw 'Host light mode is active. Disable it before enabling controller forced mode.' }
    Write-Step 'Reading the Windows System Proxy configuration...'
    $proxy = Get-SystemProxyEndpoint
    Write-Step "Detected HTTP proxy $($proxy.Host):$($proxy.Port)."
    if (-not (Test-TcpEndpoint $proxy.Host $proxy.Port)) { throw "The proxy is not reachable: $($proxy.Host):$($proxy.Port)" }
    $nodePath = Find-NodeRuntime

    $listener = Get-Listener
    $hadManagedListener = $false
    if ($listener) {
        $hadManagedListener = Test-ManagedProcess (Get-ProcessRecord ([int]$listener.OwningProcess))
        if (-not $hadManagedListener) { throw "$ListenHost`:$ListenPort is occupied by unrelated PID $($listener.OwningProcess)." }
    }
    $hadHosts = Test-ManagedHostsEntry
    $oldStartup = Get-StartupValue
    $hadState = Test-Path -LiteralPath $ControllerStateFile
    $oldStateBytes = if ($hadState) { [IO.File]::ReadAllBytes($ControllerStateFile) } else { $null }

    try {
        Install-ProgramFiles
        $state = [ordered]@{
            Version = $ToolVersion
            Mode = 'ControllerForced'
            ProxyHost = $proxy.Host
            ProxyPort = $proxy.Port
            ListenHost = $ListenHost
            ListenPort = $ListenPort
            TargetHost = $TargetHost
            TargetPort = $TargetPort
            NodePath = $nodePath
            EnabledAt = [DateTime]::UtcNow.ToString('o')
        }
        Save-JsonState $ControllerStateFile $state
        Stop-Tunnel
        Start-Tunnel
        if (-not (Test-TlsTunnel)) { throw 'TLS verification through the system proxy failed.' }
        Set-HostsMapping $true
        Set-StartupValue (Get-InstalledStartupCommand)
        ipconfig.exe /flushdns | Out-Null
    } catch {
        $failure = $_
        try {
            Stop-Tunnel
            Set-HostsMapping $hadHosts
            if ($null -ne $oldStartup) { Set-StartupValue $oldStartup } else { Remove-StartupValue }
            if ($hadState) { [IO.File]::WriteAllBytes($ControllerStateFile, $oldStateBytes) } else { Remove-Item -LiteralPath $ControllerStateFile -Force -ErrorAction SilentlyContinue }
            if ($hadManagedListener -and $hadState) { Start-Tunnel }
            ipconfig.exe /flushdns | Out-Null
        } catch { }
        throw $failure
    }

    Write-Step 'Controller forced mode enabled. Keep Clash System Proxy on; TUN may remain off.'
}

function Disable-ControllerMode {
    Stop-Tunnel
    Remove-StartupValue
    Set-HostsMapping $false
    ipconfig.exe /flushdns | Out-Null
    Remove-Item -LiteralPath $ControllerStateFile -Force -ErrorAction SilentlyContinue
    Write-Step 'Controller forced mode disabled. Backups and logs were preserved.'
}

function Enable-HostMode {
    if (Test-ControllerConfigured) { throw 'Controller forced mode is active. Disable it before enabling host light mode.' }
    if (Test-Path -LiteralPath $HostStateFile) { throw 'Host light mode already has a state file. Disable it before enabling again.' }

    $proxy = Get-SystemProxyEndpoint
    if (-not (Test-TcpEndpoint $proxy.Host $proxy.Port)) { throw "The proxy is not reachable: $($proxy.Host):$($proxy.Port)" }
    $proxyUrl = "http://$($proxy.Host):$($proxy.Port)"
    $configExisted = Test-Path -LiteralPath $ConfigPath
    $originalConfig = if ($configExisted) { [IO.File]::ReadAllText($ConfigPath) } else { '' }
    $configResult = Set-LightConfigText $originalConfig
    $previousHttpsProxy = [Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'User')

    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    $backup = Join-Path $BackupRoot ("config.before-host-enable.{0}.toml" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    [IO.File]::WriteAllText($backup, $originalConfig, $Utf8NoBom)
    $state = [ordered]@{
        Version = $ToolVersion
        Mode = 'HostLight'
        EnabledAt = [DateTime]::UtcNow.ToString('o')
        ProxyUrl = $proxyUrl
        PreviousHttpsProxyPresent = $null -ne $previousHttpsProxy
        PreviousHttpsProxy = $previousHttpsProxy
        ConfigExisted = $configExisted
        ConfigBackupPath = $backup
        ConfigChanged = [bool]$configResult.Changed
        FeaturePreviouslyPresent = [bool]$configResult.FeaturePreviouslyPresent
        PreviousFeatureLine = $configResult.PreviousFeatureLine
        AddedFeaturesSection = [bool]$configResult.AddedFeaturesSection
    }
    Save-JsonState $HostStateFile $state

    try {
        if ($configResult.Changed) {
            New-Item -ItemType Directory -Path (Split-Path $ConfigPath -Parent) -Force | Out-Null
            [IO.File]::WriteAllText($ConfigPath, [string]$configResult.Text, $Utf8NoBom)
        }
        [Environment]::SetEnvironmentVariable('HTTPS_PROXY', $proxyUrl, 'User')
        Broadcast-EnvironmentChange
    } catch {
        $failure = $_
        try {
            if ($configExisted) { [IO.File]::WriteAllText($ConfigPath, $originalConfig, $Utf8NoBom) } else { Remove-Item -LiteralPath $ConfigPath -Force -ErrorAction SilentlyContinue }
            [Environment]::SetEnvironmentVariable('HTTPS_PROXY', $previousHttpsProxy, 'User')
            Broadcast-EnvironmentChange
            Remove-Item -LiteralPath $HostStateFile -Force -ErrorAction SilentlyContinue
        } catch { }
        throw $failure
    }

    Write-Step "Host light mode enabled with HTTPS_PROXY=$proxyUrl"
    Write-Step 'Completely exit Codex, including background processes, and then restart it.'
}

function Disable-HostMode {
    $state = Read-JsonState $HostStateFile
    $conflicts = New-Object Collections.Generic.List[string]

    if ([bool]$state.ConfigChanged) {
        if (-not (Test-Path -LiteralPath $ConfigPath)) {
            $conflicts.Add('config.toml is missing; the managed setting was not restored.')
        } else {
            $currentText = [IO.File]::ReadAllText($ConfigPath)
            $restore = Get-RestoredLightConfigText $currentText $state
            if ($restore.Conflict) {
                $conflicts.Add([string]$restore.Reason)
            } else {
                [IO.File]::WriteAllText($ConfigPath, [string]$restore.Text, $Utf8NoBom)
            }
        }
    }

    $currentProxy = [Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'User')
    $environmentRestore = Get-EnvironmentRestoreDecision $currentProxy $state
    if ($environmentRestore.Conflict) {
        $conflicts.Add([string]$environmentRestore.Reason)
    } else {
        if ($environmentRestore.ValuePresent) {
            [Environment]::SetEnvironmentVariable('HTTPS_PROXY', [string]$environmentRestore.Value, 'User')
        } else {
            [Environment]::SetEnvironmentVariable('HTTPS_PROXY', $null, 'User')
        }
        Broadcast-EnvironmentChange
    }

    if ($conflicts.Count -gt 0) {
        Write-Host 'Host light mode was only partially disabled:' -ForegroundColor Yellow
        foreach ($conflict in $conflicts) { Write-Host "- $conflict" -ForegroundColor Yellow }
        Write-Host "State was kept at $HostStateFile" -ForegroundColor Yellow
        throw 'Manual changes were detected; review the warnings above.'
    }

    Remove-Item -LiteralPath $HostStateFile -Force
    Write-Step 'Host light mode disabled and previous settings restored.'
    Write-Step 'Completely exit Codex, including background processes, and then restart it.'
}

function Show-Status {
    $proxyDisplay = '<unavailable>'
    $proxyReady = $false
    try {
        $proxy = Get-SystemProxyEndpoint
        $proxyDisplay = "$($proxy.Host):$($proxy.Port)"
        $proxyReady = Test-TcpEndpoint $proxy.Host $proxy.Port
    } catch { $proxyDisplay = $_.Exception.Message }

    $hostsInstalled = Test-ManagedHostsEntry
    $startupValue = Get-StartupValue
    $listener = Get-Listener
    $managedListener = $false
    if ($listener) { $managedListener = Test-ManagedProcess (Get-ProcessRecord ([int]$listener.OwningProcess)) }
    $tlsReady = if ($managedListener) { Test-TlsTunnel } else { $false }
    $tunUp = [bool](Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { ($_.Name -match '^(Meta|Mihomo|Clash)') -and $_.Status -eq 'Up' } | Select-Object -First 1)
    $userProxy = [Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'User')
    $featureDisplay = '<missing>'
    try {
        if (Test-Path -LiteralPath $ConfigPath) {
            $analysis = Get-ConfigAnalysis ([IO.File]::ReadAllText($ConfigPath))
            if ($analysis.FeatureSectionCount -gt 1 -or $analysis.KeyCount -gt 1) { $featureDisplay = '<ambiguous>' }
            elseif ($analysis.KeyCount -eq 1) { $featureDisplay = ([string]$analysis.KeyLine).Trim() }
        }
    } catch { $featureDisplay = "<error: $($_.Exception.Message)>" }

    $rows = @(
        [pscustomobject]@{ Check = 'System proxy'; Status = if ($proxyReady) { 'OK' } else { 'NOT READY' }; Details = $proxyDisplay },
        [pscustomobject]@{ Check = 'TUN adapter'; Status = if ($tunUp) { 'ON' } else { 'OFF' }; Details = 'TUN is optional' },
        [pscustomobject]@{ Check = 'Controller hosts'; Status = if ($hostsInstalled) { 'OK' } else { 'OFF' }; Details = $TargetHost },
        [pscustomobject]@{ Check = 'Controller startup'; Status = if ($startupValue) { 'OK' } else { 'OFF' }; Details = [string]$startupValue },
        [pscustomobject]@{ Check = 'Controller tunnel'; Status = if ($managedListener -and $tlsReady) { 'OK' } elseif ($managedListener) { 'TLS FAILED' } else { 'OFF' }; Details = "$ListenHost`:$ListenPort" },
        [pscustomobject]@{ Check = 'Host HTTPS_PROXY'; Status = if ($userProxy) { 'SET' } else { 'OFF' }; Details = [string]$userProxy },
        [pscustomobject]@{ Check = 'Host feature'; Status = if ($featureDisplay -match '=\s*true') { 'SET' } else { 'OFF' }; Details = $featureDisplay },
        [pscustomobject]@{ Check = 'Host state'; Status = if (Test-Path -LiteralPath $HostStateFile) { 'ON' } else { 'OFF' }; Details = $HostStateFile }
    )
    $rows | Format-Table -AutoSize

    if ((Test-ControllerConfigured) -and (Test-HostConfigured)) {
        Write-Host 'WARNING: controller and host modes appear to be mixed. Disable one mode.' -ForegroundColor Yellow
    }
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Self-test failed: $Message" }
}

function Invoke-SelfTest {
    foreach ($case in @(
        @{ Input = '127.0.0.1:7897'; Host = '127.0.0.1'; Port = 7897 },
        @{ Input = 'http://localhost:8080'; Host = 'localhost'; Port = 8080 },
        @{ Input = '[::1]:8888'; Host = '::1'; Port = 8888 }
    )) {
        $result = ConvertFrom-ProxyAddress $case.Input
        Assert-True ($result.Host -eq $case.Host -and $result.Port -eq $case.Port) "proxy parser: $($case.Input)"
    }

    $missing = Set-LightConfigText "model = `"example`"`n"
    Assert-True ($missing.Text -match '(?m)^\[features\]$') 'add missing [features] section'
    Assert-True ($missing.Text.Contains($ManagedFeatureLine)) 'add managed feature line'
    $missingRestoreState = [pscustomobject]@{ ConfigChanged = $true; FeaturePreviouslyPresent = $false; PreviousFeatureLine = $null; AddedFeaturesSection = $true }
    $missingRestored = Get-RestoredLightConfigText $missing.Text $missingRestoreState
    Assert-True (-not $missingRestored.Conflict -and $missingRestored.Text -notmatch '(?m)^\[features\]$') 'remove a tool-created empty [features] section'
    $existing = Set-LightConfigText "[features]`njs_repl = false`n"
    Assert-True ($existing.Text.Contains($ManagedFeatureLine)) 'insert into existing [features] section'
    $alreadyTrue = Set-LightConfigText "[features]`nrespect_system_proxy = true`n"
    Assert-True (-not $alreadyTrue.Changed) 'leave an existing true value unchanged'
    $wasFalse = Set-LightConfigText "[features]`nrespect_system_proxy = false`n"
    Assert-True ($wasFalse.Changed -and $wasFalse.FeaturePreviouslyPresent) 'replace an existing false value'
    $restoreState = [pscustomobject]@{ ConfigChanged = $true; FeaturePreviouslyPresent = $true; PreviousFeatureLine = 'respect_system_proxy = false'; AddedFeaturesSection = $false }
    $restored = Get-RestoredLightConfigText $wasFalse.Text $restoreState
    Assert-True (-not $restored.Conflict -and $restored.Text -match 'respect_system_proxy = false') 'restore previous feature value'
    $conflict = Get-RestoredLightConfigText ($wasFalse.Text.Replace($ManagedFeatureLine, 'respect_system_proxy = false # user changed')) $restoreState
    Assert-True $conflict.Conflict 'detect a user-edited managed line'

    $duplicateSectionFailed = $false
    try { [void](Set-LightConfigText "[features]`n`n[features]`n") } catch { $duplicateSectionFailed = $true }
    Assert-True $duplicateSectionFailed 'reject duplicate [features] sections'
    $duplicateKeyFailed = $false
    try { [void](Set-LightConfigText "[features]`nrespect_system_proxy = true`nrespect_system_proxy = false`n") } catch { $duplicateKeyFailed = $true }
    Assert-True $duplicateKeyFailed 'reject duplicate feature keys'

    $environmentState = [pscustomobject]@{ ProxyUrl = 'http://proxy:7897'; PreviousHttpsProxyPresent = $true; PreviousHttpsProxy = 'http://old:8080' }
    $environmentRestore = Get-EnvironmentRestoreDecision 'http://proxy:7897' $environmentState
    Assert-True (-not $environmentRestore.Conflict -and $environmentRestore.Value -eq 'http://old:8080') 'restore the previous HTTPS_PROXY value'
    $environmentConflict = Get-EnvironmentRestoreDecision 'http://user-change:9999' $environmentState
    Assert-True $environmentConflict.Conflict 'preserve a newer user HTTPS_PROXY value'

    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $tempRoot = Join-Path $tempBase ("remote-codex-proxy-selftest-{0}" -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    try {
        $testStatePath = Join-Path $tempRoot 'state.json'
        $testState = [ordered]@{ Version = $ToolVersion; PreviousHttpsProxyPresent = $true; PreviousHttpsProxy = 'http://old:1' }
        Save-JsonState $testStatePath $testState
        $roundTrip = Read-JsonState $testStatePath
        Assert-True ($roundTrip.Version -eq $ToolVersion -and $roundTrip.PreviousHttpsProxy -eq 'http://old:1') 'JSON state round trip'
    } finally {
        $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
        if (-not $resolvedTemp.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing to remove a self-test directory outside the temp root.' }
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }

    $nodePath = Find-NodeRuntime
    & $nodePath --check (Join-Path $PSScriptRoot 'tunnel.cjs')
    if ($LASTEXITCODE -ne 0) { throw 'Node.js syntax check failed.' }
    Write-Step 'Self-test passed.'
}

$exitCode = 0
try {
    if (($Action -eq 'EnableController' -or $Action -eq 'DisableController') -and -not (Test-Administrator)) {
        if ($Elevated) { throw 'Administrator elevation did not take effect.' }
        Request-Administrator
        exit 0
    }

    switch ($Action) {
        'EnableController' { Enable-ControllerMode }
        'DisableController' { Disable-ControllerMode }
        'EnableHost' { Enable-HostMode }
        'DisableHost' { Disable-HostMode }
        'Status' { Show-Status }
        'Start' { Start-Tunnel }
        'Stop' { Stop-Tunnel }
        'SelfTest' { Invoke-SelfTest }
    }
} catch {
    $exitCode = 1
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
}

if ($Interactive) {
    Write-Host ''
    [void](Read-Host 'Press Enter to continue / 按回车继续')
}
exit $exitCode
