"""Where jancast keeps its state: ~/.config/jancast, or $JANCAST_CONFIG_DIR.

Resolved on every call (not at import) so tests can redirect it."""

import os
import shutil
from pathlib import Path

# Apps launched from Finder get PATH=/usr/bin:/bin:/usr/sbin:/sbin, which
# misses Homebrew/MacPorts, where ffmpeg normally lives.
EXTRA_BIN_DIRS = ("/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin")


def ensure_tool_path():
    """Add the usual package-manager bin dirs to PATH (for us and for the
    ffmpeg/ffprobe subprocesses). Returns the missing tools, if any."""
    parts = os.environ.get("PATH", "").split(os.pathsep)
    extra = [d for d in EXTRA_BIN_DIRS if d not in parts and os.path.isdir(d)]
    if extra:
        os.environ["PATH"] = os.pathsep.join(p for p in parts + extra if p)
    return [t for t in ("ffmpeg", "ffprobe") if not shutil.which(t)]


def config_dir():
    d = Path(os.environ.get("JANCAST_CONFIG_DIR") or Path.home() / ".config" / "jancast")
    d.mkdir(parents=True, exist_ok=True)
    return d


def cache_dir():
    """Regenerable data (thumbnails): ~/Library/Caches/jancast, or $JANCAST_CACHE_DIR."""
    d = Path(os.environ.get("JANCAST_CACHE_DIR") or Path.home() / "Library" / "Caches" / "jancast")
    d.mkdir(parents=True, exist_ok=True)
    return d
