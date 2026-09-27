"""Behaviour of scripts/deps.py: prebuilt libraries from fork releases."""

from __future__ import annotations

import hashlib
import io
import tarfile
import tomllib
from dataclasses import dataclass
from pathlib import Path

import pytest

SCRIPT = "scripts/deps.py"
NAME = "libdemo"
REPO = "example/libdemo"
ASSET = "libdemo-ios-arm64.tar.gz"


@dataclass
class Fixture:
    root: Path  # the eikon checkout
    releases: Path  # stands in for https://github.com
    files: dict[str, bytes]  # what the pinned asset contains

    @property
    def manifest(self) -> Path:
        return self.root / "third_party" / "deps.toml"

    @property
    def unpacked(self) -> Path:
        return self.root / "build" / "deps" / NAME

    def publish(self, tag: str, files: dict[str, bytes]) -> str:
        """Publish a release asset; return its SHA-256."""
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w:gz") as tar:
            for name, data in files.items():
                info = tarfile.TarInfo(name)
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
        path = self.releases / REPO / "releases" / "download" / tag / ASSET
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(buf.getvalue())
        return hashlib.sha256(buf.getvalue()).hexdigest()

    def pin(self, entries: list[dict[str, str]]) -> None:
        lines = []
        for entry in entries:
            lines.append("[[dep]]")
            lines += [f'{key} = "{value}"' for key, value in entry.items()]
            lines.append("")
        self.manifest.write_text("\n".join(lines))

    def snapshot(self) -> dict[str, bytes]:
        return {
            str(p.relative_to(self.unpacked)): p.read_bytes()
            for p in sorted(self.unpacked.rglob("*"))
            if p.is_file() and not p.name.startswith(".")
        }


@pytest.fixture
def project(git_repo, tmp_path) -> Fixture:
    files = {"lib/libdemo.a": b"archive bytes\n", "include/demo.h": b"int demo(void);\n"}
    fx = Fixture(root=git_repo.path, releases=tmp_path / "releases", files=files)
    fx.manifest.parent.mkdir(parents=True)
    sha = fx.publish("v1", files)
    fx.pin([{"name": NAME, "repo": REPO, "tag": "v1", "asset": ASSET, "sha256": sha}])
    return fx


def _run(run_script, fx: Fixture, *args: str):
    return run_script(
        SCRIPT, "--repo-root", str(fx.root), *args,
        cwd=fx.root, env={"EIKON_RELEASES_URL": fx.releases.as_uri()},
    )


def test_fetch_unpacks_the_pinned_release_and_is_repeatable(project, run_script):
    assert _run(run_script, project, "check").returncode == 0

    first = _run(run_script, project, "fetch")
    assert first.returncode == 0, first.stderr
    assert project.snapshot() == project.files
    assert _run(run_script, project, "verify").returncode == 0

    second = _run(run_script, project, "fetch")
    assert second.returncode == 0, second.stderr
    assert project.snapshot() == project.files

    (project.unpacked / "lib" / "libdemo.a").write_bytes(b"edited\n")
    assert _run(run_script, project, "verify").returncode != 0


def test_an_asset_that_does_not_match_its_pin_is_rejected(project, run_script):
    # The release asset is replaced after it was pinned.
    project.publish("v1", {"lib/libdemo.a": b"replaced\n"})

    result = _run(run_script, project, "fetch")
    assert result.returncode != 0
    assert NAME in result.stdout + result.stderr
    assert not project.unpacked.exists()
    assert _run(run_script, project, "verify").returncode != 0


def test_an_archive_member_outside_the_tree_is_rejected(project, run_script):
    sha = project.publish("v3", {"../outside.txt": b"escape\n"})
    project.pin([{"name": NAME, "repo": REPO, "tag": "v3", "asset": ASSET, "sha256": sha}])

    result = _run(run_script, project, "fetch")
    assert result.returncode != 0
    assert NAME in result.stdout + result.stderr
    assert not project.unpacked.exists()
    assert not (project.root / "build" / "outside.txt").exists()


def test_pin_records_a_release_and_fetch_uses_it(project, run_script):
    new_files = {"lib/libdemo.a": b"version two\n"}
    sha = project.publish("v2", new_files)

    result = _run(run_script, project, "pin", NAME, "--tag", "v2")
    assert result.returncode == 0, result.stderr
    pinned = tomllib.loads(project.manifest.read_text())["dep"][0]
    assert (pinned["tag"], pinned["sha256"]) == ("v2", sha)

    assert _run(run_script, project, "fetch").returncode == 0
    assert project.snapshot() == new_files


@pytest.mark.parametrize(
    "entries",
    [
        [{"name": NAME, "repo": REPO, "tag": "v1", "asset": ASSET, "sha256": "abc"}],
        [
            {"name": NAME, "repo": REPO, "tag": "v1", "asset": ASSET, "sha256": "a" * 64},
            {"name": NAME, "repo": REPO, "tag": "v2", "asset": ASSET, "sha256": "b" * 64},
        ],
    ],
    ids=["short-hash", "duplicate-name"],
)
def test_check_rejects_an_invalid_manifest(project, run_script, entries):
    project.pin(entries)
    assert _run(run_script, project, "check").returncode != 0
