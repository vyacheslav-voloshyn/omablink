import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import qs.Commons

// The blink reminder: a small card in the top-right corner, with the break
// screen's fog drifting inside it, whose eye blinks twice before it slides
// away.
//
// Deliberately not a notification — one of these every few minutes would
// bury the notification history in noise, and it must not need dismissing.
// It also never covers what you are reading: a screen-wide sweep every few
// minutes broke concentration more than it rested the eyes.
PanelWindow {
  id: hint

  property bool shown: false
  property string message: "Blink"
  property string detail: "slowly, twice"

  property real appear: shown ? 1 : 0
  Behavior on appear {
    NumberAnimation { duration: Style.duration(hint.shown ? 180 : 120); easing.type: Easing.OutCubic }
  }

  // The window stays mapped until the card has slid out.
  visible: shown || appear > 0.001

  anchors { top: true; right: true }
  margins { top: Style.space(12); right: Style.space(12) }
  implicitWidth: card.width
  implicitHeight: card.height
  color: "transparent"
  WlrLayershell.namespace: "omarchy-omablink-blink"
  WlrLayershell.layer: WlrLayer.Overlay
  // Never takes focus and never takes a click: the hint appears while you are
  // typing, and interrupting that would be worse than the dry eyes.
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  // Normal, not Ignore: the card sits under the bar instead of on top of it.
  exclusionMode: ExclusionMode.Normal
  mask: Region {}

  onShownChanged: if (shown) blink.restart()

  Rectangle {
    id: card
    width: row.implicitWidth + Style.spacing.panelPadding * 2
    height: row.implicitHeight + Style.spacing.panelPadding * 1.2
    radius: Style.cornerRadius
    color: Color.popups.background
    opacity: hint.appear
    transform: Translate { x: (1 - hint.appear) * Style.space(24) }

    // Masked to the card's corners: a plain clip is rectangular, and on a
    // theme with rounded corners the fog would show past them.
    Fog {
      anchors.fill: parent
      visible: hint.visible
      resolution: 1
      density: 0.5
      vignette: 0
      fogColor: Color.popups.text
      glowColor: Color.accent
      shadeColor: Color.popups.background
      layer.enabled: true
      layer.effect: MultiEffect {
        maskEnabled: true
        maskSource: cardMask
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
      }
    }

    Rectangle {
      id: cardMask
      anchors.fill: parent
      radius: card.radius
      visible: false
      layer.enabled: true
    }

    Rectangle {
      anchors.fill: parent
      radius: card.radius
      color: "transparent"
      border.width: 1
      border.color: Qt.rgba(Color.popups.border.r, Color.popups.border.g, Color.popups.border.b, 0.6)
    }

    Row {
      id: row
      anchors.centerIn: parent
      spacing: Style.space(12)

      EyeGlyph {
        id: eye
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(30)
        height: Style.space(30)
        lineColor: Color.popups.text
        irisColor: Color.accent
      }

      Column {
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          text: hint.message
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.title
          font.bold: true
        }
        Text {
          textFormat: Text.PlainText
          text: hint.detail
          color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.6)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // Shut faster than it opens: a real blink snaps closed and rolls back up.
  // Starts after the card has arrived so the first blink is actually seen.
  SequentialAnimation {
    id: blink
    PauseAnimation { duration: Style.duration(220) }
    SequentialAnimation {
      loops: 2
      NumberAnimation { target: eye; property: "openness"; to: 0; duration: Style.duration(110); easing.type: Easing.InQuad }
      PauseAnimation { duration: Style.duration(60) }
      NumberAnimation { target: eye; property: "openness"; to: 1; duration: Style.duration(220); easing.type: Easing.OutCubic }
      PauseAnimation { duration: Style.duration(160) }
    }
  }
}
