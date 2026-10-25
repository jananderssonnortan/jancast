"""api.py: routing, JSON errors, and the /api/state + /api/probe shapes vs docs/API.md.

The JSON examples in docs/API.md are parsed and used as the schema, so a field
renamed on either side shows up here. Devices/session are stubbed: no network.
"""

import http.client
import http.server
import json
import os
import re
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

from helpers import (StubConf, TempDirMixin, audio_stream, make_media, sub_stream,
                     video_stream)
from jancast import api
from jancast.local_player import LocalDevice, LocalPlayer
from jancast.session import Session

DOCS = Path(__file__).resolve().parent.parent / "docs" / "API.md"


def doc_examples():
    """{name: parsed example} for the JSON blocks in docs/API.md."""
    found = {}
    for block in re.findall(r"```json\n(.*?)```", DOCS.read_text(), re.S):
        block = re.sub(r"/\*.*?\*/", "", block)
        block = re.sub(r"(?<=[\s,])//[^\n]*", "", block)       # not the // in http://
        data = json.loads(block)
        for key, name in (("default_audio", "probe"), ("scanning", "devices"),
                          ("diagnosis", "state"), ("tx_bps", "sample"),
                          ("realtime_ratio", "request"), ("level", "event"),
                          ("interval_s", "thumbs"), ("commands", "local_player")):
            if key in data:
                found[name] = data
    return found


def shape_errors(doc, actual, path="$"):
    """Differences in keys/types between a documented example and real output.
    null in the docs matches anything; any value may be null at runtime."""
    errors = []
    if doc is None or actual is None:
        return errors
    if isinstance(doc, dict):
        if not isinstance(actual, dict):
            return [f"{path}: expected object, got {type(actual).__name__}"]
        for k in sorted(set(doc) - set(actual)):
            errors.append(f"{path}.{k}: documented but missing")
        for k in sorted(set(actual) - set(doc)):
            errors.append(f"{path}.{k}: returned but undocumented")
        for k in set(doc) & set(actual):
            errors += shape_errors(doc[k], actual[k], f"{path}.{k}")
    elif isinstance(doc, list):
        if not isinstance(actual, list):
            return [f"{path}: expected array, got {type(actual).__name__}"]
        if doc and actual:
            for i, item in enumerate(actual):
                errors += shape_errors(doc[0], item, f"{path}[{i}]")
    elif isinstance(doc, bool):
        if not isinstance(actual, bool):
            errors.append(f"{path}: expected bool, got {actual!r}")
    elif isinstance(doc, (int, float)):
        if isinstance(actual, bool) or not isinstance(actual, (int, float)):
            errors.append(f"{path}: expected number, got {actual!r}")
    elif isinstance(doc, str):
        if not isinstance(actual, str):
            errors.append(f"{path}: expected string, got {actual!r}")
    return errors


class StubDevices:
    def __init__(self):
        self.conf = StubConf()
        self.devices = {self.conf.identifier: self.conf}
        self.scanning = False
        self.pairing_state = None
        self.calls = []

    def get(self, device_id):
        return self.devices.get(device_id)

    def needs_pairing(self, conf):
        return True

    def to_json(self, conf):
        return {"id": conf.identifier, "name": conf.name}

    def list_json(self):
        return [self.to_json(c) for c in self.devices.values()]

    async def scan(self, *a, **kw):
        self.calls.append("scan")

    async def probe(self):
        self.calls.append("probe")

    class reach:
        known = {"GONE": {"name": "Bedroom"}}

    async def pair_begin(self, device_id):
        raise RuntimeError("TV said no")

    async def pair_finish(self, pin):
        self.calls.append(("pin", pin))
        raise RuntimeError("wrong PIN")


