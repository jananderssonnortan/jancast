""""This Mac": play the stream in the app's own player window instead of on a TV.

Lets the whole pipeline (preparation, HLS server, master playlist, subtitles,
resume, diagnostics) be tried without occupying the Apple TV. The app plays
the stream with AVPlayer - the same AVFoundation stack as tvOS - so most
stream problems show up here too; AirPlay itself (pairing, the play queue,
the TV's own quirks) is not exercised.

`LocalDevice` is duck-typed like the simulator's device (see airplay.is_simulated
& co.: no pairing, 127.0.0.1, in-place controls through airplay.send_command).
Its `connect()` returns a `LocalAppleTV` whose `stream.play_url()` publishes
the stream for the app (GET /api/state -> "local_player") and waits:

* The app POSTs /api/local/report about once a second with what AVPlayer sees;
  `report()` turns it into the same playback-info dict an Apple TV sends and
  hands it to `airplay._report()`.
* Controls (pause/resume/seek/stop) arrive as AirPlay-style requests through
  `airplay.send_command` and are queued as commands for the app, which applies
  them to AVPlayer and acknowledges them by id in its next report. A report
  made while a seek is still unacknowledged is marked `_seek_pending` (the
  session ignores it: it shows the spot before the jump).
* play_url returns when the app reports the end of the media. Closing the
  window counts as Stop (cancelled, position saved, not "watched"). It raises
  if the app never starts reporting or stops reporting while playing.
"""

import asyncio
import ipaddress
import socket
import threading
import time
from urllib.parse import parse_qs, urlsplit

from . import airplay

DEVICE_ID = "LOCAL:this-mac"
STARTUP_TIMEOUT_S = 30      # the app must open its player and report by then
SILENCE_TIMEOUT_S = 10      # no reports for this long while playing = app went away


class LocalDevice:
    """Duck-typed stand-in for a pyatv config, always available."""

    simulated = True          # no pairing, local address, in-place controls
    local = True              # but real watching: resume history is saved

    def __init__(self):
        self.name = "This Mac"
        self.identifier = DEVICE_ID
        self.address = ipaddress.IPv4Address("127.0.0.1")
        self.model_str = "Mac (Jancast player window)"
        self.player = None    # the current LocalPlayer, if any
        # A port that accepts connections, so reachability and latency probes
        # see the device as online (like the simulator's "AirPlay port").
        self._listener = socket.create_server((str(self.address), 0))
        self.port = self._listener.getsockname()[1]
        threading.Thread(target=self._accept_loop, daemon=True, name="local-player-port").start()

    def __repr__(self):
        return f"<LocalDevice {self.identifier}>"

    def _accept_loop(self):
        while True:
            try:
                conn, _ = self._listener.accept()
                conn.close()
            except OSError:
                return

    def connect(self):
        return LocalAppleTV(self)

    def state_json(self):
        p = self.player
        return p.state_json() if p else None

    async def report(self, body):
        p = self.player
        if p is None:
            raise RuntimeError("nothing is playing on This Mac")
        p.report(body)


class LocalAppleTV:
    def __init__(self, device):
        self.device = device
        self.stream = _Stream(self)
        self._player = None

    def close(self):
        if self._player:
            self._player.close()
        return set()


class _Stream:
    def __init__(self, atv):
        self._atv = atv

    async def play_url(self, url, position=0, **_kwargs):
        player = LocalPlayer(url, position)
        self._atv._player = player
        self._atv.device.player = player
        await player.run()


