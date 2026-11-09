#!/usr/bin/env python3
# Drives this repository's chart script against a fake status file.
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "map-chart.py"


def run(tmp, now, players, **env):
    control = tmp / "control"
    control.mkdir(exist_ok=True)
    (control / "status.json").write_text(json.dumps({
        "ts": now, "players": players, "bases": json.loads(env.pop("BASES", "{}")), "lifepods": [{"x": 100000, "y": 200000}]}))
    full = dict(os.environ, DATA_DIR=str(tmp), CONTROL_DIR=str(control), PUBLIC_DIR=str(tmp / "public"),
                MAP_PAGE=str(ROOT / "web" / "map.html"), SN2_NOW=str(now), HOST_NAME="Host", WEB_MAP="true", **env)
    subprocess.run([sys.executable, str(SCRIPT)], check=True, env=full)
    return tmp / "public" / "map.json"


def test_an_admins_map_page_in_the_data_volume_is_used_and_map_page_overrides_it() -> None:
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        (tmp / "templates").mkdir()
        (tmp / "templates" / "map.html").write_text("<html><title>{{WORLD}} mine</title></html>")
        env = dict(os.environ, DATA_DIR=str(tmp), CONTROL_DIR=str(tmp / "control"), PUBLIC_DIR=str(tmp / "public"),
                   SN2_NOW="1000", HOST_NAME="Host", WEB_MAP="true", WORLD_NAME="Deep")
        env.pop("MAP_PAGE", None)
        (tmp / "control").mkdir()
        (tmp / "control" / "status.json").write_text(json.dumps({"ts": 1000, "players": [], "bases": {}, "lifepods": []}))
        subprocess.run([sys.executable, str(SCRIPT)], check=True, env=env)
        assert "Deep mine" in (tmp / "public" / "map.html").read_text()
        subprocess.run([sys.executable, str(SCRIPT)], check=True, env=dict(env, MAP_PAGE=str(ROOT / "web" / "map.html")))
        assert "Deep mine" not in (tmp / "public" / "map.html").read_text()


def test_a_picture_over_the_size_cap_is_left_out_like_a_missing_tile() -> None:
    import importlib.util
    from unittest import mock
    spec = importlib.util.spec_from_file_location("map_chart", SCRIPT)
    chart = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(chart)

    class Big:
        def read(self, n=-1): return b"x" * (n if n > 0 else chart.MAX_PICTURE_BYTES + 1)
        def __enter__(self): return self
        def __exit__(self, *a): return False
    with tempfile.TemporaryDirectory() as d, mock.patch.object(chart.urllib.request, "urlopen", return_value=Big()):
        assert chart.fetch("https://tiles.example/0/0/0.png", Path(d)) is None
        cached = list(Path(d).iterdir())
        assert len(cached) == 1 and cached[0].stat().st_size == 0


def test_each_player_shows_where_they_were_after_the_delay_and_never_now() -> None:
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        alice = {"name": "Alice", "x": 123456, "y": -7000, "depth_m": 90}
        published = run(tmp, 1000, [alice, {"name": "Host", "x": 1, "y": 1}])
        assert json.loads(published.read_text())["divers"] == []  # now is never published
        moved = json.loads(run(tmp, 1900, [dict(alice, x=500000)]).read_text())
        assert moved["divers"] == [{"name": "Alice", "x": 1235, "y": -70, "depth": 90, "online": True, "left_minutes": None}]
        assert moved["explored"] == [[1200, -100]]  # her first square clears from the fog; the host never does
        assert moved["lifepods"] == [[1000, 2000]] and moved["bases"] == []
        left = json.loads(run(tmp, 1900 + 1200, [], SHOW_PLAYER_NAMES="false").read_text())
        assert [(p["name"], p["x"], p["online"], p["left_minutes"]) for p in left["divers"]] == [("Player 1", 5000, False, 20)]
        assert "Alice" not in published.read_text()
        assert json.loads(run(tmp, 1900 + 900 + 3600 + 60, []).read_text())["divers"] == []  # an hour after they left


def test_a_new_base_waits_out_the_delay_too() -> None:
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        now = json.loads(run(tmp, 1000, [], BASES='[{"x":70000,"y":80000}]').read_text())
        assert now["bases"] == []
        later = json.loads(run(tmp, 1000 + 900, [], BASES='[{"x":70000,"y":80000}]').read_text())
        assert later["bases"] == [[700, 800]]


def test_the_map_file_gives_each_game_branch_its_own_background() -> None:
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        (tmp / "chart.png").write_bytes(b"picture")
        tiles = "https://tiles.example/{z}/{y}/{x}.webp"
        (tmp / "map-background.json").write_text(json.dumps({
            "public": {"url": tiles, "bounds": [0, 100, 200, 300]},
            "experimental": {"url": "chart.png", "bounds": [0, 100, 200, 300], "max_zoom": 4},
            "broken": {"url": tiles}}))
        one = json.loads(run(tmp, 1000, [], STEAM_BRANCH="public").read_text())["background"]
        assert one == {"url": tiles, "tiles": True, "max_zoom": 8, "bounds": [0, 1, 2, 3]}
        two = json.loads(run(tmp, 1000, [], STEAM_BRANCH="experimental").read_text())["background"]
        assert two["url"] == "map-background-0.png" and not two["tiles"] and two["max_zoom"] == 4
        assert (tmp / "public" / "map-background-0.png").read_bytes() == b"picture"
        assert json.loads(run(tmp, 1000, [], STEAM_BRANCH="broken").read_text())["background"] is None
        assert json.loads(run(tmp, 1000, [], STEAM_BRANCH="other").read_text())["background"] is None


