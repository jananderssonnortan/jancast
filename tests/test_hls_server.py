"""hls_server.py: classification, headers, ranges, telemetry of every transfer."""

import contextlib
import http.client
import io
import os
import shutil
import socket
import struct
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

from helpers import TempDirMixin
from jancast import hls_server
from jancast.hls_server import (DirectoryBitrate, HLSServer, classify, directory_bitrate,
                                unsent_bytes, wait_drained)
from jancast.telemetry import Telemetry

PLAYLIST = ("#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:6\n#EXT-X-MAP:URI=\"init_video.mp4\"\n"
            "#EXTINF:6.000000,\nseg_video_00000.m4s\n#EXTINF:4.000000,\nseg_video_00001.m4s\n")
AUDIO_PLAYLIST = ("#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:6\n"
                  "#EXT-X-MAP:URI=\"init_audio.mp4\"\n#EXTINF:6.015833,\nseg_audio_00000.m4s\n")
SEG0 = bytes(range(256)) * 40          # 10240 bytes
AUDIO_SEG = b"\2" * 3000
BIG = b"\0" * (32 * 1024 * 1024)
MEDIUM = b"\1" * (2 * 1024 * 1024)
CAN_MEASURE_QUEUE = sys.platform == "darwin" or sys.platform.startswith("linux")


class ClassifyTest(unittest.TestCase):
    def test_classify(self):
        cases = {
            "/master.m3u8": ("master", None),
            "/ffmaster.m3u8": ("playlist", None),
            "/stream_video.m3u8": ("playlist", None),
            "/stream_audio.m3u8": ("playlist", None),
            "/stream_video_vtt.m3u8": ("playlist", None),
            "/init_video.mp4": ("init", None),
            "/init_audio.mp4": ("init", None),
            "/seg_video_00000.m4s": ("segment", 0),
            "/seg_video_00135.m4s": ("segment", 135),
            "/seg_audio_00000.m4s": ("audio", 0),
            "/seg_audio_00135.m4s": ("audio", 135),
            "/stream_video0.vtt": ("subtitle", 0),    # real ffmpeg naming: stream_<name><n>.vtt
            "/stream_video12.vtt": ("subtitle", 12),
            "/favicon.ico": ("other", None),
            "/seg_video_00001.m4s.tmp": ("other", None),
            "/seg_audio_00001.m4s.tmp": ("other", None),
            # The old single-rendition layout is no longer produced.
            "/init.mp4": ("other", None),
            "/init_subs.mp4": ("other", None),
            "/seg_0_00000.m4s": ("other", None),
            "/stream_00.vtt": ("other", None),
            "/stream_audio0.vtt": ("other", None),
        }
        for path, expected in cases.items():
            with self.subTest(path=path):
                self.assertEqual(classify(path), expected)


