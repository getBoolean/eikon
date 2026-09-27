"""Behaviour of scripts/credits.py, the third-party credits guard."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

_path = Path(__file__).resolve().parent.parent / "scripts" / "credits.py"
_spec = importlib.util.spec_from_file_location("eikon_credits", _path)
credits = importlib.util.module_from_spec(_spec)
sys.modules["eikon_credits"] = credits
_spec.loader.exec_module(credits)

SCRIPT = "scripts/credits.py"


def _toml(table: str, entries: list[dict]) -> str:
    out = []
    for entry in entries:
        out.append(f"[[{table}]]")
        for key, value in entry.items():
            if isinstance(value, list):
                out.append(f"{key} = [{', '.join(repr(v).replace(chr(39), chr(34)) for v in value)}]")
            else:
                out.append(f'{key} = "{value}"')
        out.append("")
    return "\n".join(out)


class Project:
    def __init__(self, repo) -> None:
        self.repo = repo
        self.root: Path = repo.path
        self.deps: list[dict] = []
        self.components: list[dict] = []
        repo.write("licenses/GPL-3.0-or-later.txt", "license text\n")
        self.save()

    def add_dep(self, name: str) -> None:
        self.deps.append(
            {"name": name, "repo": f"example/{name}", "tag": "v1", "asset": f"{name}.tar.gz",
             "sha256": "0" * 64}
        )

    def credit(self, name: str, *, license_files=("LICENSE",), **extra) -> None:
        for f in license_files:
            if not f.startswith("/") and ".." not in f:
                self.repo.write(f"third_party/notices/{name}/{f}", f"Copyright {name} authors\n")
        self.repo.write("licenses/MIT.txt", "MIT text\n")
        self.components.append(
            {"name": name, "dep": name, "url": f"https://example.invalid/{name}",
             "license": "MIT", "license_files": list(license_files), **extra}
        )

    def save(self, *, notices: bool = True) -> None:
        self.repo.write("third_party/deps.toml", _toml("dep", self.deps))
        self.repo.write("third_party/credits.toml", _toml("component", self.components))
        if notices:
            (self.root / "THIRD_PARTY_NOTICES.md").write_text(credits.generate_notices(self.root))


@pytest.fixture
def project(git_repo) -> Project:
    return Project(git_repo)


def _cli(run_script, project: Project, *args: str):
    return run_script(SCRIPT, *args, cwd=project.root)


def test_an_empty_repo_passes(project, run_script):
    assert credits.check(project.root) == []
    assert _cli(run_script, project, "check").returncode == 0


def test_every_dependency_must_be_credited(project, run_script):
    project.add_dep("libalpha")
    project.credit("libalpha")
    project.save()
    assert credits.check(project.root) == []

    project.add_dep("libbeta")
    project.save()
    problems = credits.check(project.root)
    assert any("libbeta" in p for p in problems)
    assert _cli(run_script, project, "check").returncode != 0


def test_a_missing_license_file_fails(project):
    project.add_dep("libalpha")
    project.credit("libalpha")
    project.save()
    assert credits.check(project.root) == []

    (project.root / "third_party" / "notices" / "libalpha" / "LICENSE").unlink()
    assert credits.check(project.root) != []


@pytest.mark.parametrize("bad_path", ["../outside.txt", "/etc/hosts"], ids=["dotdot", "absolute"])
def test_a_license_path_outside_the_notices_fails(project, bad_path):
    project.add_dep("libalpha")
    project.credit("libalpha", license_files=(bad_path,))
    project.save(notices=False)
    assert any(bad_path in p for p in credits.check(project.root))


def test_stale_notices_fail_until_regenerated(project, run_script):
    project.add_dep("libalpha")
    project.credit("libalpha")
    project.save()
    assert credits.check(project.root) == []

    project.components[0]["url"] = "https://example.invalid/moved"
    project.save(notices=False)
    assert credits.check(project.root) != []

    assert _cli(run_script, project, "notices", "--write").returncode == 0
    assert credits.check(project.root) == []