def test_a_new_save_starts_its_own_chart_and_a_new_lifepod_waits() -> None:
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        control = tmp / "control"
        control.mkdir()
        env = dict(os.environ, DATA_DIR=str(tmp), CONTROL_DIR=str(control), PUBLIC_DIR=str(tmp / "public"),
                   MAP_PAGE=str(ROOT / "web" / "map.html"), WEB_MAP="true", HOST_NAME="Host", MAP_DELAY_MINUTES="0")
        for save, now in (("One", 1000), ("Two", 1001)):
            (control / "status.json").write_text(json.dumps({"ts": now, "save": save, "branch": "public", "players": [
                {"name": "A", "x": 5000 if save == "One" else 50000, "y": 0, "depth_m": 1}]}))
            subprocess.run([sys.executable, str(SCRIPT)], check=True, env=dict(env, SN2_NOW=str(now)))
        assert [p["x"] for p in json.loads((tmp / "public" / "map.json").read_text())["divers"]] == [500]  # save One's isn't here
        env["MAP_DELAY_MINUTES"] = "15"
        (control / "status.json").write_text(json.dumps({"ts": 2000, "save": "Two", "branch": "public",
                                                         "lifepods": [{"x": 700, "y": 800}]}))
        subprocess.run([sys.executable, str(SCRIPT)], check=True, env=dict(env, SN2_NOW="2000"))
        assert json.loads((tmp / "public" / "map.json").read_text())["lifepods"] == []


def test_the_page_carries_link_preview_tags_and_a_still_is_drawn_without_a_background() -> None:
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        alice = {"name": "Alice", "x": 123456, "y": -7000, "z": -9000, "depth_m": 90}
        run(tmp, 1000, [alice], WORLD_NAME="Deep Blue", MAP_PUBLIC_URL="https://play.example", MAP_DELAY_MINUTES="0")
        page = (tmp / "public" / "map.html").read_text(encoding="utf-8")
        assert '<meta property="og:title" content="Deep Blue map">' in page
        assert '<meta property="og:image" content="https://play.example/map.png">' in page
        assert "{{" not in page
        png = (tmp / "public" / "map.png").read_bytes()
        assert png[:8] == b"\x89PNG\r\n\x1a\n"
        before = (tmp / "public" / "map.png").stat().st_mtime_ns
        run(tmp, 1001, [], WORLD_NAME="Deep Blue", MAP_DELAY_MINUTES="0")
        assert (tmp / "public" / "map.png").stat().st_mtime_ns == before  # nothing changed, not redrawn


def test_a_branch_can_lay_several_pictures_side_by_side() -> None:
    from PIL import Image
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        for n, colour in (("west", (200, 50, 50)), ("east", (50, 200, 50))):
            Image.new("RGB", (64, 64), colour).save(tmp / f"{n}.png")
        (tmp / "map-background.json").write_text(json.dumps({"public": [
            {"url": "west.png", "bounds": [0, 0, 100000, 100000]},
            {"url": "east.png", "bounds": [100000, 0, 200000, 100000]}]}))
        data = json.loads(run(tmp, 1000, [], STEAM_BRANCH="public").read_text())
        assert [g["url"] for g in data["backgrounds"]] == ["map-background-0.png", "map-background-1.png"]
        assert data["background"]["bounds"] == [0, 0, 1000, 1000] and len(data["still"]) == 16
        still = Image.open(tmp / "public" / "map.png")
        assert still.size[0] == 1200 and still.getpixel((300, 300))[:3] == (200, 50, 50)
        assert still.getpixel((900, 300))[:3] == (50, 200, 50)


def test_turning_the_map_off_withdraws_the_page_and_a_stale_status_charts_nothing() -> None:
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        published = run(tmp, 1000, [])
        assert (tmp / "public" / "map.html").exists()
        control = tmp / "control"
        (control / "status.json").write_text(json.dumps({"ts": 1, "players": [{"name": "A", "x": 5, "y": 5}]}))
        env = dict(os.environ, DATA_DIR=str(tmp), CONTROL_DIR=str(control), PUBLIC_DIR=str(tmp / "public"),
                   MAP_PAGE=str(ROOT / "web" / "map.html"), SN2_NOW="1000000", WEB_MAP="true", MAP_DELAY_MINUTES="0")
        subprocess.run([sys.executable, str(SCRIPT)], check=True, env=env)
        assert json.loads(published.read_text())["divers"] == []
        env["WEB_MAP"] = "false"
        subprocess.run([sys.executable, str(SCRIPT)], check=True, env=env)
        assert not published.exists() and not (tmp / "public" / "map.html").exists()
        assert not (tmp / "public" / "map.png").exists()


if __name__ == "__main__":
    test_each_player_shows_where_they_were_after_the_delay_and_never_now()
    test_a_new_base_waits_out_the_delay_too()
    test_the_map_file_gives_each_game_branch_its_own_background()
    test_a_new_save_starts_its_own_chart_and_a_new_lifepod_waits()
    test_a_branch_can_lay_several_pictures_side_by_side()
    test_the_page_carries_link_preview_tags_and_a_still_is_drawn_without_a_background()
    test_turning_the_map_off_withdraws_the_page_and_a_stale_status_charts_nothing()
    print("map chart: ok")
