#!/usr/bin/env python3
# Turns this host's own status.json into the data for its map page.
"""The map is a chart of where players have been, drawn from the game's own positions.

Every run adds each player's position to a grid, one chart per branch and save. Anything
new about the world, a new cell, a deeper reading of an old cell, a new base or lifepod, is
published only MAP_DELAY_MINUTES later, so the page never shows where someone is now. No
names, no game art.
A still of the map (map.png) goes beside the page for link previews and the card.
Off (WEB_MAP not true) withdraws the published files and keeps the chart.
"""
import hashlib
import math
import html
import io
import json
import os
import re
import shutil
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

from PIL import Image, ImageDraw

STILL_W = 1200  # the still's width in pixels; link previews want about this
FOCUS_MIN_M = 800  # the still never shows less than this across
FOCUS_PAD_M = 150  # room around the outermost dot
STOPS = [(0, (143, 233, 228)), (100, (43, 143, 196)), (300, (49, 64, 143)), (800, (39, 18, 79))]

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
    data volume: {"public": ..., "experimental": ...}. A branch's value is one entry or a
    list of them laid side by side, each with url (a tile address with {z}, or a picture's
    address, or a file in the volume), bounds in game units [left, top, right, bottom] and
    optionally max_zoom. None ships with this project."""
    entries = read_json(data / "map-background.json", {})
    branch = status.get("branch") or env.get("STEAM_BRANCH") or "public"
    entry = entries.get(branch) if isinstance(entries, dict) else None
    items = entry if isinstance(entry, list) else [entry]
    out = []
    for i, item in enumerate(items):
        if not isinstance(item, dict):
            continue
        source, bounds, max_zoom = item.get("url"), item.get("bounds"), item.get("max_zoom", 8)
        if not (isinstance(source, str) and source and isinstance(bounds, list) and len(bounds) == 4
                and all(number(v) for v in bounds) and number(max_zoom)
                and bounds[0] != bounds[2] and bounds[1] != bounds[3]):
            print("map-chart: map-background.json: %s needs url and four bounds" % branch, file=sys.stderr)
            continue
        if "://" not in source:
            name = Path(source).name
            served = "map-background-%d%s" % (i, Path(name).suffix)
            shutil.copyfile(data / name, public / served)
            source = served
        out.append({"url": source, "tiles": "{z}" in source, "max_zoom": max_zoom,
                    "bounds": [v / UU_PER_M for v in bounds]})
    return out


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


def depth_colour(depth):
    for i in range(1, len(STOPS)):
        if depth <= STOPS[i][0]:
            (d0, a), (d1, b) = STOPS[i - 1], STOPS[i]
            t = (depth - d0) / (d1 - d0)
            return tuple(round(a[k] + (b[k] - a[k]) * t) for k in range(3))
    return STOPS[-1][1]


def fetch(url, cache):
    """One tile or picture, kept in the data volume so a still costs the network once."""
    path = cache / hashlib.sha256(url.encode()).hexdigest()
    if not path.exists():
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "moonpool"}), timeout=10) as r:
                path.write_bytes(r.read())
        except urllib.error.HTTPError as err:
            if err.code != 404:
                raise
            path.write_bytes(b"")  # a tile the set doesn't have: empty sea
    if path.stat().st_size == 0:
        return None
    return Image.open(io.BytesIO(path.read_bytes())).convert("RGBA")


def union(items):
    xs = [v for it in items for v in (it["bounds"][0], it["bounds"][2])]
    ys = [v for it in items for v in (it["bounds"][1], it["bounds"][3])]
    return [min(xs), min(ys), max(xs), max(ys)]


def focus(page, world):
    """Where the action is: the charted cells, bases and lifepods with room around them, at
    least FOCUS_MIN_M across and twice as wide as tall, kept inside the world. None when
    nothing is charted yet, so the still shows the whole world."""
    pts = [(x + page["cell_m"] / 2, y + page["cell_m"] / 2) for x, y, _ in page["cells"]]
    pts += [(x, y) for kind in ("bases", "lifepods") for x, y in page[kind]]
    if not pts:
        return None
    wl, wr = min(world[0], world[2]), max(world[0], world[2])
    wt, wb = min(world[1], world[3]), max(world[1], world[3])
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    w = max(FOCUS_MIN_M, max(xs) - min(xs) + 2 * FOCUS_PAD_M, 2 * (max(ys) - min(ys) + 2 * FOCUS_PAD_M))
    w = min(w, wr - wl, 2 * (wb - wt))
    h = w / 2
    cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    l = min(max(cx - w / 2, wl), wr - w)
    t = min(max(cy - h / 2, wt), wb - h)
    region = [l, t, l + w, t + h]
    return region if world[1] <= world[3] else [l, t + h, l + w, t]


def backdrop(bgs, public, cache, region=None):
    """The backgrounds as one picture plus the metres its edges stand for, or a dark canvas.
    With a region, only that part, from tiles sharp enough for the still's width."""
    bg = bgs[0] if bgs else None
    if bg and bg["tiles"]:
        left, top, right, bottom = bg["bounds"]
        zoom = 2  # 4 x 4 tiles of 512 px: 2048 px across the whole world
        if region:
            share = abs(region[2] - region[0]) / abs(right - left)
            while zoom < min(bg["max_zoom"], 6) and share * 512 * (1 << zoom) < STILL_W:
                zoom += 1
        n = 1 << zoom
        w, h = (right - left) / n, (bottom - top) / n
        if region:
            x0, x1 = max(0, math.floor((region[0] - left) / w)), min(n, math.ceil((region[2] - left) / w))
            y0, y1 = max(0, math.floor((region[1] - top) / h)), min(n, math.ceil((region[3] - top) / h))
        else:
            x0, x1, y0, y1 = 0, n, 0, n
        canvas = Image.new("RGBA", (512 * (x1 - x0), 512 * (y1 - y0)), (7, 25, 35, 255))
        rows, cols = set(), set()
        for y in range(y0, y1):
            for x in range(x0, x1):
                tile = fetch(bg["url"].format(z=zoom, x=x, y=y), cache)
                if tile is not None:
                    canvas.paste(tile, ((x - x0) * 512, (y - y0) * 512)); rows.add(y); cols.add(x)
        if region:
            px = 512 / w
            box = tuple(round(v) for v in ((region[0] - left) * px - x0 * 512, (region[1] - top) * (512 / h) - y0 * 512,
                                            (region[2] - left) * px - x0 * 512, (region[3] - top) * (512 / h) - y0 * 512))
            return canvas.crop(box), region
        if not rows:
            return canvas, bg["bounds"]
        # Only the rows and columns the set has tiles for: no empty sea around the still.
        x0, x1, y0, y1 = min(cols), max(cols) + 1, min(rows), max(rows) + 1
        canvas = canvas.crop((x0 * 512, y0 * 512, x1 * 512, y1 * 512))
        return canvas, [left + x0 * w, top + y0 * h, left + x1 * w, top + y1 * h]
    if bg:
        left, top, right, bottom = union(bgs)
        px = 2048 / (right - left)
        canvas = Image.new("RGBA", (2048, max(1, round((bottom - top) * px))), (7, 25, 35, 255))
        for it in bgs:  # pictures only here; a tile set is the first entry or not at all
            if it["tiles"]:
                continue
            src = fetch(it["url"], cache) if "://" in it["url"] else Image.open(public / it["url"]).convert("RGBA")
            l, t, r, b = it["bounds"]
            box = (round((l - left) * px), round((t - top) * px), round((r - left) * px), round((b - top) * px))
            canvas.paste(src.resize((max(1, box[2] - box[0]), max(1, box[3] - box[1]))), box[:2])
        if region:
            box = tuple(round(v) for v in ((region[0] - left) * px, (region[1] - top) * px,
                                            (region[2] - left) * px, (region[3] - top) * px))
            return canvas.crop(box), region
        return canvas, [left, top, right, bottom]
    if region:
        canvas = Image.new("RGBA", (1024, 512), (7, 25, 35, 255))
        return canvas, region
    return Image.new("RGBA", (1024, 1024), (7, 25, 35, 255)), [-2560, 2560, 2560, -2560]


