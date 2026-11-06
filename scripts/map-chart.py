#!/usr/bin/env python3
# Turns this host's own status.json into the data for its map page.
"""The map is a chart of where players have been, drawn from the game's own positions.

Every run adds each player's position to a grid, one chart per branch and save. Anything
new about the world, a new cell, a deeper reading of an old cell, a new base or lifepod, is
published only MAP_DELAY_MINUTES later, so the page never shows where someone is now. No
names, no game art.
Off (WEB_MAP not true) withdraws the published files and keeps the chart.
"""
import json
import os
import re
import shutil
import sys
import time
from pathlib import Path

CELL_M = 50  # one square on the chart
UU_PER_M = 100  # the game's units are centimetres
STALE_S = 180


def read_json(path, fallback):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return fallback


def write_json(path, value):
    tmp = Path(str(path) + ".tmp")
    tmp.write_text(json.dumps(value, separators=(",", ":")), encoding="utf-8")
    os.replace(tmp, path)


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and value == value


def points(rows):
    """[x, y] in metres for each row with a position; an empty Lua table arrives as {}."""
    if not isinstance(rows, list):
        return []
    return [[round(r["x"] / UU_PER_M), round(r["y"] / UU_PER_M)]
            for r in rows if isinstance(r, dict) and number(r.get("x")) and number(r.get("y"))]


def record(chart, status, host, now):
    if not number(status.get("ts")) or now - status["ts"] > STALE_S:
        return
    for kind in ("bases", "lifepods"):
        seen = chart.setdefault(kind, {})
        for x, y in points(status.get(kind)):
            seen.setdefault("%d,%d" % (x, y), now)
    cells = chart.setdefault("cells", {})
    players = status.get("players")
    for row in players if isinstance(players, list) else []:
        if not isinstance(row, dict) or row.get("name") == host:
            continue
        if not (number(row.get("x")) and number(row.get("y"))):
            continue
        key = "%d,%d" % (row["x"] // (CELL_M * UU_PER_M), row["y"] // (CELL_M * UU_PER_M))
        depth = row["depth_m"] if number(row.get("depth_m")) else 0
        cell = cells.get(key)
        if cell is None:
            cells[key] = {"t": now, "d": depth}
        elif depth > max(cell["d"], cell.get("next", 0)):
            cell["next"], cell["next_t"] = depth, now  # shown after the delay, like a new cell


def background(status, env, data, public):
    """The host's own map for the game branch in force, from map-background.json in the
    data volume: {"public": {...}, "experimental": {...}}, each with url (a tile address
    with {z}, or a picture's address, or a file in the volume), bounds in game units
    [left, top, right, bottom] and optionally max_zoom. None ships with this project."""
    entries = read_json(data / "map-background.json", {})
    branch = status.get("branch") or env.get("STEAM_BRANCH") or "public"
    entry = entries.get(branch) if isinstance(entries, dict) else None
    if not isinstance(entry, dict):
        return None
    source, bounds, max_zoom = entry.get("url"), entry.get("bounds"), entry.get("max_zoom", 8)
    if not (isinstance(source, str) and source and isinstance(bounds, list) and len(bounds) == 4
            and all(number(v) for v in bounds) and number(max_zoom)
            and bounds[0] != bounds[2] and bounds[1] != bounds[3]):
        print("map-chart: map-background.json: %s needs url and four bounds" % branch, file=sys.stderr)
        return None
    if "://" not in source:
        name = Path(source).name
        shutil.copyfile(data / name, public / ("map-background" + Path(name).suffix))
        source = "map-background" + Path(name).suffix
    return {"url": source, "tiles": "{z}" in source, "max_zoom": max_zoom,
            "bounds": [v / UU_PER_M for v in bounds]}


def published(chart, status, world, delay_s, now):
    cells = []
    for key, cell in chart.get("cells", {}).items():
        if "next" in cell and now - cell["next_t"] >= delay_s:
            cell["d"] = cell.pop("next")
            del cell["next_t"]
        if now - cell["t"] >= delay_s:
            x, y = key.split(",")
            cells.append([int(x) * CELL_M, int(y) * CELL_M, cell["d"]])
    def settled(kind):
        current = {"%d,%d" % (x, y) for x, y in points(status.get(kind))}
        return sorted([int(v) for v in key.split(",")] for key, first in chart.get(kind, {}).items()
                      if key in current and now - first >= delay_s)
    return {"world": world, "cell_m": CELL_M, "delay_minutes": delay_s // 60, "updated": now,
            "cells": sorted(cells), "bases": settled("bases"), "lifepods": settled("lifepods")}


def main():
    data = Path(os.environ.get("DATA_DIR", "/data"))
    control = Path(os.environ.get("CONTROL_DIR", data / "control"))
    public = Path(os.environ.get("PUBLIC_DIR", data / "public"))
    page = Path(os.environ.get("MAP_PAGE", "/opt/sn2/web/map.html"))
    if os.environ.get("WEB_MAP", "false") != "true":
        for name in ("map.html", "map.json"):
            (public / name).unlink(missing_ok=True)
        return 0
    now = int(os.environ.get("SN2_NOW") or time.time())
    try:
        delay_s = max(0, int(os.environ.get("MAP_DELAY_MINUTES") or 15)) * 60
    except ValueError:
        delay_s = 15 * 60
    status = read_json(control / "status.json", {})
    status = status if isinstance(status, dict) else {}
    world_key = "%s-%s" % (status.get("branch") or os.environ.get("STEAM_BRANCH") or "public", status.get("save") or "default")
    store = data / ("map-chart-%s.json" % re.sub(r"[^A-Za-z0-9_.-]", "_", world_key))
    chart = read_json(store, {})
    chart = chart if isinstance(chart, dict) else {}
    record(chart, status, os.environ.get("HOST_NAME", "SN2 Host"), now)
    public.mkdir(parents=True, exist_ok=True)
    page_data = published(chart, status, os.environ.get("WORLD_NAME", ""), delay_s, now)
    write_json(store, chart)
    try:
        page_data["background"] = background(status, os.environ, data, public)
    except OSError as err:
        page_data["background"] = None
        print("map-chart: no background: %s" % err, file=sys.stderr)
    write_json(public / "map.json", page_data)
    shutil.copyfile(page, public / "map.html")
    return 0


if __name__ == "__main__":
    sys.exit(main())
