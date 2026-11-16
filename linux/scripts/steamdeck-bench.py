#!/usr/bin/env python3
"""Measures Crucible on the Steam Deck in Game Mode, launched by Steam as the player launches it, on a throwaway profile
signed in to the bundled demo library: launch, a resting Home screen, a scripted browse (shelves, a title page, a library
grid, back Home), and video playback of a local file. It samples the process's CPU time and memory, the APU's power and
the GPU's busy share while it runs, and reads Kiln's per-frame timings (KILN_FRAMES). Results go to a JSON file and a
table; `compare` puts two results side by side.

    steamdeck-bench.py ui --label NAME [--runs 2] [--env 'KEY=VALUE ...'] [--out DIR]
    steamdeck-bench.py play FILE --label NAME [--seconds 30] [--env ...] [--out DIR]
    steamdeck-bench.py compare BEFORE.json AFTER.json

Steam must run in Game Mode with Crucible in its library (steam-library.py beside this script adds it).
"""
import argparse
import glob
import importlib.util
import json
import os
import plistlib
import shutil
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
TICKS = os.sysconf("SC_CLK_TCK")
PAGE = os.sysconf("SC_PAGE_SIZE")

HOME_AT = 16.0
IDLE = (18.0, 38.0)
BROWSE_AT = 40.0
BROWSE_KEYS = ("r(160)" * 12 + "(400)e(2600)d(450)d(450)d(450)(600)x(1400)" + "d(500)d(500)d(500)" + "r(160)" * 8
               + "(400)u(500)u(500)u(500)(600)2(2600)" + "d(220)" * 15 + "(800)1(1800)")


def load_steam_library():
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("steam_library", os.path.join(HERE, "steam-library.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def hwmon(name):
    for path in glob.glob("/sys/class/hwmon/hwmon*"):
        try:
            if open(os.path.join(path, "name")).read().strip() == name:
                return path
        except OSError:
            pass
    return None


def read_number(path):
    try:
        return float(open(path).read().split()[0])
    except (OSError, ValueError, IndexError):
        return None


class Sampler:
    """The process's CPU seconds and resident memory, the APU's power and the GPU's busy share, four times a second."""

    def __init__(self):
        gpu = hwmon("amdgpu")
        self.power = next((os.path.join(gpu, name) for name in ("power1_input", "power1_average") if gpu and os.path.exists(os.path.join(gpu, name))), None)
        self.busy = next(iter(glob.glob("/sys/class/drm/card*/device/gpu_busy_percent")), None)
        self.samples = []

    def sample(self, pid):
        try:
            fields = open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()
            cpu = (int(fields[11]) + int(fields[12])) / TICKS
            rss = int(open(f"/proc/{pid}/statm").read().split()[1]) * PAGE
        except (OSError, IndexError, ValueError):
            return False
        watts = read_number(self.power) if self.power else None
        self.samples.append({"t": time.monotonic(), "cpu": cpu, "rss": rss, "watts": watts / 1e6 if watts is not None else None,
                             "busy": read_number(self.busy) if self.busy else None})
        return True

    def window(self, start, end):
        inside = [s for s in self.samples if start <= s["t"] <= end]
        if len(inside) < 2:
            return None
        span = inside[-1]["t"] - inside[0]["t"]
        watts = [s["watts"] for s in inside if s["watts"] is not None]
        busy = [s["busy"] for s in inside if s["busy"] is not None]
        return {"cpu_percent": 100 * (inside[-1]["cpu"] - inside[0]["cpu"]) / span if span > 0 else None,
                "apu_watts": statistics.mean(watts) if watts else None,
                "gpu_busy_percent": statistics.mean(busy) if busy else None,
                "rss_mb_peak": max(s["rss"] for s in inside) / 2**20}


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(fraction * (len(ordered) - 1))))]


def read_frames(path):
    frames, shown = [], []
    try:
        for line in open(path):
            parts = line.split()
            if parts and parts[0] == "f" and len(parts) >= 6:
                present = float(parts[6]) if len(parts) >= 7 else None
                frames.append({"start": float(parts[1]), "cpu": float(parts[2]), "gpu": float(parts[3]), "wait": float(parts[4]),
                               "input": float(parts[5]), "work": float(parts[2]) - present if present is not None else None})
            elif parts and parts[0] == "p" and len(parts) >= 2:
                shown.append(float(parts[1]))
    except OSError:
        pass
    return frames, shown


