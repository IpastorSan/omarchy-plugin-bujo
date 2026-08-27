// Unit tests for Model.js, the pure half of the plugin.
//
// Model.js holds every function that could get a date, a count, or a migration
// wrong, and none of it is reachable from a QML harness. The `.pragma library`
// line is QML-flavoured and not valid JS, so it is stripped before evaluation —
// the same thing tests/check-qml.sh does. Run with `node --test`.

const test = require("node:test")
const assert = require("node:assert")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

const source = fs
  .readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
  .split("\n")
  .filter((l) => !l.startsWith(".pragma"))
  .join("\n")

const M = {}
vm.createContext(M)
vm.runInContext(source, M)

const T0 = "2026-08-25T09:00:00.000Z"
const T1 = "2026-08-26T09:00:00.000Z"
const T2 = "2026-08-27T09:00:00.000Z"

// Build a store by replaying real mutations, so the fixtures exercise the same
// code path the UI does rather than hand-rolling a shape that could drift.
function seed(spec) {
  let store = M.emptyStore()
  let tick = 0
  for (const [key, texts] of Object.entries(spec)) {
    for (const text of texts) {
      const done = text.startsWith("+")
      const iso = new Date(Date.parse(T0) + tick++ * 1000).toISOString()
      store = M.addTask(store, key, done ? text.slice(1) : text, iso)
      if (done) {
        const list = M.tasksFor(store, key)
        store = M.toggleTask(store, key, list[list.length - 1].id, iso)
      }
    }
  }
  return store
}

// --- day keys ---------------------------------------------------------------

test("dateKey pads and shifts month to 1-indexed", () => {
  assert.equal(M.dateKey(2026, 7, 3), "2026-08-03")
  assert.equal(M.dateKey(2026, 11, 25), "2026-12-25")
})

test("parseKey builds local midnight, not UTC", () => {
  const d = M.parseKey("2026-08-27")
  assert.equal(d.getFullYear(), 2026)
  assert.equal(d.getMonth(), 7)
  assert.equal(d.getDate(), 27)
  assert.equal(d.getHours(), 0)
})

test("parseKey rejects anything that is not a key", () => {
  for (const bad of ["", "2026-8-27", "2026-08-27T00:00", "nope", null, undefined, 20260827])
    assert.equal(M.parseKey(bad), null)
})

test("shiftKey crosses month and year boundaries", () => {
  assert.equal(M.shiftKey("2026-08-31", 1), "2026-09-01")
  assert.equal(M.shiftKey("2026-01-01", -1), "2025-12-31")
  assert.equal(M.shiftKey("2024-02-28", 1), "2024-02-29") // leap year
  assert.equal(M.shiftKey("2026-02-28", 1), "2026-03-01") // not a leap year
})

test("daysBetween is signed and whole", () => {
  assert.equal(M.daysBetween("2026-08-25", "2026-08-27"), 2)
  assert.equal(M.daysBetween("2026-08-27", "2026-08-25"), -2)
  assert.equal(M.daysBetween("2026-08-27", "2026-08-27"), 0)
  // Across a DST boundary in most northern-hemisphere zones.
  assert.equal(M.daysBetween("2026-03-28", "2026-03-30"), 2)
})

test("relativeDayLabel names only the three days worth naming", () => {
  assert.equal(M.relativeDayLabel("2026-08-27", "2026-08-27"), "Today")
  assert.equal(M.relativeDayLabel("2026-08-28", "2026-08-27"), "Tomorrow")
  assert.equal(M.relativeDayLabel("2026-08-26", "2026-08-27"), "Yesterday")
  assert.equal(M.relativeDayLabel("2026-08-24", "2026-08-27"), "")
})

// --- calendar ---------------------------------------------------------------

test("monthGrid always returns six weeks of seven days", () => {
  for (const month of [0, 1, 5, 11]) {
    const weeks = M.monthGrid(2026, month, 1, "2026-08-27")
    assert.equal(weeks.length, 6)
    for (const w of weeks) assert.equal(w.days.length, 7)
  }
})

