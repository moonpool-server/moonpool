#!/usr/bin/env python3
# Community tools (node-steamcommunity, steampy) log in
# with a password; this reuses the session the signed-in Windows Steam client
# already holds under Wine, so nothing new is ever typed or stored.
"""Accept pending incoming Steam friend requests for the host account.

The Steam client's browser keeps steamcommunity.com cookies in a Chromium
cookie store, AES-256-GCM encrypted with a key that "Local State" protects
with DPAPI. Under Wine, DPAPI is Wine's own crypt32 (dlls/crypt32/
protectdata.c): 3DES-CBC, zero IV, key = CryptDeriveKey of
SHA1(user name + NUL + a fixed secret + salt).

The calls are the ones node-steamcommunity makes
(components/users.js acceptFriendRequest/removeFriend, index.js getFriendsList):
GET /textfilter/ajaxgetfriendslist, then for each relationship 2
(request recipient) POST /actions/AddFriendAjax accept_invite=1. Removing a
friend posts sessionID and steamid to /actions/RemoveFriendAjax.

`--lobby STEAMID64` reads the same session for the host's current lobby id instead
(own_lobby), for builds whose game log does not carry it whole.
"""
from __future__ import annotations

import base64
import getpass
import hashlib
import json
import os
import re
import shutil
import sqlite3
import struct
import sys
import tempfile
import urllib.parse
import urllib.request

WINE_SECRET = b"I'm hunting wabbits"  # crypt32_protectdata_secret, protectdata.c
REQUEST_RECIPIENT = 2  # EFriendRelationship.RequestRecipient
BASE = os.environ.get("STEAMCOMMUNITY_BASE", "https://steamcommunity.com")


def policy_ids(path: str) -> set[str]:
    """First tab-separated field of each non-comment policy line."""
    try:
        with open(path, encoding="utf-8") as f:
            return {line.rstrip("\r\n").split("\t", 1)[0].strip() for line in f
                    if line.strip() and not line.lstrip().startswith("#")}
    except FileNotFoundError:
        return set()


def _blob(b: bytes, o: int) -> tuple[bytes, int]:
    n = struct.unpack_from("<I", b, o)[0]
    return b[o + 4:o + 4 + n], o + 4 + n


def _derive(user: str, salt: bytes) -> bytes:
    h = hashlib.sha1(user.encode() + b"\0" + WINE_SECRET + salt).digest()
    pad = lambda c: bytes(c ^ (h[i] if i < 20 else 0) for i in range(64))  # noqa: E731
    return (hashlib.sha1(pad(0x36)).digest() + hashlib.sha1(pad(0x5C)).digest())[:24]


def wine_unprotect(b: bytes, user: str) -> bytes:
    """CryptUnprotectData as Wine implements it (no optional entropy)."""
    from cryptography.hazmat.primitives.ciphers import Cipher, modes
    try:  # cryptography >= 43 moved 3DES here; the images ship older releases
        from cryptography.hazmat.decrepit.ciphers.algorithms import TripleDES
    except ImportError:
        from cryptography.hazmat.primitives.ciphers.algorithms import TripleDES
    o = 4 + 16 + 4 + 16 + 4            # count0, info0[16], count1, info1[16], null0
    _, o = _blob(b, o)                  # description
    o += 8                              # cipher alg, key length
    _, o = _blob(b, o)                  # data0
    o += 4 + 8                          # null1, hash alg, hash length
    salt, o = _blob(b, o)
    cipher, o = _blob(b, o)
    d = Cipher(TripleDES(_derive(user, salt)), modes.CBC(bytes(8))).decryptor()
    p = d.update(cipher) + d.finalize()
    if not p or not 1 <= p[-1] <= 8 or p[-p[-1]:] != bytes([p[-1]]) * p[-1]:
        raise ValueError("DPAPI blob did not decrypt (wrong Wine user name?)")
    return p[:-p[-1]]


def community_cookies(htmlcache: str, user: str) -> dict[str, str]:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    with open(os.path.join(htmlcache, "Local State"), encoding="utf-8") as f:
        ek = base64.b64decode(json.load(f)["os_crypt"]["encrypted_key"])
    if ek[:5] != b"DPAPI":
        raise ValueError("Local State key is not DPAPI-protected")
    key = wine_unprotect(ek[5:], user)
    if len(key) != 32:
        raise ValueError("Local State key is not an AES-256 key")
    fd, tmp = tempfile.mkstemp()
    os.close(fd)
    try:  # the client holds the database open; read a copy
        shutil.copy(os.path.join(htmlcache, "Default", "Network", "Cookies"), tmp)
        con = sqlite3.connect(tmp)
        rows = con.execute("select name, encrypted_value from cookies where host_key = 'steamcommunity.com'").fetchall()
        con.close()
    finally:
        os.remove(tmp)
    out = {}
    for name, ev in rows:
        if ev[:3] in (b"v10", b"v11"):
            out[name] = AESGCM(key).decrypt(ev[3:15], ev[15:], None).decode()
    return out


def _req(path: str, cookies: dict[str, str], form: dict[str, str] | None = None) -> bytes:
    data = urllib.parse.urlencode(form).encode() if form is not None else None
    r = urllib.request.Request(BASE + path, data=data, headers={
        "Cookie": "; ".join(f"{k}={v}" for k, v in cookies.items()),
        "Referer": BASE + "/", "User-Agent": "sn2-host friend-accept"})
    with urllib.request.urlopen(r, timeout=20) as resp:
        return resp.read()


def name_of(steamid: str, cookies: dict[str, str]) -> str:
    try:
        m = re.search(rb"<steamID><!\[CDATA\[(.*?)\]\]>", _req(f"/profiles/{steamid}?xml=1", cookies))
        return m.group(1).decode("utf-8", "replace") if m else steamid
    except OSError:
        return steamid


