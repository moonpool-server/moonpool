#!/usr/bin/env python3
"""The join page: one static render of the game's current Steam lobby into public/join.html.

Without a lobby it's a retrying "starting" page. With published mods the launcher leads
and nothing joins by itself; otherwise the page hands off to Steam on its own.
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

from jinja2 import FileSystemLoader, StrictUndefined, TemplateError, select_autoescape
from jinja2.sandbox import SandboxedEnvironment

sys.path.insert(0, str(Path(__file__).resolve().parent))
import steamfile  # noqa: E402  (beside this file)

HERE = Path(__file__).resolve().parent


def render_join(search, values):
    """The page from the first join.html.j2 on `search`, in a sandbox with every variable
    required; None when that template cannot render."""
    env = SandboxedEnvironment(loader=FileSystemLoader(search), autoescape=select_autoescape(["j2", "html"]),
                               undefined=StrictUndefined)
    try:
        return env.get_template("join.html.j2").render(**values)
    except TemplateError as err:
        print(f"join page: the template in {search[0]} did not render ({err}); using the shipped page", file=sys.stderr)
        return None


def main():
    data = Path(os.environ.get("DATA_DIR") or "/data")
    run = Path(os.environ.get("RUN_DIR") or data / "run")
    public = Path(os.environ.get("PUBLIC_DIR") or data / "public")
    control = Path(os.environ.get("SN2_CONTROL_DIR") or data / "control")
    session_file = Path(os.environ.get("SESSION_FILE") or run / "mod-session.json")
    public.mkdir(parents=True, exist_ok=True)

    try:
        session = json.loads(session_file.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        session = {}
    lobby, sid = str(session.get("lobby_id") or ""), str(session.get("host_steamid") or "")
    if lobby.startswith("0x"):
        lobby = str(int(lobby, 16))
    join = friend = ""
    if re.fullmatch(r"[0-9]+", lobby) and re.fullmatch(r"[0-9]{17}", sid):
        join = f"steam://joinlobby/1962700/{lobby}/{sid}"
        friend = f"https://steamcommunity.com/profiles/{sid}"

    # Each mod's public numbers, refreshed every few hours (mod-stats.py); a slow or failed read
    # leaves the last ones and never holds up the page.
    stats_file = run / "mod-stats.json"
    try:
        subprocess.run([sys.executable, str(HERE / "mod-stats.py"), str(control / "plugins.yaml"), str(stats_file)],
                       capture_output=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        pass
    # The server's mod list as HTML (plugins-section.py), empty when there is none.
    try:
        modnote = subprocess.run([sys.executable, str(HERE / "plugins-section.py"), str(control / "plugins.yaml"), str(public),
                                  str(stats_file)],
                                 capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        modnote = ""
    try:
        published = len(json.loads((public / "mods.json").read_text(encoding="utf-8")).get("mods") or []) > 0
    except (OSError, ValueError, AttributeError):
        published = False

    # The Steam branch and build the server runs: a player on another branch cannot join.
    manifest = os.environ.get("SN2_APPMANIFEST") or str(Path(os.environ.get("WINEPREFIX") or data / "wine")
                                                      / "drive_c/Program Files (x86)/Steam/steamapps/appmanifest_1962700.acf")
    build = steamfile.get(manifest, "buildid")
    branch = steamfile.get(manifest, "BetaKey") or os.environ.get("STEAM_BRANCH") or ""
    if build and not branch:
        branch = "public"

    refresh = "" if not join else ("" if published else f"1;url={join}")
    if not join:
        refresh = "15"
    # The admin's own copy of the page, templates/join.html.j2 in the data volume, wins over the
    # shipped one. A copy that fails to render is said in the log and the shipped page is used.
    values = dict(world=os.environ.get("WORLD_NAME") or "Subnautica 2 server", join=join, friend=friend, refresh=refresh,
                  modnote=modnote, mods_published=published, build=build, branch=branch, branch_label=branch[:1].upper() + branch[1:])
    shipped = str(HERE.parent / "web")
    html = render_join([str(data / "templates"), shipped], values)
    if html is None:
        html = render_join([shipped], values)
    tmp = public / "join.html.tmp"
    tmp.write_text(html, encoding="utf-8")
    os.replace(tmp, public / "join.html")
    return 0


if __name__ == "__main__":
    sys.exit(main())
