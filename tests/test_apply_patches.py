"""Behaviour of scripts/apply_patches.py against a fixture superproject."""

from __future__ import annotations

import shutil
from dataclasses import dataclass
from pathlib import Path

import pytest

SCRIPT = "scripts/apply_patches.py"
NAME = "libdemo"
SUB = f"third_party/{NAME}"

# Local-path submodule clones are refused by default; only the tests allow them.
FILE_PROTOCOL = {
    "GIT_CONFIG_COUNT": "1",
    "GIT_CONFIG_KEY_0": "protocol.file.allow",
    "GIT_CONFIG_VALUE_0": "always",
}


@dataclass
class Fixture:
    repo: object  # the superproject (a GitRepo)
    pin: str  # the gitlink commit
    patched: dict[str, bytes]  # the tree the patches were made from

    @property
    def root(self) -> Path:
        return self.repo.path

    @property
    def sub(self) -> Path:
        return self.repo.path / SUB

    def git(self, *args: str) -> str:
        return self.repo.git(*args).stdout

    def sub_git(self, *args: str) -> str:
        return self.repo.git("-C", SUB, *args).stdout


def _snapshot(tree: Path) -> dict[str, bytes]:
    return {
        str(p.relative_to(tree)): p.read_bytes()
        for p in sorted(tree.rglob("*"))
        if p.is_file() and ".git" not in p.relative_to(tree).parts
    }


@pytest.fixture
def project(make_repo, tmp_path) -> Fixture:
    upstream = make_repo("upstream")
    upstream.write("greeting.txt", "hello\n")
    upstream.write("notes.txt", "one\ntwo\nthree\n")
    upstream.commit("Initial import")
    pin = upstream.git("rev-parse", "HEAD").stdout.strip()

    # Patches made with format-patch against the pin, in a scratch clone.
    scratch = tmp_path / "scratch"
    upstream.git("clone", "-q", str(upstream.path), str(scratch))
    patch_dir = tmp_path / "made-patches"
    for number, (path, text) in enumerate(
        [("greeting.txt", "hello, patched\n"), ("notes.txt", "one\ntwo, patched\nthree\n")],
        start=1,
    ):
        (scratch / path).write_text(text)
        upstream.git("-C", str(scratch), "commit", "-qam", f"Change {path}")
        upstream.git(
            "-C", str(scratch), "format-patch", "-1", "--start-number", str(number),
            "-o", str(patch_dir),
        )
    patched = _snapshot(scratch)

    root = make_repo("super")
    root.git("-c", "protocol.file.allow=always", "submodule", "add", "-q", str(upstream.path), SUB)
    root.git("config", "-f", ".gitmodules", f"submodule.{SUB}.ignore", "dirty")
    shutil.copytree(patch_dir, root.path / "patches" / NAME)
    root.commit("Add libdemo with patches")

    # Move the submodule to a later upstream commit: the tool must use the
    # gitlink, not whatever the submodule has checked out.
    upstream.write("later.txt", "after the pin\n")
    upstream.commit("After the pin")
    root.git("-C", SUB, "fetch", "-q", "origin")
    root.git("-C", SUB, "checkout", "-q", "--detach", "origin/HEAD")

    return Fixture(repo=root, pin=pin, patched=patched)


def _run(run_script, fx: Fixture, *args: str):
    return run_script(SCRIPT, "--repo-root", str(fx.root), *args, cwd=fx.root, env=FILE_PROTOCOL)


def _at_clean_pin(fx: Fixture) -> bool:
    head = fx.sub_git("rev-parse", "HEAD").strip()
    return head == fx.pin and fx.sub_git("status", "--porcelain", "--ignored") == ""


def test_apply_changes_the_tree_and_is_idempotent(project, run_script):
    first = _run(run_script, project, "apply")
    assert first.returncode == 0, first.stderr
    after_first = _snapshot(project.sub)
    assert after_first == project.patched

    second = _run(run_script, project, "apply")
    assert second.returncode == 0, second.stderr
    assert _snapshot(project.sub) == after_first


def test_apply_records_no_new_submodule_commit(project, run_script):
    assert _run(run_script, project, "apply").returncode == 0

    gitlink = project.git("ls-tree", "HEAD", SUB).split()[2]
    assert project.sub_git("rev-parse", "HEAD").strip() == gitlink == project.pin
    assert project.git("status", "--porcelain") == ""
    assert project.git("diff", "--submodule") == ""


def test_a_conflicting_patch_fails_cleanly(project, run_script):
    bad = project.root / "patches" / NAME / "0003-change-missing-line.patch"
    bad.write_text(
        "diff --git a/greeting.txt b/greeting.txt\n"
        "--- a/greeting.txt\n"
        "+++ b/greeting.txt\n"
        "@@ -1 +1 @@\n"
        "-a line that is not there\n"
        "+a replacement\n"
    )

    result = _run(run_script, project, "apply")
    assert result.returncode != 0
    output = result.stdout + result.stderr
    assert NAME in output and bad.name in output
    assert _at_clean_pin(project)


def test_restore_returns_to_the_pin(project, run_script):
    assert _run(run_script, project, "apply").returncode == 0
    (project.sub / "stray-build-output.o").write_text("junk\n")

    result = _run(run_script, project, "restore")
    assert result.returncode == 0, result.stderr
    assert _at_clean_pin(project)
