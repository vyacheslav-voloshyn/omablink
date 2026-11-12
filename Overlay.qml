import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The break itself: one fullscreen layer per monitor.
//
// The break is drawn as the eye exercise it asks for. The screen you were
// working on is captured and slowly loses focus, the way your eyes do when
// they shift to something far away; fog drifts in over it and breathes; a
// horizon line runs out as the countdown. When the break is done the fog
// clears and the capture comes back into focus, landing on exactly the
// pixels underneath, so the overlay leaves without a visible cut.
//
// One value, `veil`, carries the whole scene: 0 is your sharp desktop, 1 is
// the full break. Blur, dimming, fog and the text all read from it, so the
// entrance and every exit stay in step.
PanelWindow {
  id: overlay

  property int remaining: 0
  property int total: 20
  property string kind: "micro"
  property bool skippable: true
  property int postponeMinutes: 5

  // Driven by the host. Before it clears `shown`, it sets `exit` to how the
  // break ended, and keeps the window for `exitMillis` while that plays.
  property bool shown: false
  property string exit: ""
  readonly property int exitMillis: exit === "done" ? Style.duration(2400)
    : exit === "lock" ? Style.duration(1400)
    : Style.duration(650)

  signal skipRequested
  signal postponeRequested

  readonly property bool locking: kind === "lock"
  readonly property real progress: total > 0 ? Math.max(0, Math.min(1, remaining / total)) : 0
  readonly property color tint: locking ? Color.urgent : Color.accent
  readonly property color soft: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.62)

  // --- backdrop source --------------------------------------------------------

  // The capture happens while this window is still fully transparent, so it
  // holds the desktop and not the overlay. A compositor that refuses
  // screencopy leaves the wallpaper instead, which then fades in rather than
  // pretending to be the desktop.
  readonly property bool captured: shot.hasContent
  property bool useWallpaper: false
  readonly property bool ready: captured || useWallpaper

  readonly property string wallpaperPath: {
    var state = Quickshell.env("XDG_STATE_HOME")
    return (state && state !== "" ? state : Quickshell.env("HOME") + "/.local/state") + "/omarchy/current/background"
  }

  Timer {
    interval: 600
    running: overlay.shown && !overlay.captured
    onTriggered: overlay.useWallpaper = true
  }

  // --- scene state -------------------------------------------------------------

  property real veil: 0
  property real done: 0
  property real darkness: 0

  onReadyChanged: maybeEnter()
  onShownChanged: shown ? maybeEnter() : leave()
  Component.onCompleted: maybeEnter()

  function maybeEnter() {
    if (shown && ready && veil === 0 && !enter.running) enter.restart()
  }

  function leave() {
    enter.stop()
    releaseHold()
    if (exit === "done") finishDone.restart()
    else if (exit === "lock") finishLock.restart()
    else finishSkip.restart()
  }

  NumberAnimation {
    id: enter
    target: overlay
    property: "veil"
    to: 1
    duration: Style.duration(1500)
    easing.type: Easing.OutCubic
  }

  SequentialAnimation {
    id: finishDone
    NumberAnimation { target: overlay; property: "done"; to: 1; duration: Style.duration(650); easing.type: Easing.OutCubic }
    PauseAnimation { duration: Style.duration(300) }
    // Focus coming back should feel like eyes refocusing, not a cut: long,
    // and gentle at both ends.
    NumberAnimation { target: overlay; property: "veil"; to: 0; duration: Style.duration(1400); easing.type: Easing.InOutSine }
  }

  NumberAnimation {
    id: finishSkip
    target: overlay
    property: "veil"
    to: 0
    duration: Style.duration(550)
    easing.type: Easing.OutCubic
  }

  // The lock break ends in the dark rather than back on the desktop: the
  // lock screen takes over from black, so nothing flashes in between.
  NumberAnimation {
    id: finishLock
    target: overlay
    property: "darkness"
    to: 1
    duration: Style.duration(600)
    easing.type: Easing.InCubic
  }

  function stage(from, to) {
    if (veil >= to) return 1
    if (veil <= from) return 0
    return (veil - from) / (to - from)
  }

  // Six seconds in, six out, read from the fog density and the label under
  // the line. Slow enough that following it is restful rather than a task.
  property real breath: 0
  property bool breathingIn: true
  SequentialAnimation on breath {
    running: overlay.shown && Style.duration(1000) > 0
    loops: Animation.Infinite
    ScriptAction { script: overlay.breathingIn = true }
    NumberAnimation { to: 1; duration: 6000; easing.type: Easing.InOutSine }
    ScriptAction { script: overlay.breathingIn = false }
    NumberAnimation { to: 0; duration: 6000; easing.type: Easing.InOutSine }
  }

  // The line is drawn from an animated copy of the progress, so it runs out
  // smoothly between whole seconds instead of stepping.
  property real drawnProgress: progress
  Behavior on drawnProgress {
    NumberAnimation { duration: Style.duration(950); easing.type: Easing.Linear }
  }

  // A lock break grows darker as it runs out, so the lock arrives as the end
  // of a dusk rather than a surprise.
  readonly property real dusk: locking ? (1 - drawnProgress) * 0.55 : 0

  // --- hold to skip ------------------------------------------------------------

  // Skipping is a hold, not a tap. The overlay owns the keyboard while it is
  // up, and a single Esc is the most common keystroke on this desktop — in
  // vim it arrives several times a minute.
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
    if (!skippable || !shown || holding === action) return
    holding = action
    hold.restart()
  }

  function releaseHold() {
    hold.stop()
    holding = ""
    holdProgress = 0
  }

  // --- window ------------------------------------------------------------------

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

  // --- backdrop ----------------------------------------------------------------

  ScreencopyView {
    id: shot
    anchors.fill: parent
    captureSource: overlay.screen
    live: false
    visible: false
  }

  BackgroundMedia {
    id: wallpaper
    anchors.fill: parent
    path: overlay.useWallpaper ? overlay.wallpaperPath : ""
    cached: false
    constrainDecode: true
    decodeSize: Qt.size(width, height)
    visible: false
  }

  MultiEffect {
    anchors.fill: parent
    source: overlay.captured ? shot : wallpaper
    visible: overlay.captured || wallpaper.ready
    opacity: overlay.captured ? 1 : overlay.veil
    autoPaddingEnabled: false
    blurEnabled: true
    blur: overlay.veil
    blurMax: 64
    blurMultiplier: 1.4
    saturation: -0.35 * overlay.veil
  }

  Rectangle {
    anchors.fill: parent
    color: Color.background
    opacity: overlay.veil * 0.5
  }

  Fog {
    anchors.fill: parent
    visible: overlay.veil > 0.001
    opacity: overlay.veil
    density: overlay.locking
      ? 0.45 * (1 - overlay.darkness)
      : 0.55 + 0.30 * overlay.breath
    vignette: 0.55
    fogColor: Qt.tint(Color.foreground, Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.15))
    glowColor: overlay.tint
    shadeColor: Color.background
  }

  // Grain over the gradients: a smooth dark blur bands into visible steps
  // on an 8-bit panel, and a little noise hides them.
  Canvas {
    id: grain
    anchors.fill: parent
    opacity: overlay.veil * 0.05
    visible: opacity > 0
    renderTarget: Canvas.Image
    onPaint: {
      var ctx = getContext("2d")
      var tile = 128
      var image = ctx.createImageData(tile, tile)
      for (var i = 0; i < image.data.length; i += 4) {
        var v = Math.random() * 255
        image.data[i] = v
        image.data[i + 1] = v
        image.data[i + 2] = v
        image.data[i + 3] = 255
      }
      for (var x = 0; x < width; x += tile)
        for (var y = 0; y < height; y += tile) ctx.putImageData(image, x, y)
    }
  }

  Rectangle {
    anchors.fill: parent
    color: Qt.darker(Color.background, 2.2)
    opacity: Math.max(overlay.dusk * overlay.veil, overlay.darkness)
  }

  // Swallows clicks so a stray click during the break does not land in the
  // app underneath.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.AllButtons
  }

  // --- content -----------------------------------------------------------------

  Column {
    id: content
    anchors.centerIn: parent
    anchors.verticalCenterOffset: -Style.space(20)
    width: Math.min(parent.width - Style.spacing.panelPadding * 4, 760)
    spacing: Style.space(14)
    opacity: 1 - overlay.darkness

    Item {
      anchors.horizontalCenter: parent.horizontalCenter
      width: parent.width
      height: title.implicitHeight
      opacity: overlay.stage(0.30, 0.70)
      transform: Translate { y: (1 - overlay.stage(0.30, 0.70)) * 12 }

      Text {
        id: title
        anchors.horizontalCenter: parent.horizontalCenter
        textFormat: Text.PlainText
        text: Model.tierTitle(overlay.kind)
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Math.round(Style.font.displayLarge * 1.15)
        font.weight: Font.Light
        font.letterSpacing: 3
        opacity: Math.max(0, 1 - overlay.done * 3)
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        textFormat: Text.PlainText
        text: overlay.kind === "long" ? "Welcome back" : "Eyes rested"
        color: Color.foreground
        font: title.font
        opacity: Math.max(0, (overlay.done - 0.35) / 0.65)
      }
    }

    Item {
      id: dial
      anchors.horizontalCenter: parent.horizontalCenter
      width: 320
      height: digits.implicitHeight
      opacity: overlay.stage(0.40, 0.80)
      scale: 0.96 + 0.04 * opacity

      Text {
        id: digits
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: String(overlay.remaining)
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: 168
        font.weight: Font.ExtraLight
        opacity: liveOpacity * Math.max(0, 1 - overlay.done * 4)
        scale: 1 - 0.3 * Math.min(1, overlay.done * 4)
        property real liveOpacity: 1
        property real lift: 0
        anchors.verticalCenterOffset: lift

        // Each second rises into place, which reads as a count instead of
        // a flicker.
        onTextChanged: tick.restart()
        ParallelAnimation {
          id: tick
          NumberAnimation { target: digits; property: "liveOpacity"; from: 0.3; to: 1; duration: Style.duration(320); easing.type: Easing.OutCubic }
          NumberAnimation { target: digits; property: "lift"; from: 9; to: 0; duration: Style.duration(360); easing.type: Easing.OutCubic }
        }
      }

      // The finale: a ring closes and a check draws inside it.
      Canvas {
        id: check
        anchors.centerIn: parent
        width: 120
        height: 120
        visible: overlay.done > 0
        readonly property real value: overlay.done
        onValueChanged: requestPaint()
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          var t = overlay.tint
          var ring = Math.min(1, value / 0.6)
          var tick = Math.max(0, (value - 0.35) / 0.65)
          var r = width / 2 - 4
          ctx.lineCap = "round"
          ctx.lineJoin = "round"
          ctx.lineWidth = 3
          ctx.strokeStyle = Qt.rgba(t.r, t.g, t.b, 0.9)
          ctx.beginPath()
          ctx.arc(width / 2, height / 2, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * ring)
          ctx.stroke()
          if (tick <= 0) return
          var points = [[0.30, 0.52], [0.45, 0.66], [0.72, 0.38]]
          var first = Math.min(1, tick / 0.4)
          var second = Math.max(0, (tick - 0.4) / 0.6)
          ctx.lineWidth = 4
          ctx.strokeStyle = Color.foreground
          ctx.beginPath()
          ctx.moveTo(points[0][0] * width, points[0][1] * height)
          ctx.lineTo((points[0][0] + (points[1][0] - points[0][0]) * first) * width,
                     (points[0][1] + (points[1][1] - points[0][1]) * first) * height)
          if (second > 0)
            ctx.lineTo((points[1][0] + (points[2][0] - points[1][0]) * second) * width,
                       (points[1][1] + (points[2][1] - points[1][1]) * second) * height)
          ctx.stroke()
        }
      }
    }

    // The horizon: the countdown as a line that runs out toward its centre.
    Item {
      id: horizon
      anchors.horizontalCenter: parent.horizontalCenter
      width: Math.min(parent.width, 560)
      height: 18
      opacity: overlay.stage(0.50, 0.90) * (1 - overlay.done)
      readonly property real span: width * overlay.drawnProgress

      Rectangle {
        anchors.centerIn: parent
        width: horizon.span + 40
        height: 10
        radius: 5
        opacity: 0.30 + 0.25 * overlay.breath
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0; color: "transparent" }
          GradientStop { position: 0.5; color: Qt.rgba(overlay.tint.r, overlay.tint.g, overlay.tint.b, 0.55) }
          GradientStop { position: 1; color: "transparent" }
        }
      }

      Rectangle {
        anchors.centerIn: parent
        width: horizon.span
        height: 2
        radius: 1
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0; color: "transparent" }
          GradientStop { position: 0.15; color: overlay.tint }
          GradientStop { position: 0.85; color: overlay.tint }
          GradientStop { position: 1; color: "transparent" }
        }
      }
    }

    Item {
      anchors.horizontalCenter: parent.horizontalCenter
      width: breathLabel.implicitWidth
      height: breathLabel.implicitHeight
      opacity: overlay.stage(0.55, 0.95) * (1 - overlay.done) * (overlay.locking ? 0 : 1)

      Text {
        id: breathLabel
        textFormat: Text.PlainText
        text: overlay.breathingIn ? "BREATHE IN" : "BREATHE OUT"
        color: overlay.soft
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.letterSpacing: 6
        Behavior on text {
          SequentialAnimation {
            NumberAnimation { target: breathLabel; property: "opacity"; to: 0; duration: Style.duration(200) }
            PropertyAction {}
            NumberAnimation { target: breathLabel; property: "opacity"; to: 1; duration: Style.duration(300) }
          }
        }
      }
    }

    Item { width: 1; height: Style.space(6) }

    Item {
      anchors.horizontalCenter: parent.horizontalCenter
      width: parent.width
      height: tip.implicitHeight
      opacity: overlay.stage(0.60, 1) * (1 - overlay.done)

      Text {
        id: tip
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: Model.tierTip(overlay.kind, overlay.total - overlay.remaining, 5)
        color: overlay.soft
        font.family: Style.font.family
        font.pixelSize: Math.round(Style.font.heading * 1.25)
        transform: Translate { id: tipShift }
        // The next tip leaves upward and the new one rises in, so the
        // change reads as a sequence rather than a flicker.
        Behavior on text {
          SequentialAnimation {
            ParallelAnimation {
              NumberAnimation { target: tip; property: "opacity"; to: 0; duration: Style.duration(260) }
              NumberAnimation { target: tipShift; property: "y"; to: -6; duration: Style.duration(260) }
            }
            PropertyAction {}
            PropertyAction { target: tipShift; property: "y"; value: 8 }
            ParallelAnimation {
              NumberAnimation { target: tip; property: "opacity"; to: 1; duration: Style.duration(420); easing.type: Easing.OutCubic }
              NumberAnimation { target: tipShift; property: "y"; to: 0; duration: Style.duration(420); easing.type: Easing.OutCubic }
            }
          }
        }
      }
    }
  }

  // --- key hints ---------------------------------------------------------------

  Row {
    id: actions
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(64)
    spacing: Style.space(40)
    visible: overlay.skippable
    opacity: overlay.stage(0.70, 1) * (1 - overlay.done) * (1 - overlay.darkness)

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
        opacity: mouse.containsMouse || held ? 1 : 0.7

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
            border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.25)
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
