<#
.SYNOPSIS
    Deploys a scheduled task that silently removes the OPENVPN-GUI HKCU Run key at every user logon.

.DESCRIPTION
    Designed for Intune > Devices > Scripts and remediations > Platform scripts.
    Run this script using the logged-on credentials: NO
    Enforce script signature check: NO
    Run script in 64-bit PowerShell host: YES

    The script lays down two files in C:\ProgramData\IntuneScripts\:
      1. Remove-OpenVPNGUIRunKey.ps1 - the worker that deletes the registry value.
      2. Remove-OpenVPNGUIRunKey.vbs - a launcher that invokes the .ps1 with a fully
         hidden window. Using wscript.exe + WScript.Shell.Run(..., 0, ...) prevents
         the brief console flash that powershell.exe -WindowStyle Hidden can produce.

    Then it registers a scheduled task that runs the .vbs at every user logon.

    The task is registered against the BUILTIN\Users group (SID S-1-5-32-545) so it
    executes in the context of whichever user just logged on, giving the worker
    script access to the correct HKCU hive.
#>

$ErrorActionPreference = 'Stop'

# --- Paths ---
$scriptDir = 'C:\ProgramData\IntuneScripts'
$ps1Path   = Join-Path $scriptDir 'Remove-OpenVPNGUIRunKey.ps1'
$vbsPath   = Join-Path $scriptDir 'Remove-OpenVPNGUIRunKey.vbs'
$taskName  = 'Remove-OpenVPNGUIRunKey'

if (-not (Test-Path $scriptDir)) {
    New-Item -Path $scriptDir -ItemType Directory -Force | Out-Null
}

# --- Worker PowerShell script (runs at each user logon) ---
$workerScript = @'
$ErrorActionPreference = 'SilentlyContinue'
$runKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$valName = 'OPENVPN-GUI'

try {
    $props = Get-ItemProperty -Path $runKey -ErrorAction Stop
    if ($null -ne $props.PSObject.Properties[$valName]) {
        Remove-ItemProperty -Path $runKey -Name $valName -Force -ErrorAction Stop
    }
} catch {
    # Silent failure by design - no user-visible output.
}
'@

Set-Content -Path $ps1Path -Value $workerScript -Encoding UTF8 -Force

# --- VBScript launcher (zero visible window) ---
# WScript.Shell.Run intWindowStyle 0 = hidden. wscript.exe itself has no console,
# so PowerShell launches without ever creating a visible conhost window.
$vbsScript = @"
Set objShell = CreateObject("WScript.Shell")
objShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -NonInteractive -File ""$ps1Path""", 0, False
Set objShell = Nothing
"@

Set-Content -Path $vbsPath -Value $vbsScript -Encoding ASCII -Force

# --- Build the scheduled task ---
$wscriptExe  = "$env:SystemRoot\System32\wscript.exe"
$wscriptArgs = "//B //Nologo `"$vbsPath`""   # //B = batch mode (suppresses errors/prompts), //Nologo = no banner

$action    = New-ScheduledTaskAction -Execute $wscriptExe -Argument $wscriptArgs
$trigger   = New-ScheduledTaskTrigger -AtLogOn
# Group principal => task runs as whichever user just logged on, in their own context (HKCU).
$principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited  # BUILTIN\Users
$settings  = New-ScheduledTaskSettingsSet `
                -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries `
                -StartWhenAvailable `
                -MultipleInstances IgnoreNew `
                -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
                -Hidden

# Remove any prior version, then register fresh.
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

Register-ScheduledTask `
    -TaskName    $taskName `
    -Action      $action `
    -Trigger     $trigger `
    -Principal   $principal `
    -Settings    $settings `
    -Description 'Silently removes the OPENVPN-GUI HKCU Run autostart entry at user logon. Deployed via Intune.' | Out-Null

Write-Output "Scheduled task '$taskName' registered successfully."
exit 0
