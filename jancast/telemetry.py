"""Thread-safe telemetry: 1 Hz samples, HLS request log, events and diagnosis."""

import collections
import statistics
import sys
import threading
import time

MAX_SAMPLES = 3600
MAX_REQUESTS = 2000
MAX_EVENTS = 1000
INITIAL_SAMPLES = 900
INITIAL_REQUESTS = 400
INITIAL_EVENTS = 300
# Phases in which the Apple TV is expected to send playback reports.
REPORTING_PHASES = ("buffering", "playing", "paused", "stalled")
# A seek makes the TV drop its in-flight transfers: aborts that end this long
# after session["last_seek_at"] (or up to SEEK_GRACE_BEFORE_S before it, for
# clock/ordering slack) are the user's doing, not the network's.
SEEK_GRACE_S = 3.0
SEEK_GRACE_BEFORE_S = 1.0


def _caused_by_seek(r, last_seek_at):
    if not last_seek_at:
        return False
    # r["t"] is when the request started; it ended duration_ms later.
    ended = r["t"] + (r.get("duration_ms") or 0) / 1000
    return last_seek_at - SEEK_GRACE_BEFORE_S <= ended <= last_seek_at + SEEK_GRACE_S


class Telemetry:
    def __init__(self, echo_events=False):
        self.lock = threading.RLock()
        self.echo_events = echo_events
        self.seq = 0
        self.samples = collections.deque(maxlen=MAX_SAMPLES)
        self.requests = collections.deque(maxlen=MAX_REQUESTS)
        self.events = collections.deque(maxlen=MAX_EVENTS)
        self.reset_counters()

    def reset_counters(self):
        with self.lock:
            self._tx_bytes = 0          # bytes sent since the last sample
            self._req_done = 0          # requests completed since the last sample
            self.http_errors = 0
            self.client_aborts = 0
            self.not_ready = 0
            self.rtt_ms = None
            self.rtt_history = collections.deque(maxlen=30)   # ms or None (timeout)

    def _next_seq(self):
        self.seq += 1
        return self.seq

    # ---- producers -------------------------------------------------------

    def event(self, level, source, message):
        with self.lock:
            self.events.append({"seq": self._next_seq(), "t": time.time(), "level": level,
                                "source": source, "message": message})
        if self.echo_events or level == "error":
            print(f"[{source}] {message}", file=sys.stderr)

    def add_tx_bytes(self, n):
        with self.lock:
            self._tx_bytes += n

    def request(self, entry):
        with self.lock:
            entry["seq"] = self._next_seq()
            self.requests.append(entry)
            self._req_done += 1
            if entry["error"] == "client aborted":
                self.client_aborts += 1
            elif entry["status"] == 404:
                self.not_ready += 1
            elif entry["status"] >= 500:
                self.http_errors += 1

    def rtt(self, ms):
        with self.lock:
            self.rtt_ms = ms
            self.rtt_history.append(ms)

    def sample(self, fields):
        """Record one 1 Hz sample; tx/request counters are drained here."""
        with self.lock:
            s = {"seq": self._next_seq(), "t": time.time(),
                 "tx_bps": self._tx_bytes * 8, "requests": self._req_done,
                 "rtt_ms": self.rtt_ms, **fields}
            self._tx_bytes = 0
            self._req_done = 0
            self.samples.append(s)
            return s

    # ---- consumers -------------------------------------------------------

    def since(self, seq):
        with self.lock:
            if not seq:
                return (list(self.samples)[-INITIAL_SAMPLES:],
                        list(self.requests)[-INITIAL_REQUESTS:],
                        list(self.events)[-INITIAL_EVENTS:])
            return ([s for s in self.samples if s["seq"] > seq],
                    [r for r in self.requests if r["seq"] > seq],
                    [e for e in self.events if e["seq"] > seq])

    def snapshot(self, seq):
        """Like since(), plus the current seq read under the same lock, so a
        poller that sends the returned seq back never skips an item that was
        added between reading the collections and reading the seq."""
        with self.lock:
            samples, requests, events = self.since(seq)
            return self.seq, samples, requests, events

    def recent_samples(self, seconds):
        cutoff = time.time() - seconds
        with self.lock:
            return [s for s in self.samples if s["t"] >= cutoff]

    def recent_requests(self, seconds):
        cutoff = time.time() - seconds
        with self.lock:
            return [r for r in self.requests if r["t"] >= cutoff]

    def network_summary(self):
        with self.lock:
            last10 = [s["tx_bps"] for s in list(self.samples)[-10:]]
            rtts = [r for r in self.rtt_history if r is not None]
            return {
                "tx_bps_now": last10[-1] if last10 else 0,
                "tx_bps_avg10": int(sum(last10) / len(last10)) if last10 else 0,
                "rtt_ms": self.rtt_ms,
                "rtt_ms_avg": round(statistics.mean(rtts), 1) if rtts else None,
                "rtt_loss": (round(1 - len(rtts) / len(self.rtt_history), 2)
                             if self.rtt_history else 0.0),
                "http_errors": self.http_errors,
                "client_aborts": self.client_aborts,
            }


