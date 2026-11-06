#!/usr/bin/env python3
# Blocks game-derived files and credentials; no stock
# pre-commit hook covers those.
"""Repository policy check.

Fails when the tree contains something this project must never ship:
  * files derived from the game's binaries (AOB signature scripts, header
    dumps, mappings, UE4SS layouts)
  * Steam session or credential files

Usage: python3 scripts/check_repo_policy.py [paths...]
With no paths it checks every file git tracks or would track (honours
.gitignore). Exit 0 clean, 1 on any finding.
"""
from __future__ import annotations

import fnmatch
import os
import re
import subprocess
import sys
from pathlib import Path

FORBIDDEN_NAMES = [
    re.compile(r"(^|/)MemberVariableLayout\.ini$", re.I),
    re.compile(r"(^|/)VTableLayout\.ini$", re.I),
    re.compile(r"(^|/)UE4SS_Signatures/", re.I),
    re.compile(r"(^|/)(msvcp140|vcruntime140|vccorlib140)[^/]*\.dll$", re.I),
    re.compile(r"(^|/)vc_redist[^/]*\.exe$", re.I),
    re.compile(r"(^|/)HOST_ARMED$"),
    re.compile(r"(^|/)CXXHeaderDump/", re.I),
    re.compile(r"\.usmap$", re.I),
    re.compile(r"\.(pdb|pak|utoc|ucas|dll|exe)$", re.I),
    re.compile(r"(^|/)(config/loginusers\.vdf|ssfn\d*|local\.vdf)$", re.I),
    re.compile(r"(^|/)\.env$"),
    # Game data and saves, and any picture: the repository ships no images at all,
    # so no game art, logo or screenshot can slip in.
    re.compile(r"\.(sav|uasset|umap|bnk|png|jpe?g|gif|webp|bmp|ico|svg|tga|dds)$", re.I),
    re.compile(r"(^|/)\.github/FUNDING\.ya?ml$", re.I),
    # Layout sets and scan patterns are per game build and stay with the operator.
    re.compile(r"(^|/)ue4ss/layouts/", re.I),
]

# Non-commercial: no donation or payment links anywhere.
DONATION = re.compile(r"(patreon\.com|ko-fi\.com|buymeacoffee\.com|paypal\.me|"
                      r"github\.com/sponsors|liberapay\.com|opencollective\.com)", re.I)
# The README's takedown contact must be filled before a release tag.
CONTACT_PLACEHOLDER = "CONTACT: <owner fills before publishing>"

TEXT_SUFFIXES = {
    "", ".md", ".sh", ".lua", ".json", ".yml", ".yaml", ".py", ".ini", ".txt",
    ".service", ".bats", ".example", ".toml", ".cfg", ".ps1", ".cmd",
}


def tracked_files(root: Path) -> list[Path]:
    out = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=root, check=True, capture_output=True,
    ).stdout.decode()
    return [root / p for p in out.split("\0") if p]


def check(root: Path, files: list[Path]) -> list[str]:
    problems: list[str] = []
    for f in files:
        rel = f.relative_to(root).as_posix() if f.is_absolute() else f.as_posix()
        for pat in FORBIDDEN_NAMES:
            if pat.search(rel):
                problems.append(f"{rel}: forbidden file (game-derived, binary or credential)")
                break
        if not f.is_file() or f.suffix.lower() not in TEXT_SUFFIXES:
            continue
        if rel == "scripts/check_repo_policy.py":
            continue
        try:
            text = f.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for n, line in enumerate(text.splitlines(), 1):
            if DONATION.search(line):
                problems.append(f"{rel}:{n}: donation or payment link (non-commercial project)")
    return problems


def check_contact(root: Path, tagged: bool) -> list[str]:
    """README must carry a CONTACT line; the placeholder is refused once tagged."""
    readme = root / "README.md"
    text = readme.read_text(encoding="utf-8") if readme.is_file() else ""
    if not any(line.startswith("CONTACT:") for line in text.splitlines()):
        return ["README.md: no CONTACT: line for takedown requests or concerns"]
    if tagged and CONTACT_PLACEHOLDER in text:
        return ["README.md: CONTACT is still the placeholder; fill it before tagging a release"]
    return []


def dockerignore_admits(root: Path, src: str) -> bool:
    """Whether .dockerignore lets src into the build context: the last matching line wins,
    a "!" line admits, a directory line covers what is under it (Docker's own order)."""
    di = root / ".dockerignore"
    if not di.is_file():
        return True
    s, admitted = src.rstrip("/"), True
    for raw in di.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        neg = line.startswith("!")
        pat = (line[1:] if neg else line).rstrip("/")
        if fnmatch.fnmatchcase(s, pat) or s.startswith(pat + "/"):
            admitted = neg
    return admitted


def check_dockerfile_sources(root: Path) -> list[str]:
    """Every local COPY source in the Dockerfile exists (a deleted script breaks the build)
    and .dockerignore lets it into the context."""
    df = root / "Dockerfile"
    if not df.is_file():
        return []
    joined = df.read_text(encoding="utf-8").replace("\\\n", " ")
    problems = []
    for line in joined.splitlines():
        words = line.split()
        if not words or words[0] != "COPY" or any(w.startswith("--from") for w in words):
            continue
        for src in [w for w in words[1:-1] if not w.startswith("--")]:
            if not (root / src).exists():
                problems.append(f"Dockerfile: COPY source {src} does not exist")
            elif not dockerignore_admits(root, src):
                problems.append(f"Dockerfile: COPY source {src} is kept out of the build context by .dockerignore")
    return problems


def head_is_tagged(root: Path) -> bool:
    r = subprocess.run(["git", "tag", "--points-at", "HEAD"], cwd=root,
                       capture_output=True, text=True)
    return bool(r.stdout.strip()) or bool(os.environ.get("RELEASE_TAG"))


def main(argv: list[str]) -> int:
    root = Path(__file__).resolve().parent.parent
    files = [Path(a).resolve() for a in argv] if argv else tracked_files(root)
    problems = (check(root, files) + check_contact(root, head_is_tagged(root))
                + check_dockerfile_sources(root))
    for p in problems:
        print(f"policy: {p}")
    if problems:
        return 1
    print(f"policy: {len(files)} files checked, clean")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
