import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Bar entry point. Roots at qs.Ui Panel — the same shape the first-party panels
// use — which supplies bar/moduleName/settings/setting(), the
// opened/open/close/closeForPopoutSwitch contract the bar's popout routing
// requires, and a PanelController. manageIpc:false so this file owns the single
// IpcHandler on the target and can add bujo's own methods to it.
Panel {
  id: root

  moduleName: "io.github.ipastorsan.bujo"
  ipcTarget: "bujo"
  manageIpc: false

  // Nerd Font, shipped with Omarchy: an unchecked and a checked box.
  readonly property string glyphOpen: "󰄱"
  readonly property string glyphDone: "󰄲"

  // --- time ----------------------------------------------------------------

  // The one place "now" enters the plugin. Model is pure and takes it as an
  // argument, which is what makes the migration logic testable.
  property string todayKey: Model.keyForDate(new Date())
  function nowIso() { return new Date().toISOString() }

  // The day on screen. Starts at today and is the only thing the chevrons move.
  property string viewedKey: todayKey
  property string view: "day"          // day | month | summary

  // Month shown by the calendar, independent of the selected day so paging
  // through months does not move the selection.
  property int viewYear: new Date().getFullYear()
  property int viewMonth: new Date().getMonth()

  readonly property var weekStart: Model.normalizedWeekStart(
    setting("weekStartDay", "locale"), Qt.locale().firstDayOfWeek)

  function goToday() {
    root.viewedKey = root.todayKey
    root.syncMonthToViewed()
    root.view = "day"
  }

  function stepDay(delta) {
    root.viewedKey = Model.shiftKey(root.viewedKey, delta)
    root.syncMonthToViewed()
  }

  function syncMonthToViewed() {
    var d = Model.parseKey(root.viewedKey)
    if (!d) return
    root.viewYear = d.getFullYear()
    root.viewMonth = d.getMonth()
  }

  function selectDay(key) {
    root.viewedKey = key
    root.syncMonthToViewed()
    root.view = "day"
  }

  // --- store ---------------------------------------------------------------

  Store {
    id: store
    overridePath: root.setting("statePath", "")
  }

  // Reading the device id is a subprocess, so for the first moments of a
  // session there is no device to stamp an id with. Falling back to a constant
  // would make every machine's earliest tasks share a tag, which is exactly the
  // collision the tag exists to prevent — and the first task of a session is
  // precisely when someone types into a freshly opened panel. Hold them.
  property var pendingAdds: []

  Connections {
    target: store
    function onDeviceIdChanged() {
      if (!store.deviceId || !root.pendingAdds.length) return
      var queued = root.pendingAdds
      root.pendingAdds = []
      var next = root.journal
      for (var i = 0; i < queued.length; i++) {
        next = Model.addTask(next, queued[i].key, queued[i].text, root.nowIso(), store.deviceId)
      }
      store.commit(next)
    }
  }

  readonly property var journal: store.journal
  readonly property var todayStats: Model.dayStats(root.journal, root.todayKey)

  function addTask(text) {
    if (!store.deviceId) { pendingAdds.push({ key: root.viewedKey, text: text }); return }
    store.commit(Model.addTask(root.journal, root.viewedKey, text, root.nowIso(), store.deviceId))
  }
  function toggleTask(id) {
    store.commit(Model.toggleTask(root.journal, root.viewedKey, id, root.nowIso()))
  }
  function editTask(id, text) {
    store.commit(Model.editTask(root.journal, root.viewedKey, id, text, root.nowIso()))
  }
  function deleteTask(id) {
    store.commit(Model.deleteTask(root.journal, root.viewedKey, id, root.nowIso()))
  }
  function moveTask(id, delta) {
    store.commit(Model.moveTask(root.journal, root.viewedKey, id, delta))
  }

  // Migrate the day on screen. The destination is whatever carryTarget names,
  // so the button label and the action can never disagree.
  function migrateViewed() {
    var target = Model.carryTarget(root.viewedKey, root.todayKey)
    if (!target) return 0
    var before = Model.dayStats(root.journal, root.viewedKey).open
    if (!before) return 0
    store.commit(Model.carryOver(root.journal, root.viewedKey, target.key, root.nowIso()))
    return before
  }

  // Everything still open from before today, pulled onto today at once.
  function migrateBacklog() {
    var n = Model.openBefore(root.journal, root.todayKey)
    if (!n) return 0
    store.commit(Model.migrateBacklog(root.journal, root.todayKey, root.todayKey, root.nowIso()))
    return n
  }

  // --- bar pill ------------------------------------------------------------

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property bool todayClear: root.todayStats.total > 0 && root.todayStats.open === 0
  readonly property string pillGlyph: root.todayClear ? root.glyphDone : root.glyphOpen

  // WidgetButton, not BarIconButton: the latter hides its label and pins itself
  // to a fixed icon slot, which would clip "󰄲 2/5" down to the glyph.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.pillText(root.setting("pillMode", "ratio"), root.todayStats, root.pillGlyph)
    fontSize: Style.font.caption
    horizontalMargin: 6
    // Dim only a day nothing has been written on. A day with work left is the
    // whole reason the widget is there, so it stays at full strength.
    dimmed: root.todayStats.total === 0 && root.setting("dimWhenEmpty", true)
    // Colour the pill when today is fully cleared — the one moment worth a nudge.
    active: root.todayClear
    tooltipText: root.todayStats.total === 0
      ? "Nothing written today"
      : root.todayStats.done + " of " + root.todayStats.total + " done"
         + (root.backlogCount > 0 ? " · " + root.backlogCount + " open from earlier" : "")

    onPressed: function (b) {
      // Right-click snaps back to today without opening anything, so a widget
      // left on last week is one click from useful.
      if (b === Qt.RightButton) { root.goToday(); return }
      if (b === Qt.MiddleButton) { root.goToday(); root.open(); root.requestQuickAdd(); return }
      root.toggle()
    }
  }

  readonly property int backlogCount: Model.openBefore(root.journal, root.todayKey)

  signal requestQuickAdd()

  // Rolls the pill over at midnight without a restart. Re-armed on every tick
  // rather than left repeating, because the interval to the next midnight is
  // different every time and DST makes it not exactly 24h.
  function msUntilMidnight() {
    var now = new Date()
    var next = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1, 0, 0, 5)
    return Math.max(1000, next - now)
  }

  Timer {
    id: midnight
    running: true
    repeat: false
    // Assigned, not bound. A binding over `new Date()` depends on nothing
    // reactive, so it evaluates once and restart() then reuses the very first
    // value forever: a shell started at 10:00 keeps firing 14 hours apart, and
    // the day rolls over hours late from the second night onward.
    interval: root.msUntilMidnight()
    onTriggered: {
      var wasToday = root.viewedKey === root.todayKey
      root.todayKey = Model.keyForDate(new Date())
      if (wasToday) root.goToday()
      midnight.interval = root.msUntilMidnight()
      midnight.restart()
    }
  }

  onOpenedChanged: {
    if (opened) {
      // Re-read before showing anything. The file watch normally keeps this
      // current, but it can miss an edit that lands in the moment after our own
      // atomic write swaps the inode — and pointing statePath at a synced
      // folder makes outside edits routine. Opening the panel is exactly when
      // stale contents would be seen, and re-reading a file this small is free.
      // Deferred, not immediate: reload() can deliver onLoaded synchronously,
      // and replacing the journal in the middle of the open transition
      // re-evaluates every binding under a panel that is still being laid out.
      Qt.callLater(store.reloadNow)
      // The panel always lands on today's list. Reopening on the calendar you
      // happened to close from, or on a day from last week, is disorienting —
      // the day is the primary screen and the other two are excursions. The
      // IPC view()/day() calls open first and select after, so an explicit
      // destination still wins over this.
      if (root.view !== "day") root.view = "day"
      if (Model.daysBetween(root.viewedKey, root.todayKey) !== 0) root.goToday()
      Qt.callLater(function () { keyCatcher.forceActiveFocus() })
    }
  }

  // --- popup ---------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(viewLoader.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      // Freeze navigation whenever a text field owns input, or typing a task
      // containing "j" walks the cursor down the list instead.
      blocked: viewLoader.item ? viewLoader.item.editing === true : false

      onCloseRequested: root.close()
      onMoveRequested: function (dx, dy) {
        if (viewLoader.item && viewLoader.item.move) viewLoader.item.move(dx, dy)
      }
      onActivateRequested: if (viewLoader.item && viewLoader.item.activate) viewLoader.item.activate()
      onDeleteRequested: if (viewLoader.item && viewLoader.item.remove) viewLoader.item.remove()
      onTabRequested: function (d) { root.switchPanel(d) }

      onTextKey: function (t) {
        switch (t) {
        case "a": case "i": root.requestQuickAdd(); break
        case "g": root.goToday(); break
        case "m": root.view = root.view === "month" ? "day" : "month"; break
        case "s": root.view = root.view === "summary" ? "day" : "summary"; break
        case "c": root.migrateViewed(); break
        case "?": root.showHelp = !root.showHelp; break
        default:
          if (viewLoader.item && viewLoader.item.textKey) viewLoader.item.textKey(t)
        }
      }

      Loader {
        id: viewLoader
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        source: Qt.resolvedUrl("views/" + (root.view === "month" ? "MonthView.qml"
                                        : root.view === "summary" ? "SummaryView.qml"
                                        : "DayView.qml"))
        // onLoaded runs AFTER the child's Component.onCompleted, so a view that
        // reads `panel` on completion sees null. Views react to onPanelChanged
        // instead; this only hands over the reference.
        onLoaded: if (item) item.panel = root
      }
    }
  }

  property bool showHelp: false

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }

    // Opens, like view() and day() do. "Take me to today" that leaves the panel
    // shut is not what any caller means, least of all a keybinding.
    function today(): string {
      root.open()
      root.goToday()
      return root.todayKey
    }

    // Jump straight to a screen or a date, so the panel is scriptable from a
    // keybinding: `omarchy-shell bujo view month`, `bujo day 2026-08-25`.
    // Open BEFORE selecting, in both of these. Opening runs the
    // land-on-today reset synchronously, so selecting first would have the
    // reset silently undo the caller's choice.
    function view(name: string): string {
      var wanted = String(name || "").trim().toLowerCase()
      if (["day", "month", "summary"].indexOf(wanted) === -1) return "unknown view: " + wanted
      root.open()
      root.view = wanted
      return wanted
    }

    function day(key: string): string {
      var wanted = String(key || "").trim()
      if (!Model.isKey(wanted)) return "expected yyyy-MM-dd"
      root.open()
      root.selectDay(wanted)
      return wanted
    }

    // Quick capture from anywhere: `omarchy-shell bujo add "call the bank"`.
    // Lands on today, not on whatever day the panel happens to be showing.
    function add(text: string): string {
      var clean = String(text || "").trim()
      if (!clean) return "empty"
      if (!store.deviceId) { pendingAdds.push({ key: root.todayKey, text: clean }); return "queued" }
      store.commit(Model.addTask(root.journal, root.todayKey, clean, root.nowIso(), store.deviceId))
      return "ok"
    }

    function migrate(): string {
      var n = root.migrateBacklog()
      return "migrated " + n
    }

    function status(): string {
      var s = root.todayStats
      return JSON.stringify({
        today: root.todayKey,
        opened: root.opened,
        view: root.view,
        viewed: root.viewedKey,
        total: s.total,
        done: s.done,
        open: s.open,
        migrated: s.migrated,
        percent: Model.percent(s.ratio),
        backlog: root.backlogCount,
        streak: Model.streak(root.journal, root.todayKey),
        path: store.resolvedPath,
        device: store.deviceId,
        ready: store.ready,
        loads: store.loadCount,
        changes: store.changeCount,
        writes: store.writeCount
      })
    }
  }
}
