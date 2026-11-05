"""Where luftbro keeps its state: ~/.config/luftbro, or $LUFTBRO_CONFIG_DIR.

Resolved on every call (not at import) so tests can redirect it."""

import json
import os
import shutil
import stat
import tempfile
import threading
from pathlib import Path

# Apps launched from Finder get PATH=/usr/bin:/bin:/usr/sbin:/sbin, which
# misses Homebrew/MacPorts, where ffmpeg normally lives.
EXTRA_BIN_DIRS = ("/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin")

# The config dir holds history and the Apple TV's pairing credentials
# (pyatv.json), the cache dir subtitles and frames of what was watched: none
# of it is for other users of the Mac.
PRIVATE_DIR = 0o700
PRIVATE_FILE = 0o600
_secured = set()            # dirs already made private this run (one pass, not per call)
_secured_lock = threading.Lock()


def ensure_tool_path():
    """Add the usual package-manager bin dirs to PATH (for us and for the
    ffmpeg/ffprobe subprocesses). Returns the missing tools, if any."""
    parts = os.environ.get("PATH", "").split(os.pathsep)
    extra = [d for d in EXTRA_BIN_DIRS if d not in parts and os.path.isdir(d)]
    if extra:
        os.environ["PATH"] = os.pathsep.join(p for p in parts + extra if p)
    return [t for t in ("ffmpeg", "ffprobe") if not shutil.which(t)]


def config_dir():
    d = Path(os.environ.get("LUFTBRO_CONFIG_DIR") or Path.home() / ".config" / "luftbro")
    return _private_dir(d, files_too=True)


def cache_dir():
    """Regenerable data (thumbnails): ~/Library/Caches/luftbro, or $LUFTBRO_CACHE_DIR."""
    d = Path(os.environ.get("LUFTBRO_CACHE_DIR") or Path.home() / "Library" / "Caches" / "luftbro")
    return _private_dir(d)


def _private_dir(d, files_too=False):
    """`d`, created if needed, readable by this user only. A dir that already
    exists is tightened too, the first time it is used in a run (whatever
    umask or tool made it); with `files_too` so are the files in it."""
    d.mkdir(parents=True, exist_ok=True, mode=PRIVATE_DIR)
    with _secured_lock:
        if d in _secured:
            return d
        _secured.add(d)
    try:
        if stat.S_IMODE(d.stat().st_mode) != PRIVATE_DIR:
            d.chmod(PRIVATE_DIR)
        if files_too:
            for f in d.iterdir():
                if f.is_file() and not f.is_symlink():
                    make_private(f)
    except OSError:
        pass            # not ours to change (unusual); the files are still written 0600
    return d


def make_private(path):
    """chmod `path` to 0600 (for files written by libraries with the default mode)."""
    try:
        if stat.S_IMODE(os.stat(path).st_mode) != PRIVATE_FILE:
            os.chmod(path, PRIVATE_FILE)
    except OSError:
        pass


def write_private_json(path, data, **dumps_kwargs):
    """Write `data` as JSON to `path`: created 0600 from the start (not chmod'ed
    after, so it is never readable in between) and atomically (a crash midway
    leaves the old file, not a half-written one)."""
    path = Path(path)
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(json.dumps(data, **dumps_kwargs))
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
