"""Prebuilt third-party libraries, downloaded from GitHub releases of the forks.

    uv run scripts/deps.py [--repo-root PATH] COMMAND

Commands:
    check                         validate third_party/deps.toml (no network)
    fetch [names]                 download, check and unpack each pinned release asset
    verify [names]                each dependency is unpacked, unmodified, from its pin
    pin NAME --tag TAG [--asset]  pin NAME to a release: record its tag, asset and SHA-256

Assets unpack into build/deps/<name>/. Downloads come from
https://github.com/<repo>/releases/download/<tag>/<asset>, or from
$EIKON_RELEASES_URL in place of https://github.com. See third_party/README.md.
"""

from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import urllib.parse
import urllib.request
import zipfile
from dataclasses import dataclass
from pathlib import Path

MANIFEST = Path("third_party") / "deps.toml"
DEPS_DIR = Path("build") / "deps"
CACHE = ".cache"
STAMPS = ".stamps"
DEFAULT_RELEASES_URL = "https://github.com"

_PATTERNS = {
    "name": re.compile(r"^[a-z0-9][a-z0-9._-]*$"),
    "repo": re.compile(r"^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$"),
    "tag": re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$"),
    "asset": re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$"),
    "sha256": re.compile(r"^[0-9a-f]{64}$"),
}
_OPTIONAL = ("upstream",)
_TAR_SUFFIXES = (".tar", ".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.bz2", ".tbz2")
_ARCHIVE_ERRORS = (tarfile.TarError, zipfile.BadZipFile, OSError)


class DepError(Exception):
    pass


@dataclass(frozen=True)
class Dep:
    name: str
    repo: str
    tag: str
    asset: str
    sha256: str


def _asset_kind(asset: str) -> str | None:
    """"tar", "zip" or "file"; None for an archive format that can't be unpacked."""
    lower = asset.lower()
    if lower.endswith(_TAR_SUFFIXES):
        return "tar"
    if lower.endswith(".zip"):
        return "zip"
    if ".tar." in lower or lower.endswith((".tzst", ".zst", ".lz4", ".7z", ".rar")):
        return None
    return "file"


def _tables(text: str) -> list[dict]:
    try:
        data = tomllib.loads(text)
    except tomllib.TOMLDecodeError as err:
        raise DepError(f"{MANIFEST}: {err}") from err
    if set(data) - {"dep"}:
        raise DepError(f"{MANIFEST}: unknown keys {sorted(set(data) - {'dep'})}")
    entries = data.get("dep", [])
    if not isinstance(entries, list) or not all(isinstance(e, dict) for e in entries):
        raise DepError(f"{MANIFEST}: `dep` must be an array of tables ([[dep]])")
    return entries


def _parse(text: str) -> list[Dep]:
    problems: list[str] = []
    deps: list[Dep] = []
    for i, entry in enumerate(_tables(text), start=1):
        label = f"{MANIFEST} entry {i}" + (
            f" ({entry['name']})" if isinstance(entry.get("name"), str) else ""
        )
        extra = sorted(set(entry) - set(_PATTERNS) - set(_OPTIONAL))
        if extra:
            problems.append(f"{label}: unknown keys {', '.join(extra)}")
        bad = [
            key for key, pattern in _PATTERNS.items()
            if not isinstance(entry.get(key), str) or not pattern.match(entry[key])
        ]
        bad += [key for key in _OPTIONAL if key in entry and not isinstance(entry[key], str)]
        if bad:
            problems.append(f"{label}: missing or malformed {', '.join(bad)}")
            continue
        if _asset_kind(entry["asset"]) is None:
            problems.append(
                f"{label}: {entry['asset']} is an archive format this tool can't unpack; "
                "use .tar.gz, .tar.xz, .tar.bz2 or .zip"
            )
        deps.append(Dep(**{key: entry[key] for key in _PATTERNS}))

    names = [d.name for d in deps]
    for name in sorted({n for n in names if names.count(n) > 1}):
        problems.append(f"{MANIFEST}: two dependencies are named {name!r}")
    if problems:
        raise DepError("\n".join(problems))
    return deps


