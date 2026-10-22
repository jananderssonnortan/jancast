"""telemetry.diagnose(): the rule table, plus regressions for misattributions."""

import time
import unittest

from jancast.telemetry import Telemetry, diagnose

CAUSES = {"network", "encoder", "device", "source", "server"}
STATUSES = {"ok", "warning", "failing", "failed", "unknown"}


def request(t, kind="segment", status=200, ratio=None, error=None, path=None):
    return {"t": t, "path": path or "/seg_video_00001.m4s", "kind": kind, "segment": 1,
            "status": status, "bytes": 1000, "duration_ms": 10.0, "mbps": 1.0,
            "realtime_ratio": ratio, "client": "192.0.2.20", "error": error}


class DiagnoseTest(unittest.TestCase):
    def setUp(self):
        self.now = time.time()
        self.tm = Telemetry()
        self.session = {"id": "s1", "started_at": self.now - 300, "stream_bitrate_bps": 10e6,
                        "segment_duration_s": 6}
        self.prep = {"progress": 1.0, "speed": 400.0, "prepared_s": 3000.0, "done": True,
                     "error": None}
        self.playback = {"position": 800.0, "duration": 3000.0, "rate": 1.0,
                         "buffered_ahead_s": 50.0, "buffer_empty": False, "buffer_full": False,
                         "likely_to_keep_up": True, "ready_to_play": True, "stall_count": 0,
                         "stalled_s_total": 0.0, "last_report_at": self.now - 0.5,
                         "error": None}
        self.network = {"tx_bps_now": 20e6, "tx_bps_avg10": 12e6, "rtt_ms": 4.0,
                        "rtt_ms_avg": 5.0, "rtt_loss": 0.0, "http_errors": 0,
                        "client_aborts": 0}

    def segments(self, ratio, n=5, ago=10):
        for i in range(n):
            self.tm.request(request(self.now - ago + i, ratio=ratio))

    def run_diag(self, phase="playing", session="default"):
        d = diagnose(phase, self.session if session == "default" else session,
                     self.prep, self.playback, self.network, self.tm)
        self.assertEqual(set(d), {"status", "headline", "details", "suspects"})
        self.assertIn(d["status"], STATUSES)
        if d["suspects"]:
            self.assertEqual({s["cause"] for s in d["suspects"]}, CAUSES)
            confs = [s["confidence"] for s in d["suspects"]]
            self.assertEqual(confs, sorted(confs, reverse=True))
            for s in d["suspects"]:
                self.assertTrue(0 <= s["confidence"] <= 1)
                self.assertIsInstance(s["evidence"], str)
        return d

    def top(self, d):
        return d["suspects"][0]["cause"], d["suspects"][0]["confidence"]

    # ---- scenarios -----------------------------------------------------

    def test_nothing_playing(self):
        d = self.run_diag("idle", session=None)
        self.assertEqual((d["status"], d["headline"], d["suspects"]),
                         ("unknown", "Nothing playing", []))

    def test_healthy(self):
        self.segments(20.0)
        d = self.run_diag()
        self.assertEqual((d["status"], d["headline"]), ("ok", "Streaming healthy"))
        self.assertTrue(all(s["confidence"] < 0.5 for s in d["suspects"]))
        self.assertIn("Stream needs 10.0 Mbit/s; last 10 s delivered 12.0 Mbit/s on average",
                      d["details"])
        self.assertIn("Apple TV has 50 s buffered", d["details"])

    def test_slow_network_warning_then_failing(self):
        self.segments(0.8)
        d = self.run_diag()
        self.assertEqual(self.top(d), ("network", 0.9))
        self.assertEqual(d["status"], "warning")
        self.assertEqual(d["headline"], "The network to the Apple TV is barely keeping up")
        self.playback["buffered_ahead_s"] = 2.0
        d = self.run_diag()
        self.assertEqual((d["status"], d["headline"]),
                         ("failing", "The network to the Apple TV is too slow"))
        d = self.run_diag("stalled")
        self.assertEqual((d["status"], self.top(d)[0]), ("failing", "network"))

    def test_marginal_network_while_stalled(self):
        self.segments(2.0)
        d = self.run_diag("stalled")
        self.assertEqual(self.top(d), ("network", 0.6))

    def test_latency_and_loss(self):
        self.segments(20.0)
        self.network.update(rtt_loss=0.3)
        self.assertEqual(self.top(self.run_diag()), ("network", 0.7))
        self.network.update(rtt_loss=0.0, rtt_ms_avg=150.0)
        d = self.run_diag()
        self.assertEqual(self.top(d), ("network", 0.5))
        self.assertIn("150 ms", d["suspects"][0]["evidence"])

    def test_aborts_raise_network(self):
        self.segments(20.0)
        self.tm.request(request(self.now - 1, error="client aborted"))
        net = next(s for s in self.run_diag()["suspects"] if s["cause"] == "network")
        self.assertEqual(net["confidence"], 0.4)

    def test_encoder_too_slow(self):
        self.prep.update(done=False, speed=0.8, prepared_s=820.0, progress=0.27)
        self.segments(20.0)
        for i in range(3):
            self.tm.request(request(self.now - 5 + i, status=404, error="not ready (404)"))
        d = self.run_diag()
        self.assertEqual(self.top(d), ("encoder", 0.9))
        self.assertEqual(d["status"], "warning")
        self.assertIn("3 segment(s)", d["suspects"][0]["evidence"])
        d = self.run_diag("stalled")
        self.assertEqual((d["status"], d["headline"]),
                         ("failing", "Preparing the stream is too slow"))
        # Device must not be blamed: segments are missing, not undecodable.
        dev = next(s for s in d["suspects"] if s["cause"] == "device")
        self.assertEqual(dev["confidence"], 0.0)

    def test_encoder_slow_without_404(self):
        self.prep.update(done=False, speed=0.9, prepared_s=820.0)
        self.assertEqual(self.top(self.run_diag()), ("encoder", 0.6))
        self.prep.update(prepared_s=900.0)                      # 100 s headroom
        self.assertEqual(self.top(self.run_diag()), ("encoder", 0.3))
        self.prep.update(speed=None, prepared_s=805.0)          # speed unknown, 5 s ahead
        self.assertEqual(self.top(self.run_diag()), ("encoder", 0.5))

    def test_fast_start_headroom_counts_only_on_a_short_tv_buffer(self):
        """Fast start makes segments as the TV asks: little made ahead with a
        healthy TV buffer (or right after a jump) is no reason to warn."""
        self.prep.update(done=False, speed=None, prepared_s=805.0, on_demand=True)
        d = self.run_diag()
        self.assertEqual(d["status"], "ok")
        self.assertNotIn("barely keeping up", d["headline"])
        self.playback.update(buffered_ahead_s=0.0)
        enc = next(s for s in self.run_diag("buffering")["suspects"] if s["cause"] == "encoder")
        self.assertEqual(enc["confidence"], 0.0)                                # after a jump
        self.playback.update(buffered_ahead_s=5.0)
        self.assertEqual(self.top(self.run_diag()), ("encoder", 0.5))

    def test_ffmpeg_failed(self):
        self.prep.update(done=False, error="Conversion failed!")
        d = self.run_diag("failed")
        self.assertEqual(self.top(d), ("encoder", 1.0))
        self.assertEqual((d["status"], d["headline"]),
                         ("failed", "Preparing the stream is too slow"))

    def test_tv_error(self):
        self.segments(20.0)
        self.playback["error"] = "-11828 (AVFoundationErrorDomain): Cannot Open"
        d = self.run_diag("failed")
        self.assertEqual(self.top(d), ("device", 0.95))
        self.assertEqual((d["status"], d["headline"]),
                         ("failed", "The Apple TV has a playback problem"))

    def test_failed_without_evidence(self):
        d = self.run_diag("failed")
        self.assertEqual((d["status"], d["headline"]), ("failed", "Playback failed"))

    def test_stalled_with_fast_segments_blames_device(self):
        self.segments(20.0)
        self.playback.update(buffered_ahead_s=0.0, buffer_empty=True, stall_count=2,
                             stalled_s_total=7.4)
        d = self.run_diag("stalled")
        self.assertEqual(self.top(d), ("device", 0.6))
        self.assertEqual((d["status"], d["headline"]),
                         ("failing", "The Apple TV has a playback problem"))
        self.assertIn("2 stall(s), 7 s in total", d["details"])

    def test_stalled_no_evidence(self):
        self.playback.update(buffered_ahead_s=0.0, buffer_empty=True)
        d = self.run_diag("stalled")
        self.assertEqual((d["status"], d["headline"]), ("failing", "Playback stalled"))
        self.playback.update(buffered_ahead_s=None)
        d = self.run_diag("stalled")
        self.assertEqual((d["status"], d["headline"]), ("failing", "Playback stalled"))

    def test_tv_stopped_reporting(self):
        self.segments(20.0)
        self.playback["last_report_at"] = self.now - 30
        d = self.run_diag()
        self.assertEqual(self.top(d), ("device", 0.6))
        self.assertEqual(d["status"], "warning")

    def test_source_problems(self):
        self.segments(20.0)
        self.tm.event("warn", "ffmpeg", "[matroska @ 0x1] Invalid data found when processing input")
        self.tm.event("warn", "ffmpeg", "[h264 @ 0x2] corrupt decoded frame")
        self.tm.event("info", "ffmpeg", "error-free info line ignored (info level)")
        self.tm.event("warn", "http", "invalid but not from ffmpeg")
        d = self.run_diag()
        src = next(s for s in d["suspects"] if s["cause"] == "source")
        self.assertAlmostEqual(src["confidence"], 0.4)
        self.assertIn("2 data problem(s)", src["evidence"])
        for _ in range(6):
            self.tm.event("warn", "ffmpeg", "Error while decoding stream #0:1")
        d = self.run_diag()
        self.assertEqual(self.top(d), ("source", 0.8))
        self.assertEqual((d["status"], d["headline"]),
                         ("warning", "The source file has damaged or unsupported data"))

    def test_source_events_from_previous_session_ignored(self):
        self.tm.event("warn", "ffmpeg", "Invalid data found when processing input")
        self.tm.events[-1]["t"] = self.session["started_at"] - 10
        src = next(s for s in self.run_diag()["suspects"] if s["cause"] == "source")
        self.assertEqual(src["confidence"], 0.0)

    def test_server_errors(self):
        self.segments(20.0)
        self.tm.request(request(self.now - 2, status=500, error="OSError: disk"))
        d = self.run_diag()
        self.assertEqual(self.top(d), ("server", 0.8))
        self.assertEqual(d["headline"], "The local stream server is failing")

    def test_finished_and_stopped(self):
        self.segments(20.0)
        d = self.run_diag("finished")
        self.assertEqual((d["status"], d["headline"]), ("ok", "Playback finished"))
        d = self.run_diag("stopped")
        self.assertEqual((d["status"], d["headline"]), ("ok", "Stopped"))

    def test_nulls_before_tv_reports(self):
        """Phases before playback: every playback field is None, no ratios at all."""
        self.prep = {"progress": 0.0, "speed": None, "prepared_s": 0.0, "done": False,
                     "error": None}
        self.playback = {k: None for k in self.playback}
        self.playback.update(stall_count=0, stalled_s_total=0.0)
        self.network = {"tx_bps_now": 0, "tx_bps_avg10": 0, "rtt_ms": None, "rtt_ms_avg": None,
                        "rtt_loss": 0.0, "http_errors": 0, "client_aborts": 0}
        self.session["stream_bitrate_bps"] = None
        for phase in ("preparing", "connecting", "buffering"):
            with self.subTest(phase=phase):
                d = self.run_diag(phase)
                self.assertEqual((d["status"], d["headline"]), ("ok", "Streaming healthy"))
                self.assertEqual(d["details"], [])
        # Even an empty network dict must not crash.
        self.network = {}
        self.run_diag("buffering")

    # ---- regressions (misattributions fixed in telemetry.py) -----------

    def test_previous_session_requests_ignored(self):
        """Slow segments / 404s / 5xx logged before this session started must not
        be blamed on it (the request log is shared across sessions)."""
        old = self.session["started_at"] - 5
        for i in range(5):
            self.tm.request(request(old - i, ratio=0.5))
            self.tm.request(request(old - i, status=404, error="not ready (404)"))
            self.tm.request(request(old - i, status=500, error="boom"))
        self.session["started_at"] = self.now - 2
        self.prep.update(done=False, speed=5.0, prepared_s=900.0)
        d = self.run_diag()
        self.assertEqual(d["status"], "ok", d)
        self.assertTrue(all(s["confidence"] < 0.5 for s in d["suspects"]), d["suspects"])

    def test_non_media_404_not_blamed_on_encoder(self):
        self.prep.update(done=False, speed=5.0, prepared_s=900.0)
        for _ in range(3):
            self.tm.request(request(self.now - 1, kind="other", status=404, error="not found",
                                    path="/favicon.ico"))
        enc = next(s for s in self.run_diag()["suspects"] if s["cause"] == "encoder")
        self.assertLess(enc["confidence"], 0.5)

    def test_stopped_session_not_reported_as_problem(self):
        """After the user stops: ffmpeg was terminated (prep error) and the TV no
        longer reports - that is expected, not a warning."""
        self.playback["last_report_at"] = self.now - 60
        self.prep.update(done=False, error="Exiting normally, received signal 15.")
        d = self.run_diag("stopped")
        self.assertEqual((d["status"], d["headline"]), ("ok", "Stopped"))
        self.prep.update(error=None, done=True)
        d = self.run_diag("finished")
        self.assertEqual((d["status"], d["headline"]), ("ok", "Playback finished"))
        dev = next(s for s in d["suspects"] if s["cause"] == "device")
        self.assertEqual(dev["confidence"], 0.0)

    def test_full_tv_buffer_is_not_a_network_problem(self):
        """With a full buffer the TV reads slowly on purpose; slow transfers then
        don't mean the network can't keep up."""
        self.segments(0.7)
        self.playback.update(buffer_full=True, buffered_ahead_s=120.0)
        d = self.run_diag()
        self.assertEqual(d["status"], "ok", d)
        net = next(s for s in d["suspects"] if s["cause"] == "network")
        self.assertLessEqual(net["confidence"], 0.25)
        self.assertIn("buffer is full", net["evidence"])
        # ...but a stall still counts, and so do aborted transfers / probe loss.
        self.assertEqual(self.top(self.run_diag("stalled"))[0], "network")
        self.tm.request(request(self.now - 1, error="client aborted"))
        net = next(s for s in self.run_diag()["suspects"] if s["cause"] == "network")
        self.assertEqual(net["confidence"], 0.4)
        self.network["rtt_loss"] = 0.5
        self.assertEqual(self.top(self.run_diag()), ("network", 0.7))

    def test_only_200_segments_with_ratio_count(self):
        # Range (206) requests and requests without a ratio are ignored for the median.
        for i in range(5):
            self.tm.request(request(self.now - i, status=206, ratio=0.1))
            self.tm.request(request(self.now - i, ratio=None))
        net = next(s for s in self.run_diag()["suspects"] if s["cause"] == "network")
        self.assertEqual(net["confidence"], 0.0)

    def test_hung_tv_still_blamed_after_ratio_window(self):
        """Regression (e2e `stuck --long`): a TV frozen with a full buffer fetches
        nothing, so its fast segment ratios age out of the 60 s window; the
        buffered data it isn't playing still points at the device."""
        self.segments(20.0, ago=200)                 # last downloads 200 s ago
        self.playback.update(buffered_ahead_s=30.0, stall_count=1)
        d = self.run_diag("stalled")
        self.assertEqual(self.top(d), ("device", 0.6))
        self.assertIn("30 s buffered", d["suspects"][0]["evidence"])
        self.assertEqual((d["status"], d["headline"]),
                         ("failing", "The Apple TV has a playback problem"))
        # Less than two segments buffered: that's an empty-ish buffer, not proof.
        self.playback["buffered_ahead_s"] = 11.0
        self.assertEqual(self.top(self.run_diag("stalled"))[1], 0.0)
        # Missing segments are the encoder's fault, not the TV's.
        self.playback["buffered_ahead_s"] = 30.0
        self.prep.update(done=False, speed=5.0, prepared_s=900.0)
        self.tm.request(request(self.now - 1, status=404, error="not ready (404)"))
        d = self.run_diag("stalled")
        self.assertEqual(self.top(d)[0], "encoder")
        dev = next(s for s in d["suspects"] if s["cause"] == "device")
        self.assertEqual(dev["confidence"], 0.0)

    def test_hung_tv_rule_defers_to_recent_slow_ratios(self):
        self.segments(0.8)
        self.playback.update(buffered_ahead_s=30.0)
        self.assertEqual(self.top(self.run_diag("stalled")), ("network", 0.9))
        dev = next(s for s in self.run_diag("stalled")["suspects"] if s["cause"] == "device")
        self.assertEqual(dev["confidence"], 0.0)

    def test_seek_aborts_not_blamed_on_network(self):
        """Regression: a user seek makes the TV drop in-flight transfers; those
        aborts raised the network suspect to 0.4 for a minute."""
        self.segments(20.0)
        seek = self.now - 20
        self.session["last_seek_at"] = seek
        # Started before the seek, aborted right after it / just before it was
        # recorded / a couple of seconds later.
        for start, dur_ms in ((seek - 1.5, 1600), (seek - 0.8, 500), (seek + 1.0, 1500)):
            self.tm.request({**request(start, error="client aborted"), "duration_ms": dur_ms})
        net = next(s for s in self.run_diag()["suspects"] if s["cause"] == "network")
        self.assertEqual(net["confidence"], 0.0, net)
        self.assertNotIn("aborted", net["evidence"])
        # An abort well after the seek still counts.
        self.tm.request({**request(seek + 10, error="client aborted"), "duration_ms": 100})
        net = next(s for s in self.run_diag()["suspects"] if s["cause"] == "network")
        self.assertEqual(net["confidence"], 0.4)
        self.assertIn("1 transfer(s) aborted", net["evidence"])
        # ...and so does one long before it.
        self.tm.request({**request(seek - 30, error="client aborted"), "duration_ms": 100})
        net = next(s for s in self.run_diag()["suspects"] if s["cause"] == "network")
        self.assertIn("2 transfer(s) aborted", net["evidence"])

    def test_seek_field_missing_or_none(self):
        self.segments(20.0)
        self.tm.request(request(self.now - 1, error="client aborted"))
        for value in ("absent", None, 0):
            with self.subTest(last_seek_at=value):
                self.session.pop("last_seek_at", None)
                if value != "absent":
                    self.session["last_seek_at"] = value
                net = next(s for s in self.run_diag()["suspects"] if s["cause"] == "network")
                self.assertEqual(net["confidence"], 0.4)


if __name__ == "__main__":
    unittest.main()
