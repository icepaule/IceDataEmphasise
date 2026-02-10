# =============================================================================
# install-cribl-edge.ps1 - Install Cribl Edge on Windows (Managed Mode)
# =============================================================================
# Installs Cribl Edge as a managed Edge node, registers it with the Cribl
# Leader, assigns it to the "windows-workstations" fleet, configures Windows
# Event Log collection, and starts the service.
#
# Must be run as Administrator.
# =============================================================================

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# =============================================================================
# Configuration
# =============================================================================

$CriblVersion   = "4.16.0"
$LeaderHost     = "100.64.0.1"         # <-- Replace with your Tailscale IP of the Cribl Leader
$LeaderPort     = "4200"
$InstallDir     = "C:\Program Files\Cribl\Edge"
$FleetName      = "windows-workstations"
$ServiceName    = "CriblEdge"
$MsiUrl         = "https://cdn.cribl.io/dl/$CriblVersion/cribl-$CriblVersion-windows-x64.msi"
$TempDir        = "$env:TEMP\CriblEdgeInstall"
$MsiPath        = "$TempDir\cribl-$CriblVersion-windows-x64.msi"

# Windows Event Log channels to collect
$EventLogChannels = @("Application", "Security", "System")

# =============================================================================
# Functions
# =============================================================================

function Write-Log {
    param (
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("INFO", "OK", "WARN", "ERROR")][string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $colors = @{
        "INFO"  = "Cyan"
        "OK"    = "Green"
        "WARN"  = "Yellow"
        "ERROR" = "Red"
    }
    Write-Host "[$Level]  $timestamp $Message" -ForegroundColor $colors[$Level]
}

function Assert-Administrator {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )
    if (-not $currentPrincipal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {

        Write-Log "Script requires Administrator privileges. Attempting to self-elevate..." -Level WARN

        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        try {
            Start-Process -FilePath "powershell.exe" `
                          -ArgumentList $arguments `
                          -Verb RunAs
        }
        catch {
            Write-Log "Failed to elevate. Please right-click the script and select 'Run as Administrator'." -Level ERROR
            exit 1
        }
        exit 0
    }
    Write-Log "Running with Administrator privileges."
}

function Initialize-TempDirectory {
    if (-not (Test-Path $TempDir)) {
        New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
        Write-Log "Created temporary directory: $TempDir"
    }
}

function Get-CriblMsi {
    Write-Log "Downloading Cribl Edge $CriblVersion MSI..."
    Write-Log "URL: $MsiUrl"

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $webClient = New-Object System.Net.WebClient
        $webClient.DownloadFile($MsiUrl, $MsiPath)
        Write-Log "Download complete: $MsiPath" -Level OK
    }
    catch {
        Write-Log "Failed to download MSI: $_" -Level ERROR
        exit 1
    }

    if (-not (Test-Path $MsiPath)) {
        Write-Log "MSI file not found after download." -Level ERROR
        exit 1
    }
}

