#!/usr/bin/env python3
"""End-to-end check of the whole pipeline against the simulated Apple TV.

Creates a short test clip (testsrc2 1280x720 H.264 ~8 Mbit/s CBR + sine AAC +
an SRT subtitle track, muxed to .mkv), then for each simulator profile runs a
real Session (ffmpeg remux -> HLS server -> FakeAppleTV over HTTP -> playback
reports -> diagnose()), prints a compact 1 Hz timeline and checks that the
diagnosis blames the right cause.

    .venv/bin/python scripts/e2e_sim.py            # all profiles
    .venv/bin/python scripts/e2e_sim.py slow flaky # some
    .venv/bin/python scripts/e2e_sim.py --clip x.mkv --quiet
    .venv/bin/python scripts/e2e_sim.py stuck --long   # 90 s hang (+1 min)

Scenarios: good, slow, flaky, tv-error, stuck (one per simulator profile) and
seek (pause/resume/seek on the good profile).

Diagnosis-sensitive profiles run at simulator speed 1 (the backend's
realtime_ratio would otherwise inflate by the speed factor, see
jancast/simulator.py); only `good` runs accelerated. Profiles stop as soon as
their assertions are settled. Exit status is non-zero if any check fails.
"""

import argparse
import asyncio
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from jancast import airplay  # noqa: E402
from jancast.media import probe  # noqa: E402
from jancast.session import Session  # noqa: E402
from jancast.telemetry import Telemetry  # noqa: E402

CLIP_SECONDS = 90
SRT = """1
00:00:01,000 --> 00:00:04,000
jancast simulator test

2
00:00:30,000 --> 00:00:34,000
thirty seconds

3
00:01:00,000 --> 00:01:04,000
one minute
"""

# Checks known to fail because of backend rules (telemetry.py diagnose() /
# session.py stall accounting), not the simulator: {(scenario, check): reason}.
# A failure is reported as XFAIL, a pass as XPASS (time to delete the entry).
EXPECTED_FAILURES = {
}


def make_clip(directory, seconds=CLIP_SECONDS):
    directory = Path(directory)
    srt = directory / "subs.srt"
    srt.write_text(SRT)
    out = directory / "e2e_clip.mkv"
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
           "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30",
           "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
           "-i", str(srt), "-t", str(seconds),
           "-map", "0:v", "-map", "1:a", "-map", "2:s",
           "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
           "-b:v", "8M", "-minrate", "8M", "-maxrate", "8M", "-bufsize", "8M",
           "-x264-params", "nal-hrd=cbr:force-cfr=1",
           "-g", "60", "-keyint_min", "60", "-sc_threshold", "0",
           "-c:a", "aac", "-b:a", "128k", "-c:s", "srt",
           "-metadata:s:a:0", "language=eng", "-metadata:s:s:0", "language=eng",
           str(out)]
    subprocess.run(cmd, check=True)
    return out


# ---- scenarios ----------------------------------------------------------

class Scenario:
    """Watches 1 Hz state snapshots; `checks` maps name -> True/False/None (pending).
    `actions`: [(sim_time, session method name, *args)] performed by the runner."""
    profile = None             # simulator profile, default: the scenario name
    speed = 1.0
    timeout = 120.0
    stop_early = True
    actions = ()
    done = False               # scenario decided it has seen enough

    def __init__(self):
        self.checks = {}
        self.history = []

    def observe(self, st, sim_t):
        self.history.append((sim_t, st))

    def settled(self):
        return self.stop_early and self.checks and all(v is not None for v in self.checks.values())

    def finish(self, st, phase_done):
        for k, v in self.checks.items():
            if v is None:
                self.checks[k] = False


def top(st):
    s = st["diagnosis"]["suspects"]
    return s[0] if s else {"cause": None, "confidence": 0}


class Good(Scenario):
    speed = 3.0
    timeout = 90.0
    stop_early = False

    def __init__(self):
        super().__init__()
        self.checks = {"finishes": None, "no stalls": None, "status ok throughout": True,
                       "final status ok": None, "subtitles fetched": None,
                       "audio rendition fetched": None}

    def observe(self, st, sim_t):
        super().observe(st, sim_t)
        if st["diagnosis"]["status"] in ("failing", "failed"):
            self.checks["status ok throughout"] = False

    def finish(self, st, phase_done):
        self.checks["finishes"] = st["phase"] == "finished"
        self.checks["no stalls"] = st["playback"]["stall_count"] == 0
        self.checks["final status ok"] = st["diagnosis"]["status"] == "ok"
        self.checks["subtitles fetched"] = st["_subtitle_requests"] > 0
        # Every video segment comes with the audio covering it (separate rendition).
        self.checks["audio rendition fetched"] = (
            st["_audio_requests"] > 0 and st["_audio_requests"] >= st["_segment_requests"])
        super().finish(st, phase_done)


