// Self-check for the widget's pure math: node test/model-test.cjs
const assert = require("assert")
const Model = require("../Model.js")

// Clamping is the guard against a hand-edited shell.json: 0 minutes would
// fire a break every tick, a negative one never.
assert.strictEqual(Model.clampNumber(20, 20, 1, 240), 20)
assert.strictEqual(Model.clampNumber(0, 20, 1, 240), 1)
assert.strictEqual(Model.clampNumber(-5, 20, 1, 240), 1)
assert.strictEqual(Model.clampNumber(9999, 20, 1, 240), 240)
assert.strictEqual(Model.clampNumber("30", 20, 1, 240), 30)
assert.strictEqual(Model.clampNumber("nonsense", 20, 1, 240), 20)
assert.strictEqual(Model.clampNumber(null, 20, 1, 240), 20)

assert.strictEqual(Model.boolSetting(false, true), false)
assert.strictEqual(Model.boolSetting("false", true), false)
assert.strictEqual(Model.boolSetting(undefined, true), true)
assert.strictEqual(Model.boolSetting("yes", false), false)

assert.strictEqual(Model.stepValue(20, 5, 1, 1, 180), 25)
assert.strictEqual(Model.stepValue(20, 5, -1, 1, 180), 15)
assert.strictEqual(Model.stepValue(23, 5, 1, 1, 180), 25)
assert.strictEqual(Model.stepValue(23, 5, -1, 1, 180), 20)
assert.strictEqual(Model.stepValue(5, 5, -1, 1, 180), 1)
assert.strictEqual(Model.stepValue(180, 5, 1, 1, 180), 180)

assert.strictEqual(Model.tierTip("micro", 0, 5), "Find something at least six metres away")
assert.strictEqual(Model.tierTip("micro", 5, 5), "Let your focus soften on it")
assert.strictEqual(Model.tierTip("micro", 20, 5), "Find something at least six metres away")
assert.strictEqual(Model.tierTip("unknown", 0, 5), Model.tierTip("micro", 0, 5))

// Labels round up, so the bar never shows "0m" while a minute is still left.
assert.strictEqual(Model.formatRemaining(45), "45s")
assert.strictEqual(Model.formatRemaining(59), "59s")
assert.strictEqual(Model.formatRemaining(60), "1m")
assert.strictEqual(Model.formatRemaining(61), "2m")
assert.strictEqual(Model.formatRemaining(1200), "20m")
assert.strictEqual(Model.formatRemaining(3600), "1h")
assert.strictEqual(Model.formatRemaining(3900), "1h 5m")
assert.strictEqual(Model.formatRemaining(-5), "0s")

assert.strictEqual(Model.idleCreditsBreak(25, 20), true)
assert.strictEqual(Model.idleCreditsBreak(20, 20), true)
assert.strictEqual(Model.idleCreditsBreak(19, 20), false)

const allHolds = {
  pauseOnFullscreen: true, pauseOnMedia: true, pauseOnMicrophone: true,
  pauseOnVideo: true, pauseOnMeeting: true, pauseOnCalendar: true,
  meetingPattern: "Google Meet|Zoom Meeting"
}
const holds = (facts, config) => Model.holdReasons(Object.assign({ windows: [], captures: [], events: [], now: 0 }, facts), config || allHolds)
const win = (extra) => Object.assign({ title: "", cls: "", visible: true, fullscreen: 0, inhibitingIdle: false }, extra)

assert.deepStrictEqual(holds({}), [])
// Hidden windows play to nobody; the meeting pattern still matches them,
// because the call usually sits behind whatever is being discussed.
assert.deepStrictEqual(holds({ windows: [win({ visible: false, fullscreen: 1, inhibitingIdle: true })] }), [])
assert.deepStrictEqual(holds({ windows: [win({ visible: false, title: "Google Meet" })] }), ["meeting"])
assert.deepStrictEqual(holds({ windows: [win({ fullscreen: 2, inhibitingIdle: true })] }), ["fullscreen", "media"])
// A broken user regex disables the check instead of throwing every tick.
assert.deepStrictEqual(holds({ windows: [win({ title: "x" })] }, Object.assign({}, allHolds, { meetingPattern: "(" })), [])
// Recording a sink's monitor (cava, EasyEffects) is not a call.
assert.deepStrictEqual(holds({ captures: [{ audio: true, video: false, fromSink: true }] }), [])
assert.deepStrictEqual(holds({ captures: [{ audio: true, video: false, fromSink: false }] }), ["microphone"])
assert.deepStrictEqual(holds({ captures: [{ audio: false, video: true, fromSink: false }] }), ["video"])
// Every check obeys its switch.
assert.deepStrictEqual(holds({ windows: [win({ fullscreen: 1, inhibitingIdle: true, title: "Google Meet" })],
  captures: [{ audio: true, video: true, fromSink: false }] }, {}), [])

