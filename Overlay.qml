import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The break itself: one fullscreen layer per monitor.
//
// The backdrop is the desktop's own wallpaper, blurred and dimmed, so the
// break reads as the desktop stepping back rather than a modal dropping in.
// It is opaque on purpose: an alpha scrim over the windows leaves the work
// readable through it, which defeats the point.
//
// Everything eases rather than appearing: the overlay takes the whole screen
// away mid-sentence, and a hard cut reads as a glitch. The pieces arrive in
// order (title, then ring, then key hints) off a single `appear` value, the
// ring sweeps between whole seconds instead of ticking, and an aura breathes
// behind it at a pace worth copying with your own lungs.
PanelWindow {
  id: overlay

  property int remaining: 0
  property int total: 20
  property string kind: "micro"
  property bool skippable: true
  property int postponeMinutes: 5

  // Driven by the host: set false to play the fade-out before the window is
  // dropped, so a skipped break does not vanish instantly.
  property bool shown: false

  signal skipRequested
  signal postponeRequested

  // The shell's own wallpaper link — the same one the lock screen blurs. A
  // video wallpaper fails to load as an image and leaves the flat theme
  // background, which is the right fallback.
  readonly property string wallpaperPath: {
    var state = Quickshell.env("XDG_STATE_HOME")
    return (state && state !== "" ? state : Quickshell.env("HOME") + "/.local/state") + "/omarchy/current/background"
  }

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
  readonly property color soft: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.6)

  // One animated value drives the whole entrance; each element reads its own
  // slice of it through stage(), which is what staggers them without a
  // timeline per element. Longer than a panel's 180ms: this is a scene change
  // that happens a few times an hour, not a popup.
  property real appear: shown ? 1 : 0
  Behavior on appear {
    NumberAnimation { duration: Style.duration(overlay.shown ? 700 : 240); easing.type: Easing.OutCubic }
  }

  function stage(from, to) {
    if (appear >= to) return 1
    if (appear <= from) return 0
    return (appear - from) / (to - from)
  }

  Item {
    id: backdrop
    anchors.fill: parent
    opacity: overlay.stage(0, 0.45)

    Rectangle {
      anchors.fill: parent
      color: Color.background
    }

    BackgroundMedia {
      id: wallpaper
      anchors.fill: parent
      path: overlay.wallpaperPath
      // The link's target changes with the wallpaper; a cached decode would
      // keep showing the old one.
      cached: false
      // Blurred to nothing anyway, so half resolution costs no detail.
      constrainDecode: true
      decodeSize: Qt.size(Math.round(width / 2), Math.round(height / 2))
      visible: false
    }

    MultiEffect {
      anchors.fill: parent
      source: wallpaper
      visible: wallpaper.ready
      autoPaddingEnabled: false
      blurEnabled: true
      blur: 1.0
      blurMax: 64
      blurMultiplier: 1.5
      saturation: -0.2
    }

    // Dims the wallpaper toward the theme background so the text keeps its
    // contrast on any picture, and darkens top and bottom to pull the eye in.
    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.55)
    }
    Rectangle {
      anchors.fill: parent
      gradient: Gradient {
        orientation: Gradient.Vertical
        GradientStop { position: 0; color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.35) }
        GradientStop { position: 0.5; color: "transparent" }
        GradientStop { position: 1; color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.45) }
      }
    }
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
    anchors.verticalCenterOffset: -Style.space(24)
    spacing: Style.space(10)
    width: Math.min(parent.width - Style.spacing.panelPadding * 4, 720)

    Text {
      id: title
      anchors.horizontalCenter: parent.horizontalCenter
      textFormat: Text.PlainText
      text: Model.tierTitle(overlay.kind)
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Math.round(Style.font.displayLarge * 1.5)
      font.weight: Font.DemiBold
      font.letterSpacing: 0.5
      opacity: overlay.stage(0.2, 0.6)
      transform: Translate { y: (1 - title.opacity) * 14 }
    }

    Text {
      id: subtitle
      anchors.horizontalCenter: parent.horizontalCenter
      textFormat: Text.PlainText
      text: Model.tierSubtitle(overlay.kind)
      color: overlay.soft
      font.family: Style.font.family
      font.pixelSize: Style.font.heading
      opacity: overlay.stage(0.3, 0.7)
      transform: Translate { y: (1 - subtitle.opacity) * 12 }
    }

    Item { width: 1; height: Style.space(18) }

    Item {
      id: dial
      anchors.horizontalCenter: parent.horizontalCenter
      width: 380
      height: 380
      opacity: overlay.stage(0.35, 0.85)
      scale: 0.95 + opacity * 0.05

      // The arc is painted from an animated copy of the progress rather than
      // from `remaining` itself: one repaint per second looks like a stutter,
      // the interpolated value sweeps.
      property real drawnProgress: overlay.progress
      Behavior on drawnProgress {
        NumberAnimation { duration: Style.duration(950); easing.type: Easing.Linear }
      }

      // Breath pacer: six seconds in, six out. Slow enough that following it
      // is restful rather than a task, and it gives the eye something to do
      // that is not the number.
      property real breath: 0
      SequentialAnimation on breath {
        running: overlay.shown
        loops: Animation.Infinite
        NumberAnimation { to: 1; duration: 6000; easing.type: Easing.InOutSine }
        NumberAnimation { to: 0; duration: 6000; easing.type: Easing.InOutSine }
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
          var radius = 132
          var cx = width / 2
          var cy = height / 2
          var t = overlay.tint
          var start = -Math.PI / 2
          var end = start + Math.PI * 2 * ring.value

          ctx.reset()

          // The aura: a soft halo that swells past the ring on the in-breath
          // and settles back toward it on the out-breath.
          var outer = radius * (1.05 + 0.35 * ring.breath)
          var aura = ctx.createRadialGradient(cx, cy, radius * 0.4, cx, cy, outer)
          aura.addColorStop(0, Qt.rgba(t.r, t.g, t.b, 0.04))
          aura.addColorStop(0.7, Qt.rgba(t.r, t.g, t.b, 0.14 + 0.10 * ring.breath))
          aura.addColorStop(1, Qt.rgba(t.r, t.g, t.b, 0))
          ctx.fillStyle = aura
          ctx.beginPath()
          ctx.arc(cx, cy, outer, 0, Math.PI * 2)
          ctx.fill()

          ctx.lineCap = "round"

          ctx.lineWidth = 3
          ctx.strokeStyle = Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.12)
          ctx.beginPath()
          ctx.arc(cx, cy, radius, 0, Math.PI * 2)
          ctx.stroke()

          if (ring.value <= 0) return

          // A wide faint stroke under the sharp one gives the arc a glow
          // without a blur pass.
          ctx.lineWidth = 12
          ctx.strokeStyle = Qt.rgba(t.r, t.g, t.b, 0.18)
          ctx.beginPath()
          ctx.arc(cx, cy, radius, start, end)
          ctx.stroke()

          ctx.lineWidth = 4
          ctx.strokeStyle = t
          ctx.beginPath()
          ctx.arc(cx, cy, radius, start, end)
          ctx.stroke()
        }
      }

      Text {
        id: digits
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: String(overlay.remaining)
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: 112
        font.weight: Font.Light
        property real lift: 0
        anchors.verticalCenterOffset: lift

        // Each second is replaced rather than redrawn: the new number rises
        // into place, which reads as a count instead of a flicker.
        onTextChanged: tick.restart()
        ParallelAnimation {
          id: tick
          NumberAnimation { target: digits; property: "opacity"; from: 0.25; to: 1; duration: Style.duration(280); easing.type: Easing.OutCubic }
          NumberAnimation { target: digits; property: "lift"; from: 7; to: 0; duration: Style.duration(300); easing.type: Easing.OutCubic }
        }
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: digits.bottom
        anchors.topMargin: -Style.space(8)
        textFormat: Text.PlainText
        text: "seconds"
        color: overlay.soft
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.letterSpacing: 2
      }
    }

    Item { width: 1; height: Style.space(18) }

    Row {
      id: actions
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(36)
      visible: overlay.skippable
      opacity: overlay.stage(0.6, 1)
      transform: Translate { y: (1 - actions.opacity) * 10 }

      Repeater {
        model: [
          { key: "Esc", label: "hold to skip", action: "skip" },
          { key: "Space", label: "hold for +" + overlay.postponeMinutes + " min", action: "postpone" }
        ]

        // A keycap and its caption. Clicking works too; the keycap fills
        // while its key is held, so the gesture explains itself.
        Item {
          id: hintRow
          required property var modelData
          readonly property bool held: overlay.holding === modelData.action
          implicitWidth: hintContent.implicitWidth
          implicitHeight: hintContent.implicitHeight
          opacity: mouse.containsMouse || held ? 1 : 0.75

          Behavior on opacity { NumberAnimation { duration: Style.duration(120) } }

          Row {
            id: hintContent
            spacing: Style.space(10)

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: Math.max(height * 1.6, keyLabel.implicitWidth + Style.space(18))
              height: keyLabel.implicitHeight + Style.space(10)
              radius: Math.max(4, Style.cornerRadius)
              color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06)
              border.width: 1
              border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.28)
              clip: true

              Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: parent.width * (hintRow.held ? overlay.holdProgress : 0)
                color: Qt.rgba(overlay.tint.r, overlay.tint.g, overlay.tint.b, 0.45)
              }

              Text {
                id: keyLabel
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: hintRow.modelData.key
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: hintRow.modelData.label
              color: mouse.containsMouse || hintRow.held ? Color.foreground : overlay.soft
              font.family: Style.font.family
              font.pixelSize: Style.font.title
            }
          }

          MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (hintRow.modelData.action === "skip") overlay.skipRequested()
              else overlay.postponeRequested()
            }
          }
        }
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
