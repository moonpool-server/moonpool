#!/usr/bin/env python3
"""How smoothly the server ran over a time span, read from the logs the host already keeps.

For each window it reports the game's own MaxTickInterval warnings (the longest frame in each
report), ServerMove "TimeStamp expired" warnings (player moves the server dropped as too old), the
game's autosaves, the host's own save requests, the console commands the host ran as a player, and
the player count from metrics.csv. Read-only: it never touches the game.

  python3 /opt/sn2/bin/tick-report.py --from 2026-11-12T15:20 --to 2026-11-12T15:35
  python3 /opt/sn2/bin/tick-report.py --from 2026-11-12T14:00 --window 10 --json

Times are UTC. The game logs a MaxTickInterval line only for a slow frame, so `ticks` counts slow
frames, not all frames. The same line can be in an archived copy and the live log; it counts once.
"""
import argparse
import csv
import glob
import json
import os
import re
import statistics
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

GAME_STAMP = re.compile(r"\[(\d{4})\.(\d\d)\.(\d\d)-(\d\d)\.(\d\d)\.(\d\d)")
MOD_STAMP = re.compile(r"\[(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)")
MOD_SPLIT = re.compile(r"(?=\[20\d\d-\d\d-\d\d \d\d:\d\d:\d\d)")  # UE4SS.log lines carry no newlines
TICK = re.compile(r"MaxTickInterval=\[([0-9.]+)s?\]")


def when(m):
    return datetime(*(int(g) for g in m.groups()), tzinfo=timezone.utc)


def utc(text):
    t = datetime.fromisoformat(text.replace("Z", "+00:00"))
    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)


def default_logs(data):
    game_dir = os.environ.get("GAME_DIR") or str(
        data / "wine/drive_c/Program Files (x86)/Steam/steamapps/common/Subnautica2")
    live_game = [os.environ.get("UE_LOG") or f"{game_dir}/Subnautica2/Saved/Logs/Subnautica2.log"]
    live_mod = [f"{game_dir}/Subnautica2/Binaries/Win64/ue4ss/UE4SS.log"]
    hist = sorted(glob.glob(str(data / "log-history" / "*")))
    return ([f"{h}/game.log" for h in hist] + live_game, [f"{h}/UE4SS.log" for h in hist] + live_mod)


def game_events(paths, start, end):
    """Each distinct game-log line in [start, end) as (time, line), whatever copy it came from."""
    seen = set()
    for p in paths:
        try:
            fh = open(p, "r", encoding="utf-8", errors="replace")
        except OSError:
            continue
        with fh:
            for line in fh:
                m = GAME_STAMP.search(line)
                if not m:
                    continue
                key = line[m.start():].rstrip("\r\n")
                if key in seen:
                    continue
                t = when(m)
                if start <= t < end:
                    seen.add(key)
                    yield t, key


def mod_events(paths, start, end):
    seen = set()
    for p in paths:
        try:
            text = Path(p).read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for piece in MOD_SPLIT.split(text):
            m = MOD_STAMP.match(piece)
            if not m:
                continue
            key = piece.strip()
            if key in seen:
                continue
            t = when(m)
            if start <= t < end:
                seen.add(key)
                yield t, key


def players(metrics, start, end):
    counts = []
    try:
        with open(metrics, newline="", encoding="utf-8") as fh:
            for row in csv.DictReader(fh):
                try:
                    t = utc(row["utc"])
                    n = int(row.get("players") or 0)
                except (KeyError, ValueError):
                    continue
                if start <= t < end:
                    counts.append(n)
    except OSError:
        pass
    if not counts:
        return None
    return {"min": min(counts), "max": max(counts), "mean": round(statistics.fmean(counts), 2), "samples": len(counts)}


def percentile(sorted_values, q):
    """Nearest rank: the smallest value with at least q of the values at or below it."""
    if not sorted_values:
        return None
    k = max(1, -(-len(sorted_values) * q // 100))  # ceil(n*q/100), at least the first
    return sorted_values[int(k) - 1]


def report(start, end, game_logs, mod_logs, metrics):
    ticks, expired, autosaves = [], 0, 0
    for _, line in game_events(game_logs, start, end):
        m = TICK.search(line)
        if m:
            ticks.append(float(m.group(1)))
        if "TimeStamp expired" in line:
            expired += 1
        if "autosave_completed" in line:
            autosaves += 1
    host_saves = commands = 0
    for _, piece in mod_events(mod_logs, start, end):
        if "forced save requested" in piece:
            host_saves += 1
        if "console as " in piece and " failed:" not in piece:
            commands += 1
    ticks.sort()
    return {
        "from": start.strftime("%Y-%m-%dT%H:%M:%SZ"), "to": end.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "players": players(metrics, start, end),
        "slow_frames": len(ticks),
        "p50_s": percentile(ticks, 50), "p95_s": percentile(ticks, 95), "p99_s": percentile(ticks, 99),
        "max_s": ticks[-1] if ticks else None,
        "over_0_5_s": sum(1 for t in ticks if t > 0.5), "over_1_s": sum(1 for t in ticks if t > 1.0),
        "servermove_expired": expired, "game_autosaves": autosaves, "host_saves": host_saves,
        "console_commands": commands,
    }


def text(r):
    p = r["players"]
    who = f"players {p['min']}-{p['max']} (mean {p['mean']})" if p else "players unknown"
    if not r["slow_frames"]:
        frames = "no slow frames logged"
    else:
        frames = (f"slow frames {r['slow_frames']}: p50 {r['p50_s']:.3f}s p95 {r['p95_s']:.3f}s "
                  f"p99 {r['p99_s']:.3f}s max {r['max_s']:.3f}s, over 0.5s {r['over_0_5_s']}, over 1s {r['over_1_s']}")
    return (f"{r['from']} to {r['to']}  {who}\n  {frames}\n"
            f"  ServerMove expired {r['servermove_expired']}, game autosaves {r['game_autosaves']}, "
            f"host saves {r['host_saves']}, console commands {r['console_commands']}")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--from", dest="start", required=True, help="UTC start, e.g. 2026-11-12T15:20")
    ap.add_argument("--to", dest="end", help="UTC end (default: now)")
    ap.add_argument("--window", type=int, help="split into windows of this many minutes")
    ap.add_argument("--json", action="store_true", help="one JSON object per window")
    ap.add_argument("--game-log", action="append", help="a game log to read (repeatable; default: the host's own)")
    ap.add_argument("--mod-log", action="append", help="a UE4SS log to read (repeatable)")
    ap.add_argument("--metrics", help="metrics.csv (default: $DATA_DIR/metrics.csv)")
    a = ap.parse_args(argv)
    data = Path(os.environ.get("DATA_DIR") or "/home/container")
    start = utc(a.start)
    end = utc(a.end) if a.end else datetime.now(timezone.utc)
    if end <= start:
        ap.error("--to must be after --from")
    if a.window is not None and a.window <= 0:
        ap.error("--window must be a positive number of minutes")
    game_logs, mod_logs = default_logs(data)
    game_logs = a.game_log or game_logs
    mod_logs = a.mod_log or mod_logs
    metrics = a.metrics or str(data / "metrics.csv")
    step = timedelta(minutes=a.window) if a.window else end - start
    t = start
    while t < end:
        r = report(t, min(t + step, end), game_logs, mod_logs, metrics)
        print(json.dumps(r) if a.json else text(r))
        t += step
    return 0


if __name__ == "__main__":
    sys.exit(main())
