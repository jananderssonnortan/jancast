"""Apple TV discovery, pairing and URL playback via pyatv, with telemetry hooks."""

import asyncio
import json
import os
import time
from pathlib import Path

import pyatv
from pyatv.const import PairingRequirement, Protocol
from pyatv.protocols.airplay import player as _player
from pyatv.storage.file_storage import FileStorage
from pyatv.support.net import get_local_address_reaching

from .config import config_dir
from .reach import Reachability

STATUS_ORDER = {"online": 0, "not_responding": 1, "offline": 2}

# pyatv polls /playback-info once a second while a URL plays but keeps the
# result to itself. Wrap its decoder so every report also reaches us, and
# remember the player's connection so we can send pause/seek on it.
# The simulated Apple TV (simulator.py) feeds the same two hooks: it calls
# _report() with its own playback-info dicts and installs its own command target.
_playback_listeners = []
_active = {"send": None}     # async fn(path) delivering a control request to the TV
_orig_decode = _player.decode_bplist_from_body
_orig_init = _player.AirPlayPlayer.__init__


def _report(parsed):
    """Hand one /playback-info report (a dict) to every listener."""
    for listener in list(_playback_listeners):
        listener(parsed)


def _decode_and_report(resp):
    parsed = _orig_decode(resp)
    _report(parsed)
    return parsed


def _init_and_remember(self, rtsp, stream_protocol):
    _orig_init(self, rtsp, stream_protocol)

    async def send(path):
        resp = await rtsp.connection.post(path, allow_error=True)
        if resp.code >= 400:
            raise RuntimeError(f"Apple TV answered {resp.code} to {path}")

    _active["send"] = send


STARTUP_GRACE_S = 30     # how long the TV may take to start reporting playback
END_AFTER_MISSES = 5     # reports without media after playback started = it ended
MAX_STATUS_ERRORS = 10   # consecutive HTTP errors while playing = give up
LOST_AFTER_SILENCE_S = 8  # no status answer for this long (wall clock), then the connection was lost


async def _wait_for_media_to_end(self):
    """Replacement for pyatv's AirPlayPlayer._wait_for_media_to_end.

    pyatv treats any HTTP error from /playback-info as fatal. A real Apple TV
    (tvOS 26) answers the first polls with "500 Internal Server Error" while
    its player is still being created - before it has even fetched the
    playlist - so pyatv aborted and closed the connection, which stops the TV.
    Here errors and empty reports are expected during startup; we only give up
    when the TV never starts, reports a player error, or keeps failing.
    """
    started = False
    misses = 0
    errors = 0
    loop = asyncio.get_running_loop()
    began = loop.time()
    answered = time.time()   # wall clock: the monotonic one stands still while the Mac sleeps
    while True:
        try:
            resp = await self.rtsp.connection.get("/playback-info", allow_error=True)
        except (RuntimeError, _player.exceptions.ConnectionLostError):
            # The TV closes the connection when playback is stopped there (Menu
            # on the remote): the end. After a silence the connection was lost
            # instead (the Mac slept, the network hung): raise, the session
            # reconnects.
            if time.time() - answered > LOST_AFTER_SILENCE_S:
                raise _player.exceptions.ConnectionLostError(
                    f"connection was lost (no answer for {time.time() - answered:.0f} s)") from None
            break
        answered = time.time()
        parsed = {}
        if resp.code >= 400:
            errors += 1
            _report({"_http_status": resp.code})
            if started and errors >= MAX_STATUS_ERRORS:
                raise _player.exceptions.PlaybackError(
                    f"Apple TV keeps answering playback status with HTTP {resp.code}")
        else:
            errors = 0
            if resp.body:
                parsed = _player.decode_bplist_from_body(resp)   # reports to listeners

        if "error" in parsed:
            err = parsed["error"]
            code = err.get("code", "unknown") if isinstance(err, dict) else err
            domain = err.get("domain", "unknown domain") if isinstance(err, dict) else ""
            raise _player.exceptions.PlaybackError(
                f"got error {code} ({domain}) when playing video")

        if "duration" in parsed:
            started = True
            misses = 0
        elif started:
            misses += 1
            if misses >= END_AFTER_MISSES:
                break       # media ended or was stopped on the TV
        elif loop.time() - began > STARTUP_GRACE_S:
            raise _player.exceptions.PlaybackError(
                f"Apple TV did not start playing within {STARTUP_GRACE_S} s"
                + (f" (playback status answered HTTP {resp.code})" if resp.code >= 400 else ""))
        await asyncio.sleep(1)