class Slow(Scenario):
    timeout = 150.0

    def __init__(self):
        super().__init__()
        self.checks = {"stalls": None, "network top suspect while stalled": None}

    def observe(self, st, sim_t):
        super().observe(st, sim_t)
        if st["playback"]["stall_count"] >= 1:
            self.checks["stalls"] = True
        if st["phase"] == "stalled" and top(st)["cause"] == "network":
            self.checks["network top suspect while stalled"] = True


class Flaky(Scenario):
    timeout = 120.0

    def __init__(self):
        super().__init__()
        self.window_end = None
        self.checks = {"network suspect during degradation": None,
                       "transfers aborted": None, "recovers after window": None,
                       "never failed": True}

    def observe(self, st, sim_t):
        super().observe(st, sim_t)
        w = st["_profile"].window
        in_window = st["_degraded"]
        if st["phase"] == "failed":
            self.checks["never failed"] = False
        if in_window and top(st)["cause"] == "network" and top(st)["confidence"] >= 0.4:
            self.checks["network suspect during degradation"] = True
        if st["network"]["client_aborts"] > 0:
            self.checks["transfers aborted"] = True
        if sim_t >= w.offset + w.length:
            buf = st["playback"]["buffered_ahead_s"] or 0
            if st["phase"] in ("playing", "finished") and buf >= 20:
                self.checks["recovers after window"] = True


class TvError(Scenario):
    timeout = 60.0
    stop_early = False

    def __init__(self):
        super().__init__()
        self.checks = {"phase failed": None, "device top suspect": None,
                       "playback.error set": None, "status failed": None}

    def finish(self, st, phase_done):
        self.checks["phase failed"] = st["phase"] == "failed"
        self.checks["device top suspect"] = top(st)["cause"] == "device"
        self.checks["playback.error set"] = bool(st["playback"]["error"])
        self.checks["status failed"] = st["diagnosis"]["status"] == "failed"
        super().finish(st, phase_done)


class Stuck(Scenario):
    timeout = 60.0
    long = False               # --long: stay stuck > 80 s (beyond the 60 s request window)

    def __init__(self):
        super().__init__()
        self.checks = {"stalls": None, "device top suspect while stalled": None}
        if self.long:
            self.stop_early = False
            self.timeout = 100.0
            self.checks["device still blamed after 80 s"] = None
        self.late_blame = []

    def observe(self, st, sim_t):
        super().observe(st, sim_t)
        if st["phase"] == "stalled":
            self.checks["stalls"] = True
            if top(st)["cause"] == "device":
                self.checks["device top suspect while stalled"] = True
        if self.long and sim_t >= 80:
            self.late_blame.append(top(st)["cause"] == "device")
            if sim_t >= 90:
                self.done = True

    def finish(self, st, phase_done):
        if self.long:
            self.checks["device still blamed after 80 s"] = bool(self.late_blame) and all(
                self.late_blame)
        super().finish(st, phase_done)


class Seek(Scenario):
    """Controls on the good profile: pause, resume, then seek forward."""
    profile = "good"
    timeout = 60.0
    stop_early = False
    actions = ((8, "pause"), (11, "resume"), (14, "seek", 70.0))

    def __init__(self):
        super().__init__()
        self.checks = {"pause shows paused": None, "position frozen while paused": None,
                       "seek lands at 70 s": None, "finishes": None,
                       "seek rebuffer not counted as a stall": None,
                       "device never blamed": True}
        self.paused_pos = []

    def observe(self, st, sim_t):
        super().observe(st, sim_t)
        pb = st["playback"]
        if st["phase"] == "paused":
            self.checks["pause shows paused"] = True
            self.paused_pos.append(pb["position"])
        if 14 < sim_t < 20 and pb["position"] is not None and pb["position"] >= 70:
            self.checks["seek lands at 70 s"] = True
        if top(st)["cause"] == "device" and top(st)["confidence"] > 0:
            self.checks["device never blamed"] = False

    def finish(self, st, phase_done):
        self.checks["position frozen while paused"] = (
            len(self.paused_pos) >= 2 and max(self.paused_pos) - min(self.paused_pos) < 0.05)
        self.checks["finishes"] = st["phase"] == "finished"
        self.checks["seek rebuffer not counted as a stall"] = st["playback"]["stall_count"] == 0
        super().finish(st, phase_done)


SCENARIOS = {"good": Good, "slow": Slow, "flaky": Flaky, "tv-error": TvError, "stuck": Stuck,
             "seek": Seek}


# ---- runner ---------------------------------------------------------------

