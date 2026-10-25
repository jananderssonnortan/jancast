"""Session._on_playback_info: the phase state machine driven by Apple TV reports.

The Session is constructed with stub media/conf and never started (no ffmpeg,
no network, no device).
"""

import asyncio
import unittest
from unittest import mock

from helpers import StubConf, TempDirMixin, audio_stream, make_media, sub_stream, video_stream
from jancast import history
from jancast import session as session_mod
from jancast.session import HISTORY_EVERY_S, STALL_REPORTS, Session
from jancast.telemetry import Telemetry


def report(position, rate=1.0, duration=600.0, empty=False, full=False, likely=True,
           ranges=None, **extra):
    r = {"position": position, "rate": rate, "duration": duration, "readyToPlay": True,
         "playbackBufferEmpty": empty, "playbackBufferFull": full,
         "playbackLikelyToKeepUp": likely}
    if ranges is not None:
        r["loadedTimeRanges"] = ranges
    r.update(extra)
    return r


class PlaybackStateTest(TempDirMixin, unittest.TestCase):
    def setUp(self):
        self.tm = Telemetry()
        media = make_media(self.make_tempdir(), [video_stream(0), audio_stream(1)],
                           duration=600.0)
        self.s = Session(self.tm, None, media, media.audio[0], None, StubConf())
        self.s.phase = "buffering"            # what _run sets right before play_url
        self.clock = 1000.0
        patcher = mock.patch.object(session_mod.time, "time", lambda: self.clock)
        patcher.start()
        self.addCleanup(patcher.stop)

    def feed(self, *reports, step=1.0):
        for r in reports:
            self.clock += step
            self.s._on_playback_info(r)
        return self.s.phase

    def messages(self, level=None):
        return [e["message"] for e in self.tm.events if level is None or e["level"] == level]

    def play_to(self, start=0.0, n=3):
        return self.feed(*(report(start + i) for i in range(n)))

    def test_report_without_duration_keeps_buffering(self):
        self.feed({"readyToPlay": False}, {})
        self.assertEqual(self.s.phase, "buffering")
        self.assertEqual(self.s.playback["last_report_at"], self.clock)
        self.assertIsNone(self.s.playback["position"])
        keys = [m for m in self.messages() if m.startswith("Apple TV playback report keys")]
        self.assertEqual(len(keys), 1)                      # logged once only

    def test_unknown_keys_logged_as_extra(self):
        self.feed(report(0, rate=0, empty=True, uuid="x", stallCount=0))
        msg = next(m for m in self.messages() if m.startswith("Apple TV playback report keys"))
        self.assertIn("(extra: ['stallCount', 'uuid'])", msg)

    def test_initial_buffer_empty_is_buffering_not_stall(self):
        self.feed(report(0, rate=0, empty=True, likely=False),
                  report(0, rate=1, empty=True, likely=False))
        self.assertEqual(self.s.phase, "buffering")
        self.assertEqual(self.s.playback["stall_count"], 0)

    def test_initial_rate_zero_before_playback_is_not_paused(self):
        """Regression: the first report usually has rate 0 while the player
        loads; that is buffering, not "Paused on the TV"."""
        self.feed(report(0, rate=0, empty=False, likely=None))
        self.assertEqual(self.s.phase, "buffering")

    def test_playing(self):
        self.assertEqual(self.play_to(), "playing")
        pb = self.s.playback
        self.assertEqual((pb["position"], pb["duration"], pb["rate"]), (2.0, 600.0, 1.0))
        self.assertIs(pb["ready_to_play"], True)
        self.assertIs(pb["buffer_empty"], False)
        self.assertIs(pb["likely_to_keep_up"], True)
        self.assertIn("Phase: playing", self.messages())

    def test_user_pause_vs_tv_pause(self):
        self.play_to()
        self.s.user_paused = True                 # what Session.pause() sets
        self.assertEqual(self.feed(report(3, rate=0)), "paused")
        self.assertEqual(self.messages()[-1], "Paused")
        self.assertEqual(self.feed(report(3), report(4)), "playing")
        self.assertFalse(self.s.user_paused)
        self.assertEqual(self.feed(report(4, rate=0)), "paused")
        self.assertEqual(self.messages()[-1], "Paused on the TV")
        self.assertEqual(self.s.playback["stall_count"], 0)

    def test_frozen_position_while_paused_is_not_a_stall(self):
        self.play_to()
        self.feed(*(report(3, rate=0) for _ in range(10)))
        self.assertEqual(self.s.phase, "paused")

    def test_stall_via_buffer_empty_and_recovery(self):
        self.play_to(10)
        self.feed(report(12, rate=0, empty=True, likely=False, ranges=[]))
        self.assertEqual(self.s.phase, "stalled")
        pb = self.s.playback
        self.assertEqual(pb["stall_count"], 1)
        self.assertIn("Playback stalled at 12 s (TV buffer 0 s)", self.messages("warn"))
        stalled_at = self.clock
        self.feed(*(report(12, rate=0, empty=True, likely=False) for _ in range(4)))
        self.assertEqual(pb["stall_count"], 1)              # same stall
        self.feed(report(12, likely=True), step=2.5)        # 4 + 2.5 = 6.5 s later
        self.assertEqual(self.s.phase, "playing")
        self.assertEqual(pb["stalled_s_total"], round(self.clock - stalled_at, 1))
        self.assertEqual(pb["stalled_s_total"], 6.5)
        self.assertIn("Recovered after 6.5 s stall", self.messages("info"))
        # Second stall accumulates.
        self.feed(report(13, rate=0, empty=True), report(13), step=2.0)
        self.assertEqual((pb["stall_count"], pb["stalled_s_total"]), (2, 8.5))

    def test_stall_via_frozen_position(self):
        self.play_to(20)                                      # last position 22
        for i in range(STALL_REPORTS):
            self.assertEqual(self.feed(report(22.0, rate=1.0)), "playing" if i < STALL_REPORTS - 1
                             else "stalled", f"after {i + 1} frozen report(s)")
        self.assertEqual(self.s.playback["stall_count"], 1)
        self.assertEqual(self.feed(report(22.5)), "playing")
        self.assertEqual(self.s.playback["stalled_s_total"], 1.0)

    def test_tiny_position_jitter_counts_as_frozen(self):
        self.play_to(20)
        self.feed(*(report(22.0 + 0.01 * i) for i in range(1, STALL_REPORTS + 1)))
        self.assertEqual(self.s.phase, "stalled")

    def test_rate_zero_with_likely_false_is_stall(self):
        self.play_to()
        self.assertEqual(self.feed(report(3, rate=0, empty=False, likely=False)), "stalled")

    def test_pause_during_stall_ends_it(self):
        self.play_to()
        self.feed(report(3, rate=0, empty=True))
        self.s.user_paused = True
        self.assertEqual(self.feed(report(3, rate=0, empty=False), step=3.0), "paused")
        self.assertEqual(self.s.playback["stalled_s_total"], 3.0)
        self.assertIsNone(self.s._stall_began)

    def test_loaded_time_ranges(self):
        cases = [
            ([{"start": 0, "duration": 30}], 10, 20.0),
            ([{"start": 0, "duration": 5}, {"start": 8, "duration": 40.04}], 10, 38.0),
            ([{"start": 10.5, "duration": 20}], 10, 20.5),       # starts just after position
            ([{"start": 50, "duration": 20}], 10, 0.0),           # nothing around the position
            ([], 10, 0.0),
            (None, 10, None),
        ]
        for ranges, position, expected in cases:
            with self.subTest(ranges=ranges):
                self.feed(report(position, ranges=ranges))
                self.assertEqual(self.s.playback["buffered_ahead_s"], expected)

    def test_error_report(self):
        self.play_to()
        self.feed({"error": {"code": -11828, "domain": "AVFoundationErrorDomain",
                             "localizedDescription": "Cannot Open"}})
        self.assertEqual(self.s.playback["error"],
                         "-11828 (AVFoundationErrorDomain): Cannot Open")
        self.assertIn("Apple TV error -11828 (AVFoundationErrorDomain): Cannot Open",
                      self.messages("error"))
        self.feed({"error": {}})
        self.assertEqual(self.s.playback["error"], "? (unknown domain)")

    def test_end_of_media_is_not_a_stall(self):
        """Regression: a position stuck at the end while the TV still reports
        rate 1.0 is the media ending, not a stall."""
        self.play_to(597)
        self.feed(*(report(600.0, duration=600.0) for _ in range(STALL_REPORTS + 1)))
        self.assertEqual(self.s.playback["stall_count"], 0)

    def seek(self, position):
        """Seek on a simulated device: a /scrub command, playback keeps running."""
        self.s.conf = StubConf(simulated=True)
        with mock.patch.object(session_mod.airplay, "send_command", mock.AsyncMock()) as send:
            asyncio.run(self.s.seek(position))
        send.assert_awaited_once_with(f"/scrub?position={position:.3f}")

    def test_rebuffer_after_seek_is_not_a_stall(self):
        self.play_to(100)
        self.seek(300.0)
        self.assertIsNotNone(self.s.to_json()["last_seek_at"])
        self.assertIsNone(self.s._reposition)               # no restart on the simulator
        self.assertEqual(self.feed(report(300, rate=0, empty=True, likely=False)), "buffering")
        self.assertEqual(self.feed(report(300, rate=0, empty=False)), "buffering")
        self.assertEqual(self.feed(report(301), report(302)), "playing")
        self.assertEqual(self.s.playback["stall_count"], 0)
        # A real stall after the seek has settled still counts.
        self.feed(report(302, rate=0, empty=True, likely=False))
        self.assertEqual(self.s.phase, "stalled")
        self.assertEqual(self.s.playback["stall_count"], 1)

    def test_seek_that_lands_paused_is_paused_not_buffering(self):
        # This Mac: after a jump the player sat paused with a full buffer, and
        # the session said "buffering" forever.
        self.play_to(100)
        self.s._seeking = True
        self.s.last_seek_at = self.clock
        self.assertEqual(self.feed(report(5315, rate=0, full=True)), "buffering")     # just landed
        self.assertEqual(self.feed(report(5315, rate=0, full=True), step=4.0), "paused")
        self.assertFalse(self.s._seeking)
        self.assertEqual(self.feed(report(5316), report(5317)), "playing")

    def test_seek_while_paused_ends_paused(self):
        self.play_to(100)
        self.s.user_paused = True
        self.assertEqual(self.feed(report(103, rate=0)), "paused")
        self.seek(300.0)
        # Rebuffering at the new spot, then loaded but (still) paused: not "buffering" forever.
        self.assertEqual(self.feed(report(300, rate=0, empty=True, likely=False)), "buffering")
        self.assertEqual(self.feed(report(300, rate=0, full=True)), "paused")
        self.assertEqual(self.feed(report(300, rate=0, full=True)), "paused")
        self.assertEqual(self.s.playback["stall_count"], 0)
        # Resuming afterwards plays normally.
        self.assertEqual(self.feed(report(301), report(302)), "playing")

    def resume(self):
        self.s.conf = StubConf(simulated=True)
        with mock.patch.object(session_mod.airplay, "send_command", mock.AsyncMock()) as send:
            asyncio.run(self.s.resume())
        send.assert_awaited_once_with("/rate?value=1.000000")

    def pause_at(self, position=103):
        self.play_to(position - 3)
        self.s.user_paused = True
        self.assertEqual(self.feed(report(position, rate=0)), "paused")

    def test_wait_right_after_resume_is_not_a_stall(self):
        """Regression: AVPlayer (This Mac) says "waiting" for a moment after
        play(), with 50 s loaded; every resume logged a stall."""
        loaded = [{"start": 0, "duration": 153}]
        self.pause_at(103)
        self.resume()
        self.assertEqual(self.feed(report(103, rate=0, empty=True, ranges=loaded)), "buffering")
        self.assertEqual(self.feed(report(103, rate=0, empty=True, ranges=loaded)), "buffering")
        self.assertEqual(self.feed(report(104, ranges=loaded)), "playing")
        self.assertEqual(self.s.playback["stall_count"], 0)
        self.assertFalse(any("stalled" in m for m in self.messages("warn")))
        # Once it plays, a wait is a stall again.
        self.assertEqual(self.feed(report(105, rate=0, empty=True, ranges=[])), "stalled")
        self.assertEqual(self.s.playback["stall_count"], 1)

    def test_resume_on_the_tv_remote_is_not_a_stall(self):
        self.pause_at(103)                            # no Session.resume(): the TV's own remote
        self.assertEqual(self.feed(report(103, rate=0, empty=True)), "buffering")
        self.assertEqual(self.feed(report(103), report(104)), "playing")
        self.assertEqual(self.s.playback["stall_count"], 0)

    def test_rate_one_before_the_wait_after_resume(self):
        """Rate 1 for a report, playhead not moved yet, then the wait: still start-up."""
        self.pause_at(103)
        self.resume()
        self.assertEqual(self.feed(report(103)), "playing")
        self.assertEqual(self.feed(report(103, rate=0, empty=True)), "buffering")
        self.assertEqual(self.feed(report(104)), "playing")
        self.assertEqual(self.s.playback["stall_count"], 0)

    def test_long_wait_after_resume_is_a_stall(self):
        self.pause_at(103)
        self.resume()
        waits = [report(103, rate=0, empty=True, ranges=[])
                 for _ in range(int(session_mod.START_GRACE_S) + 1)]
        self.assertEqual(self.feed(*waits), "stalled")
        self.assertEqual(self.s.playback["stall_count"], 1)
        self.assertEqual(self.feed(report(104)), "playing")

    def test_stale_report_from_before_a_jump_does_not_end_it(self):
        """Regression: a report made before the jump took effect (old spot,
        still playing) ended the seek, so the rebuffer at the new spot counted
        as a stall (This Mac, far filmstrip jumps)."""
        self.play_to(100)
        self.seek(500.0)
        self.assertEqual(self.s.playback["position"], 500.0)
        self.assertEqual(self.feed(report(103)), "playing")     # stale: ignored
        self.assertTrue(self.s._seeking)
        self.assertEqual(self.s.playback["position"], 500.0)
        self.assertEqual(self.feed(report(500, rate=0, empty=True, ranges=[])), "buffering")
        self.assertEqual(self.feed(report(500, rate=0, empty=True, ranges=[])), "buffering")
        self.assertIn("Buffering after seek", self.messages())
        self.assertEqual(self.feed(report(500), report(501)), "playing")
        self.assertFalse(self.s._seeking)
        self.assertEqual(self.s.playback["stall_count"], 0)
        # A real stall after the jump has settled still counts.
        self.assertEqual(self.feed(report(502, rate=0, empty=True, ranges=[])), "stalled")

    def test_landing_a_little_before_the_target_ends_the_seek(self):
        """An Apple TV may land on a keyframe before the target: nearer the
        target than the old spot counts as there."""
        self.play_to(100)
        self.seek(400.0)
        self.assertEqual(self.feed(report(395), report(396)), "playing")
        self.assertFalse(self.s._seeking)

    def test_stale_reports_only_ignored_for_a_while(self):
        self.play_to(100)
        self.seek(400.0)
        self.feed(report(103))
        self.assertTrue(self.s._seeking)
        self.clock += session_mod.SEEK_STALE_S
        self.assertEqual(self.feed(report(110), report(111)), "playing")     # landed elsewhere
        self.assertFalse(self.s._seeking)

    def test_seek_pending_report_from_this_mac_is_ignored(self):
        """This Mac marks reports made before it applied the seek, even when
        the old spot is close to the target."""
        self.play_to(100)
        self.seek(104.0)
        self.assertEqual(self.feed(report(102.5, _seek_pending=True)), "playing")
        self.assertTrue(self.s._seeking)
        self.assertEqual(self.feed(report(104, rate=0, empty=True)), "buffering")
        self.assertEqual(self.feed(report(104), report(105)), "playing")
        self.assertEqual(self.s.playback["stall_count"], 0)

    def test_stale_paused_report_after_a_jump_while_paused(self):
        self.pause_at(103)
        self.seek(450.0)
        self.assertEqual(self.feed(report(103, rate=0)), "paused")          # stale: ignored
        self.assertTrue(self.s._seeking)
        self.assertEqual(self.feed(report(450, rate=0, empty=True, ranges=[])), "buffering")
        self.assertEqual(self.feed(report(450, rate=0, full=True)), "paused")
        self.assertEqual(self.s.playback["stall_count"], 0)

    def test_seek_on_real_device_restarts_playback(self):
        """tvOS 26 ignores queue seeks: Session cancels the running play_url so
        _play_until_done can queue the stream again at the new position."""
        self.play_to(100)
        self.s.playback["buffered_ahead_s"] = 25.0

        async def go():
            self.s._play_task = asyncio.ensure_future(asyncio.sleep(3600))
            with mock.patch.object(session_mod.airplay, "send_command",
                                   mock.AsyncMock()) as send:
                await self.s.seek(300.0)
            send.assert_not_awaited()
            task = self.s._play_task
            await asyncio.sleep(0)                          # let the cancellation land
            return task

        task = asyncio.run(go())
        self.assertTrue(task.cancelled())
        self.assertEqual(self.s._reposition, 300.0)
        self.assertTrue(self.s._seeking)
        self.assertEqual(self.s.last_seek_at, self.clock)
        self.assertEqual(self.s.playback["position"], 300.0)
        self.assertIsNone(self.s.playback["buffered_ahead_s"])
        # While the TV restarts at 300 s, its reports are a seek rebuffer, not a stall.
        self.assertEqual(self.feed(report(300, rate=0, empty=True, likely=False)), "buffering")
        self.assertEqual(self.feed(report(300, rate=0, empty=False)), "buffering")
        self.assertEqual(self.feed(report(301), report(302)), "playing")
        self.assertFalse(self.s._seeking)
        self.assertEqual(self.s.playback["stall_count"], 0)

    def test_time_to_play_and_after_a_jump(self):
        self.s.started_at = self.clock
        self.feed(report(0, rate=0), report(0, rate=0))
        self.play_to(0)
        self.assertEqual(self.s.time_to_play_s, 3.0)            # first advancing report
        self.s._seeking = True
        self.s.last_seek_at = self.clock
        self.feed(report(300, rate=0, empty=True), report(300), report(301))
        self.assertEqual(self.s.seek_to_play_s, 2.0)
        self.assertEqual(self.s.time_to_play_s, 3.0)            # unchanged by the jump
        self.assertEqual(self.s.to_json()["timing"], {"start_s": 3.0, "seek_s": 2.0})

    def test_file_says_what_it_is(self):
        info = self.s.to_json()["file"]["name_info"]
        self.assertEqual((info["title"], info["kind"]), ("Movie", "movie"))

    def test_stale_buffer_empty_while_playing_on(self):
        # tvOS kept "buffer empty" for a minute after a jump while it played on.
        loaded = lambda p: [{"start": 0, "duration": p + 58}]
        self.play_to(100)
        self.s._seeking = True                              # just jumped
        phase = self.feed(*(report(200 + i, empty=True, ranges=loaded(200 + i)) for i in range(6)))
        self.assertEqual(phase, "playing")
        self.assertFalse(self.s.playback["buffer_empty"])
        self.assertEqual(self.s.playback["stall_count"], 0)
        self.assertEqual(sum("ignoring that flag" in m for m in self.messages()), 1)

    def test_buffer_empty_with_nothing_loaded_still_counts(self):
        self.play_to(100)
        self.feed(*(report(103, empty=True, ranges=[]) for _ in range(2)))
        self.assertEqual(self.s.phase, "stalled")
        self.assertTrue(self.s.playback["buffer_empty"])

    def test_seek_on_real_device_clamps_and_needs_playback(self):
        async def go():
            with self.assertRaisesRegex(RuntimeError, "nothing is playing"):
                await self.s.seek(10)                       # no play task at all
            done = asyncio.ensure_future(asyncio.sleep(0))
            await done
            self.s._play_task = done
            with self.assertRaisesRegex(RuntimeError, "nothing is playing"):
                await self.s.seek(10)                       # play_url already returned
            self.s._play_task = asyncio.ensure_future(asyncio.sleep(3600))
            await self.s.seek(-5)
            await asyncio.sleep(0)
            return self.s._play_task

        self.assertTrue(asyncio.run(go()).cancelled())
        self.assertEqual(self.s._reposition, 0.0)
        self.assertEqual(self.s.playback["position"], 0.0)

    def test_seek_clamps_to_duration(self):
        """A seek past the end lands 1 s before it (media duration 600 s)."""
        self.s.conf = StubConf(simulated=True)
        with mock.patch.object(session_mod.airplay, "send_command", mock.AsyncMock()) as send:
            asyncio.run(self.s.seek(10_000))
        send.assert_awaited_once_with("/scrub?position=599.000")

    def test_progress_is_saved_for_resume(self):
        self.play_to(100)
        self.feed(*(report(103 + i) for i in range(HISTORY_EVERY_S)))
        saved = history.resume_info(self.s.media.path)
        self.assertIsNotNone(saved)
        self.assertGreaterEqual(saved["position"], 100)
        self.assertEqual((saved["audio"], saved["subtitle"], saved["device_id"]),
                         (1, 0, StubConf.identifier))
        self.s._save_history(finished=True)
        saved = history.resume_info(self.s.media.path)
        self.assertTrue(saved["watched"])
        self.assertIsNone(saved["resume_position"])

    def test_no_history_before_the_tv_reports(self):
        self.s._save_history()
        self.assertIsNone(history.resume_info(self.s.media.path))


