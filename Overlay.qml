import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import "Model.js" as Model

// The break itself: one fullscreen layer per monitor.
//
// Everything fades and eases rather than appearing: the overlay takes the
// whole screen away mid-sentence, and a hard cut reads as a glitch. The ring
// animates between whole seconds so it sweeps instead of ticking.
PanelWindow {
  id: overlay

  property int remaining: 0
  property int total: 20
  property string kind: "micro"
  property bool skippable: true
  property string hint: ""

  // Driven by the host: set false to play the fade-out before the window is
  // dropped, so a skipped break does not vanish instantly.
  property bool shown: false

  signal skipRequested
  signal postponeRequested

  anchors {
    top: true
    bottom: true
    left: true
    right: true
  }
  color: "transparent"
  WlrLayershell.namespace: "omarchy-omablink"
  WlrLayershell.layer: WlrLayer.Overlay
  // Exclusive keyboard focus is what makes Esc and Space reach the overlay
  // instead of whatever was focused when the break started.
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
  exclusionMode: ExclusionMode.Ignore

  readonly property real progress: total > 0 ? Math.max(0, Math.min(1, remaining / total)) : 0

  // A break screen has to actually hide the work: an alpha scrim leaves text
  // readable through it, which defeats the point. Opaque, in the theme's own
  // background, so it reads as part of the desktop rather than a modal.
  Rectangle {
    id: scrim
    anchors.fill: parent
    color: Color.background
    opacity: overlay.shown ? 1 : 0

    // Slow in, quicker out: the fade-in doubles as the warning that the
    // screen is going away, while leaving should feel immediate.
    Behavior on opacity {
      NumberAnimation { duration: overlay.shown ? 420 : 220; easing.type: Easing.InOutQuad }
    }
  }

  // Swallows clicks so a stray click during the break does not land in the
  // app underneath.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.AllButtons
  }

  Item {
    anchors.fill: parent
    opacity: overlay.shown ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

    Column {
      id: content
      anchors.centerIn: parent
      spacing: Style.spacing.panelPadding
      width: Math.min(parent.width - Style.spacing.panelPadding * 4, 720)

      scale: overlay.shown ? 1 : 0.97
      Behavior on scale { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: Model.tierTitle(overlay.kind)
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.displayLarge
        font.bold: true
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: Model.tierSubtitle(overlay.kind)
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }

      Item {
        anchors.horizontalCenter: parent.horizontalCenter
        width: 220
        height: 220

        // The arc is painted from an animated copy of the progress rather
        // than from `remaining` itself: one repaint per second looks like a
        // stutter, the interpolated value sweeps.
        property real drawnProgress: overlay.progress
        Behavior on drawnProgress {
          NumberAnimation { duration: 950; easing.type: Easing.Linear }
        }

        Canvas {
          id: ring
          anchors.fill: parent
          antialiasing: true

          readonly property real value: parent.drawnProgress
          onValueChanged: requestPaint()

          onPaint: {
            var ctx = getContext("2d")
            var radius = Math.min(width, height) / 2 - 10
            var cx = width / 2
            var cy = height / 2
            ctx.reset()
            ctx.lineCap = "round"
            ctx.lineWidth = 7

            ctx.strokeStyle = Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.3)
            ctx.beginPath()
            ctx.arc(cx, cy, radius, 0, Math.PI * 2)
            ctx.stroke()

            ctx.strokeStyle = overlay.kind === "lock" ? Color.urgent : Color.accent
            ctx.beginPath()
            ctx.arc(cx, cy, radius, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * ring.value)
            ctx.stroke()
          }
        }

        Text {
          anchors.centerIn: parent
          text: String(overlay.remaining)
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: 68

          // Each new number arrives with a tiny pulse, which is what makes
          // the count feel alive without a spinner.
          scale: 1
          onTextChanged: pulse.restart()
          SequentialAnimation {
            id: pulse
            NumberAnimation { target: parent; property: "scale"; to: 1.06; duration: 90; easing.type: Easing.OutQuad }
            NumberAnimation { target: parent; property: "scale"; to: 1.0; duration: 220; easing.type: Easing.OutQuad }
          }
        }
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.spacing.md
        visible: overlay.skippable

        Repeater {
          model: [
            { label: "Skip  (Esc)", action: "skip" },
            { label: "+5 min  (Space)", action: "postpone" }
          ]

          Rectangle {
            required property var modelData
            width: caption.implicitWidth + Style.spacing.panelPadding * 2
            height: Style.spacing.controlHeight + 6
            radius: Style.cornerRadius
            color: mouse.containsMouse
              ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, Style.hoverFillAlpha * 2)
              : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, Style.normalFillAlpha)
            border.width: 1
            border.color: Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, Style.normalBorderAlpha)

            Behavior on color { ColorAnimation { duration: 140 } }

            Text {
              id: caption
              anchors.centerIn: parent
              text: modelData.label
              color: mouse.containsMouse ? Color.accent : Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            MouseArea {
              id: mouse
              anchors.fill: parent
              hoverEnabled: true
              onClicked: {
                if (modelData.action === "skip") overlay.skipRequested()
                else overlay.postponeRequested()
              }
            }
          }
        }
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: overlay.hint !== ""
        text: overlay.hint
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }
  }

  Item {
    anchors.fill: parent
    focus: true
    Keys.onPressed: function (event) {
      // A lock break takes no keys: the point of it is that it cannot be
      // waved away, and Esc is muscle memory.
      if (!overlay.skippable) return
      if (event.key === Qt.Key_Escape) {
        overlay.skipRequested()
        event.accepted = true
      } else if (event.key === Qt.Key_Space) {
        overlay.postponeRequested()
        event.accepted = true
      }
    }
  }
}
