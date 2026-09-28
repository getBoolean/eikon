"""Behaviour of scripts/repo/build_index.py: a Sileo-ready docs/ tree from one deb."""

from __future__ import annotations

import hashlib
import importlib.util
import lzma
import shutil
import subprocess
from pathlib import Path

import pytest

if shutil.which("dpkg-deb") is None or shutil.which("zstd") is None:
    pytest.skip("dpkg-deb and zstd are required", allow_module_level=True)

ROOT = Path(__file__).resolve().parent.parent
TEMPLATES = ROOT / "packaging" / "repo"
ICONS = TEMPLATES / "icon"

_spec = importlib.util.spec_from_file_location("build_index", ROOT / "scripts" / "repo" / "build_index.py")
build_index_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(build_index_mod)

ASSET_BASE = "https://github.com/getBoolean/eikon/releases/download"


def _make_deb(directory: Path, version: str) -> Path:
    stage = directory / f"stage-{version}"
    debian = stage / "DEBIAN"
    debian.mkdir(parents=True)
    (debian / "control").write_text(
        "Package: com.getboolean.eikon.rootless\n"
        f"Version: {version}\n"
        "Architecture: iphoneos-arm64\n"
        "Name: Eikon\n"
        "Maintainer: getBoolean <https://github.com/getBoolean>\n"
        "Description: An early prototype that reports JIT and device status.\n"
    )
    payload = stage / "var" / "jb" / "Applications" / "Eikon.app"
    payload.mkdir(parents=True)
    (payload / "marker").write_text("payload\n")
    out = directory / f"com.getboolean.eikon.rootless_{version}_iphoneos-arm64.deb"
    subprocess.run(["dpkg-deb", "--root-owner-group", "-b", str(stage), str(out)],
                   check=True, capture_output=True)
    return out


def _asset_url(deb: Path, version: str) -> str:
    return f"{ASSET_BASE}/v{version}/{deb.name}"


def _parse_stanzas(text: str) -> list[dict[str, str]]:
    stanzas = []
    for block in text.strip().split("\n\n"):
        fields = {}
        key = None
        for line in block.splitlines():
            if line.startswith((" ", "\t")) and key:
                fields[key] += "\n" + line.strip()
            elif ":" in line:
                key, _, value = line.partition(":")
                key = key.strip()
                fields[key] = value.strip()
        if fields:
            stanzas.append(fields)
    return stanzas


def _release_sections(text: str) -> dict[str, list[tuple[str, int, str]]]:
    sections: dict[str, list] = {}
    current = None
    for line in text.splitlines():
        if line.endswith(":") and not line.startswith(" "):
            current = line[:-1]
            sections[current] = []
        elif line.startswith(" ") and current:
            digest, size, name = line.split()
            sections[current].append((digest, int(size), name))
    return sections


@pytest.fixture
def deb_dir(tmp_path):
    return tmp_path


def _out_docs(tmp_path) -> Path:
    return tmp_path / "eikon-source" / "docs"


def test_release_hashes_are_complete_and_correct(deb_dir, tmp_path):
    version = "0.1.0"
    deb = _make_deb(deb_dir, version)
    out = _out_docs(tmp_path)
    build_index_mod.build_index(deb, _asset_url(deb, version), out, TEMPLATES, ICONS)

    release = (out / "Release").read_text()
    fields = _parse_stanzas(release)[0]
    assert "iphoneos-arm64" in fields["Architectures"]
    assert fields.get("Components")

    sections = _release_sections(release)
    assert set(sections) >= {"MD5Sum", "SHA256"}
    for name, entries in sections.items():
        assert entries, f"{name} lists no files"
        listed = {n for _, _, n in entries}
        assert "Packages" in listed
        digest_name = {"MD5Sum": "md5", "SHA256": "sha256"}[name]
        for digest, size, filename in entries:
            target = out / filename
            assert target.is_file(), f"{filename} missing"
            data = target.read_bytes()
            assert len(data) == size
            assert hashlib.new(digest_name, data).hexdigest() == digest


