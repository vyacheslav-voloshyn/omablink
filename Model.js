// Pure timer and formatting math for the Look Away widget. Kept free of Qt
// types so it can run under node (test/model-test.cjs); the QML owns timers,
// windows and the pause detectors.

// Settings come from a hand-edited shell.json entry, so every number is
// clamped rather than trusted: a zero work interval would fire a break every
// tick, and a negative one would never fire at all.
function clampNumber(value, fallback, min, max) {
  // null, undefined and "" are "not set", not zero: Number(null) is 0, which
  // would silently clamp to the minimum instead of using the default.
  if (value === null || value === undefined || value === "") return fallback
  var number = Number(value)
  if (!isFinite(number)) return fallback
  return Math.min(max, Math.max(min, Math.round(number)))
}

// One press of a schedule stepper. Snaps to the step grid first, so a
// hand-edited 23 goes to 20 or 25 rather than 18 or 28.
function stepValue(value, step, direction, min, max) {
  var snapped = direction > 0
    ? Math.floor(value / step) * step + step
    : Math.ceil(value / step) * step - step
  return Math.max(min, Math.min(max, snapped))
}

function boolSetting(value, fallback) {
  if (value === true || value === false) return value
  if (value === "true") return true
  if (value === "false") return false
  return fallback
}

// Bar labels are read at a glance, so only the largest unit that still says
// something useful is shown.
function formatRemaining(seconds) {
  var total = Math.max(0, Math.round(Number(seconds) || 0))
  if (total < 60) return total + "s"
  var minutes = Math.ceil(total / 60)
  if (minutes < 60) return minutes + "m"
  var hours = Math.floor(minutes / 60)
  var rest = minutes % 60
  return rest === 0 ? hours + "h" : hours + "h " + rest + "m"
}

// A long enough absence already rested the eyes, so it counts as the break
// instead of queueing one for the moment you sit back down.
function idleCreditsBreak(idleSeconds, breakSeconds) {
  return Math.round(Number(idleSeconds) || 0) >= Math.round(Number(breakSeconds) || 0)
}

// ---------------------------------------------------------------------------
// Holds: reasons a due break waits instead of covering the screen.
//
// The QML gathers plain facts from Hyprland, PipeWire and the calendar cache;
// deciding what they mean lives here so it runs under node.
//
//   facts.windows   [{ title, cls, visible, fullscreen, inhibitingIdle }]
//   facts.captures  [{ audio, video, fromSink }] — active capture links only
//   facts.events    calendar events, see calendarMeetingNow
//   facts.now       epoch milliseconds
// ---------------------------------------------------------------------------

function windowMatches(pattern, window) {
  if (!pattern) return false
  var re
  try {
    re = new RegExp(pattern, "i")
  } catch (error) {
    return false
  }
  return re.test(window.title || "") || re.test(window.cls || "")
}

// A meeting is a timed, busy event with someone to meet: a join link or other
// attendees. Focus blocks and all-day markers are busy too, but nobody is on
// the other end, so the eyes still get their break. An invitation you declined
// stays on the calendar and must not hold anything.
function calendarMeetingNow(events, now) {
  var list = events || []
  for (var i = 0; i < list.length; i++) {
    var event = list[i]
    if (!event || event.allDay || event.busy === false || event.status === "cancelled") continue
    var start = Date.parse(event.start)
    var end = Date.parse(event.end)
    if (!(start <= now && now < end)) continue
    var attendees = Array.isArray(event.attendees) ? event.attendees : []
    if (!event.joinUrl && attendees.length < 2) continue
    var self = String(event.accountLabel || "").toLowerCase()
    var declined = false
    for (var j = 0; j < attendees.length; j++)
      if (self !== "" && String(attendees[j].email || "").toLowerCase() === self
          && attendees[j].status === "declined") declined = true
    if (!declined) return true
  }
  return false
}

function holdReasons(facts, config) {
  var reasons = []
  var windows = facts.windows || []
  var captures = facts.captures || []
  var add = function (reason) { if (reasons.indexOf(reason) === -1) reasons.push(reason) }

  for (var i = 0; i < windows.length; i++) {
    var w = windows[i]
    // A window on a hidden workspace plays to nobody.
    if (!w.visible) continue
    if (config.pauseOnFullscreen && w.fullscreen) add("fullscreen")
    // Players ask the compositor not to blank the screen while a video runs;
    // that request is the "someone is watching" signal.
    if (config.pauseOnMedia && w.inhibitingIdle) add("media")
  }
  if (config.pauseOnMeeting)
    for (var k = 0; k < windows.length; k++)
      if (windowMatches(config.meetingPattern, windows[k])) add("meeting")

  for (var c = 0; c < captures.length; c++) {
    // Capturing a sink's monitor is a visualiser or an effects chain, not a call.
    if (config.pauseOnMicrophone && captures[c].audio && !captures[c].fromSink) add("microphone")
    if (config.pauseOnVideo && captures[c].video) add("video")
  }

  if (config.pauseOnCalendar && calendarMeetingNow(facts.events, facts.now)) add("calendar")
  return reasons
}

