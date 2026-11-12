# Jottacloud Manager - A plugin for the Omarchy shell

Bar widget that visualizes [Jottacloud](https://www.jottacloud.com) backups using `jotta-cli status --json`.

**Bar icon** changes with the overall state: backed up, uploading, scanning, paused, or an alert when there are errors, the daemon is down, or a backup is overdue. Hover for a summary.

- Left click: open the panel
- Right click: scan now
- Middle click: pause or resume

**Panel**
- Hero with state, last backup and next scheduled run, plus a pause/resume switch
- Cloud storage used, with a split bar showing how backed-up bytes divide between folders (colours match the folder icons)
- A row per backup folder (and the sync folder), showing file count, size and last backup. A thin bar shows upload progress while transferring; otherwise it shows freshness, which drains toward the "Warn after" threshold.
- Keys: ↑/↓ move, Enter opens the folder, `p` pause/resume, `s` scan, `r` refresh, `w` open Jottacloud in the browser

**Sync notifications**: the widget runs `jotta-cli sync log --watch` and, each time jottad finishes syncing the sync folder, shows one desktop notification that summarizes the changes (for example, "Jottacloud sync: 3 downloaded, 1 deleted") and lists the first few file names. History that `--watch` replays at startup is ignored. If jottad restarts, the watcher reconnects with a backoff of up to 60 seconds.

**Settings** (`omarchy bar set lorentzfb.jottacloud <key> <value>`): `refreshIntervalSec` (60), `staleHours` (48), `pauseDuration` (`1h`), `notifySync` (`true`).

You can also set these keys in `~/.config/jottoma/jottoma.toml` (or under `$XDG_CONFIG_HOME`). Values in that file override `omarchy bar set`, and changes take effect immediately. Each time you save the file, a notification lists the values it now sets. Remove a key to fall back to the bar setting. The file supports top-level `key = value` lines with strings, integers and `true`/`false`, plus `#` comments. Unknown keys and `[sections]` are ignored.

```toml
refreshIntervalSec = 120
staleHours = 24
pauseDuration = "30m"
notifySync = false
```

Tests: `node tests/model.test.js`
