"""LAN HTTP server for the HLS output, measuring every transfer to the Apple TV."""

import collections
import http.server
import os
import re
import socket
import struct
import sys
import threading
import time
from pathlib import Path
from urllib.parse import unquote

from .media import read_segment_durations

CHUNK = 64 * 1024
CONTENT_TYPES = {
    ".m3u8": "application/vnd.apple.mpegurl",
    ".m4s": "video/iso.segment",
    ".mp4": "video/mp4",
    ".vtt": "text/vtt",
}
# Send buffer per connection. macOS autotunes it to 1-4 MB, so a whole segment
# would be "sent" (accepted by the kernel) long before it reaches the TV.
SNDBUF = 192 * 1024
# After the last write, wait (at most DRAIN_TIMEOUT_S) until the kernel has
# delivered the response before timing it. Skipped for small responses
# (playlists, empty bodies) where the queue empties within a round trip anyway.
DRAIN_MIN_BYTES = CHUNK
DRAIN_TIMEOUT_S = 5.0
DRAIN_POLL_S = 0.003
SO_NWRITE = 0x1024          # macOS: bytes in the send buffer not yet acked
SIOCOUTQ = 0x5411           # Linux (== TIOCOUTQ): unsent + unacked bytes
SEGMENT_RE = re.compile(r"^/seg_video_(\d+)\.m4s$")
AUDIO_SEGMENT_RE = re.compile(r"^/seg_audio_(\d+)\.m4s$")
SUBTITLE_RE = re.compile(r"^/stream_video(\d+)\.vtt$")
INIT_RE = re.compile(r"^/init_(video|audio)\.mp4$")


def classify(path):
    """(kind, segment index or None) for a request path (layout: media.py)."""
    if m := SEGMENT_RE.match(path):
        return "segment", int(m.group(1))
    if m := AUDIO_SEGMENT_RE.match(path):
        return "audio", int(m.group(1))
    if m := SUBTITLE_RE.match(path):
        return "subtitle", int(m.group(1))
    if path == "/master.m3u8":
        return "master", None
    if path.endswith(".m3u8"):
        return "playlist", None
    if INIT_RE.match(path):
        return "init", None
    return "other", None


class SegmentDurations:
    """Media duration per segment index, re-read from the playlist on demand."""

    def __init__(self, directory):
        self.directory = directory
        self.durations = []
        self.lock = threading.Lock()

    def get(self, index):
        with self.lock:
            if index >= len(self.durations):
                self.durations = read_segment_durations(self.directory)
            return self.durations[index] if index < len(self.durations) else None


def unsent_bytes(sock):
    """Bytes the kernel still holds for `sock` (not yet delivered/acked), or
    None if this platform can't tell."""
    try:
        if sys.platform == "darwin":
            return sock.getsockopt(socket.SOL_SOCKET, SO_NWRITE)
        if sys.platform.startswith("linux"):
            import fcntl
            buf = fcntl.ioctl(sock.fileno(), SIOCOUTQ, struct.pack("i", 0))
            return struct.unpack("i", buf)[0]
    except (OSError, ValueError):
        pass
    return None


def wait_drained(sock, timeout=DRAIN_TIMEOUT_S, poll=DRAIN_POLL_S):
    """Block until `sock`'s send queue is empty. True if it drained, False on
    timeout, None if unsupported / the socket is gone."""
    deadline = time.monotonic() + timeout
    while True:
        n = unsent_bytes(sock)
        if n is None:
            return None
        if n <= 0:
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(poll)


class HLSHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"     # keep-alive, like a normal HLS origin
    server_version = "jancast"

    def log_message(self, fmt, *args):
        pass

    def handle(self):
        # A player resetting an idle keep-alive connection makes the request-line
        # readline raise; that is routine, not worth a traceback or a record.
        # (Resets during a transfer are caught and recorded in _serve.)
        try:
            super().handle()
        except (ConnectionError, TimeoutError):
            self.close_connection = True

    def do_HEAD(self):
        self._serve(head=True)

    def do_GET(self):
        self._serve(head=False)

    def _serve(self, head):
        srv = self.server
        started = time.monotonic()
        t = time.time()
        path = unquote(self.path.split("?", 1)[0])
        kind, segment = classify(path)
        if srv.ondemand is not None:
            # Fast start: segments are made on request (waits, or restarts
            # ffmpeg at this segment for a jump).
            srv.ondemand.wait_for(path)
        entry = {"t": t, "path": path, "kind": kind, "segment": segment, "status": 200,
                 "bytes": 0, "duration_ms": 0.0, "mbps": None, "realtime_ratio": None,
                 "client": self.client_address[0], "error": None}

        try:
            file = (srv.directory / path.lstrip("/")).resolve()
            found = srv.directory in file.parents and file.is_file()
        except (OSError, ValueError):       # e.g. NUL byte in the path
            found = False
        if not found:
            entry["status"] = 404
            entry["error"] = "not ready (404)" if kind in ("segment", "audio", "subtitle") else "not found"
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            if kind in ("segment", "audio", "subtitle"):
                srv.telemetry.event("warn", "http",
                                    f"Apple TV requested {path} before it was prepared")
            self._finish(entry, started)
            return

        try:
            size = file.stat().st_size
            start, end = 0, size - 1
            rng = re.match(r"bytes=(\d*)-(\d*)$", self.headers.get("Range", "").strip())
            if rng and (rng.group(1) or rng.group(2)):
                if rng.group(1):
                    start = int(rng.group(1))
                    end = min(int(rng.group(2)), size - 1) if rng.group(2) else size - 1
                else:
                    start = max(0, size - int(rng.group(2)))
                if start > end:
                    # Unsatisfiable (start beyond EOF, end < start, or "bytes=-0").
                    entry["status"] = 416
                    entry["error"] = "range not satisfiable"
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{size}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    self._finish(entry, started)
                    return
                self.send_response(206)
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
                entry["status"] = 206
            else:
                self.send_response(200)
            length = end - start + 1
            self.send_header("Content-Type", CONTENT_TYPES.get(file.suffix, "application/octet-stream"))
            self.send_header("Content-Length", str(length))
            self.send_header("Accept-Ranges", "bytes")
            if file.suffix == ".m3u8":
                self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            if not head:
                with open(file, "rb") as f:
                    f.seek(start)
                    remaining = length
                    while remaining > 0:
                        chunk = f.read(min(CHUNK, remaining))
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        remaining -= len(chunk)
                        entry["bytes"] += len(chunk)
                        srv.telemetry.add_tx_bytes(len(chunk))
                self.wfile.flush()
                if entry["bytes"] >= DRAIN_MIN_BYTES:
                    # Time delivery, not acceptance into the send buffer.
                    wait_drained(self.connection)
        except (ConnectionError, TimeoutError):   # broken pipe, reset, aborted
            entry["error"] = "client aborted"
            self.close_connection = True
        except Exception as e:  # noqa: BLE001 - reported to the UI instead of crashing
            entry["status"] = 500
            entry["error"] = f"{type(e).__name__}: {e}"
            srv.telemetry.event("error", "http", f"Error serving {path}: {e}")
            self.close_connection = True

        elapsed = time.monotonic() - started
        # Only real transfers say something about the network: a HEAD (no body) or
        # a partial range would otherwise claim the whole segment arrived instantly.
        if (kind == "segment" and not head and entry["error"] is None and elapsed > 0
                and entry["bytes"]):
            media = srv.segments.get(segment)
            if media:
                media *= entry["bytes"] / size
                entry["realtime_ratio"] = round(media / elapsed, 2)
        self._finish(entry, started)

    def _finish(self, entry, started):
        elapsed = time.monotonic() - started
        entry["duration_ms"] = round(elapsed * 1000, 1)
        if entry["bytes"] and elapsed > 0:
            entry["mbps"] = round(entry["bytes"] * 8 / elapsed / 1e6, 2)
        self.server.telemetry.request(entry)


class HLSServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, directory, telemetry, port=0):
        self.directory = Path(directory).resolve()
        self.telemetry = telemetry
        self.segments = SegmentDurations(self.directory)
        self.ondemand = None        # ondemand.OnDemand when segments are made on request
        super().__init__(("0.0.0.0", port), HLSHandler)
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)
        self.thread.start()

    def get_request(self):
        sock, addr = super().get_request()
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, SNDBUF)
        except OSError:
            pass
        return sock, addr

    def handle_error(self, request, client_address):
        # Connection resets/timeouts outside a transfer are routine (see
        # HLSHandler.handle); anything else keeps the default traceback.
        if isinstance(sys.exc_info()[1], (ConnectionError, TimeoutError)):
            return
        super().handle_error(request, client_address)

    @property
    def port(self):
        return self.server_address[1]

    def stop(self):
        self.shutdown()
        self.server_close()


class DirectoryBitrate:
    """Average bitrate of the finished .m4s segments in one directory.

    Incremental: ffmpeg writes segments to a temp name and renames them into
    place, so a finished segment never changes; its size is stat'ed once and
    remembered by (name, inode). Each call only lists the directory (no stat
    for known files) and stats the new names; vanished files are dropped and a
    file replaced under the same name (new inode) is re-read.
    """

    def __init__(self, directory):
        self.directory = directory
        self.sizes = {}              # name -> (inode, size)
        self.total = 0
        self.lock = threading.Lock()

    def bitrate(self, prepared_s):
        if not prepared_s:
            return None
        with self.lock:
            seen = set()
            try:
                with os.scandir(self.directory) as it:
                    for e in it:
                        if not e.name.endswith(".m4s"):
                            continue
                        seen.add(e.name)
                        known = self.sizes.get(e.name)
                        ino = e.inode()
                        if known is not None and known[0] == ino:
                            continue
                        try:
                            size = e.stat().st_size
                        except OSError:          # renamed/removed meanwhile
                            seen.discard(e.name)
                            continue
                        if known is not None:
                            self.total -= known[1]
                        self.sizes[e.name] = (ino, size)
                        self.total += size
            except OSError:
                return None
            if len(seen) != len(self.sizes):
                for name in [n for n in self.sizes if n not in seen]:
                    self.total -= self.sizes.pop(name)[1]
            total = self.total
        return int(total * 8 / prepared_s) if total else None


_BITRATE_CACHE = collections.OrderedDict()     # str(directory) -> DirectoryBitrate
_BITRATE_CACHE_MAX = 8
_BITRATE_LOCK = threading.Lock()


def directory_bitrate(directory, prepared_s):
    """Average bitrate of the prepared video+audio segments, bits/s.

    Backed by a small per-directory DirectoryBitrate cache, so calling this
    once per second costs one directory listing plus a stat per *new* segment.
    """
    if not prepared_s:
        return None
    key = os.fspath(directory)
    with _BITRATE_LOCK:
        tracker = _BITRATE_CACHE.get(key)
        if tracker is None:
            tracker = _BITRATE_CACHE[key] = DirectoryBitrate(directory)
            while len(_BITRATE_CACHE) > _BITRATE_CACHE_MAX:
                _BITRATE_CACHE.popitem(last=False)
        else:
            _BITRATE_CACHE.move_to_end(key)
    return tracker.bitrate(prepared_s)
