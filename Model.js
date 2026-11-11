.pragma library

// Pure logic for the bujo widget. No Qt types, no side effects, no clock and no
// randomness — every function that could get a date or a count wrong lives here
// so `node --test` can reach it (see tests/Model.test.js). The QML half only
// binds and renders.
//
// The date helpers in the first section are adapted from Omarchy's own clock
// panel (shell/plugins/panels/clock/Model.js), which already solved week starts
// and ISO week numbering correctly. The "yyyy-MM-dd" string it uses as a day
// identity is this plugin's storage key.

// ---------------------------------------------------------------------------
// Day keys
//
// A key is the calendar day as the user sees it, not an instant. It is built
// from local Y/M/D and never round-tripped through UTC, because "what day is
// this task on" must not shift when the user is west of Greenwich in the
// evening.

function pad2(value) {
  var n = Number(value)
  return (n < 10 ? "0" : "") + n
}

// month is 0-indexed, matching Date.getMonth().
function dateKey(year, month, day) {
  return year + "-" + pad2(Number(month) + 1) + "-" + pad2(day)
}

function keyForDate(date) {
  return dateKey(date.getFullYear(), date.getMonth(), date.getDate())
}

function isKey(value) {
  return typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value)
}

// Local midnight for a key. Constructing from parts rather than parsing the
// string avoids Date's ISO-means-UTC rule.
function parseKey(key) {
  if (!isKey(key)) return null
  var parts = String(key).split("-")
  return new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
}

// Day arithmetic goes through Date so month lengths and DST are the platform's
// problem, not ours.
function shiftKey(key, delta) {
  var d = parseKey(key)
  if (!d) return key
  d.setDate(d.getDate() + Number(delta || 0))
  return keyForDate(d)
}

// Keys are zero-padded and fixed width, so lexicographic order is chronological.
function compareKeys(a, b) {
  return a < b ? -1 : (a > b ? 1 : 0)
}

function daysBetween(fromKey, toKey) {
  var a = parseKey(fromKey), b = parseKey(toKey)
  if (!a || !b) return 0
  // Compare at noon so a DST transition between the two dates cannot round the
  // difference to the wrong whole number of days.
  a.setHours(12, 0, 0, 0)
  b.setHours(12, 0, 0, 0)
  return Math.round((b - a) / 86400000)
}

function relativeDayLabel(key, todayKey) {
  var delta = daysBetween(todayKey, key)
  if (delta === 0) return "Today"
  if (delta === 1) return "Tomorrow"
  if (delta === -1) return "Yesterday"
  return ""
}

// ---------------------------------------------------------------------------
// Calendar grid (adapted from the clock panel)

function coerceWeekStart(value) {
  if (value === undefined || value === null) return null
  if (typeof value === "number")
    return isFinite(value) ? ((Math.round(value) % 7) + 7) % 7 : null
  var text = String(value).trim().toLowerCase()
  if (text === "" || text === "locale") return null
  if (text === "sunday" || text === "sun" || text === "0") return 0
  if (text === "monday" || text === "mon" || text === "1") return 1
  var n = Number(text)
  return isFinite(n) ? ((Math.round(n) % 7) + 7) % 7 : null
}

function normalizedWeekStart(value, fallback) {
  var configured = coerceWeekStart(value)
  if (configured !== null) return configured
  var fallbackStart = coerceWeekStart(fallback)
  return fallbackStart === null ? 1 : fallbackStart
}

function weekdayOrder(weekStart) {
  var start = normalizedWeekStart(weekStart, 1)
  var out = []
  for (var i = 0; i < 7; i++) out.push((start + i) % 7)
  return out
}

function isoWeek(year, month, day) {
  var date = new Date(year, month, day)
  var thursday = new Date(date)
  thursday.setDate(date.getDate() - ((date.getDay() + 6) % 7) + 3)
  var firstThursday = new Date(thursday.getFullYear(), 0, 4)
  firstThursday.setDate(firstThursday.getDate() - ((firstThursday.getDay() + 6) % 7) + 3)
  return 1 + Math.round((thursday - firstThursday) / 604800000)
}

function stepMonth(year, month, delta) {
  var d = new Date(year, month + Number(delta || 0), 1)
  return { year: d.getFullYear(), month: d.getMonth() }
}

