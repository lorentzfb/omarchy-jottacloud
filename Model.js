// Pure helpers for the Jottoma plugin. No QML imports, so the Node tests
// in tests/ can load this file directly.
//
// Everything read from `jotta-cli status --json` is treated as untrusted:
// lengths are capped, numbers are validated, and collections are bounded.

var MAX_BACKUPS = 32
var MAX_TEXT = 160
var MAX_RAW_BYTES = 2 * 1024 * 1024

var GLYPH = {
  ok: String.fromCodePoint(0xF0160),        // nf-md-cloud_check
  uploading: String.fromCodePoint(0xF0167), // nf-md-cloud_upload
  scanning: String.fromCodePoint(0xF063F),  // nf-md-cloud_sync
  paused: String.fromCodePoint(0xF0164),    // nf-md-cloud_off_outline
  error: String.fromCodePoint(0xF09E0),     // nf-md-cloud_alert
  folder: String.fromCodePoint(0xF024B),    // nf-md-folder
  sync: String.fromCodePoint(0xF04E6),      // nf-md-sync
  scan: String.fromCodePoint(0xF0450),      // nf-md-refresh
  web: String.fromCodePoint(0xF059F),       // nf-md-web
  log: String.fromCodePoint(0xF0219)        // nf-md-file_document
}

function translator(tr) {
  return typeof tr === "function" ? tr : function(key, fallback) { return fallback !== undefined ? fallback : key }
}

function pluralTranslator(tn) {
  return typeof tn === "function" ? tn : function(key, count) { return key + ":" + count }
}

function formatter(fmt) {
  return typeof fmt === "function" ? fmt : function(v, d) { return d === undefined ? String(v) : Number(v).toFixed(d) }
}

// Strip control characters and anything markup-shaped, and bound length.
function cleanText(value, max) {
  var limit = max || MAX_TEXT
  var text = String(value === undefined || value === null ? "" : value)
  text = text.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/[<>]/g, "").replace(/\s+/g, " ").trim()
  if (text.length > limit) text = text.substring(0, limit - 1) + "…"
  return text
}

function num(value) {
  var n = Number(value)
  return isFinite(n) && n >= 0 ? n : 0
}

// jotta-cli mixes seconds and milliseconds. Accept either, return ms, and
// reject anything outside a sane window (2000–2200).
function toMs(value) {
  var n = Number(value)
  if (!isFinite(n) || n <= 0) return 0
  if (n < 1e11) n *= 1000
  if (n < 946684800000 || n > 7258118400000) return 0
  return n
}

function objectSize(value) {
  if (!value || typeof value !== "object") return 0
  if (Array.isArray(value)) return value.length
  return Object.keys(value).length
}

// Sum whatever progress numbers an in-flight transfer map exposes. The
// field names vary between jottad versions, so look for the common ones.
function transferProgress(map) {
  var result = { count: 0, doneBytes: 0, totalBytes: 0 }
  if (!map || typeof map !== "object") return result
  var keys = Object.keys(map)
  result.count = Math.min(keys.length, 100000)
  for (var i = 0; i < keys.length && i < 1000; i++) {
    var item = map[keys[i]]
    if (!item || typeof item !== "object") continue
    var total = num(item.TotalBytes || item.Bytes || (item.Total && item.Total.Bytes) || item.Size)
    var done = num(item.CompletedBytes || (item.Completed && item.Completed.Bytes) || item.Progress)
    if (total > 0) {
      result.totalBytes += total
      result.doneBytes += Math.min(done, total)
    }
  }
  return result
}

function emptyStatus() {
  return {
    ok: false,
    reachable: false,
    loggedIn: false,
    email: "",
    hostname: "",
    plan: "",
    usageBytes: 0,
    capacityBytes: -1,
    paused: false,
    resumeAtMs: 0,
    backupWorking: false,
    syncWorking: false,
    uploads: { count: 0, doneBytes: 0, totalBytes: 0 },
    backups: [],
    sync: null,
    totalErrors: 0,
    lastBackupMs: 0,
    nextBackupMs: 0
  }
}