def still(page, bg, public, cache):
    """map.png: the backdrop around the action, with the delayed trails, bases and lifepods on it."""
    world = union(bg) if bg else [-2560, 2560, 2560, -2560]
    img, (left, top, right, bottom) = backdrop(bg, public, cache, focus(page, world))
    scale = STILL_W / img.width
    img = img.resize((STILL_W, round(img.height * scale)), Image.LANCZOS)
    sx, sy = img.width / (right - left), img.height / (bottom - top)

    def at(x, y):
        return ((x - left) * sx, (y - top) * sy)

    draw = ImageDraw.Draw(img)
    for x, y, d in page["cells"]:
        px, py = at(x + page["cell_m"] / 2, y + page["cell_m"] / 2)
        draw.ellipse([px - 5, py - 5, px + 5, py + 5], fill=depth_colour(d), outline=(255, 255, 255), width=2)
    for kind, fill in (("lifepods", (255, 90, 79)), ("bases", (126, 231, 135))):
        for x, y in page[kind]:
            px, py = at(x, y)
            draw.ellipse([px - 6, py - 6, px + 6, py + 6], fill=fill, outline=(234, 247, 251), width=2)
    out = io.BytesIO()
    img.convert("RGB").save(out, "PNG", optimize=True)
    return out.getvalue()