def fmt_line(t, st):
    pb, net, diag = st["playback"], st["network"], st["diagnosis"]
    tp = top(st)
    pos = f"{pb['position']:5.1f}" if pb["position"] is not None else "    -"
    buf = f"{pb['buffered_ahead_s']:4.1f}" if pb["buffered_ahead_s"] is not None else "   -"
    rtt = f"{net['rtt_ms']:5.0f}" if net["rtt_ms"] is not None else "  -  "
    return (f"{t:5.1f}s {st['phase']:<10} pos {pos} buf {buf} "
            f"tx {net['tx_bps_now'] / 1e6:5.1f} rtt {rtt} ab {net['client_aborts']} "
            f"| {diag['status']:<7} {diag['headline'][:44]:<44} "
            f"| {tp['cause']} {tp['confidence']:.2f}"
            + (" *degraded*" if st.get("_degraded") else ""))


def enrich(st, session, device):
    st["_profile"] = device.profile
    st["_degraded"] = device.conditions().degraded
    ok = [r["kind"] for r in session.telemetry.requests if r["status"] == 200]
    st["_subtitle_requests"] = ok.count("subtitle")
    st["_audio_requests"] = ok.count("audio")
    st["_segment_requests"] = ok.count("segment")
    return st


async def run_profile(name, clip, workdir, quiet):
    scen = SCENARIOS[name]()
    profile = scen.profile or name
    tm = Telemetry()
    devices = airplay.Devices(simulate=profile, sim_speed=scen.speed)
    device = devices.get(f"SIM:{profile}")
    media = probe(clip)
    sub = media.subs[0] if media.subs else None
    session = Session(tm, devices, media, media.audio[0], sub, device, workdir=workdir)
    print(f"\n=== {name}: {device.profile.description} (speed {scen.speed:g}) ===")
    task = session.start()
    t0 = time.monotonic()
    st = None
    actions = list(scen.actions)
    try:
        while True:
            await asyncio.sleep(1)
            t = time.monotonic() - t0
            sim_t = device.sim_time()
            while actions and sim_t >= actions[0][0]:
                _, method, *margs = actions.pop(0)
                if not quiet:
                    print(f"  >> {method}{tuple(margs) if margs else ''}")
                await getattr(session, method)(*margs)
            st = enrich(session.state_json(), session, device)
            scen.observe(st, sim_t)
            if not quiet:
                print(fmt_line(t, st), flush=True)
            if task.done() or scen.done or scen.settled() or t > scen.timeout:
                if t > scen.timeout:
                    print(f"  (timeout after {scen.timeout:.0f} s)")
                break
    finally:
        done = task.done()
        await session.stop()
    st = enrich(session.state_json(), session, device)
    scen.finish(st, done)
    reqs = list(tm.requests)
    kinds = {}
    for r in reqs:
        kinds[r["kind"]] = kinds.get(r["kind"], 0) + 1
    ratios = [r["realtime_ratio"] for r in reqs if r.get("realtime_ratio")]
    print(f"  end: phase {st['phase']}, stalls {st['playback']['stall_count']}, "
          f"requests {kinds}, median segment ratio "
          f"{sorted(ratios)[len(ratios) // 2] if ratios else None}, "
          f"bitrate {(st['session']['stream_bitrate_bps'] or 0) / 1e6:.2f} Mbit/s")
    results = []
    for check, ok in scen.checks.items():
        xfail = EXPECTED_FAILURES.get((name, check))
        status = ("XPASS" if ok else "XFAIL") if xfail else ("PASS" if ok else "FAIL")
        results.append((name, check, status, xfail))
        print(f"  [{status}] {check}" + (f" - known issue: {xfail}" if xfail else ""))
    return results


async def main_async(args):
    for tool in ("ffmpeg", "ffprobe"):
        if not shutil.which(tool):
            sys.exit(f"{tool} not found")
    with tempfile.TemporaryDirectory(prefix="jancast-e2e-") as tmp:
        clip = Path(args.clip) if args.clip else make_clip(tmp)
        all_results = []
        for name in args.profiles or list(SCENARIOS):
            all_results += await run_profile(name, clip, tmp, args.quiet)
    print("\n=== summary ===")
    failed = [r for r in all_results if r[2] == "FAIL"]
    for name, check, status, _ in all_results:
        print(f"  {status:<5} {name:<9} {check}")
    return 1 if failed else 0


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("profiles", nargs="*", metavar="PROFILE",
                   help=f"profiles to run (default: all of {', '.join(SCENARIOS)})")
    p.add_argument("--clip", help="use this clip instead of generating one")
    p.add_argument("--quiet", action="store_true", help="no per-second timeline")
    p.add_argument("--long", action="store_true",
                   help="also keep `stuck` hung for 90 s (checks evidence does not expire)")
    args = p.parse_args()
    Stuck.long = args.long
    bad = [n for n in args.profiles if n not in SCENARIOS]
    if bad:
        p.error(f"unknown profile(s) {bad}")
    sys.exit(asyncio.run(main_async(args)))


if __name__ == "__main__":
    main()
