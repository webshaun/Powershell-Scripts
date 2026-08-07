<#
.SYNOPSIS
    Recreates the Elgato Wave Link early-start setup from scratch.

.DESCRIPTION
    Wave Link 3 is an MSIX package. Its "silent start" (minimize to tray) is driven by
    a StartupTask activation kind that only Windows sends, and Windows deliberately
    runs AppModel startup tasks LAST in the logon chain. This deployer replaces that
    with a logon scheduled task that fires early, then hides the window manually.

    Lays down two files in %LOCALAPPDATA%\Scripts\:
      1. Start-WaveLink.ps1  - activates Wave Link, waits for its window, hides it.
      2. Start-WaveLink.vbs  - launches the .ps1 with no console window at all.

    Then disables Wave Link's native startup task and registers the logon task.

    Run as your normal user. Do NOT run elevated - a packaged app activated from an
    elevated context will not land in your interactive session.

.PARAMETER Remove
    Tears everything down: unregisters the task, deletes both scripts, and re-enables
    the native startup task.

.EXAMPLE
    .\Deploy-WaveLinkEarlyStart.ps1
    .\Deploy-WaveLinkEarlyStart.ps1 -Remove
#>

[CmdletBinding()]
param(
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

# ===========================================================================
# Config
# ===========================================================================

$ScriptDir  = Join-Path $env:LOCALAPPDATA 'Scripts'
$Ps1Path    = Join-Path $ScriptDir 'Start-WaveLink.ps1'
$VbsPath    = Join-Path $ScriptDir 'Start-WaveLink.vbs'
$TaskName   = 'Start Wave Link (early)'
$LogonDelay = 'PT5S'      # ISO 8601. PT0S = no delay, PT10S = ten seconds.
$HideMode   = 0           # 0 = SW_HIDE (correct for Wave Link 3.x)
                          # 6 = SW_MINIMIZE (leaves a taskbar button on this app)

# ===========================================================================

function Write-Step { param([string]$m) Write-Host "  $m" }
function Write-Ok   { param([string]$m) Write-Host "  [ok]   $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "  [warn] $m" -ForegroundColor Yellow }

Write-Host ''
Write-Host 'Wave Link early-start deployer' -ForegroundColor Cyan
Write-Host ''

# ---------------------------------------------------------------------------
# Guard: never run elevated
# ---------------------------------------------------------------------------

$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($isAdmin) {
    Write-Warn 'This session is elevated.'
    Write-Warn 'Packaged app activation from an elevated context lands in the wrong'
    Write-Warn 'session and the task will silently do nothing. Re-run unelevated.'
    return
}

# ---------------------------------------------------------------------------
# Locate the Wave Link package
# ---------------------------------------------------------------------------

$pkg = Get-AppxPackage -Name 'Elgato.WaveLink' -ErrorAction SilentlyContinue | Select-Object -First 1

if (-not $pkg) {
    Write-Warn 'Elgato Wave Link is not installed for this user.'
    Write-Warn 'Install it first, then re-run this script.'
    return
}

Write-Step "Package : $($pkg.Name) $($pkg.Version)"
Write-Step "PFN     : $($pkg.PackageFamilyName)"

# Find the startup task GUID from the AppModel state key rather than hardcoding it.
$stateBase = "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\" +
             "CurrentVersion\AppModel\SystemAppData\$($pkg.PackageFamilyName)"

$startupKey = Get-ChildItem $stateBase -Recurse -ErrorAction SilentlyContinue |
              Where-Object { $_.Property -contains 'State' } |
              Select-Object -First 1

if ($startupKey) {
    Write-Step "TaskId  : $($startupKey.PSChildName) (State = $((Get-ItemProperty $startupKey.PSPath).State))"
} else {
    Write-Warn 'No startup task state key found. Launch Wave Link once, then re-run.'
}

Write-Host ''

# ===========================================================================
# Removal path
# ===========================================================================

if ($Remove) {
    Write-Host 'Removing...' -ForegroundColor Cyan

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Ok "Unregistered task '$TaskName'"
    } else {
        Write-Step "Task '$TaskName' not present"
    }

    foreach ($f in @($Ps1Path, $VbsPath)) {
        if (Test-Path $f) {
            Remove-Item $f -Force
            Write-Ok "Deleted $f"
        }
    }

    if ($startupKey) {
        Set-ItemProperty -Path $startupKey.PSPath -Name 'State' -Value 2 -Type DWord
        Write-Ok 'Re-enabled native startup task (State = 2)'
        Write-Warn 'Confirm in Settings > Apps > Startup that Wave Link is toggled ON.'
    }

    Write-Host ''
    Write-Host 'Done.' -ForegroundColor Cyan
    Write-Host ''
    return
}

# ===========================================================================
# 1. Folder
# ===========================================================================

Write-Host 'Writing files...' -ForegroundColor Cyan

if (-not (Test-Path $ScriptDir)) {
    New-Item -Path $ScriptDir -ItemType Directory -Force | Out-Null
    Write-Ok "Created $ScriptDir"
} else {
    Write-Step "Folder exists: $ScriptDir"
}

# ===========================================================================
# 2. Worker script
# ===========================================================================

$worker = @'
# Start-WaveLink.ps1 - generated by Deploy-WaveLinkEarlyStart.ps1
# Activates Wave Link, waits for its window, then hides it to the tray.

$HideMode    = __HIDEMODE__
$ProcessName = 'Elgato.WaveLink'
$SettleMs    = 1200
$PollMs      = 300
$TimeoutSec  = 90
$LogPath     = Join-Path $env:TEMP 'wavelink-start.log'

$ErrorActionPreference = 'SilentlyContinue'

function Write-Log {
    param([string]$Message)
    try {
        Add-Content -Path $LogPath -Encoding UTF8 -Value (
            '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message)
    } catch { }
}

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class WL {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
}
"@

# SW_RESTORE = 9. If the window arrives iconic, un-minimize before hiding so the
# tray icon has a normal window to bring back.
function Hide-WaveWindow {
    param([IntPtr]$Handle)
    if ([WL]::IsIconic($Handle)) {
        Write-Log 'window iconic; restoring before hide'
        [void][WL]::ShowWindow($Handle, 9)
        Start-Sleep -Milliseconds 400
    }
    $r = [WL]::ShowWindow($Handle, $HideMode)
    Write-Log "ShowWindow($HideMode) returned $r"
}

Write-Log "--- start (HideMode=$HideMode) ---"

# Resolve the AppID at runtime so a reinstall or publisher-hash change does not
# break this script.
$pkg = Get-AppxPackage -Name 'Elgato.WaveLink' | Select-Object -First 1
if (-not $pkg) { Write-Log 'package not installed; aborting'; return }

$appId = (Get-StartApps | Where-Object { $_.AppID -like "$($pkg.PackageFamilyName)!*" } |
          Select-Object -First 1).AppID
if (-not $appId) { $appId = "$($pkg.PackageFamilyName)!App" }
Write-Log "resolved AppID: $appId"

# Already up with a visible window? Just hide it.
$existing = Get-Process -Name $ProcessName | Where-Object { $_.MainWindowHandle -ne 0 } |
            Select-Object -First 1
if ($existing) {
    Write-Log "already running, pid $($existing.Id)"
    Hide-WaveWindow -Handle $existing.MainWindowHandle
    Write-Log '--- done (pre-existing) ---'
    return
}

try {
    Start-Process "shell:AppsFolder\$appId"
    Write-Log 'activation sent'
} catch {
    Write-Log "activation FAILED: $($_.Exception.Message)"
    return
}

# MainWindowHandle stays 0 until a visible window exists.
$deadline = (Get-Date).AddSeconds($TimeoutSec)
do {
    Start-Sleep -Milliseconds $PollMs
    $p = Get-Process -Name $ProcessName | Where-Object { $_.MainWindowHandle -ne 0 } |
         Select-Object -First 1
} until ($p -or (Get-Date) -gt $deadline)

if (-not $p) {
    Write-Log "timed out after ${TimeoutSec}s with no visible window"
    Write-Log '--- done (timeout) ---'
    return
}

Write-Log "window found: pid $($p.Id), handle $($p.MainWindowHandle)"
Start-Sleep -Milliseconds $SettleMs
Hide-WaveWindow -Handle $p.MainWindowHandle

Start-Sleep -Milliseconds 500
Write-Log "post-hide MainWindowHandle = $((Get-Process -Id $p.Id).MainWindowHandle) (0 = hidden)"
Write-Log '--- done ---'
'@

$worker = $worker -replace '__HIDEMODE__', $HideMode
Set-Content -Path $Ps1Path -Value $worker -Encoding UTF8 -Force
Write-Ok "Wrote $Ps1Path"

# ===========================================================================
# 3. VBScript shim
# ===========================================================================
# wscript.exe has no console of its own, and Run(..., 0, False) starts PowerShell
# hidden. powershell.exe -WindowStyle Hidden cannot match this: the task host
# creates the console before PowerShell can hide it.

$vbs = @"
' Start-WaveLink.vbs - generated by Deploy-WaveLinkEarlyStart.ps1
Option Explicit
Dim sh, cmd
Set sh = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -NonInteractive -File ""$Ps1Path"""
sh.Run cmd, 0, False
Set sh = Nothing
"@

Set-Content -Path $VbsPath -Value $vbs -Encoding ASCII -Force
Write-Ok "Wrote $VbsPath"

Write-Host ''

# ===========================================================================
# 4. Disable the native startup task
# ===========================================================================

Write-Host 'Disabling native startup task...' -ForegroundColor Cyan

if ($startupKey) {
    $before = (Get-ItemProperty $startupKey.PSPath).State
    if ($before -eq 1 -or $before -eq 0) {
        Write-Ok "Already disabled (State = $before)"
    } else {
        # 1 = DisabledByUser
        Set-ItemProperty -Path $startupKey.PSPath -Name 'State' -Value 1 -Type DWord
        Start-Sleep -Milliseconds 300
        $after = (Get-ItemProperty $startupKey.PSPath).State
        if ($after -eq 1) {
            Write-Ok "State $before -> 1 (DisabledByUser)"
        } else {
            Write-Warn "Write did not stick (State still $after)."
            Write-Warn 'Toggle Wave Link OFF in Settings > Apps > Startup manually.'
        }
    }
} else {
    Write-Warn 'Startup task key not found; disable it in Settings > Apps > Startup.'
}

Write-Host ''

# ===========================================================================
# 5. Scheduled task
# ===========================================================================

Write-Host 'Registering scheduled task...' -ForegroundColor Cyan

$me = "$env:USERDOMAIN\$env:USERNAME"

$action = New-ScheduledTaskAction `
            -Execute "$env:SystemRoot\System32\wscript.exe" `
            -Argument "//B //Nologo `"$VbsPath`""

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $me
$trigger.Delay = $LogonDelay

$settings = New-ScheduledTaskSettingsSet `
                -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries `
                -StartWhenAvailable `
                -MultipleInstances IgnoreNew `
                -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
                -Hidden

# Limited + Interactive is required: the activation must land in the logged-on session.
$principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited

Register-ScheduledTask `
    -TaskName    $TaskName `
    -Action      $action `
    -Trigger     $trigger `
    -Settings    $settings `
    -Principal   $principal `
    -Description 'Launches Elgato Wave Link early at logon and hides its window to the tray.' `
    -Force | Out-Null

Write-Ok "Registered '$TaskName' (logon delay $LogonDelay)"

Write-Host ''
Write-Host 'Done.' -ForegroundColor Cyan
Write-Host ''
Write-Host '  Test it:  close Wave Link, then run' -ForegroundColor Gray
Write-Host "            Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Gray
Write-Host '  Log file: ' -NoNewline -ForegroundColor Gray
Write-Host (Join-Path $env:TEMP 'wavelink-start.log') -ForegroundColor Gray
Write-Host '  Undo:     re-run this script with -Remove' -ForegroundColor Gray
Write-Host ''
