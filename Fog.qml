import QtQuick
import qs.Commons

// Drifting fog from shaders/fog.frag. Rendered at `resolution` of its size
// and scaled up: fog has no detail worth full-resolution pixels, and a
// fullscreen fbm at 1440p is the one costly thing on the break screen.
Item {
  id: root

  property real density: 0.6
  property real vignette: 0.5
  property color fogColor: Color.foreground
  property color glowColor: Color.accent
  property color shadeColor: Color.background
  property real resolution: 0.5
  // Constant drift, not an entrance, so it stops outright when the user has
  // turned animations off rather than being shortened.
  property bool running: visible && Style.duration(1000) > 0

  ShaderEffect {
    id: effect
    width: root.width * root.resolution
    height: root.height * root.resolution
    scale: 1 / root.resolution
    transformOrigin: Item.TopLeft

    property real time: 0
    property real density: root.density
    property real aspect: root.height > 0 ? root.width / root.height : 1
    property real vignette: root.vignette
    property color fogColor: root.fogColor
    property color glowColor: root.glowColor
    property color shadeColor: root.shadeColor

    fragmentShader: Qt.resolvedUrl("shaders/fog.frag.qsb")

    NumberAnimation on time {
      running: root.running
      from: 0
      to: 3600
      duration: 3600 * 1000
      loops: Animation.Infinite
    }
  }
}