test("monthGrid marks in-month, today, and weekend cells", () => {
  const weeks = M.monthGrid(2026, 7, 1, "2026-08-27")
  const cells = weeks.flatMap((w) => w.days)
  const today = cells.filter((c) => c.today)
  assert.equal(today.length, 1)
  assert.equal(today[0].key, "2026-08-27")
  assert.equal(cells.filter((c) => c.inMonth).length, 31)
  for (const c of cells) assert.equal(c.weekend, c.weekday === 0 || c.weekday === 6)
})

test("weekStart rotates the weekday order and the grid's first column", () => {
  assert.deepEqual(M.weekdayOrder("monday"), [1, 2, 3, 4, 5, 6, 0])
  assert.deepEqual(M.weekdayOrder("sunday"), [0, 1, 2, 3, 4, 5, 6])
  assert.equal(M.monthGrid(2026, 7, 1, "").days, undefined)
  assert.equal(M.monthGrid(2026, 7, 1, "")[0].days[0].weekday, 1)
  assert.equal(M.monthGrid(2026, 7, 0, "")[0].days[0].weekday, 0)
})

test("stepMonth wraps the year", () => {
  assert.deepEqual(M.stepMonth(2026, 11, 1), { year: 2027, month: 0 })
  assert.deepEqual(M.stepMonth(2026, 0, -1), { year: 2025, month: 11 })
})

// --- store hygiene ----------------------------------------------------------

test("normalizeStore survives a truncated or corrupt file", () => {
  for (const bad of ['{"version":1,"days":{"2026-08-27":[{"text":"a"', "", "null", "[]", "7", "{}", '{"days":[]}', undefined]) {
    const s = M.normalizeStore(bad)
    assert.deepEqual(s, M.emptyStore(), `failed on ${JSON.stringify(bad)}`)
  }
})

test("normalizeStore drops junk days and junk tasks but keeps the good ones", () => {
  const s = M.normalizeStore({
    version: 1,
    days: {
      "2026-08-27": [{ id: "a", text: "keep" }, { text: "" }, null, 7, { id: "b" }],
      "not-a-date": [{ id: "c", text: "drop" }],
      "2026-08-26": "not an array",
    },
  })
  assert.deepEqual(Object.keys(s.days), ["2026-08-27"])
  assert.equal(s.days["2026-08-27"].length, 1)
  assert.equal(s.days["2026-08-27"][0].text, "keep")
})

test("normalizeStore backfills origin and de-duplicates ids", () => {
  const s = M.normalizeStore({
    version: 1,
    days: { "2026-08-27": [{ id: "dup", text: "one" }, { id: "dup", text: "two" }] },
  })
  const [a, b] = s.days["2026-08-27"]
  assert.notEqual(a.id, b.id)
  assert.equal(a.origin, "2026-08-27")
  assert.equal(b.origin, "2026-08-27")
})

test("normalizeText collapses a pasted paragraph into one line", () => {
  const s = M.addTask(M.emptyStore(), "2026-08-27", "  first\nsecond\t third  ", T2)
  assert.equal(M.tasksFor(s, "2026-08-27")[0].text, "first second third")
})

test("serialize sorts keys for clean diffs and drops days with nothing in them", () => {
  let s = seed({ "2026-08-27": ["b"], "2026-08-25": ["a"] })
  const text = M.serialize(s)
  assert.deepEqual(Object.keys(JSON.parse(text).days), ["2026-08-25", "2026-08-27"])
  assert.equal(JSON.parse(text).days["2026-08-25"].length, 1)
})

test("mutations do not touch the store they were given", () => {
  const before = seed({ "2026-08-27": ["a"] })
  const snapshot = JSON.stringify(before)
  const id = M.tasksFor(before, "2026-08-27")[0].id
  M.addTask(before, "2026-08-27", "b", T2)
  M.toggleTask(before, "2026-08-27", id, T2)
  M.deleteTask(before, "2026-08-27", id, T2)
  M.carryOver(before, "2026-08-27", "2026-08-28", T2)
  assert.equal(JSON.stringify(before), snapshot)
})

test("newId is deterministic and never collides within one device", () => {
  let s = M.emptyStore()
  const ids = new Set()
  for (let i = 0; i < 50; i++) {
    s = M.addTask(s, "2026-08-27", "task " + i, T2) // same instant every time
    ids.add(M.tasksFor(s, "2026-08-27")[i].id)
  }
  assert.equal(ids.size, 50)
  assert.equal(M.newId(M.emptyStore(), T2), M.newId(M.emptyStore(), T2))
})