def frame_stats(frames, start, end, refresh):
    inside = [f for f in frames if start <= f["start"] <= end]
    if not inside:
        return {"frames": 0}
    gaps = [b["start"] - a["start"] for a, b in zip(inside, inside[1:]) if b["start"] - a["start"] < 0.25]
    cpu = [f["cpu"] for f in inside]
    work = [f["work"] for f in inside if f["work"] is not None]
    gpu = [f["gpu"] for f in inside if f["gpu"] >= 0]
    latency = [f["input"] for f in inside if f["input"] >= 0]
    late = [g for g in gaps if g > refresh * 1.5]
    return {
        "frames": len(inside),
        "cpu_ms_p50": percentile(cpu, 0.5), "cpu_ms_p95": percentile(cpu, 0.95), "cpu_ms_p99": percentile(cpu, 0.99), "cpu_ms_max": max(cpu),
        "work_ms_p50": percentile(work, 0.5), "work_ms_p95": percentile(work, 0.95), "work_ms_p99": percentile(work, 0.99),
        "work_ms_max": max(work) if work else None,
        "gpu_ms_p50": percentile(gpu, 0.5), "gpu_ms_p95": percentile(gpu, 0.95),
        "interval_ms_p50": percentile(gaps, 0.5) * 1000 if gaps else None, "interval_ms_p95": percentile(gaps, 0.95) * 1000 if gaps else None,
        "interval_ms_p99": percentile(gaps, 0.99) * 1000 if gaps else None,
        "late_frames": len(late), "late_percent": 100 * len(late) / len(gaps) if gaps else None,
        "input_latency_ms_p50": percentile(latency, 0.5), "input_latency_ms_p95": percentile(latency, 0.95),
    }


def make_profile(root, demo):
    for name in ("config", "data/crucible", "cache", "state"):
        os.makedirs(os.path.join(root, name), exist_ok=True)
    plist = os.path.join(root, "config", "crucible.plist")
    if demo and not os.path.exists(plist):
        plistlib.dump({"crucible_demo_active": True}, open(plist, "wb"), fmt=plistlib.FMT_XML)


