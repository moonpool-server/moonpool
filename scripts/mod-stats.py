#!/usr/bin/env python3
"""Public numbers about each mod on the server's list, for the join page.

For a mod whose page is a GitHub repository: its stars, last push and owner, from GitHub's public
API. For a CurseForge project: its downloads, last update and authors, from CurseForge's API with
the server's CURSEFORGE_API_KEY. Nexus and other pages get nothing. Read at most every
MOD_STATS_MAX_AGE seconds (default six hours) into one JSON file; a failed read keeps the last
numbers for that mod. They say how widely a project is used, not whether a file is safe.

Usage: mod-stats.py <plugins.yaml> <stats.json>
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sn2files import write_atomic  # noqa: E402  (beside this file)

try:
    import yaml
except ImportError:
    sys.exit(0)

CF_API = os.environ.get("CURSEFORGE_API_URL", "https://api.curseforge.com/v1").rstrip("/")
CF_GAME_ID = int(os.environ.get("CURSEFORGE_GAME_ID", "99704"))  # Subnautica 2 on CurseForge
GH_API = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
GH_REPO = re.compile(r"^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(?:[/?#]|$)")
CF_SLUG = re.compile(r"^https://www\.curseforge\.com/subnautica-2/[a-z0-9-]+/([a-z0-9-]+)(?:[/?#]|$)")


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.URLError(f"refusing to follow a redirect to {newurl}")


def get_json(url, headers):
    request = urllib.request.Request(url, headers={"User-Agent": "moonpool mod stats", **headers})
    with urllib.request.build_opener(NoRedirects).open(request, timeout=20) as response:
        return json.load(response)


def cf_url(path):
    """The CurseForge API address the key may go to: https://api.curseforge.com, or a local file
    for tests. Anything else is refused before the key is attached."""
    url = f"{CF_API}{path}"
    parts = urllib.parse.urlsplit(url)
    if not ((parts.scheme == "https" and parts.hostname == "api.curseforge.com") or parts.scheme == "file"):
        raise ValueError(f"refusing to send the CurseForge key to {parts.scheme}://{parts.hostname}")
    return url


def github(repo):
    headers = {"Accept": "application/vnd.github+json"}
    if os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["GITHUB_TOKEN"]
    data = get_json(f"{GH_API}/repos/{repo}", headers)
    return {"site": "github", "stars": int(data["stargazers_count"]), "updated": str(data.get("pushed_at") or "")[:10],
            "by": str((data.get("owner") or {}).get("login") or "")}


def curseforge(project_id, slug, key):
    headers = {"x-api-key": key}
    if not project_id:
        found = get_json(cf_url(f"/mods/search?gameId={CF_GAME_ID}&slug={urllib.parse.quote(slug)}"), headers)["data"]
        if not found:
            raise ValueError(f"no CurseForge project {slug!r}")
        project = found[0]
    else:
        project = get_json(cf_url(f"/mods/{int(project_id)}"), headers)["data"]
    authors = ", ".join(str(a.get("name")) for a in project.get("authors") or [] if a.get("name"))
    return {"site": "curseforge", "downloads": int(project.get("downloadCount") or 0),
            "updated": str(project.get("dateModified") or "")[:10], "by": authors}


def project_of(entry):
    """('github', 'owner/repo'), ('curseforge', project id or slug), or None when the entry's
    pages are on no site read here."""
    install = entry.get("install") if isinstance(entry.get("install"), dict) else {}
    pages = [str(entry.get("source") or ""), str(install.get("url") or "")]
    if str(install.get("type", "")).lower() == "github" and install.get("repo"):
        return ("github", str(install["repo"]))
    for page in pages:
        m = GH_REPO.match(page)
        if m:
            return ("github", m.group(1))
    if str(install.get("type", "")).lower() == "curseforge" and isinstance(install.get("project_id"), int):
        return ("curseforge", str(install["project_id"]))
    slug = next((m.group(1) for m in (CF_SLUG.match(p) for p in pages) if m), "")
    return ("curseforge", slug) if slug else None


def lookup(project, key):
    site, ident = project
    if site == "github":
        return github(ident)
    if not key:
        return None
    return curseforge(int(ident), "", key) if ident.isdigit() else curseforge(None, ident, key)


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 64
    plugins_path, out = Path(sys.argv[1]), Path(sys.argv[2])
    try:
        stats = json.loads(out.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        stats = {}
    if not isinstance(stats, dict):
        stats = {}
    max_age = int(os.environ.get("MOD_STATS_MAX_AGE") or 21600)
    now = int(os.environ.get("SN2_NOW") or time.time())
    if now - int(stats.get("ts") or 0) < max_age:
        return 0
    try:
        plugins = (yaml.safe_load(plugins_path.read_text(encoding="utf-8")) or {}).get("plugins") or []
    except (OSError, yaml.YAMLError, AttributeError):
        return 0
    key = os.environ.get("CURSEFORGE_API_KEY", "")
    mods = stats.get("mods") if isinstance(stats.get("mods"), dict) else {}
    fresh = {}
    for entry in plugins:
        if not isinstance(entry, dict) or not entry.get("name"):
            continue
        name = str(entry["name"])
        project = project_of(entry)
        if not project:
            continue
        ident = ":".join(project)
        try:
            found = lookup(project, key)
        except (OSError, ValueError, KeyError, TypeError, urllib.error.URLError) as exc:
            last = mods.get(name)
            found = last if isinstance(last, dict) and last.get("project") == ident else None
            print(f"mod stats: {name}: {exc}; " + ("keeping the last numbers" if found else "no numbers shown"), file=sys.stderr)
        if found:
            found["project"] = ident
            fresh[name] = found
    write_atomic(out, json.dumps({"ts": now, "mods": fresh}, indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