function parseBackup(raw) {
  if (!raw || typeof raw !== "object") return null
  var path = cleanText(raw.Path, 512)
  var name = cleanText(raw.Name || path.split("/").pop() || "Backup", 80)
  var count = raw.Count || {}
  var history = Array.isArray(raw.History) ? raw.History : []
  var last = history.length > 0 ? history[history.length - 1] : null
  var lastEndedMs = 0
  for (var i = 0; i < history.length && i < 50; i++) {
    var h = history[i]
    if (h && h.Finished) lastEndedMs = Math.max(lastEndedMs, toMs(h.Ended))
  }
  var lastUpdateMs = toMs(raw.LastUpdateMS)
  var errorFiles = num(raw.ErrorFilesCount && typeof raw.ErrorFilesCount === "object"
    ? Object.keys(raw.ErrorFilesCount).reduce(function(s, k) { return s + num(raw.ErrorFilesCount[k]) }, 0)
    : raw.ErrorFilesCount)
  var errors = Math.max(objectSize(raw.Errors), errorFiles)
  var uploads = transferProgress(raw.Uploading)
  return {
    name: name,
    path: path,
    files: num(count.Files),
    bytes: num(count.Bytes),
    // "Up to date" time: the latest of a finished upload run or the last
    // scan that found nothing new.
    lastBackupMs: Math.max(lastEndedMs, lastUpdateMs),
    lastScanMs: toMs(raw.LastScanStartedMS),
    nextBackupMs: toMs(raw.NextBackupMS),
    lastUploadedFiles: last && last.Upload && last.Upload.Completed ? num(last.Upload.Completed.Files) : 0,
    lastUploadedBytes: last && last.Upload && last.Upload.Completed ? num(last.Upload.Completed.Bytes) : 0,
    errors: errors,
    uploads: uploads,
    paused: raw.Paused === true
  }
}

function parseSync(raw) {
  if (!raw || typeof raw !== "object" || raw.Enabled !== true) return null
  var count = raw.Count || {}
  var remote = raw.RemoteCount || {}
  return {
    name: "Sync",
    path: cleanText(raw.RootPath, 512),
    files: num(count.Files),
    bytes: num(count.Bytes),
    remoteFiles: num(remote.Files),
    remoteBytes: num(remote.Bytes),
    lastBackupMs: toMs(raw.LastUpdateMS),
    automatic: raw.Automatic === true,
    paused: raw.Paused === true
  }
}

function parseStatus(rawText) {
  var result = emptyStatus()
  var text = String(rawText || "")
  if (text.length > MAX_RAW_BYTES) return result
  text = text.trim()
  if (text === "") return result
  var data
  try { data = JSON.parse(text) } catch (e) { return result }
  if (!data || typeof data !== "object") return result

  result.ok = true
  result.reachable = true
  var user = data.User || {}
  var account = user.AccountInfo || {}
  result.loggedIn = !!user.Email
  result.email = cleanText(user.Email, 120)
  result.hostname = cleanText(user.Hostname || (user.device && user.device.Name), 80)
  result.plan = cleanText(account.ProductNameLocalized || account.SubscriptionNameLocalized, 80)
  result.usageBytes = num(account.Usage)
  var cap = Number(account.Capacity)
  result.capacityBytes = isFinite(cap) && cap > 0 ? cap : -1

  var state = data.State || {}
  result.paused = state.Paused === true
  result.resumeAtMs = toMs(state.ResumeAtMS)
  result.backupWorking = state.BackupWorking === true
  result.syncWorking = state.SyncWorking === true
  result.uploads = transferProgress(state.Uploading)

  var backupState = data.Backup && data.Backup.State ? data.Backup.State : {}
  var enabled = backupState.Enabled || backupState.Paused || null
  if (backupState.Paused && !backupState.Enabled) result.paused = true
  var list = enabled && Array.isArray(enabled.Backups) ? enabled.Backups : []
  for (var i = 0; i < list.length && result.backups.length < MAX_BACKUPS; i++) {
    var b = parseBackup(list[i])
    if (!b) continue
    result.backups.push(b)
    result.totalErrors += b.errors
    if (b.uploads.count > result.uploads.count) result.uploads = b.uploads
  }
  result.backups.sort(function(a, b) { return a.name.localeCompare(b.name) })
  result.sync = parseSync(data.Sync)

  // Overall "last backup" is the oldest folder's last success: the whole
  // set is only as fresh as its stalest member.
  var oldest = 0
  var next = 0
  for (var j = 0; j < result.backups.length; j++) {
    var item = result.backups[j]
    if (item.lastBackupMs > 0) oldest = oldest === 0 ? item.lastBackupMs : Math.min(oldest, item.lastBackupMs)
    if (item.nextBackupMs > 0) next = next === 0 ? item.nextBackupMs : Math.min(next, item.nextBackupMs)
  }
  result.lastBackupMs = oldest
  result.nextBackupMs = next
  return result
}

