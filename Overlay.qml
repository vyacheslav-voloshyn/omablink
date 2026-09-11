import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import "Model.js" as Model

// The break itself: one fullscreen layer per monitor.
//
// Everything eases rather than appearing: the overlay takes the whole screen
// away mid-sentence, and a hard cut reads as a glitch. The pieces arrive in
// order (title, then ring, then buttons) off a single `appear` value, the ring
// sweeps between whole seconds instead of ticking, and a slow glow breathes
// behind it at a pace worth copying with your own lungs.
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

  // Skipping is a hold, not a tap. The overlay owns the keyboard while it is
  // up, and a single Esc is the most common keystroke on this desktop — in
  // vim it arrives several times a minute, which dismissed the break before
  // it had drawn. Holding is the shortest gesture that cannot happen by
  // accident.
  readonly property int holdMillis: 700
  property string holding: ""
  property real holdProgress: 0

  NumberAnimation {
    id: hold
    target: overlay
    property: "holdProgress"
    from: 0
    to: 1
    duration: overlay.holdMillis
    onFinished: {
      var action = overlay.holding
      overlay.releaseHold()
      if (action === "skip") overlay.skipRequested()
      else if (action === "postpone") overlay.postponeRequested()
    }
  }

  function beginHold(action) {
    if (!skippable || holding === action) return
    holding = action
    hold.restart()
  }

  function releaseHold() {
    hold.stop()
    holding = ""
    holdProgress = 0
  }

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
  readonly property color tint: kind === "lock" ? Color.urgent : Color.accent

  // One animated value drives the whole entrance; each element reads its own
  // slice of it through stage(), which is what staggers them without a
  // timeline per element.
  property real appear: shown ? 1 : 0
  Behavior on appear {
    NumberAnimation { duration: overlay.shown ? 700 : 240; easing.type: Easing.OutCubic }
  }

  function stage(from, to) {
    if (appear >= to) return 1
    if (appear <= from) return 0
    return (appear - from) / (to - from)
  }

  // A break screen has to actually hide the work: an alpha scrim leaves text
  // readable through it, which defeats the point. Opaque, in the theme's own
  // background, so it reads as part of the desktop rather than a modal.
  Rectangle {
    id: scrim
    anchors.fill: parent
    color: Color.background
    opacity: overlay.stage(0, 0.45)
  }

  // Swallows clicks so a stray click during the break does not land in the
  // app underneath.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.AllButtons
  }

  Column {
    id: content
    anchors.centerIn: parent
    spacing: Style.spacing.panelPadding * 1.5
    width: Math.min(parent.width - Style.spacing.panelPadding * 4, 720)

    Text {
      id: title
      anchors.horizontalCenter: parent.horizontalCenter
      text: Model.tierTitle(overlay.kind)
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Math.round(Style.font.displayLarge * 1.7)
      font.bold: true
      opacity: overlay.stage(0.2, 0.6)
      transform: Translate { y: (1 - title.opacity) * 14 }
    }

    Text {
      id: subtitle
      anchors.horizontalCenter: parent.horizontalCenter
      text: Model.tierSubtitle(overlay.kind)
      // Color.muted is tuned for a bar sitting on a wallpaper; on the flat
      // break background it disappears.
      color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.6)
      font.family: Style.font.family
      font.pixelSize: Style.font.heading
      opacity: overlay.stage(0.3, 0.7)
      transform: Translate { y: (1 - subtitle.opacity) * 12 }
    }

    Item {
      id: dial
      anchors.horizontalCenter: parent.horizontalCenter
      width: 340
      height: 340
      opacity: overlay.stage(0.35, 0.85)
      scale: 0.9 + opacity * 0.1

      // The arc is painted from an animated copy of the progress rather than
      // from `remaining` itself: one repaint per second looks like a stutter,
      // the interpolated value sweeps.
      property real drawnProgress: overlay.progress
      Behavior on drawnProgress {
        NumberAnimation { duration: 950; easing.type: Easing.Linear }
      }

      // Breath pacer: six seconds in, six out. Slow enough that following it
      // is restful rather than a task, and it gives the eye something to do
      // that is not the number. Painted into the ring's canvas as a radial
      // gradient — a scaled Rectangle has a hard edge, which reads as a disc
      // rather than a glow.
      property real breath: 0.86
      SequentialAnimation on breath {
        running: overlay.shown
        loops: Animation.Infinite
        NumberAnimation { to: 1.25; duration: 6000; easing.type: Easing.InOutSine }
        NumberAnimation { to: 0.86; duration: 6000; easing.type: Easing.InOutSine }
      }

      Canvas {
        id: ring
        anchors.fill: parent
        antialiasing: true
        renderStrategy: Canvas.Cooperative

        readonly property real value: dial.drawnProgress
        readonly property real breath: dial.breath
        onValueChanged: requestPaint()
        onBreathChanged: requestPaint()

        onPaint: {
          var ctx = getContext("2d")
          var radius = Math.min(width, height) / 2 - 18
          var cx = width / 2
          var cy = height / 2
          var start = -Math.PI / 2
          var end = start + Math.PI * 2 * ring.value

          ctx.reset()

          var glowRadius = radius * ring.breath
          var glow = ctx.createRadialGradient(cx, cy, glowRadius * 0.25, cx, cy, glowRadius)
          glow.addColorStop(0, Qt.rgba(overlay.tint.r, overlay.tint.g, overlay.tint.b, 0.16))
          glow.addColorStop(1, Qt.rgba(overlay.tint.r, overlay.tint.g, overlay.tint.b, 0))
          ctx.fillStyle = glow
          ctx.beginPath()
          ctx.arc(cx, cy, glowRadius, 0, Math.PI * 2)
          ctx.fill()

          ctx.lineCap = "round"
          ctx.lineWidth = 10

          ctx.strokeStyle = Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.22)
          ctx.beginPath()
          ctx.arc(cx, cy, radius, 0, Math.PI * 2)
          ctx.stroke()

          if (ring.value <= 0) return

          ctx.strokeStyle = overlay.tint
          ctx.beginPath()
          ctx.arc(cx, cy, radius, start, end)
          ctx.stroke()

          // A soft head on the arc: it turns the sweep into something moving
          // rather than a bar that happens to be shrinking.
          var hx = cx + radius * Math.cos(end)
          var hy = cy + radius * Math.sin(end)
          ctx.fillStyle = Qt.rgba(overlay.tint.r, overlay.tint.g, overlay.tint.b, 0.25)
          ctx.beginPath()
          ctx.arc(hx, hy, 14, 0, Math.PI * 2)
          ctx.fill()
        }
      }

      Text {
        id: digits
        anchors.centerIn: parent
        text: String(overlay.remaining)
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: 104
        property real lift: 0
        anchors.verticalCenterOffset: lift

        // Each second is replaced rather than redrawn: the new number rises
        // into place, which reads as a count instead of a flicker.
        onTextChanged: tick.restart()
        SequentialAnimation {
          id: tick
          ParallelAnimation {
            NumberAnimation { target: digits; property: "opacity"; from: 0.25; to: 1; duration: 280; easing.type: Easing.OutCubic }
            NumberAnimation { target: digits; property: "lift"; from: 7; to: 0; duration: 320; easing.type: Easing.OutCubic }
          }
        }
      }
    }

    Row {
      id: actions
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.spacing.md
      visible: overlay.skippable
      opacity: overlay.stage(0.6, 1)
      transform: Translate { y: (1 - actions.opacity) * 10 }

      Repeater {
        model: [
          { label: "Skip  (hold Esc)", action: "skip" },
          { label: "+5 min  (hold Space)", action: "postpone" }
        ]

        Rectangle {
          required property var modelData
          width: caption.implicitWidth + Style.spacing.panelPadding * 2.5
          height: Style.spacing.controlHeight * 1.6
          radius: Style.cornerRadius
          color: mouse.containsMouse
            ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, Style.hoverFillAlpha * 2)
            : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, Style.normalFillAlpha)
          border.width: 1
          border.color: Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, Style.normalBorderAlpha)
          scale: mouse.pressed ? 0.97 : 1

          Behavior on color { ColorAnimation { duration: 140 } }
          Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

          // Fills while its key is held, so the gesture explains itself.
          Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: parent.width * (overlay.holding === modelData.action ? overlay.holdProgress : 0)
            radius: parent.radius
            color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.35)
          }

          Text {
            id: caption
            anchors.centerIn: parent
            text: modelData.label
            color: mouse.containsMouse ? Color.accent : Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.heading
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
      color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.6)
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      opacity: overlay.stage(0.7, 1)
    }
  }

  Item {
    anchors.fill: parent
    focus: true
    Keys.onPressed: function (event) {
      // A lock break takes no keys: the point of it is that it cannot be
      // waved away, and Esc is muscle memory.
      if (!overlay.skippable) return
      if (event.isAutoRepeat) {
        event.accepted = true
        return
      }
      if (event.key === Qt.Key_Escape) {
        overlay.beginHold("skip")
        event.accepted = true
      } else if (event.key === Qt.Key_Space) {
        overlay.beginHold("postpone")
        event.accepted = true
      }
    }

    Keys.onReleased: function (event) {
      if (event.isAutoRepeat) {
        event.accepted = true
        return
      }
      if (event.key === Qt.Key_Escape || event.key === Qt.Key_Space) {
        overlay.releaseHold()
        event.accepted = true
      }
    }
  }
}
