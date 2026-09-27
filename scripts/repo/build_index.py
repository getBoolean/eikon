#!/usr/bin/env python3
"""Regenerate the eikon-source docs/ tree from one deb, for the Sileo repo.

    uv run scripts/repo/build_index.py --deb PATH --asset-url URL --out DOCS_DIR
        [--templates packaging/repo] [--icons packaging/repo/icon]
        [--filename-mode absolute|relative] [--repo-readme PATH]

Only the latest version is ever in the index; history lives in GitHub Releases.
Standard library only, plus dpkg-deb (read control) and zstd (compress). See
planning/.../section-11-repo-publishing.md.
"""

from __future__ import annotations

import argparse
import email.utils
import hashlib
import html
import json
import lzma
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PAGES_BASE = "https://getboolean.github.io/eikon-source/"
GITHUB_BASE = "https://github.com/getBoolean/eikon"
PACKAGE = "com.getboolean.eikon"
ARCH = "iphoneos-arm64"
PACKAGES_FILES = ("Packages", "Packages.xz", "Packages.zst")
PLACEHOLDER = re.compile(r"@[A-Z_]+@")


class IndexBuildError(Exception):
    pass


def _run(*args: str) -> bytes:
    result = subprocess.run(args, capture_output=True)
    if result.returncode != 0:
        raise IndexBuildError(f"{' '.join(args)} failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def read_control(deb: Path) -> list[tuple[str, str]]:
    """Control fields in order; Description continuation lines kept as-is."""
    text = _run("dpkg-deb", "-f", str(deb)).decode()
    fields: list[tuple[str, str]] = []
    for line in text.splitlines():
        if line.startswith((" ", "\t")) and fields:
            key, value = fields[-1]
            fields[-1] = (key, value + "\n" + line)
        elif ":" in line:
            key, _, value = line.partition(":")
            fields.append((key.strip(), value.strip()))
    return fields


def field(fields: list[tuple[str, str]], name: str) -> str | None:
    for key, value in fields:
        if key == name:
            return value
    return None


def file_digests(path: Path) -> dict:
    md5, sha1, sha256 = hashlib.md5(), hashlib.sha1(), hashlib.sha256()
    size = 0
    with path.open("rb") as handle:
        while chunk := handle.read(1 << 20):
            size += len(chunk)
            md5.update(chunk)
            sha1.update(chunk)
            sha256.update(chunk)
    return {"size": size, "md5": md5.hexdigest(), "sha1": sha1.hexdigest(), "sha256": sha256.hexdigest()}


def packages_stanza(fields: list[tuple[str, str]], filename: str, digests: dict) -> str:
    lines = []
    for key, value in fields:
        if "\n" in value:
            head, *rest = value.split("\n")
            lines.append(f"{key}: {head}")
            lines.extend(rest)
        else:
            lines.append(f"{key}: {value}")
    lines += [
        f"Filename: {filename}",
        f"Size: {digests['size']}",
        f"MD5sum: {digests['md5']}",
        f"SHA1: {digests['sha1']}",
        f"SHA256: {digests['sha256']}",
    ]
    return "\n".join(lines) + "\n\n"


def release_text(version: str, entries: list[tuple[str, dict]]) -> str:
    date = email.utils.format_datetime(datetime.now(timezone.utc), usegmt=True)
    lines = [
        "Origin: Eikon",
        "Label: Eikon",
        "Suite: stable",
        f"Version: {version}",
        "Codename: ios",
        f"Architectures: {ARCH}",
        "Components: main",
        "Description: Eikon Sileo source",
        f"Date: {date}",
    ]
    # Sileo verifies SHA256; the MD5Sum section is included for apt-style tooling.
    for header, algo in (("MD5Sum", "md5"), ("SHA256", "sha256")):
        lines.append(f"{header}:")
        for name, digests in entries:
            lines.append(f" {digests[algo]} {digests['size']} {name}")
    return "\n".join(lines) + "\n"


def render(template_text: str, values: dict[str, str], escape) -> str:
    def replace(match: re.Match) -> str:
        token = match.group(0)[1:-1]
        if token not in values:
            return match.group(0)  # left for the leftover check to catch
        return escape(values[token])

    result = PLACEHOLDER.sub(replace, template_text)
    leftover = PLACEHOLDER.search(result)
    if leftover:
        raise IndexBuildError(f"unfilled placeholder {leftover.group(0)}")
    return result


def _description_text(raw: str) -> str:
    """Debian control Description as plain text: strip continuation indent, and
    turn Debian's ` .` blank-line markers into blank lines."""
    lines = raw.split("\n")
    normalized = [lines[0].strip()]
    for line in lines[1:]:
        stripped = line.strip()
        normalized.append("" if stripped == "." else stripped)
    return "\n".join(normalized).strip()


def _template_values(version: str, description: str) -> dict[str, str]:
    return {
        "VERSION": version,
        "DATE": datetime.now(timezone.utc).date().isoformat(),
        "DESCRIPTION": description,
        "REPO_URL": PAGES_BASE,
        "SOURCE_URL": GITHUB_BASE,
        "RELEASE_URL": f"{GITHUB_BASE}/releases/tag/v{version}",
        "LICENSE_URL": f"{GITHUB_BASE}/blob/v{version}/LICENSE",
        "NOTICES_URL": f"{GITHUB_BASE}/blob/v{version}/THIRD_PARTY_NOTICES.md",
    }


def build_index(deb: Path, asset_url: str, out_docs: Path, templates: Path, icon_src: Path,
                filename_mode: str = "absolute") -> None:
    """Rewrite out_docs entirely, keeping only the latest version. Touches nothing outside it."""
    if not deb.is_file():
        raise IndexBuildError(f"deb not found: {deb}")
    fields = read_control(deb)
    if field(fields, "Package") != PACKAGE:
        raise IndexBuildError(f"deb Package is {field(fields, 'Package')!r}, expected {PACKAGE}")
    if field(fields, "Architecture") != ARCH:
        raise IndexBuildError(f"deb Architecture is {field(fields, 'Architecture')!r}, expected {ARCH}")
    version = field(fields, "Version") or ""
    if not version:
        raise IndexBuildError("deb has no Version")

    if filename_mode == "absolute":
        if not asset_url.startswith("https://") or not asset_url.endswith(deb.name):
            raise IndexBuildError(f"asset URL must be https and end with {deb.name}: {asset_url}")
        filename = asset_url
    elif filename_mode == "relative":
        filename = f"debs/{deb.name}"
    else:
        raise IndexBuildError(f"unknown filename mode: {filename_mode}")

    if shutil.which("zstd") is None:
        raise IndexBuildError("zstd is required to write Packages.zst")

    out_docs.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(dir=out_docs.parent))
    backup = None
    swapped = False
    try:
        digests = file_digests(deb)
        stanza = packages_stanza(fields, filename, digests)
        (stage / "Packages").write_text(stanza, encoding="utf-8")
        if filename_mode == "relative":
            debs = stage / "debs"
            debs.mkdir()
            shutil.copy2(deb, debs / deb.name)

        packages_bytes = stanza.encode("utf-8")
        (stage / "Packages.xz").write_bytes(lzma.compress(packages_bytes, format=lzma.FORMAT_XZ))
        _run("zstd", "-q", "-19", "-f", "-o", str(stage / "Packages.zst"), str(stage / "Packages"))

        entries = [(name, file_digests(stage / name)) for name in PACKAGES_FILES]
        (stage / "Release").write_text(release_text(version, entries), encoding="utf-8")

        description = _description_text(field(fields, "Description") or "Eikon")
        values = _template_values(version, description)

        depiction_text = render((templates / "depiction.json.in").read_text(encoding="utf-8"),
                                 values, escape=lambda v: json.dumps(v)[1:-1])
        try:
            depiction = json.loads(depiction_text)
        except json.JSONDecodeError as error:
            raise IndexBuildError(f"rendered depiction.json is invalid: {error}") from error
        (stage / "depiction.json").write_text(json.dumps(depiction, indent=2, ensure_ascii=False) + "\n",
                                              encoding="utf-8")

        index_html = render((templates / "index.html.in").read_text(encoding="utf-8"),
                            values, escape=html.escape)
        (stage / "index.html").write_text(index_html, encoding="utf-8")

        shutil.copy2(icon_src / "icon.png", stage / "icon.png")
        shutil.copy2(icon_src / "CydiaIcon.png", stage / "CydiaIcon.png")
        (stage / ".nojekyll").write_text("")

        if out_docs.exists():
            backup = out_docs.with_name(out_docs.name + ".backup")
            if backup.exists():
                shutil.rmtree(backup)
            out_docs.rename(backup)
        stage.rename(out_docs)
        swapped = True
        stage = None
    except BaseException:
        # Restore the previous docs if we moved them aside but didn't finish the swap.
        if backup is not None and not swapped and not out_docs.exists() and backup.exists():
            backup.rename(out_docs)
        raise
    finally:
        if stage is not None and stage.exists():
            shutil.rmtree(stage)
        if swapped and backup is not None and backup.exists():
            shutil.rmtree(backup)


def render_repo_readme(templates: Path, dest: Path) -> None:
    """Render README.md.in to dest (the eikon-source root README)."""
    values = {"REPO_URL": PAGES_BASE, "SOURCE_URL": GITHUB_BASE}
    text = render((templates / "README.md.in").read_text(encoding="utf-8"), values, escape=lambda v: v)
    dest.write_text(text, encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Build the eikon-source docs/ index.")
    parser.add_argument("--deb", type=Path, required=True)
    parser.add_argument("--asset-url", required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--templates", type=Path, default=REPO_ROOT / "packaging" / "repo")
    parser.add_argument("--icons", type=Path, default=REPO_ROOT / "packaging" / "repo" / "icon")
    parser.add_argument("--filename-mode", choices=["absolute", "relative"], default="absolute")
    parser.add_argument("--repo-readme", type=Path)
    args = parser.parse_args(argv)
    try:
        build_index(args.deb, args.asset_url, args.out, args.templates, args.icons, args.filename_mode)
        if args.repo_readme:
            render_repo_readme(args.templates, args.repo_readme)
    except (IndexBuildError, OSError) as error:
        print(f"build_index.py: {error}", file=sys.stderr)
        return 1
    print(f"build_index.py: wrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
