#!/usr/bin/env python3
"""Tests for scripts/friend-accept.py without Steam or the network.

A DPAPI blob is built the way Wine's crypt32 serializes one (protectdata.c),
a Chromium cookie store is built around it, and steamcommunity.com is a local
HTTP server that records what the script sends.
"""
from __future__ import annotations

import base64
import http.server
import importlib.util
import json
import os
import sqlite3
import struct
import sys
import tempfile
import threading
import urllib.parse

sys.dont_write_bytecode = True
try:
    from cryptography.hazmat.primitives.ciphers import Cipher, modes
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except ImportError:  # the pre-commit hook supplies it; a bare python may not
    print("skip: the cryptography package is not installed; run:\n"
          "  uv run --no-project --with cryptography python tests/test_friend_accept.py")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("fa", os.path.join(HERE, "..", "scripts", "friend-accept.py"))
fa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fa)


def blob(b: bytes) -> bytes:
    return struct.pack("<I", len(b)) + b


def wine_protect(plain: bytes, user: str, salt: bytes = b"S" * 16) -> bytes:
    pad = 8 - len(plain) % 8
    p = plain + bytes([pad]) * pad
    try:
        from cryptography.hazmat.decrepit.ciphers.algorithms import TripleDES
    except ImportError:
        from cryptography.hazmat.primitives.ciphers.algorithms import TripleDES
    e = Cipher(TripleDES(fa._derive(user, salt)), modes.CBC(bytes(8))).encryptor()
    c = e.update(p) + e.finalize()
    return (struct.pack("<I", 1) + bytes(16) + struct.pack("<I", 1) + bytes(16) + struct.pack("<I", 0)
            + blob("d\0".encode("utf-16-le")) + struct.pack("<II", 0x6603, 168) + blob(b"")
            + struct.pack("<III", 0, 0x8004, 160) + blob(salt) + blob(c) + blob(b"h" * 20))


def make_store(root: str, user: str, cookies: dict[str, str]) -> None:
    key = os.urandom(32)
    with open(os.path.join(root, "Local State"), "w") as f:
        json.dump({"os_crypt": {"encrypted_key": base64.b64encode(b"DPAPI" + wine_protect(key, user)).decode()}}, f)
    os.makedirs(os.path.join(root, "Default", "Network"))
    con = sqlite3.connect(os.path.join(root, "Default", "Network", "Cookies"))
    con.execute("create table cookies (host_key text, name text, encrypted_value blob)")
    for n, v in cookies.items():
        nonce = os.urandom(12)
        con.execute("insert into cookies values (?,?,?)",
                    ("steamcommunity.com", n, b"v10" + nonce + AESGCM(key).encrypt(nonce, v.encode(), None)))
    con.execute("insert into cookies values ('store.steampowered.com','sessionid', x'00')")
    con.commit()
    con.close()


class Fake(http.server.BaseHTTPRequestHandler):
    friends: list = []
    posts: list = []
    post_paths: list = []
    cookies: list = []

    def log_message(self, *a):
        pass

    def _send(self, body: bytes, ctype="application/json"):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.end_headers()
        self.wfile.write(body)

    lobby: str | None = "109775243279513236"
    api_queries: list = []

    get_paths: list = []

    def do_GET(self):
        Fake.cookies.append(self.headers.get("Cookie", ""))
        Fake.get_paths.append(self.path)
        if self.path.startswith("/pointssummary/ajaxgetasyncconfig"):
            self._send(json.dumps({"success": 1, "data": {"webapi_token": "TOKEN"}}).encode())
        elif self.path.startswith("/IPlayerService/GetPlayerLinkDetails/v1/"):
            Fake.api_queries.append(dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(self.path).query)))
            priv = {"game_id": "1962700", "persona_state": 3}
            if Fake.lobby is not None:
                priv["lobby_steam_id"] = Fake.lobby
            self._send(json.dumps({"response": {"accounts": [{"private_data": priv}]}}).encode())
        elif self.path.startswith("/textfilter/ajaxgetfriendslist"):
            self._send(json.dumps({"success": 1, "friendslist": {"friends": Fake.friends}}).encode())
        else:
            sid = self.path.split("/")[2].split("?")[0]
            self._send(f"<profile><steamID><![CDATA[Player {sid[-2:]}]]></steamID></profile>".encode(), "text/xml")

    def do_POST(self):
        n = int(self.headers["Content-Length"])
        Fake.post_paths.append(self.path)
        Fake.posts.append(dict(urllib.parse.parse_qsl(self.rfile.read(n).decode())))
        self._send(b'{"success":1}')


