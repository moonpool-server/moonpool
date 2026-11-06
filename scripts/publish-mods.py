#!/usr/bin/env python3
# The manifest is the moonpool launcher's own format; signing is the cryptography package.
"""Turn control/plugins.yaml into the signed mod manifest the moonpool launcher syncs to.

The admin keeps ONE list (plugins.yaml). Every entry is on unless it says
`enabled: false`. An entry with an `install:` block is resolved here into a
download the launcher can verify: GitHub release assets and the server's own
mods are fetched and hashed here; CurseForge files through its API; Nexus
files once the admin has pinned the archive (`moonpool mods pin`). An entry
without `install:` stays a link on the join page, as before.

A resolved hash is remembered in the data volume (mods-pins.json), so a GitHub
asset whose bytes change under the same tag is refused instead of silently
pushed to players. An entry that cannot be resolved keeps its last published
record: an outage or a bad edit never takes a mod away from players. The
service loop passes --cached, which reuses an unchanged entry's record with no
network call; an explicit publish resolves everything again.

Subcommands: publish (default), pin <name> <archive>, enable <name>, disable <name>.
"""
import argparse
import base64
import hashlib
import io
import ipaddress
import json
import os
import re
import shutil
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import steamfile  # noqa: E402  (beside this file)

import yaml
from cryptography.hazmat.primitives import serialization

APP_ID = "1962700"
SCHEMA = 3
TRIO = {".pak", ".ucas", ".utoc"}
CF_API = os.environ.get("CURSEFORGE_API_URL", "https://api.curseforge.com/v1").rstrip("/")
CF_GAME_ID = int(os.environ.get("CURSEFORGE_GAME_ID", "99704"))  # Subnautica 2 on CurseForge
URL_SHAPES = ("https://github.com/<owner>/<repo>/releases/download/<tag>/<file>, "
              "https://www.curseforge.com/subnautica-2/<category>/<mod>/files/<file id>, "
              "https://www.nexusmods.com/subnautica2/mods/<id>?tab=files&file_id=<file id>")
CF_HASHES = {1: "sha1", 2: "md5"}
CF_DOWNLOAD_HOSTS = (".curseforge.com", ".forgecdn.net")
# The loader players get is the host's own pinned build, from this repository's
# mirror of it (upstream's experimental-latest tag moves; scripts/install-ue4ss.sh).
UE4SS_MIRROR = os.environ.get("UE4SS_MIRROR", "https://github.com/moonpool-server/moonpool/releases/download/ue4ss-mirror")
UE4SS_PINS = {
    "pinned": ("UE4SS_v3.0.1-1188-gf885e8d2.zip", "4a594fb5c6e1aa794b06a770730e072c53fb92b741f95a5f0601080d80f4a6c1"),
    "upstream-experimental": ("UE4SS_v3.0.1-1190-gf673aac0.zip", "3ce35217fead1982e4563ef974364b7cfedf1dd6d28bb1193caf19877310364b"),
}
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 _.+()\[\]-]*$")
SAFE_FOLDER = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]*$")