const at = (iso) => Date.parse(iso)
const meeting = (extra) => Object.assign({
  start: "2026-11-13T09:00:00Z", end: "2026-11-13T09:30:00Z", allDay: false, busy: true, status: "",
  joinUrl: "https://meet.example/abc", accountLabel: "me@example.com",
  attendees: [{ email: "me@example.com", status: "accepted" }, { email: "you@example.com", status: "accepted" }]
}, extra)

assert.strictEqual(Model.calendarMeetingNow([meeting()], at("2026-11-13T09:10:00Z")), true)
// Start inclusive, end exclusive: a back-to-back meeting does not overlap.
assert.strictEqual(Model.calendarMeetingNow([meeting()], at("2026-11-13T09:00:00Z")), true)
assert.strictEqual(Model.calendarMeetingNow([meeting()], at("2026-11-13T09:30:00Z")), false)
assert.strictEqual(Model.calendarMeetingNow([meeting({ allDay: true })], at("2026-11-13T09:10:00Z")), false)
assert.strictEqual(Model.calendarMeetingNow([meeting({ busy: false })], at("2026-11-13T09:10:00Z")), false)
assert.strictEqual(Model.calendarMeetingNow([meeting({ status: "cancelled" })], at("2026-11-13T09:10:00Z")), false)
// A focus block: busy, but no link and nobody else.
assert.strictEqual(Model.calendarMeetingNow([meeting({ joinUrl: "", attendees: [] })], at("2026-11-13T09:10:00Z")), false)
// An in-person meeting has attendees but no link.
assert.strictEqual(Model.calendarMeetingNow([meeting({ joinUrl: "" })], at("2026-11-13T09:10:00Z")), true)
assert.strictEqual(Model.calendarMeetingNow([meeting({
  attendees: [{ email: "ME@example.com", status: "declined" }, { email: "you@example.com", status: "accepted" }]
})], at("2026-11-13T09:10:00Z")), false)
assert.strictEqual(Model.calendarMeetingNow(null, at("2026-11-13T09:10:00Z")), false)
assert.deepStrictEqual(holds({ events: [meeting()], now: at("2026-11-13T09:10:00Z") }), ["calendar"])

// Idle input during a call or a video is watching, not resting; fullscreen
// alone is not, because the screensaver is a fullscreen window.
assert.strictEqual(Model.isWatching(["media"]), true)
assert.strictEqual(Model.isWatching(["fullscreen"]), false)
assert.strictEqual(Model.isWatching([]), false)

// A call in a meeting window also holds the mic and plays video; the bar
// names the meeting.
assert.strictEqual(Model.holdWord(["media", "microphone", "meeting"], false), "meeting")
assert.strictEqual(Model.holdWord(["media", "microphone"], false), "call")
assert.strictEqual(Model.holdWord(["fullscreen", "media"], true), "video")
assert.strictEqual(Model.holdWord([], true), "typing")
assert.strictEqual(Model.holdWord([], false), "")

assert.strictEqual(Model.pauseReasonText(["microphone"]), "call in progress")
assert.strictEqual(Model.pauseReasonText(["meeting"]), "meeting window open")
assert.strictEqual(Model.pauseReasonText(["fullscreen", "video"]), "fullscreen window, camera or screen share")
assert.strictEqual(Model.pauseReasonText([]), "")

console.log("model-test: ok")

// --- schedule ---------------------------------------------------------------