// --- mutations --------------------------------------------------------------

test("toggleTask stamps and clears doneAt", () => {
  let s = seed({ "2026-08-27": ["a"] })
  const id = M.tasksFor(s, "2026-08-27")[0].id
  s = M.toggleTask(s, "2026-08-27", id, T2)
  assert.equal(M.tasksFor(s, "2026-08-27")[0].done, true)
  assert.equal(M.tasksFor(s, "2026-08-27")[0].doneAt, T2)
  s = M.toggleTask(s, "2026-08-27", id, T2)
  assert.equal(M.tasksFor(s, "2026-08-27")[0].done, false)
  assert.equal(M.tasksFor(s, "2026-08-27")[0].doneAt, null)
})

test("deleting hides the task but keeps a marker so the delete can travel", () => {
  let s = seed({ "2026-08-27": ["a"] })
  const id = M.tasksFor(s, "2026-08-27")[0].id
  s = M.deleteTask(s, "2026-08-27", id, T2)
  assert.deepEqual(M.tasksFor(s, "2026-08-27"), [], "gone from the day")
  assert.equal(M.dayCompletion(s, "2026-08-27"), null, "and from the calendar")
  assert.equal(M.dayStats(s, "2026-08-27").total, 0, "and from the counts")
  const raw = M.rawTasksFor(s, "2026-08-27")
  assert.equal(raw.length, 1)
  assert.equal(raw[0].deleted, true)
  assert.equal(raw[0].deletedAt, T2)
})

test("a deletion marker is pruned once no device could still be holding it", () => {
  let s = seed({ "2026-08-27": ["a"] })
  s = M.deleteTask(s, "2026-08-27", M.tasksFor(s, "2026-08-27")[0].id, "2026-08-27T09:00:00.000Z")
  const soon = M.pruneDeleted(s, "2026-09-10T09:00:00.000Z", 30)
  assert.equal(M.rawTasksFor(soon, "2026-08-27").length, 1, "14 days is not long enough")
  const later = M.pruneDeleted(s, "2026-10-15T09:00:00.000Z", 30)
  assert.equal(Object.keys(later.days).length, 0, "and the empty day goes with it")
})

test("a deleted task cannot be toggled, edited, or migrated", () => {
  let s = seed({ "2026-08-27": ["a"] })
  const id = M.rawTasksFor(s, "2026-08-27")[0].id
  s = M.deleteTask(s, "2026-08-27", id, T2)
  assert.equal(M.toggleTask(s, "2026-08-27", id, T2), s)
  assert.equal(M.editTask(s, "2026-08-27", id, "changed", T2), s)
  assert.equal(M.carryOver(s, "2026-08-27", "2026-08-28", T2), s)
  assert.equal(M.deleteTask(s, "2026-08-27", id, T2), s, "deleting twice is a no-op")
})

test("moveTask reorders and refuses to run off either end", () => {
  let s = seed({ "2026-08-27": ["a", "b", "c"] })
  const [a, b] = M.tasksFor(s, "2026-08-27")
  s = M.moveTask(s, "2026-08-27", b.id, -1)
  assert.deepEqual(M.tasksFor(s, "2026-08-27").map((t) => t.text), ["b", "a", "c"])
  const same = M.moveTask(s, "2026-08-27", b.id, -1)
  assert.equal(same, s)
  assert.equal(M.moveTask(s, "2026-08-27", "nope", 1), s)
})

test("edits and toggles against an unknown id return the same store", () => {
  const s = seed({ "2026-08-27": ["a"] })
  assert.equal(M.toggleTask(s, "2026-08-27", "nope", T2), s)
  assert.equal(M.editTask(s, "2026-08-27", "nope", "x", T2), s)
  assert.equal(M.deleteTask(s, "2026-08-27", "nope", T2), s)
  assert.equal(M.editTask(s, "2026-08-27", M.tasksFor(s, "2026-08-27")[0].id, "   ", T2), s)
  assert.equal(M.addTask(s, "2026-08-27", "   ", T2), s)
  assert.equal(M.addTask(s, "not-a-date", "x", T2), s)
})

