#!/usr/bin/env python3
"""The Discord card and alerts.

One silent card in one channel the operator owns, edited in place, plus restart, update
and outage alerts that come down again once the world is back. State lives in
$DATA_DIR/discord. --dry-run prints what would be sent and sends nothing.
"""
import base64
import getpass
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import requests
import string
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import steamfile  # noqa: E402  (beside this file)
from sn2files import read_json, write_atomic  # noqa: E402

E = os.environ
HERE = Path(__file__).resolve().parent
DATA = Path(E.get("DATA_DIR") or "/data")
LOG, RUN, STATE = DATA / "logs", DATA / "run", DATA / "discord"
CONTROL = Path(E.get("SN2_CONTROL_DIR") or E.get("CONTROL_DIR") or DATA / "control")
PUBLIC = Path(E.get("PUBLIC_DIR") or DATA / "public")
WINEPREFIX = Path(E.get("WINEPREFIX") or DATA / "wine")
STEAM = WINEPREFIX / "drive_c" / "Program Files (x86)" / "Steam"
APP = E.get("GAME_APP_ID") or E.get("STEAM_APPID") or "1962700"
BRANCH = E.get("STEAM_BRANCH") or ""
EXE = E.get("GAME_EXE_NAME") or ("Subnautica2-Win64-Test.exe" if BRANCH == "experimental" else "Subnautica2-Win64-Shipping.exe")
GAME_DIR = Path(E.get("GAME_DIR") or STEAM / "steamapps" / "common" / "Subnautica2")
HOST = E.get("HOST_NAME") or "SN2 Host"
URL = E.get("DISCORD_WEBHOOK_URL") or ""
SILENT, V2 = 4096, 32768
DRY = False

LABEL = {"up": "Open", "starting": "Starting", "waiting": "Not hosting", "updating": "Updating", "down": "Down"}
# Every line a player reads on the card. card.yaml in the data volume overrides any key; the
# layout and the buttons stay the project's. Only the named placeholders are filled.
TEXT = {
    "aboard_title": "**Aboard**",
    "nobody_aboard": "Nobody aboard right now.",
    "last_aboard": " Last aboard {when}.",
    "not_hosting": "The game has run for {min} min without opening its world. Nobody can join until it does.",
    "loader_crashed": "The mod loader wrote a crash report during this run before its mods started. That usually means it doesn't fit this game build; the host's guide covers this under Updates.",
    "scanned": "Scanned lately: {scans}",
    "mods": "• **Mods** ({n}): press **Play with mods** on the [join page]({url}/join) instead of Join Game; it installs them at the server's versions and joins",
    "how_to_join": "### How to join",
    "steam_title": "**Steam**",
    "steam_beta": "• Right-click **Subnautica 2** › **Properties** › **Betas** › pick **{branch}**",
    "steam_add": "• Add the world's host as a friend with its code above; {accepts}",
    "accepts_auto": "it accepts within a minute",
    "accepts_invite": "an admin has to invite you first",
    "accepts_manual": "the host accepts it by hand",
    "steam_join": "• Press **Join**, or **Friends** › right-click the host › **Join Game**",
    "friend_requests": "-# Friend requests waiting for the host: {n}",
    "xbox_title": "**Xbox / PC Game Pass**",
    "xbox_beta": "• Join the Subnautica 2 preview in **Xbox Insider Hub**",
    "xbox_add": "• In the game's **Friends** menu add the world's Xbox code, then join the host from your in-game friends list. No Xbox code above? Ask the host to run moonpool diag friend-code",
    "tip": "-# Tip: turn on background audio in the game's audio settings, so voice keeps playing when you alt-tab",
    "footer": "-# Unofficial and not affiliated with Unknown Worlds, KRAFTON or Valve",
}
PLACEHOLDERS = {"last_aboard": {"when"}, "not_hosting": {"min"}, "scanned": {"scans"}, "mods": {"n", "url"}, "steam_beta": {"branch"}, "steam_add": {"accepts"}, "friend_requests": {"n"}}
TEXT_MAX = 400


