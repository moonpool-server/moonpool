"""Files another process may read while they are rewritten.

write_atomic puts the new content beside the target and renames it into place, so a
reader (the web server, the publisher's loop, the admin command) gets the old file or
the new one, never part of one. It does not order two writers: the last rename wins.
read_json returns the fallback for a file that is missing or is not JSON.
publish_theme puts the pages' one stylesheet of design tokens beside them.
"""
import json
import os
from pathlib import Path


def write_atomic(path, data):
    path = Path(path)
    if isinstance(data, str):
        data = data.encode("utf-8")
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        tmp.write_bytes(data)
        os.replace(tmp, path)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise


def read_json(path, fallback):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return fallback


def publish_theme(data, public, shipped):
    """theme.css beside the pages: the host's own templates/theme.css when it is a plain file there,
    else the shipped one. Every colour, font and size the pages use comes from it."""
    own = Path(data) / "templates" / "theme.css"
    plain = own.is_file() and not own.is_symlink() and own.resolve().parent == (Path(data) / "templates").resolve()
    src = own if plain else Path(shipped) / "theme.css"
    try:
        write_atomic(Path(public) / "theme.css", src.read_bytes())
    except OSError:
        pass
