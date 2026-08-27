import QtQuick
import qs.Commons

// The completion meter. Same two-rectangle construction as the clock panel's
// year rail, so it reads as part of the same shell rather than as a stranger.
Item {
  id: rail

  property real ratio: 0
  property color foreground: Color.foreground
  property color fill: Style.selectedStateColor(rail.foreground, Color.accent)

  implicitHeight: Style.space(6)

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius > 0 ? height / 2 : 0
    color: Qt.rgba(rail.foreground.r, rail.foreground.g, rail.foreground.b, 0.12)

    Rectangle {
      width: Math.round(parent.width * Math.max(0, Math.min(1, rail.ratio)))
      height: parent.height
      radius: parent.radius
      color: rail.fill

      Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    }
  }
}
