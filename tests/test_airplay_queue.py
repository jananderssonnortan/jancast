"""airplay_queue.py: the pure helpers of the tvOS 18+ remote-control queue
(CMTime conversion, report mapping, event decoding) and QueuePlayback's event
handling. No device or network is involved."""

import asyncio
import plistlib
import unittest
from unittest import mock

from helpers import StubConf, TempDirMixin, audio_stream, make_media, video_stream
from jancast import airplay_queue as aq
from jancast import session as session_mod
from jancast.session import Session
from jancast.telemetry import Telemetry


def ct(value, timescale, flags=1, epoch=0):
    return {"value": value, "timescale": timescale, "flags": flags, "epoch": epoch}


# A real playbackInfo reply from an Apple TV on tvOS 26 (seekableTimeRanges
# filled in with a plausible value).
TVOS26_PLAYBACK_INFO = {
    "playbackBufferEmpty": False,
    "position": {"flags": 1, "value": 600688033625, "timescale": 1000000000, "epoch": 0},
    "readyToPlay": True,
    "stallCount": 0,
    "item": {"uuid": "084F..."},
    "loadedTimeRanges": [{"start": {"flags": 3, "value": 428648392, "timescale": 720000,
                                    "epoch": 0},
                          "duration": {"flags": 3, "value": 12123360, "timescale": 720000,
                                       "epoch": 0}}],
    "playbackState": "playing",
    "duration": {"flags": 3, "value": 2910550, "timescale": 1000, "epoch": 0},
    "rate": 1.0,
    "playbackLikelyToKeepUp": True,
    "playbackBufferFull": False,
    "seekableTimeRanges": [{"start": {"flags": 3, "value": 0, "timescale": 1000, "epoch": 0},
                            "duration": {"flags": 3, "value": 2910550, "timescale": 1000,
                                         "epoch": 0}}],
}


class CMTimeTest(unittest.TestCase):
    def test_cmtime(self):
        self.assertEqual(aq.cmtime(0), {"value": 0, "timescale": 1000, "flags": 1, "epoch": 0})
        self.assertEqual(aq.cmtime(12.5), {"value": 12500, "timescale": 1000, "flags": 1,
                                           "epoch": 0})
        self.assertEqual(aq.cmtime(600.68803)["value"], 600688)     # rounded to ms
        self.assertEqual(aq.cmtime(0.0004)["value"], 0)
        self.assertIsInstance(aq.cmtime(1.0)["value"], int)          # plist needs an int
        self.assertAlmostEqual(aq.normalize(aq.cmtime(3723.25)), 3723.25)   # round trip

    def test_normalize_cmtime_dicts(self):
        self.assertAlmostEqual(aq.normalize(ct(600688033625, 1000000000)), 600.688033625)
        self.assertEqual(aq.normalize(ct(12123360, 720000, flags=3)), 16.838)
        # Bit 0 ("valid") missing -> unknown, also for an indefinite/invalid time.
        self.assertIsNone(aq.normalize(ct(5, 1, flags=0)))
        self.assertIsNone(aq.normalize(ct(5, 1, flags=16)))
        self.assertIsNone(aq.normalize({"value": 5, "timescale": 1}))   # no flags at all
        self.assertIsNone(aq.normalize(ct(5, 0)))                      # timescale 0

    def test_normalize_nested(self):
        info = {"a": [{"start": ct(1, 2), "duration": ct(3, 1, flags=3)}, [ct(4, 4)], "x"],
                "b": {"c": ct(10, 5, flags=0), "d": 7}, "e": None, "f": True}
        self.assertEqual(aq.normalize(info),
                         {"a": [{"start": 0.5, "duration": 3.0}, [1.0], "x"],
                          "b": {"c": None, "d": 7}, "e": None, "f": True})
        self.assertEqual(aq.normalize([]), [])
        self.assertEqual(aq.normalize("playing"), "playing")
        self.assertEqual(aq.normalize(TVOS26_PLAYBACK_INFO["item"]), {"uuid": "084F..."})

    def test_normalize_does_not_mutate(self):
        info = {"position": ct(1, 1)}
        aq.normalize(info)
        self.assertEqual(info, {"position": ct(1, 1)})