def wait_until_closed(steam, appid, seconds=40):
    """Steam ignores a launch while it still counts the last one as running, so wait for it to let go."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        running = steam.evaluate(f"SteamUIStore.RunningApps.some(app => app.appid === {appid})")
        alive = subprocess.run(["pgrep", "-x", "crucible"], capture_output=True).returncode == 0
        if not running and not alive:
            return
        time.sleep(0.5)


def launch(steam_library, steam, appid, options):
    wait_until_closed(steam, appid)
    before = set(subprocess.run(["pgrep", "-x", "crucible"], capture_output=True, text=True).stdout.split())
    gid = steam_library.game_id(appid)
    steam.evaluate(f"SteamClient.Apps.SetShortcutLaunchOptions({appid}, {json.dumps(options)})")
    steam.evaluate(f'SteamClient.Apps.RunGame("{gid}", "", -1, 100)')
    launched = time.monotonic()
    pid = None
    while time.monotonic() - launched < 30 and pid is None:
        current = set(subprocess.run(["pgrep", "-x", "crucible"], capture_output=True, text=True).stdout.split()) - before
        pid = int(current.pop()) if current else None
        if pid is None:
            time.sleep(0.05)
    time.sleep(2)
    steam.evaluate(f"SteamClient.Apps.SetShortcutLaunchOptions({appid}, {json.dumps(steam_library.LAUNCH_OPTIONS)})")
    if pid is None:
        sys.exit("steamdeck-bench: Crucible did not start; see the run's stderr file")
    subprocess.run(["xdotool", "mousemove_relative", "--", "1", "0"], env={**os.environ, "DISPLAY": ":0"}, capture_output=True)
    return pid, launched


def run_once(steam_library, steam, appid, profile, out, label, arguments, extra_env, timeout):
    frames_path = os.path.join(out, f"{label}.frames")
    env = (f"XDG_CONFIG_HOME={profile}/config XDG_DATA_HOME={profile}/data XDG_CACHE_HOME={profile}/cache XDG_STATE_HOME={profile}/state "
           f"KILN_FRAMES={frames_path} CRUCIBLE_NO_BROWSER=1 {extra_env}").strip()
    options = f"{env} %command% {arguments} 2>{os.path.join(out, label + '.stderr')}"
    sampler = Sampler()
    pid, launched = launch(steam_library, steam, appid, options)
    while time.monotonic() - launched < timeout and sampler.sample(pid):
        time.sleep(0.25)
    if os.path.exists(f"/proc/{pid}"):
        subprocess.run(["kill", "-TERM", str(pid)])
        for _ in range(20):
            if not os.path.exists(f"/proc/{pid}"):
                break
            time.sleep(0.25)
        else:
            print(f"steamdeck-bench: {label} did not quit on SIGTERM; killed", file=sys.stderr)
            subprocess.run(["kill", "-KILL", str(pid)])
    wait_until_closed(steam, appid)
    frames, shown = read_frames(frames_path)
    return sampler, frames, shown, launched


def refresh_interval():
    return 1 / 90


def ui(options):
    steam_library = load_steam_library()
    steam = steam_library.shared_context(8080)
    found = steam.evaluate(steam_library.FIND) or []
    if not found:
        sys.exit("steamdeck-bench: Crucible is not in the Steam library")
    out = os.path.abspath(options.out)
    os.makedirs(out, exist_ok=True)
    profile = os.path.join("/tmp", f"crucible-bench-{options.label}")
    shutil.rmtree(profile, ignore_errors=True)
    make_profile(profile, demo=True)
    captures = (f"--capture '{HOME_AT}::{out}/{options.label}-home.png' "
                f"--capture '{BROWSE_AT}:{BROWSE_KEYS}:{out}/{options.label}-browse.png'")
    results = []
    for run in range(options.runs):
        name = f"{options.label}-ui{run + 1}"
        sampler, frames, shown, launched = run_once(steam_library, steam, found[0], profile, out, name, f"--steam-deck {captures}", options.env, 120)
        first = frames[0]["start"] - launched if frames else None
        browse_end = max((f["start"] for f in frames), default=launched + BROWSE_AT)
        result = {
            "run": name, "cold": run == 0,
            "first_frame_s": first,
            "startup": sampler.window(launched, launched + HOME_AT),
            "startup_cpu_seconds": next((s["cpu"] for s in reversed(sampler.samples) if s["t"] <= launched + HOME_AT), None),
            "idle": sampler.window(launched + IDLE[0], launched + IDLE[1]),
            "idle_frames": frame_stats(frames, launched + IDLE[0], launched + IDLE[1], refresh_interval()),
            "browse": sampler.window(launched + BROWSE_AT, browse_end),
            "browse_frames": frame_stats(frames, launched + BROWSE_AT, browse_end, refresh_interval()),
            "presented": len(shown),
        }
        results.append(result)
        time.sleep(4)
    write(out, options.label + "-ui", results)


def play(options):
    steam_library = load_steam_library()
    steam = steam_library.shared_context(8080)
    found = steam.evaluate(steam_library.FIND) or []
    out = os.path.abspath(options.out)
    os.makedirs(out, exist_ok=True)
    profile = os.path.join("/tmp", f"crucible-bench-{options.label}-play")
    shutil.rmtree(profile, ignore_errors=True)
    make_profile(profile, demo=False)
    name = f"{options.label}-play-{os.path.splitext(os.path.basename(options.file))[0]}"
    extra = f"CRUCIBLE_PLAY_FILE={os.path.abspath(options.file)} KILN_MPV_LOG=1 {options.env}"
    seconds = options.seconds
    sampler, frames, shown, launched = run_once(steam_library, steam, found[0], profile, out, name,
                                                f"--steam-deck --capture '{seconds + 4}::{out}/{name}.png'", extra, seconds + 30)
    window = (launched + 5, launched + seconds)
    stderr = open(os.path.join(out, name + ".stderr"), errors="replace").read()
    decoder = next((line.strip() for line in stderr.splitlines() if "Using hardware decoding" in line or "hwdec" in line.lower() and "using" in line.lower()), None)
    result = [{"run": name, "file": options.file, "playback": sampler.window(*window),
               "playback_frames": frame_stats(frames, window[0], window[1], refresh_interval()), "decoder": decoder,
               "first_frame_s": frames[0]["start"] - launched if frames else None}]
    write(out, name, result)


def write(out, name, results):
    path = os.path.join(out, name + ".json")
    json.dump(results, open(path, "w"), indent=2)
    for result in results:
        print(json.dumps(result, indent=1))
    print(f"steamdeck-bench: {path}")


def flatten(prefix, value, into):
    if isinstance(value, dict):
        for key, item in value.items():
            flatten(f"{prefix}.{key}" if prefix else key, item, into)
    elif isinstance(value, (int, float)) and not isinstance(value, bool):
        into[prefix] = value
    return into


def compare(options):
    before = json.load(open(options.before))
    after = json.load(open(options.after))
    pick = lambda results: next((r for r in results if not r.get("cold")), results[-1])
    a, b = flatten("", pick(before), {}), flatten("", pick(after), {})
    print(f"{'metric':44} {'before':>12} {'after':>12} {'change':>9}")
    for key in a:
        if key in b:
            change = f"{100 * (b[key] - a[key]) / a[key]:+.0f}%" if a[key] else ""
            print(f"{key:44} {a[key]:12.2f} {b[key]:12.2f} {change:>9}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    ui_parser = sub.add_parser("ui")
    ui_parser.add_argument("--label", required=True)
    ui_parser.add_argument("--runs", type=int, default=2)
    ui_parser.add_argument("--env", default="")
    ui_parser.add_argument("--out", default=os.path.expanduser("~/crucible-bench"))
    play_parser = sub.add_parser("play")
    play_parser.add_argument("file")
    play_parser.add_argument("--label", required=True)
    play_parser.add_argument("--seconds", type=float, default=30)
    play_parser.add_argument("--env", default="")
    play_parser.add_argument("--out", default=os.path.expanduser("~/crucible-bench"))
    compare_parser = sub.add_parser("compare")
    compare_parser.add_argument("before")
    compare_parser.add_argument("after")
    options = parser.parse_args()
    {"ui": ui, "play": play, "compare": compare}[options.command](options)


if __name__ == "__main__":
    main()
