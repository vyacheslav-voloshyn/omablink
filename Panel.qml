import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The widget's popover: today's numbers, the schedule, the hold conditions.
//
// Omarchy stores a bar widget's `settingsForm` in the plugin metadata but
// never renders it, so there is no host settings dialog to hook into — this
// panel is the settings window.
//
// Laid out to stay under a screen height without scrolling: the schedule is a
// two-column grid and the switches are single-line rows, because the stock
// Toggle row is 54px tall and eight of them alone overran the card.
//
// It owns no state: values come from the host widget and every edit leaves
// through settingChanged, so shell.json stays the single source of truth.
Panel {
  id: root
  moduleName: "amsi.omablink"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  property var day: Model.emptyDay("")
  property string statusText: ""
  property bool paused: false

  signal settingChanged(string key, var value)
  signal actionRequested(string action)

  // Defaults live here as well as in the widget so a row still shows the real
  // default when shell.json has no value for it — falling back to the field's
  // minimum would silently misreport the schedule.
  readonly property var defaults: ({
    workMinutes: 20, breakSeconds: 20, longMinutes: 240, longSeconds: 120,
    lockMinutes: 45, blinkMinutes: 5
  })

  // The popup's text colour, not the bar's: `barForeground` is the colour of
  // text on the bar itself, which on a light bar is dark — and the popup
  // card is dark whatever the bar does.
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.6)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // The bar collapses its center section 120ms after the pointer leaves it
  // (Bar.qml centerSectionRevealTimer), which pulls the button this panel is
  // anchored to out from under it — the popup then closes on its own a moment
  // after opening. Every first-party center panel suppresses that collapse
  // while it is up.
  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // Deferred so a panel taking over from another one wins the shared flag.
  function open() {
    root.controller.show()
    Qt.callLater(function () {
      if (root.opened) root.setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    root.setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function numberSetting(name) {
    var fallback = root.defaults[name]
    return Model.clampNumber(setting(name, fallback), fallback, 1, 100000)
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    // KeyboardPanel's own helpers: they add the card's vertical inset and
    // clamp to what actually fits on screen.
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(layout.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
    }

    Column {
      id: layout
      width: parent.width
      spacing: Style.spacing.md

      PanelHero {
        width: parent.width
        title: "Omablink"
        meta: root.statusText
        foreground: root.foreground
        fontFamily: root.fontFamily
        iconComponent: Component {
          EyeGlyph {
            width: Style.font.display
            height: Style.font.display
            openness: root.paused ? 0 : 1
            lineColor: root.foreground
            irisColor: Color.accent
          }
        }
      }

      // --- today ------------------------------------------------------------

      PanelSectionHeader {
        width: parent.width
        text: "TODAY"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Grid {
        width: parent.width
        columns: 3
        rowSpacing: Style.spacing.sm
        columnSpacing: Style.spacing.sm

        Repeater {
          model: [
            { label: "eye breaks", value: String(root.day.micro) },
            { label: "long breaks", value: String(root.day.long) },
            { label: "locks", value: String(root.day.locks) },
            { label: "skipped", value: String(root.day.skipped) },
            { label: "blinks", value: String(root.day.blinks) },
            { label: "screen time", value: Model.formatDuration(root.day.screenSeconds) }
          ]

          Rectangle {
            required property var modelData
            width: (layout.width - Style.spacing.sm * 2) / 3
            height: tile.implicitHeight + Style.space(14)
            radius: Style.cornerRadius
            color: Style.normalFillFor(root.foreground, Color.accent)

            Column {
              id: tile
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(1)

              Text {
                textFormat: Text.PlainText
                text: modelData.value
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                font.bold: true
              }
              Text {
                textFormat: Text.PlainText
                text: modelData.label
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }

      PanelSeparator { width: parent.width }

      // --- schedule ---------------------------------------------------------

      PanelSectionHeader {
        width: parent.width
        text: "SCHEDULE"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Grid {
        width: parent.width
        columns: 2
        rowSpacing: Style.spacing.md
        columnSpacing: Style.spacing.md

        // Explicit − / + buttons with a sensible step per field instead of a
        // SpinBox: its arrows were nearly invisible slivers at the field's
        // edges, and one stray click there quietly rewrote the schedule.
        Repeater {
          model: [
            { key: "workMinutes", label: "eye break every", unit: "min", from: 1, to: 180, step: 5 },
            { key: "breakSeconds", label: "eye break length", unit: "s", from: 5, to: 300, step: 5 },
            { key: "longMinutes", label: "long break every", unit: "min", from: 15, to: 600, step: 15 },
            { key: "longSeconds", label: "long break length", unit: "s", from: 30, to: 900, step: 15 },
            { key: "lockMinutes", label: "lock screen every", unit: "min", from: 10, to: 600, step: 5 },
            { key: "blinkMinutes", label: "blink hint every", unit: "min", from: 1, to: 120, step: 1 }
          ]

          Column {
            id: cell
            required property var modelData
            readonly property int value: root.numberSetting(modelData.key)
            width: (layout.width - Style.spacing.md) / 2
            spacing: Style.space(3)

            function stepBy(direction) {
              var next = Model.stepValue(cell.value, cell.modelData.step, direction,
                                         cell.modelData.from, cell.modelData.to)
              if (next !== cell.value) root.settingChanged(cell.modelData.key, next)
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: cell.modelData.label
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Item {
              width: parent.width
              height: Style.spacing.controlHeight

              Button {
                id: minus
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: height
                height: parent.height
                text: "−"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: cell.value > cell.modelData.from
                opacity: enabled ? 1 : 0.35
                onClicked: cell.stepBy(-1)
              }

              Text {
                anchors.left: minus.right
                anchors.right: plus.left
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignHCenter
                textFormat: Text.PlainText
                text: cell.value + " " + cell.modelData.unit
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Button {
                id: plus
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: height
                height: parent.height
                text: "+"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: cell.value < cell.modelData.to
                opacity: enabled ? 1 : 0.35
                onClicked: cell.stepBy(1)
              }
            }
          }
        }
      }

      PanelSeparator { width: parent.width }

      // --- switches ---------------------------------------------------------

      PanelSectionHeader {
        width: parent.width
        text: "BREAKS AND HOLDS"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Column {
        width: parent.width
        spacing: 0

        Repeater {
          model: [
            { key: "longEnabled", label: "Long breaks" },
            { key: "lockEnabled", label: "Lock the screen (no skip)" },
            { key: "blinkEnabled", label: "Blink hints" },
            { key: "barIcon", label: "Eye icon in the bar" },
            { key: "barIconAnimated", label: "Animate the bar eye" },
            { key: "pauseOnFullscreen", label: "Hold on fullscreen" },
            { key: "pauseOnMicrophone", label: "Hold on calls (microphone)" },
            { key: "pauseOnVideo", label: "Hold on camera or screen share" },
            { key: "pauseOnMeeting", label: "Hold while a meeting window is open" },
            { key: "pauseOnCalendar", label: "Hold during calendar meetings" },
            { key: "pauseOnMedia", label: "Hold while a video plays" },
            { key: "pauseOnIdle", label: "Hold while away" }
          ]

          Rectangle {
            id: switchRow
            required property var modelData
            readonly property bool on: Model.boolSetting(root.setting(modelData.key, true), true)

            width: layout.width
            height: Style.spacing.controlHeight + Style.space(4)
            radius: Style.cornerRadius
            color: rowMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"

            Behavior on color { ColorAnimation { duration: Style.duration(120) } }

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.lg
              anchors.right: toggle.left
              anchors.rightMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: switchRow.modelData.label
              color: switchRow.on ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            ToggleSwitch {
              id: toggle
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              checked: switchRow.on
              foreground: root.foreground
              trackHeight: Math.round(Style.spacing.controlHeight * 0.6)
              // The row owns the click, so the switch is decoration with state.
              interactive: false
            }

            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.settingChanged(switchRow.modelData.key, !switchRow.on)
            }
          }
        }
      }

      PanelSeparator { width: parent.width }

      Row {
        id: actionRow
        width: parent.width
        spacing: Style.spacing.sm

        Repeater {
          model: [
            { action: "breakNow", label: "Eye break" },
            { action: "longNow", label: "Long break" },
            { action: "togglePause", label: root.paused ? "Resume" : "Pause" }
          ]

          Button {
            required property var modelData
            width: (actionRow.width - actionRow.spacing * 2) / 3
            text: modelData.label
            bordered: true
            selected: modelData.action === "togglePause" && root.paused
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: {
              root.actionRequested(modelData.action)
              if (modelData.action !== "togglePause") root.close()
            }
          }
        }
      }

      // --- footer -----------------------------------------------------------

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.spacing.sm

        Text {
          textFormat: Text.PlainText
          text: "omablink ·"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          textFormat: Text.PlainText
          text: "sponsor"
          color: sponsorMouse.containsMouse ? Color.accent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.underline: sponsorMouse.containsMouse

          MouseArea {
            id: sponsorMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              root.actionRequested("sponsor")
              root.close()
            }
          }
        }
      }
    }
  }
}
