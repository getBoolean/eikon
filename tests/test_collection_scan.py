"""Opt-in check of the collection scanner against the owner's game share.

Runs only with the share mounted and EIKON_SCAN_COLLECTION=1. The expected counts
come from the requirements table at run time; no counts or titles live here.
"""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
SHARE = Path("/Volumes/Games")

pytestmark = pytest.mark.skipif(
    not (SHARE.is_dir() and os.environ.get("EIKON_SCAN_COLLECTION") == "1"),
    reason="needs /Volumes/Games mounted and EIKON_SCAN_COLLECTION=1",
)

# Requirements-table engine names to the scanner's count keys. The table counts Unity
# by UnityPlayer.dll, so it compares with that line rather than all Unity games.
ENGINE_KEYS = {
    "Unity": "unity.unityplayer",
    "Kirikiri": "engine.kirikiri",
    "Ren'Py": "engine.renpy",
    "GameMaker": "engine.gameMaker",
    "BGI": "engine.bgi",
}


def table_counts() -> dict[str, int]:
    """Engine key -> folder count from the 'Games to support' table."""
    text = (REPO_ROOT / "planning" / "requirements.md").read_text(encoding="utf-8")
    section = text.split("## Games to support, in priority order", 1)[1]
    counts: dict[str, int] = {}
    for line in section.splitlines():
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) >= 2 and cells[0] in ENGINE_KEYS and cells[1].isdigit():
            counts[ENGINE_KEYS[cells[0]]] = int(cells[1])
        if line.startswith("## ") and counts:
            break
    return counts


def scanner_counts() -> dict[str, int]:
    """Count key -> value from the scanner's `key: <n>` lines."""
    result = subprocess.run(
        ["swift", "run", "--package-path", "Packages/EikonCore", "-c", "release",
         "eikon-scan", "--root", str(SHARE)],
        cwd=REPO_ROOT, check=True, capture_output=True, text=True,
    )
    return {match[1]: int(match[2]) for match in re.finditer(r"^([\w.-]+): (\d+)$", result.stdout, re.M)}


def test_engine_counts_match_requirements_table() -> None:
    expected = table_counts()
    assert expected, "no engine rows parsed from the requirements table"
    actual = scanner_counts()
    assert {key: actual.get(key, 0) for key in expected} == expected
