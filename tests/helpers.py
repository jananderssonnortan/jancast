"""Shared fixtures: synthetic media, stub devices, temp dirs, slow-test marker."""

import atexit
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

# Never let tests read or write the user's real ~/.config/jancast (history,
# known devices, pairing credentials).
os.environ["JANCAST_CONFIG_DIR"] = tempfile.mkdtemp(prefix="jancast-test-config-")
os.environ["JANCAST_CACHE_DIR"] = tempfile.mkdtemp(prefix="jancast-test-cache-")
for _d in (os.environ["JANCAST_CONFIG_DIR"], os.environ["JANCAST_CACHE_DIR"]):
    atexit.register(shutil.rmtree, _d, True)

from jancast.media import MediaInfo, Track  # noqa: E402

SLOW = unittest.skipIf(os.environ.get("JANCAST_SKIP_SLOW") == "1",
                       "slow test (JANCAST_SKIP_SLOW=1)")
HAVE_FFMPEG = bool(shutil.which("ffmpeg") and shutil.which("ffprobe"))
PYTHON = sys.executable


class TempDirMixin:
    def make_tempdir(self):
        d = tempfile.mkdtemp(prefix="jancast-test-")
        self.addCleanup(shutil.rmtree, d, True)
        return Path(d).resolve()


def video_stream(index=0, codec="h264", width=1920, height=1080, **extra):
    return {"index": index, "codec_type": "video", "codec_name": codec,
            "width": width, "height": height, **extra}


def audio_stream(index, codec="aac", channels=2, lang="eng", title="", default=False):
    return {"index": index, "codec_type": "audio", "codec_name": codec,
            "channels": channels, "tags": {"language": lang, "title": title},
            "disposition": {"default": int(default)}}


def sub_stream(index, codec="subrip", lang="eng", title="", forced=False,
               width=None, height=None):
    s = {"index": index, "codec_type": "subtitle", "codec_name": codec,
         "tags": {"language": lang, "title": title},
         "disposition": {"forced": int(forced)}}
    if width:
        s.update(width=width, height=height)
    return s


def make_media(directory, streams, name="movie.mkv", duration=120.0, content=b"x" * 1000):
    """A MediaInfo built from a synthetic ffprobe result (no ffprobe needed)."""
    path = Path(directory) / name
    path.write_bytes(content)
    return MediaInfo(path, {"format": {"duration": str(duration)}, "streams": streams})


def track(kind="audio", index=1, codec="aac", **kw):
    return Track(kind, index, codec, **kw)


class StubDeviceInfo:
    model_str = "Apple TV 4K (gen 3)"


class StubConf:
    """Enough of a pyatv config for Session.to_json(). `simulated=True` makes
    airplay.is_simulated() treat it like the simulator's device (controls go
    through airplay.send_command instead of restarting playback)."""
    identifier = "AA:BB:CC:DD:EE:FF"
    name = "Living Room"
    address = "192.0.2.20"
    device_info = StubDeviceInfo()
    model_str = StubDeviceInfo.model_str

    def __init__(self, simulated=False):
        self.simulated = simulated


def write_script(directory, body, name="fake_ffmpeg.py"):
    path = Path(directory) / name
    path.write_text(body)
    return [PYTHON, str(path)]