class PlaybackReportTest(unittest.TestCase):
    def test_tvos26_reply(self):
        r = aq.to_playback_report(TVOS26_PLAYBACK_INFO, None)
        self.assertEqual(r["playbackState"], "playing")
        self.assertAlmostEqual(r["position"], 600.688, places=3)
        self.assertAlmostEqual(r["duration"], 2910.55)
        self.assertEqual(r["rate"], 1.0)
        rng = r["loadedTimeRanges"][0]
        self.assertAlmostEqual(rng["start"], 595.345, places=3)
        self.assertAlmostEqual(rng["duration"], 16.838, places=3)
        self.assertIs(r["readyToPlay"], True)
        self.assertEqual(r["item"], {"uuid": "084F..."})
        self.assertIsInstance(TVOS26_PLAYBACK_INFO["position"], dict)   # input untouched

    def test_states(self):
        dur = ct(100, 1)
        cases = [
            # (info, pushed state) -> (state, rate, has duration)
            (({"playbackState": "playing", "duration": dur}, None), ("playing", 1.0, True)),
            (({"playbackState": "playing", "rate": 0.5, "duration": dur}, None),
             ("playing", 0.5, True)),                    # an explicit rate is kept
            (({"playbackState": "paused", "duration": dur}, None), ("paused", 0.0, True)),
            (({"playbackState": "paused", "rate": 1.0, "duration": dur}, None),
             ("paused", 0.0, True)),                     # paused forces rate 0
            (({"playbackState": "loading", "rate": 1.0, "duration": dur}, None),
             ("loading", 1.0, False)),
            (({"playbackState": "stopped", "duration": dur}, None), ("stopped", None, False)),
            (({"duration": dur}, None), ("loading", None, False)),       # nothing known yet
            (({"duration": dur}, "paused"), ("paused", 0.0, True)),      # pushed state used
            (({"duration": dur}, "playing"), ("playing", 1.0, True)),
            (({"playbackState": "playing", "duration": dur}, "paused"),
             ("playing", 1.0, True)),                    # the reply wins over a push
            (({"playbackState": "", "duration": dur}, "stopped"), ("stopped", None, False)),
        ]
        for (info, pushed), (state, rate, has_duration) in cases:
            with self.subTest(info=info, pushed=pushed):
                r = aq.to_playback_report(info, pushed)
                self.assertEqual(r["playbackState"], state)
                self.assertEqual(r.get("rate"), rate)
                self.assertEqual("duration" in r, has_duration)
                if has_duration:
                    self.assertEqual(r["duration"], 100.0)


class DecodeEventTest(unittest.TestCase):
    @staticmethod
    def body(inner, inner_fmt=plistlib.FMT_BINARY, outer_fmt=plistlib.FMT_BINARY):
        return plistlib.dumps({"params": {"data": plistlib.dumps(inner, fmt=inner_fmt)}},
                              fmt=outer_fmt)

    def test_nested_bplist(self):
        inner = {"kind": "response", "messageID": 3,
                 "info": {"playbackState": "playing", "position": ct(5, 1)}}
        self.assertEqual(aq._decode_event(self.body(inner)), inner)
        # The outer plist may be XML too; plistlib detects the format.
        self.assertEqual(aq._decode_event(self.body(inner, outer_fmt=plistlib.FMT_XML)), inner)
        self.assertEqual(aq._decode_event(self.body({"type": "playbackState",
                                                     "name": "paused"})),
                         {"type": "playbackState", "name": "paused"})

    def test_garbage_is_none(self):
        cases = {
            "not a plist": b"garbage",
            "empty": b"",
            "no params": plistlib.dumps({"other": 1}, fmt=plistlib.FMT_BINARY),
            "params without data": plistlib.dumps({"params": {}}, fmt=plistlib.FMT_BINARY),
            "data not bytes": plistlib.dumps({"params": {"data": "text"}},
                                             fmt=plistlib.FMT_BINARY),
            "data not a plist": plistlib.dumps({"params": {"data": b"\x00\x01junk"}},
                                               fmt=plistlib.FMT_BINARY),
            "outer is a list": plistlib.dumps([1, 2], fmt=plistlib.FMT_BINARY),
            "params not a dict": plistlib.dumps({"params": [1]}, fmt=plistlib.FMT_BINARY),
        }
        for name, body in cases.items():
            with self.subTest(name):
                self.assertIsNone(aq._decode_event(body))


