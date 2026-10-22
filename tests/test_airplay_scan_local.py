"""JANCAST_LOCAL_ONLY: test runs never find a real Apple TV."""

import asyncio
import os
import unittest
from unittest import mock

import helpers  # noqa: F401 - isolates the config dir
from jancast import airplay


class LocalOnlyScanTest(unittest.TestCase):
    def test_scan_skips_bonjour(self):
        devices = airplay.Devices()
        with mock.patch.dict(os.environ, {"JANCAST_LOCAL_ONLY": "1"}), \
                mock.patch.object(airplay.pyatv, "scan", side_effect=AssertionError("scanned")), \
                mock.patch.object(devices, "probe", mock.AsyncMock()):
            found = asyncio.run(devices.scan())
        self.assertTrue(found)
        self.assertTrue(all(airplay.is_simulated(c) for c in found))