class LocalPlayer:
    def __init__(self, url, start_position=0):
        self.url = url
        self.start_position = float(start_position or 0)
        self.commands = []          # [{"id", "action", "position"?}] not yet acknowledged
        self._next_id = 1
        self.active = True
        self.started = False        # the app reported a duration (media loaded)
        self.last_report = None     # monotonic time of the latest report
        self._done = None           # set in run(): asyncio.Event
        self._error = None
        self._closed = False        # the user closed the window: a stop, not the end
        # One bound method, so clear_command_target's identity check matches.
        self._target = self.command

    def state_json(self):
        return {"url": self.url, "start_position": self.start_position,
                "active": self.active, "commands": list(self.commands)}

    # ---- from the app ------------------------------------------------------

    def report(self, body):
        """One report from the app's AVPlayer (see docs/API.md)."""
        self.last_report = time.monotonic()
        ack = body.get("ack")
        if isinstance(ack, int):
            self.commands = [c for c in self.commands if c["id"] > ack]
        info = to_playback_info(body)
        if "duration" in info:
            self.started = True
            if any(c["action"] == "seek" for c in self.commands):
                # Made before the app applied the seek: the old spot, not the new one.
                info["_seek_pending"] = True
        airplay._report(info)
        if body.get("error"):
            self._finish(RuntimeError(f"This Mac's player failed: {body['error']}"))
        elif body.get("closed"):
            self._closed = True
            self._finish()
        elif body.get("ended"):
            self._finish()

    # ---- from the session (airplay.send_command) ---------------------------

    async def command(self, path):
        u = urlsplit(path)
        q = parse_qs(u.query)
        try:
            if u.path == "/rate":
                self._queue("pause" if float(q["value"][0]) == 0 else "resume")
            elif u.path == "/scrub":
                self._queue("seek", position=round(float(q["position"][0]), 3))
            elif u.path == "/stop":
                self._queue("stop")
            else:
                raise RuntimeError(f"This Mac's player has no {u.path} command")
        except (KeyError, ValueError) as e:
            raise RuntimeError(f"bad command {path}") from e

    def _queue(self, action, **extra):
        self.commands.append({"id": self._next_id, "action": action, **extra})
        self._next_id += 1

    # ---- lifecycle -----------------------------------------------------------

    async def run(self):
        self._done = asyncio.Event()
        airplay.set_command_target(self._target)
        began = time.monotonic()
        try:
            while not self._done.is_set():
                try:
                    await asyncio.wait_for(self._done.wait(), 1.0)
                except asyncio.TimeoutError:
                    pass
                now = time.monotonic()
                if self.last_report is None:
                    if now - began > STARTUP_TIMEOUT_S:
                        raise RuntimeError(f"This Mac's player did not start within "
                                           f"{STARTUP_TIMEOUT_S} s (is the Jancast app running?)")
                elif now - self.last_report > SILENCE_TIMEOUT_S:
                    raise RuntimeError("This Mac's player stopped reporting (window closed or "
                                       "app quit?)")
            if self._error:
                raise self._error
            if self._closed:
                # Like pressing Stop: the session saves the position, not "watched".
                raise asyncio.CancelledError
        finally:
            self.close()

    def _finish(self, error=None):
        self._error = self._error or error
        if self._done is not None:
            self._done.set()

    def close(self):
        if self.active:
            self.active = False
            self._queue("stop")         # tells the app to close its window
        airplay.clear_command_target(self._target)


def to_playback_info(body):
    """The app's report as the playback-info dict an Apple TV would send.
    No "duration" until AVPlayer has loaded the media (like the TV)."""
    info = {}
    duration = body.get("duration")
    if isinstance(duration, (int, float)) and duration > 0:
        info.update(
            duration=float(duration),
            position=float(body.get("position") or 0),
            rate=float(body.get("rate") or 0),
            readyToPlay=bool(body.get("ready_to_play")),
            playbackBufferEmpty=bool(body.get("buffer_empty")),
            playbackBufferFull=bool(body.get("buffer_full")),
            playbackLikelyToKeepUp=bool(body.get("likely_to_keep_up")),
            loadedTimeRanges=[{"start": float(r.get("start", 0)), "duration": float(r.get("duration", 0))}
                              for r in body.get("loaded_ranges") or [] if isinstance(r, dict)],
        )
    if body.get("error"):
        info["error"] = {"code": -1, "domain": "AVFoundationErrorDomain",
                         "localizedDescription": str(body["error"])}
    return info