function Install-CriblEdge {
    Write-Log "Installing Cribl Edge to $InstallDir (silent install)..."

    $msiArgs = @(
        "/i"
        "`"$MsiPath`""
        "INSTALLDIR=`"$InstallDir`""
        "/qn"
        "/norestart"
        "/L*v"
        "`"$TempDir\cribl-edge-install.log`""
    )

    $process = Start-Process -FilePath "msiexec.exe" `
                             -ArgumentList $msiArgs `
                             -Wait -PassThru

    if ($process.ExitCode -ne 0) {
        Write-Log "MSI installation failed with exit code $($process.ExitCode). Check log: $TempDir\cribl-edge-install.log" -Level ERROR
        exit 1
    }

    Write-Log "Cribl Edge installed successfully." -Level OK
}

function Set-ManagedEdgeConfiguration {
    Write-Log "Configuring Cribl Edge as managed node..."

    $criblBin = Join-Path $InstallDir "bin\cribl.exe"
    if (-not (Test-Path $criblBin)) {
        Write-Log "cribl.exe not found at $criblBin" -Level ERROR
        exit 1
    }

    # Set environment variables for managed-edge mode
    $envVars = @{
        "CRIBL_DIST_MODE"       = "managed-edge"
        "CRIBL_DIST_MASTER_URL" = "tcp://${LeaderHost}:${LeaderPort}"
    }

    foreach ($key in $envVars.Keys) {
        [System.Environment]::SetEnvironmentVariable($key, $envVars[$key], "Machine")
        Write-Log "Set system environment variable: $key = $($envVars[$key])"
    }

    # Configure mode via cribl CLI
    $modeArgs = "mode-managed-edge -H $LeaderHost -p $LeaderPort"
    Write-Log "Running: cribl.exe $modeArgs"
    $result = Start-Process -FilePath $criblBin `
                            -ArgumentList $modeArgs `
                            -Wait -PassThru -NoNewWindow

    if ($result.ExitCode -ne 0) {
        Write-Log "Failed to configure managed-edge mode (exit code $($result.ExitCode)). Continuing with environment variable approach..." -Level WARN
    }
    else {
        Write-Log "Managed-edge mode configured via CLI." -Level OK
    }

    # Fleet assignment via tags
    $localConfDir = Join-Path $InstallDir "local"
    if (-not (Test-Path $localConfDir)) {
        New-Item -ItemType Directory -Path $localConfDir -Force | Out-Null
    }

    $instanceConf = Join-Path $localConfDir "cribl.yml"
    $fleetConfig = @"
distributed:
  mode: managed-edge
  master:
    host: $LeaderHost
    port: $LeaderPort
  group: $FleetName
  tags:
    fleet: $FleetName
    os: windows
    hostname: $($env:COMPUTERNAME.ToLower())
"@
    Set-Content -Path $instanceConf -Value $fleetConfig -Encoding UTF8
    Write-Log "Fleet assignment written to $instanceConf (fleet: $FleetName)" -Level OK
}

function Set-WindowsEventLogCollection {
    Write-Log "Configuring Windows Event Log collection..."

    $inputsDir = Join-Path $InstallDir "local\cribl\inputs"
    if (-not (Test-Path $inputsDir)) {
        New-Item -ItemType Directory -Path $inputsDir -Force | Out-Null
    }

    # Build the Windows Event Log source configuration
    $channels = ($EventLogChannels | ForEach-Object { "      - `"$_`"" }) -join "`n"

    $winEventConf = @"
win_event_logs:
  inputs:
    windows_event_logs:
      id: windows_event_logs
      type: win_event_logs
      disabled: false
      channels:
$channels
      renderMessages: true
      eventBatchSize: 50
      metadata:
        - name: source
          value: "WinEventLog"
        - name: sourcetype
          value: "WinEventLog"
        - name: host
          value: "`$\{C.os.hostname\}"
"@

    $confPath = Join-Path $inputsDir "win_event_logs.yml"
    Set-Content -Path $confPath -Value $winEventConf -Encoding UTF8
    Write-Log "Windows Event Log configuration written to $confPath" -Level OK
    Write-Log "Channels configured: $($EventLogChannels -join ', ')"
}

function Register-CriblService {
    Write-Log "Registering Cribl Edge as Windows service..."

    $criblBin = Join-Path $InstallDir "bin\cribl.exe"

    # Register the service
    $result = Start-Process -FilePath $criblBin `
                            -ArgumentList "boot-start enable -m $ServiceName" `
                            -Wait -PassThru -NoNewWindow

    if ($result.ExitCode -ne 0) {
        Write-Log "Service registration via cribl CLI returned exit code $($result.ExitCode). Trying sc.exe fallback..." -Level WARN

        # Fallback: register via sc.exe
        $svcBinary = Join-Path $InstallDir "bin\cribl.exe"
        & sc.exe create $ServiceName binPath= "`"$svcBinary`" service" start= auto DisplayName= "Cribl Edge"
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Failed to register service." -Level ERROR
            exit 1
        }
    }

    Write-Log "Service '$ServiceName' registered." -Level OK
}

function Start-CriblService {
    Write-Log "Starting Cribl Edge service..."

    try {
        Start-Service -Name $ServiceName -ErrorAction Stop
    }
    catch {
        Write-Log "Start-Service failed, trying net start..." -Level WARN
        & net start $ServiceName
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Failed to start service '$ServiceName'." -Level ERROR
            exit 1
        }
    }

    # Wait for service to reach Running state
    $timeout = 30
    $elapsed = 0
    while ((Get-Service -Name $ServiceName).Status -ne "Running") {
        Start-Sleep -Seconds 1
        $elapsed++
        if ($elapsed -ge $timeout) {
            Write-Log "Timeout waiting for service '$ServiceName' to start after ${timeout}s." -Level ERROR
            exit 1
        }
    }

    Write-Log "Service '$ServiceName' is running (${elapsed}s)." -Level OK
}

function Confirm-ServiceRunning {
    Write-Log "Verifying Cribl Edge service status..."

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        Write-Log "Service '$ServiceName' not found!" -Level ERROR
        exit 1
    }

    if ($svc.Status -eq "Running") {
        Write-Log "Service '$ServiceName' is running." -Level OK
    }
    else {
        Write-Log "Service '$ServiceName' status: $($svc.Status)" -Level ERROR
        exit 1
    }
}

function Remove-TempFiles {
    Write-Log "Cleaning up temporary files..."
    if (Test-Path $TempDir) {
        Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
    }
    Write-Log "Cleanup complete."
}

function Write-SuccessMessage {
    Write-Host ""
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host "  IceDataEmphasise - Cribl Edge Installed"     -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Version:      $CriblVersion"                 -ForegroundColor White
    Write-Host "  Install Dir:  $InstallDir"                   -ForegroundColor White
    Write-Host "  Mode:         managed-edge"                  -ForegroundColor White
    Write-Host "  Leader:       tcp://${LeaderHost}:${LeaderPort}" -ForegroundColor White
    Write-Host "  Fleet:        $FleetName"                    -ForegroundColor White
    Write-Host "  Service:      $ServiceName (Running)"        -ForegroundColor Green
    Write-Host "  Event Logs:   $($EventLogChannels -join ', ')" -ForegroundColor White
    Write-Host ""
    Write-Host "  The Edge node should appear in the Cribl"    -ForegroundColor White
    Write-Host "  Leader UI within 1-2 minutes."               -ForegroundColor White
    Write-Host ""
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host ""
}

# =============================================================================
# Main
# =============================================================================

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  IceDataEmphasise - Cribl Edge Installer"    -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Blue
Write-Host "  Host: $env:COMPUTERNAME"                    -ForegroundColor Blue
Write-Host "  User: $env:USERNAME"                        -ForegroundColor Blue
Write-Host ""

Assert-Administrator
Initialize-TempDirectory
Get-CriblMsi
Install-CriblEdge
Set-ManagedEdgeConfiguration
Set-WindowsEventLogCollection
Register-CriblService
Start-CriblService
Confirm-ServiceRunning
Remove-TempFiles
Write-SuccessMessage