@pytest.mark.parametrize("mode", ["absolute", "relative"])
def test_packages_stanza_matches_the_deb(deb_dir, tmp_path, mode):
    version = "0.1.0"
    deb = _make_deb(deb_dir, version)
    asset_url = _asset_url(deb, version)
    out = _out_docs(tmp_path)
    build_index_mod.build_index(deb, asset_url, out, TEMPLATES, ICONS, filename_mode=mode)

    text = (out / "Packages").read_text()
    stanzas = _parse_stanzas(text)
    assert len(stanzas) == 1
    stanza = stanzas[0]

    deb_bytes = deb.read_bytes()
    assert stanza["SHA256"] == hashlib.sha256(deb_bytes).hexdigest()
    assert int(stanza["Size"]) == len(deb_bytes)

    if mode == "absolute":
        assert stanza["Filename"] == asset_url
    else:
        assert stanza["Filename"] == f"debs/{deb.name}"
        copied = out / "debs" / deb.name
        assert copied.is_file()
        assert hashlib.sha256(copied.read_bytes()).hexdigest() == stanza["SHA256"]

    # The xz copy decompresses to the same stanzas.
    xz_stanzas = _parse_stanzas(lzma.decompress((out / "Packages.xz").read_bytes()).decode())
    assert xz_stanzas == stanzas


def test_a_rerun_replaces_everything(deb_dir, tmp_path):
    out = _out_docs(tmp_path)
    root = out.parent

    deb_a = _make_deb(deb_dir, "0.1.0")
    build_index_mod.build_index(deb_a, _asset_url(deb_a, "0.1.0"), out, TEMPLATES, ICONS)

    (out / "stray.txt").write_text("stray")
    sentinel = root / "sentinel.txt"
    sentinel.write_text("keep me")

    deb_b = _make_deb(deb_dir, "0.2.0")
    build_index_mod.build_index(deb_b, _asset_url(deb_b, "0.2.0"), out, TEMPLATES, ICONS)

    stanzas = _parse_stanzas((out / "Packages").read_text())
    assert len(stanzas) == 1
    assert stanzas[0]["Version"] == "0.2.0"
    assert not (out / "stray.txt").exists()
    assert sentinel.read_text() == "keep me"

    # The tree matches a fresh build into an empty directory.
    fresh = tmp_path / "fresh" / "docs"
    build_index_mod.build_index(deb_b, _asset_url(deb_b, "0.2.0"), fresh, TEMPLATES, ICONS)
    produced = {p.relative_to(out) for p in out.rglob("*") if p.is_file()}
    expected = {p.relative_to(fresh) for p in fresh.rglob("*") if p.is_file()}
    assert produced == expected


def test_a_failed_rebuild_leaves_the_previous_docs_intact(deb_dir, tmp_path):
    out = _out_docs(tmp_path)
    deb_a = _make_deb(deb_dir, "0.1.0")
    build_index_mod.build_index(deb_a, _asset_url(deb_a, "0.1.0"), out, TEMPLATES, ICONS)
    before = {p.relative_to(out): p.read_bytes() for p in out.rglob("*") if p.is_file()}

    # A rebuild that fails while staging (icons missing) must not touch out_docs.
    deb_b = _make_deb(deb_dir, "0.2.0")
    with pytest.raises(Exception):
        build_index_mod.build_index(deb_b, _asset_url(deb_b, "0.2.0"), out, TEMPLATES,
                                    tmp_path / "no-such-icons")

    after = {p.relative_to(out): p.read_bytes() for p in out.rglob("*") if p.is_file()}
    assert after == before
    stanzas = _parse_stanzas((out / "Packages").read_text())
    assert stanzas[0]["Version"] == "0.1.0"
    # No leftover staging or backup siblings.
    siblings = {p.name for p in out.parent.iterdir()}
    assert siblings == {"docs"}