FAILS = 0


def check(cond: bool, what: str) -> None:
    global FAILS
    print(("ok " if cond else "not ok ") + what)
    FAILS += 0 if cond else 1


def main() -> int:
    # 1. Wine DPAPI round trip, and the wrong user name fails plainly.
    secret = b"0123456789abcdef0123456789abcdef"
    b = wine_protect(secret, "steam")
    check(fa.wine_unprotect(b, "steam") == secret, "Wine DPAPI blob decrypts with the right user")
    try:
        fa.wine_unprotect(b, "root")
        check(False, "wrong user is refused")
    except ValueError:
        check(True, "wrong user is refused")

    srv = http.server.HTTPServer(("127.0.0.1", 0), Fake)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    fa.BASE = f"http://127.0.0.1:{srv.server_port}"
    with tempfile.TemporaryDirectory() as root:
        make_store(root, "steam", {"sessionid": "SESS", "steamLoginSecure": "LOGIN"})
        ck = fa.community_cookies(root, "steam")
        check(ck == {"sessionid": "SESS", "steamLoginSecure": "LOGIN"}, "only steamcommunity.com cookies are read")

        # 2. Only incoming requests (relationship 2) are accepted.
        Fake.friends = [{"ulfriendid": "76561198000000011", "efriendrelationship": 3},
                        {"ulfriendid": "76561198000000022", "efriendrelationship": 2},
                        {"ulfriendid": "76561198000000033", "efriendrelationship": 4}]
        lines = fa.accept_pending(ck, dry_run=True)
        check(lines == ["friend pending (dry run): Player 22 (76561198000000022)"], "dry run lists, sends nothing")
        check(Fake.posts == [], "dry run posted nothing")
        lines = fa.accept_pending(ck)
        check(lines == ["friend accepted: Player 22 (76561198000000022)"], "one line per accepted friend")
        check(Fake.posts == [{"sessionID": "SESS", "steamid": "76561198000000022", "accept_invite": "1"}],
              "AddFriendAjax gets sessionID, steamid, accept_invite=1")
        check(Fake.post_paths == ["/actions/AddFriendAjax"], "accept uses AddFriendAjax")
        check(all("steamLoginSecure=LOGIN" in c for c in Fake.cookies), "the client's own session is sent")

        # Banned IDs are removed (including an existing friend), never accepted.
        Fake.posts, Fake.post_paths = [], []
        banned = "76561198000000022"
        lines = fa.accept_pending(ck, banned={banned})
        check(lines == [f"friend removed: {banned}"], "a banned pending request is removed")
        check(Fake.post_paths == ["/actions/RemoveFriendAjax"] and
              Fake.posts == [{"sessionID": "SESS", "steamid": banned}],
              "RemoveFriendAjax gets sessionID and steamid")
        Fake.friends = [{"ulfriendid": banned, "efriendrelationship": 3}]
        Fake.posts, Fake.post_paths = [], []
        check(fa.accept_pending(ck, banned={banned}) == [f"friend removed: {banned}"],
              "an already accepted banned friend is removed on reconciliation")

        # Allowlist-only ignores an unlisted request and accepts a listed one.
        other = "76561198000000044"
        Fake.friends = [{"ulfriendid": banned, "efriendrelationship": 2},
                        {"ulfriendid": other, "efriendrelationship": 2}]
        Fake.posts, Fake.post_paths = [], []
        lines = fa.accept_pending(ck, allowed={other}, allowlist_only=True)
        check(lines == [f"friend request ignored (not allowed): {banned}",
                        f"friend accepted: Player 44 ({other})"],
              "allowlist-only accepts only listed IDs")
        check(Fake.posts == [{"sessionID": "SESS", "steamid": other, "accept_invite": "1"}],
              "only the allowed ID is posted to AddFriendAjax")

        policy = os.path.join(root, "policy.txt")
        with open(policy, "w", encoding="utf-8") as f:
            f.write("# note\n76561198000000044\ttrusted\nAlice\treason here\n")
        check(fa.policy_ids(policy) == {other, "Alice"}, "policy files read identifiers and ignore reasons")

        # 3. No web session yet: plain refusal, no request made.
        Fake.posts = []
        try:
            fa.accept_pending({"sessionid": "x"})
            check(False, "missing login cookie is refused")
        except ValueError as e:
            check("no steamcommunity.com web session" in str(e), "missing login cookie is refused")

        # 4. main() never prints a cookie value, even on failure.
        import contextlib
        import io
        os.environ["STEAM_HTMLCACHE"] = root
        os.environ["WINE_USER"] = "root"  # wrong user: decryption fails
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = fa.main([])
        check(rc == 1 and "friend accept skipped" in out.getvalue(), "a failure is one 'skipped' line, rc 1")
        check("SESS" not in out.getvalue() and "LOGIN" not in out.getvalue(), "no cookie value is printed")

        # 5. --lobby: the host's own lobby id from GetPlayerLinkDetails, through the session's token.
        fa.API = fa.BASE
        os.environ["WINE_USER"] = "steam"
        host = "76561198000000001"
        check(fa.own_lobby(ck, host) == "109775243279513236", "own_lobby reads lobby_steam_id")
        check(Fake.api_queries[-1] == {"access_token": "TOKEN", "steamids[0]": host},
              "GetPlayerLinkDetails gets the session's token and the host's id")
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = fa.main(["--lobby", host])
        check(rc == 0 and out.getvalue() == "109775243279513236\n", "--lobby prints the id alone")
        check("TOKEN" not in out.getvalue() + err.getvalue(), "the token is never printed")
        Fake.lobby = None
        check(fa.own_lobby(ck, host) == "", "in no lobby: empty")
        Fake.lobby = "0"
        check(fa.own_lobby(ck, host) == "", "lobby 0: empty")
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = fa.main(["--lobby", "1234"])
        check(rc == 2 and out.getvalue() == "", "--lobby refuses an id that is not a steamid64")
        os.environ["WINE_USER"] = "root"
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = fa.main(["--lobby", host])
        check(rc == 1 and out.getvalue() == "" and "lobby lookup skipped" in err.getvalue(),
              "a failed lookup prints nothing on stdout and says why on stderr")

        # 6. With ALLOWLIST_ONLY unset, nobody off the list gets in, and a ban beats the list.
        listed, stranger, listed_and_banned = "76561198000000055", "76561198000000066", "76561198000000077"
        os.environ["WINE_USER"] = "steam"
        os.environ["SN2_CONTROL_DIR"] = root
        os.environ.pop("ALLOWLIST_ONLY", None)
        with open(os.path.join(root, "allowlist.txt"), "w", encoding="utf-8") as f:
            f.write(f"{listed}\n{listed_and_banned}\n")
        with open(os.path.join(root, "bans.txt"), "w", encoding="utf-8") as f:
            f.write(f"{listed_and_banned}\n")
        Fake.friends = [{"ulfriendid": s, "efriendrelationship": 2} for s in (listed, stranger, listed_and_banned)]
        Fake.posts, Fake.post_paths = [], []
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = fa.main([])
        check(rc == 0 and Fake.post_paths == ["/actions/AddFriendAjax", "/actions/RemoveFriendAjax"]
              and [p["steamid"] for p in Fake.posts] == [listed, listed_and_banned],
              "unset ALLOWLIST_ONLY accepts only the listed ID and removes the banned one")

        # 7. --pending only reads: the requests the rules would let in, by name, and no POST at all.
        Fake.friends += [{"ulfriendid": listed_and_banned, "efriendrelationship": 3}]
        Fake.posts, Fake.post_paths, Fake.get_paths = [], [], []
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = fa.main(["--pending"])
        check(rc == 0 and json.loads(out.getvalue()) == {"count": 1, "names": ["Player 55"]},
              "--pending counts only the requests the accept rules would let in")
        check(Fake.post_paths == [] and Fake.posts == [], "--pending posts nothing, not even for a banned friend")
        check("7656" not in out.getvalue(), "--pending prints no Steam id")
        os.environ["ALLOWLIST_ONLY"], os.environ["SHOW_PLAYER_NAMES"] = "false", "false"
        Fake.get_paths = []
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = fa.main(["--pending"])
        check(rc == 0 and json.loads(out.getvalue()) == {"count": 2, "names": []}
              and not any(p.startswith("/profiles/") for p in Fake.get_paths),
              "SHOW_PLAYER_NAMES=false: a count, and no profile is looked up")
        try:
            fa._req("/actions/AddFriendAjax", ck, {"steamid": stranger})
            check(False, "read-only mode refuses a POST")
        except ValueError:
            check(Fake.post_paths == [], "read-only mode refuses a POST")
        for k in ("ALLOWLIST_ONLY", "SHOW_PLAYER_NAMES"):
            os.environ.pop(k)
    srv.shutdown()
    print("all passed" if FAILS == 0 else f"{FAILS} failed")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
