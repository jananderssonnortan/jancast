"""Command line: `jancast movie.mkv`, `jancast --devices`, `jancast --pair`,
and `jancast serve` (the backend for the macOS app)."""

import argparse
import asyncio
import shutil
import sys

from . import airplay, history
from .config import ensure_tool_path
from .media import MediaError, probe
from .session import Session
from .telemetry import Telemetry


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def prompt_choice(question, default):
    try:
        answer = input(f"{question} [{default}]: ").strip()
    except EOFError:
        answer = ""
    return answer or str(default)


def match_track(tracks, choice, allow_off):
    """Resolve a user choice: a 1-based number, 'off', or a language/title substring."""
    choice = choice.strip().lower()
    if allow_off and choice in ("0", "off", "none", "no"):
        return None
    if choice.isdigit():
        n = int(choice)
        if 1 <= n <= len(tracks):
            return tracks[n - 1]
        die(f"track number {n} out of range")
    for t in tracks:
        if choice in (t.lang.lower(), t.title.lower()):
            return t
    for t in tracks:
        if choice in t.title.lower() or choice in t.lang.lower():
            return t
    die(f"no track matching '{choice}'")


def describe(t):
    s = t.label()
    flags = [f for f, on in (("default", t.default), ("forced", t.forced)) if on]
    if t.kind == "sub" and t.via_ocr:
        flags.append("image - shown as text (OCR)")
    elif t.kind == "sub" and t.is_bitmap:
        flags.append("image - burned in, re-encodes video")
    return s + (f"  [{', '.join(flags)}]" if flags else "")


def pick_audio(media, choice, default=None):
    if choice:
        return match_track(media.audio, choice, allow_off=False)
    if len(media.audio) == 1:
        return media.audio[0]
    print("\nAudio tracks:")
    for i, t in enumerate(media.audio, 1):
        print(f"  {i:>2}) {describe(t)}")
    return match_track(media.audio, prompt_choice("Audio", default or media.default_audio),
                       allow_off=False)


def pick_sub(media, choice, default=None):
    if choice:
        return match_track(media.subs, choice, allow_off=True)
    if not media.subs:
        return None
    print("\nSubtitles:")
    print("   0) Off")
    for i, t in enumerate(media.subs, 1):
        print(f"  {i:>2}) {describe(t)}")
    default = media.default_sub if default is None else default
    return match_track(media.subs, prompt_choice("Subtitles", default), allow_off=True)


def reach_text(entry):
    """Short reachability description of a /api/devices-style entry."""
    if entry["status"] == "online":
        return f"online, {entry['rtt_ms']:.0f} ms"
    if entry["status"] == "not_responding":
        return "not responding - may be asleep"
    return "offline"


def pairing_text(entry):
    if entry["paired"]:
        return "paired"
    return "needs pairing" if entry["pairing_required"] else "no pairing needed"


async def choose_device(devices, wanted, preferred=None):
    """Pick a device; `preferred` (an id, e.g. from the resume history) is the
    default when it is reachable, then the last used one."""
    print("Searching for Apple TVs...")
    found = await devices.scan()
    if not found:
        die("no AirPlay devices found on the network")
    if wanted:
        conf = devices.find(wanted)
        if conf is None:
            die(f"no device matching '{wanted}'. Found: " + ", ".join(d.name for d in found))
        return conf
    entries = devices.list_json()
    usable = [e for e in entries if e["status"] != "offline"]
    if len(usable) == 1 and len(entries) == 1:
        return devices.get(usable[0]["id"])
    last = airplay.load_state().get("last_device")
    default = next((i for i, e in enumerate(entries, 1)
                    if e["id"] in (preferred, last) and e["status"] == "online"), 1)
    print("\nDevices:")
    for i, e in enumerate(entries, 1):
        mark = "*" if e["id"] == last else " "
        print(f" {mark}{i:>2}) {e['name']:<22} {reach_text(e):<32} {pairing_text(e):<17} "
              f"{e['model'] or ''}")
    n = prompt_choice("Device", default)
    if not n.isdigit() or not 1 <= int(n) <= len(entries):
        die("invalid device choice")
    entry = entries[int(n) - 1]
    if entry["status"] == "offline":
        die(f"{entry['name']} is offline")
    if entry["status"] == "not_responding":
        print(f"{entry['name']} is not responding - trying anyway, it may wake up.")
    return devices.get(entry["id"])