// One of: "offline", "loggedOut", "error", "paused", "uploading",
// "scanning", "stale", "ok". Drives the bar glyph and the hero line.
function overallState(status, nowMs, staleHours) {
  if (!status || !status.reachable) return "offline"
  if (!status.loggedIn) return "loggedOut"
  if (status.totalErrors > 0) return "error"
  if (status.paused) return "paused"
  if (status.uploads.count > 0) return "uploading"
  if (status.backupWorking) return "scanning"
  var staleMs = Math.max(1, Number(staleHours) || 48) * 3600 * 1000
  if (status.backups.length > 0 && (status.lastBackupMs === 0 || nowMs - status.lastBackupMs > staleMs)) return "stale"
  return "ok"
}

function stateGlyph(state) {
  switch (state) {
  case "uploading": return GLYPH.uploading
  case "scanning": return GLYPH.scanning
  case "paused": return GLYPH.paused
  case "offline":
  case "loggedOut":
  case "error":
  case "stale": return GLYPH.error
  default: return GLYPH.ok
  }
}

function isAlarming(state) {
  return state === "error" || state === "offline" || state === "loggedOut" || state === "stale"
}

function formatBytes(value, fmt) {
  var f = formatter(fmt)
  var amount = num(value)
  var units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
  var i = 0
  while (amount >= 1024 && i < units.length - 1) { amount /= 1024; i++ }
  var digits = i === 0 ? 0 : (amount >= 100 ? 0 : (amount >= 10 ? 1 : 2))
  return f(amount, digits) + " " + units[i]
}

// "just now", "5 min ago", "3 h ago", "2 days ago" — or the future
// equivalents with ago=false ("in 5 min").
function relativeTime(ms, nowMs, tr, tn, fmt) {
  var t = translator(tr)
  var n = pluralTranslator(tn)
  var f = formatter(fmt)
  if (!ms) return t("time.never", "never")
  var diff = nowMs - ms
  var future = diff < 0
  var abs = Math.abs(diff)
  var minutes = Math.round(abs / 60000)
  if (minutes < 1) return future ? t("time.soon", "soon") : t("time.justNow", "just now")
  var key
  var value
  if (minutes < 60) { key = "minutes"; value = minutes }
  else if (minutes < 60 * 36) { key = "hours"; value = Math.round(minutes / 60) }
  else { key = "days"; value = Math.round(minutes / 1440) }
  var s = String(n((future ? "time.in." : "time.ago.") + key, value))
  return s.replace("%1", f(value))
}

function usageFraction(status) {
  if (!status || status.capacityBytes <= 0) return -1
  return Math.max(0, Math.min(1, status.usageBytes / status.capacityBytes))
}

function progressFraction(uploads) {
  if (!uploads || uploads.totalBytes <= 0) return -1
  return Math.max(0, Math.min(1, uploads.doneBytes / uploads.totalBytes))
}

// --- Sync folder events (`jotta-cli sync log --watch`) ---------------------
//
// Lines look like
//   2026-01-20 20:10:22.566 +0100 CET :: DeleteFile /hello.txt
//   2026-01-20 20:10:22.6 +0100 CET :: Finished
// and may be prefixed with terminal escapes, so the match is unanchored.

var SYNC_LINE = /(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))? ([+-])(\d{2})(\d{2})\b.*? :: ([A-Za-z]{1,40})(?: (.*))?$/
var SYNC_NAMES = 3

function parseSyncLogLine(line) {
  var text = String(line === undefined || line === null ? "" : line)
  if (text.length > 8192) return null
  var m = SYNC_LINE.exec(text)
  if (!m) return null
  var frac = String(m[7] || "0")
  var ms = Number((frac + "00").substring(0, 3))
  var utc = Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6], ms)
  var offsetMin = (m[8] === "-" ? -1 : 1) * (+m[9] * 60 + +m[10])
  var ts = toMs(utc - offsetMin * 60000)
  if (!ts) return null
  return { ts: ts, action: m[11], path: cleanText(m[12] || "", 512) }
}

function syncKind(action) {
  var a = String(action)
  if (a === "Upload") return "uploaded"
  if (a === "Download") return "downloaded"
  if (/Delete|Remove/.test(a)) return "deleted"
  return "changed"
}

function newSyncBatch() {
  return { total: 0, counts: { uploaded: 0, downloaded: 0, deleted: 0, changed: 0 }, names: [] }
}

