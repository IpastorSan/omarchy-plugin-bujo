import QtQuick
import QtQuick.Layouts
import qs.Ui
import qs.Commons
import "../Model.js" as Model

// One line of the journal.
//
// Three states, borrowed from paper notation: an open box, a checked box, and a
// migrated entry struck through with `›` and the day it went to. A migrated row
// is history — it renders, it is not actionable.
CursorSurface {
  id: row

  property var task: null
  property int rowIndex: 0
  property bool showMigrationMarks: true
  property string fontFamily: Style.font.family

  readonly property bool done: task ? task.done === true : false
  readonly property bool migrated: task ? !!task.migratedTo : false
  readonly property int migrations: task ? Number(task.migrations) || 0 : 0

  signal toggled()
  signal hovered()
  signal editRequested()

  implicitHeight: content.implicitHeight + Style.spacing.rowPaddingX
  foreground: Color.foreground

  // Hover sets the panel's cursor rather than painting this row directly —
  // CursorSurface's contract, and what keeps exactly one highlight on screen
  // across keyboard and mouse both.
  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: row.migrated ? Qt.ArrowCursor : Qt.PointingHandCursor
    onEntered: row.hovered()
    onClicked: function (mouse) {
      if (row.migrated) return
      if (mouse.button === Qt.RightButton) row.editRequested()
      else row.toggled()
    }
  }

  RowLayout {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(10)
    spacing: Style.space(8)

    Text {
      text: row.migrated ? "›" : (row.done ? "󰄲" : "󰄱")
      color: row.foreground
      opacity: row.migrated ? 0.45 : (row.done ? 0.65 : 1.0)
      font.family: row.fontFamily
      font.pixelSize: Style.font.icon
      Layout.alignment: Qt.AlignVCenter
    }

    Text {
      Layout.fillWidth: true
      text: row.task ? row.task.text : ""
      color: row.foreground
      opacity: row.migrated ? 0.45 : (row.done ? 0.55 : 1.0)
      font.family: row.fontFamily
      font.pixelSize: Style.font.body
      font.strikeout: row.done
      font.italic: row.migrated
      elide: Text.ElideRight
    }

    // How many times this has been pushed forward. Two is a nudge; five is the
    // journal telling you to either do it or drop it.
    Text {
      visible: row.showMigrationMarks && !row.migrated && row.migrations > 0
      text: "»" + (row.migrations > 1 ? row.migrations : "")
      color: row.migrations >= 3 ? Color.urgent : row.foreground
      opacity: row.migrations >= 3 ? 0.9 : 0.5
      font.family: row.fontFamily
      font.pixelSize: Style.font.caption
      Layout.alignment: Qt.AlignVCenter
    }

    // Where a migrated entry went.
    Text {
      visible: row.migrated
      // Guarded, not just `visible`. QML evaluates a binding whether or not the
      // item is shown, so on every ordinary row this ran parseKey(null) into
      // formatDate and logged an error per row per repaint.
      //
      // Model.parseKey, not new Date(key): the latter reads "2026-08-27" as UTC
      // midnight, which formats as the 26th for anyone west of Greenwich.
      text: row.migrated
        ? "→ " + Qt.formatDate(Model.parseKey(row.task.migratedTo), "d MMM")
        : ""
      color: row.foreground
      opacity: 0.45
      font.family: row.fontFamily
      font.pixelSize: Style.font.caption
      Layout.alignment: Qt.AlignVCenter
    }
  }
}