class FakeStream:
    """atv.stream: play_url records (url, position); the first call keeps
    playing until cancelled (like pyatv while the TV plays), later ones end."""

    def __init__(self, atv):
        self.atv = atv

    async def play_url(self, url, position=0):
        calls = self.atv.devices.play_calls
        calls.append((url, position))
        self.atv.played = True
        if len(calls) == 1:
            await asyncio.Event().wait()


def stub_remote_control():
    rc = mock.Mock()
    rc.set_position = mock.AsyncMock()
    rc.skip_forward = mock.AsyncMock()
    rc.skip_backward = mock.AsyncMock()
    return rc


class FakeATV:
    def __init__(self, devices):
        self.devices = devices
        self.stream = FakeStream(self)
        self.remote_control = stub_remote_control()
        self.played = False
        self.closed = False

    def close(self):
        self.closed = True
        return set()


class FakeDevices:
    """devices.connect(): play connections and the MediaRemote one alike.
    `fail_calls` lists 1-based connect() calls that raise."""

    def __init__(self):
        self.play_calls = []
        self.connected = []
        self.fail_calls = set()

    async def connect(self, conf):
        self.connected.append(conf)
        if len(self.connected) in self.fail_calls:
            raise OSError("connection refused")
        atv = FakeATV(self)
        self.connected[-1] = atv
        atv.conf = conf
        return atv

    def atvs(self):
        return [a for a in self.connected if isinstance(a, FakeATV)]