// --- migration, the heart of it ---------------------------------------------

test("carryOver preserves origin and increments migrations", () => {
  let s = seed({ "2026-08-25": ["ship it"] })
  s = M.carryOver(s, "2026-08-25", "2026-08-26", T1)
  s = M.carryOver(s, "2026-08-26", "2026-08-27", T2)
  const task = M.tasksFor(s, "2026-08-27")[0]
  assert.equal(task.text, "ship it")
  assert.equal(task.origin, "2026-08-25", "origin must survive every hop")
  assert.equal(task.migrations, 2)
  assert.equal(M.isOpen(task), true)
})

test("migrating leaves a tombstone on the day the task was written", () => {
  let s = seed({ "2026-08-25": ["ship it"] })
  s = M.carryOver(s, "2026-08-25", "2026-08-26", T1)
  const [stone] = M.tasksFor(s, "2026-08-25")
  assert.equal(stone.text, "ship it", "the line stays on the page")
  assert.equal(stone.migratedTo, "2026-08-26")
  assert.equal(M.isMigrated(stone), true)
  assert.equal(M.isOpen(stone), false, "a tombstone is not actionable")
  assert.equal(M.dayStats(s, "2026-08-25").open, 0)
  assert.equal(M.dayStats(s, "2026-08-25").migrated, 1)
})

test("the live copy and its tombstone are distinct tasks", () => {
  let s = seed({ "2026-08-25": ["a"] })
  s = M.carryOver(s, "2026-08-25", "2026-08-26", T1)
  const stone = M.tasksFor(s, "2026-08-25")[0]
  const live = M.tasksFor(s, "2026-08-26")[0]
  assert.notEqual(stone.id, live.id, "ids must not collide across days")
  // Finishing it tomorrow must not retroactively mark yesterday complete.
  s = M.toggleTask(s, "2026-08-26", live.id, T1)
  assert.equal(M.dayCompletion(s, "2026-08-26"), 1)
  assert.equal(M.dayCompletion(s, "2026-08-25"), 0)
})

test("a tombstone cannot be toggled, edited, or migrated again", () => {
  let s = seed({ "2026-08-25": ["a"] })
  s = M.carryOver(s, "2026-08-25", "2026-08-26", T1)
  const stone = M.tasksFor(s, "2026-08-25")[0]
  assert.equal(M.toggleTask(s, "2026-08-25", stone.id, T1), s)
  assert.equal(M.editTask(s, "2026-08-25", stone.id, "changed"), s)
  assert.equal(M.carryOver(s, "2026-08-25", "2026-08-27", T2), s, "no infinite re-migration")
  assert.deepEqual(M.backlogKeys(s, "2026-08-27"), ["2026-08-26"])
})

test("completed tasks never move", () => {
  let s = seed({ "2026-08-26": ["+done one", "open one"] })
  s = M.carryOver(s, "2026-08-26", "2026-08-27", T2)
  const left = M.tasksFor(s, "2026-08-26")
  assert.deepEqual(left.map((t) => t.text), ["done one", "open one"])
  assert.deepEqual(left.map((t) => t.migratedTo), [null, "2026-08-27"])
  assert.deepEqual(M.tasksFor(s, "2026-08-27").map((t) => t.text), ["open one"])
})

test("a past day's ratio is unchanged by migrating its open tasks away", () => {
  let s = seed({ "2026-08-26": ["+a", "+b", "c", "d"] })
  const before = M.dayCompletion(s, "2026-08-26")
  assert.equal(before, 0.5)
  s = M.carryOver(s, "2026-08-26", "2026-08-27", T2)
  assert.equal(M.dayCompletion(s, "2026-08-26"), 0.5, "history must stay true")
})

test("a day that migrated everything reads 0%, not 100% and not empty", () => {
  let s = seed({ "2026-08-26": ["a", "b"] })
  s = M.carryOver(s, "2026-08-26", "2026-08-27", T2)
  assert.equal(M.dayCompletion(s, "2026-08-26"), 0)
  assert.equal(M.tasksFor(s, "2026-08-27").length, 2)
})