// Holds that mean someone is looking at the screen without touching it. Idle
// input under them is not an absence, and must not count as a rested break.
// Fullscreen alone is not one: the lock screen's screensaver is fullscreen.
var WATCHING = ["media", "microphone", "video", "meeting", "calendar"]

function isWatching(reasons) {
  var list = reasons || []
  for (var i = 0; i < list.length; i++) if (WATCHING.indexOf(list[i]) !== -1) return true
  return false
}

// One word for the bar, strongest reason first: a meeting usually also holds
// the microphone and plays video, and "meeting" is the one that explains it.
var BAR_WORDS = [
  ["calendar", "meeting"], ["meeting", "meeting"], ["microphone", "call"],
  ["video", "camera"], ["media", "video"], ["fullscreen", "fullscreen"]
]

function holdWord(reasons, typing) {
  var list = reasons || []
  for (var i = 0; i < BAR_WORDS.length; i++)
    if (list.indexOf(BAR_WORDS[i][0]) !== -1) return BAR_WORDS[i][1]
  return typing ? "typing" : ""
}

var REASON_LABELS = {
  fullscreen: "fullscreen window",
  media: "video playing",
  microphone: "call in progress",
  video: "camera or screen share",
  meeting: "meeting window open",
  calendar: "meeting in calendar"
}

function pauseReasonText(reasons) {
  var list = reasons || []
  var labels = []
  for (var i = 0; i < list.length; i++)
    if (REASON_LABELS[list[i]]) labels.push(REASON_LABELS[list[i]])
  return labels.join(", ")
}

if (typeof module !== "undefined") {
  module.exports = {
    clampNumber: clampNumber,
    boolSetting: boolSetting,
    stepValue: stepValue,
    formatRemaining: formatRemaining,
    idleCreditsBreak: idleCreditsBreak,
    calendarMeetingNow: calendarMeetingNow,
    holdReasons: holdReasons,
    isWatching: isWatching,
    holdWord: holdWord,
    pauseReasonText: pauseReasonText
  }
}

// ---------------------------------------------------------------------------
// Multi-tier schedule.
//
// Four independent clocks run at once: the 20-second eye break, a longer
// stand-up break, a screen lock, and the blink hint. They are kept as
// "seconds since this tier last completed" rather than as one wall clock, so
// a skipped or deferred break only shifts its own tier.
// ---------------------------------------------------------------------------

// Strongest first: a lock that comes due while a micro break is also due
// wins, because the lock covers the eye rest anyway. Order matters and is the
// whole point of this list.
var TIERS = ["lock", "long", "micro"]

function tierPeriod(kind, settings) {
  if (kind === "lock") return settings.lockMinutes * 60
  if (kind === "long") return settings.longMinutes * 60
  return settings.workMinutes * 60
}

function tierEnabled(kind, settings) {
  if (kind === "lock") return settings.lockEnabled === true
  if (kind === "long") return settings.longEnabled === true
  return true
}

// Which break is due, given seconds elapsed per tier. "" means none.
function dueTier(elapsed, settings) {
  for (var i = 0; i < TIERS.length; i++) {
    var kind = TIERS[i]
    if (!tierEnabled(kind, settings)) continue
    if ((elapsed[kind] || 0) >= tierPeriod(kind, settings)) return kind
  }
  return ""
}

// A longer rest also satisfies the shorter ones: standing up for two minutes
// rested the eyes, and a lock rested everything. Without this the overlay
// would reappear seconds after a long break.
function tiersResetBy(kind) {
  if (kind === "lock") return ["lock", "long", "micro"]
  if (kind === "long") return ["long", "micro"]
  return ["micro"]
}

function tierDuration(kind, settings) {
  if (kind === "long") return settings.longSeconds
  if (kind === "lock") return settings.lockCountdownSeconds
  return settings.breakSeconds
}

var TIER_TITLES = {
  micro: "Look far away",
  long: "Stand up",
  lock: "Locking the screen"
}

// What to do with the break, one line at a time. The eye-break lines are the
// 20-20-20 exercise itself: refocus far, then relax the muscles that hold the
// near focus.
var TIER_TIPS = {
  micro: [
    "Find something at least six metres away",
    "Let your focus soften on it",
    "Blink slowly, a few times",
    "Relax your jaw and shoulders"
  ],
  long: [
    "Get up from the chair",
    "Roll your shoulders back, slowly",
    "Walk to the window, or refill your water",
    "Look outside, as far as you can see"
  ],
  lock: [
    "Save what you are working on",
    "Stand up and step away",
    "The screen locks when the line runs out"
  ]
}

