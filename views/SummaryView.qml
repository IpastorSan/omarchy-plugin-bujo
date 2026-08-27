import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Ui
import qs.Commons
import "../Model.js" as Model
import "../components"

// The long view: how the last week and month actually went, and which tasks you
// keep refusing to do.
Item {
  id: view

  property var panel: null
  property bool editing: false

  readonly property color foreground: panel && panel.bar ? panel.bar.foreground : Color.foreground
  readonly property color urgent: panel && panel.bar ? panel.bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: panel && panel.bar ? panel.bar.fontFamily : Style.font.family
  readonly property color accent: Color.accent

  readonly property var week: panel ? Model.rangeStats(panel.journal, panel.todayKey, 7) : null
  readonly property var month: panel ? Model.rangeStats(panel.journal, panel.todayKey, 30) : null
  readonly property int streak: panel ? Model.streak(panel.journal, panel.todayKey) : 0
  readonly property int backlog: panel ? panel.backlogCount : 0
  readonly property var deferred: panel ? Model.mostDeferred(panel.journal, 5) : []

  implicitHeight: column.implicitHeight

  function move(dx, dy) {}
  function activate() {}

  ColumnLayout {
    id: column
    anchors.left: parent.left
    anchors.right: parent.right
    spacing: Style.space(12)

    PanelHero {
      Layout.fillWidth: true
      title: view.streak === 1 ? "1 day clear" : view.streak + " days clear"
      meta: view.streak === 0
        ? "Finish everything on a day to start a run"
        : "Consecutive days with nothing left open"
      foreground: view.foreground
      fontFamily: view.fontFamily
      iconComponent: Component {
        Text {
          text: "󰈸"
          color: view.streak > 0 ? view.accent : view.dim
          font.family: view.fontFamily
          font.pixelSize: Style.font.display
        }
      }
    }

    PanelSeparator { Layout.fillWidth: true; foreground: view.foreground }

    PanelSectionHeader {
      Layout.fillWidth: true
      text: "COMPLETION"
      foreground: view.foreground
      fontFamily: view.fontFamily
    }

    RangeRow { label: "Last 7 days"; range: view.week }
    RangeRow { label: "Last 30 days"; range: view.month }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(8)

      Text {
        Layout.fillWidth: true
        text: "Open from earlier"
        color: view.dim
        font.family: view.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        text: String(view.backlog)
        color: view.backlog > 0 ? view.urgent : view.foreground
        font.family: view.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }

    PanelSeparator { Layout.fillWidth: true; foreground: view.foreground }

    // The honest part of a bullet journal: what you have rewritten five times
    // and still not done.
    //
    // The header stays even when the list is empty. Hiding it left the empty
    // message floating under the completion rails with nothing to say what it
    // was about.
    PanelSectionHeader {
      Layout.fillWidth: true
      text: "MOST DEFERRED"
      foreground: view.foreground
      fontFamily: view.fontFamily
    }

    Repeater {
      model: view.deferred

      RowLayout {
        id: deferredRow
        required property var modelData
        Layout.fillWidth: true
        spacing: Style.space(8)

        Text {
          Layout.fillWidth: true
          text: deferredRow.modelData.text
          color: view.foreground
          font.family: view.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
        Text {
          text: "»" + deferredRow.modelData.migrations
          color: deferredRow.modelData.migrations >= 3 ? view.urgent : view.dim
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    Text {
      Layout.fillWidth: true
      visible: view.deferred.length === 0
      text: "Nothing has been pushed forward yet."
      color: view.dim
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
    }

    PanelSeparator { Layout.fillWidth: true; foreground: view.foreground }

    RowLayout {
      Layout.fillWidth: true
      Text {
        Layout.fillWidth: true
        text: "Back to the day"
        color: view.accent
        font.family: view.fontFamily
        font.pixelSize: Style.font.bodySmall
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: if (view.panel) view.panel.view = "day"
        }
      }
      Text {
        text: "s · esc"
        color: view.dim
        font.family: view.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }
  }

  // One labelled rail. Declared as an inline component so the two windows stay
  // literally identical rather than merely similar.
  component RangeRow: RowLayout {
    // Named, because inside these children `parent` is the visual parent, not
    // the component root, and the label/range would silently read undefined.
    id: rangeRow
    property string label: ""
    property var range: null

    Layout.fillWidth: true
    spacing: Style.space(8)

    Text {
      text: rangeRow.label
      color: view.dim
      font.family: view.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    ProgressRail {
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
      ratio: rangeRow.range ? rangeRow.range.ratio : 0
      foreground: view.foreground
    }

    // An em dash rather than 0%: a window with no tasks in it did not fail.
    Text {
      text: rangeRow.range && rangeRow.range.total
        ? Model.percent(rangeRow.range.ratio) + "%"
        : "—"
      color: view.foreground
      font.family: view.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }
}