class PlayUntilDoneTest(TempDirMixin, unittest.IsolatedAsyncioTestCase):
    URL = "http://192.0.2.10:8000/master.m3u8"

    def setUp(self):
        self.tm = Telemetry()
        media = make_media(self.make_tempdir(), [video_stream(0), audio_stream(1)],
                           duration=600.0)
        self.devices = FakeDevices()
        self.conf = StubConf()
        self.s = Session(self.tm, self.devices, media, media.audio[0], None, self.conf)
        self.s.stream_url = self.URL

    def no_remote(self):
        """MediaRemote connection never comes up: seeks use the restart path."""
        self.s._connect_remote = mock.AsyncMock()

    def messages(self):
        return [e["message"] for e in self.tm.events]

    async def until(self, cond, what):
        for _ in range(200):
            if cond():
                return
            await asyncio.sleep(0.01)
        self.fail(what)

    async def wait_for_calls(self, n):
        await self.until(lambda: len(self.devices.play_calls) >= n,
                         f"play_url called {len(self.devices.play_calls)} time(s), expected {n}")

    def assert_all_closed(self):
        self.assertTrue(self.devices.atvs())
        self.assertTrue(all(a.closed for a in self.devices.atvs()))
        self.assertTrue(all(a.conf is self.conf for a in self.devices.atvs()))
        self.assertIsNone(self.s.atv)
        self.assertIsNone(self.s._remote)

    async def test_seek_without_remote_reconnects_and_plays_at_new_position(self):
        self.no_remote()
        run = asyncio.ensure_future(self.s._play_until_done(12.0))
        await self.wait_for_calls(1)
        first = self.s.atv
        await self.s.seek(250.0)
        await asyncio.wait_for(run, 2)                    # second play_url returns: done
        self.assertEqual(self.devices.play_calls, [(self.URL, 12.0), (self.URL, 250.0)])
        self.assertEqual(len(self.devices.connected), 2)
        self.assertIs(self.devices.connected[0], first)
        self.assert_all_closed()
        self.assertIsNone(self.s._reposition)
        self.assertIn("Restarted playback at 250 s for seek", self.messages())

    async def test_remote_unavailable_falls_back_to_restart(self):
        self.devices.fail_calls = {2}                     # 1 = play, 2 = MediaRemote
        run = asyncio.ensure_future(self.s._play_until_done(0.0))
        await self.wait_for_calls(1)
        await self.until(lambda: any("Remote control unavailable" in m
                                     for m in self.messages()), "no remote warning")
        self.assertIsNone(self.s._remote)
        await self.s.seek(100.0)
        await asyncio.wait_for(run, 2)
        self.assertEqual(self.devices.play_calls, [(self.URL, 0.0), (self.URL, 100.0)])
        self.assert_all_closed()

    async def test_seek_with_remote_moves_playhead_in_place(self):
        run = asyncio.ensure_future(self.s._play_until_done(0.0))
        await self.wait_for_calls(1)
        await self.until(lambda: self.s._remote is not None, "remote never connected")
        remote = self.s._remote
        self.assertFalse(remote.played)                   # a separate connection
        self.assertIn("Remote control connected (in-place seek and skip)", self.messages())
        play_task = self.s._play_task
        await self.s.seek(250.0)
        remote.remote_control.set_position.assert_awaited_once_with(250.0)
        await asyncio.sleep(0.05)
        self.assertFalse(play_task.done())                # no restart
        self.assertIsNone(self.s._reposition)
        self.assertEqual(self.devices.play_calls, [(self.URL, 0.0)])
        run.cancel()                                      # stop
        with self.assertRaises(asyncio.CancelledError):
            await run
        self.assertTrue(remote.closed)
        self.assert_all_closed()

    async def test_simulated_device_opens_no_remote(self):
        self.conf = self.s.conf = StubConf(simulated=True)
        self.devices.play_calls.append(("earlier", 0))     # make the next call return at once
        await asyncio.wait_for(self.s._play_until_done(0.0), 2)
        await asyncio.sleep(0.05)
        self.assertEqual(len(self.devices.connected), 1)
        self.assert_all_closed()

    async def test_plain_end_returns_without_restart(self):
        self.devices.play_calls.append(("earlier", 0))     # make the next call return at once
        await asyncio.wait_for(self.s._play_until_done(0.0), 2)
        self.assertEqual(self.devices.play_calls[1:], [(self.URL, 0.0)])
        self.assertEqual(sum(a.played for a in self.devices.atvs()), 1)
        self.assertNotIn("Restarted", " ".join(self.messages()))
        self.assert_all_closed()

    async def test_stop_while_playing_is_not_a_restart(self):
        self.no_remote()
        run = asyncio.ensure_future(self.s._play_until_done(0.0))
        await self.wait_for_calls(1)
        run.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await run
        self.assertEqual(len(self.devices.play_calls), 1)
        self.assert_all_closed()

    async def test_play_error_propagates(self):
        async def boom(url, position=0):
            raise RuntimeError("got error -11828 (AVFoundationErrorDomain) when playing video")

        orig = self.devices.connect

        async def connect(conf):
            atv = await orig(conf)
            atv.stream.play_url = boom
            return atv

        self.devices.connect = connect
        with self.assertRaisesRegex(RuntimeError, "got error -11828"):
            await self.s._play_until_done(0.0)
        self.assert_all_closed()


    async def test_lost_connection_reconnects_where_the_tv_was(self):
        # The Mac slept (or Wi-Fi dropped): play_url fails with a lost
        # connection; the session connects again and goes on from the last
        # position the TV reported instead of failing.
        from pyatv import exceptions as atv_errors
        orig, calls = self.devices.connect, []

        async def connect(conf):
            atv = await orig(conf)
            if not calls:
                async def lost(url, position=0):
                    calls.append(position)
                    self.s.playback["position"] = 1234.0
                    raise atv_errors.ConnectionLostError("connection was lost")
                atv.stream.play_url = lost
                calls.append("connected")
            return atv

        self.no_remote()
        self.devices.connect = connect
        with mock.patch.object(session_mod, "RECONNECT_DELAYS", (0, 0)):
            run = asyncio.ensure_future(self.s._play_until_done(12.0))
            await self.wait_for_calls(1)
            self.assertEqual(self.devices.play_calls, [(self.URL, 1234.0)])
            self.assertEqual(self.s.phase, "connecting")
            self.assertTrue(any("reconnecting in 0 s (attempt 1 of 2, from 1234 s)" in m
                                for m in self.messages()))
            run.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await run
        self.assert_all_closed()

    async def test_lost_connection_gives_up_after_the_last_attempt(self):
        from pyatv import exceptions as atv_errors

        async def connect(conf):
            raise atv_errors.ConnectionFailedError("no route to host")

        self.no_remote()
        self.devices.connect = connect
        with mock.patch.object(session_mod, "RECONNECT_DELAYS", (0, 0)):
            with self.assertRaisesRegex(atv_errors.ConnectionFailedError, "no route"):
                await self.s._play_until_done(0.0)
        self.assertEqual(sum("reconnecting" in m for m in self.messages()), 2)


