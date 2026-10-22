"""One playback session: prepare HLS, serve it, play it on the Apple TV, and
collect everything needed to explain what went wrong."""

import asyncio
import logging
import math
import os
import shutil
import tempfile
import time
import uuid
from pathlib import Path

from . import airplay, history, names, ocrsubs, ondemand
from .hls_server import HLSServer, directory_bitrate
from .media import (SEGMENT_SECONDS, Track, Transcoder, audio_plan, build_ffmpeg_cmd,
                    extract_text_subtitles,
                    read_segment_durations, write_master)
from .telemetry import diagnose

SEEK_SETTLE_S = 4.0          # landed (ready, buffered) but not playing this long after a seek = paused
STALL_REPORTS = 3            # position frozen this many reports while rate > 0 = stall
START_GRACE_S = 5.0          # a wait this soon after (re)starting to play is start-up, not a stall
SEEK_NEAR_S = 3.0            # a report this close to a seek's target has landed there
SEEK_STALE_S = 10.0          # how long after a seek a report from the old spot is ignored
HISTORY_EVERY_S = 10         # how often playback progress is saved for resume
READY_AHEAD_S = 3 * SEGMENT_SECONDS   # prepared video past the start point before playing
# A remux is sent to the TV only once it is complete, so the TV gets a
# finished (VOD) playlist. Starting on the growing playlist was tried: tvOS 26
# treats it as a live stream (LIVE badge), never reloads it to see the rest,
# and freezes after seeks. JANCAST_EARLY_START=1 brings that back for testing.
# (Re-encodes always start early; they are far slower than realtime remuxes.)
WAIT_FULL_PREP = os.environ.get("JANCAST_EARLY_START") != "1"
WORKDIR_PREFIX = "jancast-"
OWNER_FILE = "owner.pid"     # pid of the backend that made a work dir


def sweep_stale_workdirs(parent=None):
    """Remove work dirs (a full-size copy of the stream each) left behind by a
    backend that was killed before it could clean up. Only dirs with an
    owner file whose process is gone; returns the bytes freed."""
    parent = Path(parent or tempfile.gettempdir())
    freed = 0
    for d in parent.glob(WORKDIR_PREFIX + "*"):
        try:
            pid = int((d / OWNER_FILE).read_text())
        except (OSError, ValueError):
            continue
        if pid == os.getpid() or _alive(pid):
            continue
        freed += sum(f.stat().st_size for f in d.iterdir() if f.is_file())
        shutil.rmtree(d, ignore_errors=True)
    return freed


def _alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True
RTT_INTERVALS = {"basic": 5.0, "detailed": 1.0}   # latency probe period per telemetry level
PLAYBACK_REPORT_KEYS = ("position", "duration", "rate", "readyToPlay", "playbackBufferEmpty",
                        "playbackBufferFull", "playbackLikelyToKeepUp", "loadedTimeRanges")


class TelemetryLogHandler(logging.Handler):
    """Forward pyatv warnings/errors into the event log."""

    def __init__(self, telemetry):
        super().__init__(logging.WARNING)
        self.telemetry = telemetry

    def emit(self, record):
        level = "error" if record.levelno >= logging.ERROR else "warn"
        self.telemetry.event(level, "airplay", record.getMessage())


