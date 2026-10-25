"""Localhost JSON API used by the macOS app (contract: docs/API.md)."""

import asyncio
import http.server
import json
import signal
import sys
import threading
import time
import traceback
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from . import __version__, airplay, episodes, history, names, ocrsubs
from .config import ensure_tool_path
from .media import MediaError, audio_plan, probe
from .session import RTT_INTERVALS, Session, sweep_stale_workdirs
from .telemetry import Telemetry
from . import thumbs as thumbs_module
from .thumbs import ThumbnailStore


class ApiError(Exception):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


class Controller:
    """Owns the asyncio loop (pyatv needs one), devices and the current session."""

    def __init__(self, workdir=None, simulate=None, sim_speed=None):
        self.telemetry = Telemetry()
        self.devices = airplay.Devices(simulate=simulate, sim_speed=sim_speed)
        self.session = None
        self.workdir = workdir
        freed = sweep_stale_workdirs(workdir)
        if freed:
            self.telemetry.event("info", "app", f"Removed {freed / 1e9:.1f} GB of stream copies "
                                 "left by an earlier run")
        self.media_cache = {}
        self.thumbs = ThumbnailStore()
        self.telemetry_level = "basic"
        self.loop = asyncio.new_event_loop()
        threading.Thread(target=self.loop.run_forever, daemon=True).start()

    def call(self, coro, timeout=60):
        return asyncio.run_coroutine_threadsafe(coro, self.loop).result(timeout)

    # ---- setup ------------------------------------------------------------

    def probe(self, path, remember=True, thumbs=True):
        try:
            media = self._completed_download(path) or probe(path)
        except MediaError as e:
            raise ApiError(str(e)) from e
        self.media_cache[str(media.path)] = media
        if remember:
            history.opened(media.path, media.duration)
        if thumbs:
            self._ensure_thumbs(media)
        vmode, reason = media.video_plan(None)
        return {
            "path": str(media.path), "name": media.path.name, "size_bytes": media.size_bytes,
            "downloading": media.partial,
            "duration_s": media.duration, "name_info": names.parse(media.path),
            "video": {"codec": media.video_codec, "width": media.video.get("width"),
                      "height": media.video.get("height"), "hdr": media.hdr,
                      "mode": vmode, "reason": reason},
            "audio": [{"id": i, "label": t.label(), "lang": t.lang, "title": t.title,
                       "codec": t.codec, "channels": t.channels, "default": t.default,
                       "forced": t.forced, "mode": audio_plan(t, False)[0]}
                      for i, t in enumerate(media.audio, 1)],
            "subtitles": [{"id": i, "label": t.label(), "lang": t.lang, "title": t.title,
                           "codec": t.codec, "default": t.default, "forced": t.forced,
                           "external": t.file is not None,
                           "mode": "burn" if t.burns_in else "ocr" if t.via_ocr else "soft"}
                          for i, t in enumerate(media.subs, 1)],
            "default_audio": media.default_audio,
            "default_subtitle": media.default_sub,
            "resume": history.resume_info(media.path),
            "next": episodes.next_episode(media.path),
        }

    def _completed_download(self, path):
        """The probe of a download in progress that has since been renamed to
        `path`, so its thumbnails and subtitles carry over to the finished file."""
        key = Path(path).expanduser().resolve()
        return next((m for k, m in list(self.media_cache.items())
                     if k != str(key) and m.path == key), None)

    def _media(self, path):
        key = str(Path(path).expanduser().resolve())
        if key not in self.media_cache:
            self.probe(path, remember=False, thumbs=False)
        return self.media_cache[key]

    def _ensure_thumbs(self, media):
        # Never stop the playing file's thumbnails because another file was opened.
        keep = [self.session.media] if self.session else []
        try:
            return self.thumbs.info(media, keep)
        except OSError:
            return None

    def thumbnails(self, path, make=True):
        media = self._media(path)
        info = self._ensure_thumbs(media) if make else self.thumbs.existing(media)
        if info is None:
            raise ApiError("thumbnails are not available for this file")
        return info

    def ocr(self, path, subtitle):
        """Status of the text recognition for a picture subtitle track (starts it)."""
        media = self._media(path)
        try:
            sub = media.subs[int(subtitle) - 1]
        except (ValueError, IndexError) as e:
            raise ApiError("invalid subtitle id") from e
        if not sub.via_ocr:
            return {"status": "not_needed", "progress": 1.0, "error": None}
        return ocrsubs.status(media, sub)

    def recent(self, limit):
        return {"items": history.recent(limit)}

    def devices_json(self, refresh, probe_only):
        if refresh or not self.devices.devices:
            self.call(self.devices.scan())
        elif probe_only:
            self.call(self.devices.probe())
        return {"scanning": self.devices.scanning, "devices": self.devices.list_json()}

    def set_telemetry_level(self, level):
        if level not in RTT_INTERVALS:
            raise ApiError(f"level must be one of {', '.join(RTT_INTERVALS)}")
        self.telemetry_level = level
        if self.session:
            self.session.telemetry_level = level
        return {"ok": True}

    def pair(self, device_id):
        try:
            self.call(self.devices.pair_begin(device_id))
        except Exception as e:
            raise ApiError(f"could not start pairing: {e}") from e
        return {"ok": True}

    def pair_pin(self, pin):
        try:
            self.call(self.devices.pair_finish(str(pin)))
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "error": str(e) or type(e).__name__}
        return {"ok": True}

    # ---- playback ---------------------------------------------------------

    def play(self, body):
        media = self._media(body.get("path") or "")
        try:
            audio = media.audio[int(body.get("audio") or media.default_audio) - 1]
            sub_id = int(body.get("subtitle") or 0)
            sub = media.subs[sub_id - 1] if sub_id else None
        except (IndexError, ValueError) as e:
            raise ApiError("invalid track selection") from e
        try:
            start_position = float(body.get("start_position") or 0)
        except (TypeError, ValueError) as e:
            raise ApiError("start_position must be a number of seconds") from e
        try:
            subtitle_delay = max(-60.0, min(60.0, float(body.get("subtitle_delay") or 0)))
        except (TypeError, ValueError) as e:
            raise ApiError("subtitle_delay must be a number of seconds") from e
        device_id = body.get("device_id")
        conf = self.devices.get(device_id)
        if airplay.local_only() and (conf is None or not airplay.is_simulated(conf)):
            raise ApiError("local-only mode: only This Mac and simulated devices can play")
        if conf is None:
            known = self.devices.reach.known.get(device_id)
            if known:
                raise ApiError(f"{known['name']} is offline")
            raise ApiError("unknown device - refresh the device list")
        if self.devices.needs_pairing(conf):
            raise ApiError(f"{conf.name} must be paired first")

        async def start():
            if self.session:
                await self.session.stop()
            self.session = Session(self.telemetry, self.devices, media, audio, sub, conf,
                                   stereo=bool(body.get("stereo")), workdir=self.workdir,
                                   start_position=start_position, subtitle_delay=subtitle_delay,
                                   telemetry_level=self.telemetry_level)
            self.session.start()

        self.call(start())
        self._ensure_thumbs(media)
        if not airplay.is_simulated(conf):
            airplay.save_state({**airplay.load_state(), "last_device": conf.identifier})
        return {"ok": True}

    def control(self, body):
        s = self.session
        if s is None:
            raise ApiError("nothing is playing")
        action = body.get("action")
        coro = {
            "pause": s.pause,
            "resume": s.resume,
            "stop": s.stop,
            "seek": lambda: s.seek(body.get("position", 0)),
            "skip": lambda: s.skip(body.get("seconds", 0)),
            "volume": lambda: s.volume(body.get("step"), body.get("level")),
        }.get(action)
        if coro is None:
            raise ApiError(f"unknown action {action!r}")
        try:
            self.call(coro(), timeout=15)
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "error": str(e) or type(e).__name__}
        return {"ok": True}

    # ---- "This Mac" player window -----------------------------------------

    def local_player_json(self):
        """What the app's player window should play, while a session plays to This Mac."""
        local = getattr(self.devices, "local", None)
        if local is None or self.session is None or not airplay.is_local(self.session.conf):
            return None
        return local.state_json()

    def local_report(self, body):
        local = getattr(self.devices, "local", None)
        if local is None:
            raise ApiError("no local player")
        try:
            self.call(local.report(body), timeout=5)
        except RuntimeError as e:
            raise ApiError(str(e), status=409) from e
        return {"ok": True}

    def state(self, since):
        async def snapshot():
            base = {"phase": "idle", "session": None, "prep": None, "playback": None,
                    "network": None,
                    "diagnosis": {"status": "unknown", "headline": "Nothing playing",
                                  "details": [], "suspects": []}}
            if self.session:
                base.update(self.session.state_json())
            return base

        result = self.call(snapshot(), timeout=10)
        result["local_player"] = self.local_player_json()
        seq, samples, requests, events = self.telemetry.snapshot(since)
        result.update(seq=seq, now=time.time(), telemetry_level=self.telemetry_level,
                      pairing=self.devices.pairing_state,
                      samples=samples, requests=requests, events=events)
        return result


