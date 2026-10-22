"""local_player.py: "This Mac" - report mapping, command queue, lifecycle, listing."""

import asyncio
import unittest
from unittest import mock

from helpers import TempDirMixin, audio_stream, make_media, video_stream
from jancast import airplay, history, local_player
from jancast.local_player import LocalDevice, LocalPlayer, to_playback_info
from jancast.session import Session
from jancast.telemetry import Telemetry

REPORT = {"position": 12.5, "duration": 600, "rate": 1, "ready_to_play": True,
          "buffer_empty": False, "buffer_full": True, "likely_to_keep_up": True,
          "loaded_ranges": [{"start": 0, "duration": 40}]}


class MappingTest(unittest.TestCase):
    def test_report_becomes_apple_tv_playback_info(self):
        self.assertEqual(to_playback_info(REPORT), {
            "duration": 600.0, "position": 12.5, "rate": 1.0, "readyToPlay": True,
            "playbackBufferEmpty": False, "playbackBufferFull": True,
            "playbackLikelyToKeepUp": True,
            "loadedTimeRanges": [{"start": 0.0, "duration": 40.0}]})

    def test_no_duration_until_loaded(self):
        self.assertEqual(to_playback_info({"position": 0, "rate": 0}), {})

    def test_error(self):
        info = to_playback_info({"error": "Cannot Open"})
        self.assertEqual(info["error"]["localizedDescription"], "Cannot Open")


class PlayerTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.reports = []
        airplay.add_playback_listener(self.reports.append)
        self.addCleanup(airplay.remove_playback_listener, self.reports.append)
        self.p = LocalPlayer("http://127.0.0.1:1/master.m3u8", 30)

    async def start(self):
        task = asyncio.ensure_future(self.p.run())
        await asyncio.sleep(0.05)
        return task

    async def test_commands_are_queued_and_acknowledged(self):
        task = await self.start()
        await airplay.send_command("/rate?value=0.000000")
        await airplay.send_command("/scrub?position=90.25")
        await airplay.send_command("/rate?value=1.000000")
        self.assertEqual(self.p.state_json()["commands"], [
            {"id": 1, "action": "pause"}, {"id": 2, "action": "seek", "position": 90.25},
            {"id": 3, "action": "resume"}])
        self.p.report({**REPORT, "ack": 2})
        self.assertEqual([c["id"] for c in self.p.commands], [3])
        self.assertEqual(self.reports[-1]["position"], 12.5)
        self.p.report({**REPORT, "ended": True})
        await asyncio.wait_for(task, 2)              # the end of the media ends play_url
        self.assertFalse(self.p.state_json()["active"])
        self.assertEqual(self.p.commands[-1]["action"], "stop")   # app closes the window
        with self.assertRaises(RuntimeError):
            await airplay.send_command("/rate?value=0")          # no longer the target

    async def test_reports_before_a_seek_is_applied_are_marked(self):
        task = await self.start()
        self.p.report(REPORT)
        self.assertNotIn("_seek_pending", self.reports[-1])
        await airplay.send_command("/scrub?position=900")
        self.p.report(REPORT)                        # made before the app applied it
        self.assertTrue(self.reports[-1]["_seek_pending"])
        self.p.report({**REPORT, "ack": 1})
        self.assertNotIn("_seek_pending", self.reports[-1])
        self.p.report({**REPORT, "ended": True})
        await asyncio.wait_for(task, 2)

    async def test_closing_the_window_is_a_stop(self):
        task = await self.start()
        self.p.report({**REPORT, "closed": True})
        with self.assertRaises(asyncio.CancelledError):
            await asyncio.wait_for(task, 2)

    async def test_player_error_fails(self):
        task = await self.start()
        self.p.report({"error": "Cannot Open"})
        with self.assertRaisesRegex(RuntimeError, "Cannot Open"):
            await asyncio.wait_for(task, 2)
        self.assertIn("error", self.reports[-1])

    async def test_app_never_starting_fails(self):
        with mock.patch.object(local_player, "STARTUP_TIMEOUT_S", 0.2):
            with self.assertRaisesRegex(RuntimeError, "did not start"):
                await asyncio.wait_for(self.p.run(), 3)

    async def test_app_going_silent_fails(self):
        with mock.patch.object(local_player, "SILENCE_TIMEOUT_S", 0.2):
            task = await self.start()
            self.p.report(REPORT)
            with self.assertRaisesRegex(RuntimeError, "stopped reporting"):
                await asyncio.wait_for(task, 3)

    async def test_device_play_url_publishes_the_player(self):
        dev = LocalDevice()
        atv = dev.connect()
        task = asyncio.ensure_future(atv.stream.play_url("http://x/master.m3u8", position=5))
        await asyncio.sleep(0.05)
        self.assertEqual(dev.state_json()["url"], "http://x/master.m3u8")
        self.assertEqual(dev.state_json()["start_position"], 5.0)
        await dev.report({**REPORT, "ended": True})
        await asyncio.wait_for(task, 2)


class DeviceTest(TempDirMixin, unittest.IsolatedAsyncioTestCase):
    async def test_this_mac_is_listed_online_after_the_real_tvs(self):
        devices = airplay.Devices()
        with mock.patch.object(airplay.pyatv, "scan", mock.AsyncMock(return_value=[])):
            await devices.scan()
        listed = devices.list_json()
        mac = next(d for d in listed if d["id"] == local_player.DEVICE_ID)
        self.assertEqual((mac["name"], mac["status"], mac["pairing_required"]),
                         ("This Mac", "online", False))
        self.assertFalse(devices.needs_pairing(devices.get(local_player.DEVICE_ID)))
        self.assertTrue(airplay.is_local(devices.local) and airplay.is_simulated(devices.local))

    def test_local_plays_save_resume_history_but_simulated_ones_do_not(self):
        media = make_media(self.make_tempdir(), [video_stream(0), audio_stream(1)], duration=600.0)
        for conf, saved in ((LocalDevice(), True), (mock.Mock(simulated=True, local=False), False)):
            history._save({})
            s = Session(Telemetry(), None, media, media.audio[0], None, conf)
            s.playback["position"] = 120.0
            s._save_history()
            entry = history.resume_info(media.path)
            self.assertEqual(entry is not None and entry["resume_position"] == 120.0, saved, conf)