class SeekDuringRestartTest(TempDirMixin, unittest.TestCase):
    """Regression: a second seek while playback restarts for the first one used
    to fail with "nothing is playing"; it must retarget the pending restart."""

    def test_second_seek_retargets_pending_restart(self):
        media = make_media(self.make_tempdir(), [video_stream(0), audio_stream(1)],
                           duration=600.0)
        s = Session(Telemetry(), None, media, media.audio[0], None, StubConf())
        s._reposition = 100.0                   # restart for the first seek pending
        asyncio.run(s.seek(250.0))
        self.assertEqual(s._reposition, 250.0)
        self.assertEqual(s.playback["position"], 250.0)


class RemoteSeekSkipTest(TempDirMixin, unittest.IsolatedAsyncioTestCase):
    """seek()/skip() on a real device with (or without) the MediaRemote connection."""

    def setUp(self):
        self.tm = Telemetry()
        media = make_media(self.make_tempdir(), [video_stream(0), audio_stream(1)],
                           duration=600.0)
        self.s = Session(self.tm, None, media, media.audio[0], None, StubConf())
        self.s.playback["position"] = 100.0
        self.rc = stub_remote_control()
        self.s._remote = mock.Mock(remote_control=self.rc)

    async def asyncSetUp(self):
        self.play_task = self.s._play_task = asyncio.ensure_future(asyncio.sleep(3600))
        self.addCleanup(self.play_task.cancel)

    def warnings(self):
        return [e["message"] for e in self.tm.events if e["level"] == "warn"]

    async def test_seek_with_remote(self):
        await self.s.seek(300.0)
        self.rc.set_position.assert_awaited_once_with(300.0)
        await asyncio.sleep(0)
        self.assertFalse(self.play_task.done())
        self.assertIsNone(self.s._reposition)
        self.assertEqual(self.s.playback["position"], 300.0)
        self.assertTrue(self.s._seeking)
        self.assertIsNotNone(self.s.last_seek_at)
        await self.s.seek(5000)                            # clamped to duration - 1
        self.rc.set_position.assert_awaited_with(599.0)

    async def test_seek_with_failing_remote_restarts(self):
        self.rc.set_position.side_effect = RuntimeError("MediaRemote timeout")
        await self.s.seek(300.0)
        self.rc.set_position.assert_awaited_once_with(300.0)
        await asyncio.sleep(0)
        self.assertTrue(self.play_task.cancelled())
        self.assertEqual(self.s._reposition, 300.0)
        self.assertEqual(self.s.playback["position"], 300.0)
        self.assertIn("In-place seek failed (MediaRemote timeout); restarting", self.warnings())

    async def test_volume_through_the_apple_tv(self):
        audio = mock.Mock(volume_up=mock.AsyncMock(), volume_down=mock.AsyncMock(),
                          set_volume=mock.AsyncMock())
        self.s._remote.audio = audio
        await self.s.volume("up")
        await self.s.volume("down")
        await self.s.volume(level=150)                     # clamped
        audio.volume_up.assert_awaited_once()
        audio.volume_down.assert_awaited_once()
        audio.set_volume.assert_awaited_once_with(100.0)
        with self.assertRaises(ValueError):
            await self.s.volume("sideways")
        self.s._remote = None
        with self.assertRaisesRegex(RuntimeError, "remote control"):
            await self.s.volume("up")
        self.assertEqual(self.s.volume_json(), {"supported": False, "level": None})

    async def test_skip_with_remote(self):
        await self.s.skip(10)
        self.rc.skip_forward.assert_awaited_once_with(10.0)
        self.rc.skip_backward.assert_not_awaited()
        self.assertTrue(self.s._seeking)
        self.assertIsNotNone(self.s.last_seek_at)
        self.assertEqual(self.s.playback["position"], 110.0)
        self.s._seeking = False
        await self.s.skip("-30")                           # API values may be strings
        self.rc.skip_backward.assert_awaited_once_with(30.0)
        self.assertTrue(self.s._seeking)
        self.assertEqual(self.s.playback["position"], 80.0)
        await self.s.skip(-500)
        self.rc.skip_backward.assert_awaited_with(500.0)
        self.assertEqual(self.s.playback["position"], 0.0)  # never negative
        self.rc.set_position.assert_not_awaited()
        self.assertFalse(self.play_task.done())

    async def test_skip_remembers_where_it_goes(self):
        await self.s.skip(-30)
        self.assertEqual((self.s._seek_origin, self.s._seek_target), (100.0, 70.0))
        await self.s.seek(300.0)
        self.assertEqual((self.s._seek_origin, self.s._seek_target), (70.0, 300.0))

    async def test_skip_before_first_report_with_remote(self):
        self.s.playback["position"] = None
        await self.s.skip(10)
        self.rc.skip_forward.assert_awaited_once_with(10.0)
        self.assertIsNone(self.s.playback["position"])

    async def test_failing_skip_falls_back_to_seek(self):
        self.rc.skip_forward.side_effect = RuntimeError("not supported")
        await self.s.skip(15)
        self.rc.set_position.assert_awaited_once_with(115.0)
        self.assertIn("Skip failed (not supported); seeking instead", self.warnings())

    async def test_skip_without_remote_seeks(self):
        self.s._remote = None
        await self.s.skip(-20)
        await asyncio.sleep(0)
        self.assertEqual(self.s._reposition, 80.0)          # restart path at position - 20
        self.assertTrue(self.play_task.cancelled())
        self.assertTrue(self.s._seeking)

    async def test_skip_without_remote_or_position_fails(self):
        self.s._remote = None
        self.s.playback["position"] = None
        with self.assertRaisesRegex(RuntimeError, "nothing is playing"):
            await self.s.skip(10)
        self.assertFalse(self.play_task.done())

    async def test_skip_on_simulator_scrubs(self):
        self.s.conf = StubConf(simulated=True)
        with mock.patch.object(session_mod.airplay, "send_command", mock.AsyncMock()) as send:
            await self.s.skip(10)
        send.assert_awaited_once_with("/scrub?position=110.000")
        self.rc.skip_forward.assert_not_awaited()


