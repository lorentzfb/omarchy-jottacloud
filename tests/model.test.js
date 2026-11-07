// Run with: node tests/model.test.js
const assert = require("assert")
const fs = require("fs")
const path = require("path")
const M = require("../Model.js")

const fixture = fs.readFileSync(path.join(__dirname, "fixture-status.json"), "utf8")
const s = M.parseStatus(fixture)
assert.ok(s.ok && s.reachable && s.loggedIn)
assert.ok(s.backups.length >= 1)
assert.ok(s.backups[0].files > 0 && s.backups[0].bytes > 0)
assert.ok(s.backups[0].lastBackupMs > 0)
assert.ok(s.sync && s.sync.path === "/home/user/jottasync")
assert.strictEqual(s.capacityBytes, -1) // unlimited plan

// Unreachable daemon / garbage output.
assert.strictEqual(M.overallState(M.parseStatus(""), Date.now(), 48), "offline")
assert.strictEqual(M.parseStatus("not json").ok, false)
assert.strictEqual(M.parseStatus("x".repeat(3 * 1024 * 1024)).ok, false)

// Markup-shaped and control-character input is neutralized and bounded.
const evil = JSON.parse(fixture)
evil.Backup.State.Enabled.Backups[0].Name = '<img src="https://example.invalid/t">\u0007Pics'
evil.User.Email = "a".repeat(500)
const e = M.parseStatus(JSON.stringify(evil))
assert.ok(!/[<>\u0007]/.test(e.backups[0].name))
assert.ok(e.email.length <= 120)

// State derivation.
const now = s.lastBackupMs + 60 * 1000
assert.strictEqual(M.overallState(s, now, 48), s.backupWorking ? "scanning" : "ok")
assert.strictEqual(M.overallState(s, s.lastBackupMs + 49 * 3600 * 1000, 48), s.backupWorking ? "scanning" : "stale")
const paused = Object.assign({}, s, { paused: true })
assert.strictEqual(M.overallState(paused, now, 48), "paused")
const failing = Object.assign({}, s, { totalErrors: 3 })
assert.strictEqual(M.overallState(failing, now, 48), "error")

// Uploads with progress fields.
const up = M.transferProgress({ a: { TotalBytes: 100, CompletedBytes: 25 }, b: { TotalBytes: 100, CompletedBytes: 75 } })
assert.strictEqual(up.count, 2)
assert.strictEqual(M.progressFraction(up), 0.5)

// Timestamps: seconds and ms both accepted; nonsense rejected.
assert.strictEqual(M.toMs(1793914675), 1793914675000)
assert.strictEqual(M.toMs(1793914675000), 1793914675000)
assert.strictEqual(M.toMs(-5), 0)
assert.strictEqual(M.toMs(1e20), 0)

assert.strictEqual(M.formatBytes(1536), "1.50 KiB")
const tn = (k, n) => ({ "time.ago.minutes": "%1 min ago", "time.in.hours": "in %1 h" })[k]
assert.strictEqual(M.relativeTime(1000 - 5 * 60000, 1000, null, tn), "5 min ago")
assert.strictEqual(M.relativeTime(1000 + 2 * 3600000, 1000, null, tn), "in 2 h")

// Sync log lines (`jotta-cli sync log --watch`).
const del = M.parseSyncLogLine("2026-01-20 20:10:22.566 +0100 CET :: DeleteFile /hello.txt")
assert.deepStrictEqual(del, { ts: Date.UTC(2026, 0, 20, 19, 10, 22, 566), action: "DeleteFile", path: "/hello.txt" })
const fin = M.parseSyncLogLine("\u001b[?25h2026-01-20 20:10:22.6 +0100 CET :: Finished ")
assert.strictEqual(fin.action, "Finished")
assert.strictEqual(fin.path, "")
assert.strictEqual(fin.ts, Date.UTC(2026, 0, 20, 19, 10, 22, 600))
assert.strictEqual(M.parseSyncLogLine("garbage"), null)
assert.strictEqual(M.parseSyncLogLine(""), null)
assert.strictEqual(M.parseSyncLogLine("2026-01-20 20:10:22 +0100 CET :: Rm; /x"), null)
const nasty = M.parseSyncLogLine("2026-01-20 20:10:22 -0500 EST :: Upload /a/<b>\u0007" + "x".repeat(2000))
assert.strictEqual(nasty.ts, Date.UTC(2026, 0, 21, 1, 10, 22))
assert.ok(!/[<>\u0007]/.test(nasty.path) && nasty.path.length <= 512)

// Batching and summary.
const tnSync = (k, n) => ({ "sync.uploaded": "%1 uploaded", "sync.downloaded": "%1 downloaded",
  "sync.deleted": "%1 deleted", "sync.changed": "%1 changed", "sync.more": "and %1 more" })[k]
assert.strictEqual(M.summarizeSyncBatch(M.newSyncBatch(), null, tnSync), null)
const batch = M.newSyncBatch()
;["Download /a/one.md", "Download /two.md", "Upload /x/three.txt", "DeleteFile /four", "Download /five", "Finished "]
  .forEach(s => M.addToSyncBatch(batch, M.parseSyncLogLine("2026-01-20 20:10:22 +0100 CET :: " + s)))
assert.strictEqual(batch.total, 5)
const note = M.summarizeSyncBatch(batch, null, tnSync)
assert.strictEqual(note.title, "Jottacloud sync: 1 uploaded, 3 downloaded, 1 deleted")
assert.strictEqual(note.body, "one.md\ntwo.md\nthree.txt\nand 2 more")

// User config (TOML subset).
assert.deepStrictEqual(M.parseConfig(""), {})
assert.deepStrictEqual(M.parseConfig(null), {})
assert.deepStrictEqual(M.parseConfig([
  "# Jottoma config",
  "",
  "refreshIntervalSec = 120   # two minutes",
  "staleHours=24",
  'pauseDuration = "30m"',
  "notifySync = false",
  "unknownKey = 5",
  "garbage line",
  "staleHours = [1, 2]"
].join("\r\n")), { refreshIntervalSec: 120, staleHours: 24, pauseDuration: "30m", notifySync: false })
assert.deepStrictEqual(M.parseConfig("pauseDuration = '1h'\nnotifySync = true"), { pauseDuration: "1h", notifySync: true })
// Keys after a section header belong to that section, not to us.
assert.deepStrictEqual(M.parseConfig("staleHours = 6\n[other]\nrefreshIntervalSec = 10"), { staleHours: 6 })
// Strings are sanitized; unterminated quotes and oversize input are rejected.
assert.strictEqual(M.parseConfig('pauseDuration = "<b>1h</b>"').pauseDuration, "b1h/b")
assert.deepStrictEqual(M.parseConfig('pauseDuration = "1h'), {})
assert.deepStrictEqual(M.parseConfig("staleHours = 6\n" + "#".repeat(70 * 1024)), {})

// Config reload notification.
assert.deepStrictEqual(M.summarizeConfig({ notifySync: false, refreshIntervalSec: 120, pauseDuration: "30m" }), {
  title: "Jottoma config reloaded",
  body: 'refreshIntervalSec = 120, pauseDuration = "30m", notifySync = false'
})
assert.strictEqual(M.summarizeConfig({}).body, "No settings in file; using bar settings")
assert.deepStrictEqual(M.summarizeConfig({ staleHours: 6 }, null, true), { title: "Jottoma config removed", body: "Using bar settings" })

console.log("model tests passed")
