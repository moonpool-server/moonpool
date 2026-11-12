#!/usr/bin/env python3
"""One value out of a Steam VDF or ACF file: steamfile.py <file> <key>.

Reads the file with the vdf package and looks for the key at the top of the tree
first, then anywhere below it. Prints nothing when the file or the key is missing.

steamfile.py --account <loginusers.vdf> prints the steamid64 of the account Steam signs in
as: the one marked MostRecent, else the one marked AutoLogin, else the first in the file.
"""
import re
import sys
from pathlib import Path

import vdf


def find(tree, key):
    for k, v in tree.items():
        if k == key and not isinstance(v, dict):
            return v
    for v in tree.values():
        if isinstance(v, dict):
            hit = find(v, key)
            if hit is not None:
                return hit
    return None


def load(path):
    try:
        return vdf.loads(Path(path).read_text(encoding="utf-8", errors="replace"))
    except (OSError, SyntaxError, ValueError):
        return {}


def get(path, key):
    hit = find(load(path), key)
    return "" if hit is None else str(hit)


def account(path):
    users = load(path).get("users")
    users = {sid: {k.lower(): v for k, v in row.items()} for sid, row in (users if isinstance(users, dict) else {}).items()
             if re.fullmatch(r"7656\d{13}", sid) and isinstance(row, dict)}
    for flag in ("mostrecent", "autologin"):
        for sid, row in users.items():
            if row.get(flag) == "1":
                return sid
    return next(iter(users), "")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: steamfile.py <file> <key> | steamfile.py --account <loginusers.vdf>", file=sys.stderr)
        sys.exit(2)
    sys.stdout.write(account(sys.argv[2]) if sys.argv[1] == "--account" else get(sys.argv[1], sys.argv[2]))
