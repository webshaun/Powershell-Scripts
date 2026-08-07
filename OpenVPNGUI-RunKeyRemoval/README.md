# OpenVPNGUI-RunKeyRemoval

Stops OpenVPN GUI from launching itself at every user logon, and keeps it
stopped — across profile creations, client upgrades, and users who flip the
setting back on.

### The problem

OpenVPN GUI autostarts by writing an `OPENVPN-GUI` value into the per-user Run
key:

```
HKCU\Software\Microsoft\Windows\CurrentVersion\Run
```

That location makes a one-shot cleanup unreliable on a managed fleet, for three
reasons:

- **It's per-profile.** Deleting it for one user does nothing for the next
  person who logs on to that machine, or for a profile created later.
- **It comes back.** Client upgrades and reinstalls re-apply the launch-at-logon
  behavior, and the GUI's own settings expose a toggle that recreates the value.
- **Intune platform scripts don't repeat.** A platform script runs once per
  device (or once per user, in user context) and won't run again unless the
  script content changes — so it can't be relied on to re-remove a value that
  reappears weeks later.

Blocking the client outright isn't the goal either. Users still need to launch
OpenVPN GUI on demand; it just shouldn't sit in the tray connecting on its own
at every logon.

### The approach

Deploy once from Intune in SYSTEM context, and leave behind a logon-triggered
scheduled task that does the removal from then on.

`Deploy-RemoveOpenVPNGUIRunKey.ps1` writes two files to
`C:\ProgramData\IntuneScripts\`:

| File | Purpose |
| --- | --- |
| `Remove-OpenVPNGUIRunKey.ps1` | Deletes the `OPENVPN-GUI` value from the current user's Run key |
| `Remove-OpenVPNGUIRunKey.vbs` | Launches the `.ps1` with no visible window |

It then registers a scheduled task, `Remove-OpenVPNGUIRunKey`, triggered
`-AtLogOn`.

Two details carry most of the design:

**The task uses a group principal, not a user principal.** It's registered
against `BUILTIN\Users` (SID `S-1-5-32-545`) with `-RunLevel Limited`, so it
fires in the context of whichever user just logged on. That's what makes `HKCU:`
resolve to the right hive — a SYSTEM-context task would edit SYSTEM's own Run
key and accomplish nothing. Limited run level also means no elevation and no UAC
prompt, which is fine here: the Run key is user-writable.

**The VBS launcher exists to kill the console flash.** `powershell.exe
-WindowStyle Hidden` still creates a conhost window and tears it down, which
reads as a black flicker at logon — exactly the kind of thing that generates
help desk tickets. `wscript.exe` has no console of its own, and
`WScript.Shell.Run(..., 0, False)` starts PowerShell already hidden, so nothing
ever paints to the screen. The task calls it with `//B //Nologo` to suppress the
script host banner and any error dialogs.

The worker itself is deliberately quiet — `$ErrorActionPreference =
'SilentlyContinue'` and a `try`/`catch` that swallows failures. If the Run key
or the value doesn't exist, that's the desired end state anyway, and there's
nothing useful to surface to a user mid-logon.

### Usage

Deploy through **Intune → Devices → Scripts and remediations → Platform
scripts**, using these settings:

| Setting | Value |
| --- | --- |
| Run this script using the logged-on credentials | **No** |
| Enforce script signature check | **No** |
| Run script in 64-bit PowerShell host | **Yes** |

Logged-on credentials must be **No** — the deployer needs to write to
`C:\ProgramData` and register a task with a group principal, both of which
require SYSTEM or local admin. The user-context work is handled by the task it
leaves behind, not by the deployer.

To run it manually for testing, launch an elevated PowerShell session:

```powershell
.\Deploy-RemoveOpenVPNGUIRunKey.ps1
```

The script is idempotent. It unregisters any existing task of the same name
before registering a fresh one, so re-running it is safe.

### Verify

Confirm the task registered:

```powershell
Get-ScheduledTask -TaskName 'Remove-OpenVPNGUIRunKey' | Format-List TaskName, State
```

Confirm the value is gone for the current user:

```powershell
Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' |
    Select-Object -ExpandProperty 'OPENVPN-GUI' -ErrorAction SilentlyContinue
```

No output means no autostart entry.

To exercise the task without logging out, run it on demand from a user session:

```powershell
Start-ScheduledTask -TaskName 'Remove-OpenVPNGUIRunKey'
```

### Removal

There's no `-Remove` switch on this deployer. Tear it down from an elevated
session:

```powershell
Unregister-ScheduledTask -TaskName 'Remove-OpenVPNGUIRunKey' -Confirm:$false
Remove-Item 'C:\ProgramData\IntuneScripts\Remove-OpenVPNGUIRunKey.ps1' -Force
Remove-Item 'C:\ProgramData\IntuneScripts\Remove-OpenVPNGUIRunKey.vbs' -Force
```

Removing the task does not restore the Run value. If a machine needs autostart
back, re-enable it from OpenVPN GUI's own settings, or recreate the value.

### Requirements

- Windows PowerShell 5.1
- SYSTEM or local administrator rights to deploy
- Intune platform script deployment, or any other tool that can run a script
  elevated once per device

### Notes

**Timing.** The task removes the value at logon. If something writes it back
mid-session — a client upgrade, or a user toggling launch-at-logon in the GUI —
it stays until the next logon, at which point it's stripped again before
OpenVPN GUI can act on it.

**The task is hidden.** `New-ScheduledTaskSettingsSet -Hidden` keeps it out of
the default Task Scheduler view. To see it in the console, enable
**View → Show Hidden Tasks**. `Get-ScheduledTask` lists it regardless.

**Encodings differ between the two generated files, on purpose.** The worker
`.ps1` is written UTF-8 (with BOM, which is what `Set-Content -Encoding UTF8`
produces on PowerShell 5.1) — PowerShell reads that cleanly. The `.vbs` is
written ASCII, because a BOM at the top of a script file can confuse the Windows
Script Host.

**Scope.** This removes exactly one Run value for the logged-on user. It doesn't
uninstall OpenVPN GUI, touch the OpenVPN service, alter connection profiles, or
prevent manual launch.

Paths and the task name sit in a configuration block near the top of the
deployer if you need to change them. Adapting it to strip a different Run value
is a two-line edit — `$valName` in the worker and the task name.