def remove_friend(cookies: dict[str, str], steamid: str) -> bool:
    r = json.loads(_req("/actions/RemoveFriendAjax", cookies,
                        {"sessionID": cookies["sessionid"], "steamid": steamid}) or b"{}")
    return r.get("success") in (1, True)


def accept_pending(cookies: dict[str, str], dry_run: bool = False,
                   banned: set[str] | None = None, allowed: set[str] | None = None,
                   allowlist_only: bool = False) -> list[str]:
    if "sessionid" not in cookies or "steamLoginSecure" not in cookies:
        raise ValueError("the Steam client has no steamcommunity.com web session yet")
    body = json.loads(_req("/textfilter/ajaxgetfriendslist", cookies))
    if body.get("success") != 1:
        raise ValueError(f"friends list refused: success={body.get('success')}")
    lines = []
    banned, allowed = banned or set(), allowed or set()
    for f in body.get("friendslist", {}).get("friends", []):
        sid = str(f["ulfriendid"])
        if sid in banned:
            if dry_run:
                lines.append(f"friend blocked (dry run): {sid}")
            elif remove_friend(cookies, sid):
                lines.append(f"friend removed: {sid}")
            else:
                lines.append(f"friend remove failed: {sid}")
            continue
        if f.get("efriendrelationship") != REQUEST_RECIPIENT:
            continue
        if allowlist_only and sid not in allowed:
            lines.append(f"friend request ignored (not allowed): {sid}")
            continue
        name = name_of(sid, cookies)
        if dry_run:
            lines.append(f"friend pending (dry run): {name} ({sid})")
            continue
        r = json.loads(_req("/actions/AddFriendAjax", cookies,
                            {"sessionID": cookies["sessionid"], "steamid": sid, "accept_invite": "1"}) or b"{}")
        if r.get("success") in (1, True):
            lines.append(f"friend accepted: {name} ({sid})")
        else:
            lines.append(f"friend accept failed: {name} ({sid}): {json.dumps(r)[:120]}")
    return lines


API = os.environ.get("STEAMAPI_BASE", "https://api.steampowered.com")


def own_lobby(cookies: dict[str, str], steamid: str) -> str:
    """The account's current Steam lobby id (decimal), or "" when it is in none.

    What Steam's own web friends list reads: IPlayerService/GetPlayerLinkDetails, with the
    web API token the community session hands out (pointssummary/ajaxgetasyncconfig).
    ISteamUser/GetPlayerSummaries refuses that token (HTTP 400). Used on the public branch,
    whose game log masks the id (Lobby[0x18...B694]).
    """
    cfg = json.loads(_req("/pointssummary/ajaxgetasyncconfig", cookies) or b"{}")
    tok = (cfg.get("data") or {}).get("webapi_token")
    if not tok:
        raise ValueError("the community session handed out no web API token")
    q = urllib.parse.urlencode({"access_token": tok, "steamids[0]": steamid})
    with urllib.request.urlopen(f"{API}/IPlayerService/GetPlayerLinkDetails/v1/?{q}", timeout=20) as r:
        acc = (json.load(r).get("response", {}).get("accounts") or [{}])[0]
    lobby = str((acc.get("private_data") or {}).get("lobby_steam_id") or "")
    return lobby if lobby.isdigit() and lobby != "0" else ""


def main(argv: list[str]) -> int:
    dry = "--dry-run" in argv
    htmlcache = os.environ.get("STEAM_HTMLCACHE") or os.path.join(
        os.environ.get("STEAM_SESSION_DIR")
        or os.path.join(os.environ.get("DATA_DIR", "/data"), "steam-session", "local-appdata"), "htmlcache")
    user = os.environ.get("WINE_USER") or getpass.getuser()
    if "--lobby" in argv:  # --lobby STEAMID64: print the lobby id (or nothing), never a secret
        i = argv.index("--lobby")
        sid = argv[i + 1] if i + 1 < len(argv) else ""
        if not re.fullmatch(r"7656\d{13}", sid):
            print("usage: friend-accept.py --lobby STEAMID64", file=sys.stderr)
            return 2
        try:
            lobby = own_lobby(community_cookies(htmlcache, user), sid)
        except (OSError, ValueError, KeyError) as e:
            print(f"lobby lookup skipped: {type(e).__name__}: {str(e)[:160]}", file=sys.stderr)
            return 1
        if lobby:
            print(lobby)
        return 0
    control = (os.environ.get("SN2_CONTROL_DIR") or os.environ.get("CONTROL_DIR")
               or os.path.join(os.environ.get("DATA_DIR", "/data"), "control"))
    try:
        cookies = community_cookies(htmlcache, user)
        if "--remove" in argv:
            i = argv.index("--remove")
            sid = argv[i + 1] if i + 1 < len(argv) else ""
            if not re.fullmatch(r"7656\d{13}", sid):
                print("usage: friend-accept.py --remove STEAMID64", file=sys.stderr)
                return 2
            if not remove_friend(cookies, sid):
                raise ValueError("Steam refused the friend removal")
            print(f"friend removed: {sid}")
            return 0
        for line in accept_pending(cookies, dry, policy_ids(os.path.join(control, "bans.txt")),
                                   policy_ids(os.path.join(control, "allowlist.txt")),
                                   os.environ.get("ALLOWLIST_ONLY", "true").strip().lower() != "false"):
            print(line)
    except (OSError, ValueError, KeyError) as e:  # never print a cookie value
        print(f"friend accept skipped: {type(e).__name__}: {str(e)[:160]}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
