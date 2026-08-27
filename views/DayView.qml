import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Ui
import qs.Commons
import "../Model.js" as Model
import "../components"

// The day on screen: its date, how it went, what is on it, and the one button
// that moves what is left somewhere it can still be done.
Item {
  id: view

  property var panel: null
  // Read by Panel.qml's PanelKeyCatcher: while true, keys belong to the editor
  // and must not walk the cursor.
  property bool editing: false

  property int cursor: 0
  property bool cursorActive: false
  property string editingId: ""

  readonly property color foreground: panel && panel.bar ? panel.bar.foreground : Color.foreground
  readonly property color urgent: panel && panel.bar ? panel.bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: panel && panel.bar ? panel.bar.fontFamily : Style.font.family
  readonly property color accent: Color.accent

  readonly property string dayKey: panel ? panel.viewedKey : ""
  readonly property var tasks: panel ? Model.tasksFor(panel.journal, dayKey) : []
  readonly property var stats: panel ? Model.dayStats(panel.journal, dayKey) : Model.stats([])
  readonly property var target: panel ? Model.carryTarget(dayKey, panel.todayKey) : null
  readonly property int backlog: panel ? panel.backlogCount : 0
  readonly property bool isToday: panel ? dayKey === panel.todayKey : false

  readonly property string relative: panel ? Model.relativeDayLabel(dayKey, panel.todayKey) : ""
  readonly property string dateLabel: {
    var d = Model.parseKey(dayKey)
    return d ? Qt.formatDate(d, "ddd d MMM yyyy") : ""
  }

  implicitHeight: column.implicitHeight

  // The Loader assigns `panel` after this object completes, so first focus has
  // to hang off the property change, not Component.onCompleted.
  onPanelChanged: if (panel) {
    panel.requestQuickAdd.connect(view.beginAdd)
    Qt.callLater(view.clampCursor)
  }
  onDayKeyChanged: { view.cursor = 0; view.cursorActive = false; view.endEdit() }

  function clampCursor() {
    if (view.cursor >= view.tasks.length) view.cursor = Math.max(0, view.tasks.length - 1)
    if (view.cursor < 0) view.cursor = 0
  }

  function beginAdd() {
    view.endEdit()
    addField.forceActiveFocus()
  }

  function endEdit() {
    view.editingId = ""
    view.editing = addField.activeFocus
  }

  function selected() {
    if (view.cursor < 0 || view.cursor >= view.tasks.length) return null
    return view.tasks[view.cursor]
  }

  // --- the contract Panel.qml calls into ------------------------------------

  function move(dx, dy) {
    if (dx !== 0) { if (panel) panel.stepDay(dx); return }
    if (!view.cursorActive) { view.cursorActive = true; return }
    if (!view.tasks.length) return
    view.cursor = Math.max(0, Math.min(view.tasks.length - 1, view.cursor + dy))
  }

  function activate() {
    var task = view.selected()
    if (!task || task.migratedTo) return
    view.cursorActive = true
    if (panel) panel.toggleTask(task.id)
  }

  function remove() {
    var task = view.selected()
    if (!task || !panel) return
    panel.deleteTask(task.id)
    Qt.callLater(view.clampCursor)
  }

  function textKey(t) {
    var task = view.selected()
    if (t === "e" && task && !task.migratedTo) { view.editingId = task.id; view.editing = true }
    else if (t === "J" && task) { panel.moveTask(task.id, 1); view.cursor = Math.min(view.tasks.length - 1, view.cursor + 1) }
    else if (t === "K" && task) { panel.moveTask(task.id, -1); view.cursor = Math.max(0, view.cursor - 1) }
  }

  ColumnLayout {
    id: column
    anchors.left: parent.left
    anchors.right: parent.right
    spacing: Style.space(10)

    // ---- date header, with the day steppers on its outer edges -------------
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(8)

      PanelActionButton {
        iconText: "‹"
        foreground: view.foreground
        fontFamily: view.fontFamily
        onClicked: if (view.panel) view.panel.stepDay(-1)
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: 0

        Text {
          Layout.fillWidth: true
          text: view.relative || view.dateLabel
          color: view.foreground
          font.family: view.fontFamily
          font.pixelSize: Style.font.subtitle
          elide: Text.ElideRight
        }
        Text {
          Layout.fillWidth: true
          visible: view.relative !== ""
          text: view.dateLabel
          color: view.dim
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        visible: !view.isToday
        text: "today"
        color: view.accent
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          cursorShape: Qt.PointingHandCursor
          onClicked: if (view.panel) view.panel.goToday()
        }
      }

      PanelActionButton {
        iconText: "›"
        foreground: view.foreground
        fontFamily: view.fontFamily
        onClicked: if (view.panel) view.panel.stepDay(1)
      }
    }

    // ---- how the day went --------------------------------------------------
    RowLayout {
      Layout.fillWidth: true
      visible: view.stats.total > 0
      spacing: Style.space(8)

      ProgressRail {
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        ratio: view.stats.ratio
        foreground: view.foreground
      }

      Text {
        text: view.stats.done + "/" + view.stats.total + " · " + Model.percent(view.stats.ratio) + "%"
        color: view.dim
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // ---- the debt banner ---------------------------------------------------
    //
    // The daily ritual, compressed to one click: everything still open from any
    // earlier day, pulled onto today together.
    CursorSurface {
      Layout.fillWidth: true
      visible: view.isToday && view.backlog > 0
      bordered: true
      foreground: view.foreground
      implicitHeight: banner.implicitHeight + Style.spacing.rowPaddingX

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: if (view.panel) view.panel.migrateBacklog()
      }

      RowLayout {
        id: banner
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(10)
        spacing: Style.space(8)

        Text {
          text: "󰃰"
          color: view.urgent
          font.family: view.fontFamily
          font.pixelSize: Style.font.icon
        }
        Text {
          Layout.fillWidth: true
          text: view.backlog + (view.backlog === 1 ? " task open from earlier" : " tasks open from earlier")
          color: view.foreground
          font.family: view.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
        Text {
          text: "pull in →"
          color: view.accent
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    PanelSeparator { Layout.fillWidth: true; foreground: view.foreground; visible: view.tasks.length > 0 }

    // ---- the day itself ----------------------------------------------------
    Text {
      Layout.fillWidth: true
      visible: view.tasks.length === 0
      text: view.isToday ? "Nothing written today.\nType below to start the day."
                         : "Nothing written on this day."
      color: view.dim
      font.family: view.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      Layout.topMargin: Style.space(6)
      Layout.bottomMargin: Style.space(6)
    }

    Flickable {
      Layout.fillWidth: true
      Layout.preferredHeight: Math.min(taskColumn.implicitHeight, Style.space(300))
      visible: view.tasks.length > 0
      contentWidth: width
      contentHeight: taskColumn.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: taskColumn
        width: parent.width
        spacing: Style.space(2)

        Repeater {
          model: view.tasks

          Item {
            id: slot
            required property var modelData
            required property int index
            width: taskColumn.width
            implicitHeight: Math.max(row.implicitHeight, editor.visible ? editor.implicitHeight : 0)

            TaskRow {
              id: row
              width: parent.width
              visible: view.editingId !== slot.modelData.id
              task: slot.modelData
              rowIndex: slot.index
              showMigrationMarks: view.panel ? view.panel.setting("showMigrationMarks", true) : true
              fontFamily: view.fontFamily
              foreground: view.foreground
              hasCursor: view.cursorActive && view.cursor === slot.index
              onHovered: { view.cursorActive = true; view.cursor = slot.index }
              onToggled: if (view.panel) view.panel.toggleTask(slot.modelData.id)
              onEditRequested: { view.editingId = slot.modelData.id; view.editing = true }
            }

            // Inline rename, in place, so the list never jumps.
            TextField {
              id: editor
              width: parent.width
              visible: view.editingId === slot.modelData.id
              text: slot.modelData.text
              foreground: view.foreground
              font.family: view.fontFamily
              onVisibleChanged: if (visible) { forceActiveFocus(); selectAll() }
              onActiveFocusChanged: view.editing = activeFocus || addField.activeFocus
              Keys.onEscapePressed: view.endEdit()
              onAccepted: {
                if (view.panel) view.panel.editTask(slot.modelData.id, text)
                view.endEdit()
              }
            }
          }
        }
      }
    }

    // ---- capture -----------------------------------------------------------
    TextField {
      id: addField
      Layout.fillWidth: true
      placeholderText: view.isToday ? "Add a task for today" : "Add a task for " + view.dateLabel
      foreground: view.foreground
      font.family: view.fontFamily
      // Adding stays armed after each entry: writing the day's list is one
      // burst of typing, not six round trips to the mouse.
      onActiveFocusChanged: view.editing = activeFocus || view.editingId !== ""
      Keys.onEscapePressed: { addField.text = ""; addField.focus = false; view.endEdit() }
      onAccepted: {
        var value = addField.text
        if (!value || !value.trim()) return
        if (view.panel) view.panel.addTask(value)
        addField.text = ""
        addField.forceActiveFocus()
      }
    }

    // ---- migrate -----------------------------------------------------------
    Button {
      Layout.fillWidth: true
      visible: view.target !== null && view.stats.open > 0
      bordered: true
      focusable: false
      foreground: view.foreground
      fontFamily: view.fontFamily
      // The destination is named, always. A migrate button that does not say
      // where things land is a button people stop trusting.
      text: view.target
        ? "Migrate " + view.stats.open + " open → " + view.target.label
        : ""
      onClicked: if (view.panel) view.panel.migrateViewed()
    }

    Text {
      Layout.fillWidth: true
      visible: view.panel ? view.panel.showHelp : false
      text: "j/k move · space done · e edit · x delete · J/K reorder\n"
          + "h/l day · g today · m month · s summary · c migrate · a add"
      color: view.dim
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }
}
