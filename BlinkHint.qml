import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons

// The blink reminder: two eyelids sweep in from the edges, meet for an
// instant and open again, with a short caption in the gap.
//
// Deliberately not a notification — one of these every five minutes would
// bury the notification history in noise, and it must not need dismissing.
// The earlier version was a small strip under the bar, which is exactly the
// kind of thing peripheral vision filters out; a screen-wide gesture is seen
// without being read.
PanelWindow {
  id: hint

  property bool shown: false
  property string message: "Blink"

  // The window stays mapped for the whole sweep, so visibility follows the
  // animation rather than `shown` directly.
  visible: shown || lids.progress > 0.001

  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  WlrLayershell.namespace: "omarchy-omablink-blink"
  WlrLayershell.layer: WlrLayer.Overlay
  // Never takes focus and never takes a click: the hint appears while you are
  // typing, and interrupting that would be worse than the dry eyes.
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  exclusionMode: ExclusionMode.Ignore
  mask: Region {}

  onShownChanged: if (shown) blink.restart()

  Item {
    id: lids
    anchors.fill: parent

    // 0 is open, 1 is shut. One value drives both lids and the caption, so
    // they cannot drift apart.
    property real progress: 0

    // Close faster than it opens: a real blink snaps shut and rolls back up.
    SequentialAnimation {
      id: blink
      NumberAnimation { target: lids; property: "progress"; to: 1; duration: 220; easing.type: Easing.InQuad }
      PauseAnimation { duration: 90 }
      NumberAnimation { target: lids; property: "progress"; to: 0; duration: 520; easing.type: Easing.OutCubic }
    }

    Rectangle {
      width: parent.width
      height: parent.height * 0.5 * lids.progress
      anchors.top: parent.top
      color: Color.background
      opacity: 0.92
    }

    Rectangle {
      width: parent.width
      height: parent.height * 0.5 * lids.progress
      anchors.bottom: parent.bottom
      color: Color.background
      opacity: 0.92
    }

    Text {
      anchors.centerIn: parent
      text: hint.message
      color: Color.accent
      font.family: Style.font.family
      font.pixelSize: Math.round(Style.font.displayLarge * 1.7)
      font.bold: true
      // Only legible while the lids are near shut, which is also when the
      // background behind it is covered.
      opacity: Math.max(0, lids.progress * 1.6 - 0.6)
      scale: 0.92 + lids.progress * 0.08
    }
  }
}
