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

// The helper prints one reason per line; anything else on stdout (an error
// from hyprctl, say) must not read as a reason to skip the break forever.
var KNOWN_REASONS = ["fullscreen", "microphone", "video"]

function parsePauseReasons(stdout) {
  var lines = String(stdout || "").split("\n")
  var reasons = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/^\s+|\s+$/g, "").toLowerCase()
    if (KNOWN_REASONS.indexOf(line) !== -1 && reasons.indexOf(line) === -1) reasons.push(line)
  }
  return reasons
}

var REASON_LABELS = {
  fullscreen: "fullscreen window",
  microphone: "call in progress",
  video: "camera or screen share"
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
    formatRemaining: formatRemaining,
    idleCreditsBreak: idleCreditsBreak,
    parsePauseReasons: parsePauseReasons,
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
  micro: "Look away",
  long: "Stand up",
  lock: "Locking the screen"
}

var TIER_SUBTITLES = {
  micro: "20 feet away, until the count runs out",
  long: "Walk, stretch, refill the water",
  lock: "Step away — the screen locks when the count ends"
}

function tierTitle(kind) {
  return TIER_TITLES[kind] || TIER_TITLES.micro
}

function tierSubtitle(kind) {
  return TIER_SUBTITLES[kind] || TIER_SUBTITLES.micro
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
  module.exports.tierSubtitle = tierSubtitle
  module.exports.secondsToNext = secondsToNext
  module.exports.dayKey = dayKey
  module.exports.emptyDay = emptyDay
  module.exports.normalizeDay = normalizeDay
  module.exports.bumpDay = bumpDay
  module.exports.mergeHistory = mergeHistory
  module.exports.formatDuration = formatDuration
}
