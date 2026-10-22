"""URL playback for tvOS 18+: the AirPlay remote-control play queue.

tvOS 26 accepts the classic `POST /play` but then answers every
`GET /playback-info` with an empty HTTP 500 and never loads the URL - not
even Apple's own sample streams (pyatv 0.18 is affected, upstream issue
#2906). Current senders instead open a *remote-control stream* (RTSP SETUP
with stream type 130) on the same encrypted AirPlay 2 connection and drive
it with plist commands posted to `/command`:

    insertPlayQueueItem {item: {Content-Location, Start-Position (CMTime)}}
    setProperty actionAtItemEnd / setRate

Status is requested with a `playbackInfo` command; the receiver answers -
and pushes `playbackState` changes - over the encrypted event channel that
pyatv already opens, wrapped as a nested binary plist in `params.data`.
Times are CMTime dicts ({value, timescale, flags, epoch}).

Flow and field names follow node-appletv-remote's implementation (MIT,
github.com/energee/node-appletv-remote, src/airplay-playback.ts), which was
verified on tvOS 26.6.

Older receivers that reject the type-130 SETUP get the classic /play flow.
"""

import asyncio
import logging
import plistlib
import time
from uuid import uuid4

from pyatv import exceptions
from pyatv.protocols.airplay import channels as _channels
from pyatv.protocols.airplay import player as _player
from pyatv.protocols.raop.protocols.airplayv2 import AirPlayV2
from pyatv.support.http import HttpResponse, decode_bplist_from_body

# Under "pyatv." so Session's log handler shows warnings in the event log.
_LOGGER = logging.getLogger("pyatv.jancast.queue")

REMOTE_CONTROL_CLIENT_TYPE = "A6B27562-B43A-4F2D-B75F-82391E250194"
STATUS_TIMEOUT_S = 5
STARTUP_GRACE_S = 30        # loading longer than this = the TV can't play the URL
MAX_STATUS_FAILURES = 10    # consecutive unanswered status requests = give up

_event_sinks = []           # callables receiving each decoded event-channel message


# ---- event channel ---------------------------------------------------------

def _decode_event(body):
    """The inner plist of an event-channel /command, or None."""
    try:
        outer = plistlib.loads(body)
        data = outer.get("params", {}).get("data") if isinstance(outer, dict) else None
        return plistlib.loads(data) if isinstance(data, bytes) else None
    except Exception:  # noqa: BLE001 - not every event carries a nested plist
        return None


def _handle_received(self):
    """pyatv's EventChannel.handle_received, plus handing each message's
    payload to our sinks (pyatv only acknowledges and drops them)."""
    while self.buffer:
        try:
            request, _, self.buffer = self.parse_request(self.buffer)
            if request is None:
                break
            event = _decode_event(request.body) if request.body else None
            if event is not None:
                for sink in list(_event_sinks):
                    sink(event)
            headers = {"Content-Length": "0", "Audio-Latency": "0"}
            for key in ("Server", "CSeq"):
                if key in request.headers:
                    headers[key] = request.headers[key]
            self.send(self.format_response(
                HttpResponse(request.protocol, request.version, 200, "OK", headers, b"")))
        except Exception:  # noqa: BLE001
            _LOGGER.debug("Failed to handle message on event channel", exc_info=True)


_channels.EventChannel.handle_received = _handle_received


# ---- helpers ---------------------------------------------------------------

def cmtime(seconds):
    return {"value": int(round(seconds * 1000)), "timescale": 1000, "flags": 1, "epoch": 0}


def _seconds(value):
    if isinstance(value, dict) and "value" in value and "timescale" in value:
        if not (int(value.get("flags", 0)) & 1) or not value["timescale"]:
            return None
        return value["value"] / value["timescale"]
    return value


