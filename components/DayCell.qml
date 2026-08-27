import QtQuick
import qs.Ui
import qs.Commons

// One square of the month grid: the date, and a dot underneath saying how that
// day went.
//
//   no dot      nothing was ever written
//   hollow ring written, nothing finished
//   part ring   partly finished, filled clockwise by ratio
//   solid       cleared
CursorSurface {
  id: cell

  property var day: null
  // null means the day is empty, which must not render as 0%.
  property var completion: null
  property bool selected: false
  property string fontFamily: Style.font.family

  signal picked()
  signal hovered()

  readonly property bool hasWork: completion !== null
  readonly property real ratio: hasWork ? Number(completion) : 0
  readonly property color accent: Color.accent

  current: cell.selected
  foreground: Color.foreground

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onEntered: cell.hovered()
    onClicked: cell.picked()
  }

  Column {
    anchors.centerIn: parent
    spacing: Style.space(3)

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: cell.day ? cell.day.day : ""
      color: cell.day && cell.day.today ? cell.accent : cell.foreground
      // Days outside the month on screen are context, not content.
      opacity: cell.day && cell.day.inMonth ? (cell.day.weekend ? 0.7 : 1.0) : 0.28
      font.family: cell.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: cell.day && cell.day.today
    }

    Item {
      anchors.horizontalCenter: parent.horizontalCenter
      width: Style.space(6)
      height: Style.space(6)
      opacity: cell.day && cell.day.inMonth ? 1.0 : 0.3

      Rectangle {
        anchors.fill: parent
        radius: width / 2
        visible: cell.hasWork
        color: "transparent"
        border.width: 1
        border.color: Qt.rgba(cell.foreground.r, cell.foreground.g, cell.foreground.b, 0.55)
      }

      // The fill grows from the bottom, so a glance down a column reads like a
      // row of tiny gauges.
      Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        visible: cell.hasWork && cell.ratio > 0
        width: parent.width
        height: Math.max(1, Math.round(parent.height * cell.ratio))
        radius: width / 2
        color: cell.accent
        clip: true
      }
    }
  }
}