if __name__ == "__main__":
    unittest.main()


class EarlyStartTest(TempDirMixin, unittest.IsolatedAsyncioTestCase):
    """Playback starts once the start point is prepared, not after the whole
    remux; the AirPlay connection opened meanwhile is reused."""

    def setUp(self):
        self.tm = Telemetry()
        media = make_media(self.make_tempdir(), [video_stream(0), audio_stream(1)],
                           duration=600.0)
        self.devices = FakeDevices()
        self.s = Session(self.tm, self.devices, media, media.audio[0], None, StubConf())
        self.s.transcoder = mock.Mock(done=False, progress=0.1)
        self.dir = self.make_tempdir()
        (self.dir / "ffmaster.m3u8").write_text("#EXTM3U\n")

    def segments(self, n):
        (self.dir / "stream_video.m3u8").write_text(
            "#EXTM3U\n" + "".join("#EXTINF:6.000000,\nseg.m4s\n" for _ in range(n)))

    async def ready_within(self, reencoding=False, timeout=1.0):
        try:
            await asyncio.wait_for(self.s._wait_until_playable(self.dir, reencoding), timeout)
            return True
        except asyncio.TimeoutError:
            return False

    async def test_remux_waits_for_the_whole_file_by_default(self):
        self.segments(50)
        self.assertFalse(await self.ready_within(timeout=0.5))
        self.s.transcoder.done = True
        self.s.transcoder.failed = False
        self.assertTrue(await self.ready_within())

    async def test_reencode_starts_after_a_few_segments(self):
        self.segments(3)
        self.assertTrue(await self.ready_within(reencoding=True))

    async def test_early_start_switch_starts_a_remux_early(self):
        self.segments(3)
        with mock.patch.object(session_mod, "WAIT_FULL_PREP", False):
            self.assertTrue(await self.ready_within())

    async def test_resume_waits_until_the_start_point_is_prepared(self):
        self.s.start_position = 100
        self.segments(10)                       # 60 s: not there yet
        self.assertFalse(await self.ready_within(reencoding=True, timeout=0.5))
        self.segments(20)                       # 120 s >= 100 + 18
        self.assertTrue(await self.ready_within(reencoding=True))

    async def test_early_connection_is_used_once(self):
        self.s._early_connect = asyncio.ensure_future(self.devices.connect(self.s.conf))
        first = await self.s._take_connection()
        second = await self.s._take_connection()
        self.assertIsNot(first, second)
        self.assertEqual(len(self.devices.atvs()), 2)

    async def test_failed_early_connection_reconnects(self):
        self.devices.fail_calls = {1}
        self.s._early_connect = asyncio.ensure_future(self.devices.connect(self.s.conf))
        atv = await self.s._take_connection()
        self.assertIsInstance(atv, FakeATV)
        self.assertTrue(any("Early connection failed" in e["message"] for e in self.tm.events))


