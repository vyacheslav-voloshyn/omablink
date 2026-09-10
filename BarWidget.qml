import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Eye-rest and stand-up breaks, on four independent clocks: the 20-second eye
// break, a longer stand-up break, a screen lock, and the blink hint. Each
// tier tracks its own elapsed seconds, so skipping or deferring one does not
// shift the others (Model.js owns that arithmetic).
//
// Left click opens the panel with today's numbers and every setting, right
// click takes an eye break now, middle click pauses.
//
// A bar surface exists per monitor, so this widget runs once per screen and
// each instance owns the overlay for its own screen. State-changing actions
// go through broadcast() so the screens stay in step instead of one overlay
// hanging around after the other was dismissed.
BarWidget {
  id: root
  moduleName: "amsi.omablink"

  // --- settings -------------------------------------------------------------

  readonly property var config: ({
    workMinutes: Model.clampNumber(setting("workMinutes", 20), 20, 1, 180),
    breakSeconds: Model.clampNumber(setting("breakSeconds", 20), 20, 5, 300),
    longMinutes: Model.clampNumber(setting("longMinutes", 240), 240, 15, 600),
    longSeconds: Model.clampNumber(setting("longSeconds", 120), 120, 30, 900),
    longEnabled: Model.boolSetting(setting("longEnabled", true), true),
    lockMinutes: Model.clampNumber(setting("lockMinutes", 45), 45, 10, 600),
    lockCountdownSeconds: Model.clampNumber(setting("lockCountdownSeconds", 30), 30, 5, 300),
    lockEnabled: Model.boolSetting(setting("lockEnabled", true), true),
    blinkMinutes: Model.clampNumber(setting("blinkMinutes", 5), 5, 1, 120),
    blinkSeconds: Model.clampNumber(setting("blinkHintSeconds", 2), 2, 1, 10),
    blinkEnabled: Model.boolSetting(setting("blinkEnabled", true), true),
    headsUpSeconds: Model.clampNumber(setting("headsUpSeconds", 60), 60, 0, 600),
    postponeSeconds: Model.clampNumber(setting("postponeMinutes", 5), 5, 1, 60) * 60,
    idleSeconds: Model.clampNumber(setting("idleMinutes", 3), 3, 1, 60) * 60,
    pauseOnFullscreen: Model.boolSetting(setting("pauseOnFullscreen", true), true),
    pauseOnMicrophone: Model.boolSetting(setting("pauseOnMicrophone", true), true),
    pauseOnVideo: Model.boolSetting(setting("pauseOnVideo", true), true),
    pauseOnIdle: Model.boolSetting(setting("pauseOnIdle", true), true)
  })

  // --- state ----------------------------------------------------------------

  property var elapsed: ({ micro: 0, long: 0, lock: 0 })
  property int blinkElapsed: 0
  property bool paused: false
  property string deferReason: ""
  property int idleTicks: 0
  property string headsUpFor: ""

  property bool breaking: false
  property bool overlayShown: false
  property string breakKind: "micro"
  property int breakRemaining: 0

  property var day: Model.emptyDay(Model.dayKey(new Date()))
  property var history: []
  property bool statsDirty: false

  readonly property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/omablink.json"
  readonly property string helperPath: Qt.resolvedUrl("bin/omablink-pause-check")
    .toString().replace("file://", "")

  readonly property bool away: config.pauseOnIdle && idleMonitor.isIdle
  readonly property bool counting: !breaking && !paused && !away
  readonly property int secondsToNext: Model.secondsToNext(elapsed, config)

  readonly property string displayText: breaking
    ? String(breakRemaining) + "s"
    : Model.formatRemaining(secondsToNext)

  readonly property string statusText: {
    if (breaking) return Model.tierTitle(breakKind) + " — " + breakRemaining + "s left"
    if (paused) return "Paused"
    if (away) return "Away — timer held"
    if (deferReason !== "") return "Waiting: " + deferReason
    return "Next break in " + Model.formatRemaining(secondsToNext)
  }

  // --- statistics -----------------------------------------------------------

  function bump(field, amount) {
    root.day = Model.bumpDay(root.day, field, amount)
    root.statsDirty = true
  }

  function loadState(raw) {
    var parsed = null
    try {
      parsed = raw && raw !== "" ? JSON.parse(raw) : null
    } catch (error) {
      parsed = null
    }
    var stored = parsed && Array.isArray(parsed.history) ? parsed.history : []
    var key = Model.dayKey(new Date())
    var today = null
    for (var i = 0; i < stored.length; i++)
      if (stored[i] && stored[i].date === key) today = stored[i]
    root.history = stored
    root.day = Model.normalizeDay(today, key)
  }

  function flushState() {
    if (!root.statsDirty) return
    root.statsDirty = false
    root.history = Model.mergeHistory(root.history, root.day, 30)
    stateFile.setText(JSON.stringify({ version: 1, history: root.history }, null, 2) + "\n")
  }

  // Crossing midnight starts a fresh row rather than piling onto yesterday.
  function rollDayIfNeeded() {
    var key = Model.dayKey(new Date())
    if (root.day.date === key) return
    flushState()
    root.history = Model.mergeHistory(root.history, root.day, 30)
    root.day = Model.emptyDay(key)
    root.statsDirty = true
  }

  // --- breaks ---------------------------------------------------------------

  function resetTier(kind) {
    var next = { micro: root.elapsed.micro, long: root.elapsed.long, lock: root.elapsed.lock }
    var tiers = Model.tiersResetBy(kind)
    for (var i = 0; i < tiers.length; i++) next[tiers[i]] = 0
    root.elapsed = next
    root.headsUpFor = ""
    root.deferReason = ""
  }

  function requestBreak(kind) {
    if (breaking) return
    pendingKind = kind
    pauseCheck.running = false
    pauseCheck.command = [
      root.helperPath,
      root.config.pauseOnFullscreen ? "1" : "0",
      root.config.pauseOnMicrophone ? "1" : "0",
      root.config.pauseOnVideo ? "1" : "0"
    ]
    pauseCheck.running = true
  }

  property string pendingKind: "micro"

  function startBreak(kind) {
    var tier = kind === undefined || kind === "" ? "micro" : kind
    root.deferReason = ""
    root.breakKind = tier
    root.breakRemaining = Model.tierDuration(tier, root.config)
    root.breaking = true
    root.overlayShown = true
  }

  function finishOverlay() {
    root.overlayShown = false
    fadeOut.restart()
    // Breaks are the numbers worth keeping, so they are written straight
    // away rather than waiting for the slow flush — a shell restart in
    // between would otherwise lose them.
    flushState()
  }

  // The break ran its course: credit it, reset the tiers it covers, and for
  // the lock tier hand over to the lock screen.
  function completeBreak() {
    var kind = root.breakKind
    if (kind === "lock") {
      bump("locks")
      locker.running = false
      locker.command = ["omarchy-shell", "lock", "lock"]
      locker.running = true
    } else {
      bump(kind === "long" ? "long" : "micro")
    }
    resetTier(kind)
    finishOverlay()
  }

  function skipBreak() {
    if (!root.breaking) return
    // The lock break is the one that cannot be waved away — that is the
    // whole point of having it as a separate tier.
    if (root.breakKind === "lock") return
    bump("skipped")
    resetTier(root.breakKind)
    finishOverlay()
  }

  function postponeBreak() {
    if (!root.breaking || root.breakKind === "lock") return
    bump("postponed")
    var next = { micro: root.elapsed.micro, long: root.elapsed.long, lock: root.elapsed.lock }
    next[root.breakKind] = Math.max(0, Model.tierPeriod(root.breakKind, root.config) - root.config.postponeSeconds)
    root.elapsed = next
    root.headsUpFor = ""
    root.deferReason = ""
    finishOverlay()
  }

  function togglePause() {
    root.paused = !root.paused
    root.headsUpFor = ""
  }

  function notify(summary, body) {
    // No --icon: the icon themes Omarchy ships have nothing eye-shaped, and a
    // missing name renders as a broken-image placeholder rather than nothing.
    notifier.running = false
    notifier.command = ["notify-send", "--app-name=Look Away", summary, body]
    notifier.running = true
  }

  function persistSetting(key, value) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    entry[key] = value

    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // The bar routes popups through the widget root, not through the panel:
  // Bar.findPanelWidget wants open/close/opened here, and KeyboardPanel's
  // own close() falls back to writing its `open` property directly when the
  // owner has no close() — which destroys the binding to the panel
  // controller, so the popup opens exactly once and never again. That was the
  // "first click works, second does nothing" bug.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() {
    if (!panelLoader.item) return
    pushDay()
    panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  // Bar.requestPopout prefers this over close() when another bar widget takes
  // over the popup slot, so the switch animates instead of blinking.
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function togglePanel() {
    if (!panelLoader.item) return
    // The bar can rebuild its widget row, which leaves the panel anchored to
    // a button that no longer exists — and KeyboardPanel derives its screen
    // from the anchor's window, so it silently stops mapping. Re-anchor on
    // every open instead of only when `bar` or `settings` change.
    injectPanel()
    pushDay()
    panelLoader.item.toggle()
  }

  // Today's counters are pushed on open and then on a slow tick while the
  // panel is up. Binding them straight to `day` rewrote the panel's content
  // every second — screenSeconds increments on every tick — which resized the
  // card continuously and left the popup unable to map at all after a while.
  function pushDay() {
    if (!panelLoader.item) return
    if ("day" in panelLoader.item) panelLoader.item.day = root.day
    if ("statusText" in panelLoader.item) panelLoader.item.statusText = root.statusText
  }

  // Only the structural wiring is pushed imperatively, and only when it
  // actually changes. The live values (status line, today's counters) arrive
  // through Bindings below: re-injecting them every second — the status text
  // changes on every tick — churned the panel's whole content tree and left
  // the popup coordinator unable to reopen it after a while.
  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  // Only while the panel is up: writing into a closed popup's content is
  // what broke it before. The status line changes on its own schedule (the
  // countdown, and the "away" flip after a few idle minutes), so leaving the
  // binding live meant resizing a hidden card behind the scenes.
  Binding {
    target: panelLoader.item
    property: "statusText"
    value: root.statusText
    when: panelLoader.item !== null && panelLoader.item.opened
  }

  Binding {
    target: panelLoader.item
    property: "paused"
    value: root.paused
    when: panelLoader.item !== null
  }

  Timer {
    interval: 1000
    repeat: true
    running: true

    onTriggered: {
      if (root.breaking) {
        root.breakRemaining -= 1
        if (root.breakRemaining <= 0) root.completeBreak()
        return
      }

      if (root.paused) return

      if (root.away) {
        root.idleTicks += 1
        return
      }

      // Back from an absence long enough to have rested the eyes: the break
      // already happened away from the screen.
      if (root.idleTicks > 0) {
        var credited = Model.idleCreditsBreak(root.idleTicks, root.config.breakSeconds)
        root.idleTicks = 0
        if (credited) {
          root.resetTier("micro")
          return
        }
      }

      root.rollDayIfNeeded()

      root.elapsed = {
        micro: root.elapsed.micro + 1,
        long: root.elapsed.long + 1,
        lock: root.elapsed.lock + 1
      }
      root.bump("screenSeconds", 1)

      if (root.config.blinkEnabled) {
        root.blinkElapsed += 1
        if (root.blinkElapsed >= root.config.blinkMinutes * 60) {
          root.blinkElapsed = 0
          root.bump("blinks")
          blinkHint.shown = true
          blinkTimer.interval = root.config.blinkSeconds * 1000
          blinkTimer.restart()
        }
      }

      var due = Model.dueTier(root.elapsed, root.config)
      if (due !== "") {
        root.requestBreak(due)
        return
      }

      // One heads-up per cycle, named after the tier it belongs to so a
      // postponed break earns a fresh warning.
      var next = Model.dueTier({
        micro: root.elapsed.micro + root.config.headsUpSeconds,
        long: root.elapsed.long + root.config.headsUpSeconds,
        lock: root.elapsed.lock + root.config.headsUpSeconds
      }, root.config)

      if (root.config.headsUpSeconds > 0 && next !== "" && root.headsUpFor !== next) {
        root.headsUpFor = next
        root.notify(Model.tierTitle(next) + " in " + Model.formatRemaining(root.secondsToNext),
                    next === "lock" ? "The screen locks after the countdown."
                                    : "Wrap up what you are typing.")
      }
    }
  }

  // Statistics are written on a slow cadence, not on every tick: the file
  // exists so the day survives a shell restart, not as a live log.
  Timer {
    interval: 30000
    repeat: true
    running: true
    onTriggered: root.flushState()
  }

  Timer {
    interval: 5000
    repeat: true
    running: panelLoader.item !== null && panelLoader.item.opened
    onTriggered: root.pushDay()
  }

  Timer {
    id: blinkTimer
    onTriggered: blinkHint.shown = false
  }

  Timer {
    id: fadeOut
    interval: 280
    onTriggered: root.breaking = false
  }

  IdleMonitor {
    id: idleMonitor
    enabled: root.config.pauseOnIdle
    timeout: root.config.idleSeconds
    // The break is about eyes, not about the machine: an idle inhibitor set
    // by a video player should not also hold this timer.
    respectInhibitors: false
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadState(text())
    onLoadFailed: root.loadState("")
  }

  Process {
    id: pauseCheck
    stdout: StdioCollector {
      onStreamFinished: {
        var reasons = Model.parsePauseReasons(text)
        if (reasons.length === 0) {
          root.startBreak(root.pendingKind)
          return
        }
        // Retry in a minute instead of dropping the break: a two-hour call
        // would otherwise cost the whole afternoon's breaks.
        root.deferReason = Model.pauseReasonText(reasons)
        root.bump("deferred")
        var next = { micro: root.elapsed.micro, long: root.elapsed.long, lock: root.elapsed.lock }
        next[root.pendingKind] = Math.max(0, Model.tierPeriod(root.pendingKind, root.config) - 60)
        root.elapsed = next
        root.headsUpFor = root.pendingKind
      }
    }
  }

  Process { id: notifier }
  Process { id: locker }
  Process { id: opener }

  BlinkHint {
    id: blinkHint
    message: "Blink"
  }

  Loader {
    id: overlayLoader
    active: root.breaking
    source: Qt.resolvedUrl("Overlay.qml")

    onLoaded: {
      item.screen = root.QsWindow && root.QsWindow.window ? root.QsWindow.window.screen : null
      item.total = Model.tierDuration(root.breakKind, root.config)
      item.kind = root.breakKind
      item.skippable = root.breakKind !== "lock"
      item.remaining = root.breakRemaining
      item.skipRequested.connect(function () { root.broadcast("skipBreak") })
      item.postponeRequested.connect(function () { root.broadcast("postponeBreak") })
      // Set last so the fade-in runs from the window's first frame.
      item.shown = root.overlayShown
    }
  }

  Binding {
    target: overlayLoader.item
    property: "remaining"
    value: root.breakRemaining
    when: overlayLoader.item !== null
  }

  Binding {
    target: overlayLoader.item
    property: "shown"
    value: root.overlayShown
    when: overlayLoader.item !== null
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false

    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
      item.settingChanged.connect(function (key, value) { root.persistSetting(key, value) })
      item.actionRequested.connect(function (action) {
        if (action === "breakNow") root.broadcast("startBreak")
        else if (action === "longNow") root.startLongBreak()
        else if (action === "togglePause") root.broadcast("togglePause")
        else if (action === "sponsor") root.openSponsor()
      })
    }
  }

  function startLongBreak() { startBreak("long") }

  function openSponsor() {
    opener.running = false
    opener.command = ["xdg-open", "https://github.com/sponsors/vyacheslav-voloshyn"]
    opener.running = true
  }

  IpcHandler {
    target: "amsi.omablink"

    // Reports the live settings too: a hand-edited shell.json that did not
    // reach the widget is otherwise invisible from outside.
    function status(): string {
      var state = root.statusText
      return state + " [eye " + root.config.workMinutes + "m/" + root.config.breakSeconds
        + "s, long " + (root.config.longEnabled ? root.config.longMinutes + "m" : "off")
        + ", lock " + (root.config.lockEnabled ? root.config.lockMinutes + "m" : "off")
        + ", blink " + (root.config.blinkEnabled ? root.config.blinkMinutes + "m" : "off") + "]"
    }
    function stats(): string { return JSON.stringify(root.day) }
    function debug(): string {
      return JSON.stringify({
        panelLoaded: panelLoader.item !== null,
        panelStatus: panelLoader.status,
        panelOpened: panelLoader.item ? panelLoader.item.opened : null,
        away: root.away,
        paused: root.paused,
        breaking: root.breaking,
        hasBar: root.bar !== null,
        peers: root.bar && typeof root.bar.moduleWidgets === "function"
          ? root.bar.moduleWidgets(root.moduleName).length : -1
      })
    }

    // Scriptable settings, so the schedule can be changed from a keybinding
    // or a hook without opening the panel. Values arrive as strings over IPC.
    function set(key: string, value: string): string {
      var text = String(value === undefined ? "" : value).trim()
      var coerced = text === "true" ? true
        : text === "false" ? false
        : isFinite(Number(text)) && text !== "" ? Number(text)
        : text
      root.persistSetting(String(key), coerced)
      return "ok"
    }
    function pause(): void { root.paused = true }
    function resume(): void { root.paused = false; root.headsUpFor = "" }
    function toggle(): void { root.broadcast("togglePause") }
    function breakNow(): void { root.broadcast("startBreak") }
    function longNow(): void { root.broadcast("startLongBreak") }
    function lockNow(): void { root.startBreak("lock") }
    function skip(): void { root.broadcast("skipBreak") }
    function panel(): void { root.broadcast("togglePanel") }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function blink(): void { blinkHint.shown = true; blinkTimer.interval = 2000; blinkTimer.restart() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.displayText
    // The tooltip carries the click hint too: the panel is the only way into
    // the settings, and a bare countdown gives no reason to click it.
    tooltipText: root.statusText + "  ·  click: stats and settings, middle: pause"
    dimmed: root.paused || root.away
    active: root.breaking
    horizontalMargin: 8.75
    verticalPadding: 8.75

    onPressed: function (mouseButton) {
      if (mouseButton === Qt.RightButton) root.broadcast("startBreak")
      else if (mouseButton === Qt.MiddleButton) root.broadcast("togglePause")
      else root.togglePanel()
    }
  }
}
