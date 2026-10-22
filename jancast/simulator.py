"""Simulated Apple TV, so the whole pipeline can be tested and demoed without a TV.

`Devices(simulate="slow")` adds a `SimulatedDevice` ("Simulated Apple TV (slow)",
id "SIM:slow", no pairing). `Devices.connect()` returns a `FakeAppleTV` for it,
which offers what Session uses from a pyatv connection:

* `atv.stream.play_url(url)` blocks until playback ends, like pyatv. It runs a
  realistic HLS client over real HTTP against our server: master playlist ->
  video playlist -> audio rendition playlist (#EXT-X-MEDIA:TYPE=AUDIO) ->
  subtitle playlist -> both init segments -> video segments in order, each
  followed by the audio and WebVTT segments covering it, fetching while the
  forward buffer (measured on the video) is below 30 s (like AVPlayer) and
  reloading the playlists while they have no #EXT-X-ENDLIST. Downloads are paced per profile (chunked reads + sleep, with a
  small receive buffer) so the server's per-request timing reflects the
  simulated link. Transfers are aborted (TCP RST) on seek and, for `flaky`,
  when a segment crawls - as a real player does.
* A simulated playhead starts once ~2 segments are buffered, advances while
  data is buffered, stalls (playbackBufferEmpty) when it runs out and resumes
  after rebuffering one segment. Once per second it emits a playback-info dict
  with the same keys an Apple TV sends, through `airplay._report()` (the same
  path pyatv's /playback-info hook uses). Errors are reported like an Apple TV
  ({"error": {...}}) and make play_url raise pyatv's PlaybackError.
* Controls: it installs itself as `airplay.send_command`'s target and handles
  "/rate?value=0|1" (pause/resume), "/scrub?position=X" (seek: drops the
  buffer, aborts the transfer in flight, refetches from the right segment) and
  "/stop".
* RTT: the device listens on a local TCP port (its "AirPlay port", so plain TCP
  probes reach it) and offers `probe_rtt()`, which Session's latency loop
  prefers; it connects to that port and adds the profile's latency/loss.

Profiles (`PROFILES`): good, slow, flaky, tv-error, stuck - see their descriptions.

Time acceleration (`speed`, from the argument or JANCAST_SIM_SPEED, default 1):
the playhead advances `speed` x wall time and every bandwidth limit (and the
profile schedules) scale by the same factor, so buffer dynamics - when it
stalls, how far ahead it buffers - are identical to speed 1. What does *not*
scale is the backend: it measures realtime_ratio = media seconds / wall
seconds, so ratios inflate by `speed`, and its wall-clock rules (stall after 3
frozen reports, "TV stopped answering" after 6 s, the 60 s request window, the
30-probe RTT history) see compressed media time. Decision: speed is a demo
convenience; the simulator does not try to correct for it. Anything whose
diagnosis depends on the ratio thresholds must run at speed 1 with a short
clip (scripts/e2e_sim.py does that for slow/flaky/tv-error/stuck and only uses
speed > 1 for `good`, where inflated ratios cannot change the verdict).

Measurement caveat: the pacing happens in this process, behind the kernel's
TCP buffers. On macOS loopback the receive buffer autotunes to ~450 KB whatever
SO_RCVBUF says and the server's send buffer to ~1 MB, so the server sees the
first ~1 MB of every response as instantaneous. With 6 MB segments `slow`
(0.8x) therefore measures ~0.95x realtime on the server - still below 1.0.
"""

import asyncio
import http.client
import ipaddress
import os
import random
import socket
import struct
import threading
import time
import uuid
from dataclasses import dataclass
from urllib.parse import parse_qs, urljoin, urlsplit

from pyatv import exceptions

from . import airplay

