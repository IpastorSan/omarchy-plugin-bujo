import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Ui
import qs.Commons
import "../Model.js" as Model
import "../components"

// A month at a glance. Each square carries a dot saying how that day went, so
// a streak — or a week you abandoned — is visible without opening anything.
Item {
  id: view

  property var panel: null
  property bool editing: false

  property int cursorRow: 0
  property int cursorCol: 0
  property bool cursorActive: false

  readonly property color foreground: panel && panel.bar ? panel.bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: panel && panel.bar ? panel.bar.fontFamily : Style.font.family
  readonly property color accent: Color.accent

  readonly property var labelLocale: Qt.locale()
  readonly property int weekStart: panel ? panel.weekStart : 1
  readonly property var weekdays: Model.weekdayOrder(weekStart)
  readonly property var weeks: panel
    ? Model.monthGrid(panel.viewYear, panel.viewMonth, weekStart, panel.todayKey)
    : []

  readonly property string monthLabel: panel
    ? Qt.formatDate(new Date(panel.viewYear, panel.viewMonth, 1), "MMMM yyyy")
    : ""

  implicitHeight: column.implicitHeight

  onPanelChanged: if (panel) Qt.callLater(view.syncCursorToSelection)

  function weekdayLabel(weekday) {
    return String(labelLocale.dayName(weekday, Locale.ShortFormat)).slice(0, 2).toUpperCase()
  }

  function completionFor(key) {
    return panel ? Model.dayCompletion(panel.journal, key) : null
  }

  function cellAt(row, col) {
    if (row < 0 || row >= view.weeks.length) return null
    return view.weeks[row].days[col]
  }

  function syncCursorToSelection() {
    if (!panel) return
    for (var r = 0; r < view.weeks.length; r++) {
      for (var c = 0; c < 7; c++) {
        if (view.weeks[r].days[c].key === panel.viewedKey) {
          view.cursorRow = r
          view.cursorCol = c
          return
        }
      }
    }
  }

  // --- the contract Panel.qml calls into ------------------------------------

  function move(dx, dy) {
    if (!view.cursorActive) { view.cursorActive = true; view.syncCursorToSelection(); return }
    var col = view.cursorCol + dx
    var row = view.cursorRow + dy
    // Walking off an edge pages the month rather than stopping dead, so a whole
    // year is reachable with one key.
    if (col < 0) { col = 6; row -= 1 }
    else if (col > 6) { col = 0; row += 1 }
    if (row < 0) { view.stepMonth(-1); row = 0 }
    else if (row >= view.weeks.length) { view.stepMonth(1); row = view.weeks.length - 1 }
    view.cursorRow = Math.max(0, Math.min(view.weeks.length - 1, row))
    view.cursorCol = Math.max(0, Math.min(6, col))
  }

  function activate() {
    var cell = view.cellAt(view.cursorRow, view.cursorCol)
    if (cell && panel) panel.selectDay(cell.key)
  }

  function stepMonth(delta) {
    if (!panel) return
    var next = Model.stepMonth(panel.viewYear, panel.viewMonth, delta)
    panel.viewYear = next.year
    panel.viewMonth = next.month
  }

  ColumnLayout {
    id: column
    anchors.left: parent.left
    anchors.right: parent.right
    spacing: Style.space(10)

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(8)

      PanelActionButton {
        iconText: "‹"
        foreground: view.foreground
        fontFamily: view.fontFamily
        onClicked: view.stepMonth(-1)
      }

      Text {
        Layout.fillWidth: true
        text: view.monthLabel
        color: view.foreground
        font.family: view.fontFamily
        font.pixelSize: Style.font.subtitle
        horizontalAlignment: Text.AlignHCenter
      }

      PanelActionButton {
        iconText: "›"
        foreground: view.foreground
        fontFamily: view.fontFamily
        onClicked: view.stepMonth(1)
      }
    }

    // The grid keeps its own tight spacing: as a direct child of `column` each
    // week row would inherit the 10px gap meant for separating sections, and a
    // calendar with section-sized gutters between weeks reads as seven lists.
    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.space(2)

    // ---- weekday headings --------------------------------------------------
    RowLayout {
      Layout.fillWidth: true
      Layout.bottomMargin: Style.space(2)
      spacing: Style.space(2)

      Repeater {
        model: view.weekdays
        Text {
          required property var modelData
          Layout.fillWidth: true
          Layout.preferredWidth: 1
          text: view.weekdayLabel(modelData)
          color: view.dim
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }

    // ---- the grid ----------------------------------------------------------
    Repeater {
      model: view.weeks

      RowLayout {
        id: weekRow
        required property var modelData
        required property int index
        Layout.fillWidth: true
        spacing: Style.space(2)

        Repeater {
          model: weekRow.modelData.days

          DayCell {
            id: cell
            required property var modelData
            required property int index
            Layout.fillWidth: true
            // Equal columns: fillWidth alone would size each cell to its own
            // content and make a "1" narrower than a "28".
            Layout.preferredWidth: 1
            Layout.preferredHeight: Style.space(34)
            day: cell.modelData
            completion: view.completionFor(cell.modelData.key)
            selected: view.panel ? cell.modelData.key === view.panel.viewedKey : false
            hasCursor: view.cursorActive
              && view.cursorRow === weekRow.index
              && view.cursorCol === cell.index
            foreground: view.foreground
            fontFamily: view.fontFamily
            onHovered: {
              view.cursorActive = true
              view.cursorRow = weekRow.index
              view.cursorCol = cell.index
            }
            onPicked: if (view.panel) view.panel.selectDay(cell.modelData.key)
          }
        }
      }
    }
    }

    PanelSeparator { Layout.fillWidth: true; foreground: view.foreground }

    // ---- what the month added up to ----------------------------------------
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(8)

      Text {
        Layout.fillWidth: true
        text: "Back to the day"
        color: view.accent
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: if (view.panel) view.panel.view = "day"
        }
      }

      Text {
        text: "m · esc"
        color: view.dim
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