test("a migrated day breaks the streak instead of faking a clean sweep", () => {
  // The 26th ends half-finished and pushes its remainder to the 28th, so the
  // 27th stays genuinely clean and the run can only be one day long.
  let s = seed({ "2026-08-27": ["+a"], "2026-08-26": ["+b", "c"], "2026-08-25": ["+d"] })
  s = M.carryOver(s, "2026-08-26", "2026-08-28", T2)
  assert.equal(M.dayCompletion(s, "2026-08-26"), 0.5, "still half-finished")
  assert.equal(M.dayCompletion(s, "2026-08-27"), 1)
  assert.equal(M.streak(s, "2026-08-27"), 1, "the 26th must not be forgiven")
})

test("carryOver is a no-op when there is nothing open, or nowhere to go", () => {
  const s = seed({ "2026-08-26": ["+a"] })
  assert.equal(M.carryOver(s, "2026-08-26", "2026-08-27", T2), s)
  assert.equal(M.carryOver(s, "2026-08-26", "2026-08-26", T2), s)
  assert.equal(M.carryOver(s, "nope", "2026-08-27", T2), s)
})

test("migrateBacklog sweeps every earlier day, oldest debt first", () => {
  let s = seed({
    "2026-08-20": ["oldest"],
    "2026-08-23": ["+finished", "middle"],
    "2026-08-26": ["newest"],
    "2026-08-27": ["already here"],
    "2026-08-28": ["tomorrow, untouched"],
  })
  s = M.migrateBacklog(s, "2026-08-27", "2026-08-27", T2)
  assert.deepEqual(
    M.tasksFor(s, "2026-08-27").map((t) => t.text),
    ["already here", "oldest", "middle", "newest"]
  )
  assert.deepEqual(M.tasksFor(s, "2026-08-23").map((t) => t.text), ["finished", "middle"])
  assert.equal(M.dayStats(s, "2026-08-23").ratio, 0.5, "the 23rd was and stays half-done")
  assert.deepEqual(M.tasksFor(s, "2026-08-28").map((t) => t.text), ["tomorrow, untouched"])
  assert.equal(M.openBefore(s, "2026-08-27"), 0)
})

test("carryTarget names where a migration lands, and hides on future days", () => {
  const today = "2026-08-27"
  assert.deepEqual(M.carryTarget(today, today), { key: "2026-08-28", label: "tomorrow" })
  assert.deepEqual(M.carryTarget("2026-08-20", today), { key: today, label: "today" })
  assert.equal(M.carryTarget("2026-08-28", today), null)
  assert.equal(M.carryTarget("nope", today), null)
})

// --- derived ----------------------------------------------------------------

test("stats counts an empty day without dividing by zero", () => {
  assert.deepEqual(M.stats([]), { total: 0, done: 0, open: 0, migrated: 0, ratio: 0 })
})

test("stats separates done, open, and migrated across one day", () => {
  const s = M.stats([{ done: true }, { done: false }, { done: false, migratedTo: "2026-08-28" }])
  assert.deepEqual(
    { total: s.total, done: s.done, open: s.open, migrated: s.migrated },
    { total: 3, done: 1, open: 1, migrated: 1 }
  )
  assert.equal(M.percent(s.ratio), 33, "a migrated task counts against the day")
})

test("dayCompletion distinguishes an empty day from an unfinished one", () => {
  const s = seed({ "2026-08-26": ["a"], "2026-08-25": ["+a"] })
  assert.equal(M.dayCompletion(s, "2026-08-24"), null, "never written")
  assert.equal(M.dayCompletion(s, "2026-08-26"), 0, "written, nothing done")
  assert.equal(M.dayCompletion(s, "2026-08-25"), 1)
})

test("openBefore and backlogKeys ignore the day itself and the future", () => {
  const s = seed({ "2026-08-25": ["a", "+b"], "2026-08-26": ["c"], "2026-08-27": ["d"], "2026-08-28": ["e"] })
  assert.deepEqual(M.backlogKeys(s, "2026-08-27"), ["2026-08-25", "2026-08-26"])
  assert.equal(M.openBefore(s, "2026-08-27"), 2)
})