async def pair(devices, conf):
    print(f"\nPairing with {conf.name}...")
    await devices.pair_begin(conf.identifier)
    if devices.pairing_state and devices.pairing_state["awaiting_pin"]:
        await devices.pair_finish(input("Enter the PIN shown on the TV: ").strip())
    print("Paired.")
    return devices.get(conf.identifier)


def make_devices(args):
    try:
        return airplay.Devices(simulate=args.simulate, sim_speed=args.sim_speed)
    except ValueError as e:
        die(str(e))


async def cmd_devices(args):
    devices = make_devices(args)
    await devices.scan()
    entries = devices.list_json()
    if not entries:
        print("No AirPlay video devices found.")
    last = airplay.load_state().get("last_device")
    for e in entries:
        mark = "*" if e["id"] == last else " "
        print(f"{mark} {e['name']:<22} {e['address']:<15} {reach_text(e):<32} "
              f"{pairing_text(e):<17} {e['model'] or ''}")


async def cmd_pair(args):
    devices = make_devices(args)
    await pair(devices, await choose_device(devices, args.device))


def fmt_time(seconds):
    seconds = int(seconds)
    h, m, s = seconds // 3600, seconds // 60 % 60, seconds % 60
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


def status_line(session):
    st = session.state_json()
    pb, prep, net = st["playback"], st["prep"], st["network"]
    parts = [st["phase"]]
    if not prep["done"]:
        parts.append(f"prep {prep['progress']:.0%}" + (f" {prep['speed']:.1f}x" if prep["speed"] else ""))
    if pb["position"] is not None:
        parts.append(f"{fmt_time(pb['position'])} / {fmt_time(pb['duration'] or 0)}")
    if pb["buffered_ahead_s"] is not None:
        parts.append(f"buffer {pb['buffered_ahead_s']:.0f}s")
    parts.append(f"{net['tx_bps_avg10'] / 1e6:.1f} Mbit/s")
    if net["rtt_ms"] is not None:
        parts.append(f"rtt {net['rtt_ms']:.0f}ms")
    diag = st["diagnosis"]
    if diag["status"] != "ok":
        parts.append(f"! {diag['headline']}")
    return " | ".join(parts)


async def cmd_play(args):
    for tool in ("ffmpeg", "ffprobe"):
        if not shutil.which(tool):
            die(f"{tool} not found - install it with: brew install ffmpeg")
    try:
        media = probe(args.file)
    except MediaError as e:
        die(str(e))

    if args.info:
        v = media.video
        print(f"Video: {media.video_codec} {v.get('width')}x{v.get('height')}"
              f"  {media.duration / 60:.0f} min  -> {media.video_plan(None)[0]}")
        print("Audio:")
        for i, t in enumerate(media.audio, 1):
            print(f"  {i:>2}) {describe(t)}")
        print("Subtitles:")
        for i, t in enumerate(media.subs, 1):
            print(f"  {i:>2}) {describe(t)}")
        return

    saved = history.resume_info(media.path)
    start_position = 0.0
    if saved and saved["resume_position"] and not args.from_start:
        at = fmt_time(saved["resume_position"])
        if prompt_choice(f"Resume from {at}? (y/n)", "y").lower().startswith("y"):
            start_position = saved["resume_position"]
    audio = pick_audio(media, args.audio, saved and saved.get("audio"))
    sub = pick_sub(media, args.sub, saved.get("subtitle") if saved else None)
    devices = make_devices(args)
    if devices.simulated and not args.device:
        conf = next(iter(devices.simulated.values()))   # no network scan needed
    else:
        conf = await choose_device(devices, args.device, saved and saved.get("device_id"))
    if devices.needs_pairing(conf):
        conf = await pair(devices, conf)
    if not airplay.is_simulated(conf):
        airplay.save_state({**airplay.load_state(), "last_device": conf.identifier})

    telemetry = Telemetry(echo_events=args.verbose)
    session = Session(telemetry, devices, media, audio, sub, conf, stereo=args.stereo,
                      quality=args.quality, workdir=args.workdir, hls_port=args.port,
                      start_position=start_position)
    print(f"\n{media.path.name}\n  audio: {audio.label()}\n  subs:  {sub.label() if sub else 'off'}"
          f"\nPress Ctrl+C to stop.\n")
    task = session.start()
    try:
        while not task.done():
            print("\r\033[K" + status_line(session), end="", flush=True)
            await asyncio.sleep(1)
    finally:
        await session.stop()
        print()
    if session.phase == "failed":
        diag = session.state_json()["diagnosis"]
        print(f"Failed: {session.error}\nLikely cause: {diag['headline']}")
        for s in diag["suspects"][:3]:
            print(f"  {s['cause']:<8} {s['confidence']:.0%}  {s['evidence']}")
        sys.exit(1)