class StaleWorkdirTest(TempDirMixin, unittest.TestCase):
    def test_sweep_removes_only_dirs_of_dead_backends(self):
        parent = self.make_tempdir()
        dead, live, legacy, other = (parent / n for n in ("jancast-dead", "jancast-live",
                                                          "jancast-legacy", "unrelated"))
        for d in (dead, live, legacy, other):
            d.mkdir()
            (d / "seg_video_00000.m4s").write_bytes(b"x" * 1000)
        (dead / session_mod.OWNER_FILE).write_text("999999")
        (live / session_mod.OWNER_FILE).write_text(str(session_mod.os.getpid()))
        with mock.patch.object(session_mod, "_alive", lambda pid: pid != 999999):
            freed = session_mod.sweep_stale_workdirs(parent)
        self.assertEqual(sorted(p.name for p in parent.iterdir()),
                         ["jancast-legacy", "jancast-live", "unrelated"])
        self.assertGreaterEqual(freed, 1000)


class TVDurationTest(PlaybackStateTest):
    def test_file_duration_wins_over_the_tvs_partial_one(self):
        self.feed(report(10, duration=120.0))
        self.assertEqual(self.s.playback["duration"], 600.0)

    def test_warns_when_tv_keeps_a_short_stream_after_prep(self):
        self.s.transcoder = mock.Mock(done=True, failed=False)
        self.feed(*(report(10 + i, duration=300.0) for i in range(25)))
        warns = [m for m in self.messages("warn") if "still sees a 300 s stream" in m]
        self.assertEqual(len(warns), 1)

    def test_no_warning_once_tv_has_the_full_length(self):
        self.s.transcoder = mock.Mock(done=True, failed=False)
        self.feed(*(report(10 + i, duration=600.0) for i in range(25)))
        self.assertFalse([m for m in self.messages("warn") if "still sees" in m])


