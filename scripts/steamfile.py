#!/usr/bin/env python3
"""One value out of a Steam VDF or ACF file: steamfile.py <file> <key>.

Reads the file with the vdf package and looks for the key at the top of the tree
first, then anywhere below it. Prints nothing when the file or the key is missing.
"""
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


def get(path, key):
    try:
        tree = vdf.loads(Path(path).read_text(encoding="utf-8", errors="replace"))
    except (OSError, SyntaxError, ValueError):
        return ""
    hit = find(tree, key)
    return "" if hit is None else str(hit)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: steamfile.py <file> <key>", file=sys.stderr)
        sys.exit(2)
    sys.stdout.write(get(sys.argv[1], sys.argv[2]))