def _read_manifest(repo_root: Path) -> str | None:
    path = repo_root / MANIFEST
    return path.read_bytes().decode("utf-8") if path.is_file() else None


def load(repo_root: Path) -> list[Dep]:
    """Read and validate the manifest. A missing or empty manifest has no dependencies."""
    text = _read_manifest(repo_root)
    return _parse(text) if text is not None else []


def _select(deps: list[Dep], names: list[str]) -> list[Dep]:
    if not names:
        return deps
    known = {d.name: d for d in deps}
    unknown = [n for n in names if n not in known]
    if unknown:
        raise DepError(f"not in {MANIFEST}: {', '.join(unknown)}")
    return [known[n] for n in names]


def _url(repo: str, tag: str, asset: str) -> str:
    base = os.environ.get("EIKON_RELEASES_URL", DEFAULT_RELEASES_URL).rstrip("/")
    tag_q, asset_q = (urllib.parse.quote(s, safe="") for s in (tag, asset))
    return f"{base}/{repo}/releases/download/{tag_q}/{asset_q}"


def _download(url: str, dest: Path) -> str:
    """Download `url` to `dest`; return its SHA-256. Leaves nothing behind on failure."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256()
    tmp = dest.with_name(dest.name + ".part")
    received = 0
    try:
        with urllib.request.urlopen(url, timeout=60) as response, tmp.open("wb") as out:
            expected = response.headers.get("Content-Length")
            while chunk := response.read(1 << 20):
                digest.update(chunk)
                out.write(chunk)
                received += len(chunk)
        if expected is not None and expected.isdigit() and received != int(expected):
            raise DepError(f"download of {url} was truncated ({received} of {expected} bytes)")
    except (OSError, http.client.HTTPException) as err:  # URLError/HTTPError are OSErrors
        tmp.unlink(missing_ok=True)
        raise DepError(f"could not download {url}: {err}") from err
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise
    tmp.replace(dest)
    return digest.hexdigest()


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        while chunk := f.read(1 << 20):
            digest.update(chunk)
    return digest.hexdigest()


def _cache_path(repo_root: Path, sha256: str, asset: str) -> Path:
    return repo_root / DEPS_DIR / CACHE / sha256 / asset


def _cached_asset(repo_root: Path, dep: Dep) -> Path:
    """The pinned asset in the download cache, downloading it if needed."""
    cached = _cache_path(repo_root, dep.sha256, dep.asset)
    if cached.is_file() and _sha256(cached) == dep.sha256:
        return cached
    got = _download(_url(dep.repo, dep.tag, dep.asset), cached)
    if got != dep.sha256:
        cached.unlink(missing_ok=True)
        raise DepError(
            f"{dep.name}: {dep.asset} from {dep.repo} {dep.tag} has SHA-256 {got}, "
            f"but {MANIFEST} pins {dep.sha256}"
        )
    return cached


def _unpack(archive: Path, dest: Path) -> None:
    kind = _asset_kind(archive.name)
    if kind == "tar":
        with tarfile.open(archive) as tar:
            tar.extractall(dest, filter="data")
    elif kind == "zip":
        with zipfile.ZipFile(archive) as zf:
            for member in zf.namelist():
                if not (dest / member).resolve().is_relative_to(dest.resolve()):
                    raise DepError(f"member {member!r} escapes the archive")
            zf.extractall(dest)
    else:
        shutil.copy2(archive, dest / archive.name)


def _file_hashes(tree: Path) -> dict[str, str]:
    """SHA-256 of every regular file under `tree`; symlinks by their target text."""
    hashes = {}
    for path in sorted(tree.rglob("*")):
        rel = path.relative_to(tree).as_posix()
        if path.is_symlink():
            hashes[rel] = "link:" + os.readlink(path)
        elif path.is_file():
            hashes[rel] = _sha256(path)
    return hashes


def _stamp_path(repo_root: Path, name: str) -> Path:
    return repo_root / DEPS_DIR / STAMPS / name


def _pin_record(dep: Dep) -> dict[str, str]:
    return {"repo": dep.repo, "tag": dep.tag, "asset": dep.asset, "sha256": dep.sha256}


def _problem(repo_root: Path, dep: Dep) -> str | None:
    """Why build/deps/<name> doesn't match its pin, or None if it does."""
    stamp = _stamp_path(repo_root, dep.name)
    tree = repo_root / DEPS_DIR / dep.name
    try:
        record = json.loads(stamp.read_text())
    except (OSError, ValueError):
        return "not unpacked"
    if record.get("pin") != _pin_record(dep):
        return "unpacked from a different release"
    if not tree.is_dir() or tree.is_symlink() or _file_hashes(tree) != record.get("files"):
        return "files changed since it was unpacked"
    return None