class StubSession:
    def __init__(self):
        self.calls = []

    async def pause(self):
        self.calls.append("pause")

    async def resume(self):
        raise RuntimeError("Apple TV answered 500 to /rate?value=1.000000")

    async def stop(self):
        self.calls.append("stop")

    async def seek(self, position):
        self.calls.append(("seek", position))

    async def volume(self, step=None, level=None):
        self.calls.append(("volume", step, level))

    async def skip(self, seconds):
        if seconds == 999:
            raise RuntimeError("nothing is playing")
        self.calls.append(("skip", seconds))

    def state_json(self):
        return {"phase": "playing"}


class ApiTest(TempDirMixin, unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.controller = api.Controller()
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), api.ApiHandler)
        cls.server.daemon_threads = True
        cls.server.controller = cls.controller
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.controller.loop.call_soon_threadsafe(cls.controller.loop.stop)

    def setUp(self):
        c = self.controller
        c.devices = StubDevices()
        c.session = None
        c.media_cache = {}
        c.telemetry = api.Telemetry()
        c.thumbs = api.ThumbnailStore()     # the per-run test cache dir (see helpers)
        self.addCleanup(c.thumbs.stop_all)

    def request(self, method, path, body=None, raw=None, conn=None):
        c = conn or http.client.HTTPConnection("127.0.0.1", self.server.server_address[1],
                                               timeout=10)
        if conn is None:
            self.addCleanup(c.close)
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None
                                            else None)
        c.request(method, path, body=data,
                  headers={"Content-Type": "application/json"} if data is not None else {})
        r = c.getresponse()
        payload = r.read()
        self.assertEqual(r.getheader("Content-Type"), "application/json")
        return r.status, json.loads(payload)

    # ---- routing / errors ------------------------------------------------

    def test_health(self):
        self.assertEqual(self.request("GET", "/api/health"),
                         (200, {"ok": True, "version": api.__version__, "missing_tools": []}))

    def test_tools_found_with_finder_path(self):
        """Apps started from Finder get a minimal PATH without Homebrew."""
        from jancast.config import ensure_tool_path
        with mock.patch.dict("os.environ", {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}):
            self.assertEqual(ensure_tool_path(), [])

    def test_unknown_routes(self):
        for method in ("GET", "POST"):
            with self.subTest(method=method):
                self.assertEqual(self.request(method, "/api/nope", body={} if method == "POST"
                                              else None),
                                 (404, {"ok": False, "error": "not found"}))
        self.assertEqual(self.request("GET", "/api/play")[0], 404)       # POST-only route

    def test_invalid_json(self):
        self.assertEqual(self.request("POST", "/api/control", raw=b"{not json"),
                         (400, {"ok": False, "error": "invalid JSON"}))

    def test_empty_body_is_empty_object(self):
        status, body = self.request("POST", "/api/control", raw=b"")
        self.assertEqual((status, body), (400, {"ok": False, "error": "nothing is playing"}))

    def test_api_error_is_400_json(self):
        status, body = self.request("POST", "/api/play", {"path": "/nonexistent/x.mkv"})
        self.assertEqual(status, 400)
        self.assertFalse(body["ok"])
        self.assertIn("no such file", body["error"])

    def test_play_validation(self):
        d = self.make_tempdir()
        media = make_media(d, [video_stream(0), audio_stream(1), sub_stream(2)])
        self.controller.media_cache[str(media.path)] = media
        cases = [({"audio": 5}, "invalid track selection"),
                 ({"subtitle": 9}, "invalid track selection"),
                 ({"audio": "x"}, "invalid track selection"),
                 ({"device_id": "nope"}, "unknown device"),
                 ({"device_id": "GONE"}, "Bedroom is offline"),
                 ({"start_position": "soon"}, "start_position must be a number"),
                 ({"device_id": StubConf.identifier}, "must be paired first")]
        for extra, error in cases:
            with self.subTest(extra=extra):
                status, body = self.request("POST", "/api/play",
                                            {"path": str(media.path), **extra})
                self.assertEqual(status, 400)
                self.assertIn(error, body["error"])
        self.assertIsNone(self.controller.session)

    def test_local_only_mode_refuses_real_devices(self):
        d = self.make_tempdir()
        media = make_media(d, [video_stream(0), audio_stream(1)])
        self.controller.media_cache[str(media.path)] = media
        with mock.patch.dict(os.environ, {"JANCAST_LOCAL_ONLY": "1"}):
            status, body = self.request("POST", "/api/play",
                                        {"path": str(media.path), "device_id": StubConf.identifier})
        self.assertEqual(status, 400)
        self.assertIn("local-only mode", body["error"])
        self.assertIsNone(self.controller.session)

    def test_pairing(self):
        status, body = self.request("POST", "/api/pair", {"device_id": "x"})
        self.assertEqual(status, 400)
        self.assertIn("could not start pairing: TV said no", body["error"])
        self.assertEqual(self.request("POST", "/api/pair/pin", {"pin": 1234}),
                         (200, {"ok": False, "error": "wrong PIN"}))
        self.assertEqual(self.controller.devices.calls, [("pin", "1234")])

    def test_devices_uses_cache_unless_refresh(self):
        status, body = self.request("GET", "/api/devices")
        self.assertEqual(status, 200)
        self.assertEqual(self.controller.devices.calls, [])
        self.assertEqual(body["devices"][0]["id"], StubConf.identifier)
        self.request("GET", "/api/devices?refresh=1")
        self.assertEqual(self.controller.devices.calls, ["scan"])
        self.request("GET", "/api/devices?probe=1")
        self.assertEqual(self.controller.devices.calls, ["scan", "probe"])

    def test_telemetry_level(self):
        self.assertEqual(self.request("GET", "/api/state")[1]["telemetry_level"], "basic")
        self.assertEqual(self.request("POST", "/api/telemetry", {"level": "detailed"}),
                         (200, {"ok": True}))
        self.assertEqual(self.request("GET", "/api/state")[1]["telemetry_level"], "detailed")
        status, body = self.request("POST", "/api/telemetry", {"level": "verbose"})
        self.assertEqual(status, 400)

    def test_control(self):
        self.assertEqual(self.request("POST", "/api/control", {"action": "pause"}),
                         (400, {"ok": False, "error": "nothing is playing"}))
        s = self.controller.session = StubSession()
        self.assertEqual(self.request("POST", "/api/control", {"action": "pause"}),
                         (200, {"ok": True}))
        self.assertEqual(self.request("POST", "/api/control",
                                      {"action": "seek", "position": 12.5}), (200, {"ok": True}))
        self.assertEqual(self.request("POST", "/api/control",
                                      {"action": "skip", "seconds": -10}), (200, {"ok": True}))
        self.assertEqual(self.request("POST", "/api/control",
                                      {"action": "skip", "seconds": 30}), (200, {"ok": True}))
        self.assertEqual(self.request("POST", "/api/control", {"action": "skip"}),
                         (200, {"ok": True}))                   # seconds default to 0
        self.assertEqual(self.request("POST", "/api/control",
                                      {"action": "skip", "seconds": 999}),
                         (200, {"ok": False, "error": "nothing is playing"}))
        self.assertEqual(self.request("POST", "/api/control", {"action": "volume", "step": "up"}),
                         (200, {"ok": True}))
        self.assertEqual(self.request("POST", "/api/control", {"action": "stop"}),
                         (200, {"ok": True}))
        self.assertEqual(s.calls, ["pause", ("seek", 12.5), ("skip", -10), ("skip", 30),
                                   ("skip", 0), ("volume", "up", None), "stop"])
        self.assertEqual(self.request("POST", "/api/control", {"action": "resume"}),
                         (200, {"ok": False,
                                "error": "Apple TV answered 500 to /rate?value=1.000000"}))
        status, body = self.request("POST", "/api/control", {"action": "jump"})
        self.assertEqual((status, body["error"]), (400, "unknown action 'jump'"))

    def test_keep_alive(self):
        c = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=5)
        self.addCleanup(c.close)
        self.request("GET", "/api/health", conn=c)
        sock = c.sock
        self.request("POST", "/api/control", {"action": "x"}, conn=c)
        self.request("GET", "/api/state", conn=c)
        self.assertIs(c.sock, sock)

    def test_bad_since_is_400(self):
        """Regression: a non-numeric since used to raise ValueError -> 500."""
        with mock.patch("traceback.print_exc"):
            self.assertEqual(self.request("GET", "/api/state?since=abc")[0], 400)

    def test_non_object_body_is_400(self):
        """Regression: a JSON body that is not an object (e.g. []) used to raise
        AttributeError on body.get -> 500."""
        with mock.patch("traceback.print_exc"):
            self.assertEqual(self.request("POST", "/api/pair", raw=b"[]")[0], 400)

    # ---- /api/state ------------------------------------------------------

    def test_idle_state(self):
        status, st = self.request("GET", "/api/state")
        self.assertEqual(status, 200)
        doc = doc_examples()["state"]
        self.assertEqual(set(st), set(doc))
        self.assertEqual((st["phase"], st["session"], st["pairing"]), ("idle", None, None))
        self.assertEqual(st["diagnosis"]["status"], "unknown")
        self.assertEqual(shape_errors(doc, st), [])
        # Documented: with no session, prep/playback/network are null too.
        self.assertEqual((st["prep"], st["playback"], st["network"]), (None, None, None))

    def make_live_session(self):
        tm = self.controller.telemetry
        d = self.make_tempdir()
        media = make_media(d, [video_stream(0, width=1920, height=960),
                               audio_stream(1, "eac3", 6, default=True),
                               sub_stream(2, "subrip", "swe", "Svenska")], duration=3011.4)
        s = Session(tm, self.controller.devices, media, media.audio[0], media.subs[0],
                    StubConf())
        s.phase = "buffering"
        for i in range(4):
            s._on_playback_info({"position": 800.0 + i, "duration": 3011.4, "rate": 1.0,
                                 "readyToPlay": True, "playbackBufferEmpty": False,
                                 "playbackBufferFull": False, "playbackLikelyToKeepUp": True,
                                 "loadedTimeRanges": [{"start": 0.0, "duration": 860.0}]})
        tm.rtt(4.1)
        tm.request({"t": time.time(), "path": "/seg_video_00135.m4s", "kind": "segment",
                    "segment": 135, "status": 200, "bytes": 7840211, "duration_ms": 290.0,
                    "mbps": 216.3, "realtime_ratio": 20.7, "client": "192.0.2.20",
                    "error": None})
        tm.add_tx_bytes(1000)
        s._take_sample(d)          # the real 1 Hz sample, with no transcoder yet
        return s

    def test_live_state_matches_docs(self):
        self.controller.session = self.make_live_session()
        status, st = self.request("GET", "/api/state?since=0")
        self.assertEqual(status, 200)
        docs = doc_examples()
        errors = shape_errors(docs["state"], st)
        for item in st["samples"]:
            errors += shape_errors(docs["sample"], item, "$.samples[]")
        for item in st["requests"]:
            errors += shape_errors(docs["request"], item, "$.requests[]")
        for item in st["events"]:
            errors += shape_errors(docs["event"], item, "$.events[]")
        self.assertEqual(errors, [])
        self.assertEqual(st["phase"], "playing")
        self.assertTrue(st["samples"] and st["requests"] and st["events"])
        self.assertEqual(st["playback"]["buffered_ahead_s"], 57.0)
        self.assertEqual(st["session"]["subtitle"]["mode"], "soft")
        self.assertEqual(st["seq"], self.controller.telemetry.seq)
        for e in st["events"]:
            self.assertIn(e["level"], ("info", "warn", "error"))
            self.assertIn(e["source"], ("app", "ffmpeg", "http", "airplay", "network"))
        self.assertIn(st["diagnosis"]["status"], ("ok", "warning", "failing", "failed",
                                                  "unknown"))
        for s in st["diagnosis"]["suspects"]:
            self.assertIn(s["cause"], ("network", "encoder", "device", "source", "server"))

    def test_state_since_is_incremental(self):
        self.controller.session = self.make_live_session()
        _, first = self.request("GET", "/api/state")
        _, again = self.request("GET", f"/api/state?since={first['seq']}")
        self.assertEqual((again["samples"], again["requests"], again["events"]), ([], [], []))
        self.controller.telemetry.event("warn", "network", "Latency probe to Apple TV timed out")
        _, nxt = self.request("GET", f"/api/state?since={first['seq']}")
        self.assertEqual([e["message"] for e in nxt["events"]],
                         ["Latency probe to Apple TV timed out"])
        self.assertGreater(nxt["seq"], first["seq"])

    def test_state_seq_never_skips_items(self):
        """Regression: the collections and seq must be read atomically. Another
        thread producing an event right after the collections were read must
        not get a seq <= the returned one (the poller would never see it)."""
        tm = self.controller.telemetry
        real_since = tm.since
        producers = []

        def since_then_concurrent_event(seq):
            result = real_since(seq)
            t = threading.Thread(target=tm.event,
                                 args=("warn", "http", "produced by another thread meanwhile"))
            t.start()
            t.join(0.2)     # blocks on the telemetry lock if seq is read atomically
            producers.append(t)
            return result

        with mock.patch.object(tm, "since", since_then_concurrent_event):
            _, st = self.request("GET", "/api/state")
        for t in producers:
            t.join(5)
        _, nxt = self.request("GET", f"/api/state?since={st['seq']}")
        got = [e["message"] for e in st["events"] + nxt["events"]]
        self.assertIn("produced by another thread meanwhile", got)

    # ---- /api/probe ------------------------------------------------------

    def test_probe_matches_docs(self):
        d = self.make_tempdir()
        (d / "movie.en.srt").write_text("")
        media = make_media(d, [video_stream(0, "av1", 1920, 960),
                               audio_stream(1, "eac3", 6, default=True),
                               audio_stream(2, "dts", 6, "swe"),
                               sub_stream(3, "subrip", title="English"),
                               sub_stream(4, "hdmv_pgs_subtitle", forced=True)])
        with mock.patch.object(api, "probe", return_value=media), \
                mock.patch("jancast.media.shutil.which", return_value=None):    # no OCR
            status, body = self.request("GET", "/api/probe?path=" + str(media.path))
        self.assertEqual(status, 200)
        self.assertEqual(shape_errors(doc_examples()["probe"], body), [])
        self.assertEqual((body["video"]["mode"], body["default_audio"], body["default_subtitle"]),
                         ("reencode", 1, 2))
        self.assertEqual([a["mode"] for a in body["audio"]], ["copy", "transcode"])
        self.assertEqual([(s["id"], s["mode"], s["external"]) for s in body["subtitles"]],
                         [(1, "soft", False), (2, "burn", False), (3, "soft", True)])
        self.assertIn(str(media.path), self.controller.media_cache)
        # With OCR available the picture subtitles are offered as text instead.
        self.controller.media_cache = {}
        with mock.patch.object(api, "probe", return_value=media), \
                mock.patch("jancast.media.shutil.which", return_value="/usr/bin/swiftc"):
            _, body = self.request("GET", "/api/probe?path=" + str(media.path))
        self.assertEqual(body["subtitles"][1]["mode"], "ocr")
        self.assertEqual(body["video"]["mode"], "reencode")     # AV1 here; PGS no longer forces it