// Six fixed rows, so the panel height does not jump between months.
function monthGrid(year, month, weekStart, todayKey) {
  var start = normalizedWeekStart(weekStart, 1)
  var leading = (new Date(year, month, 1).getDay() - start + 7) % 7
  var cursor = new Date(year, month, 1 - leading)
  var today = String(todayKey || "")
  var weeks = []

  for (var w = 0; w < 6; w++) {
    var days = []
    var thursday = null
    for (var d = 0; d < 7; d++) {
      var cellYear = cursor.getFullYear()
      var cellMonth = cursor.getMonth()
      var cellDay = cursor.getDate()
      var weekday = cursor.getDay()
      var key = dateKey(cellYear, cellMonth, cellDay)
      if (weekday === 4) thursday = { year: cellYear, month: cellMonth, day: cellDay }
      days.push({
        key: key,
        year: cellYear,
        month: cellMonth,
        day: cellDay,
        weekday: weekday,
        inMonth: cellMonth === month && cellYear === year,
        weekend: weekday === 0 || weekday === 6,
        today: key === today
      })
      cursor.setDate(cursor.getDate() + 1)
    }
    var anchor = thursday || days[0]
    weeks.push({ week: isoWeek(anchor.year, anchor.month, anchor.day), days: days })
  }
  return weeks
}

// ---------------------------------------------------------------------------
// Store shape
//
// { version: 1, days: { "yyyy-MM-dd": [task, ...] } }
//
// Every mutation below is pure: it returns a new store and leaves the argument
// untouched. That is what lets QML treat `store` as a plain bindable value and
// what lets these tests run without Qt.

var SCHEMA_VERSION = 1
var MAX_TEXT = 500

// A lookup table keyed by ids and roots read from the file. A plain {} would
// answer "constructor" or "__proto__" from Object.prototype, so a task named
// that would be skipped as already seen, or crash a merge pushing onto it.
function dict() {
  return Object.create(null)
}

function emptyStore() {
  return { version: SCHEMA_VERSION, days: {} }
}

function cloneStore(store) {
  var out = { version: SCHEMA_VERSION, days: {} }
  var days = (store && store.days) || {}
  for (var key in days) {
    if (!Object.prototype.hasOwnProperty.call(days, key)) continue
    out.days[key] = days[key].slice()
  }
  return out
}

function normalizeText(value) {
  if (typeof value !== "string") return ""
  // Collapse newlines: a task is one line. Paste of a paragraph becomes one
  // task rather than silently losing everything after the first break.
  return value.replace(/\s+/g, " ").trim().slice(0, MAX_TEXT)
}

function normalizeTask(raw, dayKey) {
  if (!raw || typeof raw !== "object") return null
  var text = normalizeText(raw.text)
  if (!text) return null
  var migrations = Number(raw.migrations)
  if (!isFinite(migrations) || migrations < 0) migrations = 0
  var origin = isKey(raw.origin) ? raw.origin : dayKey
  var id = typeof raw.id === "string" && raw.id ? raw.id : ""
  // The identity of the WORK, stable across every migration, as opposed to the
  // id, which identifies one copy of it on one day. Two machines that migrate
  // the same task to different days produce two copies with different ids but
  // the same root, which is what lets the merge tell they are one task.
  //
  // Backfilled for journals written before this existed: a migrated copy's id
  // is "<source>>YYYY-MM-DD", so the text before the first ">" is the root.
  var root = typeof raw.root === "string" && raw.root ? raw.root : id.split(">")[0]
  return {
    id: id,
    root: root,
    text: text,
    done: raw.done === true,
    createdAt: typeof raw.createdAt === "string" ? raw.createdAt : "",
    doneAt: typeof raw.doneAt === "string" ? raw.doneAt : null,
    // Last time a person ticked or unticked this task. The merge settles `done`
    // by it, so an untick on one device beats a stale tick on another.
    toggledAt: typeof raw.toggledAt === "string" ? raw.toggledAt : null,
    origin: origin,
    migrations: Math.floor(migrations),
    // Set on the entry left behind when a task is migrated forward: the day it
    // went to. A tombstone is not actionable and is not open, but it still
    // counts against the day it was written on.
    migratedTo: isKey(raw.migratedTo) ? raw.migratedTo : null,
    migratedAt: typeof raw.migratedAt === "string" ? raw.migratedAt : null,
    // Last time a person changed this task. Only the merge reads it, to settle
    // the one field two devices can genuinely disagree about: the text.
    updatedAt: typeof raw.updatedAt === "string" ? raw.updatedAt : "",
    // Deleting is a soft delete, because a merge that only unions cannot tell
    // "new over there" from "deleted over here" — without a marker, every task
    // you delete on one device is resurrected by the other. Pruned once the
    // marker is older than every device could plausibly be offline.
    deleted: raw.deleted === true,
    deletedAt: typeof raw.deletedAt === "string" ? raw.deletedAt : null
  }
}

