#!/usr/bin/env python3
"""Render the join page's "mods this server uses" section.

Reads plugins.yaml (the admin's one list) and, when the server has published
a manifest (public/mods.json), the launcher that installs it. Prints a "Play
with mods" button when any mod is installable, then one list of the mods, each
a link to its own page, with its summary and, from mod-stats.py's file, its
public numbers. Prints nothing when the list is empty, so a bare server's join
page stays a plain "Join now". The HTML is web/mods.html.j2, rendered by Jinja2 with
every value escaped.

Usage: plugins-section.py <plugins.yaml> [<public dir>] [<mod stats file>]
"""
import datetime
import json
import os
import sys
from pathlib import Path

try:
    import yaml
    from jinja2 import FileSystemLoader, StrictUndefined
    from jinja2.sandbox import SandboxedEnvironment
except ModuleNotFoundError:
    sys.exit(0)  # no yaml or jinja2 available: render nothing rather than break the page


def read_stats(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            mods = json.load(fh).get("mods")
    except (OSError, ValueError, AttributeError):
        return {}
    return mods if isinstance(mods, dict) else {}


def stats_of(s: object) -> dict | None:
    """A mod's public numbers for the page ('★ 214 on GitHub · updated 8 Nov 2026 · by someone'), or None."""
    if not isinstance(s, dict):
        return None
    try:
        if s.get("site") == "github":
            out = {"stars": f"{int(s['stars']):,}", "downloads": ""}
        elif s.get("site") == "curseforge":
            out = {"stars": "", "downloads": f"{int(s['downloads']):,}"}
        else:
            return None
    except (KeyError, TypeError, ValueError):
        return None
    try:
        day = datetime.date.fromisoformat(str(s.get("updated") or ""))
        out["updated"] = f"{day.day} {day:%b %Y}"
    except ValueError:
        out["updated"] = ""
    out["by"] = str(s.get("by") or "")
    return out


def fetched_summary(s: object) -> str:
    """The mod's own one-line description from GitHub or CurseForge, for an entry the admin gave none."""
    return str(s.get("summary") or "") if isinstance(s, dict) else ""


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

    def row(p: dict) -> dict:
        name = str(p.get("name"))
        pub = published.get(name) or {}
        source = pub.get("source") or {}
        link = str(p.get("source") or source.get("page") or "")
        notes = []
        if str(p.get("tier", "optional")).lower() != "mandatory":
            notes.append("optional, off unless you tick it" if p.get("default", True) is False else "optional")
        if pub.get("native"):
            notes.append("native code")
        if source.get("type") == "local":
            notes.append("this server's own copy")
        if not pub:
            notes.append("install it yourself")
        elif not source.get("url"):
            notes.append("needs one download from its page")
        return {"name": name, "link": link if link.lower().startswith(("https://", "http://")) else "",
                "version": str(p.get("version") or pub.get("version") or ""), "notes": notes,
                "summary": str(p.get("summary") or pub.get("summary") or fetched_summary(stats.get(name))), "stats": stats_of(stats.get(name))}

    env = SandboxedEnvironment(loader=FileSystemLoader(Path(__file__).resolve().parent.parent / "web"), autoescape=True,
                               undefined=StrictUndefined)
    return env.get_template("mods.html.j2").render(launcher=bool(published and address), address=address, setup_url=SETUP_URL,
                                                   mods=[row(p) for p in shown])


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