class OCRPrepTest(TempDirMixin, unittest.TestCase):
    """Picture subtitles: playback follows the reading the ready view started."""

    def setUp(self):
        d = self.make_tempdir()
        self.media = make_media(d, [video_stream(0), audio_stream(1), sub_stream(2, "hdmv_pgs_subtitle")])
        self.vtt = str(self.make_tempdir() / "text.fast.vtt")
        self.tm = Telemetry()

    def session(self):
        with mock.patch("jancast.media.shutil.which", return_value="/usr/bin/swiftc"):
            self.assertTrue(self.media.subs[0].via_ocr)
            return Session(self.tm, None, self.media, self.media.audio[0], self.media.subs[0], StubConf())

    def test_follows_a_running_job_with_its_progress(self):
        s = self.session()
        job = mock.Mock(progress=0.4, error=None)
        job.done.is_set.side_effect = [False, False, True]
        seen = []
        cached = mock.Mock(side_effect=[None, self.vtt])

        async def sleep(_):
            seen.append(s._sub_progress)
            job.progress = 0.8

        with mock.patch.object(session_mod.ocrsubs, "ensure", return_value=job), \
                mock.patch.object(session_mod.ocrsubs, "cached", cached), \
                mock.patch.object(session_mod.asyncio, "sleep", sleep), \
                mock.patch("jancast.media.shutil.which", return_value="/usr/bin/swiftc"):
            track = asyncio.run(s._prepare_subtitles())
        self.assertEqual(seen, [0.4, 0.8])
        self.assertIsNone(s._sub_progress)
        self.assertEqual(str(track.file), self.vtt)

    def test_failed_reading_plays_without_subtitles(self):
        s = self.session()
        job = mock.Mock(progress=0.0, error="Vision failed")
        job.done.is_set.return_value = True
        with mock.patch.object(session_mod.ocrsubs, "ensure", return_value=job), \
                mock.patch.object(session_mod.ocrsubs, "cached", return_value=None), \
                mock.patch("jancast.media.shutil.which", return_value="/usr/bin/swiftc"):
            self.assertIsNone(asyncio.run(s._prepare_subtitles()))
        self.assertTrue(any("Vision failed" in e["message"] for e in self.tm.events))
