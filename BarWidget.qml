import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Services.Pipewire
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
    pauseOnIdle: Model.boolSetting(setting("pauseOnIdle", true), true),
    pauseOnMeeting: Model.boolSetting(setting("pauseOnMeeting", true), true),
    pauseOnMedia: Model.boolSetting(setting("pauseOnMedia", true), true),
    pauseOnCalendar: Model.boolSetting(setting("pauseOnCalendar", true), true),
    // Omarchy's Google Calendar plugin keeps this cache fresh; any source that
    // writes the same shape works (see README, "Calendar").
    calendarFile: String(setting("calendarFile", "~/.cache/omarchy-google-calendar/events.json"))
      .replace(/^~(?=\/)/, Quickshell.env("HOME")),
    barIcon: Model.boolSetting(setting("barIcon", true), true),
    barIconAnimated: Model.boolSetting(setting("barIconAnimated", true), true),
    // Matched against every window's title and class. A muted listener holds
    // no microphone and no camera, so the window is the only thing left to
    // look at. Deliberately narrow: a pattern that also matches the chat app
    // sitting open all day would defer every break forever.
    meetingPattern: String(setting("meetingPattern",
      "Google Meet|Meet - |Meet – |Zoom Meeting|Microsoft Teams|Teams Meeting|Webex|Jitsi|huddle"))
  })

  // --- state ----------------------------------------------------------------

  property var elapsed: ({ micro: 0, long: 0, lock: 0 })
  property int blinkElapsed: 0
  property bool paused: false
  property string deferReason: ""
  property int idleTicks: 0
  property string headsUpFor: ""
  property var holds: []
  property var calendarEvents: []
  property int inputWait: 0

  property bool breaking: false
  property bool overlayShown: false
  property string breakKind: "micro"
  property int breakRemaining: 0

  property var day: Model.emptyDay(Model.dayKey(new Date()))
  property var history: []
  property bool statsDirty: false

  readonly property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/omablink.json"

  readonly property bool away: config.pauseOnIdle && idleMonitor.isIdle && !Model.isWatching(holds)
  readonly property bool counting: !breaking && !paused && !away
  readonly property int secondsToNext: Model.secondsToNext(elapsed, config)

  // While a hold is on, the countdown is not the news: the break will wait
  // past zero, so the bar names what it waits for instead.
  readonly property string holdWord: Model.holdWord(holds, inputWait > 0)
  readonly property bool holding: counting && holdWord !== ""

  readonly property string displayText: breaking
    ? String(breakRemaining) + "s"
    : holding && !vertical ? holdWord
    : Model.formatRemaining(secondsToNext)

  readonly property string statusText: {
    if (breaking) return Model.tierTitle(breakKind) + " — " + breakRemaining + "s left"
    if (paused) return "Paused"
    if (away) return "Away — timer held"
    if (holding) return "Break waits for "
      + (holds.length > 0 ? Model.pauseReasonText(holds) : "a pause in typing")
      + " — next due in " + Model.formatRemaining(secondsToNext)
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
    if (root.holds.length === 0) {
      root.startBreak(kind)
      return
    }
    // Retry in a minute instead of dropping the break: a two-hour call
    // would otherwise cost the whole afternoon's breaks.
    root.deferReason = Model.pauseReasonText(root.holds)
    root.bump("deferred")
    var next = { micro: root.elapsed.micro, long: root.elapsed.long, lock: root.elapsed.lock }
    next[kind] = Math.max(0, Model.tierPeriod(kind, root.config) - 60)
    root.elapsed = next
    root.headsUpFor = kind
  }

  // --- holds ----------------------------------------------------------------

  // Plain facts for Model.holdReasons, read from Quickshell's own Hyprland and
  // PipeWire connections rather than by spawning hyprctl or pw-dump.
  function collectFacts() {
    var windows = []
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var ipc = toplevels[i].lastIpcObject || {}
      windows.push({
        title: ipc.title || toplevels[i].title || "",
        cls: ipc["class"] || "",
        visible: ipc.visible === true,
        fullscreen: ipc.fullscreen || 0,
        inhibitingIdle: ipc.inhibitingIdle === true
      })
    }

    var captures = []
    var groups = Pipewire.linkGroups.values
    for (var j = 0; j < groups.length; j++) {
      var group = groups[j]
      if (!group.source || !group.target || !group.target.isStream) continue
      if (group.state !== PwLinkState.Active) continue
      var targetType = group.target.type
      captures.push({
        audio: (targetType & PwNodeType.AudioInStream) === PwNodeType.AudioInStream,
        video: (targetType & PwNodeType.Video) !== 0,
        fromSink: (group.source.type & PwNodeType.Sink) !== 0
      })
    }

    return { windows: windows, captures: captures, events: root.calendarEvents, now: Date.now() }
  }

  function refreshHolds() {
    var next = Model.holdReasons(collectFacts(), root.config)
    if (next.join() !== root.holds.join()) root.holds = next
  }

  function startBreak(kind) {
    var tier = kind === undefined || kind === "" ? "micro" : kind
    root.deferReason = ""
    root.breakKind = tier
    root.breakRemaining = Model.tierDuration(tier, root.config)
    root.breaking = true
    root.overlayShown = true
  }

  // `exit` says how the break ended, which picks the overlay's finale; the
  // window stays until that has played.
  function finishOverlay(exit) {
    if (overlayLoader.item) {
      overlayLoader.item.exit = exit
      fadeOut.interval = Math.max(1, overlayLoader.item.exitMillis)
    }
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
      // hyprlock types through whatever keyboard layout Hyprland has active,
      // so locking while a non-Latin layout is selected leaves a password
      // that cannot be typed. Layout 0 is the first entry of kb_layout.
      locker.command = ["sh", "-c",
        "hyprctl switchxkblayout all 0 >/dev/null 2>&1; exec omarchy-shell lock lock"]
      locker.running = true
    } else {
      bump(kind === "long" ? "long" : "micro")
    }
    resetTier(kind)
    finishOverlay(kind === "lock" ? "lock" : "done")
  }

  function skipBreak() {
    if (!root.breaking) return
    // The lock break is the one that cannot be waved away — that is the
    // whole point of having it as a separate tier.
    if (root.breakKind === "lock" || !root.overlayShown) return
    bump("skipped")
    resetTier(root.breakKind)
    finishOverlay("skip")
  }

  function postponeBreak() {
    if (!root.breaking || root.breakKind === "lock" || !root.overlayShown) return
    bump("postponed")
    var next = { micro: root.elapsed.micro, long: root.elapsed.long, lock: root.elapsed.lock }
    next[root.breakKind] = Math.max(0, Model.tierPeriod(root.breakKind, root.config) - root.config.postponeSeconds)
    root.elapsed = next
    root.headsUpFor = ""
    root.deferReason = ""
    finishOverlay("skip")
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
    // Same re-anchoring as togglePanel: the bar can rebuild its widget row,
    // and KeyboardPanel derives its screen from the anchor's window, so a
    // stale anchor leaves the popup unable to map at all.
    injectPanel()
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

  property double lastToggleAt: 0

  function togglePanel() {
    if (!panelLoader.item) return

    // A click on the widget while the panel is open can arrive twice: the
    // panel's dismissal surface forwards presses that land on the bar, and
    // the bar strip is also masked click-through so the real press reaches
    // this button. Two toggles in one gesture cancel out, which read as "the
    // second click does nothing".
    var now = Date.now()
    if (now - root.lastToggleAt < 250) return
    root.lastToggleAt = now
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
        // The finale is still playing; the break itself is already over.
        if (!root.overlayShown) return
        root.breakRemaining -= 1
        if (root.breakRemaining <= 0) root.completeBreak()
        return
      }

      root.refreshHolds()

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

      // The bar eye blinks every ten seconds through the last minute, so a
      // break is seen coming before the notification even arrives.
      if (root.secondsToNext <= 60 && root.secondsToNext % 10 === 0) root.blinkEye()

      if (root.config.blinkEnabled) {
        root.blinkElapsed += 1
        if (root.blinkElapsed >= root.config.blinkMinutes * 60) {
          root.blinkElapsed = 0
          root.bump("blinks")
          root.showBlinkHint(root.config.blinkSeconds)
        }
      }

      var due = Model.dueTier(root.elapsed, root.config)
      if (due !== "") {
        // Let the sentence or the drag finish: wait for a few seconds without
        // input, but not for longer than half a minute of it.
        if (!inputMonitor.isIdle && root.inputWait < 30) {
          root.inputWait += 1
          return
        }
        root.inputWait = 0
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

      // Nothing to wrap up while a hold is on; the deferral speaks for itself.
      if (root.config.headsUpSeconds > 0 && next !== "" && root.headsUpFor !== next
          && root.holds.length === 0) {
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

  IdleMonitor {
    id: inputMonitor
    timeout: 5
    respectInhibitors: false
  }

  // lastIpcObject (fullscreen, visibility, idle inhibition) is a snapshot that
  // Hyprland events do not update, so it is re-read on a slow cadence.
  Timer {
    interval: 5000
    repeat: true
    running: root.config.pauseOnFullscreen || root.config.pauseOnMedia || root.config.pauseOnMeeting
    triggeredOnStart: true
    onTriggered: Hyprland.refreshToplevels()
  }

  // Link state stays "unlinked" until the link is bound, and only then does
  // an active capture tell itself apart from an idle one.
  PwObjectTracker {
    objects: root.config.pauseOnMicrophone || root.config.pauseOnVideo ? Pipewire.linkGroups.values : []
  }

  FileView {
    id: calendarFile
    path: root.config.pauseOnCalendar ? root.config.calendarFile : ""
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var parsed = null
      try {
        parsed = JSON.parse(text())
      } catch (error) {
        parsed = null
      }
      root.calendarEvents = parsed && Array.isArray(parsed.events) ? parsed.events : []
    }
    onLoadFailed: root.calendarEvents = []
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
      item.postponeMinutes = Math.round(root.config.postponeSeconds / 60)
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
        holds: root.holds,
        calendarEvents: root.calendarEvents.length,
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
    function blink(): void { root.showBlinkHint(2) }
  }

  function showBlinkHint(seconds) {
    blinkHint.shown = true
    blinkTimer.interval = seconds * 1000
    blinkTimer.restart()
    blinkEye()
  }

  function blinkEye() {
    if (root.config.barIcon && root.config.barIconAnimated) eyeBlink.restart()
  }

  // The bar label is drawn here rather than by WidgetButton when the eye is
  // on: WidgetButton centres a single text label and has no slot for an icon
  // beside it. The button still owns the hit area, tooltip, dimming and the
  // press feedback, which this content follows through pressScale.
  readonly property bool showEye: root.config.barIcon && !root.vertical
  readonly property color labelColor: root.breaking && root.bar ? root.bar.urgent : button.foreground

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.displayText
    // The tooltip carries the click hint too: the panel is the only way into
    // the settings, and a bare countdown gives no reason to click it.
    tooltipText: root.statusText + "  ·  click: stats and settings, middle: pause"
    dimmed: root.paused || root.away || root.holding
    active: root.breaking
    horizontalMargin: 8.75
    verticalPadding: 8.75
    labelVisible: !root.showEye
    fixedWidth: root.showEye ? eyeRow.implicitWidth + button.scaledHorizontalMargin * 2 : -1

    Row {
      id: eyeRow
      visible: root.showEye
      anchors.centerIn: parent
      spacing: Style.space(root.holding ? 8 : 5)
      scale: button.pressScale

      EyeGlyph {
        id: eye
        anchors.verticalCenter: parent.verticalCenter
        width: Math.round(Style.font.body * 1.45)
        height: width
        lineWidth: 1.5
        lineColor: root.labelColor
        irisColor: root.labelColor
        // Shut while nothing is counting, so a paused timer reads at a glance.
        // The blink animates `lid` and leaves `base` bound to the state.
        // Half shut while a hold keeps the break waiting.
        property real base: root.paused || root.away ? 0 : root.holding ? 0.45 : 1
        property real lid: 1
        openness: base * lid
        Behavior on base {
          NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic }
        }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: root.displayText
        color: root.labelColor
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
      }
    }

    SequentialAnimation {
      id: eyeBlink
      NumberAnimation { target: eye; property: "lid"; to: 0; duration: Style.duration(90); easing.type: Easing.InQuad }
      PauseAnimation { duration: Style.duration(50) }
      NumberAnimation { target: eye; property: "lid"; to: 1; duration: Style.duration(180); easing.type: Easing.OutCubic }
    }

    onPressed: function (mouseButton) {
      if (mouseButton === Qt.RightButton) root.broadcast("startBreak")
      else if (mouseButton === Qt.MiddleButton) root.broadcast("togglePause")
      else root.togglePanel()
    }
  }
}
