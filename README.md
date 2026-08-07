# Powershell-Scripts

Windows automation and endpoint utility scripts.

Each project lives in its own folder with everything it needs. Scripts are
written for Windows PowerShell 5.1 unless noted otherwise.

| Project | What it does |
| --- | --- |
| [WaveLink-EarlyStart](#wavelink-earlystart) | Makes Elgato Wave Link 3 launch early at logon, hidden |
| [OpenVPNGUI-RunKeyRemoval](#openvpngui-runkeyremoval) | Strips the OpenVPN GUI autostart entry at every user logon |

---

## WaveLink-EarlyStart

Makes Elgato Wave Link 3 launch early at logon instead of last, without the
main window flashing up on screen.

### The problem

Wave Link 3 is an MSIX-packaged app. It registers its autostart through a
`windows.startupTask` extension in its `AppxManifest.xml`, which Windows
manages through AppModel/StateRepository rather than the classic autostart
locations — so it appears in none of the usual places:

- `HKCU\...\CurrentVersion\Run` / `HKLM\...\CurrentVersion\Run` (32- and 64-bit)
- The user or system Startup folders
- Task Scheduler

Windows deliberately runs AppModel startup tasks **last** in the logon chain,
which is why Wave Link takes so long to appear and why audio routing isn't ready
when you need it.

The obvious fix — disable the native startup task, substitute your own scheduled
task — has a catch. Wave Link's "start minimized to tray" behavior is tied to the
`StartupTask` activation kind, which Windows only sends when launching through the
registered startup task. A custom scheduled task produces a plain `Launch`
activation, so the window opens visibly. There is no runtime silent or quiet
launch argument; the only silent switches Elgato ships are installer-time.

### The approach

Register a logon-triggered scheduled task that fires early, then hide the window
manually after activation rather than relying on Wave Link to start hidden.

`Deploy-WaveLinkEarlyStart.ps1` writes two files to `%LOCALAPPDATA%\Scripts\`:

| File | Purpose |
| --- | --- |
| `Start-WaveLink.ps1` | Activates Wave Link, waits for its window, hides it |
| `Start-WaveLink.vbs` | Launches the `.ps1` with no console window |

It then disables Wave Link's native startup task and registers the logon task.

The package family name and startup task GUID are **discovered at runtime**
rather than hardcoded, so the setup survives Elgato changing their publisher
hash on a future release.

### Usage

Run `Run-Deploy-WaveLinkEarlyStart.cmd`, or call the script directly:

```powershell
.\Deploy-WaveLinkEarlyStart.ps1
```

To tear everything down — unregister the task, delete both generated files, and
re-enable the native startup task:

```powershell
.\Deploy-WaveLinkEarlyStart.ps1 -Remove
```

### Requirements

- Elgato Wave Link 3 installed for the current user
- Wave Link launched at least once, so its startup task state key exists
- Windows PowerShell 5.1

### Run unelevated

**Do not run this as administrator.** A packaged app activated from an elevated
context will not land in your interactive session. Run it as your normal user.

### Notes

The deployer disables the native startup task by writing `State = 1` to the
AppModel state key. That key mirrors StateRepository, so the write may not
persist. The script verifies afterward and reports either way — if it didn't
stick, toggle Wave Link off manually under **Settings → Apps → Startup**.

Configuration values sit in a block at the top of the deployer if you want to
change paths or the task name.

---

## OpenVPNGUI-RunKeyRemoval

Stops OpenVPN GUI from launching itself at every user logon, and keeps it
stopped — across profile creations, client upgrades, and users who flip the
setting back on. Built for Intune platform script deployment.

### The problem

OpenVPN GUI autostarts from the per-user Run key
(`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, value `OPENVPN-GUI`),
which makes a one-shot cleanup unreliable on a managed fleet. The value is
per-profile, so removing it for one user does nothing for the next person who
signs in. It gets recreated by client upgrades and by the GUI's own
launch-at-logon toggle. And an Intune platform script only runs once — it won't
re-run to remove a value that reappears a month later.

Blocking the client outright isn't the goal. Users still need to launch OpenVPN
GUI on demand; it just shouldn't connect on its own at every logon.

### The approach

Deploy once in SYSTEM context, and leave behind a logon-triggered scheduled task
that handles the removal from then on.

`Deploy-RemoveOpenVPNGUIRunKey.ps1` writes two files to
`C:\ProgramData\IntuneScripts\`:

| File | Purpose |
| --- | --- |
| `Remove-OpenVPNGUIRunKey.ps1` | Deletes the `OPENVPN-GUI` value from the current user's Run key |
| `Remove-OpenVPNGUIRunKey.vbs` | Launches the `.ps1` with no visible window |

The task is registered against **`BUILTIN\Users` (S-1-5-32-545)** rather than a
specific user, so it runs in the context of whoever just logged on — which is
what makes `HKCU:` point at the right hive. A SYSTEM-context task would edit
SYSTEM's own Run key and accomplish nothing.

The VBS launcher is there to eliminate the console flash: `powershell.exe
-WindowStyle Hidden` still creates and destroys a conhost window, which reads as
a black flicker at logon. `wscript.exe` has no console of its own, so nothing
ever paints.

### Usage

Deploy via **Intune → Devices → Scripts and remediations → Platform scripts**:

| Setting | Value |
| --- | --- |
| Run this script using the logged-on credentials | **No** |
| Enforce script signature check | **No** |
| Run script in 64-bit PowerShell host | **Yes** |

Logged-on credentials must be **No** — the deployer needs SYSTEM or admin rights
to write to `C:\ProgramData` and register the task. The user-context work is
done by the task it leaves behind.

Re-running is safe; the script unregisters any prior task of the same name
before registering fresh.

Teardown, from an elevated session:

```powershell
Unregister-ScheduledTask -TaskName 'Remove-OpenVPNGUIRunKey' -Confirm:$false
Remove-Item 'C:\ProgramData\IntuneScripts\Remove-OpenVPNGUIRunKey.*' -Force
```

### Requirements

- Windows PowerShell 5.1
- SYSTEM or local administrator rights to deploy

### Notes

Removal happens at logon. If the value is written back mid-session, it stays
until the next logon, then gets stripped before OpenVPN GUI can act on it.

The task is registered hidden — enable **View → Show Hidden Tasks** in Task
Scheduler to see it, or use `Get-ScheduledTask`, which lists it regardless.

Full details, verification commands, and troubleshooting notes are in
[`OpenVPNGUI-RunKeyRemoval/README.md`](OpenVPNGUI-RunKeyRemoval/README.md).