function tierTitle(kind) {
  return TIER_TITLES[kind] || TIER_TITLES.micro
}

// The tip shown `elapsed` seconds into a break, changing every `period`
// seconds and wrapping round, so a long break cycles rather than running out.
function tierTip(kind, elapsed, period) {
  var tips = TIER_TIPS[kind] || TIER_TIPS.micro
  var step = Math.max(1, Math.round(Number(period) || 1))
  var index = Math.floor(Math.max(0, Number(elapsed) || 0) / step) % tips.length
  return tips[index]
}

// Seconds until the next break of any enabled tier, for the bar label.
function secondsToNext(elapsed, settings) {
  var best = -1
  for (var i = 0; i < TIERS.length; i++) {
    var kind = TIERS[i]
    if (!tierEnabled(kind, settings)) continue
    var left = Math.max(0, tierPeriod(kind, settings) - (elapsed[kind] || 0))
    if (best < 0 || left < best) best = left
  }
  return best < 0 ? 0 : best
}

// ---------------------------------------------------------------------------
// Daily statistics. One record per calendar day, kept in a small JSON file so
// the numbers survive a shell restart; the widget only ever touches today's.
// ---------------------------------------------------------------------------

var STAT_FIELDS = ["micro", "long", "locks", "skipped", "postponed", "deferred", "blinks", "screenSeconds"]

function dayKey(date) {
  var d = date || new Date()
  var month = d.getMonth() + 1
  var day = d.getDate()
  return d.getFullYear() + "-" + (month < 10 ? "0" : "") + month + "-" + (day < 10 ? "0" : "") + day
}

function emptyDay(key) {
  var day = { date: String(key || "") }
  for (var i = 0; i < STAT_FIELDS.length; i++) day[STAT_FIELDS[i]] = 0
  return day
}

// Anything the file is missing (an older version wrote fewer fields, a hand
// edit dropped one) reads as zero rather than as undefined arithmetic.
function normalizeDay(raw, key) {
  var day = emptyDay(key)
  if (!raw || typeof raw !== "object") return day
  for (var i = 0; i < STAT_FIELDS.length; i++) {
    var field = STAT_FIELDS[i]
    var value = Number(raw[field])
    day[field] = isFinite(value) && value > 0 ? Math.round(value) : 0
  }
  day.date = String(raw.date || key || "")
  return day
}

function bumpDay(day, field, amount) {
  var next = normalizeDay(day, day ? day.date : "")
  if (STAT_FIELDS.indexOf(field) === -1) return next
  next[field] += amount === undefined ? 1 : Math.round(Number(amount) || 0)
  if (next[field] < 0) next[field] = 0
  return next
}

// History is capped: this is a habit tracker, not a time series, and an
// unbounded file would be read on every shell start forever.
function mergeHistory(history, day, limit) {
  var max = limit === undefined ? 30 : limit
  var list = []
  var source = Array.isArray(history) ? history : []
  for (var i = 0; i < source.length; i++) {
    var entry = normalizeDay(source[i], source[i] ? source[i].date : "")
    if (entry.date !== "" && entry.date !== day.date) list.push(entry)
  }
  list.push(normalizeDay(day, day.date))
  list.sort(function (a, b) { return a.date < b.date ? -1 : a.date > b.date ? 1 : 0 })
  return list.slice(Math.max(0, list.length - max))
}

function formatDuration(seconds) {
  var total = Math.max(0, Math.round(Number(seconds) || 0))
  var hours = Math.floor(total / 3600)
  var minutes = Math.round((total % 3600) / 60)
  if (hours === 0) return minutes + "m"
  return hours + "h " + (minutes < 10 ? "0" : "") + minutes + "m"
}

if (typeof module !== "undefined") {
  module.exports.TIERS = TIERS
  module.exports.tierPeriod = tierPeriod
  module.exports.tierEnabled = tierEnabled
  module.exports.dueTier = dueTier
  module.exports.tiersResetBy = tiersResetBy
  module.exports.tierDuration = tierDuration
  module.exports.tierTitle = tierTitle
  module.exports.tierTip = tierTip
  module.exports.secondsToNext = secondsToNext
  module.exports.dayKey = dayKey
  module.exports.emptyDay = emptyDay
  module.exports.normalizeDay = normalizeDay
  module.exports.bumpDay = bumpDay
  module.exports.mergeHistory = mergeHistory
  module.exports.formatDuration = formatDuration
}