TARGET_BUFFER_S = 30.0     # keep fetching while less than this is buffered ahead
START_BUFFER_S = 12.0      # ~2 segments before playback starts
RESUME_BUFFER_S = 6.0      # rebuffer this much after a stall / seek
SEEK_SETTLE_S = 1.5        # after a scrub the TV needs at least this long to resume
CHUNK = 64 * 1024
RCVBUF = 64 * 1024         # ask for a small TCP window (macOS autotunes it to ~450 KB anyway)
TICK = 0.1                 # playhead resolution, wall seconds
USER_AGENT = "AppleCoreMedia/1.0.0.21K69 (Apple TV; U; CPU OS 17_2 like Mac OS X; en_us)"

TV_ERROR = {"code": -11829, "domain": "AVFoundationErrorDomain",
            "localizedDescription": "Cannot Open"}


@dataclass(frozen=True)
class Window:
    """Recurring degradation: active for `length` s every `period` s from `offset` (sim time)."""
    period: float
    offset: float
    length: float
    bw_factor: float               # link bandwidth as a multiple of the stream bitrate
    rtt_ms: float = 0.0
    loss: float = 0.0              # fraction of latency probes that time out
    abort_after_s: float = None    # abort a segment transfer crawling for this long


@dataclass(frozen=True)
class Profile:
    name: str
    description: str
    bw_mbps: float = None          # absolute link bandwidth ...
    bw_factor: float = None        # ... or a multiple of the stream bitrate
    rtt_ms: float = 3.0
    window: Window = None
    error_at_s: float = None       # report TV_ERROR when the playhead gets here
    freeze_at_s: float = None      # playhead freezes here (decoder hang), data keeps coming

    def window_active(self, t):
        w = self.window
        return w is not None and t >= w.offset and (t - w.offset) % w.period < w.length


PROFILES = {p.name: p for p in (
    Profile("good", "~100 Mbit/s, 3 ms RTT", bw_mbps=100, rtt_ms=3),
    Profile("slow", "link at 0.8x the stream bitrate: stalls, network to blame",
            bw_factor=0.8, rtt_ms=12),
    Profile("flaky", "good, but every 40 s (from 25 s) a 15 s window at 0.3x bitrate with "
            "high latency, lost probes and aborted transfers",
            bw_mbps=100, rtt_ms=4,
            window=Window(period=40, offset=25, length=15, bw_factor=0.3, rtt_ms=180,
                          loss=0.5, abort_after_s=3.0)),
    Profile("tv-error", "plays ~20 s, then the TV reports AVFoundation error -11829",
            bw_mbps=100, rtt_ms=3, error_at_s=20),
    Profile("stuck", "data arrives fast but the playhead freezes at ~15 s: device to blame",
            bw_mbps=100, rtt_ms=3, freeze_at_s=15),
)}


def parse_profiles(spec):
    """'good' or 'good,slow' -> ['good', 'slow']; raises ValueError for unknown names."""
    names = [n.strip() for n in str(spec).split(",") if n.strip()]
    bad = [n for n in names if n not in PROFILES]
    if bad or not names:
        raise ValueError(f"unknown simulator profile {', '.join(bad) or spec!r}; "
                         f"choose from {', '.join(PROFILES)}")
    return names


@dataclass(frozen=True)
class Conditions:
    bw_mbps: float
    bw_factor: float
    rtt_ms: float
    loss: float
    abort_after_s: float
    degraded: bool


