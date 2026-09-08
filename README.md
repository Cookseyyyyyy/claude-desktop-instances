# claude-desktop-instances

Spin up additional Claude Desktop windows, each with its own isolated profile but sharing your MCP config and authentication.

## How it works

Claude Desktop is built on Electron and accepts `--user-data-dir` to run from a separate profile directory. This repo manages those directories under `%APPDATA%\Claude-instances\instance-N\`, each cloned from your base profile so it inherits your auth and MCP servers.

Your base profile (`%APPDATA%\Claude`) is never modified.

## Launch behaviour

| Situation | What happens |
|---|---|
| Nothing running | Opens the persistent **core** instance (`instance-1`) |
| Claude already running | Creates a brand new **ephemeral** instance and opens it |

Ephemeral instances are never reused — each press gives you a clean window. They accumulate on disk, so run `-Cleanup` occasionally.

## Usage

**Open an instance (most common)** — this is what the taskbar shortcut runs:

```powershell
.\launch-claude.ps1
# or double-click launch.bat
```

**List instances and their running state:**

```powershell
.\launch-claude.ps1 -List
```

**Delete stopped ephemeral instances** (keeps the core one):

```powershell
.\launch-claude.ps1 -Cleanup
```

**Sync MCP config to all instances** after editing `claude_desktop_config.json`:

```powershell
.\launch-claude.ps1 -SyncConfig
```

**Repair login** after a Claude update breaks auth in existing instances:

```powershell
.\launch-claude.ps1 -FixAuth
```

**Force a specific instance number:**

```powershell
.\launch-claude.ps1 -Instance 3
```

## Taskbar shortcut

```powershell
.\create-shortcut.ps1
```

Creates "Launch Claude" on the Desktop with the Claude icon; right-click it and choose **Pin to taskbar**. Re-run this if you move the repo.

## What gets copied into a new instance

| Item | Purpose |
|------|---------|
| `claude_desktop_config.json` | MCP servers |
| `config.json` | Auth token + preferences |
| `ant-device-registry.json` | Device identity (current format) |
| `ant-did` | Device identity (legacy, pre-Aug 2026) |
| `Local State` | Chromium key that decrypts cookies |
| `Preferences` | Window/app settings |
| `git-worktrees.json` | Worktree config |
| `Local Storage/` | Auth state |
| `Network/` | Session cookies |
| `Partitions/` | Auth cookies for Claude's web partitions |
| `IndexedDB/`, `Session Storage/` | App/session data |

Cache directories are skipped — Claude regenerates them, and copying them added over a minute to launch time.

## The cookie problem and the auth seed

New instances need the base profile's session cookies or they open on a login screen. But Chromium holds `Network\Cookies` open exclusively, so those files cannot be copied while the original Claude app is running.

To handle this the script keeps a snapshot at `%APPDATA%\Claude-instances\_seed`:

- Every launch refreshes the seed, but **only** while the base profile is closed, so a good snapshot is never overwritten with a partial one.
- When creating an instance, any file locked in the base profile is sourced from the newest unlocked profile — a stopped instance, or the seed.
- `_seed` is not an instance, so `-List` ignores it and `-Cleanup` never deletes it.

Recoveries are recorded in `launch-claude.log`, naming the file and where it came from.

If new windows start landing on a login screen again, fully quit Claude from the system tray and launch once through the script. That refreshes the seed with current cookies.

## Troubleshooting

**Nothing happens when I click the shortcut.** The shortcut runs hidden, so check `launch-claude.log` in this folder — every failure is logged there, and a popup should also appear.

**A new instance shows a login screen.** The auth seed is stale or missing. Fully quit Claude from the system tray, then launch once through the script — that captures a fresh seed while the cookie files are unlocked. Check `launch-claude.log` to confirm the seed refreshed.

**`-Cleanup` says instances are still running after I closed the windows.** Claude keeps background processes alive in the system tray. Right-click the tray icon and choose Quit, then re-run.

## Notes

- Instances live in `%APPDATA%\Claude-instances\`. Deleting a folder resets that instance.
- The exe path resolves from `%LOCALAPPDATA%\AnthropicClaude\claude.exe`. If a Claude update moves it, edit `$ClaudeExe` at the top of `launch-claude.ps1`.