_player.decode_bplist_from_body = _decode_and_report
_player.AirPlayPlayer.__init__ = _init_and_remember
_player.AirPlayPlayer._wait_for_media_to_end = _wait_for_media_to_end


def add_playback_listener(fn):
    _playback_listeners.append(fn)


def remove_playback_listener(fn):
    if fn in _playback_listeners:
        _playback_listeners.remove(fn)


def set_command_target(send):
    """Route send_command() to `send` (an async fn taking the request path)."""
    _active["send"] = send


def clear_command_target(send):
    if _active["send"] is send:
        _active["send"] = None


# tvOS 18+ only plays URLs through the remote-control play queue.
from . import airplay_queue  # noqa: E402

airplay_queue.install(_report, set_command_target, clear_command_target)


async def send_command(path):
    """Send an AirPlay control request (e.g. /rate?value=0) on the playing connection."""
    send = _active["send"]
    if send is None:
        raise RuntimeError("nothing is playing")
    await send(path)


def load_state():
    try:
        return json.loads((config_dir() / "state.json").read_text())
    except (FileNotFoundError, ValueError):
        return {}


def save_state(state):
    (config_dir() / "state.json").write_text(json.dumps(state, indent=2))


# A device is either a pyatv config or a simulator.SimulatedDevice (duck-typed:
# name, identifier, address, port, model_str, simulated=True). These helpers
# hide the difference from the rest of the code.

def local_only():
    """JANCAST_LOCAL_ONLY=1 (automated test runs): only This Mac and simulated
    devices exist; nothing can be sent to a real Apple TV."""
    return os.environ.get("JANCAST_LOCAL_ONLY") == "1"


def is_simulated(conf):
    return getattr(conf, "simulated", False)


def is_local(conf):
    """The "This Mac" player window (local_player.py): simulated-style plumbing,
    but real watching."""
    return getattr(conf, "local", False)


def airplay_port(conf):
    if is_simulated(conf):
        return conf.port
    return conf.get_service(Protocol.AirPlay).port or 7000


def device_model(conf):
    return conf.model_str if is_simulated(conf) else conf.device_info.model_str


def local_address_for(conf):
    if is_simulated(conf):
        return "127.0.0.1"
    return get_local_address_reaching(conf.address)


def plays_video(conf):
    """AirPlay receivers advertising video playback (feature bit 0), excluding
    this machine itself. Filters out speakers such as Sonos/HomePod."""
    service = conf.get_service(Protocol.AirPlay)
    if service is None:
        return False
    features = service.properties.get("features", "0").split(",")[0]
    try:
        video = int(features, 16) & 1
    except ValueError:
        video = 0
    return bool(video) and local_address_for(conf) != conf.address