class Session:
    def __init__(self, telemetry, devices, media, audio, sub, conf,
                 stereo=False, quality=65, workdir=None, hls_port=0, start_position=0,
                 telemetry_level="basic", subtitle_delay=0.0):
        self.id = uuid.uuid4().hex[:8]
        self.telemetry = telemetry
        self.devices = devices
        self.media = media
        self.audio = audio
        self.sub = sub
        self.subtitle_delay = float(subtitle_delay or 0)   # seconds, + = later
        self.play_sub = sub         # what ffmpeg gets: a text file for OCR/delayed subtitles
        self._sub_progress = None   # 0..1 while picture subtitles are read as text
        self.conf = conf
        self.stereo = stereo
        self.quality = quality
        self.workdir_parent = workdir
        self.hls_port = hls_port
        self.start_position = max(0.0, float(start_position or 0))
        self.telemetry_level = telemetry_level
        self.started_at = time.time()
        self.last_seek_at = None
        self.time_to_play_s = None      # Play → the TV playing
        self.seek_to_play_s = None      # last jump → playing again
        self._seeking = False
        self._paused_at_seek = False    # a seek made while paused ends paused, not playing
        self._seek_target = None        # where the latest seek goes (None: not known)
        self._seek_origin = None        # where playback was when it was made
        self._grace_until = None        # waits before this are start-up after play/resume
        self._stale_empty_logged = False
        self._history_saved_at = 0.0
        self._fresh_rtt = None      # (rtt_ms | None) from a probe since the last sample
        self._play_task = None
        self._reposition = None     # seek target while playback restarts there
        self._remote = None         # second pyatv connection for MediaRemote seek/skip
        self._early_connect = None  # AirPlay connection opened while ffmpeg prepares
        self._remote_task = None
        self.phase = "preparing"
        self.stream_url = None
        self.stream_bitrate = None
        self.transcoder = None
        self.server = None
        self.atv = None
        self.task = None
        self.user_paused = False
        self.error = None
        self.playback = {"position": None, "duration": None, "rate": None,
                         "buffered_ahead_s": None, "buffer_empty": None, "buffer_full": None,
                         "likely_to_keep_up": None, "ready_to_play": None, "stall_count": 0,
                         "stalled_s_total": 0.0, "last_report_at": None, "error": None}
        self._started_playing = False
        self._frozen_reports = 0
        self._last_position = None
        self._stall_began = None
        self._logged_keys = False
        self._logged_startup_status = False
        self._short_since = None        # TV still sees a shorter stream after prep finished

    # ---- lifecycle --------------------------------------------------------

    def start(self):
        self.task = asyncio.ensure_future(self._run())
        return self.task

    async def stop(self):
        if self.task and not self.task.done():
            self.task.cancel()
            try:
                await self.task
            except (asyncio.CancelledError, Exception):
                pass

    def _set_phase(self, phase, level="info", message=None):
        if phase == self.phase:
            return
        self.phase = phase
        self.telemetry.event(level, "app", message or f"Phase: {phase}")

    async def _run(self):
        tm = self.telemetry
        tm.reset_counters()
        log_handler = TelemetryLogHandler(tm)
        logging.getLogger("pyatv").addHandler(log_handler)
        workdir = Path(tempfile.mkdtemp(prefix=WORKDIR_PREFIX, dir=self.workdir_parent))
        (workdir / OWNER_FILE).write_text(str(os.getpid()))
        side_tasks = []
        try:
            vmode, reason = self.media.video_plan(self.sub)
            tm.event("info", "app", f"Starting {self.media.path.name} on {self.conf.name}")
            tm.event("info", "app", f"Video {self.media.video_codec}: {vmode}"
                     + (f" ({reason})" if reason else ""))
            amode, aout, _ = audio_plan(self.audio, self.stereo)
            tm.event("info", "app", f"Audio {self.audio.label()}: {amode} -> {aout}")
            if self.sub:
                tm.event("info", "app", f"Subtitles {self.sub.label()}: "
                         + ("burned in" if self.sub.burns_in
                            else "picture subtitles as text (OCR)" if self.sub.via_ocr
                            else "soft (WebVTT)")
                         + (f", delay {self.subtitle_delay:+.1f} s" if self.subtitle_delay else ""))
            self.play_sub = await self._prepare_subtitles()

            keyframes = await asyncio.get_running_loop().run_in_executor(
                None, ondemand.keyframes_for, self.media, self.play_sub)
            fast = None
            if keyframes:
                # Fast start: complete playlists now, segments made on request.
                fast = ondemand.OnDemand(self.media, self.audio, self.play_sub, workdir, keyframes,
                                         self.stereo,
                                         on_warning=lambda line: tm.event("warn", "ffmpeg", line),
                                         subtitle_delay=self.subtitle_delay)
                tm.event("info", "ffmpeg", f"Fast start: {fast.count} segments planned from the "
                         f"file's keyframe index; made on request")
                self.transcoder = fast
                fast.start(self.start_position)
            else:
                cmd = build_ffmpeg_cmd(self.media, self.audio, self.play_sub, workdir,
                                       self.stereo, self.quality,
                                       sub_delay=self.subtitle_delay
                                       if self.play_sub and self.play_sub.file else 0.0)
                tm.event("info", "ffmpeg", "Running: " + " ".join(cmd))
                self.transcoder = Transcoder(
                    cmd, self.media.duration,
                    on_warning=lambda line: tm.event("warn", "ffmpeg", line))
            side_tasks.append(asyncio.ensure_future(self._sample_loop(workdir)))
            # Connect to the TV while ffmpeg works instead of after it.
            self._early_connect = asyncio.ensure_future(self.devices.connect(self.conf))
            if not airplay.is_simulated(self.conf):
                self._remote_task = asyncio.ensure_future(self._connect_remote())
            if fast:
                started = time.monotonic()
                await asyncio.get_running_loop().run_in_executor(
                    None, fast.wait_ready, self.start_position)
                tm.event("info", "ffmpeg", f"First segments ready after "
                         f"{(time.monotonic() - started) * 1000:.0f} ms")
            else:
                await self._wait_until_playable(workdir, vmode == "reencode")
                write_master(workdir, self.audio, self.play_sub, self.media)
                if not self.transcoder.done:
                    side_tasks.append(asyncio.ensure_future(self._final_master(workdir)))

            local_ip = airplay.local_address_for(self.conf)
            if not local_ip:
                raise RuntimeError(f"no local network interface reaches {self.conf.address}")
            self.server = HLSServer(workdir, tm, self.hls_port)
            self.server.ondemand = fast
            self.stream_url = f"http://{local_ip}:{self.server.port}/master.m3u8"
            tm.event("info", "http", f"Serving {self.stream_url}")

            self._set_phase("connecting")
            side_tasks.append(asyncio.ensure_future(self._rtt_loop()))
            airplay.add_playback_listener(self._on_playback_info)
            self._set_phase("buffering", message="Sent stream to Apple TV, waiting for playback"
                            + (f" (from {self.start_position:.0f} s)" if self.start_position else ""))
            await self._play_until_done(self.start_position)
            self._end_stall()
            self._set_phase("finished", message="Playback finished")
            self._save_history(finished=True)
        except asyncio.CancelledError:
            self._end_stall()
            self._set_phase("stopped", message="Stopped")
            self._save_history()
            raise
        except Exception as e:  # noqa: BLE001 - shown in the UI
            self._end_stall()
            self.error = str(e) or type(e).__name__
            if "got error" in self.error and not self.playback["error"]:
                self.playback["error"] = self.error
            self._set_phase("failed", "error", f"Playback failed: {self.error}")
            self._save_history()
        finally:
            for t in (self._early_connect, self._remote_task):
                if t:
                    t.cancel()
            if self._early_connect and self._early_connect.done() and not self._early_connect.cancelled() \
                    and self._early_connect.exception() is None:
                self._early_connect.result().close()     # opened but never used
            airplay.remove_playback_listener(self._on_playback_info)
            logging.getLogger("pyatv").removeHandler(log_handler)
            if self.atv:
                self.atv.close()
            if self.server:
                self.server.stop()
            if self.transcoder:
                self.transcoder.stop()
            # One last sample so the charts show the end state.
            self._take_sample(workdir)
            for t in side_tasks:
                t.cancel()
            shutil.rmtree(workdir, ignore_errors=True)

    async def _play_until_done(self, position):
        """Play on the TV, with a MediaRemote connection for seeking.

        tvOS 26 ignores seek commands on the AirPlay play queue. Seeking and
        skipping go through MediaRemote instead (the Now Playing remote
        protocol, tunnelled over AirPlay with the same credentials), which
        moves the playhead in place in ~50 ms. If that connection can't be
        opened, a seek falls back to reconnecting and queueing the (already
        prepared) stream again at the new position - a short rebuffer.
        """
        if self._remote_task is None and not airplay.is_simulated(self.conf):
            self._remote_task = asyncio.ensure_future(self._connect_remote())
        try:
            while True:
                self.atv = await self._take_connection()
                self._play_task = asyncio.ensure_future(
                    self.atv.stream.play_url(self.stream_url, position=position))
                try:
                    await self._play_task
                except asyncio.CancelledError:
                    if self._reposition is None or not self._play_task.cancelled():
                        raise           # a real stop, not our restart for a seek
                finally:
                    self.atv.close()
                    self.atv = None
                if self._reposition is None:
                    return
                position, self._reposition = self._reposition, None
                self.telemetry.event("info", "app", f"Restarted playback at {position:.0f} s for seek")
        finally:
            if self._remote_task:
                self._remote_task.cancel()
            if self._remote:
                self._remote.close()
                self._remote = None

    async def _take_connection(self):
        """The connection opened during preparation (once), else a new one."""
        early, self._early_connect = self._early_connect, None
        if early is not None:
            try:
                return await early
            except Exception as e:  # noqa: BLE001 - e.g. the TV woke up meanwhile; try again
                self.telemetry.event("warn", "airplay", f"Early connection failed ({e}), reconnecting")
        return await self.devices.connect(self.conf)

    async def _connect_remote(self):
        try:
            self._remote = await self.devices.connect(self.conf)
            self.telemetry.event("info", "airplay", "Remote control connected (in-place seek and skip)")
        except Exception as e:  # noqa: BLE001 - seeking falls back to restarting
            self.telemetry.event("warn", "airplay", f"Remote control unavailable, seeking will "
                                 f"restart playback: {e}")

    async def _final_master(self, workdir):
        """Once ffmpeg is done, rewrite the master with its exact bandwidth."""
        while not self.transcoder.done:
            await asyncio.sleep(0.5)
        if not self.transcoder.failed:
            write_master(workdir, self.audio, self.play_sub, self.media)

    async def _wait_until_playable(self, workdir, reencoding):
        """A remux: return when it is complete (see WAIT_FULL_PREP). A
        re-encode: return once the start point plus READY_AHEAD_S is prepared,
        and let ffmpeg keep going in the background."""
        start = time.monotonic()
        tc = self.transcoder
        while True:
            if tc.done:
                await asyncio.get_running_loop().run_in_executor(None, tc.wait)
                if tc.failed:
                    raise RuntimeError("ffmpeg failed: " + " | ".join(tc.stderr_tail[-3:]))
                self.telemetry.event("info", "ffmpeg", "Stream fully prepared")
                return
            durations = read_segment_durations(workdir)
            need = min(self.start_position + READY_AHEAD_S, max(0.0, self.media.duration - 1))
            ready = ((workdir / "ffmaster.m3u8").exists()
                     and len(durations) >= 3 and sum(durations) >= need)
            if ready and (reencoding or not WAIT_FULL_PREP or time.monotonic() - start > 20):
                self.telemetry.event("info", "ffmpeg", f"Starting playback at "
                                     f"{tc.progress:.0%} prepared; continuing in background")
                return
            await asyncio.sleep(0.3)

    # ---- Apple TV reports -------------------------------------------------

    def _on_playback_info(self, info):
        pb = self.playback
        now = time.time()
        pb["last_report_at"] = now
        if "_http_status" in info:
            # The TV answered the status poll with an HTTP error: normal for a
            # few seconds while its player starts, a problem once playing.
            status = info["_http_status"]
            if self._started_playing:
                self.telemetry.event("warn", "airplay",
                                     f"Apple TV answered playback status with HTTP {status}")
            elif not self._logged_startup_status:
                self._logged_startup_status = True
                self.telemetry.event("info", "airplay", f"Apple TV is still starting its player "
                                     f"(playback status HTTP {status}) - waiting")
            return
        if not self._logged_keys and info:
            self._logged_keys = True
            extra = sorted(set(info) - set(PLAYBACK_REPORT_KEYS))
            self.telemetry.event("info", "airplay", "Apple TV playback report keys: "
                                 + ", ".join(sorted(info)) + (f" (extra: {extra})" if extra else ""))
        if "error" in info:
            err = info["error"]
            if isinstance(err, dict):
                pb["error"] = (f"{err.get('code', '?')} ({err.get('domain', 'unknown domain')})"
                               + (f": {err['localizedDescription']}"
                                  if err.get("localizedDescription") else ""))
            else:
                pb["error"] = str(err)
            self.telemetry.event("error", "airplay", f"Apple TV error {pb['error']}")
            return
        if info.get("duration") is None:
            return

        position = float(info.get("position") or 0)
        rate = float(info.get("rate") or 0)
        if self._stale_after_seek(info, position, now):
            return
        # While ffmpeg still prepares, the TV only knows the part listed so far
        # (a growing playlist), so its duration is short. The file's own
        # duration is the real one, for the app and for the end-of-media check.
        tv_duration = float(info["duration"])
        duration = self.media.duration or tv_duration
        self._check_tv_duration(tv_duration, now)
        pb.update(position=position, duration=duration, rate=rate,
                  ready_to_play=info.get("readyToPlay"),
                  buffer_empty=info.get("playbackBufferEmpty"),
                  buffer_full=info.get("playbackBufferFull"),
                  likely_to_keep_up=info.get("playbackLikelyToKeepUp"))
        ahead = None
        for r in info.get("loadedTimeRanges") or []:
            start, end = float(r.get("start", 0)), float(r.get("start", 0)) + float(r.get("duration", 0))
            if start - 1 <= position <= end:
                ahead = max(ahead or 0, end - position)
        # Once the TV reports loaded ranges, "nothing around the playhead" means 0 s.
        if ahead is None and info.get("loadedTimeRanges") is not None:
            ahead = 0.0
        pb["buffered_ahead_s"] = round(ahead, 1) if ahead is not None else None

        # A position stuck at the very end is the media ending, not a stall.
        at_end = duration > 0 and position >= duration - 1
        advancing = (rate > 0 and self._last_position is not None
                     and position - self._last_position >= 0.05)
        if (rate > 0 and not at_end and self._last_position is not None
                and abs(position - self._last_position) < 0.05):
            self._frozen_reports += 1
        else:
            self._frozen_reports = 0
        self._last_position = position

        # After a jump tvOS can keep saying "buffer empty" for a minute while it
        # plays on with plenty loaded. The playhead moving is what counts.
        if pb["buffer_empty"] and advancing and (pb["buffered_ahead_s"] or 0) >= 2:
            pb["buffer_empty"] = False
            if not self._stale_empty_logged:
                self._stale_empty_logged = True
                self.telemetry.event("info", "airplay",
                                     f"Apple TV says its buffer is empty but plays on with "
                                     f"{pb['buffered_ahead_s']:.0f} s loaded; ignoring that flag")

        if rate == 0 and not pb["buffer_empty"] and pb["likely_to_keep_up"] is not False:
            if self._seeking and self._paused_at_seek:
                self._seeking = False           # landed, and stays paused as it was
            elif (self._seeking and self._started_playing and pb["ready_to_play"]
                  and self.last_seek_at is not None and now - self.last_seek_at >= SEEK_SETTLE_S):
                # Landed with data to play, but the player didn't resume: it is
                # paused, not buffering (waiting for "playing" here never ended).
                self._seeking = False
            if self._started_playing and not self._seeking:
                self._end_stall()
                self._set_phase("paused", message="Paused" + ("" if self.user_paused else " on the TV"))
            else:
                self._set_phase("buffering")    # still loading (initially or after a seek)
        elif rate == 0 or pb["buffer_empty"] or self._frozen_reports >= STALL_REPORTS:
            # Right after play/resume the player waits a moment for its buffer
            # (AVPlayer: "waiting to play" with 50 s loaded): start-up, not a stall.
            # Resumed on the TV's own remote: the wait is the first sign of it.
            starting = self._grace_until is not None and now < self._grace_until
            if self.phase == "paused" and not starting:
                self._grace_until, starting = now + START_GRACE_S, True
            if self._seeking:
                self._set_phase("buffering", message="Buffering after seek")
            elif starting:
                self._set_phase("buffering")
            elif self._started_playing:
                if self.phase != "stalled":
                    pb["stall_count"] += 1
                    self._stall_began = now
                    self._set_phase("stalled", "warn",
                                    f"Playback stalled at {position:.0f} s "
                                    f"(TV buffer {pb['buffered_ahead_s'] or 0:.0f} s)")
            else:
                self._set_phase("buffering")
        else:
            if not self._started_playing:
                self.time_to_play_s = round(now - self.started_at, 2)
            elif self._seeking and self.last_seek_at is not None:
                self.seek_to_play_s = round(now - self.last_seek_at, 2)
            if advancing:
                self._grace_until = None        # the playhead moves: start-up is over
            elif self._seeking or self.phase in ("buffering", "paused"):
                # Rate 1 but not moved yet: a wait may still follow.
                self._grace_until = now + START_GRACE_S
            self._end_stall()
            self._started_playing = True
            self._seeking = False
            self.user_paused = False
            self._set_phase("playing")
        if now - self._history_saved_at >= HISTORY_EVERY_S:
            self._save_history()

    def _stale_after_seek(self, info, position, now):
        """A report from before the latest seek took effect: the player still at
        (or playing on from) the old spot. It says nothing about the new one -
        "playing" there must not end the seek, or the rebuffer at the new spot
        that follows would count as a stall. This Mac's player says so itself
        (the seek command not acknowledged yet); for an Apple TV the position
        tells: nearer where it was than where it goes. Not after SEEK_STALE_S,
        in case the jump landed somewhere else entirely."""
        if not self._seeking or self.last_seek_at is None or now - self.last_seek_at > SEEK_STALE_S:
            return False
        if info.get("_seek_pending"):
            return True
        target, origin = self._seek_target, self._seek_origin
        if target is None or abs(position - target) <= SEEK_NEAR_S:
            return False
        return origin is None or abs(position - origin) < abs(position - target)

    def _check_tv_duration(self, tv_duration, now):
        """Once preparation is done the TV should pick up the full length within
        a few playlist reloads; if it doesn't, playback would end early."""
        tc = self.transcoder
        if not (tc and tc.done and not tc.failed and self.media.duration):
            return
        if tv_duration >= self.media.duration - 30:
            self._short_since = None
            return
        if self._short_since is None:
            self._short_since = now
        elif self._short_since is not False and now - self._short_since > 20:
            self._short_since = False   # warn once
            self.telemetry.event("warn", "airplay",
                                 f"Apple TV still sees a {tv_duration:.0f} s stream, 20 s after "
                                 f"the whole {self.media.duration:.0f} s was prepared - it may "
                                 "have stopped reloading the playlist and will stop early")

    async def _prepare_subtitles(self):
        """The subtitle track ffmpeg should use: picture subtitles recognised
        as text, or a text track extracted to a file when it is delayed."""
        sub = self.sub
        if sub is None:
            return None
        loop = asyncio.get_running_loop()
        try:
            if sub.via_ocr:
                # One reading per track: picking the subtitle in the ready view
                # may already have started it, so follow that job (and its
                # progress) rather than queue a second run behind its lock.
                job = ocrsubs.ensure(self.media, sub)   # quick pass, then the accurate one
                if ocrsubs.cached(self.media, sub) is None and job is not None:
                    self.telemetry.event("info", "app", "Reading the picture subtitles as text "
                                         "(first time for this file, ~10 s)")
                    try:
                        while not job.done.is_set():
                            self._sub_progress = job.progress
                            await asyncio.sleep(0.2)
                    finally:
                        self._sub_progress = None
                    if job.error:
                        raise ocrsubs.OCRError(job.error)
                path = ocrsubs.cached(self.media, sub)
                if path is None:
                    raise ocrsubs.OCRError("no text was made")
            elif self.subtitle_delay and not sub.file and not sub.is_bitmap:
                path = await loop.run_in_executor(None, extract_text_subtitles, self.media, sub)
            else:
                return sub
        except Exception as e:  # noqa: BLE001 - play without subtitles rather than fail
            self.telemetry.event("warn", "app", f"Subtitles unavailable: {e}")
            return None
        return Track("sub", 0, "webvtt", lang=sub.lang, title=sub.title, forced=sub.forced, file=path)

    def _save_history(self, finished=False):
        """Remember where we are so the app can offer to resume later."""
        pos = self.playback["position"]
        simulated = airplay.is_simulated(self.conf) and not airplay.is_local(self.conf)
        if simulated or (pos is None and not finished):
            return
        self._history_saved_at = time.time()
        try:
            history.record(
                self.media.path, position=pos or 0, duration=self.media.duration,
                audio=self.media.audio.index(self.audio) + 1,
                subtitle=self.media.subs.index(self.sub) + 1 if self.sub else 0,
                device_id=self.conf.identifier, stereo=self.stereo, finished=finished,
                subtitle_delay=self.subtitle_delay)
        except (OSError, ValueError) as e:
            self.telemetry.event("warn", "app", f"Could not save playback position: {e}")

    def _end_stall(self):
        if self._stall_began is not None:
            took = time.time() - self._stall_began
            self.playback["stalled_s_total"] = round(self.playback["stalled_s_total"] + took, 1)
            self.telemetry.event("info", "app", f"Recovered after {took:.1f} s stall")
            self._stall_began = None

    # ---- periodic measurements -------------------------------------------

    def _take_sample(self, workdir):
        tc = self.transcoder
        pb = self.playback
        prepared = tc.prepared_s if tc else 0.0
        if tc and tc.done and not tc.failed:
            prepared = self.media.duration
        own = getattr(tc, "bitrate", None)      # fast start knows it from the file
        self.stream_bitrate = own or directory_bitrate(workdir, prepared) or self.stream_bitrate
        headroom = (round(prepared - pb["position"], 1)
                    if pb["position"] is not None and prepared else None)
        # Only report latency in the second it was measured: at the basic level
        # the probe runs every 5 s, and a gap must not look like a timeout.
        probed, self._fresh_rtt = self._fresh_rtt, None
        self.telemetry.sample({
            "rtt_ms": probed[0] if probed else None,
            "rtt_timeout": bool(probed) and probed[0] is None,
            "ff_speed": tc.speed if tc and not tc.done else None,
            "ff_prepared_s": round(prepared, 1),
            "tv_position": pb["position"],
            "tv_buffered_ahead_s": pb["buffered_ahead_s"],
            "tv_rate": pb["rate"],
            "tv_buffer_empty": pb["buffer_empty"],
            "headroom_s": headroom,
        })

    async def _sample_loop(self, workdir):
        loop = asyncio.get_running_loop()
        next_tick = loop.time()
        while True:
            next_tick += 1
            await asyncio.sleep(max(0, next_tick - loop.time()))
            try:
                await loop.run_in_executor(None, self._take_sample, workdir)
            except FileNotFoundError:
                pass

    async def _tcp_connect_ms(self):
        """TCP connect time to the TV's AirPlay port in ms, None on timeout/error."""
        loop = asyncio.get_running_loop()
        t0 = loop.time()
        try:
            _, writer = await asyncio.wait_for(
                asyncio.open_connection(str(self.conf.address), airplay.airplay_port(self.conf)),
                1.0)
        except (OSError, asyncio.TimeoutError):
            return None
        writer.close()
        return (loop.time() - t0) * 1000

    async def _rtt_loop(self):
        """Latency to the TV: TCP connect time to its AirPlay port, or the
        device's own probe_rtt() coroutine if it has one (the simulated Apple TV
        uses that to report profile-dependent latency/loss). Runs every 5 s at
        the basic telemetry level and every second at detailed."""
        probe = getattr(self.conf, "probe_rtt", None) or self._tcp_connect_ms
        loop = asyncio.get_running_loop()
        was_down = False
        while True:
            t0 = loop.time()
            rtt = await probe()
            self._fresh_rtt = (round(rtt, 1) if rtt is not None else None,)
            if rtt is not None:
                self.telemetry.rtt(round(rtt, 1))
                if was_down:
                    self.telemetry.event("info", "network", "Apple TV reachable again")
                was_down = False
            else:
                self.telemetry.rtt(None)
                if not was_down:
                    self.telemetry.event("warn", "network",
                                         "Latency probe to Apple TV timed out")
                was_down = True
            # Sleep in short steps, re-reading the level, so switching to
            # "detailed" (Diagnostics window opened) takes effect right away.
            while True:
                interval = RTT_INTERVALS.get(self.telemetry_level, RTT_INTERVALS["basic"])
                remaining = interval - (loop.time() - t0)
                if remaining <= 0:
                    break
                await asyncio.sleep(min(0.25, remaining))

    # ---- controls ---------------------------------------------------------

    async def pause(self):
        self.user_paused = True
        await airplay.send_command("/rate?value=0.000000")

    async def resume(self):
        self.user_paused = False
        self._grace_until = time.time() + START_GRACE_S
        await airplay.send_command("/rate?value=1.000000")

    def _begin_seek(self, target):
        """The rebuffer that follows a seek is expected, not a stall."""
        if not self._seeking:
            self._paused_at_seek = self.phase == "paused"
        self._seeking = True
        self.last_seek_at = time.time()
        self._seek_origin = self.playback["position"]
        self._seek_target = target
        self._frozen_reports = 0
        self._last_position = None      # movement is measured from the new spot

    async def seek(self, position):
        position = max(0.0, float(position))
        if self.media.duration:
            position = min(position, self.media.duration - 1)
        self._begin_seek(position)
        if airplay.is_simulated(self.conf):
            await airplay.send_command(f"/scrub?position={position:.3f}")
            # Where it is going, so a quick second jump starts from there.
            self.playback["position"] = position
            return
        if self._remote is not None:
            try:
                await self._remote.remote_control.set_position(position)
                self.playback["position"] = position
                return
            except Exception as e:  # noqa: BLE001
                self.telemetry.event("warn", "airplay", f"In-place seek failed ({e}); restarting")
        if self._reposition is not None:
            # A restart for an earlier seek is still under way: just retarget it.
            self._reposition = position
            self.playback.update(position=position, buffered_ahead_s=None)
            return
        if self._play_task is None or self._play_task.done():
            raise RuntimeError("nothing is playing")
        self._reposition = position
        self.playback.update(position=position, buffered_ahead_s=None)
        self._play_task.cancel()        # _play_until_done reconnects at `position`

    async def volume(self, step=None, level=None):
        """The TV's volume, through the Apple TV (which works it over HDMI-CEC
        or IR, as set up in its Remotes and Devices settings): `step` "up" /
        "down" one notch, or `level` 0-100 where the device supports it."""
        if airplay.is_local(self.conf):
            raise RuntimeError("This Mac plays through the Mac's own volume")
        if airplay.is_simulated(self.conf):
            raise RuntimeError("a simulated device has no volume")
        rc = self._remote
        if rc is None:
            raise RuntimeError("the Apple TV's remote control isn't connected yet")
        if level is not None:
            await rc.audio.set_volume(max(0.0, min(100.0, float(level))))
        elif step in ("up", "down"):
            await (rc.audio.volume_up() if step == "up" else rc.audio.volume_down())
        else:
            raise ValueError(f"volume needs step up/down or a level, not {step!r}")

    def volume_json(self):
        """{"supported", "level"}: can the TV's volume be changed from here, and
        its level when the device reports one (an Apple TV driving a TV over
        CEC usually doesn't)."""
        rc = self._remote
        if rc is None or airplay.is_simulated(self.conf) or airplay.is_local(self.conf):
            return {"supported": False, "level": None}
        try:
            from pyatv.const import FeatureName, FeatureState
            ok = rc.features.in_state(FeatureState.Available, FeatureName.VolumeUp)
            has_level = rc.features.in_state(FeatureState.Available, FeatureName.Volume)
            return {"supported": bool(ok),
                    "level": round(rc.audio.volume, 1) if has_level else None}
        except Exception:  # noqa: BLE001 - a feature query is never worth failing the state
            return {"supported": False, "level": None}

    async def skip(self, seconds):
        """Jump relative to the current position, e.g. +10 / -10 s."""
        seconds = float(seconds)
        if self._remote is not None and not airplay.is_simulated(self.conf):
            try:
                rc = self._remote.remote_control
                pos = self.playback["position"]
                self._begin_seek(None if pos is None else max(0.0, pos + seconds))
                await (rc.skip_forward(seconds) if seconds >= 0 else rc.skip_backward(-seconds))
                if self.playback["position"] is not None:
                    self.playback["position"] = max(0.0, self.playback["position"] + seconds)
                return
            except Exception as e:  # noqa: BLE001
                self.telemetry.event("warn", "airplay", f"Skip failed ({e}); seeking instead")
        if self.playback["position"] is None:
            raise RuntimeError("nothing is playing")
        await self.seek(self.playback["position"] + seconds)

    # ---- reporting --------------------------------------------------------

    def prep_json(self):
        tc = self.transcoder
        if tc is None:
            # Before ffmpeg starts: maybe reading picture subtitles as text.
            reading = self._sub_progress is not None
            return {"progress": round(self._sub_progress, 3) if reading else 0.0, "speed": None,
                    "prepared_s": 0.0, "done": False, "on_demand": False, "fast_start": None,
                    "stage": "subtitles" if reading else "video", "error": None}
        failed = tc.failed
        return {"progress": round(tc.progress, 4), "speed": tc.speed,
                "prepared_s": round(self.media.duration if tc.done and not failed
                                    else tc.prepared_s, 1),
                "done": tc.done and not failed, "stage": "video",
                "on_demand": bool(getattr(tc, "on_demand", False)),
                "fast_start": tc.wait_stats() if hasattr(tc, "wait_stats") else None,
                "error": " | ".join(tc.stderr_tail[-3:]) if failed else None}

    def _ocr_text_quality(self):
        """"fast" / "accurate" recognition for subtitles read as text, else None."""
        if not (self.sub and self.sub.via_ocr and self.play_sub and self.play_sub.file):
            return None
        return "fast" if str(self.play_sub.file).endswith(".fast.vtt") else "accurate"

    def to_json(self):
        vmode, reason = self.media.video_plan(self.sub)
        amode, aout, _ = audio_plan(self.audio, self.stereo)
        hevc = self.media.video_codec == "hevc"
        durations = read_segment_durations(self.server.directory) if self.server else []
        return {
            "id": self.id,
            "started_at": self.started_at,
            "file": {"path": str(self.media.path), "name": self.media.path.name,
                     "size_bytes": self.media.size_bytes, "duration_s": self.media.duration,
                     "name_info": names.parse(self.media.path)},
            "video": {"codec": self.media.video_codec, "width": self.media.video.get("width"),
                      "height": self.media.video.get("height"), "mode": vmode, "reason": reason,
                      "out_codec": self.media.video_codec if vmode == "copy"
                      else ("hevc" if hevc else "h264")},
            "audio": {"id": self.media.audio.index(self.audio) + 1,
                      "label": self.audio.label(), "codec": self.audio.codec,
                      "channels": self.audio.channels, "mode": amode, "out_codec": aout},
            "subtitle": ({"id": self.media.subs.index(self.sub) + 1,
                          "label": self.sub.label(), "codec": self.sub.codec,
                          "mode": "burn" if self.sub.burns_in else "ocr" if self.sub.via_ocr
                          else "soft", "delay": self.subtitle_delay,
                          # False when preparing them failed: playing without.
                          "in_stream": self.play_sub is not None,
                          "text": self._ocr_text_quality()}
                         if self.sub else None),
            "timing": {"start_s": self.time_to_play_s, "seek_s": self.seek_to_play_s},
            "stereo": self.stereo,
            "device": {"id": self.conf.identifier, "name": self.conf.name,
                       "address": str(self.conf.address),
                       "model": airplay.device_model(self.conf)},
            "stream_url": self.stream_url,
            "stream_bitrate_bps": self.stream_bitrate,
            "segment_duration_s": SEGMENT_SECONDS,
            "segments_ready": getattr(self.transcoder, "segments_ready", None) or len(durations),
            # Estimate: copied video is cut at keyframes, so real segments vary around 6 s.
            "segments_total": getattr(self.transcoder, "count", None)
            or max(1, math.ceil(self.media.duration / SEGMENT_SECONDS)),
            "start_position": self.start_position,
            "last_seek_at": self.last_seek_at,
            "volume": self.volume_json(),
            "error": self.error,
        }

    def state_json(self):
        session = self.to_json()
        prep = self.prep_json()
        network = self.telemetry.network_summary()
        playback = dict(self.playback)
        diagnosis = diagnose(self.phase, session, prep, playback, network, self.telemetry)
        if self.phase == "failed" and self.error:
            # Whatever the rules conclude, the actual error is the first thing to show.
            diagnosis["details"].insert(0, f"Error: {self.error}")
        return {
            "phase": self.phase,
            "session": session,
            "prep": prep,
            "playback": playback,
            "network": network,
            "diagnosis": diagnosis,
        }