class QueueEventTest(unittest.IsolatedAsyncioTestCase):
    async def test_response_resolves_waiter_by_message_id(self):
        q = aq.QueuePlayback(rtsp=None)
        loop = asyncio.get_running_loop()
        f1, f2 = loop.create_future(), loop.create_future()
        q._waiters.update({1: f1, 2: f2})
        q.on_event({"kind": "response", "messageID": 2, "info": {"playbackState": "paused"}})
        self.assertFalse(f1.done())
        self.assertEqual(f2.result(), {"playbackState": "paused"})
        q.on_event({"kind": "response", "messageID": 2, "info": {"x": 1}})   # late duplicate
        self.assertEqual(f2.result(), {"playbackState": "paused"})
        q.on_event({"kind": "response", "messageID": 1})                     # no info
        self.assertEqual(f1.result(), {})
        q.on_event({"kind": "response", "messageID": 99, "info": {}})       # unknown id: ignored
        self.assertIsNone(q.pushed_state)

    async def test_pushed_playback_state(self):
        q = aq.QueuePlayback(rtsp=None)
        q.on_event({"type": "playbackState", "name": "playing"})
        self.assertEqual(q.pushed_state, "playing")
        q.on_event({"type": "playbackState", "name": 3})                     # not a string
        q.on_event({"type": "somethingElse", "name": "stopped"})
        q.on_event({})
        self.assertEqual(q.pushed_state, "playing")
        q.on_event({"type": "playbackState", "name": "paused"})
        self.assertEqual(q.pushed_state, "paused")

    async def test_status_round_trip(self):
        """status() posts a playbackInfo request and returns the event-channel
        reply carrying its messageID."""
        q = aq.QueuePlayback(rtsp=None)
        sent = []

        async def command(data):
            sent.append(data)
            q.on_event({"kind": "response", "messageID": data["messageID"],
                        "info": dict(TVOS26_PLAYBACK_INFO)})

        q.command = command
        info = await q.status()
        self.assertEqual(sent, [{"type": "playbackInfo", "kind": "request", "messageID": 1}])
        self.assertEqual(info["playbackState"], "playing")
        self.assertEqual(q._waiters, {})
        await q.status()
        self.assertEqual(sent[-1]["messageID"], 2)

    async def test_control_maps_classic_paths(self):
        q = aq.QueuePlayback(rtsp=None)
        q.command = mock.AsyncMock()
        await q.control("/rate?value=0.000000")
        await q.control("/scrub?position=42.500")
        await q.control("/stop")
        self.assertEqual([c.args[0] for c in q.command.await_args_list],
                         [{"type": "setRate", "rate": 0.0},
                          {"type": "seek", "time": aq.cmtime(42.5)},
                          {"type": "setRate", "rate": 0.0}])
        with self.assertRaises(RuntimeError):
            await q.control("/volume?x=1")


class SessionIntegrationTest(TempDirMixin, unittest.TestCase):
    def test_tvos26_reply_drives_session(self):
        tm = Telemetry()
        media = make_media(self.make_tempdir(), [video_stream(0), audio_stream(1)],
                           duration=2910.55)
        s = Session(tm, None, media, media.audio[0], None, StubConf(simulated=True))
        s.phase = "buffering"
        with mock.patch.object(session_mod.time, "time", return_value=1000.0):
            s._on_playback_info(aq.to_playback_report(TVOS26_PLAYBACK_INFO, None))
        pb = s.playback
        self.assertEqual(s.phase, "playing")
        self.assertAlmostEqual(pb["position"], 600.69, places=2)
        self.assertAlmostEqual(pb["duration"], 2910.55)
        self.assertEqual(pb["rate"], 1.0)
        self.assertEqual(pb["buffered_ahead_s"], 11.5)      # 595.345 + 16.838 - 600.688
        self.assertIs(pb["ready_to_play"], True)
        self.assertIs(pb["buffer_empty"], False)
        self.assertIs(pb["likely_to_keep_up"], True)
        keys = next(e["message"] for e in tm.events if "report keys" in e["message"])
        self.assertIn("extra: ['item', 'playbackState', 'seekableTimeRanges', 'stallCount']",
                      keys)

    def test_loading_reply_keeps_buffering(self):
        tm = Telemetry()
        media = make_media(self.make_tempdir(), [video_stream(0), audio_stream(1)])
        s = Session(tm, None, media, media.audio[0], None, StubConf(simulated=True))
        s.phase = "buffering"
        info = {"playbackState": "loading", "readyToPlay": False,
                "duration": ct(0, 1, flags=0), "position": ct(0, 1)}
        s._on_playback_info(aq.to_playback_report(info, None))
        self.assertEqual(s.phase, "buffering")
        self.assertIsNone(s.playback["position"])


if __name__ == "__main__":
    unittest.main()
