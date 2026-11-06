#!/usr/bin/env python3
"""Render the join page's "mods this server uses" section.

Reads plugins.yaml (the admin's one list) and, when the server has published
a manifest (public/mods.json), the launcher that installs it. Prints a "Play
with mods" button when any mod is installable, then one list of the mods, each
a link to its own page. Prints nothing when the list is empty, so a bare
server's join page stays a plain "Join now".

Usage: plugins-section.py <plugins.yaml> [<public dir>]
"""
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


def render(plugins: list, manifest: dict, address: str = "") -> str:
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
        if not pub:
            notes.append("install it yourself")
        elif not source.get("url"):
            notes.append("needs one download from its page")
        return f'<li>{text}{" (" + ", ".join(notes) + ")" if notes else ""}</li>'

    head = (f'<a class="button" href="moonpool:{esc(address)}">Play with mods</a>'
            f'<p class="fine">Asks you first, installs these, and joins. First time? '
            f'<a href="{SETUP_URL}">Get the launcher</a> once, from the project on GitHub.</p>') \
        if published and address else \
        '<div class="opt"><p class="fine">Mods this server asks for:</p>'
    tail = "" if published else "</div>"
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
        sys.stdout.write(render(plugins, read_manifest(public), server_address(public) if public else ""))


if __name__ == "__main__":
    main()
