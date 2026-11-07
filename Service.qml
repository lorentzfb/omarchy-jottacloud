import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Polls `jotta-cli status --json` and runs the few control commands the
// panel offers. Every command is a fixed argv; nothing from jottad's output
// is ever interpolated into a command line except a backup path, which is
// passed as its own argv element (never through a shell).
Item {
  id: root

  property var settings: ({})

  // User config file, watched so edits apply live. Missing file = empty.
  readonly property string configPath: {
    var base = Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")
    return base + "/jottoma/jottoma.toml"
  }
  property var fileConfig: ({})
  // Set after the first load, so the startup load doesn't notify.
  property bool _configReady: false
  property bool _configRemoved: false

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.fileConfig = Model.parseConfig(text())
      if (root._configReady) { root._configRemoved = false; configNotify.restart() }
      root._configReady = true
    }
    // text() is stale inside the change signal; reload and parse in onLoaded.
    onFileChanged: reload()
    onLoadFailed: {
      root.fileConfig = ({})
      if (root._configReady) { root._configRemoved = true; configNotify.restart() }
      root._configReady = true
    }
  }

  // Editors often fire several change events per save; notify once.
  Timer {
    id: configNotify
    interval: 300
    onTriggered: root.notifyConfig()
  }

  function notifyConfig() {
    var note = Model.summarizeConfig(fileConfig, tr, _configRemoved)
    Quickshell.execDetached(["notify-send", "-a", "Jottacloud", "-i", "preferences-system", note.title, note.body])
  }
  property bool panelOpen: false

  property var status: Model.parseStatus("")
  property string lastError: ""
  property double now: Date.now()
  property double lastRefreshMs: 0

  readonly property int closedRefreshSec: intSetting("refreshIntervalSec", 60, 10, 3600)
  readonly property int openRefreshSec: 3
  readonly property int staleHours: intSetting("staleHours", 48, 1, 720)
  readonly property string pauseDuration: {
    var v = String(setting("pauseDuration", "1h"))
    return /^([0-9]{1,3}h)?([0-9]{1,3}m)?$/.test(v) && v !== "" ? v : "1h"
  }
  readonly property string state: Model.overallState(status, now, staleHours)
  readonly property bool busy: controlProcess.running
  readonly property bool installed: _installed

  property bool _installed: true

  // Translation functions from the panel (strings.t / strings.tn).
  property var tr: null
  property var tn: null

  // Sync-folder notifications: a long-lived `jotta-cli sync log --watch`.
  // Events are batched until jottad reports "Finished", then summarized in
  // a single notification.
  readonly property bool notifySync: {
    var v = setting("notifySync", true)
    return v === true || v === "true"
  }
  readonly property bool syncWatchWanted: notifySync && _installed
  property var _syncBatch: Model.newSyncBatch()
  property double _syncWatchStartMs: 0
  property int _syncBackoffSec: 5

  onSyncWatchWantedChanged: {
    if (syncWatchWanted) startSyncWatch()
    else { syncRestart.stop(); syncWatch.running = false; _syncBatch = Model.newSyncBatch() }
  }
  Component.onCompleted: if (syncWatchWanted) startSyncWatch()

  function startSyncWatch() {
    if (syncWatch.running || !syncWatchWanted) return
    // --watch replays recent history first; skip anything from before now.
    _syncWatchStartMs = Date.now() - 2000
    syncWatch.running = true
  }

  function onSyncLine(line) {
    var ev = Model.parseSyncLogLine(line)
    if (!ev || ev.ts < _syncWatchStartMs) return
    _syncBackoffSec = 5
    if (ev.action === "Finished") { flushSyncBatch(); return }
    Model.addToSyncBatch(_syncBatch, ev)
    syncFlush.restart()
  }

  function flushSyncBatch() {
    syncFlush.stop()
    var note = Model.summarizeSyncBatch(_syncBatch, tr, tn)
    _syncBatch = Model.newSyncBatch()
    if (!note) return
    var argv = ["notify-send", "-a", "Jottacloud", "-i", "folder-sync", note.title]
    if (note.body) argv.push(note.body)
    Quickshell.execDetached(argv)
    refresh()
  }

  // Precedence: ~/.config/jottoma/jottoma.toml, then host settings
  // (`omarchy bar set`), then the built-in fallback.
  function setting(name, fallback) {
    var value = fileConfig ? fileConfig[name] : undefined
    if (value === undefined || value === null) value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function refresh() {
    now = Date.now()
    if (statusProcess.running) return
    statusProcess.running = true
  }

  function runControl(args) {
    if (controlProcess.running || !_installed) return
    controlProcess.command = ["jotta-cli"].concat(args)
    controlProcess.running = true
  }

  function pause() { runControl(["pause", pauseDuration]) }
  function resume() { runControl(["resume"]) }
  function togglePause() { status.paused ? resume() : pause() }
  function scan() { runControl(["scan"]) }

  function openWeb() { Quickshell.execDetached(["jotta-cli", "web"]) }

  function openFolder(path) {
    var p = String(path || "")
    if (p === "" || p.charAt(0) !== "/") return
    Quickshell.execDetached(["xdg-open", p])
  }

  Timer {
    interval: (root.panelOpen ? root.openRefreshSec : root.closedRefreshSec) * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Keeps "5 min ago" labels ticking between polls without re-running the CLI.
  Timer {
    interval: 30000
    repeat: true
    running: true
    onTriggered: root.now = Date.now()
  }

  Timer {
    id: settle
    property int ticks: 0
    interval: 1200
    repeat: true
    onTriggered: {
      root.refresh()
      if (++ticks >= 3) { ticks = 0; running = false }
    }
  }

  Process {
    id: statusProcess
    command: ["jotta-cli", "status", "--json"]
    stdout: StdioCollector { id: statusOut }
    stderr: StdioCollector { id: statusErr }
    onExited: function(exitCode) {
      root.now = Date.now()
      root.lastRefreshMs = root.now
      if (exitCode === 0) {
        var parsed = Model.parseStatus(statusOut.text)
        root.status = parsed
        root.lastError = parsed.ok ? "" : "Could not read jotta-cli output"
      } else {
        root.status = Model.parseStatus("")
        root.lastError = Model.cleanText(statusErr.text || statusOut.text || "jottad is not responding", 200)
      }
    }
  }

  Process {
    command: ["sh", "-c", "command -v jotta-cli >/dev/null"]
    running: true
    onExited: function(exitCode) { root._installed = exitCode === 0 }
  }

  Process {
    id: syncWatch
    command: ["jotta-cli", "sync", "log", "--watch"]
    stdout: SplitParser { onRead: function(line) { root.onSyncLine(line) } }
    onExited: {
      root.flushSyncBatch()
      if (!root.syncWatchWanted) return
      syncRestart.interval = root._syncBackoffSec * 1000
      root._syncBackoffSec = Math.min(60, root._syncBackoffSec * 2)
      syncRestart.restart()
    }
  }

  // Reconnect after jottad restarts or the watch otherwise ends.
  Timer {
    id: syncRestart
    onTriggered: root.startSyncWatch()
  }

  // Fallback in case a batch never gets its "Finished" line.
  Timer {
    id: syncFlush
    interval: 10000
    onTriggered: root.flushSyncBatch()
  }

  Process {
    id: controlProcess
    command: []
    stderr: StdioCollector { id: controlErr }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.lastError = Model.cleanText(controlErr.text || "jotta-cli command failed", 200)
      settle.ticks = 0
      settle.restart()
      root.refresh()
    }
  }
}