test("rangeStats covers the window ending at the given day, inclusive", () => {
  const s = seed({ "2026-08-27": ["+a", "b"], "2026-08-26": ["+c"], "2026-08-20": ["d"] })
  const week = M.rangeStats(s, "2026-08-27", 7)
  assert.deepEqual(
    { total: week.total, done: week.done, activeDays: week.activeDays },
    { total: 3, done: 2, activeDays: 2 },
    "2026-08-20 is eight days back and must fall outside the window"
  )
  assert.equal(M.rangeStats(M.emptyStore(), "2026-08-27", 30).ratio, 0)
})

test("streak counts cleared days and breaks on a partial one", () => {
  const s = seed({ "2026-08-27": ["+a"], "2026-08-26": ["+b"], "2026-08-25": ["+c", "d"], "2026-08-24": ["+e"] })
  assert.equal(M.streak(s, "2026-08-27"), 2, "25th was partial, so the run stops there")
})

test("an empty today does not break yesterday's streak, but an empty gap does", () => {
  const s = seed({ "2026-08-26": ["+a"], "2026-08-25": ["+b"] })
  assert.equal(M.streak(s, "2026-08-27"), 2, "today has not happened yet")
  assert.equal(M.streak(seed({ "2026-08-25": ["+a"] }), "2026-08-27"), 0, "the 26th is a real gap")
})

test("mostDeferred ranks by migration count, then by age", () => {
  let s = seed({ "2026-08-20": ["old"], "2026-08-23": ["young"], "2026-08-26": ["never moved"] })
  s = M.carryOver(s, "2026-08-20", "2026-08-27", T2)
  s = M.carryOver(s, "2026-08-23", "2026-08-27", T2)
  s = M.carryOver(s, "2026-08-27", "2026-08-28", T2)
  const ranked = M.mostDeferred(s, 5)
  assert.deepEqual(ranked.map((t) => t.text), ["old", "young"])
  assert.equal(ranked[0].migrations, 2)
  assert.equal(ranked[0].origin, "2026-08-20")
})

test("mostDeferred skips finished tasks however often they moved", () => {
  let s = seed({ "2026-08-25": ["a"] })
  s = M.carryOver(s, "2026-08-25", "2026-08-27", T2)
  s = M.toggleTask(s, "2026-08-27", M.tasksFor(s, "2026-08-27")[0].id, T2)
  assert.deepEqual(M.mostDeferred(s, 5), [])
})

test("mostDeferred lists each task once, not once per tombstone", () => {
  let s = seed({ "2026-08-25": ["a"] })
  s = M.carryOver(s, "2026-08-25", "2026-08-26", T1)
  s = M.carryOver(s, "2026-08-26", "2026-08-27", T2)
  const ranked = M.mostDeferred(s, 5)
  assert.equal(ranked.length, 1)
  assert.equal(ranked[0].migrations, 2)
})

// --- the bar pill -----------------------------------------------------------

test("pillText renders each mode", () => {
  const s = M.stats([{ done: true }, { done: false }, { done: false }])
  assert.equal(M.pillText("ratio", s, "I"), "I 1/3")
  assert.equal(M.pillText("count", s, "I"), "I 2")
  assert.equal(M.pillText("percent", s, "I"), "I 33%")
  assert.equal(M.pillText("icon", s, "I"), "I")
})

test("pillText falls back to the bare glyph on an empty day", () => {
  const empty = M.stats([])
  for (const mode of ["ratio", "count", "percent", "icon"])
    assert.equal(M.pillText(mode, empty, "I"), "I")
})

test("percent rounds rather than truncates", () => {
  assert.equal(M.percent(2 / 3), 67)
  assert.equal(M.percent(0), 0)
  assert.equal(M.percent(1), 100)
})

// --- merging two devices -----------------------------------------------------
//
// The property that matters is convergence: whichever order the two machines
// see each other's writes in, they must end up holding the same journal. Every
// test below that calls `converge` is asserting exactly that, by merging in
// both directions and comparing.

// Compare content, not order. Order within a day follows the local list by
// design — it is what J/K controls — so it is the one thing allowed to differ.
function content(store) {
  const out = {}
  for (const day of Object.keys(store.days).sort()) {
    out[day] = M.rawTasksFor(store, day)
      .map((t) => JSON.stringify(t, Object.keys(t).sort()))
      .sort()
  }
  return out
}

