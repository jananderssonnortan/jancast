"""The patched status poll: a TV that closes the connection stopped playback
there; a connection that dies after a silence (the Mac slept) was lost."""

import asyncio
import unittest
from unittest import mock

import helpers  # noqa: F401 - isolates the config dir
from jancast import airplay

ConnectionLostError = airplay._player.exceptions.ConnectionLostError


class Player:
    """Just what _wait_for_media_to_end uses: rtsp.connection.get."""

    def __init__(self, get):
        self.rtsp = mock.Mock()
        self.rtsp.connection.get = get


class WaitForMediaToEndTest(unittest.TestCase):
    def run_poll(self, clock):
        async def closed(path, allow_error=True):
            raise ConnectionLostError("connection was lost")

        with mock.patch.object(airplay.time, "time", side_effect=clock):
            return asyncio.run(airplay._wait_for_media_to_end(Player(closed)))

    def test_closed_right_away_is_a_stop_on_the_tv(self):
        self.assertIsNone(self.run_poll(iter([100.0, 101.0]).__next__))

    def test_closed_after_a_silence_is_a_lost_connection(self):
        # 42 s between the last answer and the error: the Mac was asleep.
        with self.assertRaisesRegex(ConnectionLostError, r"no answer for 42 s"):
            self.run_poll(iter([100.0, 142.0, 142.0]).__next__)


if __name__ == "__main__":
    unittest.main()