// Tolerates anything: a truncated file, a hand-edit, an object where an array
// belongs. A corrupt store must degrade to an empty one, never throw — this
// runs inside the shell process, where an exception is a broken desktop.
function normalizeStore(raw) {
  var parsed = raw
  if (typeof raw === "string") {
    try { parsed = JSON.parse(raw) } catch (e) { return emptyStore() }
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return emptyStore()

  var days = parsed.days
  if (!days || typeof days !== "object" || Array.isArray(days)) return emptyStore()

  var out = emptyStore()
  var seen = dict()
  for (var key in days) {
    if (!Object.prototype.hasOwnProperty.call(days, key)) continue
    if (!isKey(key)) continue
    var list = days[key]
    if (!Array.isArray(list)) continue
    var tasks = []
    for (var i = 0; i < list.length; i++) {
      var task = normalizeTask(list[i], key)
      if (!task) continue
      // A duplicate id makes toggling ambiguous, so only one can survive.
      //
      // The first occurrence wins and the rest are DROPPED — never renamed.
      // Renaming looked kinder, but a renamed task is a new identity, each
      // device invents a different one, and the merge then treats them as
      // extra tasks and writes them back at each other. One malformed file
      // multiplied a single task into six that way.
      if (!task.id || seen[task.id]) continue
      seen[task.id] = true
      tasks.push(task)
    }
    if (tasks.length) out.days[key] = tasks
  }
  return out
}

function serialize(store) {
  return JSON.stringify(pruneEmptyDays(store), null, 2) + "\n"
}

function pruneEmptyDays(store) {
  var out = { version: SCHEMA_VERSION, days: {} }
  var days = (store && store.days) || {}
  // Sorted so the file diffs cleanly in git when someone points statePath at a
  // synced or version-controlled directory.
  var keys = Object.keys(days).sort()
  for (var i = 0; i < keys.length; i++) {
    var list = days[keys[i]]
    if (Array.isArray(list) && list.length) out.days[keys[i]] = list
  }
  return out
}

// A task is in exactly one of three visible states. Only a live one can be
// acted on. Deleted is a fourth, invisible state that exists solely so the
// merge can propagate a deletion.
function isMigrated(task) {
  return !!(task && task.migratedTo)
}

function isOpen(task) {
  return !!task && !task.done && !task.migratedTo && !task.deleted
}

function isDeleted(task) {
  return !!(task && task.deleted)
}

// Everything stored under a day, deletion markers included. The merge and the
// serializer want this; nothing else should.
function rawTasksFor(store, key) {
  var days = (store && store.days) || {}
  var list = days[key]
  return Array.isArray(list) ? list : []
}

// What is actually on the day. Every caller that renders or counts wants this
// one, so a deleted task drops out of the list, the stats, and the calendar
// without any of them having to know deletion markers exist.
function tasksFor(store, key) {
  var list = rawTasksFor(store, key)
  for (var i = 0; i < list.length; i++) {
    if (list[i].deleted) return list.filter(function (t) { return !t.deleted })
  }
  return list
}

function allIds(store) {
  var used = dict()
  var days = (store && store.days) || {}
  for (var key in days) {
    if (!Object.prototype.hasOwnProperty.call(days, key)) continue
    var list = days[key]
    for (var i = 0; i < list.length; i++) used[list[i].id] = true
  }
  return used
}

// A short, filesystem- and JSON-safe tag for the machine that made a task.
function deviceTag(deviceId) {
  var clean = String(deviceId || "").toLowerCase().replace(/[^a-z0-9]/g, "")
  return clean ? clean.slice(0, 8) : "local"
}

// Derived from the timestamp, the device, and the ids already in the store —
// never from Math.random(), so the same inputs always produce the same id and
// the tests can assert on it.
//
// The device tag is not decoration. The counter only avoids collisions inside
// one store, so two machines adding a task in the same millisecond used to
// mint the same id. Under whole-file sync that was invisible; under a merge it
// silently welds two different tasks into one.
function newId(store, nowIso, deviceId) {
  var base = Date.parse(nowIso)
  if (!isFinite(base)) base = 0
  var stem = Math.floor(base).toString(36) + "-" + deviceTag(deviceId)
  var used = allIds(store)
  var n = 0
  var id = stem + "-" + n
  while (used[id]) { n++; id = stem + "-" + n }
  return id
}

// The id of the copy a migration puts on the target day, derived from the task
// it came from and where it landed.
//
// Deliberately not newId(): if two devices both migrate the same task to the
// same day — which is exactly what "pull in the backlog" does on both machines
// on the same morning — deriving the id makes them the same task, and the
// merge collapses them. A fresh id on each side would leave you holding two.
function migratedId(store, sourceId, toKey) {
  var stem = String(sourceId) + ">" + String(toKey)
  var used = allIds(store)
  if (!used[stem]) return stem
  var n = 1
  while (used[stem + "-" + n]) n++
  return stem + "-" + n
}

// ---------------------------------------------------------------------------
// Mutations

function addTask(store, key, text, nowIso, deviceId) {
  var clean = normalizeText(text)
  if (!clean || !isKey(key)) return store
  var out = cloneStore(store)
  var list = (out.days[key] || []).slice()
  var id = newId(out, nowIso, deviceId)
  list.push({
    id: id,
    root: id,
    text: clean,
    done: false,
    createdAt: String(nowIso || ""),
    doneAt: null,
    toggledAt: null,
    origin: key,
    migrations: 0,
    migratedTo: null,
    migratedAt: null,
    updatedAt: String(nowIso || ""),
    deleted: false,
    deletedAt: null
  })
  out.days[key] = list
  return out
}

function toggleTask(store, key, id, nowIso) {
  var out = cloneStore(store)
  var list = out.days[key]
  if (!list) return store
  var changed = false
  out.days[key] = list.map(function (task) {
    if (task.id !== id || isMigrated(task) || isDeleted(task)) return task
    changed = true
    var done = !task.done
    var copy = {}
    for (var k in task) copy[k] = task[k]
    copy.done = done
    copy.doneAt = done ? String(nowIso || "") : null
    copy.toggledAt = String(nowIso || "")
    copy.updatedAt = String(nowIso || "")
    return copy
  })
  return changed ? out : store
}

function editTask(store, key, id, text, nowIso) {
  var clean = normalizeText(text)
  if (!clean) return store
  var out = cloneStore(store)
  var list = out.days[key]
  if (!list) return store
  var changed = false
  out.days[key] = list.map(function (task) {
    if (task.id !== id || isMigrated(task) || isDeleted(task)) return task
    changed = true
    var copy = {}
    for (var k in task) copy[k] = task[k]
    copy.text = clean
    // The merge settles a text disagreement by recency, so an edit that does
    // not move this hand is an edit the other device will silently win.
    copy.updatedAt = String(nowIso || task.updatedAt || "")
    return copy
  })
  return changed ? out : store
}

// A soft delete: the entry stays, marked, until pruneDeleted drops it. See the
// comment on `deleted` in normalizeTask for why a merge cannot work otherwise.
// tasksFor() filters these out, so nothing that renders or counts sees them.
function deleteTask(store, key, id, nowIso) {
  var out = cloneStore(store)
  var list = out.days[key]
  if (!list) return store
  var changed = false
  out.days[key] = list.map(function (task) {
    // Migrated entries are refused for the same reason toggling and editing
    // them is: the tombstone is what keeps the day's percentage honest, and
    // removing it turns a half-finished day into a perfect one. History is a
    // record here, not a list.
    if (task.id !== id || task.deleted || isMigrated(task)) return task
    changed = true
    var copy = {}
    for (var k in task) copy[k] = task[k]
    copy.deleted = true
    copy.deletedAt = String(nowIso || "")
    copy.updatedAt = String(nowIso || "")
    return copy
  })
  return changed ? out : store
}

// Reorder within the list as the user sees it.
//
// Deliberately not "move one place in the stored array": deletion markers live
// in that array and are invisible, so a raw ±1 can swap a task with a marker
// and leave the visible order completely unchanged. Positions are resolved
// among the visible entries, then applied to the stored one.
function moveTask(store, key, id, delta) {
  var step = Number(delta || 0)
  if (!step) return store

  var list = rawTasksFor(store, key)
  var visible = []
  var from = -1
  for (var i = 0; i < list.length; i++) {
    if (list[i].deleted) continue
    if (list[i].id === id) from = visible.length
    visible.push(i)
  }
  if (from === -1) return store

  var to = from + step
  if (to < 0 || to >= visible.length) return store

  var out = cloneStore(store)
  var next = out.days[key].slice()
  // Swap the two stored slots the visible neighbours occupy. A swap rather than
  // a splice, so every marker keeps its position and the operation is its own
  // inverse.
  var a = visible[from], b = visible[to]
  var held = next[a]
  next[a] = next[b]
  next[b] = held
  out.days[key] = next
  return out
}

// Carry a day's open tasks onto another day.
//
// The entry is NOT erased from the day it was written on. It stays there as a
// tombstone pointing at where it went, which is what migrating means on paper:
// you strike the bullet through with `>` and the line remains on the page. That
// is not sentimentality — it is the only way the day's completion percentage
// can stay honest. Erase the open tasks instead and every day you ever migrated
// from reads 100%, because all that is left on it is the work you finished.
//
// Completed tasks never move; the day they were finished on is a fact.
function carryOver(store, fromKey, toKey, nowIso) {
  if (!isKey(fromKey) || !isKey(toKey) || fromKey === toKey) return store
  var source = tasksFor(store, fromKey)
  if (!source.some(isOpen)) return store

  var out = cloneStore(store)
  var target = (out.days[toKey] || []).slice()

  out.days[fromKey] = source.map(function (task) {
    if (!isOpen(task)) return task
    var moved = {}
    for (var k in task) moved[k] = task[k]
    moved.id = migratedId(out, task.id, toKey)
    moved.root = task.root || task.id
    moved.migrations = Math.floor(Number(task.migrations) || 0) + 1
    moved.origin = isKey(task.origin) ? task.origin : fromKey
    moved.migratedTo = null
    moved.migratedAt = String(nowIso || "")
    moved.updatedAt = String(nowIso || "")
    target.push(moved)
    // The copy is a new task with its own id; the original becomes the marker.
    var stone = {}
    for (var j in task) stone[j] = task[j]
    stone.migratedTo = toKey
    stone.migratedAt = String(nowIso || "")
    stone.updatedAt = String(nowIso || "")
    return stone
  })

  out.days[toKey] = target
  return out
}

// Every open task on a day strictly before `beforeKey`, pulled onto `toKey` in
// chronological order so the oldest debt lands at the top.
function migrateBacklog(store, beforeKey, toKey, nowIso) {
  var keys = backlogKeys(store, beforeKey)
  var out = store
  for (var i = 0; i < keys.length; i++) {
    if (keys[i] === toKey) continue
    out = carryOver(out, keys[i], toKey, nowIso)
  }
  return out
}

// ---------------------------------------------------------------------------
// Merging two devices
//
// Plain file sync gives you no common ancestor and no ordering: two machines
// hand you two whole files and you have to produce one. Everything below is a
// two-way merge over the journal, and it only works because the task shape
// already carries what a merge needs — a stable id, a creation day, a
// migration count, and timestamps for the things that change.
//
// The rules are chosen so that merging is CONVERGENT: whichever order the two
// devices see each other's writes in, they end up holding the same journal.
// Every field either takes a monotonic step (done, deleted, migrated,
// migrations) or is settled by a timestamp (text). Nothing is settled by "mine
// wins", because "mine" is different on each machine and would never converge.

function earlierStamp(a, b) {
  var x = a || "", y = b || ""
  if (!x) return y || null
  if (!y) return x || null
  return x <= y ? x : y
}

function laterStamp(a, b) {
  var x = a || "", y = b || ""
  if (!x) return y || ""
  if (!y) return x || ""
  return x >= y ? x : y
}

function toggleStamp(task) {
  return laterStamp(task.toggledAt, task.doneAt)
}

function mergeTask(local, remote) {
  if (!local) return remote
  if (!remote) return local

  var out = {}
  for (var k in local) out[k] = local[k]

  // Text is the only field two people can genuinely disagree about, so it is
  // the only one settled by recency. A tie keeps the local text; the tie can
  // only happen when neither side edited since they last agreed.
  var lu = local.updatedAt || "", ru = remote.updatedAt || ""
  if (ru > lu) out.text = remote.text
  out.updatedAt = laterStamp(lu, ru)

  // Deleting outranks everything. If one machine says this is gone, it is
  // gone — otherwise a delete could be undone by the other machine merely
  // still remembering the task.
  out.deleted = local.deleted === true || remote.deleted === true
  out.deletedAt = out.deleted ? earlierStamp(local.deletedAt, remote.deletedAt) : null

  // Finishing is settled by the later tick or untick. It used to be monotonic
  // — done on either machine meant done — but a bar widget runs one store per
  // monitor, so every untick was merged straight back into a tick by a sibling
  // that still remembered it. Journals written before toggledAt existed only
  // have doneAt, which is the stamp of their last tick.
  var lt = toggleStamp(local), rt = toggleStamp(remote)
  if (lt === rt) {
    // Neither side toggled since they last agreed, or both did in the same
    // millisecond: done wins, and the first completion is the true one.
    out.done = local.done === true || remote.done === true
    out.doneAt = out.done ? earlierStamp(local.done ? local.doneAt : null, remote.done ? remote.doneAt : null) : null
  } else {
    var toggled = lt > rt ? local : remote
    out.done = toggled.done === true
    out.doneAt = out.done ? (toggled.doneAt || null) : null
  }
  out.toggledAt = laterStamp(lt, rt) || null

  // So is migrating. If both machines migrated it, the first one decided where
  // it went; the target key breaks a stamp tie so the choice is deterministic
  // rather than dependent on which file arrived first.
  if (local.migratedTo && remote.migratedTo && local.migratedTo !== remote.migratedTo) {
    var lm = local.migratedAt || "", rm = remote.migratedAt || ""
    var localWins = lm === rm
      ? local.migratedTo <= remote.migratedTo
      : (lm && rm ? lm < rm : !!lm)
    out.migratedTo = localWins ? local.migratedTo : remote.migratedTo
  } else {
    out.migratedTo = local.migratedTo || remote.migratedTo || null
  }

  // Independent of migratedTo, and NOT cleared when it is null: this stamp
  // means "the last time a migration touched this task", which on a tombstone
  // is when the work left and on a copy is when it arrived. Clearing it for
  // copies — which have no migratedTo of their own — silently rewrote them on
  // every merge, so two devices never stopped writing the file back at
  // each other.
  out.migratedAt = earlierStamp(local.migratedAt, remote.migratedAt)

  out.migrations = Math.max(Number(local.migrations) || 0, Number(remote.migrations) || 0)
  // Identical in practice; the smaller string keeps it deterministic if a
  // hand-edited file ever disagrees with itself.
  out.root = (local.root && remote.root)
    ? (local.root <= remote.root ? local.root : remote.root)
    : (local.root || remote.root || local.id)
  out.origin = earlierStamp(local.origin, remote.origin) || local.origin
  out.createdAt = earlierStamp(local.createdAt, remote.createdAt) || ""

  return out
}

// Union both journals by day, then by task id.
//
// Order within a day follows the local list, with tasks only the other machine
// has appended after. Order is the one thing deliberately NOT converged: it is
// what the J/K reordering controls, and forcing a canonical sort would mean one
// machine silently rearranging the other's list every time they meet.
function mergeStores(local, remote) {
  var out = { version: SCHEMA_VERSION, days: {} }
  var keys = dict()
  var k
  for (k in ((local && local.days) || {})) keys[k] = true
  for (k in ((remote && remote.days) || {})) keys[k] = true

  // A task id belongs to exactly one day. The two files can disagree about
  // which — a hand edit, or a sync tool reviving an older copy — and unioning
  // per day would then place the same id under both, which every later pass
  // reads as two tasks. Settle it once, earliest day wins.
  var dayOf = dict()
  var side, sk, sl, si, sid
  for (var pass = 0; pass < 2; pass++) {
    side = (pass === 0 ? local : remote)
    var sdays = (side && side.days) || {}
    for (sk in sdays) {
      if (!Object.prototype.hasOwnProperty.call(sdays, sk)) continue
      sl = sdays[sk]
      for (si = 0; si < sl.length; si++) {
        sid = sl[si].id
        if (dayOf[sid] === undefined || sk < dayOf[sid]) dayOf[sid] = sk
      }
    }
  }

  for (var day in keys) {
    var l = rawTasksFor(local, day)
    var r = rawTasksFor(remote, day)

    var byId = dict()
    for (var i = 0; i < r.length; i++) byId[r[i].id] = r[i]

    var merged = []
    var seen = dict()
    for (var j = 0; j < l.length; j++) {
      var lt = l[j]
      if (seen[lt.id] || dayOf[lt.id] !== day) continue
      seen[lt.id] = true
      merged.push(byId[lt.id] ? mergeTask(lt, byId[lt.id]) : lt)
    }
    for (var m = 0; m < r.length; m++) {
      if (seen[r[m].id] || dayOf[r[m].id] !== day) continue
      seen[r[m].id] = true
      merged.push(r[m])
    }

    if (merged.length) out.days[day] = merged
  }
  return collapseLineages(out)
}

// Two machines that migrated the same task to DIFFERENT days each made their
// own copy before they met. Union alone leaves both, and you are holding the
// same work twice on two different days.
//
// The copies have different ids — they have to, they are on different days —
// but they share a root, so they can be recognised as one task and folded back
// together.
//
// The survivor is the copy on the earliest day, tie-broken by id: deterministic
// on both machines, and it errs toward showing you the work sooner rather than
// later. Its fields absorb every sibling first, so a completion or a rename
// made on the losing copy is not thrown away; the siblings then become deletion
// markers so the collapse propagates like any other delete.
function collapseLineages(store) {
  var days = (store && store.days) || {}

  // Gather the live copies of each root. Migrated and deleted entries are
  // history and never collapse.
  var byRoot = dict()
  var day, i, list, task, key
  for (day in days) {
    if (!Object.prototype.hasOwnProperty.call(days, day)) continue
    list = days[day]
    for (i = 0; i < list.length; i++) {
      task = list[i]
      if (task.deleted || task.migratedTo) continue
      key = task.root || task.id
      if (!byRoot[key]) byRoot[key] = []
      byRoot[key].push({ day: day, task: task })
    }
  }

  var winners = dict()
  var losers = dict()
  var found = false
  for (key in byRoot) {
    var group = byRoot[key]
    if (group.length < 2) continue
    found = true
    group.sort(function (a, b) {
      if (a.day !== b.day) return a.day < b.day ? -1 : 1
      return a.task.id < b.task.id ? -1 : 1
    })
    var survivor = group[0].task
    for (i = 1; i < group.length; i++) {
      // mergeTask keeps the left-hand id, so the survivor absorbs the sibling's
      // done/text/migrations without inheriting its identity or its day.
      var absorbed = mergeTask(survivor, group[i].task)
      absorbed.id = survivor.id
      absorbed.root = survivor.root || survivor.id
      absorbed.migratedTo = null
      survivor = absorbed
      losers[group[i].task.id] = group[i].task
    }
    winners[group[0].task.id] = survivor
  }

  if (!found) return store

  var out = { version: SCHEMA_VERSION, days: {} }
  for (day in days) {
    if (!Object.prototype.hasOwnProperty.call(days, day)) continue
    out.days[day] = days[day].map(function (t) {
      if (winners[t.id] && !t.deleted && !t.migratedTo) return winners[t.id]
      if (losers[t.id] && !t.deleted && !t.migratedTo) {
        var gone = {}
        for (var k in t) gone[k] = t[k]
        gone.deleted = true
        // Derived from the task, never from the clock: both machines must
        // produce byte-identical results or they write back at each other.
        gone.deletedAt = t.migratedAt || t.updatedAt || t.createdAt || ""
        return gone
      }
      return t
    })
  }
  return out
}

// Drop deletion markers old enough that no device could still be carrying the
// task. Until then they have to stay, or syncing resurrects deleted tasks.
function pruneDeleted(store, nowIso, days) {
  var horizon = Number(days)
  if (!isFinite(horizon) || horizon <= 0) horizon = 30
  var cutoff = Date.parse(nowIso)
  if (!isFinite(cutoff)) return store
  cutoff -= horizon * 86400000

  var out = { version: SCHEMA_VERSION, days: {} }
  var src = (store && store.days) || {}
  var dropped = false
  for (var day in src) {
    if (!Object.prototype.hasOwnProperty.call(src, day)) continue
    var kept = src[day].filter(function (task) {
      if (!task.deleted) return true
      var at = Date.parse(task.deletedAt || "")
      if (!isFinite(at)) return true
      if (at >= cutoff) return true
      dropped = true
      return false
    })
    if (kept.length) out.days[day] = kept
  }
  return dropped ? out : store
}

// ---------------------------------------------------------------------------
// Derived values

// `total` counts tombstones, which is the whole point: work you pushed to
// another day is work this day did not finish, and the ratio has to say so.
// `open` counts only what is still actionable here, so the migrate button and
// the backlog banner never offer to move an entry twice.
function stats(tasks) {
  var list = Array.isArray(tasks) ? tasks : []
  var done = 0, open = 0, migrated = 0
  for (var i = 0; i < list.length; i++) {
    if (list[i].done) done++
    else if (isMigrated(list[i])) migrated++
    else open++
  }
  return {
    total: list.length,
    done: done,
    open: open,
    migrated: migrated,
    ratio: list.length ? done / list.length : 0
  }
}

function dayStats(store, key) {
  return stats(tasksFor(store, key))
}

// null means "nothing was ever written on this day", which the calendar must
// render differently from a day whose tasks are all still open. Collapsing the
// two into 0 would paint an empty month as total failure.
function dayCompletion(store, key) {
  var list = tasksFor(store, key)
  if (!list.length) return null
  return stats(list).ratio
}

// Days strictly before `beforeKey` that still hold open tasks, oldest first.
function backlogKeys(store, beforeKey) {
  var days = (store && store.days) || {}
  var out = []
  for (var key in days) {
    if (!Object.prototype.hasOwnProperty.call(days, key)) continue
    if (compareKeys(key, beforeKey) >= 0) continue
    if (days[key].some(isOpen)) out.push(key)
  }
  return out.sort()
}

function openBefore(store, beforeKey) {
  var keys = backlogKeys(store, beforeKey)
  var n = 0
  for (var i = 0; i < keys.length; i++) n += stats(tasksFor(store, keys[i])).open
  return n
}

// Totals across the `days`-day window ending at endKey inclusive.
function rangeStats(store, endKey, days) {
  var span = Math.max(1, Math.floor(Number(days) || 1))
  var total = 0, done = 0, activeDays = 0
  for (var i = 0; i < span; i++) {
    var s = dayStats(store, shiftKey(endKey, -i))
    if (s.total) activeDays++
    total += s.total
    done += s.done
  }
  return { total: total, done: done, open: total - done, activeDays: activeDays, ratio: total ? done / total : 0 }
}

// Consecutive fully-cleared days ending at today. A day with no tasks is not a
// cleared day and breaks the run — except today itself, which is allowed to be
// empty because the morning has not happened yet.
function streak(store, todayKey) {
  var cursor = todayKey
  if (dayCompletion(store, cursor) === null) cursor = shiftKey(cursor, -1)
  var n = 0
  // Bounded so a pathological store cannot spin the shell's UI thread.
  for (var guard = 0; guard < 3660; guard++) {
    if (dayCompletion(store, cursor) !== 1) break
    n++
    cursor = shiftKey(cursor, -1)
  }
  return n
}

// The tasks you keep pushing. Ranked by how often, then by how long ago they
// were first written.
function mostDeferred(store, limit) {
  var days = (store && store.days) || {}
  var out = []
  for (var key in days) {
    if (!Object.prototype.hasOwnProperty.call(days, key)) continue
    var list = days[key]
    for (var i = 0; i < list.length; i++) {
      var task = list[i]
      if (task.done || isMigrated(task) || !task.migrations) continue
      out.push({ key: key, text: task.text, migrations: task.migrations, origin: task.origin })
    }
  }
  out.sort(function (a, b) {
    if (b.migrations !== a.migrations) return b.migrations - a.migrations
    return compareKeys(a.origin, b.origin)
  })
  var n = Math.max(0, Math.floor(Number(limit) || 0))
  return n ? out.slice(0, n) : out
}

// Where a migration from the day on screen would land, and what to call it.
// Named on the button so the destination is never a surprise.
function carryTarget(viewedKey, todayKey) {
  if (!isKey(viewedKey) || !isKey(todayKey)) return null
  var delta = daysBetween(todayKey, viewedKey)
  if (delta > 0) return null                                        // future: nothing to rescue
  if (delta === 0) return { key: shiftKey(todayKey, 1), label: "tomorrow" }
  return { key: todayKey, label: "today" }
}

function percent(ratio) {
  return Math.round((Number(ratio) || 0) * 100)
}

// The bar pill. `glyph` is supplied by the QML side so the icon stays a
// presentation decision and this stays testable.
function pillText(mode, s, glyph) {
  var icon = String(glyph || "")
  if (mode === "icon" || !s || !s.total) return icon
  var suffix
  if (mode === "count") suffix = String(s.open)
  else if (mode === "percent") suffix = percent(s.ratio) + "%"
  else suffix = s.done + "/" + s.total
  return icon ? icon + " " + suffix : suffix
}