def render_page(template, page, public_url):
    """The page with its link-preview tags filled in; absolute addresses need the public url."""
    world = page["world"] or "World map"
    about = "Where players have been on %s, about %d minutes behind. No live positions." % (world, page["delay_minutes"])
    image = (public_url.rstrip("/") + "/map.png") if public_url else "map.png"
    return (template.replace("{{WORLD}}", html.escape(world)).replace("{{ABOUT}}", html.escape(about))
            .replace("{{IMAGE}}", html.escape(image)))


def main():
    data = Path(os.environ.get("DATA_DIR", "/data"))
    control = Path(os.environ.get("CONTROL_DIR", data / "control"))
    public = Path(os.environ.get("PUBLIC_DIR", data / "public"))
    page = Path(os.environ.get("MAP_PAGE", "/opt/sn2/web/map.html"))
    if os.environ.get("WEB_MAP", "false") != "true":
        for name in ("map.html", "map.json", "map.png"):
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
        page_data["backgrounds"] = background(status, os.environ, data, public)
    except OSError as err:
        page_data["backgrounds"] = []
        print("map-chart: no background: %s" % err, file=sys.stderr)
    page_data["background"] = page_data["backgrounds"][0] if page_data["backgrounds"] else None
    # The still only when what it shows changed: the chart, the bases, the lifepods or the backdrop.
    sig = hashlib.sha256(json.dumps([page_data["cells"], page_data["bases"], page_data["lifepods"],
                                     page_data["backgrounds"]], sort_keys=True).encode()).hexdigest()[:16]
    page_data["still"] = sig
    write_json(public / "map.json", page_data)
    (public / "map.html").write_text(render_page(page.read_text(encoding="utf-8"), page_data,
                                                 os.environ.get("MAP_PUBLIC_URL", "")), encoding="utf-8")
    if chart.get("still") != sig or not (public / "map.png").exists():
        cache = data / "map-tiles"
        cache.mkdir(exist_ok=True)
        try:
            (public / "map.png").write_bytes(still(page_data, page_data["backgrounds"], public, cache))
            chart["still"] = sig
            write_json(store, chart)
        except (OSError, ValueError) as err:
            print("map-chart: no still: %s" % err, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
