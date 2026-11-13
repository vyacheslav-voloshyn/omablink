# Omablink

A screen-break timer for the [Omarchy](https://omarchy.org) bar: look away,
stand up, blink — and it waits while you are on a call.

![Omablink break screen: the desktop drifts into fog, counts down, and comes back sharp](assets/demo.gif)

## Install

```bash
omarchy plugin add https://github.com/vyacheslav-voloshyn/omablink.git --enable
```

A countdown appears in the bar ![Bar widget](assets/bar.png). **Click** it for
stats and settings, **right-click** for a break now, **middle-click** to pause.
Tested on Omarchy 4.5. Nothing to install beyond Omarchy itself: it reads
Hyprland and PipeWire through the shell's own Quickshell services and calls
`notify-send`, which Omarchy ships.

To remove it: `omarchy plugin remove amsi.omablink`, then `omarchy restart shell`.
Its settings live only in the widget's entry in `~/.config/omarchy/shell.json`,
and its daily stats in `~/.local/state/omarchy/omablink.json`.

## Reminders

| Reminder | Default | Skip |
|---|---|---|
| Eye break, fullscreen | every 20 min, 20 s | hold `Esc` |
| Long break, "stand up" | every 4 h, 2 min | hold `Esc` |
| Screen lock, after a countdown | every 45 min | no |
| Blink hint, a corner card ![Blink hint](assets/blink.png) | every 5 min | goes by itself |

During a break your screen drifts out of focus into fog that breathes on a
six-second cycle, with a tip on what to do; when it ends, the fog clears and
the screen comes back sharp. A lock break darkens instead, like dusk.

Hold `Space` to postpone a break by 5 min. A notification comes a minute
before each break. A longer break resets the shorter timers.

## Settings

Everything is in the panel. It writes to the widget's entry in
`~/.config/omarchy/shell.json`, which you can also edit by hand.

![Settings panel](assets/panel.png)

<details>
<summary>All keys</summary>

| Key | Default | Meaning |
|---|---|---|
| `workMinutes` / `breakSeconds` | 20 / 20 | Eye break interval / length |
| `longEnabled`, `longMinutes` / `longSeconds` | true, 240 / 120 | Long break |
| `lockEnabled`, `lockMinutes`, `lockCountdownSeconds` | true, 45, 30 | Screen lock |
| `blinkEnabled`, `blinkMinutes` / `blinkHintSeconds` | true, 5 / 2 | Blink hint |
| `barIcon`, `barIconAnimated` | true, true | Eye beside the countdown; it blinks with each hint and every 10 s in the last minute |
| `headsUpSeconds` | 60 | Notice before a break, 0 = off |
| `postponeMinutes` | 5 | What a postpone adds |
| `idleMinutes` | 3 | Away time that stops the timers |
| `pauseOnFullscreen`, `pauseOnMedia`, `pauseOnMicrophone`, `pauseOnVideo`, `pauseOnMeeting`, `pauseOnCalendar`, `pauseOnIdle` | true | Hold conditions, see below |
| `meetingPattern` | Meet, Zoom, Teams, Webex, Jitsi, huddle | Regex over window titles and classes |
| `calendarFile` | `~/.cache/omarchy-google-calendar/events.json` | Calendar events to hold for, see below |

</details>

## Holds

A break that comes due at a bad moment waits a minute at a time instead of
being dropped. It waits while:

- a visible window is fullscreen, or plays a video (the player asks Hyprland
  not to blank the screen);
- an app records the microphone, or a camera or screen share runs through
  PipeWire; recording a speaker's monitor (cava, EasyEffects) does not count;
- a window matches `meetingPattern`, or the calendar has a meeting now;
- you are typing or moving the mouse: the break waits for five quiet seconds,
  at most half a minute;
- you are away.

Being away longer than a break counts as the break, but sitting still through
a video or a call is watching, not away. While a hold is on, the bar dims,
half-shuts the eye and names it in place of the countdown — `meeting`, `call`,
`camera`, `video`, `fullscreen` or `typing`; the tooltip keeps the countdown.

### Calendar

A meeting is a timed, busy event with a join link or other attendees that you
have not declined. Omarchy's Google Calendar plugin writes the default
`calendarFile`; any other source can write the same shape:

```json
{ "events": [ {
  "start": "2026-11-13T09:00:00Z", "end": "2026-11-13T09:30:00Z",
  "allDay": false, "busy": true, "status": "", "joinUrl": "https://…",
  "accountLabel": "you@example.com",
  "attendees": [ { "email": "you@example.com", "status": "accepted" } ]
} ] }
```

`accountLabel` names you among the attendees. The file is re-read whenever it
changes.

## Command line

```
omarchy-shell amsi.omablink status | stats | panel
omarchy-shell amsi.omablink pause | resume | toggle | skip | blink
omarchy-shell amsi.omablink breakNow | longNow | lockNow
omarchy-shell amsi.omablink set <key> <value>     # e.g. set workMinutes 25
```

Bind any of them in `~/.config/hypr/bindings.lua`.

## Troubleshooting

- **Breaks feel too frequent:** `status` shows the settings actually in use.
- **Breaks never come:** the tooltip says what holds them; a too-broad
  `meetingPattern` holds them forever.
- **Lock rejects the password:** the lock screen needs PAM; check
  `omarchy-shell lock status`.
- **Code changes don't apply:** run `omarchy restart shell`.

Statistics for the last 30 days are kept in `~/.local/state/omarchy/omablink.json`.
Tests: `node test/model-test.cjs`.

[Sponsor](https://github.com/sponsors/vyacheslav-voloshyn) · MIT
