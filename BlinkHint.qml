import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons

// The blink reminder: a small strip under the bar that fades in, sits for a
// moment and fades out. Deliberately not a notification — one of these every
// five minutes would bury the notification history in noise, and it must not
// need dismissing.
PanelWindow {
  id: hint

  property bool shown: false
  property string message: "Blink"

  // The window stays mapped for the whole fade, so visibility follows the
  // animated opacity rather than `shown` directly.
  visible: shown || card.opacity > 0.01

  anchors {
    top: true
    left: true
    right: true
  }
  implicitHeight: 120
  color: "transparent"
  WlrLayershell.namespace: "omarchy-omablink-blink"
  WlrLayershell.layer: WlrLayer.Overlay
  // Never takes focus: the hint appears while you are typing, and stealing
  // the keyboard for a reminder would be worse than the dry eyes.
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  exclusionMode: ExclusionMode.Ignore
  mask: Region {}

  Rectangle {
    id: card
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: parent.top
    anchors.topMargin: Style.bar.sizeHorizontal + Style.spacing.md
    width: label.implicitWidth + Style.spacing.panelPadding * 2
    height: label.implicitHeight + Style.spacing.md * 2
    radius: Style.cornerRadius
    color: Color.tooltip.background
    border.width: 1
    border.color: Qt.rgba(Color.tooltip.border.r, Color.tooltip.border.g, Color.tooltip.border.b, 0.4)

    opacity: hint.shown ? 1 : 0
    scale: hint.shown ? 1 : 0.94
    y: hint.shown ? 0 : -6

    Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
    Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutBack } }

    Text {
      id: label
      anchors.centerIn: parent
      text: hint.message
      color: Color.tooltip.text
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }
  }
}