def int_param(q, name, default):
    try:
        return int(q.get(name) or default)
    except ValueError as e:
        raise ApiError(f"{name} must be an integer") from e


class ApiHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _send_file(self, path):
        body = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "image/jpeg")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "max-age=86400")
        self.end_headers()
        self.wfile.write(body)

    def _send(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _handle(self, fn):
        try:
            self._send(200, fn())
        except ApiError as e:
            self._send(e.status, {"ok": False, "error": str(e)})
        except Exception as e:  # noqa: BLE001
            traceback.print_exc()
            self._send(500, {"ok": False, "error": f"{type(e).__name__}: {e}"})

    def do_GET(self):
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        c = self.server.controller
        if url.path.startswith("/api/thumbs/"):
            _, _, rest = url.path.partition("/api/thumbs/")
            key, _, name = rest.partition("/")
            f = c.thumbs.file(key, name)
            if f is None:
                self._send(404, {"ok": False, "error": "no such thumbnail"})
            else:
                self._send_file(f)
            return
        routes = {
            "/api/health": lambda: {"ok": True, "version": __version__,
                                    "missing_tools": ensure_tool_path()},
            "/api/state": lambda: c.state(int_param(q, "since", 0)),
            "/api/devices": lambda: c.devices_json(q.get("refresh") == "1", q.get("probe") == "1"),
            "/api/probe": lambda: c.probe(q.get("path", ""), q.get("remember") != "0"),
            "/api/recent": lambda: c.recent(int_param(q, "limit", 20)),
            "/api/ocr": lambda: c.ocr(q.get("path", ""), q.get("subtitle", "0")),
            "/api/thumbs": lambda: c.thumbnails(q.get("path", ""), q.get("make") != "0"),
        }
        fn = routes.get(url.path)
        if fn is None:
            self._send(404, {"ok": False, "error": "not found"})
        else:
            self._handle(fn)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            self._send(400, {"ok": False, "error": "invalid JSON"})
            return
        if not isinstance(body, dict):
            self._send(400, {"ok": False, "error": "request body must be a JSON object"})
            return
        c = self.server.controller
        routes = {
            "/api/play": lambda: c.play(body),
            "/api/control": lambda: c.control(body),
            "/api/pair": lambda: c.pair(body.get("device_id")),
            "/api/pair/pin": lambda: c.pair_pin(body.get("pin", "")),
            "/api/telemetry": lambda: c.set_telemetry_level(body.get("level")),
            "/api/local/report": lambda: c.local_report(body),
        }
        fn = routes.get(urlparse(self.path).path)
        if fn is None:
            self._send(404, {"ok": False, "error": "not found"})
        else:
            self._handle(fn)


def serve(port=0, workdir=None, simulate=None, sim_speed=None):
    controller = Controller(workdir, simulate, sim_speed)
    # Build the OCR helper now (once, ~15 s) rather than when subtitles are needed.
    threading.Thread(target=ocrsubs.prepare, daemon=True).start()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), ApiHandler)
    server.daemon_threads = True
    server.controller = controller
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print("JANCAST_READY " + json.dumps({"port": server.server_address[1]}), flush=True)

    # SIGTERM (the app quitting, or `kill`) stops like EOF does, so the
    # session still removes its work dir (a full-size copy of the stream).
    def on_sigterm(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, on_sigterm)

    # The app keeps our stdin open; EOF means it went away.
    try:
        while sys.stdin.read(1024):
            pass
    except KeyboardInterrupt:
        pass
    signal.signal(signal.SIGTERM, signal.SIG_IGN)     # don't cut the cleanup short
    controller.thumbs.stop_all()
    if controller.session:
        try:
            controller.call(controller.session.stop(), timeout=10)
        except Exception:  # noqa: BLE001
            pass
    server.shutdown()
