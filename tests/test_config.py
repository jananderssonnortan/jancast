"""config.py: where Luftbro keeps its state, and that it is this user's only."""

import json
import os
import stat
import unittest
from unittest import mock

from helpers import TempDirMixin
from luftbro import config


def mode(path):
    return stat.S_IMODE(os.stat(path).st_mode)


class ConfigDirTest(TempDirMixin, unittest.TestCase):
    def test_overrides_are_used_as_they_are(self):
        d = self.make_tempdir() / "cfg"
        c = self.make_tempdir() / "cache"
        with mock.patch.dict(config.os.environ, {"LUFTBRO_CONFIG_DIR": str(d), "LUFTBRO_CACHE_DIR": str(c)}):
            self.assertEqual(config.config_dir(), d)
            self.assertEqual(config.cache_dir(), c)
        self.assertTrue(d.is_dir() and c.is_dir())
        # Created private: history and pairing credentials live there.
        self.assertEqual((mode(d), mode(c)), (0o700, 0o700))

    def test_existing_dir_and_files_are_made_private_once(self):
        """A dir and files with wider modes (another umask, another tool) are tightened."""
        d = self.make_tempdir() / "cfg"
        d.mkdir(0o755)
        (d / "pyatv.json").write_text("{}")
        (d / "history.json").write_text("{}")
        os.chmod(d / "pyatv.json", 0o644)
        os.chmod(d / "history.json", 0o664)
        sub = d / "sub"
        sub.mkdir(0o755)
        with mock.patch.dict(config.os.environ, {"LUFTBRO_CONFIG_DIR": str(d)}):
            config.config_dir()
            self.assertEqual(mode(d), 0o700)
            self.assertEqual((mode(d / "pyatv.json"), mode(d / "history.json")), (0o600, 0o600))
            self.assertEqual(mode(sub), 0o755)         # files only
            # Once per run: a file made readable afterwards is left alone (it is
            # ours, written 0600 anyway) rather than stat'ed on every call.
            os.chmod(d / "history.json", 0o644)
            config.config_dir()
            self.assertEqual(mode(d / "history.json"), 0o644)

    def test_write_private_json_is_atomic_and_private(self):
        d = self.make_tempdir()
        path = d / "state.json"
        config.write_private_json(path, {"a": 1}, indent=2)
        self.assertEqual(json.loads(path.read_text()), {"a": 1})
        self.assertEqual(mode(path), 0o600)
        self.assertEqual([p.name for p in d.iterdir()], ["state.json"])    # no temp file left
        os.chmod(path, 0o644)
        config.write_private_json(path, {"a": 2})
        self.assertEqual((json.loads(path.read_text()), mode(path)), ({"a": 2}, 0o600))
        with self.assertRaises(TypeError):
            config.write_private_json(path, {"a": object()})
        self.assertEqual(json.loads(path.read_text()), {"a": 2})            # old file intact
        self.assertEqual([p.name for p in d.iterdir()], ["state.json"])

    def test_make_private(self):
        f = self.make_tempdir() / "pyatv.json"
        f.write_text("{}")
        os.chmod(f, 0o644)
        config.make_private(f)
        self.assertEqual(mode(f), 0o600)
        config.make_private(f.parent / "missing.json")        # quietly nothing


class StateFilesTest(TempDirMixin, unittest.TestCase):
    """What we write to the config dir is this user's only: history, the
    state file, and pyatv's credentials file (written by pyatv, tightened by us)."""

    def setUp(self):
        self.dir = self.make_tempdir()
        patcher = mock.patch.dict(config.os.environ, {"LUFTBRO_CONFIG_DIR": str(self.dir)})
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_history_and_state_are_private(self):
        from luftbro import airplay, history
        movie = self.dir / "movie.mkv"
        movie.write_bytes(b"x")
        history.record(movie, position=100, duration=1000, audio=1, subtitle=0, device_id="X")
        history.opened(movie, 1000)
        airplay.save_state({"last_device": "X"})
        self.assertEqual(mode(self.dir / "history.json"), 0o600)
        self.assertEqual(mode(self.dir / "state.json"), 0o600)
        self.assertEqual(airplay.load_state(), {"last_device": "X"})
        self.assertEqual(history.resume_info(movie)["resume_position"], 100)
        self.assertEqual(sorted(p.name for p in self.dir.iterdir()),
                         ["history.json", "movie.mkv", "state.json"])     # no temp files

    def test_pyatv_credentials_are_private_after_every_save(self):
        import asyncio
        from luftbro.airplay import PrivateFileStorage
        path = self.dir / "pyatv.json"

        async def run():
            storage = PrivateFileStorage(str(path), asyncio.get_running_loop())
            await storage.load()
            await storage.save()
            self.assertEqual(mode(path), 0o600)
            os.chmod(path, 0o644)
            await storage.save()
            self.assertEqual(mode(path), 0o600)
        asyncio.run(run())

    def test_pyatv_credentials_survive_a_failed_save(self):
        import asyncio
        from unittest import mock
        from luftbro import config
        from luftbro.airplay import PrivateFileStorage
        path = self.dir / "pyatv.json"
        loop = asyncio.new_event_loop()
        self.addCleanup(loop.close)
        storage = PrivateFileStorage(str(path), loop)
        storage._save_file({"devices": ["paired"]})
        with mock.patch.object(config.json, "dumps", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                storage._save_file({"devices": []})
        self.assertEqual(path.read_text(), '{"devices": ["paired"]}')
        self.assertEqual(sorted(p.name for p in self.dir.iterdir()), ["pyatv.json"])

    def test_state_updates_merge(self):
        from luftbro import airplay
        airplay.update_state(last_device="X")
        airplay.update_state(known_devices={"Y": {}})
        self.assertEqual(airplay.load_state(), {"last_device": "X", "known_devices": {"Y": {}}})


if __name__ == "__main__":
    unittest.main()