const settings = {
  workMinutes: 20, breakSeconds: 20,
  longMinutes: 240, longSeconds: 120, longEnabled: true,
  lockMinutes: 45, lockCountdownSeconds: 30, lockEnabled: true
}

assert.strictEqual(Model.dueTier({ micro: 0, long: 0, lock: 0 }, settings), "")
assert.strictEqual(Model.dueTier({ micro: 1200, long: 0, lock: 0 }, settings), "micro")

// The strongest due tier wins: a lock that comes due at the same moment as an
// eye break replaces it rather than queueing behind it.
assert.strictEqual(Model.dueTier({ micro: 1200, long: 0, lock: 2700 }, settings), "lock")
assert.strictEqual(Model.dueTier({ micro: 1200, long: 14400, lock: 0 }, settings), "long")

// A disabled tier never comes due, however long it has been.
const noLock = Object.assign({}, settings, { lockEnabled: false })
assert.strictEqual(Model.dueTier({ micro: 0, long: 0, lock: 99999 }, noLock), "")

assert.deepStrictEqual(Model.tiersResetBy("micro"), ["micro"])
assert.deepStrictEqual(Model.tiersResetBy("long"), ["long", "micro"])
assert.deepStrictEqual(Model.tiersResetBy("lock"), ["lock", "long", "micro"])

assert.strictEqual(Model.tierDuration("micro", settings), 20)
assert.strictEqual(Model.tierDuration("long", settings), 120)

// The label counts down to whichever tier arrives first.
assert.strictEqual(Model.secondsToNext({ micro: 0, long: 0, lock: 0 }, settings), 1200)
assert.strictEqual(Model.secondsToNext({ micro: 1190, long: 0, lock: 2695 }, settings), 5)
assert.strictEqual(Model.secondsToNext({ micro: 9999, long: 0, lock: 0 }, settings), 0)

// --- statistics -------------------------------------------------------------

assert.strictEqual(Model.dayKey(new Date(2026, 8, 10)), "2026-09-10")
assert.strictEqual(Model.dayKey(new Date(2026, 0, 5)), "2026-01-05")

const fresh = Model.emptyDay("2026-09-10")
assert.strictEqual(fresh.micro, 0)
assert.strictEqual(fresh.screenSeconds, 0)

// A record written by an older version, or hand-edited, must not poison the
// arithmetic with undefined or negatives.
const partial = Model.normalizeDay({ date: "2026-09-10", micro: 4, screenSeconds: -20 }, "2026-09-10")
assert.strictEqual(partial.micro, 4)
assert.strictEqual(partial.long, 0)
assert.strictEqual(partial.screenSeconds, 0)

let day = Model.bumpDay(fresh, "micro")
day = Model.bumpDay(day, "micro")
day = Model.bumpDay(day, "screenSeconds", 60)
day = Model.bumpDay(day, "unknownField")
assert.strictEqual(day.micro, 2)
assert.strictEqual(day.screenSeconds, 60)
assert.strictEqual(day.unknownField, undefined)

// Today's record replaces the stored one for the same date instead of
// appending a second row for it.
const history = Model.mergeHistory(
  [{ date: "2026-09-08", micro: 1 }, { date: "2026-09-10", micro: 1 }],
  Model.bumpDay(Model.emptyDay("2026-09-10"), "micro", 7)
)
assert.strictEqual(history.length, 2)
assert.strictEqual(history[1].date, "2026-09-10")
assert.strictEqual(history[1].micro, 7)

const capped = Model.mergeHistory(
  Array.from({ length: 40 }, (_, i) => ({ date: "2026-08-" + String(i + 1).padStart(2, "0"), micro: i })),
  Model.emptyDay("2026-09-10"),
  30
)
assert.strictEqual(capped.length, 30)
assert.strictEqual(capped[capped.length - 1].date, "2026-09-10")

assert.strictEqual(Model.formatDuration(0), "0m")
assert.strictEqual(Model.formatDuration(90), "2m")
assert.strictEqual(Model.formatDuration(3600), "1h 00m")
assert.strictEqual(Model.formatDuration(7 * 3600 + 25 * 60), "7h 25m")

console.log("schedule + stats: ok")
