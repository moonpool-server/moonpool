"""scripts/sn2files.py: a file is replaced whole, and a bad JSON file reads as its fallback."""
import sys
from pathlib import Path
from unittest import mock

import pytest

sys.path.insert(0, str(Path(__file__).parents[1] / "scripts"))
import sn2files  # noqa: E402


def test_a_write_replaces_the_file_and_leaves_nothing_beside_it(tmp_path) -> None:
    target = tmp_path / "map.html"
    sn2files.write_atomic(target, "one")
    sn2files.write_atomic(target, b"two")
    assert target.read_bytes() == b"two"
    assert [p.name for p in tmp_path.iterdir()] == ["map.html"]


def test_a_write_that_fails_keeps_the_old_file_and_cleans_up(tmp_path) -> None:
    target = tmp_path / "pins.json"
    target.write_text("old")
    with mock.patch.object(sn2files.os, "replace", side_effect=OSError("disk")), pytest.raises(OSError):
        sn2files.write_atomic(target, "new")
    assert target.read_text() == "old"
    assert [p.name for p in tmp_path.iterdir()] == ["pins.json"]


def test_a_reader_never_sees_part_of_a_file(tmp_path) -> None:
    target = tmp_path / "big.json"
    seen = []
    real = sn2files.os.replace

    def replace(src, dst):
        seen.append(target.read_text() if target.exists() else None)  # what a reader gets just before the swap
        real(src, dst)

    sn2files.write_atomic(target, "a" * 100000)
    with mock.patch.object(sn2files.os, "replace", replace):
        sn2files.write_atomic(target, "b" * 100000)
    assert seen == ["a" * 100000] and target.read_text() == "b" * 100000


def test_missing_or_broken_json_reads_as_the_fallback(tmp_path) -> None:
    assert sn2files.read_json(tmp_path / "none.json", {"x": 1}) == {"x": 1}
    (tmp_path / "bad.json").write_text("{not json")
    assert sn2files.read_json(tmp_path / "bad.json", []) == []
    (tmp_path / "good.json").write_text('{"a": 2}')
    assert sn2files.read_json(tmp_path / "good.json", None) == {"a": 2}