class Devices:
    """Scanning, pairing and credentials (stored in ~/.config/jancast)."""

    def __init__(self, simulate=None, sim_speed=None):
        self.storage = None
        self.devices = {}          # identifier -> pyatv config (or simulated device)
        self.scanning = False
        self._pairing = None
        self.pairing_state = None  # {"device_id", "awaiting_pin", "error"}
        # Every real device ever seen, so switched-off TVs are listed as offline.
        self.reach = Reachability(load_state().get("known_devices"))
        # `simulate`: profile name(s), e.g. "slow" or "good,flaky" (see simulator.py).
        self.simulated = {}
        # "This Mac" is always there: play in the app's own window (local_player.py).
        from .local_player import LocalDevice
        self.local = LocalDevice()
        self.simulated[self.local.identifier] = self.local
        if simulate:
            from .simulator import SimulatedDevice, parse_profiles
            for name in parse_profiles(simulate):
                dev = SimulatedDevice(name, sim_speed)
                self.simulated[dev.identifier] = dev

    async def _storage(self):
        if self.storage is None:
            self.storage = FileStorage(str(config_dir() / "pyatv.json"),
                                       asyncio.get_running_loop())
            await self.storage.load()
        return self.storage

    async def scan(self, timeout=4):
        self.scanning = True
        try:
            # Test runs never see real Apple TVs (JANCAST_LOCAL_ONLY=1).
            confs = [] if local_only() else await pyatv.scan(
                asyncio.get_running_loop(), timeout=timeout, storage=await self._storage())
        finally:
            self.scanning = False
        self.devices = {c.identifier: c for c in confs if plays_video(c)}
        self.devices.update(self.simulated)
        self.reach.begin_scan()
        for c in self.devices.values():
            self.reach.saw(c.identifier, c.name, c.address, airplay_port(c), device_model(c),
                           **self._pairing_flags(c))
        await self.probe()
        return list(self.devices.values())

    async def probe(self):
        """Re-check which known devices answer, without a Bonjour scan."""
        await self.reach.probe_known()
        known = {i: d for i, d in self.reach.known.items() if i not in self.simulated}
        save_state({**load_state(), "known_devices": known})

    def status(self, device_id):
        return self.reach.status(device_id)

    def _pairing_flags(self, conf):
        if is_simulated(conf):
            return {"paired": False, "pairing_required": False}
        service = conf.get_service(Protocol.AirPlay)
        return {"paired": bool(service.credentials),
                "pairing_required": service.pairing == PairingRequirement.Mandatory}

    def list_json(self):
        """Every known device (seen now or earlier) with reachability, best first."""
        entries = [self.to_json(c) for c in self.devices.values()]
        listed = {e["id"] for e in entries}
        last = load_state().get("last_device")
        for device_id, d in self.reach.known.items():
            if device_id not in listed:
                entries.append({"id": device_id, "name": d["name"], "address": d["address"],
                                "model": d.get("model"), "paired": d.get("paired", False),
                                "pairing_required": d.get("pairing_required", False),
                                "last_used": last == device_id, **self.reach.to_json(device_id)})
        # "This Mac" answers in microseconds; list it after the real TVs anyway.
        entries.sort(key=lambda e: (STATUS_ORDER[e["status"]], e["id"] == self.local.identifier,
                                    e["rtt_ms"] if e["rtt_ms"] is not None else 1e9, e["name"]))
        return entries

    def get(self, device_id):
        return self.devices.get(device_id) or self.simulated.get(device_id)

    def find(self, wanted):
        """Match a user-supplied name, IP or identifier."""
        w = wanted.lower()
        for c in {**self.simulated, **self.devices}.values():
            if w in c.name.lower() or w == str(c.address) or w == (c.identifier or "").lower():
                return c
        return None

    @staticmethod
    def needs_pairing(conf):
        if is_simulated(conf):
            return False
        service = conf.get_service(Protocol.AirPlay)
        return service.pairing == PairingRequirement.Mandatory and not service.credentials

    def to_json(self, conf):
        return {
            "id": conf.identifier,
            "name": conf.name,
            "address": str(conf.address),
            "model": device_model(conf),
            **self._pairing_flags(conf),
            "last_used": load_state().get("last_device") == conf.identifier,
            **self.reach.to_json(conf.identifier),
        }

    async def pair_begin(self, device_id):
        conf = self.get(device_id)
        if conf is None:
            raise RuntimeError("unknown device")
        if is_simulated(conf):
            raise RuntimeError("simulated devices need no pairing")
        if self._pairing:
            await self._pairing.close()
        self._pairing = await pyatv.pair(conf, Protocol.AirPlay, asyncio.get_running_loop(),
                                         storage=await self._storage())
        await self._pairing.begin()
        self.pairing_state = {"device_id": device_id,
                              "awaiting_pin": self._pairing.device_provides_pin,
                              "error": None}
        if not self._pairing.device_provides_pin:
            await self.pair_finish(None)

    async def pair_finish(self, pin):
        if self._pairing is None:
            raise RuntimeError("no pairing in progress")
        device_id = self.pairing_state["device_id"]
        try:
            if pin is not None:
                self._pairing.pin(pin)
            await self._pairing.finish()
            if not self._pairing.has_paired:
                raise RuntimeError("pairing was not accepted")
        except Exception as e:
            self.pairing_state = {"device_id": device_id, "awaiting_pin": False,
                                  "error": str(e) or type(e).__name__}
            raise
        finally:
            await self._pairing.close()
            self._pairing = None
        await self.storage.save()
        self.pairing_state = None
        # Rescan so the config picks up the new credentials from storage.
        confs = await pyatv.scan(asyncio.get_running_loop(), identifier=device_id,
                                 storage=self.storage)
        for c in confs:
            self.devices[c.identifier] = c
            self.reach.saw(c.identifier, c.name, c.address, airplay_port(c), device_model(c),
                           **self._pairing_flags(c))

    async def connect(self, conf):
        if is_simulated(conf):
            return conf.connect()       # simulator.FakeAppleTV
        return await pyatv.connect(conf, asyncio.get_running_loop(),
                                   storage=await self._storage())