class ServerTest(unittest.TestCase):
    """One server for the class (shutdown takes ~0.5 s); fresh telemetry per test."""

    @classmethod
    def setUpClass(cls):
        cls.root = Path(tempfile.mkdtemp(prefix="jancast-test-")).resolve()
        cls.dir = cls.root / "hls"
        cls.dir.mkdir()
        (cls.dir / "master.m3u8").write_text("#EXTM3U\n")
        (cls.dir / "stream_video.m3u8").write_text(PLAYLIST)
        (cls.dir / "init_video.mp4").write_bytes(b"I" * 100)
        (cls.dir / "seg_video_00000.m4s").write_bytes(SEG0)
        (cls.dir / "seg_video_00001.m4s").write_bytes(SEG0)
        (cls.dir / "seg_video_00002.m4s").write_bytes(BIG)
        (cls.dir / "seg_video_00003.m4s").write_bytes(MEDIUM)
        (cls.dir / "stream_video0.vtt").write_text("WEBVTT\n")
        (cls.dir / "stream_audio.m3u8").write_text(AUDIO_PLAYLIST)
        (cls.dir / "init_audio.mp4").write_bytes(b"A" * 50)
        (cls.dir / "seg_audio_00000.m4s").write_bytes(AUDIO_SEG)
        (cls.root / "hls-secret.txt").write_text("secret")
        cls.srv = HLSServer(cls.dir, Telemetry())

    @classmethod
    def tearDownClass(cls):
        cls.srv.stop()
        shutil.rmtree(cls.root, ignore_errors=True)

    def setUp(self):
        self.tm = self.srv.telemetry = Telemetry()

    def conn(self):
        c = http.client.HTTPConnection("127.0.0.1", self.srv.port, timeout=5)
        self.addCleanup(c.close)
        return c

    def get(self, path, method="GET", headers=None, conn=None):
        c = conn or self.conn()
        before = len(self.tm.requests)
        c.request(method, path, headers=headers or {})
        r = c.getresponse()
        body = r.read()
        # The record is written after the response went out; wait for it so it
        # can't land in the next test's telemetry.
        self.last_request(before + 1)
        return r, body

    def last_request(self, n=1, timeout=2.0):
        """Telemetry is recorded after the response is sent - wait for it."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.tm.lock:
                if len(self.tm.requests) >= n:
                    return self.tm.requests[n - 1]
            time.sleep(0.01)
        self.fail(f"only {len(self.tm.requests)} request(s) recorded")

    def test_content_types_and_cache_control(self):
        expected = {"/master.m3u8": "application/vnd.apple.mpegurl",
                    "/stream_video.m3u8": "application/vnd.apple.mpegurl",
                    "/init_video.mp4": "video/mp4", "/seg_video_00000.m4s": "video/iso.segment",
                    "/init_audio.mp4": "video/mp4", "/seg_audio_00000.m4s": "video/iso.segment",
                    "/stream_audio.m3u8": "application/vnd.apple.mpegurl",
                    "/stream_video0.vtt": "text/vtt"}
        for path, ctype in expected.items():
            with self.subTest(path=path):
                r, body = self.get(path)
                self.assertEqual(r.status, 200)
                self.assertEqual(r.getheader("Content-Type"), ctype)
                self.assertEqual(r.getheader("Accept-Ranges"), "bytes")
                self.assertEqual(int(r.getheader("Content-Length")), len(body))
                self.assertEqual(r.getheader("Cache-Control"),
                                 "no-cache" if path.endswith(".m3u8") else None)
        self.assertEqual(body, b"WEBVTT\n")

    def test_full_segment_request_telemetry(self):
        r, body = self.get("/seg_video_00000.m4s?x=1")
        self.assertEqual(body, SEG0)
        e = self.last_request()
        self.assertEqual((e["path"], e["kind"], e["segment"], e["status"], e["bytes"]),
                         ("/seg_video_00000.m4s", "segment", 0, 200, len(SEG0)))
        self.assertIsNone(e["error"])
        self.assertEqual(e["client"], "127.0.0.1")
        self.assertGreater(e["realtime_ratio"], 6.0)      # 6 s of media in << 1 s
        self.assertIsNotNone(e["mbps"])
        self.assertGreaterEqual(e["duration_ms"], 0)
        s = self.tm.sample({})
        self.assertEqual(s["tx_bps"], len(SEG0) * 8)
        self.assertEqual(s["requests"], 1)
        self.assertEqual(self.tm.sample({})["tx_bps"], 0)   # drained

    def test_audio_segment_request_telemetry(self):
        """Audio rendition segments are recorded as their own kind, without a
        realtime ratio (that is measured on the video segments only)."""
        r, body = self.get("/seg_audio_00000.m4s")
        self.assertEqual((r.status, body), (200, AUDIO_SEG))
        e = self.last_request()
        self.assertEqual((e["path"], e["kind"], e["segment"], e["status"], e["bytes"]),
                         ("/seg_audio_00000.m4s", "audio", 0, 200, len(AUDIO_SEG)))
        self.assertIsNone(e["error"])
        self.assertIsNone(e["realtime_ratio"])
        self.assertIsNotNone(e["mbps"])
        self.assertEqual(self.tm.sample({})["tx_bps"], len(AUDIO_SEG) * 8)
        r, body = self.get("/init_audio.mp4")
        self.assertEqual((r.status, body), (200, b"A" * 50))
        self.assertEqual(self.last_request(2)["kind"], "init")

    def test_missing_audio_or_subtitle_segment_is_not_ready_404(self):
        for path, kind, index in (("/seg_audio_00009.m4s", "audio", 9),
                                  ("/stream_video5.vtt", "subtitle", 5)):
            with self.subTest(path=path):
                self.tm = self.srv.telemetry = Telemetry()
                r, body = self.get(path)
                self.assertEqual((r.status, body), (404, b""))
                e = self.last_request()
                self.assertEqual((e["kind"], e["segment"], e["error"]),
                                 (kind, index, "not ready (404)"))
                warn = [ev for ev in self.tm.events if ev["level"] == "warn"]
                self.assertEqual(len(warn), 1)
                self.assertIn(path, warn[0]["message"])
                self.assertEqual(self.tm.not_ready, 1)

    def test_realtime_ratio_uses_extinf_duration(self):
        orig = hls_server.time.monotonic
        # Make every request appear to take exactly 2 s of wall time.
        ticks = iter([100.0, 102.0, 102.0, 102.0, 102.0])
        hls_server.time.monotonic = lambda: next(ticks)
        try:
            self.get("/seg_video_00001.m4s")
            e = self.last_request()
        finally:
            hls_server.time.monotonic = orig
        self.assertEqual(e["realtime_ratio"], 2.0)          # EXTINF 4 s / 2 s
        self.assertEqual(e["duration_ms"], 2000.0)

    def test_ranges(self):
        size = len(SEG0)
        cases = [("bytes=0-99", 0, 99), ("bytes=100-", 100, size - 1),
                 ("bytes=-50", size - 50, size - 1), ("bytes=10-999999", 10, size - 1),
                 ("bytes=-999999", 0, size - 1)]
        for rng, start, end in cases:
            with self.subTest(rng=rng):
                r, body = self.get("/seg_video_00000.m4s", headers={"Range": rng})
                self.assertEqual(r.status, 206)
                self.assertEqual(r.getheader("Content-Range"), f"bytes {start}-{end}/{size}")
                self.assertEqual(body, SEG0[start:end + 1])
                self.assertEqual(int(r.getheader("Content-Length")), end - start + 1)

    def test_unsatisfiable_range_is_416(self):
        # Regression: start beyond EOF produced a negative Content-Length.
        size = len(SEG0)
        for rng in (f"bytes={size}-", f"bytes={size + 500}-{size + 600}", "bytes=50-10",
                    "bytes=-0"):
            with self.subTest(rng=rng):
                c = self.conn()
                r, body = self.get("/seg_video_00000.m4s", headers={"Range": rng}, conn=c)
                self.assertEqual(r.status, 416)
                self.assertEqual(r.getheader("Content-Range"), f"bytes */{size}")
                self.assertEqual(body, b"")
                # Connection still usable afterwards.
                r2, _ = self.get("/init_video.mp4", conn=c)
                self.assertEqual(r2.status, 200)

    def test_partial_and_head_do_not_fake_realtime_ratio(self):
        # Regression: HEAD (0 bytes) and small ranges were credited with the
        # full segment's media duration -> huge ratios -> "network is fine".
        orig = hls_server.time.monotonic
        ticks = iter([0.0, 1.0, 1.0, 1.0, 1.0])
        hls_server.time.monotonic = lambda: next(ticks)
        try:
            self.get("/seg_video_00000.m4s", headers={"Range": f"bytes=0-{len(SEG0) // 2 - 1}"})
            e = self.last_request()
        finally:
            hls_server.time.monotonic = orig
        self.assertEqual(e["status"], 206)
        self.assertEqual(e["realtime_ratio"], 3.0)           # half of 6 s in 1 s
        self.get("/seg_video_00000.m4s", method="HEAD")
        self.assertIsNone(self.last_request(2)["realtime_ratio"])

    def test_head_has_no_body(self):
        c = self.conn()
        c.request("HEAD", "/seg_video_00000.m4s")
        r = c.getresponse()
        self.assertEqual(r.status, 200)
        self.assertEqual(int(r.getheader("Content-Length")), len(SEG0))
        self.assertEqual(r.read(), b"")
        # Same connection: if the server had sent a body, this response would be garbage.
        r2, body = self.get("/init_video.mp4", conn=c)
        self.assertEqual((r2.status, body), (200, b"I" * 100))
        e = self.last_request()
        self.assertEqual(e["bytes"], 0)

    def test_keep_alive(self):
        c = self.conn()
        r1, b1 = self.get("/master.m3u8", conn=c)
        sock = c.sock
        r2, b2 = self.get("/seg_video_00000.m4s", conn=c)
        self.assertIs(c.sock, sock, "connection was not reused")
        self.assertEqual((r1.status, r2.status), (200, 200))
        self.assertEqual(b2, SEG0)

    def test_missing_segment_is_not_ready_404(self):
        r, body = self.get("/seg_video_00007.m4s")
        self.assertEqual((r.status, body), (404, b""))
        e = self.last_request()
        self.assertEqual((e["status"], e["kind"], e["segment"], e["error"]),
                         (404, "segment", 7, "not ready (404)"))
        warn = [ev for ev in self.tm.events if ev["level"] == "warn" and ev["source"] == "http"]
        self.assertEqual(len(warn), 1)
        self.assertIn("/seg_video_00007.m4s", warn[0]["message"])
        self.assertEqual(self.tm.not_ready, 1)

    def test_missing_other_is_plain_not_found(self):
        r, _ = self.get("/favicon.ico")
        self.assertEqual(r.status, 404)
        self.assertEqual(self.last_request()["error"], "not found")
        self.assertEqual(list(self.tm.events), [])

    def test_path_traversal_refused(self):
        secret = "hls-secret.txt"
        paths = ["/../etc/passwd", "/../" + secret, "/%2e%2e/" + secret, "/%2E%2E%2F" + secret,
                 "/..%2f" + secret, "/./../" + secret, "//etc/passwd", "/", "/.",
                 "/seg_video_00000.m4s/../../" + secret]
        for path in paths:
            with self.subTest(path=path):
                r, body = self.get(path)
                self.assertEqual(r.status, 404)
                self.assertNotIn(b"secret", body)
        # Raw request line (http.client would refuse to send these).
        for raw in (b"GET /../../../../etc/passwd HTTP/1.1\r\nHost: x\r\n\r\n",
                    b"GET /a%00b HTTP/1.1\r\nHost: x\r\n\r\n"):
            with self.subTest(raw=raw):
                with socket.create_connection(("127.0.0.1", self.srv.port), 5) as s:
                    s.sendall(raw)
                    resp = s.recv(4096)
                self.assertTrue(resp.startswith(b"HTTP/1.1 404"), resp[:40])

    def test_percent_encoded_names_are_decoded(self):
        r, body = self.get("/seg%5Fvideo_00000.m4s")
        self.assertEqual((r.status, body), (200, SEG0))
        self.assertEqual(self.last_request()["kind"], "segment")

    def test_client_abort_recorded(self):
        s = socket.create_connection(("127.0.0.1", self.srv.port), 5)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        s.sendall(b"GET /seg_video_00002.m4s HTTP/1.1\r\nHost: x\r\n\r\n")
        s.recv(1024)
        # RST instead of FIN, like a player dropping a transfer.
        s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, b"\1\0\0\0\0\0\0\0")
        s.close()
        e = self.last_request(timeout=5)
        self.assertEqual(e["error"], "client aborted")
        self.assertLess(e["bytes"], len(BIG))
        self.assertIsNone(e["realtime_ratio"])
        self.assertEqual(self.tm.client_aborts, 1)
        self.assertEqual(self.tm.network_summary()["client_aborts"], 1)
        # The server keeps serving afterwards.
        r, _ = self.get("/init_video.mp4")
        self.assertEqual(r.status, 200)

    # ---- transfer timing = delivery, not kernel acceptance ---------------

    def test_send_buffer_capped(self):
        seen = []
        orig = self.srv.get_request

        def spy():
            sock, addr = orig()
            seen.append(sock.getsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF))
            return sock, addr
        self.srv.get_request = spy
        try:
            self.get("/init_video.mp4")
        finally:
            del self.srv.get_request
        self.assertEqual(len(seen), 1)
        # Linux reports twice the requested value; macOS autotunes to MBs if unset.
        self.assertLessEqual(seen[0], 2 * hls_server.SNDBUF)

    def test_drain_wait_only_for_large_bodies(self):
        calls = []
        orig = hls_server.wait_drained

        def spy(sock, *a, **kw):
            calls.append(len(self.tm.requests))      # nothing recorded yet?
            return orig(sock, *a, **kw)
        hls_server.wait_drained = spy
        try:
            c = self.conn()
            self.get("/stream_video.m3u8", conn=c)
            self.get("/seg_video_00000.m4s", conn=c)      # 10 KB: below DRAIN_MIN_BYTES
            self.get("/seg_video_00000.m4s", method="HEAD", conn=c)
            self.assertEqual(calls, [])
            r, body = self.get("/seg_video_00003.m4s", conn=c)
            self.assertEqual(body, MEDIUM)
            r2, _ = self.get("/init_video.mp4", conn=c)     # keep-alive survives the wait
            self.assertEqual(r2.status, 200)
        finally:
            hls_server.wait_drained = orig
        self.assertEqual(calls, [3])                  # waited before recording the 4th
        self.assertEqual(self.last_request(5)["path"], "/init_video.mp4")

    @unittest.skipUnless(CAN_MEASURE_QUEUE, "no send-queue query on this platform")
    def test_slow_reader_duration_reflects_delivery(self):
        """Regression: elapsed was taken when the last chunk entered the (MB-sized,
        autotuned) send buffer, so a slow link looked fast."""
        s = socket.create_connection(("127.0.0.1", self.srv.port), 5)
        self.addCleanup(s.close)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 64 * 1024)
        t0 = time.monotonic()
        s.sendall(b"GET /seg_video_00003.m4s HTTP/1.1\r\nHost: x\r\n\r\n")
        got = 0
        while got < len(MEDIUM):
            chunk = s.recv(32 * 1024)
            self.assertTrue(chunk)
            got += len(chunk)
            time.sleep(0.01)                          # ~3 MB/s reader
        client_s = time.monotonic() - t0
        e = self.last_request(timeout=5)
        self.assertEqual(e["bytes"], len(MEDIUM))
        self.assertIsNone(e["error"])
        # Delivered = in the client's receive buffer (~0.5 MB on loopback even
        # with SO_RCVBUF 64 KB), so the server finishes ~75 % into the client's
        # read; before the fix (1 MB+ autotuned send buffer, no drain) ~50 %.
        self.assertGreater(e["duration_ms"] / 1000, 0.65 * client_s,
                           (e["duration_ms"], client_s))

    @unittest.skipUnless(CAN_MEASURE_QUEUE, "no send-queue query on this platform")
    def test_wait_drained(self):
        ls = socket.create_server(("127.0.0.1", 0))
        self.addCleanup(ls.close)
        c = socket.create_connection(ls.getsockname(), 5)
        self.addCleanup(c.close)
        sv, _ = ls.accept()
        self.addCleanup(sv.close)
        self.assertEqual(unsent_bytes(sv), 0)
        self.assertTrue(wait_drained(sv, timeout=0.5))
        sv.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 64 * 1024)
        sv.setblocking(False)
        # Fill our send buffer *and* the client's (autotuning) receive buffer.
        sent, stuck = 0, 0
        while stuck < 3 and sent < 64 * 1024 * 1024:
            try:
                sent += sv.send(b"x" * 65536)
                stuck = 0
            except BlockingIOError:
                stuck += 1
                time.sleep(0.05)
        self.assertGreater(unsent_bytes(sv), 0)
        self.assertFalse(wait_drained(sv, timeout=0.05))     # client isn't reading

        def drain():
            n = 0
            while n < sent:
                n += len(c.recv(65536))
        t = threading.Thread(target=drain)
        t.start()
        self.assertTrue(wait_drained(sv, timeout=5))
        t.join(5)
        self.assertEqual(unsent_bytes(sv), 0)
        sv.close()
        self.assertIsNone(wait_drained(sv, timeout=0.05))    # closed: give up at once

    # ---- idle keep-alive resets ------------------------------------------

    def test_idle_connection_reset_is_quiet(self):
        """Regression: a player resetting an idle keep-alive connection made the
        request-line readline raise ConnectionResetError -> socketserver traceback."""
        ls = socket.create_server(("127.0.0.1", 0))
        self.addCleanup(ls.close)
        c = socket.create_connection(ls.getsockname(), 5)
        sv, addr = ls.accept()
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            # The server's own per-connection code path, run on our socket.
            t = threading.Thread(target=self.srv.process_request_thread, args=(sv, addr))
            t.start()
            c.sendall(b"GET /init_video.mp4 HTTP/1.1\r\nHost: x\r\n\r\n")
            resp = b""
            while not resp.endswith(b"I" * 100):
                resp += c.recv(4096)
            self.last_request()                       # served and recorded
            time.sleep(0.05)                          # server is back in readline
            c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            c.close()                                 # RST
            t.join(5)
        self.assertFalse(t.is_alive())
        self.assertEqual(err.getvalue(), "")
        self.assertEqual(len(self.tm.requests), 1)    # no record for the reset
        self.assertEqual(self.tm.client_aborts, 0)

    def test_other_handler_errors_still_reported(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            try:
                raise ValueError("boom")
            except ValueError:
                self.srv.handle_error(None, ("192.0.2.1", 1))
            try:
                raise ConnectionResetError("reset")
            except ConnectionResetError:
                self.srv.handle_error(None, ("192.0.2.1", 1))
        self.assertIn("ValueError: boom", err.getvalue())
        self.assertNotIn("reset", err.getvalue())


class _CountingEntry:
    def __init__(self, entry, counter):
        self._e, self._c = entry, counter
        self.name = entry.name

    def inode(self):
        return self._e.inode()

    def stat(self, **kw):
        self._c.append(self.name)
        return self._e.stat(**kw)


class DirectoryBitrateTest(TempDirMixin, unittest.TestCase):
    def test_bitrate(self):
        d = self.make_tempdir()
        self.assertIsNone(directory_bitrate(d, 0))
        self.assertIsNone(directory_bitrate(d, 10))
        (d / "seg_video_00000.m4s").write_bytes(b"x" * 1000)
        (d / "seg_video_00001.m4s").write_bytes(b"x" * 1500)
        (d / "seg_video_00002.m4s.tmp").write_bytes(b"x" * 99999)   # being written
        (d / "init_video.mp4").write_bytes(b"x" * 99999)
        self.assertEqual(directory_bitrate(d, 10.0), 2000)
        self.assertIsNone(directory_bitrate(d, None))
        self.assertEqual(directory_bitrate(str(d), 10.0), 2000)     # str path too
        # The audio rendition's segments are part of the stream bitrate.
        (d / "seg_audio_00000.m4s").write_bytes(b"x" * 250)
        (d / "seg_audio_00001.m4s").write_bytes(b"x" * 250)
        (d / "init_audio.mp4").write_bytes(b"x" * 99999)
        self.assertEqual(directory_bitrate(d, 10.0), 2400)
        self.assertIsNone(directory_bitrate(d / "missing", 10.0))

    def counting_scandir(self):
        stats = []
        orig = os.scandir

        @contextlib.contextmanager
        def scandir(path):
            with orig(path) as it:
                yield (_CountingEntry(e, stats) for e in it)
        hls_server.os.scandir = scandir
        self.addCleanup(setattr, hls_server.os, "scandir", orig)
        return stats

    def test_incremental_stats_only_new_segments(self):
        """Regression: every 1 Hz sample stat'ed every segment (~2000/s for 3 h)."""
        d = self.make_tempdir()
        for i in range(50):
            (d / f"seg_video_{i:05d}.m4s").write_bytes(b"x" * 100)
        stats = self.counting_scandir()
        tracker = DirectoryBitrate(d)
        self.assertEqual(tracker.bitrate(10.0), 50 * 100 * 8 // 10)
        self.assertEqual(len(stats), 50)
        stats.clear()
        self.assertEqual(tracker.bitrate(20.0), 50 * 100 * 8 // 20)
        self.assertEqual(stats, [])                    # nothing new: no stat at all
        (d / "seg_video_00050.m4s").write_bytes(b"x" * 900)
        (d / "seg_video_00051.m4s.tmp").write_bytes(b"x" * 999)
        self.assertEqual(tracker.bitrate(10.0), (5000 + 900) * 8 // 10)
        self.assertEqual(stats, ["seg_video_00050.m4s"])

    def test_incremental_handles_removed_and_replaced_files(self):
        d = self.make_tempdir()
        (d / "seg_video_00000.m4s").write_bytes(b"x" * 1000)
        (d / "seg_video_00001.m4s").write_bytes(b"x" * 1000)
        tracker = DirectoryBitrate(d)
        self.assertEqual(tracker.bitrate(8.0), 2000)
        (d / "seg_video_00001.m4s").unlink()
        self.assertEqual(tracker.bitrate(8.0), 1000)
        # Replaced via rename (new inode), as ffmpeg's temp_file does.
        (d / "new.tmp").write_bytes(b"x" * 3000)
        os.replace(d / "new.tmp", d / "seg_video_00000.m4s")
        self.assertEqual(tracker.bitrate(8.0), 3000)
        (d / "seg_video_00000.m4s").unlink()
        self.assertIsNone(tracker.bitrate(8.0))

    def test_module_function_reuses_tracker(self):
        d = self.make_tempdir()
        for i in range(5):
            (d / f"seg_video_{i:05d}.m4s").write_bytes(b"x" * 100)
        stats = self.counting_scandir()
        self.assertEqual(directory_bitrate(d, 1.0), 4000)
        self.assertEqual(directory_bitrate(d, 1.0), 4000)
        self.assertEqual(len(stats), 5)


if __name__ == "__main__":
    unittest.main()
