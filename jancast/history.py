"""What was played, where it stopped, and with which tracks/device.

Stored in ~/.config/jancast/history.json, keyed by resolved file path. An
entry only applies while the file's size and mtime are unchanged, so a file
replaced under the same name doesn't resume at a stale position. A download
in progress ("movie.mkv.part") changes all the time, so only has to exist; its
entry moves to the finished file once the download client renames it.
"""

import json
import os
import threading
import time
from pathlib import Path

from . import names
from .config import config_dir

MAX_ENTRIES = 50
WATCHED_FRACTION = 0.95     # past this, the file counts as watched
MIN_RESUME_S = 30           # don't offer to resume a few seconds in

_lock = threading.Lock()


def _history_file():
    return config_dir() / "history.json"


def _load():
    try:
        data = json.loads(_history_file().read_text())
        return data if isinstance(data, dict) else {}
    except (FileNotFoundError, ValueError):
        return {}


def _save(data):
    path = _history_file()
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=1))
    tmp.replace(path)


def _fingerprint(path):
    st = os.stat(path)
    return {"size_bytes": st.st_size, "mtime": st.st_mtime}


def record(path, *, position, duration, audio, subtitle, device_id, stereo=False,
           finished=False, subtitle_delay=0.0):
    """Save progress for a file. `audio`/`subtitle` are 1-based ids (0 = no subs)."""
    path = str(Path(path).resolve())
    try:
        fp = _fingerprint(path)
    except OSError:
        return
    watched = finished or (duration and position >= duration * WATCHED_FRACTION)
    with _lock:
        data = _load()
        data[path] = {
            "path": path, "name": Path(path).name, **fp,
            "position": 0.0 if watched else round(float(position or 0), 1),
            "duration": duration, "watched": bool(watched),
            "audio": audio, "subtitle": subtitle, "device_id": device_id,
            "stereo": bool(stereo), "subtitle_delay": round(float(subtitle_delay or 0), 2),
            "updated_at": time.time(),
        }
        if len(data) > MAX_ENTRIES:
            for old in sorted(data, key=lambda p: data[p]["updated_at"])[:-MAX_ENTRIES]:
                del data[old]
        _save(data)


def opened(path, duration):
    """A file was opened (not necessarily played): list it in Recents if it
    isn't there yet. One already listed keeps its place and everything saved:
    Recents moves when something plays, not while the user browses."""
    path = str(Path(path).resolve())
    try:
        fp = _fingerprint(path)
    except OSError:
        return
    with _lock:
        data = _followed()
        entry = data.get(path)
        if entry and (_same_file(entry, fp) or names.is_partial(path)):
            pass
        else:
            data[path] = {
                "path": path, "name": Path(path).name, **fp,
                "position": 0.0, "duration": duration, "watched": False,
                "audio": None, "subtitle": None, "device_id": None,
                "stereo": False, "updated_at": time.time(),
            }
        if len(data) > MAX_ENTRIES:
            for old in sorted(data, key=lambda p: data[p]["updated_at"])[:-MAX_ENTRIES]:
                del data[old]
        _save(data)


def _same_file(entry, fp):
    return fp["size_bytes"] == entry.get("size_bytes") and abs(fp["mtime"] - entry.get("mtime", 0)) < 1


def _valid(entry):
    if names.is_partial(entry["path"]):
        return os.path.exists(entry["path"])
    try:
        fp = _fingerprint(entry["path"])
    except OSError:
        return False
    return _same_file(entry, fp)


def _followed():
    """The history, with entries of finished downloads ("movie.mkv.part" now
    "movie.mkv") moved to the finished file. Call with the lock held."""
    data = _load()
    moved = False
    for path, entry in list(data.items()):
        if (done := names.completed(path)) is None:
            continue
        del data[path]
        moved = True
        done = str(done.resolve())
        if done in data and data[done].get("updated_at", 0) >= entry.get("updated_at", 0):
            continue
        try:
            fp = _fingerprint(done)
        except OSError:
            continue
        data[done] = {**entry, "path": done, "name": Path(done).name, **fp}
    if moved:
        _save(data)
    return data


def resume_info(path):
    """The saved entry for this file if it is still the same file, else None.
    `resume_position` is null when there is nothing worth resuming."""
    path = Path(path).resolve()
    path = str(names.completed(path) or path)
    with _lock:
        entry = _followed().get(path)
    if not entry or not _valid(entry):
        return None
    return _with_derived(entry)


def recent(limit=20):
    """Most recently played files that still exist, newest first."""
    with _lock:
        entries = list(_followed().values())
    entries.sort(key=lambda e: e.get("updated_at", 0), reverse=True)
    out = []
    for e in entries:
        if len(out) >= limit:
            break
        if _valid(e):
            out.append(_with_derived(e))
    return out


def _with_derived(entry):
    """An entry as the API shows it: plus where to resume and what the file is
    (parsed on the way out, so a better parser also improves old entries)."""
    pos = entry.get("position") or 0
    return {**entry,
            "resume_position": pos if not entry.get("watched") and pos >= MIN_RESUME_S else None,
            "name_info": names.parse(entry["path"])}