def normalize(obj):
    """Replace CMTime dicts with seconds, recursively."""
    if isinstance(obj, dict):
        if "value" in obj and "timescale" in obj:
            return _seconds(obj)
        return {k: normalize(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [normalize(v) for v in obj]
    return obj


def to_playback_report(info, pushed_state):
    """Turn a queue `playbackInfo` reply into the classic /playback-info shape
    the rest of jancast understands (position/duration/rate in seconds)."""
    report = normalize(info)
    state = info.get("playbackState") or pushed_state or "loading"
    report["playbackState"] = state
    if state in ("playing", "paused"):
        report.setdefault("rate", 1.0 if state == "playing" else 0.0)
        if state == "paused":
            report["rate"] = 0.0
    else:
        report.pop("duration", None)        # not playing yet / anymore
    return report


# ---- the queue session -----------------------------------------------------

class QueuePlayback:
    def __init__(self, rtsp):
        self.rtsp = rtsp
        self.stream_id = None
        self.session_id = str(uuid4()).upper()
        self.pushed_state = None
        self._message_id = 0
        self._waiters = {}

    def on_event(self, event):
        if event.get("kind") == "response" and event.get("messageID") in self._waiters:
            fut = self._waiters[event["messageID"]]
            if not fut.done():
                fut.set_result(event.get("info") or {})
        elif event.get("type") == "playbackState" and isinstance(event.get("name"), str):
            self.pushed_state = event["name"]
            _LOGGER.debug("Pushed playback state: %s", self.pushed_state)

    async def command(self, data):
        body = plistlib.dumps({"params": {"data": plistlib.dumps(data, fmt=plistlib.FMT_BINARY)}},
                              fmt=plistlib.FMT_BINARY)
        headers = {
            "Content-Type": "application/x-apple-binary-plist",
            "X-Apple-ProtocolVersion": "1",
            "X-Apple-Session-ID": self.session_id,
            "X-Apple-StreamID": str(self.stream_id),
            "DACP-ID": self.rtsp.dacp_id,
            "Active-Remote": self.rtsp.active_remote,
            "Client-Instance": self.rtsp.dacp_id,
        }
        resp = await self.rtsp.connection.post("/command", headers=headers, body=body,
                                               allow_error=True)
        if resp.code >= 300:
            raise exceptions.PlaybackError(f"Apple TV answered {resp.code} to {data.get('type')}")
        return resp

    async def open(self):
        """SETUP the remote-control stream. Raises HttpError if unsupported."""
        resp = await self.rtsp.setup(body={"streams": [{
            "type": 130, "controlType": 1,
            "channelID": str(uuid4()).upper(), "clientUUID": str(uuid4()).upper(),
            "clientTypeUUID": REMOTE_CONTROL_CLIENT_TYPE,
        }]})
        streams = decode_bplist_from_body(resp).get("streams") or [{}]
        self.stream_id = streams[0].get("streamID")
        if self.stream_id is None:
            raise exceptions.HttpError("remote-control SETUP returned no streamID", resp.code)

    async def play(self, url, position=0.0):
        item = {"uuid": str(uuid4()).upper(), "mediaType": "file", "Content-Location": url}
        if position:
            # tvOS reads the start as a CMTime; Start-Position-Seconds is ignored.
            item["Start-Position"] = cmtime(position)
        await self.command({"type": "insertPlayQueueItem", "item": item})
        await self.command({"type": "setProperty", "property": "actionAtItemEnd", "value": 1})
        await self.command({"type": "setRate", "rate": 1.0})

    async def status(self):
        self._message_id += 1
        mid = self._message_id
        fut = asyncio.get_running_loop().create_future()
        self._waiters[mid] = fut
        try:
            await self.command({"type": "playbackInfo", "kind": "request", "messageID": mid})
            return await asyncio.wait_for(fut, STATUS_TIMEOUT_S)
        finally:
            self._waiters.pop(mid, None)

    async def control(self, path):
        """Map the classic control paths Session sends onto queue commands."""
        if path.startswith("/rate?value="):
            await self.command({"type": "setRate", "rate": float(path.split("=", 1)[1])})
        elif path.startswith("/scrub?position="):
            await self.seek(float(path.split("=", 1)[1]))
        elif path == "/stop":
            await self.command({"type": "setRate", "rate": 0.0})
        else:
            raise RuntimeError(f"unsupported control {path}")

    async def seek(self, position):
        await self.command({"type": "seek", "time": cmtime(position)})

    async def wait_until_done(self, report):
        """Poll status once a second, feeding `report` until playback ends."""
        started = False
        failures = 0
        began = time.monotonic()
        while True:
            try:
                info = await self.status()
                failures = 0
            except asyncio.TimeoutError:
                failures += 1
                report({"_http_status": "no reply"})
                if failures >= MAX_STATUS_FAILURES:
                    raise exceptions.PlaybackError("Apple TV stopped answering status requests")
                continue
            _LOGGER.debug("playbackInfo: %s", info)
            if info.get("error"):
                err = info["error"]
                code = err.get("code", "unknown") if isinstance(err, dict) else err
                domain = err.get("domain", "unknown domain") if isinstance(err, dict) else ""
                report({"error": err})
                raise exceptions.PlaybackError(f"got error {code} ({domain}) when playing video")
            playback = to_playback_report(info, self.pushed_state)
            report(playback)
            state = playback["playbackState"]
            if state in ("playing", "paused"):
                started = True
            elif state == "stopped" and started:
                return          # finished, or stopped on the TV
            elif not started and time.monotonic() - began > STARTUP_GRACE_S:
                raise exceptions.PlaybackError(
                    f"Apple TV did not start playing within {STARTUP_GRACE_S} s "
                    f"(state: {state}) - it may not be able to reach or play the stream")
            await asyncio.sleep(1)


# ---- AirPlayPlayer.play_url replacement ------------------------------------

_orig_play_url = _player.AirPlayPlayer.play_url
_hooks = {"report": None, "set_target": None, "clear_target": None}


def install(report, set_command_target, clear_command_target):
    """Route pyatv URL playback through the queue (called by airplay.py)."""
    _hooks.update(report=report, set_target=set_command_target, clear_target=clear_command_target)
    _player.AirPlayPlayer.play_url = _play_url


async def _play_url(self, url, position=0):
    if not isinstance(self.stream_protocol, AirPlayV2):
        return await _orig_play_url(self, url, position)

    async with _player.timing_server(self.rtsp) as server:
        proto = self.stream_protocol
        await proto._setup_base(server.port)
        await proto.start_feedback()
        await self.rtsp.record()

        queue = QueuePlayback(self.rtsp)
        try:
            await queue.open()
        except exceptions.HttpError as e:
            _LOGGER.info("Remote-control queue not supported (%s); using classic /play", e)
            await _classic_play(self, url, position)
            return

        _event_sinks.append(queue.on_event)
        _hooks["set_target"](queue.control)
        try:
            await queue.play(url, position)
            await queue.wait_until_done(_hooks["report"])
        finally:
            _hooks["clear_target"](queue.control)
            if queue.on_event in _event_sinks:
                _event_sinks.remove(queue.on_event)
            proto.teardown()


async def _classic_play(player, url, position):
    """The pre-tvOS 18 flow on an already set-up session: POST /play, start, poll."""
    body = {"Content-Location": url, "Start-Position-Seconds": position,
            "uuid": str(uuid4()), "streamType": 1, "mediaType": "file", "rate": 1.0}
    resp = await player.rtsp.connection.post(
        "/play", headers=_player.HEADERS,
        body=plistlib.dumps(body, fmt=plistlib.FMT_BINARY), allow_error=True)
    if resp.code >= 400:
        raise exceptions.PlaybackError(f"Apple TV answered {resp.code} to /play")
    await player.rtsp.exchange("POST", uri="/rate?value=1.000000")
    await player._wait_for_media_to_end()
