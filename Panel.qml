import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The widget's popover: today's numbers, the schedule, the hold conditions.
//
// Omarchy 4.0.3 stores a bar widget's `settingsForm` in the plugin metadata
// but never renders it (shell.qml:1407 is the only reader), so there is no
// host settings dialog to hook into — this panel is the settings window.
//
// Laid out to stay under a screen height without scrolling: the schedule is a
// two-column grid and the switches are single-line rows, because the stock
// Toggle row is 54px tall and seven of them alone overran the card.
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

  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // The bar collapses its center section 120ms after the pointer leaves it
  // (Bar.qml centerSectionRevealTimer), which pulls the button this panel is
  // anchored to out from under it — the popup then closes on its own a moment
  // after opening. Every first-party center panel suppresses that collapse
  // while it is up; without it the panel looked like it "opens only the first
  // time", because opening it without the pointer on the bar closed it again
  // immediately.
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
    // clamp to what actually fits on screen. Guessing the slack by hand left
    // the footer outside the card and the height unclamped.
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
        foreground: root.barForeground
        fontFamily: root.fontFamily
      }

      // --- today ------------------------------------------------------------

      PanelSectionHeader {
        width: parent.width
        text: "TODAY"
        foreground: root.barForeground
        fontFamily: root.fontFamily
      }

      Grid {
        width: parent.width
        columns: 3
        rowSpacing: Style.spacing.sm
        columnSpacing: Style.spacing.md

        Repeater {
          model: [
            { label: "eye breaks", value: String(root.day.micro) },
            { label: "long breaks", value: String(root.day.long) },
            { label: "locks", value: String(root.day.locks) },
            { label: "skipped", value: String(root.day.skipped) },
            { label: "blinks", value: String(root.day.blinks) },
            { label: "screen time", value: Model.formatDuration(root.day.screenSeconds) }
          ]

          Row {
            required property var modelData
            width: (layout.width - Style.spacing.md * 2) / 3
            spacing: Style.spacing.sm

            Text {
              anchors.baseline: caption.baseline
              text: modelData.value
              color: Color.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
            }
            Text {
              id: caption
              text: modelData.label
              color: Color.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      PanelSeparator { width: parent.width }

      // --- schedule ---------------------------------------------------------

      PanelSectionHeader {
        width: parent.width
        text: "SCHEDULE"
        foreground: root.barForeground
        fontFamily: root.fontFamily
      }

      Grid {
        width: parent.width
        columns: 2
        rowSpacing: Style.spacing.sm
        columnSpacing: Style.spacing.md

        Repeater {
          model: [
            { key: "workMinutes", label: "eye break every, min", from: 1, to: 180 },
            { key: "breakSeconds", label: "eye break length, s", from: 5, to: 300 },
            { key: "longMinutes", label: "long break every, min", from: 15, to: 600 },
            { key: "longSeconds", label: "long break length, s", from: 30, to: 900 },
            { key: "lockMinutes", label: "lock screen every, min", from: 10, to: 600 },
            { key: "blinkMinutes", label: "blink hint every, min", from: 1, to: 120 }
          ]

          Column {
            required property var modelData
            width: (layout.width - Style.spacing.md) / 2
            spacing: 2

            Text {
              width: parent.width
              text: modelData.label
              color: Color.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            NumberField {
              value: root.numberSetting(modelData.key)
              from: modelData.from
              to: modelData.to
              stepSize: 1
              fieldWidth: parent.width
              onModified: function (next) { root.settingChanged(modelData.key, next) }
            }
          }
        }
      }

      PanelSeparator { width: parent.width }

      // --- switches ---------------------------------------------------------

      PanelSectionHeader {
        width: parent.width
        text: "BREAKS AND HOLDS"
        foreground: root.barForeground
        fontFamily: root.fontFamily
      }

      Repeater {
        model: [
          { key: "longEnabled", label: "Long breaks" },
          { key: "lockEnabled", label: "Lock the screen (no skip)" },
          { key: "blinkEnabled", label: "Blink hints" },
          { key: "pauseOnFullscreen", label: "Hold on fullscreen" },
          { key: "pauseOnMicrophone", label: "Hold on calls (microphone)" },
          { key: "pauseOnVideo", label: "Hold on camera or screen share" },
          { key: "pauseOnMeeting", label: "Hold while a meeting window is open" },
          { key: "pauseOnIdle", label: "Hold while away" }
        ]

        Rectangle {
          id: switchRow
          required property var modelData
          readonly property bool on: Model.boolSetting(root.setting(modelData.key, true), true)

          width: layout.width
          height: Style.spacing.controlHeight + 4
          radius: Style.cornerRadius
          color: rowMouse.containsMouse
            ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, Style.hoverFillAlpha)
            : "transparent"

          Behavior on color { ColorAnimation { duration: 120 } }

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - toggle.width - Style.spacing.md * 2
            text: switchRow.modelData.label
            color: switchRow.on ? Color.foreground : Color.muted
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
            // The row owns the click, so the switch is decoration with state.
            interactive: false
          }

          MouseArea {
            id: rowMouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: root.settingChanged(switchRow.modelData.key, !switchRow.on)
          }
        }
      }

      PanelSeparator { width: parent.width }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.spacing.sm

        Repeater {
          model: [
            { action: "breakNow", label: "Eye break" },
            { action: "longNow", label: "Long break" },
            { action: "togglePause", label: root.paused ? "Resume" : "Pause" }
          ]

          Rectangle {
            required property var modelData
            width: buttonCaption.implicitWidth + Style.spacing.panelPadding
            height: Style.spacing.controlHeight
            radius: Style.cornerRadius
            color: area.containsMouse
              ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, Style.hoverFillAlpha * 2)
              : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, Style.normalFillAlpha)
            border.width: 1
            border.color: Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, Style.normalBorderAlpha)

            Behavior on color { ColorAnimation { duration: 140 } }

            Text {
              id: buttonCaption
              anchors.centerIn: parent
              text: modelData.label
              color: area.containsMouse ? Color.accent : Color.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            MouseArea {
              id: area
              anchors.fill: parent
              hoverEnabled: true
              onClicked: {
                root.actionRequested(modelData.action)
                if (modelData.action !== "togglePause") root.close()
              }
            }
          }
        }
      }

      // --- footer -----------------------------------------------------------

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.spacing.sm

        Text {
          text: "omablink"
          color: Color.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          text: "·"
          color: Color.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          id: sponsor
          text: "sponsor"
          color: sponsorMouse.containsMouse ? Color.accent : Color.muted
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