def text_problem(key, value):
    """Why a card.yaml line is refused, or '' when it is fine."""
    if key not in TEXT:
        return "not a card line"
    if not isinstance(value, str):
        return "must be text"
    if len(value) > TEXT_MAX:
        return f"longer than {TEXT_MAX} characters"
    allowed = PLACEHOLDERS.get(key, set())
    try:
        for _, field, spec, conv in string.Formatter().parse(value):
            if field is None:
                continue
            if field not in allowed or spec or conv:
                return "placeholders here are " + (", ".join("{%s}" % f for f in sorted(allowed)) or "none")
    except ValueError as err:
        return f"bad placeholder: {err}"
    return ""


def card_text():
    """TEXT with card.yaml's overrides; a bad line is logged and the shipped one kept."""
    text = dict(TEXT)
    path = DATA / "card.yaml"
    if not path.is_file():
        return text
    try:
        raw = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as err:
        note(f"card.yaml unreadable, shipped wording kept: {err}")
        return text
    if not isinstance(raw, dict):
        note("card.yaml is not a mapping of lines, shipped wording kept")
        return text
    for key, value in raw.items():
        why = text_problem(key, value)
        if why:
            note(f"card.yaml {key}: {why}; shipped line kept")
            continue
        text[key] = value
    return text
ICON = {"up": "🟢", "starting": "🟡", "waiting": "⚪", "updating": "🟡", "down": "🔴"}
SKY = {"DA_Clear": "Clear", "DA_ClearGameStart": "Clear", "DA_CloudyA": "Cloudy", "DA_CloudyB": "Cloudy",
       "DA_DistantStormy": "Storm nearby", "DA_Misty": "Misty", "DA_SparseClouds": "Light clouds",
       "DA_StormA": "Storm", "DA_StormB": "Storm", "DA_Storm_Quick": "Storm"}


def save_dir():
    if E.get("SAVE_DIR"):
        return E["SAVE_DIR"]
    if EXE.endswith("-Shipping.exe"):
        return str(WINEPREFIX / "drive_c" / "users" / (E.get("USER") or getpass.getuser()) / "AppData/Local/Subnautica2/Saved/SaveGames")
    return str(GAME_DIR / "Subnautica2" / "Saved" / "SaveGames")


def now():
    return int(float(E.get("SN2_NOW") or time.time()))


def dumps(value):
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


def read_text(path):
    try:
        return Path(path).read_text(encoding="utf-8")
    except OSError:
        return ""


write = write_atomic


def note(message):
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    line = re.sub(r"https://(discord|discordapp)\.com/api/webhooks/[^ \"?]+", "<webhook>", message)
    try:
        LOG.mkdir(parents=True, exist_ok=True)
        with (LOG / "discord.log").open("a", encoding="utf-8") as f:
            f.write(f"[{stamp}] discord: {line}\n")
    except OSError:
        pass


def send(method, suffix, body):
    """One webhook call: (code, response text). A dry run prints it instead."""
    if DRY:
        print(f"{method} {suffix or '/'}\n{body}")
        return "", ""
    if not URL:
        note("no DISCORD_WEBHOOK_URL; skipped")
        return "000", ""
    code, text = 0, ""
    for _ in range(2):
        try:
            r = requests.request(method, URL + suffix, data=body.encode("utf-8"),
                                 headers={"Content-Type": "application/json"}, timeout=15)
            code, text = r.status_code, r.text
        except requests.RequestException:
            code, text = 0, ""
        if code != 429:
            break
        wait = math.ceil(float((read_json_text(text) or {}).get("retry_after") or 1))
        note(f"429; waiting {wait}s once")
        time.sleep(wait)
    write(STATE / "resp.json", text)
    note(f"{method} {suffix.split('?')[0]} -> HTTP {code:03d}")
    return f"{code:03d}", text


def read_json_text(text):
    try:
        return json.loads(text)
    except ValueError:
        return None


