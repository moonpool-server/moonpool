#!/usr/bin/env python3
"""Durable facts about the served world as one JSON object: when it was created, hours
played, sessions, who has been aboard, the peak and the last time anyone was on.
Cached for ten minutes because metrics.csv only grows."""
import csv
import json
import os
import re
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sn2files import write_atomic  # noqa: E402  (beside this file)


def env(name, default):
    return os.environ.get(name) or str(default)


def iso(when):
    return when.strftime("%Y-%m-%dT%H:%M:%SZ")


def stamp(text):
    """A metrics timestamp as a datetime, or None."""
    try:
        return datetime.strptime(text[:16], "%Y-%m-%dT%H:%M").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def oldest_file(folder, label, best):
    if not folder.is_dir():
        return best
    for f in folder.rglob("*"):
        if f.is_file():
            when = datetime.fromtimestamp(int(f.stat().st_mtime), timezone.utc)
            if best is None or when < best[0]:
                best = (when, label)
    return best


def play(metrics):
    """Hours, sessions, peak and last time from the minute-by-minute player count."""
    out = {"hours_played": None, "sessions": None, "peak_players": None, "peak_when": None, "last_played": None}
    try:
        with metrics.open(newline="", encoding="utf-8") as f:
            rows = list(csv.reader(f))
    except OSError:
        return out
    if not rows:
        return out
    col = rows[0].index("players") if "players" in rows[0] else 3
    seen = False
    positive = sessions = peak = 0
    peak_at = last = previous = None
    for row in rows[1:]:
        if len(row) <= col or not row[col].isdigit():
            continue
        seen, count = True, int(row[col])
        if count > peak:
            peak, peak_at = count, row[0]
        if count > 0:
            positive += 1
            current = stamp(row[0])
            # A new session starts after any gap of more than one minute.
            if previous is None or current is None or current - previous > timedelta(minutes=1):
                sessions += 1
            last, previous = current, current
        else:
            previous = None
    if seen:
        out.update(hours_played=round(positive / 60, 2), sessions=sessions, peak_players=peak, peak_when=peak_at,
                   last_played=iso(last + timedelta(minutes=1)) if last else None)
    return out


def main():
    data = Path(env("DATA_DIR", "/data"))
    save_dir = Path(env("WORLD_STATS_SAVE_DIR", Path(env("GAME_DIR", "/home/container/game")) / "Subnautica2/Saved/SaveGames"))
    staging = Path(env("WORLD_STATS_STAGING_DIR", data / "backup-staging"))
    archive = Path(env("WORLD_STATS_ARCHIVE_DIR", "/archive"))
    join_log = Path(env("WORLD_STATS_JOIN_LOG", data / "logs" / "join_watch.log"))
    status_json = Path(env("WORLD_STATS_STATUS_JSON", data / "control" / "status.json"))
    cache = Path(env("WORLD_STATS_CACHE", data / "world-stats.json"))
    now = int(float(env("SN2_NOW", time.time())))
    if cache.is_file() and cache.stat().st_size and now - cache.stat().st_mtime < 600:
        try:
            text = cache.read_text(encoding="utf-8")
            json.loads(text)
            sys.stdout.write(text.strip())
            return 0
        except (OSError, ValueError):
            pass

    created = oldest_file(staging, "backup-staging", oldest_file(save_dir, "SaveGames", None))
    if archive.is_dir():  # an archive's name carries its instant even when its contents can't be read here
        for f in archive.glob("sn2-saves-*.tar.gz"):
            m = re.fullmatch(r"sn2-saves-(\d{4}-\d{2}-\d{2})T(\d{2})-(\d{2})-(\d{2})\.tar\.gz", f.name)
            if m:
                when = datetime.fromisoformat(f"{m[1]}T{m[2]}:{m[3]}:{m[4]}+00:00")
                if created is None or when < created[0]:
                    created = (when, "backup archive name")

    players_seen = None
    if join_log.is_file():
        names = sorted({m.group(1) for m in re.finditer(r"Join succeeded: (.*)$", join_log.read_text(encoding="utf-8", errors="replace"), re.M)})
        players_seen = len(names) if env("SHOW_PLAYER_NAMES", "true") == "false" else names
    day = None
    try:
        value = json.loads(status_json.read_text(encoding="utf-8")).get("day")
        day = value if isinstance(value, (int, float)) and not isinstance(value, bool) else None
    except (OSError, ValueError, AttributeError):
        pass

    facts = play(metrics=Path(env("WORLD_STATS_METRICS", data / "metrics.csv")))
    out = {"created": iso(created[0]) if created else None, "created_source": created[1] if created else None,
           "hours_played": facts["hours_played"], "sessions": facts["sessions"], "players_seen": players_seen,
           "peak_players": facts["peak_players"], "peak_when": facts["peak_when"],
           "last_played": facts["last_played"], "in_game_day": day}
    text = json.dumps(out, separators=(",", ":"))
    cache.parent.mkdir(parents=True, exist_ok=True)
    write_atomic(cache, text)
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