class ThumbsAndNextTest(ApiTest):
    def store(self):
        st = api.ThumbnailStore(self.make_tempdir())
        self.addCleanup(st.stop_all)        # runs before the folder is removed
        return st

    def test_thumbs_info_and_files(self):
        d = self.make_tempdir()
        media = make_media(d, [video_stream(0), audio_stream(1)], name="Show.S01E01.mkv",
                           duration=95)
        (d / "Show.S01E02.mkv").write_bytes(b"x")
        store = self.store()
        self.controller.thumbs = store
        key = store.key(media)
        out = store.root / key
        out.mkdir(parents=True)
        (out / "00001.jpg").write_bytes(b"\xff\xd8jpeg")
        (out / api.thumbs_module.DONE_FILE).write_text('{"count": 1}')
        with mock.patch.object(api, "probe", return_value=media):
            status, body = self.request("GET", "/api/probe?path=" + str(media.path))
            self.assertEqual(body["next"]["name"], "Show.S01E02.mkv")
            self.assertEqual(body["name_info"]["title"], "Show S1 · E1")
            self.assertEqual(body["next"]["name_info"]["title"], "Show S1 · E2")
            self.assertEqual(shape_errors(doc_examples()["probe"], body), [])
            status, info = self.request("GET", "/api/thumbs?path=" + str(media.path))
        self.assertEqual(status, 200)
        self.assertEqual(shape_errors(doc_examples()["thumbs"], info), [])
        self.assertEqual((info["url"], info["count"], info["done"]),
                         (f"/api/thumbs/{key}/", 1, True))

        c = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=10)
        self.addCleanup(c.close)
        c.request("GET", info["url"] + "1.jpg")
        r = c.getresponse()
        self.assertEqual((r.status, r.getheader("Content-Type"), r.read()),
                         (200, "image/jpeg", b"\xff\xd8jpeg"))
        status, body = self.request("GET", info["url"] + "2.jpg")
        self.assertEqual(status, 404)
        status, body = self.request("GET", "/api/thumbs/../../etc/1.jpg")
        self.assertEqual(status, 404)

    def test_opened_files_are_recent_but_lookups_are_not(self):
        d = self.make_tempdir()
        a = make_media(d, [video_stream(0), audio_stream(1)], name="a.mkv")
        b = make_media(d, [video_stream(0), audio_stream(1)], name="b.mkv")
        self.controller.thumbs = self.store()
        api.history.record(a.path, position=600, duration=1200, audio=2, subtitle=1,
                           device_id="X")
        with mock.patch.object(api, "probe", side_effect=lambda p: {str(a.path): a, str(b.path): b}[p]):
            self.request("GET", "/api/probe?path=" + str(b.path))
            self.request("GET", "/api/probe?path=" + str(a.path))
            names = [e["name"] for e in self.request("GET", "/api/recent")[1]["items"]]
            self.assertEqual(names[:2], ["b.mkv", "a.mkv"])
            # b is new, so it goes on top; a was already listed and keeps its
            # place (Recents moves on playing, not on opening), and its saved
            # position and tracks.
            entry = next(e for e in self.request("GET", "/api/recent")[1]["items"] if e["name"] == "a.mkv")
            self.assertEqual((entry["resume_position"], entry["audio"]), (600, 2))
            self.assertEqual((entry["name_info"]["title"], entry["name_info"]["kind"]), ("A", "movie"))
            # Poster lookups (make=0) neither reorder Recents nor start ffmpeg.
            self.controller.media_cache = {}
            self.controller.thumbs = self.store()
            status, info = self.request("GET", "/api/thumbs?make=0&path=" + str(b.path))
            self.assertEqual((status, info["count"], info["done"]), (200, 0, False))
            self.assertEqual(self.controller.thumbs.jobs, {})
            names = [e["name"] for e in self.request("GET", "/api/recent")[1]["items"]]
            self.assertEqual(names[:2], ["b.mkv", "a.mkv"])
            # remember=0 probes don't either.
            self.request("GET", "/api/probe?remember=0&path=" + str(b.path))
            names = [e["name"] for e in self.request("GET", "/api/recent")[1]["items"]]
            self.assertEqual(names[:2], ["b.mkv", "a.mkv"])

    def test_thumbs_unknown_file(self):
        status, body = self.request("GET", "/api/thumbs?path=/nonexistent.mkv")
        self.assertEqual(status, 400)

    def test_download_completes(self):
        d = self.make_tempdir()
        part = make_media(d, [video_stream(0), audio_stream(1)], name="Show.S01E01.mkv.part")
        old = str(part.path)
        self.controller.thumbs = self.store()
        with mock.patch.object(api, "probe", return_value=part):
            self.request("GET", "/api/probe?path=" + old)
        api.history.record(old, position=600, duration=1200, audio=1, subtitle=0, device_id="X")
        (d / "Show.S01E01.mkv.part").write_bytes(b"x" * 2000)      # still downloading
        self.assertEqual(api.history.resume_info(old)["resume_position"], 600)

        (d / "Show.S01E01.mkv.part").rename(d / "Show.S01E01.mkv")
        new = str(d / "Show.S01E01.mkv")
        # The finished file keeps the probe (thumbnails, subtitles) without probing again ...
        with mock.patch.object(api, "probe", side_effect=AssertionError("probed again")):
            status, body = self.request("GET", "/api/probe?path=" + new)
            self.assertEqual((status, body["path"], body["name"]), (200, new, "Show.S01E01.mkv"))
            self.assertIs(self.controller._media(old), self.controller._media(new))
        # ... and its place in Recents, under the new name.
        self.assertEqual(body["resume"]["resume_position"], 600)
        items = self.request("GET", "/api/recent")[1]["items"]
        self.assertEqual([e["path"] for e in items if e["path"].startswith(str(d))], [new])
        self.assertEqual(api.history.resume_info(old)["path"], new)


