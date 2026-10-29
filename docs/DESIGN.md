# Jancast — UI design

Native SwiftUI macOS app (macOS 14+, SwiftPM, no dependencies) in `app/`.
It talks to the Python backend only through the contract in `docs/API.md`.

## Principles

1. **Calm by default, deep on demand.** The main window is a player, not a
   dashboard. Everything needed to explain a failure exists, but lives in an
   opt-in Diagnostics drawer. Telemetry is *always* recorded (client ring
   buffers are fed by the 1 Hz `/api/state` poll whether or not the drawer
   is open), so opening Diagnostics after a failure shows the whole story.
2. **First-party feel.** Standard controls (Form/Picker/Toggle/Table/Menu,
   sheets, popovers), SF Symbols, system colors and materials, unified
   toolbar, menus with keyboard shortcuts, light and dark mode for free.
3. **Explain consequences in plain words.** "Video is copied, not
   re-encoded — original quality, almost no CPU" instead of "mode: copy".
4. **Answer "why did it fail?"** with a ranked list of causes and evidence
   from the backend, and charts whose reference lines say what "good" is.

## Windows and flow

### Main window (`Window "main"`, 480 pt wide, min 640 tall)

The TV is the screen, so the Mac shows a **remote** (`RemoteLayout`): one
480 pt column (440 until 1.3) — now card, filmstrip timeline, big round transport,
audio/subtitle tiles — with the **library** under it. Always one column:
the window is exactly the column's width and only its height changes, so it
stays remote-shaped and looks the same on every screen (a side-by-side
layout for wide windows was tried and dropped; a narrower 400 pt minimum let
long format badges push the column off-centre). Format badges wrap to a
second line rather than widen it. No
`NavigationSplitView`: the library is a first-class panel under the remote.
The episode in Up Next isn't repeated under Recent. The Diagnostics drawer
slides up under everything.

Keyboard: ↑ / ↓ step through the library in screen order (Recent, then
Suggested), also while something plays: a file loads as a click does (a held
key only reads the file it stops on; playback carries on), and the playing row
brings the player back. Return plays the selection, resumed. TV volume is
⌘↑ / ⌘↓ (as in Music; one step per 0.15 s while held), listed in the
Playback menu with the library moves. Return only acts when there is a file to
play (else it stays with the default button, e.g. Choose File…). Space works in
the main and This Mac windows only, and leaves text fields, tables and a button
focused with Full Keyboard Access alone; ⌘ + arrows in a text field edit the
text instead of skipping or changing the volume; ⌘← / ⌘→ skip only with the
playing picture in front; ⌘. doesn't stop playback while the PIN sheet is up.
In the This Mac window the picture (`KeylessPlayerView`) never takes the keys,
and Space, ← / → and ↑ / ↓ bring up the control bar. Library rows are one
VoiceOver button each (selected state, a Play action). The library keeps one shape and order while the app runs: what
plays stays in its own row (highlighted, play badge, live progress; clicking
it shows the player), new files go on top, and *Suggested* at the bottom is the
next episode of what plays, else of what was played last (not of the file
clicked), only when that episode isn't already listed (then it keeps its row:
starting something never moves a file out of the list). What was played moves up at the next launch; the backend never
moves a listed file on opening. Rows don't jump under the pointer or the arrows.
Switching files keeps the current remote until the next is read, and the
film's backdrop has a fixed height (`RemoteLayout.backdropHeight`), so neither
collapses and regrows.