def _prune(repo_root: Path, deps: list[Dep]) -> None:
    """Remove trees, stamps and staging directories that no manifest entry owns."""
    deps_dir = repo_root / DEPS_DIR
    wanted = {d.name for d in deps}
    for path in sorted(deps_dir.iterdir()) if deps_dir.is_dir() else []:
        if path.name in (CACHE, STAMPS):
            continue
        if path.name.startswith(".") or path.name not in wanted:
            _remove(path)
            print(f"removed {path.relative_to(repo_root)}")
    stamps = deps_dir / STAMPS
    for stamp in sorted(stamps.iterdir()) if stamps.is_dir() else []:
        if stamp.name not in wanted:
            stamp.unlink()


def _remove(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path)


def _install(repo_root: Path, dep: Dep, archive: Path) -> None:
    """Unpack into staging, then swap it into build/deps/<name>. The stamp is
    removed first and written last, so an interrupted swap never verifies."""
    deps_dir = repo_root / DEPS_DIR
    stamp = _stamp_path(repo_root, dep.name)
    final = deps_dir / dep.name
    staging = Path(tempfile.mkdtemp(prefix=f".staging-{dep.name}-", dir=deps_dir))
    trash = None
    try:
        _unpack(archive, staging)
        files = _file_hashes(staging)
        stamp.unlink(missing_ok=True)
        if final.exists() or final.is_symlink():
            trash = deps_dir / f".trash-{dep.name}-{os.getpid()}"
            final.rename(trash)
        staging.rename(final)
        stamp.parent.mkdir(parents=True, exist_ok=True)
        tmp = stamp.with_name(stamp.name + ".tmp")
        tmp.write_text(json.dumps({"pin": _pin_record(dep), "files": files}, indent=1))
        tmp.replace(stamp)
    except DepError as err:
        raise DepError(f"{dep.name}: {err}") from err
    except _ARCHIVE_ERRORS as err:
        raise DepError(f"{dep.name}: could not unpack {dep.asset}: {err}") from err
    finally:
        for leftover in (staging, trash):
            if leftover is not None and (leftover.exists() or leftover.is_symlink()):
                _remove(leftover)


def fetch(repo_root: Path, names: list[str]) -> None:
    """Download, check and unpack each pinned asset into build/deps/<name>/.
    A dependency that already matches its pin is left alone. Fetching every
    dependency also removes directories no manifest entry owns."""
    deps = load(repo_root)
    (repo_root / DEPS_DIR).mkdir(parents=True, exist_ok=True)
    if not names:
        _prune(repo_root, deps)
    for dep in _select(deps, names):
        if _problem(repo_root, dep) is None:
            print(f"{dep.name}: up to date ({dep.tag})")
            continue
        _install(repo_root, dep, _cached_asset(repo_root, dep))
        print(f"{dep.name}: unpacked {dep.asset} from {dep.repo} {dep.tag}")


def verify(repo_root: Path, names: list[str]) -> None:
    """Every dependency is unpacked, unmodified, from its pinned asset, and
    build/deps holds nothing else."""
    deps = load(repo_root)
    problems = [
        f"{dep.name}: {why}" for dep in _select(deps, names)
        if (why := _problem(repo_root, dep)) is not None
    ]
    deps_dir = repo_root / DEPS_DIR
    if not names and deps_dir.is_dir():
        wanted = {d.name for d in deps}
        problems += [
            f"{p.name}: in {DEPS_DIR} but not in {MANIFEST}"
            for p in sorted(deps_dir.iterdir())
            if not p.name.startswith(".") and p.name not in wanted
        ]
    if problems:
        raise DepError("\n".join(problems) + "\nrun `make fetch-deps`")
    print("all dependencies match their pins")


