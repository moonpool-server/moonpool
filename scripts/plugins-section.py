#!/usr/bin/env python3
"""Render the join page's "mods this server uses" section.

Reads plugins.yaml (the admin's one list) and, when the server has published
a manifest (public/mods.json), the launcher that installs it. Prints a "Play
with mods" button when any mod is installable, then one list of the mods, each
a link to its own page, with its summary and, from mod-stats.py's file, its
public numbers. Prints nothing when the list is empty, so a bare server's join
page stays a plain "Join now".

Usage: plugins-section.py <plugins.yaml> [<public dir>] [<mod stats file>]
"""
import datetime
import html
import json
import os
import sys

try:
    import yaml
except ModuleNotFoundError:
    sys.exit(0)  # no yaml available: render nothing rather than break the page


def esc(value: object) -> str:
    return html.escape(str(value or ""), quote=True)


MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")


def read_stats(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            mods = json.load(fh).get("mods")
    except (OSError, ValueError, AttributeError):
        return {}
    return mods if isinstance(mods, dict) else {}


def stats_line(s: object) -> str:
    """One line of a mod's public numbers: '★ 214 on GitHub · updated 8 Nov 2026 · by someone'."""
    if not isinstance(s, dict):
        return ""
    parts = []
    try:
        if s.get("site") == "github":
            parts.append(f"&#9733; {int(s['stars']):,} on GitHub")
        elif s.get("site") == "curseforge":
            parts.append(f"{int(s['downloads']):,} downloads on CurseForge")
        else:
            return ""
    except (KeyError, TypeError, ValueError):
        return ""
    try:
        day = datetime.date.fromisoformat(str(s.get("updated") or ""))
        parts.append(f"updated {day.day} {MONTHS[day.month - 1]} {day.year}")
    except ValueError:
        pass
    if s.get("by"):
        parts.append("by " + esc(s["by"]))
    return " &middot; ".join(parts)


def read_manifest(public: str) -> dict:
    if not public:
        return {}
    path = os.path.join(public, "mods.json")
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


SETUP_URL = "https://github.com/moonpool-server/moonpool/releases/latest/download/moonpool-setup.cmd"


def server_address(public: str) -> str:
    try:
        with open(os.path.join(public, "moonpool.json"), encoding="utf-8") as fh:
            return str(json.load(fh)["manifest_url"]).rsplit("/", 1)[0]
    except (OSError, ValueError, KeyError, TypeError):
        return ""


def render(plugins: list, manifest: dict, address: str = "", stats: dict | None = None) -> str:
    stats = stats or {}
    published = {m.get("name"): m for m in manifest.get("mods", []) if isinstance(m, dict)}
    shown = [p for p in plugins if isinstance(p, dict) and p.get("name") and p.get("enabled", True) is not False
             and str(p.get("side", "client")).lower() != "host"]
    if not shown:
        return ""

    def row(p: dict) -> str:
        name = str(p.get("name"))
        pub = published.get(name) or {}
        source = pub.get("source") or {}
        link = p.get("source") or source.get("page") or ""
        text = f'<a href="{esc(link)}">{esc(name)}</a>' if link.lower().startswith(("https://", "http://")) else esc(name)
        version = p.get("version") or pub.get("version")
        if version:
            text += f" {esc(version)}"
        notes = []
        if str(p.get("tier", "optional")).lower() != "mandatory":
            notes.append("optional")
        if pub.get("native"):
            notes.append("native code")
        if source.get("type") == "local":
            notes.append("this server's own copy")
        if not pub:
            notes.append("install it yourself")
        elif not source.get("url"):
            notes.append("needs one download from its page")
        about = [esc(p.get("summary") or pub.get("summary") or ""), stats_line(stats.get(name))]
        about = "<br>".join(a for a in about if a)
        about = f'<span class="about">{about}</span>' if about else ""
        return f'<li>{text}{" (" + ", ".join(notes) + ")" if notes else ""}{about}</li>'

    # A page cannot tell whether the moonpool: link has a handler, so a click says at once what
    # should happen, and if the page still has focus a few seconds later, what to do when it didn't.
    head = (f'<a class="button" id="playmods" href="moonpool:{esc(address)}">Play with mods</a>'
            f'<div class="notice" id="opening" hidden><strong>Opening Moonpool&hellip;</strong> '
            f'If your browser asks, allow it to open Moonpool. Its window lists the mods and asks before installing anything.</div>'
            f'<div class="notice warn" id="nothing" hidden><strong>Still waiting?</strong> '
            f'If your browser is asking to open Moonpool, allow it. If nothing is asking and no Moonpool window opened, '
            f'this PC doesn\'t have the launcher yet. It takes a minute, once:'
            f'<ol><li>Download the launcher with the button below. It is one small file from the Moonpool project on GitHub.</li>'
            f'<li>Run it. Windows may say it protected your PC, because the file isn\'t code-signed: '
            f'choose More info, then Run anyway.</li>'
            f'<li>Press Play with mods again.</li></ol>'
            f'<a class="button get" href="{SETUP_URL}">Download the launcher</a></div>'
            f'<p>First time on this PC? <a href="{SETUP_URL}">Get the launcher</a> once, then press Play with mods.</p>'
            f'<p class="fine">Play with mods installs or updates this server\'s mods and turns them on only until '
            f'Subnautica 2 closes; normal launches don\'t load them. Mods run with your Windows account\'s rights, '
            f'so only accept a host you trust.</p>'
            '<script>(function(){var b=document.getElementById("playmods"),o=document.getElementById("opening"),'
            'n=document.getElementById("nothing"),t=0;if(!b||!o||!n)return;'
            'b.addEventListener("click",function(){o.hidden=false;n.hidden=true;clearTimeout(t);'
            't=setTimeout(function(){if(document.visibilityState==="visible"&&document.hasFocus()){o.hidden=true;n.hidden=false;}},4000);});'
            'window.addEventListener("blur",function(){clearTimeout(t);});})();</script>') \
        if published and address else \
        '<div class="opt"><p class="fine">Mods this server asks for:</p>'
    tail = "" if published else "</div>"
    if any(stats_line(stats.get(str(p.get("name")))) for p in shown):
        tail = ('<p class="fine">Stars and downloads come from GitHub and CurseForge. They show how widely a mod '
                'is used, not that its file is safe.</p>') + tail
    return head + '<ul class="mods">' + "".join(row(p) for p in shown) + "</ul>" + tail


def main() -> None:
    path = sys.argv[1] if len(sys.argv) > 1 else "plugins.yaml"
    public = sys.argv[2] if len(sys.argv) > 2 else ""
    try:
        with open(path, encoding="utf-8") as fh:
            data = yaml.safe_load(fh) or {}
    except FileNotFoundError:
        return
    plugins = data.get("plugins") if isinstance(data, dict) else None
    if isinstance(plugins, list):
        stats = read_stats(sys.argv[3]) if len(sys.argv) > 3 else {}
        sys.stdout.write(render(plugins, read_manifest(public), server_address(public) if public else "", stats))


if __name__ == "__main__":
    main()