class SimulatedDevice:
    """Duck-typed stand-in for a pyatv config (see airplay.is_simulated & co.)."""

    simulated = True

    def __init__(self, profile, speed=None):
        parse_profiles(profile)
        self.profile = PROFILES[profile]
        self.name = f"Simulated Apple TV ({profile})"
        self.identifier = f"SIM:{profile}"
        self.address = ipaddress.IPv4Address("127.0.0.1")
        self.model_str = "Simulated Apple TV"
        self.speed = float(speed or os.environ.get("JANCAST_SIM_SPEED") or 1)
        if self.speed <= 0:
            raise ValueError("simulator speed must be > 0")
        self._clock_start = None
        self._rng = random.Random(profile)
        # The "AirPlay port": accepts and closes connections, so TCP probes succeed.
        self._listener = socket.create_server((str(self.address), 0))
        self.port = self._listener.getsockname()[1]
        threading.Thread(target=self._accept_loop, daemon=True,
                         name=f"sim-atv-{profile}-port").start()

    def __repr__(self):
        return f"<SimulatedDevice {self.identifier} speed={self.speed}>"

    def _accept_loop(self):
        while True:
            try:
                conn, _ = self._listener.accept()
                conn.close()
            except OSError:
                return

    def sim_time(self):
        """Simulated seconds since the current playback started (-1 when idle)."""
        if self._clock_start is None:
            return -1.0
        return (time.monotonic() - self._clock_start) * self.speed

    def conditions(self):
        p = self.profile
        if p.window_active(self.sim_time()):
            w = p.window
            return Conditions(None, w.bw_factor, w.rtt_ms, w.loss, w.abort_after_s, True)
        return Conditions(p.bw_mbps, p.bw_factor, p.rtt_ms, 0.0, None, False)

    async def probe_rtt(self):
        """Latency in ms like Session's TCP probe, or None for a lost probe."""
        c = self.conditions()
        loop = asyncio.get_running_loop()
        t0 = loop.time()
        if c.loss and self._rng.random() < c.loss:
            await asyncio.sleep(1.0)          # the real probe's timeout
            return None
        try:
            _, writer = await asyncio.wait_for(
                asyncio.open_connection(str(self.address), self.port), 1.0)
            writer.close()
        except (OSError, asyncio.TimeoutError):
            return None
        await asyncio.sleep(c.rtt_ms * (0.8 + 0.4 * self._rng.random()) / 1000)
        return (loop.time() - t0) * 1000

    def connect(self):
        return FakeAppleTV(self)


class FakeAppleTV:
    """What Devices.connect() returns for a simulated device."""

    def __init__(self, device):
        self.device = device
        self.stream = _Stream(self)
        self._player = None

    def close(self):
        if self._player:
            self._player.close()
        return set()                          # pyatv returns pending close tasks


class _Stream:
    def __init__(self, atv):
        self._atv = atv

    async def play_url(self, url, position=0, **_kwargs):
        player = _Player(self._atv.device, url, position)
        self._atv._player = player
        await player.run()


class _Closed(Exception):
    pass


class _HTTPStatus(Exception):
    def __init__(self, status, path):
        super().__init__(f"HTTP {status}: {path}")
        self.status = status
        self.path = path


_RETRY = object()                             # transfer failed/aborted, try again


class _Conn(http.client.HTTPConnection):
    """Keep-alive connection with a small receive window (so pacing is visible
    to the sender) that can be torn down with a RST like an aborting player."""

    def connect(self):
        family, stype, proto, _, addr = socket.getaddrinfo(
            self.host, self.port, type=socket.SOCK_STREAM)[0]
        sock = socket.socket(family, stype, proto)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, RCVBUF)
        sock.settimeout(self.timeout)
        sock.connect(addr)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.sock = sock

    def abort(self):
        if self.sock:
            try:
                self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                                     struct.pack("ii", 1, 0))
            except OSError:
                pass
        self.close()


@dataclass
class _Seg:
    start: float
    duration: float
    uri: str


def _parse_media_playlist(text):
    segs, endlist, target, init = [], False, 6.0, None
    t, dur = 0.0, None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("#EXTINF:"):
            dur = float(line[8:].split(",")[0])
        elif line.startswith("#EXT-X-TARGETDURATION:"):
            target = float(line.split(":", 1)[1])
        elif line.startswith("#EXT-X-MAP:"):
            init = line.split('URI="', 1)[1].split('"', 1)[0]
        elif line == "#EXT-X-ENDLIST":
            endlist = True
        elif line and not line.startswith("#") and dur is not None:
            segs.append(_Seg(t, dur, line))
            t += dur
            dur = None
    return segs, endlist, target, init