def pin(repo_root: Path, name: str, tag: str, asset: str | None) -> None:
    """Point NAME at release TAG (and ASSET, if given), recording the asset's SHA-256."""
    text = _read_manifest(repo_root)
    deps = _parse(text) if text is not None else []
    (old,) = _select(deps, [name])
    asset = asset or old.asset
    for key, value in (("tag", tag), ("asset", asset)):
        if not _PATTERNS[key].match(value):
            raise DepError(f"{name}: malformed {key} {value!r}")
    if _asset_kind(asset) is None:
        raise DepError(f"{name}: {asset} is an archive format this tool can't unpack")

    with tempfile.TemporaryDirectory() as tmp:
        sha = _download(_url(old.repo, tag, asset), Path(tmp) / asset)
        if (tag, asset) == (old.tag, old.asset) and sha != old.sha256:
            raise DepError(
                f"{name}: release {tag} now has a different {asset} than the pinned one. "
                "A pinned release must never be replaced; publish a new tag instead."
            )
        cached = _cache_path(repo_root, sha, asset)
        cached.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(Path(tmp) / asset, cached)

    # Rewrite only this dependency's tag, asset and sha256 values, then check that
    # the parsed result differs from the old manifest in exactly those values.
    tables = re.split(r"(?m)^(?=\[\[dep\]\])", text)
    name_re = re.compile(rf'(?m)^[ \t]*name[ \t]*=[ \t]*"{re.escape(name)}"[ \t]*(#.*)?$')
    hits = [i for i, t in enumerate(tables) if name_re.search(t)]
    if len(hits) != 1:
        raise DepError(f"{name}: could not find its table in {MANIFEST}")
    table = tables[hits[0]]
    new_values = {"tag": tag, "asset": asset, "sha256": sha}
    for key, value in new_values.items():
        line_re = re.compile(rf'(?m)^([ \t]*{key}[ \t]*=[ \t]*")[^"\r\n]*(")')
        table, count = line_re.subn(lambda m, v=value: f"{m.group(1)}{v}{m.group(2)}", table)
        if count != 1:
            raise DepError(f"{name}: could not find its {key} line in {MANIFEST}")
    tables[hits[0]] = table
    new_text = "".join(tables)
    expected = [({**t, **new_values} if t.get("name") == name else t) for t in _tables(text)]
    if _tables(new_text) != expected:
        raise DepError(f"{name}: rewriting {MANIFEST} would change more than this pin; edit it by hand")
    _parse(new_text)

    manifest = repo_root / MANIFEST
    tmp_manifest = manifest.with_name(manifest.name + ".tmp")
    tmp_manifest.write_bytes(new_text.encode("utf-8"))
    tmp_manifest.replace(manifest)
    print(f"{name}: pinned {old.repo} {tag} {asset} ({sha})")


def _default_root() -> Path:
    for start in (Path(__file__).resolve().parent, Path.cwd()):
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"], cwd=start, capture_output=True, text=True
        )
        if result.returncode == 0:
            return Path(result.stdout.strip())
    raise DepError("not inside a git repository; pass --repo-root")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo-root", type=Path, help="Eikon checkout (default: git top-level)")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("check")
    for command in ("fetch", "verify"):
        sub.add_parser(command).add_argument("names", nargs="*")
    pin_parser = sub.add_parser("pin")
    pin_parser.add_argument("name")
    pin_parser.add_argument("--tag", required=True)
    pin_parser.add_argument("--asset")
    args = parser.parse_args(argv)
    try:
        root = (args.repo_root or _default_root()).resolve()
        if args.command == "check":
            print(f"{MANIFEST}: {len(load(root))} dependencies, valid")
        elif args.command == "fetch":
            fetch(root, args.names)
        elif args.command == "verify":
            verify(root, args.names)
        else:
            pin(root, args.name, args.tag, args.asset)
    except DepError as err:
        print(f"deps.py: {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