class LocalPlayerApiTest(ApiTest):
    """ "This Mac": state.local_player and POST /api/local/report."""

    def setUp(self):
        super().setUp()
        self.local = LocalDevice()
        self.controller.devices.local = self.local

    def test_report_without_a_local_session_is_409(self):
        status, body = self.request("POST", "/api/local/report", {"position": 1})
        self.assertEqual((status, body["ok"]), (409, False))

    def test_state_and_report_while_playing_to_this_mac(self):
        session = StubSession()
        session.conf = self.local
        self.controller.session = session
        player = LocalPlayer("http://127.0.0.1:5000/master.m3u8", 42)
        self.local.player = player
        self.controller.call(player.command("/scrub?position=90"))
        status, st = self.request("GET", "/api/state")
        self.assertEqual(shape_errors(doc_examples()["local_player"], st["local_player"]), [])
        self.assertEqual(st["local_player"]["commands"], [{"id": 1, "action": "seek", "position": 90.0}])
        got = []
        api.airplay.add_playback_listener(got.append)
        self.addCleanup(api.airplay.remove_playback_listener, got.append)
        status, body = self.request("POST", "/api/local/report",
                                    {"position": 91, "duration": 600, "rate": 1, "ack": 1})
        self.assertEqual((status, body), (200, {"ok": True}))
        self.assertEqual(got[-1]["position"], 91.0)
        self.assertEqual(self.request("GET", "/api/state")[1]["local_player"]["commands"], [])

    def test_no_local_player_state_when_playing_to_a_tv(self):
        session = StubSession()
        session.conf = StubConf()
        self.controller.session = session
        self.assertIsNone(self.request("GET", "/api/state")[1]["local_player"])


class DocParserTest(unittest.TestCase):
    def test_all_examples_found(self):
        self.assertEqual(set(doc_examples()),
                         {"probe", "devices", "state", "sample", "request", "event", "thumbs",
                          "local_player"})

    def test_shape_errors(self):
        self.assertEqual(shape_errors({"a": 1, "b": {"c": "x"}}, {"a": None, "b": {"c": "y"}}), [])
        self.assertEqual(shape_errors({"a": 1}, {"a": "1", "z": 0}),
                         ["$.z: returned but undocumented", "$.a: expected number, got '1'"])


if __name__ == "__main__":
    unittest.main()