class _Player:
    """One play_url(): an HLS download thread plus a playhead on the event loop."""

    def __init__(self, device, url, start_position=0):
        self.device = device
        self.profile = device.profile
        self.speed = device.speed
        self.url = url
        u = urlsplit(url)
        self.host, self.port = u.hostname, u.port or 80
        self.lock = threading.Lock()
        self.closed = False
        self.stopped = False
        self.gen = 0                  # bumped on seek/close; stale transfers abort
        self.segments = []
        self.audio = []               # audio rendition segments (fetched alongside video)
        self.subs = []
        self.endlist = False
        self.target_duration = 6.0
        self.media_path = self.sub_path = self.init_path = None
        self.audio_path = self.audio_init_path = None
        self.position = float(start_position or 0)
        self.range_start = self.loaded_end = 0.0
        self.next_index = self.next_sub = self.next_audio = 0
        self.started = self.waiting = self.paused = self.frozen = self.ended = False
        self.settle_until = 0.0       # monotonic time before which a seek cannot resume
        self.fatal = None             # error dict reported to the backend
        self.bitrate_bps = None
        self._seg_bytes = 0           # video segment bytes ...
        self._seg_media = 0.0         # ... and their media seconds
        self._audio_bytes = 0
        self._conn = None
        self._last_reload = 0.0
        self.session_id = str(uuid.uuid4()).upper()

    @property
    def duration(self):
        return (self.segments[-1].start + self.segments[-1].duration) if self.segments else 0.0

    def _complete(self):
        return self.endlist and self.next_index >= len(self.segments)

    # ---- control ---------------------------------------------------------

    def close(self):
        self.closed = True
        self.gen += 1
        airplay.clear_command_target(self.command)

    async def command(self, path):
        u = urlsplit(path)
        q = parse_qs(u.query)
        try:
            if u.path == "/rate":
                with self.lock:
                    self.paused = float(q["value"][0]) == 0
            elif u.path == "/scrub":
                self.seek(float(q["position"][0]))
            elif u.path == "/stop":
                self.stopped = True
            else:
                raise RuntimeError(f"Apple TV answered 404 to {path}")
        except (KeyError, ValueError) as e:
            raise RuntimeError(f"Apple TV answered 400 to {path}") from e

    def seek(self, position):
        with self.lock:
            if not self.segments:
                self.position = max(0.0, position)
                return
            pos = max(0.0, min(position, self.duration - 0.1))
            idx = next((i for i, s in enumerate(self.segments)
                        if s.start <= pos < s.start + s.duration), len(self.segments) - 1)
            self.gen += 1
            self.position = pos
            self.next_index = idx
            self.range_start = self.loaded_end = self.segments[idx].start
            self.next_sub = self._first_covering(self.subs, self.range_start)
            self.next_audio = self._first_covering(self.audio, self.range_start)
            self.ended = False
            self.settle_until = time.monotonic() + SEEK_SETTLE_S / self.speed
            if self.started:
                self.waiting = True

    @staticmethod
    def _first_covering(segs, t):
        return next((j for j, s in enumerate(segs) if s.start + s.duration > t), len(segs))

    # ---- playhead (event loop) -------------------------------------------

    async def run(self):
        loop = asyncio.get_running_loop()
        self.device._clock_start = time.monotonic()
        airplay.set_command_target(self.command)
        threading.Thread(target=self._download_main, daemon=True,
                         name=f"sim-atv-{self.profile.name}-http").start()
        last = loop.time()
        next_report = last + 1.0
        empty_reports = 0
        try:
            while True:
                await asyncio.sleep(TICK)
                now = loop.time()
                self._advance((now - last) * self.speed)
                last = now
                if now < next_report:
                    continue
                next_report += 1.0
                if self.stopped:
                    return                    # pyatv: no more "duration" -> playback ended
                info = self._playback_info()
                if info is None:
                    # Nothing loaded yet: the TV answers without content. pyatv gives
                    # up after a few such polls, treating it as "playback ended".
                    empty_reports += 1
                    if empty_reports > 5:
                        return
                    continue
                airplay._report(info)
                if "error" in info:
                    err = info["error"]
                    raise exceptions.PlaybackError(
                        f"got error {err.get('code', 'unknown')} "
                        f"({err.get('domain', 'unknown domain')}) when playing video")
                if self.ended:
                    return
        finally:
            self.close()
            self.device._clock_start = None

    def _advance(self, dt):
        p = self.profile
        with self.lock:
            if self.ended or self.fatal or not self.segments:
                return
            complete = self._complete()
            ahead = self.loaded_end - self.position
            if not self.started:
                if ahead > 0 and (ahead >= START_BUFFER_S - 1e-6 or complete):
                    self.started = True
                else:
                    return
            if self.paused:
                return
            if self.waiting:
                if time.monotonic() < self.settle_until:
                    return
                if ahead > 0 and (ahead >= RESUME_BUFFER_S - 1e-6 or complete):
                    self.waiting = False
                else:
                    return
            if self.frozen:
                return
            self.position = min(self.position + dt, self.loaded_end)
            if p.freeze_at_s is not None and self.position >= p.freeze_at_s:
                self.frozen = True
            if p.error_at_s is not None and self.position >= p.error_at_s:
                self.fatal = dict(TV_ERROR)
            if self.position >= self.loaded_end - 1e-6:
                if complete:
                    self.ended = True
                else:
                    self.waiting = True       # ran dry: stall

    def _playback_info(self):
        with self.lock:
            if self.fatal:
                return {"error": dict(self.fatal)}
            if not self.segments:
                return None
            dur = self.duration
            complete = self._complete()
            ahead = max(0.0, self.loaded_end - self.position)
            playing = self.started and not self.waiting and not self.paused
            loaded = ([{"start": round(self.range_start, 3),
                        "duration": round(self.loaded_end - self.range_start, 3)}]
                      if self.loaded_end > self.range_start else [])
            return {
                "duration": round(dur, 3),
                "position": round(self.position, 3),
                "rate": 1.0 if playing else 0.0,
                "readyToPlay": self.started,
                "playbackBufferEmpty": ahead < 0.05 and not complete,
                "playbackBufferFull": ahead >= TARGET_BUFFER_S or (complete and ahead > 0),
                "playbackLikelyToKeepUp": self.started and not self.waiting,
                "loadedTimeRanges": loaded,
                "seekableTimeRanges": [{"start": 0.0, "duration": round(dur, 3)}],
            }

    # ---- HLS client (thread) ---------------------------------------------

    def _download_main(self):
        try:
            self._load_master()
            self._reload_playlists()
            if self.init_path:
                self._fetch_until_done("init", self.init_path)
            if self.audio_init_path:
                self._fetch_until_done("init", self.audio_init_path)
            while True:
                self._step()
        except _Closed:
            pass
        except _HTTPStatus as e:
            with self.lock:
                self.fatal = {"code": -12938, "domain": "CoreMediaErrorDomain",
                              "localizedDescription": str(e)}
        except Exception as e:  # noqa: BLE001 - becomes a TV-side error report
            with self.lock:
                self.fatal = {"code": -1005, "domain": "NSURLErrorDomain",
                              "localizedDescription": f"The network connection was lost ({e})"}
        finally:
            if self._conn:
                self._conn.close()

    def _path(self, uri):
        u = urlsplit(urljoin(self.url, uri))
        return u.path + (f"?{u.query}" if u.query else "")

    def _load_master(self):
        text = self._fetch_until_done("master", self._path(self.url)).decode()
        if "#EXT-X-STREAM-INF" not in text:
            self.media_path = self._path(self.url)      # a media playlist, not a master
            return
        lines = text.splitlines()
        for i, line in enumerate(lines):
            if line.startswith("#EXT-X-STREAM-INF") and self.media_path is None:
                attrs = line.split(":", 1)[1]
                for key in ("AVERAGE-BANDWIDTH=", "BANDWIDTH="):
                    if key in attrs:
                        self.bitrate_bps = float(attrs.split(key, 1)[1].split(",")[0])
                        break
                uri = next(x for x in lines[i + 1:] if x.strip() and not x.startswith("#"))
                self.media_path = self._path(uri.strip())
            elif line.startswith("#EXT-X-MEDIA:") and "TYPE=SUBTITLES" in line \
                    and 'URI="' in line and self.sub_path is None:
                self.sub_path = self._path(line.split('URI="', 1)[1].split('"', 1)[0])
            elif line.startswith("#EXT-X-MEDIA:") and "TYPE=AUDIO" in line \
                    and 'URI="' in line and self.audio_path is None:
                self.audio_path = self._path(line.split('URI="', 1)[1].split('"', 1)[0])

    def _reload_playlists(self):
        segs, endlist, target, init = _parse_media_playlist(
            self._fetch_until_done("playlist", self.media_path).decode())
        audio = audio_init = subs = None
        if self.audio_path:
            audio, _, _, audio_init = _parse_media_playlist(
                self._fetch_until_done("playlist", self.audio_path).decode())
        if self.sub_path:
            subs = _parse_media_playlist(
                self._fetch_until_done("playlist", self.sub_path).decode())[0]
        with self.lock:
            self.segments = [_Seg(s.start, s.duration, self._path(s.uri)) for s in segs]
            self.endlist, self.target_duration = endlist, target
            if audio is not None:
                self.audio = [_Seg(s.start, s.duration, self._path(s.uri)) for s in audio]
            if subs is not None:
                self.subs = [_Seg(s.start, s.duration, self._path(s.uri)) for s in subs]
        if init:
            self.init_path = self._path(init)
        if audio_init:
            self.audio_init_path = self._path(audio_init)
        self._last_reload = time.monotonic()

    def _step(self):
        with self.lock:
            if self.closed:
                raise _Closed
            gen, idx = self.gen, self.next_index
            have = idx < len(self.segments)
            ahead = self.loaded_end - self.position
        if not have:
            if not self.endlist and (time.monotonic() - self._last_reload
                                     >= self.target_duration / 2 / self.speed):
                self._reload_playlists()
            else:
                self._sleep(0.05)
            return
        if ahead >= TARGET_BUFFER_S:
            self._sleep(0.05)
            return
        seg = self.segments[idx]
        body = self._fetch("segment", seg.uri, media_s=seg.duration, gen=gen)
        if body is _RETRY:
            self._sleep(0.5 / self.speed)
            return
        if body is None:
            return                            # superseded by a seek
        with self.lock:
            if gen != self.gen:
                return
            self._seg_bytes += len(body)
            self._seg_media += seg.duration
            self._update_bitrate()
            self.loaded_end = seg.start + seg.duration
            self.next_index = idx + 1
        end = seg.start + seg.duration
        # The audio and subtitles covering what we just loaded. Only the video
        # counts towards the buffer; audio is small next to it.
        if self._fetch_covering("audio", "audio", "next_audio", end, gen):
            self._fetch_covering("subtitle", "subs", "next_sub", end, gen)

    def _update_bitrate(self):
        """Stream bitrate (video + audio) seen so far; call with the lock held."""
        if self._seg_media:
            self.bitrate_bps = (self._seg_bytes + self._audio_bytes) * 8 / self._seg_media

    def _fetch_covering(self, kind, segs_attr, next_attr, end, gen):
        """Fetch the segments of `segs_attr` starting before `end`, advancing
        `next_attr`. False if a seek/close superseded them."""
        while True:
            with self.lock:
                segs, j = getattr(self, segs_attr), getattr(self, next_attr)
                if gen != self.gen:
                    return False
                if j >= len(segs) or segs[j].start >= end - 1e-3:
                    return True
                seg = segs[j]
            r = self._fetch(kind, seg.uri, gen=gen)
            if r is None:
                return False
            if r is _RETRY:
                self._sleep(0.5 / self.speed)
                continue
            with self.lock:
                if gen != self.gen:
                    return False
                setattr(self, next_attr, j + 1)
                if kind == "audio":
                    self._audio_bytes += len(r)
                    self._update_bitrate()

    def _sleep(self, seconds, gen=None):
        """Sleep in small slices; False if interrupted by close/seek."""
        end = time.monotonic() + seconds
        while True:
            if self.closed:
                raise _Closed
            if gen is not None and gen != self.gen:
                return False
            left = end - time.monotonic()
            if left <= 0:
                return True
            time.sleep(min(left, 0.05))

    def _fetch_until_done(self, kind, path):
        while True:
            body = self._fetch(kind, path)
            if body is not _RETRY:
                return body
            self._sleep(1.0 / self.speed)

    def _connection(self):
        if self._conn is None:
            self._conn = _Conn(self.host, self.port, timeout=15)
        return self._conn

    def _drop_conn(self, abort=False):
        if self._conn:
            if abort:
                self._conn.abort()
            else:
                self._conn.close()
            self._conn = None

    def _fetch(self, kind, path, media_s=None, gen=None):
        """GET `path` paced by the simulated link. Returns the body, None when a
        seek made it obsolete, or _RETRY (404 for a segment, slow transfer
        aborted, connection error)."""
        if self.closed:
            raise _Closed
        for attempt in range(5):
            try:
                conn = self._connection()
                conn.request("GET", path, headers={
                    "User-Agent": USER_AGENT, "Accept": "*/*",
                    "X-Playback-Session-Id": self.session_id})
                resp = conn.getresponse()
            except (OSError, http.client.HTTPException):
                self._drop_conn()
                if attempt == 4:
                    raise
                self._sleep(1.0 / self.speed)
                continue
            if resp.status >= 400:
                resp.read()
                if resp.will_close:
                    self._drop_conn()
                if resp.status == 404 and kind in ("segment", "audio", "subtitle"):
                    return _RETRY             # not prepared yet: AVPlayer retries
                raise _HTTPStatus(resp.status, path)
            try:
                return self._read_body(resp, kind, media_s, gen)
            except (OSError, http.client.HTTPException):
                self._drop_conn(abort=True)
                return _RETRY
        return _RETRY

    def _link_bps(self, kind, length, media_s):
        c = self.device.conditions()
        if c.bw_mbps:
            bps = c.bw_mbps * 1e6
        else:
            if kind == "segment" and media_s:
                est = ((self._seg_bytes + self._audio_bytes + length) * 8
                       / (self._seg_media + media_s))
            else:
                est = self.bitrate_bps or 5e6
            bps = c.bw_factor * est
        return bps * self.speed, c

    def _read_body(self, resp, kind, media_s, gen):
        length = int(resp.getheader("Content-Length") or 0)
        body = bytearray()
        t_start = time.monotonic()
        _, c = self._link_bps(kind, length, media_s)
        next_t = t_start + c.rtt_ms / 1000            # first-byte latency
        while len(body) < length:
            if self.closed:
                self._drop_conn()                     # player went away: plain close
                raise _Closed
            if gen is not None and gen != self.gen:
                self._drop_conn(abort=True)           # seek: abandon this transfer
                return None
            chunk = resp.read(min(CHUNK, length - len(body)))
            if not chunk:
                raise OSError("connection closed mid-transfer")
            body += chunk
            bps, c = self._link_bps(kind, length, media_s)
            now = time.monotonic()
            next_t = max(next_t, now - 0.02) + len(chunk) * 8 / bps
            if kind == "segment" and c.abort_after_s and media_s:
                elapsed_sim = (now - t_start) * self.speed
                if elapsed_sim > c.abort_after_s:
                    projected = len(body) / length * media_s / elapsed_sim
                    if projected < 0.5:               # hopelessly slow: drop and retry
                        self._drop_conn(abort=True)
                        return _RETRY
            if next_t > now and not self._sleep(next_t - now, gen):
                self._drop_conn(abort=True)
                return None
        if resp.will_close:
            self._drop_conn()
        return bytes(body)
