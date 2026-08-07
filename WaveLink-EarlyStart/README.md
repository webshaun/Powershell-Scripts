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
