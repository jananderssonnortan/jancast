"""Is an Apple TV actually within reach?

A Bonjour scan only proves a device is *advertised* - a sleeping Apple TV is
still announced by the network's sleep proxy, and stale entries linger. So we
also TCP-connect to each device's AirPlay port and remember every device we
have ever seen, which lets the UI tell apart:

  online          answers on its AirPlay port (with connect time in ms)
  not_responding  advertised, but the port does not answer (asleep, or a
                  firewall / client-isolated Wi-Fi in between)
  offline         seen before, not found on the network now
"""

import asyncio
import time

PROBE_TIMEOUT = 1.5


async def probe(address, port, timeout=PROBE_TIMEOUT):
    """TCP connect time in ms, or None if the port did not answer in time."""
    loop = asyncio.get_running_loop()
    t0 = loop.time()
    try:
        _, writer = await asyncio.wait_for(asyncio.open_connection(str(address), port), timeout)
    except (OSError, asyncio.TimeoutError):
        return None
    rtt = (loop.time() - t0) * 1000
    writer.close()
    return round(rtt, 1)


async def probe_all(targets, timeout=PROBE_TIMEOUT):
    """{id: rtt_ms | None} for targets given as {id: (address, port)}, probed concurrently."""
    ids = list(targets)
    results = await asyncio.gather(*(probe(*targets[i], timeout=timeout) for i in ids))
    return dict(zip(ids, results))


class Reachability:
    """Tracks every device ever seen and its latest probe result.

    `known` is persisted by the caller (it's a plain dict of plain values).
    """

    def __init__(self, known=None):
        # id -> {"name", "address", "port", "model", "last_seen"}
        self.known = dict(known or {})
        self.advertised = set()     # ids present in the latest scan
        self.rtt = {}               # id -> ms | None, from the latest probe
        self.probed_at = {}         # id -> epoch of the latest probe

    def saw(self, device_id, name, address, port, model, **extra):
        """Record a device found by a scan; `extra` (e.g. pairing flags) is kept
        so the device can still be described while it is offline."""
        self.advertised.add(device_id)
        self.known[device_id] = {"name": name, "address": str(address), "port": port,
                                 "model": model, "last_seen": time.time(), **extra}

    def begin_scan(self):
        self.advertised = set()

    async def probe_known(self):
        """Probe every known device (offline ones too - they may have come back)."""
        targets = {i: (d["address"], d["port"] or 7000) for i, d in self.known.items()}
        results = await probe_all(targets)
        now = time.time()
        for i, rtt in results.items():
            self.rtt[i] = rtt
            self.probed_at[i] = now
            if rtt is not None:
                self.known[i]["last_seen"] = now
        return results

    def status(self, device_id):
        rtt = self.rtt.get(device_id)
        if rtt is not None:
            return "online"
        if device_id in self.advertised:
            return "not_responding"
        return "offline"

    def to_json(self, device_id):
        """Reachability fields merged into a device entry of /api/devices."""
        d = self.known.get(device_id, {})
        return {
            "status": self.status(device_id),
            "reachable": self.rtt.get(device_id) is not None,
            "rtt_ms": self.rtt.get(device_id),
            "last_seen": d.get("last_seen"),
            "probed_at": self.probed_at.get(device_id),
        }