// Counts are unbounded integers; only the first few names are kept.
function addToSyncBatch(batch, event) {
  if (!batch || !event || event.action === "Finished") return batch
  batch.total++
  batch.counts[syncKind(event.action)]++
  if (batch.names.length < SYNC_NAMES) {
    var name = cleanText(String(event.path).split("/").pop() || event.path, 80)
    if (name) batch.names.push(name)
  }
  return batch
}

// { title, body } for one notification, or null when nothing happened.
function summarizeSyncBatch(batch, tr, tn) {
  if (!batch || batch.total <= 0) return null
  var t = translator(tr)
  var n = pluralTranslator(tn)
  var parts = []
  var kinds = ["uploaded", "downloaded", "deleted", "changed"]
  for (var i = 0; i < kinds.length; i++) {
    var c = batch.counts[kinds[i]]
    if (c > 0) parts.push(String(n("sync." + kinds[i], c)).replace("%1", String(c)))
  }
  var body = batch.names.join("\n")
  var rest = batch.total - batch.names.length
  if (rest > 0) body += (body ? "\n" : "") + String(n("sync.more", rest)).replace("%1", String(rest))
  return {
    title: String(t("sync.title", "Jottacloud sync")) + ": " + parts.join(", "),
    body: body
  }
}

// User config from ~/.config/jottoma/jottoma.toml. A small TOML subset:
// top-level `key = value` lines with "string", 'string', integer, or
// true/false values, plus # comments. Only known keys are kept; sections,
// unknown keys and lines that don't parse are ignored. The values still go
// through the same validation as host settings in Service.qml.
var CONFIG_KEYS = ["refreshIntervalSec", "staleHours", "pauseDuration", "notifySync"]
var MAX_CONFIG_BYTES = 64 * 1024

function parseConfig(text) {
  var result = {}
  var raw = String(text === undefined || text === null ? "" : text)
  if (raw.length > MAX_CONFIG_BYTES) return result
  var lines = raw.split(/\r?\n/)
  var inSection = false
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line || line.charAt(0) === "#") continue
    if (/^\[/.test(line)) { inSection = true; continue }
    if (inSection) continue
    var m = line.match(/^([A-Za-z][A-Za-z0-9_]{0,63})\s*=\s*("([^"\\]*)"|'([^']*)'|(-?[0-9]{1,9})|(true|false))\s*(#.*)?$/)
    if (!m || CONFIG_KEYS.indexOf(m[1]) < 0) continue
    var value
    if (m[3] !== undefined) value = cleanText(m[3])
    else if (m[4] !== undefined) value = cleanText(m[4])
    else if (m[5] !== undefined) value = parseInt(m[5], 10)
    else value = m[6] === "true"
    result[m[1]] = value
  }
  return result
}

// Notification text for a config reload: the keys the file sets, in
// CONFIG_KEYS order. `removed` means the file went away.
function summarizeConfig(config, tr, removed) {
  var t = translator(tr)
  if (removed) {
    return {
      title: String(t("config.removed", "Jottoma config removed")),
      body: String(t("config.usingBar", "Using bar settings"))
    }
  }
  var parts = []
  for (var i = 0; i < CONFIG_KEYS.length; i++) {
    var k = CONFIG_KEYS[i]
    if (!config || config[k] === undefined || config[k] === null) continue
    var v = config[k]
    parts.push(k + " = " + (typeof v === "string" ? '"' + v + '"' : String(v)))
  }
  return {
    title: String(t("config.reloaded", "Jottoma config reloaded")),
    body: parts.length ? parts.join(", ") : String(t("config.empty", "No settings in file; using bar settings"))
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    GLYPH: GLYPH,
    CONFIG_KEYS: CONFIG_KEYS,
    parseConfig: parseConfig,
    summarizeConfig: summarizeConfig,
    cleanText: cleanText,
    toMs: toMs,
    parseStatus: parseStatus,
    overallState: overallState,
    stateGlyph: stateGlyph,
    isAlarming: isAlarming,
    formatBytes: formatBytes,
    relativeTime: relativeTime,
    usageFraction: usageFraction,
    progressFraction: progressFraction,
    transferProgress: transferProgress,
    parseSyncLogLine: parseSyncLogLine,
    newSyncBatch: newSyncBatch,
    addToSyncBatch: addToSyncBatch,
    summarizeSyncBatch: summarizeSyncBatch
  }
}