def add_simulate_args(p):
    p.add_argument("--simulate", metavar="PROFILE",
                   help="add a simulated Apple TV (good, slow, flaky, tv-error, stuck; "
                        "comma-separate for several) - see jancast/simulator.py")
    p.add_argument("--sim-speed", type=float, default=None,
                   help="simulated time acceleration (default: $JANCAST_SIM_SPEED or 1)")


def main():
    ensure_tool_path()
    if len(sys.argv) > 1 and sys.argv[1] == "serve":
        p = argparse.ArgumentParser(prog="jancast serve", description="Backend for the macOS app")
        p.add_argument("--api-port", type=int, default=0)
        p.add_argument("--workdir")
        add_simulate_args(p)
        args = p.parse_args(sys.argv[2:])
        if args.simulate:
            make_devices(args)                  # validate the profile names early
        from .api import serve
        serve(args.api_port, args.workdir, args.simulate, args.sim_speed)
        return

    p = argparse.ArgumentParser(
        prog="jancast",
        description="AirPlay MKV files to an Apple TV with audio/subtitle selection.",
        epilog="Track choices are 1-based numbers from the list, a language code "
               "(eng, swe) or part of the track title. Use -s off for no subtitles. "
               "'jancast serve' runs the backend for the macOS app.",
    )
    p.add_argument("file", nargs="?", help="video file to play")
    p.add_argument("-a", "--audio", help="audio track (number, language or title)")
    p.add_argument("-s", "--sub", help="subtitle track (number, language, title or 'off')")
    p.add_argument("-d", "--device", help="Apple TV name, IP or identifier")
    p.add_argument("--stereo", action="store_true", help="downmix audio to stereo AAC")
    p.add_argument("--from-start", action="store_true",
                   help="don't offer to resume where playback last stopped")
    p.add_argument("--info", action="store_true", help="list the file's tracks and exit")
    p.add_argument("--devices", action="store_true", help="list AirPlay devices and exit")
    p.add_argument("--pair", action="store_true", help="pair with an Apple TV and exit")
    p.add_argument("--port", type=int, default=0, help="HTTP port to serve on (default: random)")
    p.add_argument("--quality", type=int, default=65,
                   help="VideoToolbox quality 1-100 when re-encoding is needed (default 65)")
    p.add_argument("--workdir", help="where to put the temporary HLS files (default: system temp)")
    p.add_argument("-v", "--verbose", action="store_true", help="print all events")
    add_simulate_args(p)
    args = p.parse_args()

    if args.devices:
        coro = cmd_devices(args)
    elif args.pair:
        coro = cmd_pair(args)
    elif args.file:
        coro = cmd_play(args)
    else:
        p.print_help()
        return
    try:
        asyncio.run(coro)
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