The toolbar carries what was a "TV pill" at the top of the remote, so nothing
is said twice: the TV menu at the left (where it plays: "Play on" while
playing, the picker with a reachability dot when ready), Open and
Diagnostics at the right. The TV picked there is global: every file plays on
it (a file's history keeps its tracks, not its TV), and it is remembered
across launches. The Diagnostics glyph gets a coloured dot when the
stream has a problem (none while healthy) and bounces once when it worsens.
The window title isn't drawn (macOS 15+): the now card says what is on.

**Remote, playing** (`PlayingRemote`): the now card: poster tile, show name, "Season 1 · Episode 3" and the episode
title (from the backend's `name_info`; `Fmt` parses the file name only as a
fallback, e.g. in mock mode), **format badges** (1080p/4K, HDR, codec, "Re-encode" in orange, audio codec +
channels, CC). The **filmstrip** is the timeline: frames from the preview
thumbnails across the episode, played part dimmed, a white playhead, prepared
(grey) and TV-buffered (accent) on a 2 pt line under it; hovering or dragging
lifts an enlarged frame + time above the pointer (on demand only), `seek` on
release (the model holds the target until the TV gets there). Times and the
phase in plain words (only when not simply playing) under it. Transport: big
round −10 / play-pause (filled) / +30, small stop. Audio and subtitle tiles
re-POST `/api/play` at the current position. **Up Next** (last 2½ min of an
episode) is an inline row: Play (same TV, tracks matched by language/title)
or Not Now; never autoplays. The next episode — from Play or loaded at the
end — gets the audio/subtitle languages and stereo the session actually
played (a forced subtitle track only stands in for a forced one), unless it
was left part-way with tracks of its own. "Up next after …" on its ready
screen goes once something plays. **Media keys / Control Center / AirPods**
(`NowPlaying`) as before.

**Remote, ready** (`ReadyRemote`, a file loaded, nothing plays until Play):
the same layout (the TV picker is in the toolbar), the filmstrip is static with the playhead at the resume point ("Stopped at 27:10 ·
yesterday"), one primary **Resume 27:10** (or **Play** / **Pair & Play**) with
**Start Over** beside it, the same tiles, and one quiet cost line ("Video will
be re-encoded", "Audio is converted") with details in a popover.

Frames show everywhere (posters, film roll, scrub preview). A "no spoilers"
rule that hid frames from unwatched parts was tried and dropped: it hid
most of the timeline after a few jumps. Posters fall back to a neutral tile
("S1 · E4" or the title's initials) only while thumbnails don't exist yet.

**Library** (`LibraryPanel`, titled *Recent*): one list (≤ 10 from
`GET /api/recent`: played and merely opened files). Rows: poster frame (only
if thumbnails already exist — `thumbs?make=0` — and from a watched part), show + "S1 · E2" or cleaned
title, "Watched" / progress + time left / "Not started". Click loads the file
into the ready view; **double-click plays it** at its resume point on the TV
picked in the toolbar; context menu: Resume/Play, Start Over, Show in Finder.

While another file plays, the ready remote shows a "Now playing ›" pill back
to it. Reachability is re-probed every 5 s while visible; a user's explicit TV
choice is never overridden. *Launch restore*: the newest resumable history
entry is loaded (never auto-played). When an episode is watched to the end,
the next one is loaded ready to play. Pairing uses a PIN sheet; after success
the pending Play continues. Empty state: dashed drop target ("Drop a video or
press ⌘O") above the library.

**This Mac** (`Store/LocalPlayer`, backend `local_player.py`): a device that is
always listed (after the real TVs). The session runs unchanged; instead of an
Apple TV, an `AVPlayerView` window ("This Mac", 16:9, frame remembered) plays
`state.local_player.url`, applies the queued commands (pause / resume / seek /
stop; acked by id) and POSTs what AVPlayer sees about once a second to
`/api/local/report` (timer in the common run-loop modes: an open menu or
⌘O panel must not silence it — the backend fails the session after 10 s
without a report), which the backend turns into the same playback-info an
Apple TV sends. "Waiting for data" and the rate come from `timeControlStatus`
(`isPlaybackBufferEmpty` goes stale after seeks). The session's subtitle
rendition is selected explicitly. The window is ordered front without
becoming key, so Space and the arrows stay with the main window until the
user clicks it or goes full screen (double-click or the bar's button; Esc
leaves it from any window). AVKit's own controls stay off (they acted behind
the session's back); Jancast's control bar (`PlayerControls`: −10 /
play-pause / +30, scrubber with times, stop, audio and subtitle menus as on
the remote's tiles, full screen) fades in when the
mouse moves and out after 2.5 s idle (kept while paused or hovered), the
pointer hiding with it over the picture. It sends the remote's commands. Its
hosting view reports only its intrinsic size: the default min/max sizing
constrained the window and kept the picture small in full screen.
Closing the window = Stop. A failure refreshes Recents. Resume history is
saved (unlike the simulator). Not in mock mode.

### Diagnostics drawer (opt-in)

Toggled with View ▸ Show Diagnostics (⌥⌘I; ⌥⌘D
is taken by macOS for Dock hiding), the toolbar button, or the
indicator popover. When the screen has room for both, it opens as a
full-height 520 pt panel beside the remote (the window grows to the right,
moving left first if it must, and moves back on closing); otherwise, and in
full screen, as a drawer under the remote, resizable from its top edge
(height remembered) and top-aligned, so a short window cuts a pane's bottom,
never its tabs. Optional
Settings toggle "Open Diagnostics automatically when playback fails"
(default off). While it is open the app POSTs `/api/telemetry
{"level":"detailed"}` (1 Hz latency probe), and `basic` when it closes.

Header: tabs **Summary · Charts · Segments · Events** (problem counts in the
titles), the one-line verdict (status glyph + headline) on every tab, Copy
Report, close.

- **Diagnosis banner**: status color + symbol (phase appended only when it
  adds information — never "FAILED · FAILED"), headline, the raw
  `session.error` in a selectable monospaced box with a Copy button (the
  duplicate "Error: …" details line is hidden), details, Apple TV
  `playback.error` / `prep.error` in red, and *Likely causes* ranked by
  confidence with a confidence bar, percentage ("ruled out" < 5 %) and
  evidence. Collapsed to a one-line summary when status is ok.
- **Summary**: the diagnosis banner, then **KPI tiles** (6 across, 3×2 when narrow): Throughput (avg10, now, needed,
  recent segment speed), TV buffer, Prep headroom / Done, Round trip (avg,
  loss), Stalls (count, total), HTTP (errors, client aborts). Each has a
  status glyph and a colored edge when warning or worse. Throughput health
  is judged by *segment delivery speed* (realtime ratio of recent segments),
  because a full TV buffer idles the link on purpose: low average throughput
  with a full buffer is not a problem.
  A collapsed *Stream details* row holds video mode, bitrate, prepared
  segments, stream URL, telemetry level and the TV's last report.
- **Charts**: timeline charts (Swift Charts; range picker 1 / 5 / 15 min / Session;
  long ranges are bucketed to ≤ 600 points — mean for rates, min for
  buffers, max for RTT). All charts share the x-domain and one hover
  crosshair; each card's header reads out its value at the hovered second.
  1. *Throughput to Apple TV*: per-second area (bursts clipped at 3× the
     bitrate so the reference stays readable) + 10 s average line + dashed
     "needed" rule at `stream_bitrate_bps`.
  2. *TV buffer ahead* (s) with stall intervals (`tv_buffer_empty`) as red
     bands.
  3. *Round trip* (ms): line through measured samples (works at 1 Hz and at
     the 5 s "basic" rate), red × for timeouts. A missing RTT is a gap, not a
     timeout — see contract note below.
  4. *Prep headroom* (s) with a 2-segment danger rule; caption says when the
     whole file is prepared (encoder ruled out).
  5. *ffmpeg speed* (× realtime) with a 1× rule. (Separate charts instead of
     a dual axis.)
- **Segments**: summary (sent / fast / marginal / too slow-failed / median
  ratio), a bar per segment of *time to send* vs. the dashed segment
  duration (6 s = realtime; green ≥ 1.5×, yellow 1–1.5×, red < 1× or
  failed), and a `Table` of requests (time, segment, kind, status, size,
  send time, Mbit/s, realtime ×, error); filters "Segments only" /
  "Slow or failed only"; ⌘C copies selected rows, Copy copies all visible.
- **Events**: newest first, level filter (All / Warnings & Errors / Errors),
  source menu, "This session only", search, ⌘C / Copy.
- **Copy Report** (⇧⌘C): plain-text summary for sharing (session, diagnosis
  + suspects, playback/prep/network numbers, recent warnings/errors).

## Visual language

- **Ambience**: the remote sits on a soft wash of its poster frame (else the
  film's palette), from under the toolbar (macOS 15+: the window's
  background, toolbar background hidden) fading into the window where the
  library starts. Its most vivid colour, made legible, is the tint: TV-buffered
  line, progress bars, the Now Playing row, Resume. Grey pictures keep the
  system accent. The wash is blurred once on a 48 px copy (`Ambience`), then
  drawn as a plain image — no live blur (see Engineering notes). Pictures are
  cut to 16:9 first (films are 2.39:1 to 16:9, and each filled at its own
  scale zoomed the background in and out between titles) and change with a
  Core Animation fade (`FadingImage`), never a SwiftUI insert/remove
  transition, which briefly laid the new picture out at another size. Over its top
  a softened frame (blurred once at 480 px) shows the scene behind the now
  card, fading out by the timeline: the frame at the start of the current
  five minutes (not the poster's — no echo, no spoilers), crossfading as the
  episode goes on. The whole backdrop fades to transparent at its bottom, so
  it meets the library without a seam whatever the window colour is (on
  macOS 26 it differs from `windowBackgroundColor` and is translucent).
  Behind the library sits a glow of the film's three strongest colours
  (`LibraryWash`, from the palette), so the window keeps the film's colours
  all the way down.
- Launch: the window opens in last run's colours (`SavedLook`: the frame,
  poster and palette saved on quit, with the remote's size) and shows only
  them until the backend runs and the restored file has its poster frame
  (at most 1.5 s); then the remote fades in at once. "Starting Jancast…"
  appears only if that takes over 1.2 s. No piece-by-piece filling in.
- Surfaces have a little depth instead of flat fills: a top-to-bottom
  gradient with a hairline edge (transport buttons, tiles), soft shadows under
  posters and the play button; small-caps section captions (AUDIO, NOW PLAYING).
- Status colors are reserved for state and always paired with a symbol:
  good = green `checkmark`, warning = yellow `exclamationmark.triangle`,
  serious = orange `exclamationmark.octagon`, critical = red `xmark.octagon`.
- Series colors are identity only, one per measure, consistent between tiles
  and charts: throughput blue, buffer teal, headroom indigo, ffmpeg purple,
  RTT cyan; references are secondary-ink dashed rules; incidents (stalls,
  timeouts) are red.
- Text stays in primary/secondary ink; axes carry units (Mbit/s, s, ms,
  × realtime); grids are faint; every multi-mark chart has a small legend.

## Keyboard

⌘O open · ⌘↩ play/resume · Space pause/resume · ← / → skip −10 / +10 s ·
⌘← / ⌘→ skip −30 / +30 s · ⌘. stop · ⌘R scan for Apple TVs · ⌥⌘I
Diagnostics · ⇧⌘C copy report.

Space and plain arrows are handled by a local key monitor, only in the main
window while the player is shown and never when a text field has focus
(Diagnostics tables and search keep their arrows). Skips use
`/api/control {"action":"skip","seconds":±N}` (in place on the TV): clicks
and key presses within 300 ms of each other are merged into one request
(3 quick → presses = one +30 s); a held arrow key accumulates its repeats
and sends once, 300 ms after it is released,
the scrubber jumps optimistically at once and `/api/state` corrects it, and
a small "+30 s" bubble above the playhead fades after 0.8 s. The transport
buttons (−10 / +30) use the same path. The Playback menu lists all skips.

## Engineering notes

- Staying connected: the Apple TV fetches every segment from the Mac, and
  nobody touches the Mac while watching, so macOS idle-slept it mid-film
  (display off, "Idle Sleep" 5 s later, 42 s asleep) and the AirPlay connection
  was lost. While a session streams (not while paused) the app holds a
  `.userInitiated` activity (`SleepGuard`: PreventUserIdleSystemSleep; the
  display may still sleep; the lid still sleeps the Mac). A connection lost
  anyway (Wi-Fi drop, the lid) is retried from the TV's last reported position
  after 1, 3, 5, 10, 20 and 30 s (`RECONNECT_DELAYS`, the MediaRemote connection
  reopened too; a connection that played 60 s gets the full set again), shown
  as "connecting". The status poll tells a stop on the TV (it closes the
  connection: the end) from a lost one by the silence before it: no answer for
  over 8 s of wall clock (monotonic time stands still while the Mac sleeps).
- `Backend` protocol with `LiveBackend` (spawns
  `.venv/bin/python -m jancast serve --api-port 0` in `JANCAST_BACKEND_DIR`,
  parses `JANCAST_READY`, keeps stdin open, shows stderr tail on failure,
  closes stdin + SIGTERM on quit; `JANCAST_API_PORT` attaches to a running
  backend) and `MockBackend` (`--mock` / `JANCAST_MOCK=1`).
- Activity Monitor: the backend runs as "Jancast Backend" — a copy of the
  venv's Python launcher in `~/Library/Caches/jancast/bin`, refreshed when
  Python changes, pointed at the venv with `__PYVENV_LAUNCHER__` (plain
  `.venv/bin/python` if it won't start). ffmpeg and `jancast-ocr-*` run under it.
- `JANCAST_LOCAL_ONLY=1` (automated test runs): the backend never scans for
  Apple TVs and refuses to play to anything but This Mac or a simulated device.
- Housekeeping: work dirs go when a session ends (and stale ones at startup);
  thumbnails keep 40 files' worth; cached subtitle texts keep the 200 most
  recently used; only the current OCR helper build is kept.
- Decoding is lenient: optionals everywhere, enum-like fields as strings
  mapped with fallbacks, lossy arrays for samples/requests/events.
- Ring buffers: samples (4 h), requests (8000), events (3000); samples and
  requests reset when `session.id` changes (a track switch is a new session);
  events persist across sessions.
- Mock: 4 Apple TVs (online paired + last used, online needs pairing — any
  4-digit PIN works, not responding, offline), probe with 4 audio / 5
  subtitle tracks (one PGS), 3 recents (mid-way with resume — restored on
  launch, watched, 10 % in). Playback runs preparing → connecting →
  buffering → playing; ~60 s in the Wi-Fi degrades (segments < 1×
  realtime, RTT spikes and timeouts, a client abort, buffer drains, one
  stall; diagnosis warning → failing with network as top suspect) and
  recovers at ~105 s. Picking the PGS subtitle switches to a ~1.4× re-encode.
  `JANCAST_MOCK_SPEED=N` runs the simulation faster,
  `JANCAST_MOCK_AUTOPLAY=1` starts playing the sample file at launch,
  `JANCAST_MOCK_FAIL=N` makes the session fail N sim-seconds in (with a
  `session.error` message) to exercise the failure UI.
- Thumbnails (`Store/Thumbnails`): one `Thumbnails` object follows the
  file on screen (the playing file in the player, else the loaded one),
  polls `/api/thumbs` until `done`, and loads JPEGs on demand into a ≤ 240
  image cache; `image(at:)` returns the nearest loaded frame while the exact
  one loads, so hovering never flickers. No live SwiftUI blur, materials or
  repeating symbol effects over large areas: any animation redraws the whole
  layer every frame (a pulsing glyph over a live blur kept the main thread
  ~65 % busy and stalled the UI). Mock mode draws its thumbnails.
- `JANCAST_SNAPSHOT_DIR` / `_PLAN` / `_FULL` / `_SIZE` / `_QUIT` /
  `_HOVER`: in-app window capture to PNG (diagnostics tab names open the
  drawer on that tab; `_HOVER=0.3` pretends the pointer hovers the filmstrip
  at 30 %), plus `do-arrowright…` / `do-pause` steps; `JANCAST_MOCK_START=2600`
  makes mock autoplay start near the end (Up Next) (development aid; known
  limits: Form/List content and some materials render blank).

## Contract notes

- RTT timeouts: the Sample spec says `rtt_ms` is null on timeout, but with
  the 5 s "basic" probe rate most seconds are simply not probed. The app
  treats a second as a timeout only if `rtt_timeout: true` is present
  (proposed optional field), or — as a fallback — if `rtt_ms` is an explicit
  `null` *and* a `network` warning/error event is within ±1 s. Proposal:
  omit `rtt_ms` (or send null) for unprobed seconds and add
  `"rtt_timeout": true` on timeouts.
