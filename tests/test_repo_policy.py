#!/usr/bin/env python3
"""Tests for scripts/check_repo_policy.py: what the repository refuses to ship.

The publishing-safety rules: no game files, saves or
binaries, no picture of any kind (so no game art, logo or screenshot), no
donation links, and a CONTACT line that is filled before a release tag.
"""
import importlib.util
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True  # never leave scripts/__pycache__ behind
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("policy", HERE.parent / "scripts" / "check_repo_policy.py")
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)

FILLED = "# x\n\nCONTACT: https://github.com/example/project/issues\n"


def run(files: dict[str, bytes], readme: str = FILLED, tagged: bool = False) -> list[str]:
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        (root / "README.md").write_text(readme, encoding="utf-8")
        paths = []
        for name, data in files.items():
            p = root / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
            paths.append(p)
        return policy.check(root, paths) + policy.check_contact(root, tagged)


def test_refuses_game_origin_files() -> None:
    for name in ("Binaries/Win64/Subnautica2-Win64-Test.exe", "ue4ss/UE4SS.dll",
                 "Content/Paks/pakchunk0-Windows.pak", "SaveGames/slot1.sav",
                 "docs/img/screenshot.png", "docs/logo.jpg", "art/icon.webp", "docs/images/Shot.PNG",
                 "docs/images/a.jpg", "docs/images/sub/a.png"):
        problems = run({name: b"\x00binary"})
        assert problems, f"{name} was accepted"


def test_accepts_original_text() -> None:
    assert run({"scripts/a.sh": b"#!/bin/sh\necho ok\n", "docs/a.md": b"# ok\n"}) == []


def test_refuses_donation_links() -> None:
    link = "https://ko" + "-fi.com/someone"  # built from parts so this file passes
    assert run({"docs/a.md": f"Support me: {link}\n".encode()})
    assert run({".github/FUNDING.yml": b"github: someone\n"})


def test_no_layout_set_can_be_committed() -> None:
    ini = b"[FUObjectItem]\nObject = 0x8\n"
    for name in ("MemberVariableLayout.ini", "mod/SN2SlotFreeHost/VTableLayout.ini",
                 "ue4ss/layouts/abcd1234/MemberVariableLayout.ini",
                 "ue4ss/layouts/abcd1234/VTableLayout.ini",
                 "ue4ss/layouts/abcd1234/UE4SS-settings.ini",
                 "ue4ss/layouts/abcd1234/UE4SS_Signatures/GNatives.lua"):
        assert run({name: ini}), f"{name} was accepted"


def test_a_screenshot_of_moonpool_itself_may_live_in_docs_images() -> None:
    assert run({"docs/images/discord-card.png": b"PNG picture"}) == []


def test_contact_line() -> None:
    assert run({}, readme="# x\n")  # no CONTACT line at all
    placeholder = "# x\n\n" + policy.CONTACT_PLACEHOLDER + "\n"
    assert run({}, readme=placeholder) == []  # untagged: allowed while private
    assert run({}, readme=placeholder, tagged=True)  # tagged: refused
    assert run({}, tagged=True) == []


def test_dockerfile_copy_sources_exist() -> None:
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        (root / "a.sh").write_text("x\n")
        (root / "Dockerfile").write_text(
            "FROM x AS b\nCOPY --chmod=0755 a.sh \\\n     gone.py /opt/\nCOPY --from=b /y /z\n")
        assert policy.check_dockerfile_sources(root) == [
            "Dockerfile: COPY source gone.py does not exist"]
        # An allowlist .dockerignore: a source it does not admit is refused by name.
        (root / "d").mkdir()
        (root / "d" / "x").write_text("x\n")
        (root / "new.sh").write_text("x\n")
        (root / ".dockerignore").write_text("*\n!a.sh\n!d/\nd/**/*.dll\n")
        (root / "Dockerfile").write_text("FROM x\nCOPY a.sh new.sh /opt/\nCOPY d/ /opt/d/\n")
        assert policy.check_dockerfile_sources(root) == [
            "Dockerfile: COPY source new.sh is kept out of the build context by .dockerignore"]
    assert policy.check_dockerfile_sources(HERE.parent) == []  # the real one



if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
            print(f"ok {name}")