def manifest():
    paths = [STEAM / "steamapps" / f"appmanifest_{APP}.acf"]
    try:
        import vdf
        folders = vdf.loads(read_text(STEAM / "steamapps" / "libraryfolders.vdf") or "{}")
        for entry in next(iter(folders.values()), {}).values():
            if isinstance(entry, dict) and entry.get("path"):
                paths.append(Path(entry["path"].replace("\\\\", "/")) / "steamapps" / f"appmanifest_{APP}.acf")
    except (SyntaxError, ValueError, AttributeError):
        pass
    return next((p for p in paths if p.is_file()), None)


def branch_name():
    m = manifest()
    return (steamfile.get(m, "BetaKey") if m else "") or BRANCH


def build_id():
    m = manifest()
    return steamfile.get(m, "buildid") if m else ""


def status():
    s = read_json(CONTROL / "status.json", {})
    return s if isinstance(s, dict) else {}


def others(st):
    return [p for p in st.get("players") or [] if isinstance(p, dict) and p.get("name") != HOST]


def player_lines(st):
    rows = []
    for i, p in enumerate(others(st)):
        name = p.get("name") if E.get("SHOW_PLAYER_NAMES", "true") == "true" and p.get("name") else f"Player {i + 1}"
        ping = p.get("ping_ms")
        rows.append(name + (f" · {round(ping)} ms" if isinstance(ping, (int, float)) and not isinstance(ping, bool) else ""))
    return rows