def sha256(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as src:
        for block in iter(lambda: src.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def acf_value(path, name):
    return steamfile.get(path, name)


def read_plugins(path):
    if not path.is_file():
        return []
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    value = data.get("plugins") if isinstance(data, dict) else None
    if value is None:
        return []
    if not isinstance(value, list):
        raise ValueError("plugins.yaml: plugins must be a list")
    return value


def write_plugins(path, plugins):
    text = yaml.safe_dump({"plugins": plugins}, sort_keys=False, allow_unicode=True)
    tmp = path.with_suffix(".yaml.tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def put(path, data):
    """Replace a served file whole, and only when it changed: the loop runs every 30 s
    and a player may be downloading it."""
    path = Path(path)
    if path.is_file() and path.read_bytes() == data:
        return
    tmp = path.with_name("." + path.name + ".tmp")
    tmp.write_bytes(data)
    os.replace(tmp, path)


def zip_bytes(members):
    """A zip whose bytes depend only on its members, so an unchanged mod keeps its hash."""
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as bundle:
        for name, data in members:
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            bundle.writestr(info, data)
    return out.getvalue()


MAX_DOWNLOAD = 512 * 1024 * 1024


def copy_capped(response, output, url, cap=None):
    """Stream a download to disk and refuse one past the cap, so a mod page cannot fill the disk."""
    cap = MAX_DOWNLOAD if cap is None else cap
    total = 0
    while True:
        chunk = response.read(1024 * 1024)
        if not chunk:
            return total
        total += len(chunk)
        if total > cap:
            raise ValueError(f"download of {url} passed {cap // (1024 * 1024)} MB; refused")
        output.write(chunk)


def fetch(url, dest, headers=None):
    request = urllib.request.Request(url, headers=headers or {"User-Agent": "moonpool publisher"})
    try:
        with urllib.request.urlopen(request, timeout=120) as response, Path(dest).open("wb") as output:
            copy_capped(response, output, url)
    except urllib.error.URLError as exc:
        raise ValueError(f"download failed for {url}: {exc}") from exc


def check_cf_host(url):
    parts = urllib.parse.urlsplit(url)
    host = parts.hostname or ""
    if parts.scheme != "https" or not host.endswith(CF_DOWNLOAD_HOSTS):
        raise ValueError(f"refusing to send the CurseForge key to {url}")


class CurseForgeRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        check_cf_host(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch_with_cf_key(url, dest, key):
    """A download that carries the API key: every hop must be CurseForge's own."""
    check_cf_host(url)
    request = urllib.request.Request(url, headers={"x-api-key": key})
    try:
        with urllib.request.build_opener(CurseForgeRedirects).open(request, timeout=120) as response, \
                Path(dest).open("wb") as output:
            copy_capped(response, output, url)
    except urllib.error.URLError as exc:
        raise ValueError(f"download failed for {url}: {exc}") from exc


def cf_get(path, key):
    request = urllib.request.Request(f"{CF_API}{path}", headers={"x-api-key": key})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)["data"]
    except (urllib.error.URLError, KeyError, json.JSONDecodeError) as exc:
        raise ValueError(f"CurseForge API request failed for {path}: {exc}") from exc


def cf_hashes(file_data):
    result = []
    for entry in file_data.get("hashes", []):
        algorithm = CF_HASHES.get(entry.get("algo"))
        value = str(entry.get("value", "")).lower()
        if algorithm and value:
            result.append({"algorithm": algorithm, "value": value})
    if not result:
        raise ValueError(f"CurseForge file {file_data.get('id')} has no supported hash")
    return result


def verify_hashes(path, hashes):
    for expected in hashes:
        digest = hashlib.new(expected["algorithm"])
        with Path(path).open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
        if digest.hexdigest().lower() != expected["value"]:
            raise ValueError(f"{Path(path).name} failed its {expected['algorithm']} check")


# ---- what is inside an archive -------------------------------------------------

def archive_roots(archive, kind):
    """The mods inside a zip, as the launcher must place them.

    ue4ss: every folder holding Scripts/main.lua or dlls/main.dll is one mod
    (`{name, prefix}`; prefix is the folder inside the zip, '' for a zip that IS
    the mod). pak: the .pak/.ucas/.utoc trios, by stem. Member names are checked
    so a crafted zip cannot name a path outside its folder."""
    roots = []
    with zipfile.ZipFile(archive) as bundle:
        names = [m.filename for m in bundle.infolist() if not m.is_dir()]
        for member in names:
            parts = member.replace("\\", "/").split("/")
            if any(p in ("", ".", "..") or ":" in p for p in parts) or member.startswith("/"):
                raise ValueError(f"archive {Path(archive).name} has an unsafe path: {member}")
        if kind == "ue4ss":
            seen = set()
            for member in names:
                # Windows reads the folder names without regard to case, and so do authors.
                m = re.match(r"^(?:(.*)/)?(?i:scripts/main\.lua|dlls/main\.dll)$", member.replace("\\", "/"))
                if not m:
                    continue
                prefix = m.group(1) or ""
                name = prefix.rsplit("/", 1)[-1] if prefix else ""
                if prefix in seen:
                    continue
                seen.add(prefix)
                # Native code is any DLL under the mod's folder, not only a UE4SS C++ mod's
                # dlls/main.dll: a Lua mod that loads its own library carries one elsewhere.
                folder = prefix + "/" if prefix else ""
                native = any(n.replace("\\", "/").lower().endswith(".dll") and n.replace("\\", "/").startswith(folder)
                             for n in names)
                roots.append({"name": name, "prefix": prefix, "native": native})
            if not roots:
                raise ValueError(f"archive {Path(archive).name} holds no UE4SS mod (no Scripts/main.lua or dlls/main.dll)")
        else:
            stems = {}
            for member in names:
                p = Path(member)
                if p.suffix.lower() in TRIO:
                    stems.setdefault(str(p.with_suffix("")), set()).add(p.suffix.lower())
            if not stems:
                raise ValueError(f"archive {Path(archive).name} has no .pak/.ucas/.utoc files")
            for stem, have in sorted(stems.items()):
                if (".ucas" in have or ".utoc" in have) and have != TRIO:
                    raise ValueError(f"archive {Path(archive).name}: {stem} is an incomplete .pak/.ucas/.utoc trio")
                roots.append({"name": Path(stem).name, "prefix": stem})
    return roots


def choose_root(roots, install, name):
    """Which mod inside the archive this entry installs: `install.folder` names it;
    with one root there is nothing to choose; otherwise the entry must say."""
    folder = install.get("folder")
    if folder:
        for r in roots:
            if r["name"] == folder or r["prefix"] == folder:
                return r
        raise ValueError(f"{name}: install.folder '{folder}' is not in the archive; it holds: "
                         + ", ".join(r["name"] or "(root)" for r in roots))
    if len(roots) == 1:
        return roots[0]
    raise ValueError(f"{name}: the archive holds several mods ({', '.join(r['name'] for r in roots)}); "
                     "set install.folder to the one this entry installs")


# ---- sources --------------------------------------------------------------------

def install_from_url(install, name):
    """install.url is the link an admin copies from the mod's release or file page. It fills
    in the fields the resolvers read, and the type when none is given. Explicit fields win."""
    url = str(install.get("url", "") or "").strip()
    if not url:
        return install
    parts = urllib.parse.urlsplit(url)
    host, path = parts.netloc.lower(), parts.path
    m = re.match(r"^/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/releases/download/([^/]+)/([^/]+)$", path)
    if host == "github.com" and m:
        install.setdefault("type", "github")
        install.setdefault("repo", m.group(1)); install.setdefault("tag", urllib.parse.unquote(m.group(2)))
        install.setdefault("asset", urllib.parse.unquote(m.group(3)))
        return install
    m = re.match(r"^/[^/]+/[^/]+/([A-Za-z0-9_-]+)/files/(\d+)", path)
    if host in ("www.curseforge.com", "curseforge.com") and m:
        install.setdefault("type", "curseforge")
        install.setdefault("slug", m.group(1)); install.setdefault("file_id", int(m.group(2)))
        return install
    m = re.match(r"^/subnautica2/mods/(\d+)", path)
    q = urllib.parse.parse_qs(parts.query)
    if host in ("www.nexusmods.com", "nexusmods.com") and m and q.get("file_id"):
        install.setdefault("type", "nexus")
        install.setdefault("mod_id", int(m.group(1))); install.setdefault("file_id", int(q["file_id"][0]))
        return install
    raise ValueError(f"{name}: install.url is not a link this reads; paste one shaped like {URL_SHAPES}")



def github_url(install, name):
    repo, tag, asset = install.get("repo", ""), install.get("tag", ""), install.get("asset", "")
    if not re.match(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", repo):
        raise ValueError(f"{name}: install.repo must be owner/name")
    if not tag or "/" in tag or not asset or "/" in asset:
        raise ValueError(f"{name}: install.tag and install.asset are required (one release asset)")
    base = os.environ.get("SN2_GITHUB_BASE", "https://github.com").rstrip("/")
    return (f"{base}/{repo}/releases/download/{urllib.parse.quote(tag)}/{urllib.parse.quote(asset)}",
            asset, f"https://github.com/{repo}/releases/tag/{urllib.parse.quote(tag)}")


def resolve_github(entry, install, pins, temp_dir, name):
    url, asset, page = github_url(install, name)
    key = f"github:{install['repo']}@{install['tag']}/{asset}"
    archive = temp_dir / asset
    fetch(url, archive)
    digest = sha256(archive)
    pinned = (install.get("sha256") or pins.get(key, {}).get("sha256") or "").lower()
    if pinned and pinned != digest:
        raise ValueError(f"{name}: {asset} at tag {install['tag']} changed (pinned {pinned[:12]}…, now {digest[:12]}…); "
                         "re-pin it on purpose with `moonpool mods pin`, or point at a new tag")
    pins[key] = {"sha256": digest, "size": archive.stat().st_size}
    return {"type": "github", "page": entry.get("source") or page, "url": url, "file_name": asset,
            "size": archive.stat().st_size, "hashes": [{"algorithm": "sha256", "value": digest}]}, archive


def resolve_nexus(entry, install, pins, name):
    mod_id, file_id = install.get("mod_id"), install.get("file_id")
    if not isinstance(mod_id, int) or mod_id <= 0 or not isinstance(file_id, int) or file_id <= 0:
        raise ValueError(f"{name}: install.mod_id and install.file_id must be positive numbers")
    page = f"https://www.nexusmods.com/subnautica2/mods/{mod_id}?tab=files&file_id={file_id}"
    key = f"nexus:{mod_id}/{file_id}"
    pin = pins.get(key) or {}
    file_name = install.get("file_name") or pin.get("file_name") or ""
    digest = (install.get("sha256") or pin.get("sha256") or "").lower()
    if not file_name or not re.match(r"^[0-9a-f]{64}$", digest):
        raise ValueError(f"{name}: a Nexus file needs its archive pinned once: download it from {page} and run "
                         "`moonpool mods pin \"" + name + "\" <that file>`")
    return {"type": "nexus", "page": page, "url": "", "file_name": file_name, "size": pin.get("size", 0),
            "hashes": [{"algorithm": "sha256", "value": digest}], "roots": pin.get("roots", [])}


def resolve_curseforge(entry, install, key, temp_dir, name, kind):
    project_id = install.get("project_id")
    if project_id is None and install.get("slug"):  # from a pasted file link: the project by its slug
        found = cf_get(f"/mods/search?gameId={CF_GAME_ID}&slug={urllib.parse.quote(str(install['slug']))}", key)
        if not found:
            raise ValueError(f"{name}: CurseForge has no Subnautica 2 project called {install['slug']!r}")
        project_id = install["project_id"] = int(found[0]["id"])
    if not isinstance(project_id, int) or project_id <= 0:
        raise ValueError(f"{name}: install.project_id must be a positive number")
    project = cf_get(f"/mods/{project_id}", key)
    file_id = install.get("file_id")
    if file_id is None:
        raise ValueError(f"{name}: install.file_id is required (an exact CurseForge file, never 'latest')")
    file_data = cf_get(f"/mods/{project_id}/files/{file_id}", key)
    if not file_data.get("isAvailable", True):
        raise ValueError(f"{name}: CurseForge file {file_id} is not available")
    hashes = cf_hashes(file_data)
    page = (project.get("links") or {}).get("websiteUrl", f"https://www.curseforge.com/projects/{project_id}")
    source = {"type": "curseforge", "page": page, "url": "", "file_name": file_data["fileName"],
              "size": file_data.get("fileLength", 0), "hashes": hashes,
              "allow_mod_distribution": bool(project.get("allowModDistribution", False))}
    if not source["allow_mod_distribution"]:
        return source, None
    url = file_data.get("downloadUrl")
    if not url:
        raise ValueError(f"{name}: CurseForge file {file_id} has no download URL")
    archive = temp_dir / file_data["fileName"]
    fetch_with_cf_key(url, archive, key)
    verify_hashes(archive, hashes)
    # CurseForge's own hashes are sha1 and md5; the launcher checks every hash listed and
    # names the archive by the first, so the server's sha256 of the bytes it verified leads.
    source["hashes"] = [{"algorithm": "sha256", "value": sha256(archive)}] + hashes
    source["url"] = url
    return source, archive


def resolve_local(entry, install, data, public, name):
    """The server's own mod: a folder under client-mods/<name>/ zipped and served."""
    folder = data / "client-mods" / name
    if not folder.is_dir():
        raise ValueError(f"{name}: client-mods/{name}/ is missing in the data volume")
    files = sorted(p for p in folder.rglob("*") if p.is_file())
    if not files:
        raise ValueError(f"{name}: client-mods/{name}/ is empty")
    top = folder.resolve()
    for path in files:
        if path.is_symlink() or not path.resolve().is_relative_to(top):
            raise ValueError(f"{name}: client-mods/{name}/{path.relative_to(folder).as_posix()} is a link; only plain files are published")
    out_dir = public / "files"
    out_dir.mkdir(parents=True, exist_ok=True)
    zip_name = re.sub(r"[^A-Za-z0-9_.-]+", "-", name) + ".zip"
    archive = out_dir / zip_name
    put(archive, zip_bytes((path.relative_to(folder).as_posix(), path.read_bytes()) for path in files))
    return {"type": "local", "page": entry.get("source") or "", "url": f"files/{zip_name}", "file_name": zip_name,
            "size": archive.stat().st_size, "hashes": [{"algorithm": "sha256", "value": sha256(archive)}]}, archive


# ---- the manifest -----------------------------------------------------------------

def manifest_mod(entry, args, data, public, pins, temp_dir):
    name = str(entry.get("name", "")).strip()
    if not SAFE_NAME.match(name):
        raise ValueError(f"unsafe mod name: {name!r}")
    install = entry.get("install")
    if not isinstance(install, dict):
        return None
    install_from_url(install, name)
    kind = str(install.get("kind", "ue4ss")).lower()
    if kind not in ("ue4ss", "pak"):
        raise ValueError(f"{name}: install.kind must be ue4ss or pak")
    side = str(entry.get("side", "client")).lower()
    if side != "client":
        raise ValueError(f"{name}: side: {side} is not supported; this list is what players install. "
                         "A mod the host runs goes in ue4ss-local/Mods/<name>/ (docs/operating.md)")
    source_type = str(install.get("type", "")).lower()
    archive = None
    if source_type == "github":
        source, archive = resolve_github(entry, install, pins, temp_dir, name)
    elif source_type == "nexus":
        source = resolve_nexus(entry, install, pins, name)
    elif source_type == "curseforge":
        key = os.environ.get("CURSEFORGE_API_KEY", "")
        if not key:
            raise ValueError(f"{name}: CURSEFORGE_API_KEY is not set")
        source, archive = resolve_curseforge(entry, install, key, temp_dir, name, kind)
    elif source_type == "local":
        source, archive = resolve_local(entry, install, data, public, name)
    else:
        raise ValueError(f"{name}: install.type must be github, nexus, curseforge or local")
    if archive is not None:
        roots = archive_roots(archive, kind)
    else:
        roots = source.pop("roots", []) or []
        if not roots:
            raise ValueError(f"{name}: the archive has not been inspected; pin it with `moonpool mods pin`")
    root = choose_root(roots, install, name)
    folder = install.get("folder") or root["name"] or re.sub(r"[^A-Za-z0-9_.-]+", "", name)
    if not SAFE_FOLDER.match(folder):
        raise ValueError(f"{name}: the install folder '{folder}' has characters the game folder cannot take")
    tier = str(entry.get("tier", "optional")).lower()
    return {"name": name, "version": str(entry.get("version", "")), "summary": str(entry.get("summary", "")),
            "required": tier == "mandatory", "kind": kind, "folder": folder, "prefix": root["prefix"],
            "native": bool(root.get("native")), "source": source}


def checked_public_url(url):
    """The address decides whose mods a player is offered: plain characters only, and plain
    http only inside a private network. The launcher applies the same rule."""
    host = urllib.parse.urlsplit(url).hostname or ""
    if not re.fullmatch(r"https?://[A-Za-z0-9.:\[\]-]+(/[A-Za-z0-9._~/-]*)?", url):
        raise ValueError(f"SN2_PUBLIC_URL is not a plain http(s) address: {url!r}")
    try:
        private = ipaddress.ip_address(host).is_private
    except ValueError:
        private = host == "localhost"
    if url.lower().startswith("http://") and not private:
        raise ValueError(f"SN2_PUBLIC_URL must be https:// outside a private network, not {url}")
    return url


def ue4ss_block(args, mods, public):
    """The loader players get: the host's own pinned build. Served from the host's
    verified copy (the install cache) so a player never depends on GitHub, which
    refuses a private repository's release assets; the mirror URL only when the
    cache holds no verified copy."""
    if not any(m["kind"] == "ue4ss" for m in mods):
        return None
    channel = os.environ.get("UE4SS_CHANNEL_IN_FORCE", "pinned")
    asset, digest = UE4SS_PINS.get(channel, UE4SS_PINS["pinned"])
    asset = os.environ.get("UE4SS_ASSET", asset)
    digest = os.environ.get("UE4SS_RELEASE_SHA256", digest).lower()
    allowed = [v.strip().lower() for v in os.environ.get("CLIENT_BUILDS", "").split(",") if v.strip()]
    exe_sha = (args.exe_sha256 or "").strip().lower()
    if exe_sha and exe_sha not in allowed:
        allowed.append(exe_sha)
    for value in allowed:
        if not re.match(r"^[0-9a-f]{64}$", value):
            raise ValueError("CLIENT_BUILDS must be comma-separated sha256 values")
    url = f"{UE4SS_MIRROR}/{asset}"
    cached = Path(args.ue4ss_cache) / asset if args.ue4ss_cache else None
    if cached and cached.is_file() and sha256(cached) == digest:
        files = public / "files"
        files.mkdir(parents=True, exist_ok=True)
        served = files / asset
        if not served.is_file() or sha256(served) != digest:
            shutil.copyfile(cached, served)
        url = f"files/{asset}"
    return {"channel": channel, "url": url, "asset": asset, "sha256": digest, "allowed_builds": allowed}


def signing_key(data):
    key_dir = data / "mod-signing"
    private_key, public_key = key_dir / "private.pem", key_dir / "public.pem"
    key_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not private_key.is_file():
        subprocess.run(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:3072",
                        "-out", str(private_key)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        private_key.chmod(0o600)
        subprocess.run(["openssl", "pkey", "-in", str(private_key), "-pubout", "-out", str(public_key)], check=True)
    return private_key, public_key


def write_config(args, public, public_key, base, session):
    key = serialization.load_pem_public_key(public_key.read_bytes()).public_numbers()
    modulus = key.n.to_bytes((key.n.bit_length() + 7) // 8, "big")
    exponent = key.e.to_bytes((key.e.bit_length() + 7) // 8, "big")
    config = {"manifest_url": f"{base}/mods.json", "signature_url": f"{base}/mods.json.sig",
              "public_key": {"modulus": base64.b64encode(modulus).decode(), "exponent": base64.b64encode(exponent).decode()},
              "server_name": args.server_name, "server_id": hashlib.sha256(public_key.read_bytes()).hexdigest()[:16]}
    if session.get("host_steamid"):
        config["host_steamid"] = str(session["host_steamid"])
    put(public / "moonpool.json", (json.dumps(config, indent=2) + "\n").encode())
    # Servers supply data, never code: drop the launcher an older image served.
    for old in ("sn2-join.ps1", "sn2-join.cmd", "sn2-join.json", "sn2-launcher.zip"):
        (public / old).unlink(missing_ok=True)
    return config


def previous_mods(public):
    try:
        data = json.loads((public / "mods.json").read_text())
    except (OSError, ValueError):
        return {}
    return {m["name"]: m for m in data.get("mods", []) if isinstance(m, dict) and m.get("name")}


def publish(args):
    data = Path(args.data_dir)
    public = data / "public"
    public.mkdir(parents=True, exist_ok=True)
    pins_path = data / "mods-pins.json"
    pins = json.loads(pins_path.read_text()) if pins_path.is_file() else {}
    plugins = read_plugins(Path(args.plugins))
    mods, skipped, linked = [], [], []
    previous = previous_mods(public)
    with tempfile.TemporaryDirectory() as tmp:
        for entry in plugins:
            if not isinstance(entry, dict) or not entry.get("name"):
                raise ValueError("each plugins.yaml entry needs a name")
            if entry.get("enabled", True) is False:
                continue
            config = hashlib.sha256(json.dumps(entry, sort_keys=True, default=str).encode()).hexdigest()
            last = previous.get(str(entry.get("name", "")).strip())
            is_local = isinstance(entry.get("install"), dict) and str(entry["install"].get("type", "")).lower() == "local"
            try:
                if args.cached and last and last.get("config") == config and not is_local:
                    mod = last
                else:
                    mod = manifest_mod(entry, args, data, public, pins, Path(tmp))
                    if mod is not None:
                        mod["config"] = config
            except (ValueError, OSError, zipfile.BadZipFile) as exc:
                reason = str(exc)
                if not last:
                    skipped.append({"name": str(entry.get("name")), "reason": reason})
                    continue
                skipped.append({"name": str(entry.get("name")), "reason": reason + "; players keep the last published version"})
                mod = last
            if mod is None:
                if str(entry.get("side", "client")).lower() != "host":
                    linked.append(str(entry["name"]))
                continue
            if any(m["folder"].lower() == mod["folder"].lower() for m in mods):
                skipped.append({"name": mod["name"], "reason": f"another entry already installs the folder {mod['folder']}"})
                continue
            mods.append(mod)
    pins_path.write_text(json.dumps(pins, indent=2, sort_keys=True) + "\n")
    if not mods and skipped:
        return {"enabled": False, "mods": 0, "linked": linked, "skipped": skipped}
    if not mods:
        # Players who ran the launcher keep asking this address: once anything was
        # published, an empty signed list is what tells them to clear their set and join.
        if not (public / "mods.json").is_file():
            return {"enabled": False, "mods": 0, "linked": linked, "skipped": skipped}
    base = args.public_url.rstrip("/")
    if not base:
        raise ValueError("no public address yet: set SN2_PUBLIC_URL, or wait for the tunnel; what was published stays")
    checked_public_url(base)
    private_key, public_key = signing_key(data)
    session_path = data / "run" / "mod-session.json"
    session = json.loads(session_path.read_text()) if session_path.is_file() else {}
    if str(session.get("lobby_id", "")).lower().startswith("0x"):
        session["lobby_id"] = str(int(session["lobby_id"], 16))
    config = write_config(args, public, public_key, base, session)
    appmanifest = Path(args.appmanifest)
    manifest = {
        "schema": SCHEMA, "app_id": APP_ID,
        "game": {"branch": acf_value(appmanifest, "BetaKey") or args.branch, "buildid": acf_value(appmanifest, "buildid")},
        "server": {"id": config["server_id"], "name": args.server_name},
        "mods": mods,
    }
    loader = ue4ss_block(args, mods, public)
    if loader:
        manifest["ue4ss"] = loader
    if session.get("lobby_id") and session.get("host_steamid"):
        manifest["session"] = {"lobby_id": str(session["lobby_id"]), "host_steamid": str(session["host_steamid"])}
    manifest_path = public / "mods.json"
    temp = public / ".mods.json.tmp"
    temp_sig = public / ".mods.json.sig.tmp"
    temp.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    # Signed before either goes live, so a failed signing leaves the last good pair serving.
    subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(private_key), "-out",
                    str(temp_sig), str(temp)], check=True)
    os.replace(temp_sig, public / "mods.json.sig")
    os.replace(temp, manifest_path)
    # A file off the list stops being served: only what the signed list names stays public.
    listed = {Path(u).name for u in [m["source"]["url"] for m in mods] + [(loader or {}).get("url", "")]}
    for served in (public / "files").glob("*"):
        if served.is_file() and served.name not in listed:
            served.unlink()
    return {"enabled": bool(mods), "mods": len(mods), "required": sum(1 for m in mods if m["required"]),
            "ue4ss": bool(loader), "linked": linked, "skipped": skipped,
            "manifest": str(manifest_path),
            "names": [m["name"] for m in mods]}


def pin(args):
    """Record a hand-downloaded archive (Nexus, or a GitHub asset re-pinned on purpose)."""
    path = Path(args.plugins)
    plugins = read_plugins(path)
    entry = next((p for p in plugins if isinstance(p, dict) and str(p.get("name")) == args.name), None)
    if entry is None:
        raise ValueError(f"no entry named {args.name!r} in plugins.yaml")
    install = entry.get("install")
    if not isinstance(install, dict):
        raise ValueError(f"{args.name}: has no install: block to pin")
    install_from_url(install, args.name)  # a pasted link gains its fields here, and the pin beside them
    archive = Path(args.archive)
    if not archive.is_file():
        raise ValueError(f"no such file: {archive}")
    kind = str(install.get("kind", "ue4ss")).lower()
    roots = archive_roots(archive, kind)
    digest = sha256(archive)
    data = Path(args.data_dir)
    pins_path = data / "mods-pins.json"
    pins = json.loads(pins_path.read_text()) if pins_path.is_file() else {}
    source_type = str(install.get("type", "")).lower()
    if source_type == "nexus":
        key = f"nexus:{install.get('mod_id')}/{install.get('file_id')}"
    elif source_type == "github":
        key = f"github:{install.get('repo')}@{install.get('tag')}/{install.get('asset')}"
    else:
        raise ValueError(f"{args.name}: only nexus and github entries are pinned by hand")
    pins[key] = {"sha256": digest, "size": archive.stat().st_size, "file_name": archive.name, "roots": roots}
    pins_path.write_text(json.dumps(pins, indent=2, sort_keys=True) + "\n")
    install["sha256"] = digest
    if source_type == "nexus":
        install["file_name"] = archive.name
    write_plugins(path, plugins)
    return {"pinned": args.name, "sha256": digest, "file_name": archive.name,
            "mods_in_archive": [r["name"] or "(root)" for r in roots]}


def set_enabled(args, value):
    path = Path(args.plugins)
    plugins = read_plugins(path)
    entry = next((p for p in plugins if isinstance(p, dict) and str(p.get("name")) == args.name), None)
    if entry is None:
        raise ValueError(f"no entry named {args.name!r} in plugins.yaml")
    entry["enabled"] = value
    write_plugins(path, plugins)
    return {"name": args.name, "enabled": value}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", required=True)
    parser.add_argument("--plugins", required=True)
    parser.add_argument("--appmanifest", default="")
    parser.add_argument("--exe-sha256", default="")
    parser.add_argument("--ue4ss-cache", default="")
    parser.add_argument("--cached", action="store_true")
    parser.add_argument("--branch", default="public")
    parser.add_argument("--public-url", default="")
    parser.add_argument("--server-name", default="SN2 Host")
    sub = parser.add_subparsers(dest="command")
    sub.add_parser("publish")
    p_pin = sub.add_parser("pin"); p_pin.add_argument("name"); p_pin.add_argument("archive")
    p_on = sub.add_parser("enable"); p_on.add_argument("name")
    p_off = sub.add_parser("disable"); p_off.add_argument("name")
    args = parser.parse_args()
    try:
        if args.command == "pin":
            result = pin(args)
        elif args.command == "enable":
            result = set_enabled(args, True)
        elif args.command == "disable":
            result = set_enabled(args, False)
        else:
            result = publish(args)
        print(json.dumps(result, separators=(",", ":")))
    except (OSError, ValueError, subprocess.CalledProcessError, json.JSONDecodeError, zipfile.BadZipFile, yaml.YAMLError) as exc:
        print(json.dumps({"enabled": False, "error": str(exc)}, separators=(",", ":")))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
