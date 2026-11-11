"""Files another process may read while they are rewritten.

write_atomic puts the new content beside the target and renames it into place, so a
reader (the web server, the publisher's loop, the admin command) gets the old file or
the new one, never part of one. It does not order two writers: the last rename wins.
read_json returns the fallback for a file that is missing or is not JSON.
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