def game_pid():
    try:
        return subprocess.run(["pgrep", "-f", EXE], capture_output=True, text=True, timeout=10).stdout.split("\n")[0].strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def game_age(pid):
    """Seconds the game process has run, from ps; 0 when ps cannot say."""
    try:
        out = subprocess.run(["ps", "-o", "etimes=", "-p", pid], capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return 0
    return int(out) if out.isdigit() else 0


GAME_AGE = {"s": 0}  # sampled once per run, so the state and the minutes on the card agree


def loader_crashed():
    """True when UE4SS wrote a crash dump during this game run before logging that its mods started.
    Usually the loader does not fit the game build; the card says only what was seen."""
    folder = GAME_DIR / "Subnautica2" / "Binaries" / "Win64" / "ue4ss"
    started = now() - GAME_AGE["s"]
    try:
        dumps = [p for p in folder.glob("crash_*.dmp") if p.stat().st_mtime >= started]
        if not dumps:
            return False
        return "Starting mods" not in (folder / "UE4SS.log").read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False


def not_open(pid):
    """Starting while the game is young; after STARTING_MAX seconds (default 600) a game that
    still has not opened its world is reported as not hosting, so the card stops promising."""
    GAME_AGE["s"] = game_age(pid)
    return "waiting" if GAME_AGE["s"] > int(E.get("STARTING_MAX") or 600) else "starting"


def detected_state():
    pid = game_pid()
    if not pid:
        return "down"
    # The launcher removes the last run's readiness.json, and the mod writes a new one each poll;
    # until it says hosted the world is not open, whatever the leftover status.json says.
    readiness = read_json(CONTROL / "readiness.json", None)
    if not (isinstance(readiness, dict) and readiness.get("hosted") is True):
        return not_open(pid)  # open means joinable: the Host call was made, not only that the game runs
    ts = status().get("ts")
    ts = int(ts) if isinstance(ts, (int, float)) and not isinstance(ts, bool) else 0
    if ts == 0 or now() - ts > int(E.get("STATUS_MAX_AGE") or 90):
        return "starting"  # hosted once, but the mod has gone quiet: not claimed open, not claimed shut
    return "up"


def state():
    override = read_text(STATE / "override").strip()
    expires = read_text(STATE / "override.expires").strip()
    if override and expires.isdigit() and now() < int(expires):
        return override
    return detected_state()


def since_for(st):
    since = read_text(STATE / "card.since").strip()
    if st != read_text(STATE / "card.state").strip() or not since:
        since = str(now())
    if not DRY:
        write(STATE / "card.state", st)
        write(STATE / "card.since", since)
    return since


def esc(s):
    return re.sub(r"([\\*_`~|>#\[\]])", r"\\\1", s)


def clamp(s, n):
    return s if len(s) <= n else s[: n - 1] + "…"


def epoch(iso):
    return int(datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp())


def host_steamid():
    return steamfile.account(STEAM / "config" / "loginusers.vdf")


def public_url():
    url = E.get("SN2_PUBLIC_URL") or ""
    if not url and E.get("TUNNEL", "off") == "quick":
        try:
            host = requests.get(E.get("TUNNEL_METRICS_URL") or "http://tunnel:20241/quicktunnel", timeout=2).json().get("hostname") or ""
        except (requests.RequestException, ValueError, AttributeError):
            host = ""
        if host.endswith(".trycloudflare.com"):
            url = "https://" + host
    return url.rstrip("/")


def world_name(st):
    return st.get("world_name") or E.get("WORLD_NAME") or "Subnautica 2 server"


def world_stats():
    try:
        out = subprocess.run([sys.executable, str(HERE / "world-stats.py")], capture_output=True, text=True, timeout=60,
                             env={**E, "WORLD_STATS_SAVE_DIR": save_dir()}).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    stats = read_json_text(out)
    return stats if isinstance(stats, dict) else None


def world_container():
    st = status()
    kind = state()
    since = since_for(kind)
    names = player_lines(st)
    sid = host_steamid()
    code = str(int(sid) - 76561197960265728) if sid else ""
    sonar = st.get("sonar_code") or (read_text(CONTROL / "sonar-code.txt").split() or [""])[0]
    branch, build = branch_name(), build_id()
    slots = st.get("player_slots")
    slots = str(slots) if isinstance(slots, int) and not isinstance(slots, bool) else ""
    url = public_url()
    join = f"{url}/join" if url else ""
    map_url = f"{url}/map" if url and E.get("WEB_MAP", "false") == "true" else ""
    still = re.sub(r"[^0-9a-f]", "", str(read_json(PUBLIC / "map.json", {}).get("still") or "")) if map_url else ""
    tod, weather = str(st.get("time_of_day") or ""), str(st.get("weather") or "")
    scans = st.get("unlocks", {}).get("scans") if isinstance(st.get("unlocks"), dict) else None
    scans = ", ".join(str(s) for s in scans[-3:]) if isinstance(scans, list) else ""
    T = card_text()
    mods = ""
    if url:
        n = len((read_json(PUBLIC / "mods.json", {}) or {}).get("mods") or [])
        if n:
            mods = T["mods"].format(n=n, url=url)
    stats = world_stats()

    h = esc(HOST)
    fine = " · ".join(x for x in [branch[:1].upper() + branch[1:] if branch else "", f"build {build}" if build else ""] if x)
    head = (f"## 🌊 {esc(world_name(st))}\n{ICON.get(kind, '🔴')} **{LABEL.get(kind, 'Down')}** since <t:{since}:R> · **{len(names)}"
            + (f"/{slots}" if slots else "") + "** aboard" + (f"\n-# {fine}" if fine else ""))
    hour = int(tod[:2]) if tod[:2].isdigit() else None
    daypart = None if hour is None else "Morning" if 5 <= hour < 12 else "Afternoon" if 12 <= hour < 17 else "Evening" if 17 <= hour < 21 else "Night"
    now_line = " · ".join(x for x in [daypart, SKY.get(weather)] if x)
    if names:
        aboard = T["aboard_title"] + "\n" + "\n".join("• " + esc(n) for n in names)
    else:
        aboard = T["nobody_aboard"]
        if stats and stats.get("last_played"):
            try:
                aboard += T["last_aboard"].format(when=f"<t:{epoch(stats['last_played'])}:R>")
            except ValueError:
                pass
    statline = ""
    if stats:
        parts = []
        if stats.get("created"):
            try:
                parts.append(f"Created <t:{epoch(stats['created'])}:D>")
            except ValueError:
                pass
        if stats.get("hours_played") is not None:
            parts.append("Played %s h" % ("%g" % (round(stats["hours_played"] * 10) / 10)))
        seen = stats.get("players_seen")
        crew = seen if isinstance(seen, int) else len(seen) if isinstance(seen, list) else 0
        if crew > 0:
            parts.append(f"Crew {crew}")
        if stats.get("peak_players") is not None:
            parts.append(f"Peak {stats['peak_players']} at once")
        statline = " · ".join(parts)
    codes = [f"**Steam** add **{h}**" + (f" ([profile](https://steamcommunity.com/profiles/{sid}))" if sid else "") + (f" · code **{code}**" if code else "")]
    if sonar:
        codes.append(f"**Xbox** add code **{sonar}**")
    if mods:
        codes.append(mods)
    fr = RUN / "friend-requests.json"  # the watcher rewrites it every minute; an older one is not shown
    fresh = E.get("AUTO_ACCEPT_FRIENDS", "0") != "1" and fr.is_file() and time.time() - fr.stat().st_mtime < 180
    waiting = (read_json(fr, {}) or {}).get("count") if fresh else 0
    if isinstance(waiting, int) and waiting > 0:
        codes.append(T["friend_requests"].format(n=waiting))

    head_component = {"type": 10, "content": clamp(head, 260)}
    if join:
        head_component = {"type": 9, "components": [head_component],
                          "accessory": {"type": 2, "style": 5, "url": join, "disabled": kind != "up",
                                        "label": "Join" if kind == "up" else "Offline" if kind == "down" else "Not open" if kind == "waiting" else "Starting…"}}
    components = [head_component, {"type": 14, "divider": True, "spacing": 1}, {"type": 10, "content": clamp(aboard, 400)}]
    if kind == "waiting" and GAME_AGE["s"]:
        components.append({"type": 10, "content": clamp(T["not_hosting"].format(min=GAME_AGE["s"] // 60), 400)})
        if loader_crashed():
            components.append({"type": 10, "content": clamp(T["loader_crashed"], 400)})
    if now_line:
        components.append({"type": 10, "content": now_line})
    if scans:
        components.append({"type": 10, "content": clamp(T["scanned"].format(scans=esc(scans)), 160)})
    if statline:
        components.append({"type": 10, "content": clamp("-# " + statline, 160)})
    components += [{"type": 14, "divider": False, "spacing": 2}, {"type": 10, "content": clamp("\n".join(codes), 420)}]
    if map_url and still:
        components.append({"type": 12, "items": [{"media": {"url": f"{map_url}.png?v={still}"}, "description": "Lifepods and signals"}]})
    if map_url:
        components.append({"type": 1, "components": [{"type": 2, "style": 5, "label": "Map", "url": map_url}]})
    colour = 3066993 if kind == "up" else 15105570 if kind in ("starting", "updating") else 9807270 if kind == "waiting" else 15158332
    return {"type": 17, "accent_color": colour, "components": components}


def how_to_join():
    """The steps to join, once under every world on the board."""
    branch = branch_name()
    beta = branch not in ("", "public")
    T = card_text()
    if E.get("AUTO_ACCEPT_FRIENDS", "0") != "1":
        accepts = T["accepts_manual"]
    else:
        accepts = T["accepts_auto"] if E.get("ALLOWLIST_ONLY", "true") == "false" else T["accepts_invite"]
    lines = [T["how_to_join"], T["steam_title"]]
    if beta:
        lines.append(T["steam_beta"].format(branch=branch))
    lines += [T["steam_add"].format(accepts=accepts), T["steam_join"], T["xbox_title"]]
    if beta:
        lines.append(T["xbox_beta"])
    lines.append(T["xbox_add"])
    lines.append(T["tip"])
    if E.get("DISCORD_CARD_NOTE"):
        lines.append(E["DISCORD_CARD_NOTE"])
    lines.append(T["footer"])
    return {"type": 10, "content": "\n".join(lines)}


def publish_card(container, world):
    """This world's panel for a board that shows several worlds, webhook or not."""
    if DRY:
        return
    try:
        PUBLIC.mkdir(parents=True, exist_ok=True)
        if E.get("PUBLISH_CARD") == "true":  # what the card shows, for another world's board; names included
            write(PUBLIC / "card.json", dumps({"ts": now(), "world": world, "container": container}))
        else:
            (PUBLIC / "card.json").unlink(missing_ok=True)
    except OSError:
        pass


def peer_containers():
    """The other worlds' panels (DISCORD_BOARD_PEERS); a silent one shows as Offline, never a stale Open."""
    out = []
    for url in (E.get("DISCORD_BOARD_PEERS") or "").split():
        key = hashlib.sha256(url.encode()).hexdigest()[:12]
        try:
            body = read_json_text(requests.get(url, timeout=5).text)
        except requests.RequestException:
            body = None
        fresh = isinstance(body, dict) and isinstance(body.get("container"), dict) and body["container"].get("type") == 17 \
            and isinstance(body.get("ts"), int)
        if fresh and now() - body["ts"] <= int(E.get("DISCORD_PEER_MAX_AGE") or 600):
            if not DRY:
                write(STATE / f"peer-{key}.json", dumps(body))
            out.append(body["container"])
            continue
        if not fresh:
            body = read_json(STATE / f"peer-{key}.json", {})
        world = (body or {}).get("world") or "another world"
        ts = (body or {}).get("ts")
        seen = f" · last seen <t:{ts}:R>" if ts else ""
        out.append({"type": 17, "accent_color": 9807270, "components": [{"type": 10, "content": f"## 🌊 {esc(world)}\n⚪ **Offline**{seen}"}]})
    return out


def count(c):
    return 1 + sum(count(x) for x in c.get("components") or []) + (1 if c.get("accessory") else 0)


def text_of(c):
    total = len(c["content"]) if c.get("type") == 10 else 0
    return total + sum(text_of(x) for x in c.get("components") or [])


def card():
    own = world_container()
    publish_card(own, world_name(status()))
    peers = peer_containers()
    comps = [own]
    for p in peers:  # Discord allows 40 components: a world that would pass it is left out whole
        if sum(count(c) for c in comps) + count(p) <= 40:
            comps.append(p)
    if len(comps) != 1 + len(peers):
        note("board full at 40 components; a world was left out")
    how = how_to_join()
    if sum(text_of(c) for c in comps) + text_of(how) <= 4000:  # the steps give way before a world does
        comps.append(how)
    payload = {"flags": SILENT + V2, "allowed_mentions": {"parse": []}, "components": comps}
    body = dumps(payload)
    digest = hashlib.sha256(body.encode("utf-8")).hexdigest()[:32]
    if not URL and not DRY:
        note("no DISCORD_WEBHOOK_URL: panel published for a board only")
        return
    if not DRY and read_text(STATE / "card.sum") == digest:
        note("card unchanged")
        return
    message_id = read_text(STATE / "card.id").strip() or read_text(STATE / "status.id").strip()
    code = ""
    if message_id:
        # The edit also turns an older embed card into this one, so a pinned message stays pinned.
        code, text = send("PATCH", f"/messages/{message_id}?with_components=true", dumps({**payload, "embeds": None, "attachments": []}))
        if code == "404":
            note("card was deleted; recreating it")
            message_id = ""
        elif code == "400":
            note(f"card edit refused: {text[:300]}; posting a new card (pin it)")
            message_id = ""
        elif code.startswith("2"):
            write(STATE / "card.id", message_id)
            note(f"card message id {message_id} edited in place")
    if not message_id:
        code, text = send("POST", "?wait=true&with_components=true", body)
        if not DRY:
            new_id = str((read_json_text(text) or {}).get("id") or "")
            if new_id:
                write(STATE / "card.id", new_id)
                note(f"card message id {new_id} kept in {STATE / 'card.id'}")
    if code.startswith("2"):
        write(STATE / "card.sum", digest)


def alert(kind, detail):
    said = {"restart": "restarting", "update": "update", "outage": "outage", "down": "outage", "crash": "outage"}.get(kind)
    if not said:
        note(f"refused: '{kind}' is not an alert")
        print(f"not an alert: {kind}", file=sys.stderr)
        return 65
    write(STATE / "override", "updating" if kind in ("restart", "update") else "down")
    write(STATE / "override.expires", str(now() + 600))
    role = E.get("DISCORD_ALERT_ROLE_ID") or ""
    text = f"{HOST}: {said}" + (f" — {detail}" if detail else "")
    if role:
        text = f"<@&{role}> {text}"
    # Silent (shown, no push or sound) unless the operator asks for pushes.
    flags = 0 if E.get("DISCORD_ALERTS_NOTIFY", "false") == "true" else SILENT
    mentions = {"parse": [], "roles": [role]} if role else {"parse": []}
    code, response = send("POST", "?wait=true", dumps({"content": text, "flags": flags, "allowed_mentions": mentions}))
    if not DRY:
        print(f"{code} {response}")
        new_id = str((read_json_text(response) or {}).get("id") or "")
        if new_id:
            with (STATE / "alerts.ids").open("a", encoding="utf-8") as f:
                f.write(new_id + "\n")
    return 0


def clear_alerts():
    """Every alert posted here comes down once the world is back, so the channel holds only the card."""
    ids = [i for i in read_text(STATE / "alerts.ids").split("\n") if i]
    if not ids:
        return
    keep = []
    for message_id in ids:
        code, _ = send("DELETE", f"/messages/{message_id}", "")
        if code.startswith("2") or code == "404":
            note(f"alert {message_id} removed after recovery")
        else:
            keep.append(message_id)
    if keep:
        write(STATE / "alerts.ids", "".join(i + "\n" for i in keep))
    else:
        (STATE / "alerts.ids").unlink(missing_ok=True)


def run_hook(args):
    """The admin's own script, given the event and its detail. It never holds up the host."""
    hook = DATA / "hooks" / "on-event"
    if not (hook.is_file() and os.access(hook, os.X_OK)):
        return
    cmd = ([shutil.which("timeout"), "60"] if shutil.which("timeout") else []) + [str(hook)] + list(args)
    try:
        LOG.mkdir(parents=True, exist_ok=True)
        with (LOG / "hooks.log").open("a") as out:
            subprocess.Popen(cmd, stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
    except OSError as err:
        note(f"hook did not start: {err}")


def main(argv):
    global DRY
    sys.stdout.reconfigure(encoding="utf-8")
    if argv and argv[0] == "--dry-run":
        DRY, argv = True, argv[1:]
    STATE.mkdir(parents=True, exist_ok=True)
    LOG.mkdir(parents=True, exist_ok=True)
    cmd = argv[0] if argv else ""
    if cmd in ("status", "welcome", "heartbeat", "flush-due", "sweep"):
        if cmd not in ("status", "welcome"):
            note(f"{cmd}: card refresh only")
        card()
        return 0
    if cmd == "event":
        kind, detail = (argv[1] if len(argv) > 1 else ""), " ".join(argv[2:])
        if not DRY:
            run_hook(argv[1:])
        if kind in ("restart", "update", "outage", "down", "crash"):
            alert(kind, detail)
        elif kind == "up":
            for name in ("override", "override.expires"):
                (STATE / name).unlink(missing_ok=True)
            clear_alerts()
        elif kind in ("join", "leave", "backup_failed", ""):
            note(f"routine event {kind or 'empty'}: card refresh only")
        else:
            note(f"refused: '{kind}' is not an event")
            return 65
        card()
        return 0
    if cmd == "avatar":
        path = Path(argv[1]) if len(argv) > 1 else None
        if not (path and path.is_file()):
            return 66
        if DRY:
            print("PATCH / avatar")
            return 0
        send("PATCH", "", dumps({"avatar": "data:image/png;base64," + base64.b64encode(path.read_bytes()).decode()}))
        return 0
    print("usage: discord-notify.py [--dry-run] status | welcome | event <restart|update|outage|up|down|crash|join|leave|backup_failed> [detail] | heartbeat", file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