function converge(a, b) {
  const ab = M.mergeStores(a, b)
  const ba = M.mergeStores(b, a)
  assert.deepEqual(content(ab), content(ba), "merge must not depend on which side is local")
  // And settling twice must change nothing, or the two devices write back and
  // forth forever.
  assert.deepEqual(content(M.mergeStores(ab, ba)), content(ab), "merge must be idempotent")
  return ab
}

test("a task added on each device survives on both", () => {
  const laptop = M.addTask(M.emptyStore(), "2026-08-27", "from the laptop", T2, "aaaa")
  const desktop = M.addTask(M.emptyStore(), "2026-08-27", "from the desktop", T2, "bbbb")
  const merged = converge(laptop, desktop)
  assert.deepEqual(
    M.tasksFor(merged, "2026-08-27").map((t) => t.text).sort(),
    ["from the desktop", "from the laptop"]
  )
})

test("two devices adding in the same millisecond do not collide into one task", () => {
  // This is the bug the device tag exists to prevent. Without it both sides
  // mint the same id and the merge welds two different tasks together.
  const a = M.addTask(M.emptyStore(), "2026-08-27", "call the bank", T2, "aaaa")
  const b = M.addTask(M.emptyStore(), "2026-08-27", "renew the domain", T2, "bbbb")
  assert.notEqual(
    M.tasksFor(a, "2026-08-27")[0].id,
    M.tasksFor(b, "2026-08-27")[0].id
  )
  assert.equal(M.tasksFor(converge(a, b), "2026-08-27").length, 2)
})

test("finishing on one device wins, and keeps the earlier completion time", () => {
  const base = M.addTask(M.emptyStore(), "2026-08-27", "ship it", T0, "aaaa")
  const id = M.tasksFor(base, "2026-08-27")[0].id
  const done = M.toggleTask(base, "2026-08-27", id, T1)
  const merged = converge(done, base)
  const task = M.tasksFor(merged, "2026-08-27")[0]
  assert.equal(task.done, true)
  assert.equal(task.doneAt, T1)
})

test("deleting on one device propagates instead of being resurrected", () => {
  const base = M.addTask(M.emptyStore(), "2026-08-27", "drop me", T0, "aaaa")
  const id = M.tasksFor(base, "2026-08-27")[0].id
  const gone = M.deleteTask(base, "2026-08-27", id, T1)
  const merged = converge(gone, base)
  assert.deepEqual(M.tasksFor(merged, "2026-08-27"), [], "the other device must not bring it back")
  assert.equal(M.rawTasksFor(merged, "2026-08-27")[0].deleted, true)
})

test("deleting outranks finishing", () => {
  const base = M.addTask(M.emptyStore(), "2026-08-27", "x", T0, "aaaa")
  const id = M.tasksFor(base, "2026-08-27")[0].id
  const merged = converge(
    M.deleteTask(base, "2026-08-27", id, T1),
    M.toggleTask(base, "2026-08-27", id, T1)
  )
  assert.deepEqual(M.tasksFor(merged, "2026-08-27"), [])
})

test("the later edit wins the text, and a tie keeps what is already here", () => {
  const base = M.addTask(M.emptyStore(), "2026-08-27", "original", T0, "aaaa")
  const id = M.tasksFor(base, "2026-08-27")[0].id
  const early = M.editTask(base, "2026-08-27", id, "edited early", T1)
  const late = M.editTask(base, "2026-08-27", id, "edited late", T2)
  assert.equal(M.tasksFor(converge(early, late), "2026-08-27")[0].text, "edited late")
  // Same instant on both sides: local text stands, and both sides still agree
  // on every other field.
  const tieA = M.editTask(base, "2026-08-27", id, "aaa", T1)
  const tieB = M.editTask(base, "2026-08-27", id, "bbb", T1)
  assert.equal(M.mergeStores(tieA, tieB).days["2026-08-27"][0].text, "aaa")
  assert.equal(M.mergeStores(tieB, tieA).days["2026-08-27"][0].text, "bbb")
})