def diagnose(phase, session, prep, playback, network, telemetry):
    """Rule-based guess at what is (or is about to go) wrong.

    Each suspect gets a confidence in 0..1 from simple, explainable evidence;
    the strongest one drives the status and headline.
    """
    if session is None:
        return {"status": "unknown", "headline": "Nothing playing", "details": [],
                "suspects": []}

    bitrate = session.get("stream_bitrate_bps") or 0
    started_at = session.get("started_at") or 0
    # Only this session's requests: the log is shared with the previous session.
    reqs = [r for r in telemetry.recent_requests(60) if r["t"] >= started_at]
    segs = [r for r in reqs
            if r["kind"] == "segment" and r["status"] == 200 and r.get("realtime_ratio")]
    ratios = [r["realtime_ratio"] for r in segs[-10:]]
    median_ratio = statistics.median(ratios) if ratios else None
    # A 404 for e.g. /favicon.ico says nothing about the encoder.
    not_ready = [r for r in reqs if r["status"] == 404 and r["kind"] in ("segment", "audio", "subtitle")]
    last_seek_at = session.get("last_seek_at")
    aborts = [r for r in reqs if r["error"] == "client aborted"
              and not _caused_by_seek(r, last_seek_at)]
    server_errors = [r for r in reqs if r["status"] >= 500]
    buffered = playback.get("buffered_ahead_s")
    stalled = phase == "stalled"
    segment_duration = session.get("segment_duration_s") or 6
    details = []
    suspects = []

    # Encoder / preparation too slow.
    enc, enc_ev = 0.0, "Stream fully prepared" if prep.get("done") else "Preparing ahead of playback"
    if prep.get("error"):
        enc, enc_ev = 1.0, f"ffmpeg failed: {prep['error']}"
    elif not prep.get("done"):
        headroom = (prep.get("prepared_s") or 0) - (playback.get("position") or 0)
        short = headroom < 2 * segment_duration and playback.get("position")
        if short and prep.get("on_demand"):
            # Fast start makes segments as the TV asks for them, so little made
            # ahead is normal (right after a jump: nothing yet). It only says
            # something while the TV plays on a short buffer too.
            short = (phase in ("playing", "stalled") and buffered is not None
                     and buffered < 2 * segment_duration)
        speed = prep.get("speed")
        found = []          # (confidence, evidence); the strongest one is reported
        if not_ready:
            found.append((0.9, f"Apple TV asked for {len(not_ready)} segment(s) that were "
                               f"not prepared yet"))
        if speed is not None and speed < 1.05 and playback.get("position") is not None:
            found.append((0.6 if headroom < 30 else 0.3,
                          f"ffmpeg runs at {speed:.2f}x realtime, headroom {headroom:.0f} s"))
        elif short:
            found.append((0.5, f"Only {headroom:.0f} s prepared ahead of playback"))
        if found:
            enc, enc_ev = max(found, key=lambda f: f[0])
    suspects.append({"cause": "encoder", "confidence": enc, "evidence": enc_ev})

    # Network between this Mac and the Apple TV.
    net, net_ev = 0.0, "Segments arrive quickly"
    if median_ratio is not None:
        net_ev = f"Segments download at {median_ratio:.1f}x realtime (median of last {len(ratios)})"
        if median_ratio < 1.0:
            net = 0.9
        elif median_ratio < 1.5:
            net = 0.6
        elif median_ratio < 3:
            net = 0.25
        if playback.get("buffer_full") and not stalled and net > 0.25:
            # The TV has a full buffer, so it isn't pulling (or pulls lazily):
            # transfer speed now says nothing about whether delivery keeps up.
            # Latency, loss and aborts below still count.
            net = 0.25
            net_ev += ", but the Apple TV buffer is full"
    rtt_avg, loss = network.get("rtt_ms_avg"), network.get("rtt_loss") or 0
    if loss >= 0.2:
        net = max(net, 0.7)
        net_ev += f"; {loss:.0%} of latency probes to the TV time out"
    elif rtt_avg is not None and rtt_avg > 80:
        net = max(net, 0.5)
        net_ev += f"; high latency to the TV ({rtt_avg:.0f} ms)"
    if aborts:
        net = max(net, 0.4)
        net_ev += f"; {len(aborts)} transfer(s) aborted by the TV"
    if stalled and net < 0.5 and median_ratio is not None and median_ratio < 3:
        net = 0.6
    suspects.append({"cause": "network", "confidence": net, "evidence": net_ev})

    # Apple TV itself (decoder, player errors, unresponsive).
    dev, dev_ev = 0.0, "Apple TV reports normally"
    if playback.get("error"):
        dev, dev_ev = 0.95, f"Apple TV reported: {playback['error']}"
    elif (phase in REPORTING_PHASES and playback.get("last_report_at")
          and time.time() - playback["last_report_at"] > 6):
        dev, dev_ev = 0.6, "Apple TV stopped answering playback status requests"
    elif stalled and (median_ratio or 0) >= 3 and not not_ready:
        dev, dev_ev = 0.6, "Stalled although data arrives fast - the TV may fail to decode"
    elif (stalled and median_ratio is None and (buffered or 0) >= 2 * segment_duration
          and not not_ready):
        # A hung TV with a full buffer fetches nothing, so the ratio evidence
        # above expires after the 60 s window; the buffer itself still says
        # the data is there and the TV isn't playing it. (Recent slow ratios
        # point at the network instead - left to the rules above.)
        dev, dev_ev = 0.6, (f"Stalled with {buffered:.0f} s buffered - the TV isn't playing "
                            f"data it already has")
    suspects.append({"cause": "device", "confidence": dev, "evidence": dev_ev})

    # Source file (corrupt data, unsupported content).
    src, src_ev = 0.0, "No source problems detected"
    with telemetry.lock:
        events = list(telemetry.events)
    bad = [e for e in events if e["source"] == "ffmpeg" and e["level"] != "info"
           and e["t"] >= started_at
           and any(k in e["message"].lower() for k in ("invalid", "corrupt", "error", "missing"))]
    if bad:
        src = min(0.8, 0.2 + 0.1 * len(bad))
        src_ev = f"ffmpeg reported {len(bad)} data problem(s), e.g. \"{bad[-1]['message'][:80]}\""
    suspects.append({"cause": "source", "confidence": src, "evidence": src_ev})

    # Our HTTP server.
    srv, srv_ev = 0.0, "HTTP server healthy"
    if server_errors:
        srv, srv_ev = 0.8, f"{len(server_errors)} HTTP 5xx response(s) in the last minute"
    suspects.append({"cause": "server", "confidence": srv, "evidence": srv_ev})

    suspects.sort(key=lambda s: s["confidence"], reverse=True)
    top = suspects[0]

    if bitrate and network.get("tx_bps_avg10"):
        details.append(f"Stream needs {bitrate / 1e6:.1f} Mbit/s; last 10 s delivered "
                       f"{network['tx_bps_avg10'] / 1e6:.1f} Mbit/s on average")
    if buffered is not None:
        details.append(f"Apple TV has {buffered:.0f} s buffered")
    if playback.get("stall_count"):
        details.append(f"{playback['stall_count']} stall(s), "
                       f"{playback.get('stalled_s_total', 0):.0f} s in total")

    names = {"encoder": "Preparing the stream is too slow",
             "network": "The network to the Apple TV is too slow",
             "device": "The Apple TV has a playback problem",
             "source": "The source file has damaged or unsupported data",
             "server": "The local stream server is failing"}

    if phase == "failed":
        status = "failed"
        headline = names[top["cause"]] if top["confidence"] >= 0.3 else "Playback failed"
    elif phase in ("finished", "stopped"):
        # Over: stopping ffmpeg / the TV going quiet afterwards is expected.
        status = "ok"
        headline = "Playback finished" if phase == "finished" else "Stopped"
    elif stalled or (buffered is not None and buffered < 4 and phase == "playing"
                     and top["confidence"] >= 0.5):
        status = "failing"
        headline = names[top["cause"]] if top["confidence"] >= 0.3 else "Playback stalled"
    elif top["confidence"] >= 0.5:
        status = "warning"
        headline = names[top["cause"]].replace(" is too slow", " is barely keeping up")
    else:
        status = "ok"
        headline = "Streaming healthy"
    return {"status": status, "headline": headline, "details": details, "suspects": suspects}
