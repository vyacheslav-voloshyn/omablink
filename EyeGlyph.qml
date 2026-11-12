import QtQuick

// An almond eye with an iris, drawn rather than taken from a font: the icon
// fonts Omarchy ships have no eye whose lid can move. `openness` runs from 0
// (shut) to 1 (open); the upper lid travels most of the way, as a real one does.
Canvas {
  id: root

  property real openness: 1
  property color lineColor: "white"
  property color irisColor: "white"
  property real lineWidth: Math.max(1.5, width / 14)

  implicitWidth: 28
  implicitHeight: 28
  antialiasing: true

  onOpennessChanged: requestPaint()
  onLineColorChanged: requestPaint()
  onIrisColorChanged: requestPaint()

  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()

    var pad = lineWidth
    var left = pad
    var right = width - pad
    var cy = height / 2
    var cx = width / 2
    var reach = height * 0.62
    var open = Math.max(0, Math.min(1, openness))
    // Quadratic control points sit twice as far out as the curve's peak.
    var upper = cy - reach * open
    var lower = cy + reach * (0.35 + 0.65 * open)

    ctx.beginPath()
    ctx.moveTo(left, cy)
    ctx.quadraticCurveTo(cx, upper, right, cy)
    ctx.quadraticCurveTo(cx, lower, left, cy)
    ctx.closePath()

    if (open > 0.08) {
      ctx.save()
      ctx.clip()
      ctx.fillStyle = irisColor
      ctx.beginPath()
      ctx.arc(cx, cy, height * 0.2, 0, Math.PI * 2)
      ctx.fill()
      ctx.restore()
    }

    ctx.lineWidth = lineWidth
    ctx.lineJoin = "round"
    ctx.strokeStyle = lineColor
    ctx.beginPath()
    ctx.moveTo(left, cy)
    ctx.quadraticCurveTo(cx, upper, right, cy)
    ctx.quadraticCurveTo(cx, lower, left, cy)
    ctx.closePath()
    ctx.stroke()
  }
}