test("both devices pulling the same backlog forward yields one task, not two", () => {
  // The realistic collision: you open the journal on both machines the same
  // morning and hit the backlog banner on each. Deriving the migrated copy's
  // id from the source and the target is what makes these the same task.
  let base = M.addTask(M.emptyStore(), "2026-08-25", "call the accountant", T0, "aaaa")
  const laptop = M.migrateBacklog(base, "2026-08-27", "2026-08-27", T1)
  const desktop = M.migrateBacklog(base, "2026-08-27", "2026-08-27", T2)
  const merged = converge(laptop, desktop)
  assert.equal(M.tasksFor(merged, "2026-08-27").length, 1, "one copy, not one per device")
  assert.equal(M.tasksFor(merged, "2026-08-27")[0].migrations, 1)
  assert.equal(M.rawTasksFor(merged, "2026-08-25")[0].migratedTo, "2026-08-27")
})

test("migrating to different days on each device settles deterministically", () => {
  let base = M.addTask(M.emptyStore(), "2026-08-25", "renew the domain", T0, "aaaa")
  const toThe26th = M.carryOver(base, "2026-08-25", "2026-08-26", T1)
  const toThe27th = M.carryOver(base, "2026-08-25", "2026-08-27", T2)
  const merged = converge(toThe26th, toThe27th)
  // The earlier migration decided where the original went...
  assert.equal(M.rawTasksFor(merged, "2026-08-25")[0].migratedTo, "2026-08-26")
  // ...but each device already made its own copy, and a two-way merge with no
  // common ancestor cannot know they are the same work. This is the one case
  // that leaves a duplicate, and it is documented as such.
  assert.equal(M.tasksFor(merged, "2026-08-26").length, 1)
  assert.equal(M.tasksFor(merged, "2026-08-27").length, 1)
})

test("migrations never counts down", () => {
  let base = M.addTask(M.emptyStore(), "2026-08-25", "x", T0, "aaaa")
  const once = M.carryOver(base, "2026-08-25", "2026-08-26", T1)
  const twice = M.carryOver(once, "2026-08-26", "2026-08-27", T2)
  const merged = converge(twice, once)
  assert.equal(M.tasksFor(merged, "2026-08-27")[0].migrations, 2)
})

test("a device that has never seen the journal adopts it whole", () => {
  const full = seed({ "2026-08-25": ["+a", "b"], "2026-08-27": ["c"] })
  const merged = converge(M.emptyStore(), full)
  assert.deepEqual(content(merged), content(full))
})

test("merging a journal with itself changes nothing", () => {
  const s = seed({ "2026-08-25": ["+a", "b"], "2026-08-26": ["c"] })
  assert.deepEqual(content(M.mergeStores(s, s)), content(s))
})

test("a three-way round trip converges after one exchange each way", () => {
  // laptop and desktop both diverge from a shared base, then each reads the
  // other's file once. Both must end up holding the same journal.
  const base = seed({ "2026-08-27": ["shared"] })
  const sharedId = M.tasksFor(base, "2026-08-27")[0].id

  let laptop = M.addTask(base, "2026-08-27", "laptop only", T1, "aaaa")
  laptop = M.toggleTask(laptop, "2026-08-27", sharedId, T1)

  let desktop = M.addTask(base, "2026-08-27", "desktop only", T1, "bbbb")
  desktop = M.editTask(desktop, "2026-08-27", sharedId, "shared, renamed", T2)

  const laptopSees = M.mergeStores(laptop, desktop)
  const desktopSees = M.mergeStores(desktop, laptop)
  assert.deepEqual(content(laptopSees), content(desktopSees))

  const settled = M.tasksFor(laptopSees, "2026-08-27")
  assert.equal(settled.length, 3)
  const shared = settled.find((t) => t.id === sharedId)
  assert.equal(shared.done, true, "the laptop finished it")
  assert.equal(shared.text, "shared, renamed", "the desktop renamed it later")
})

test("merge tolerates a corrupt file on the other side", () => {
  const mine = seed({ "2026-08-27": ["keep me"] })
  const merged = M.mergeStores(mine, M.normalizeStore('{"days":{"2026-08-27":[{"text"'))
  assert.deepEqual(content(merged), content(mine))
})
