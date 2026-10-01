"""Third-party credits: the guard, the shipped notices and the in-app acknowledgements.

    uv run scripts/credits.py check
    uv run scripts/credits.py notices [--write]
    uv run scripts/credits.py app-json <out>

Every dependency in third_party/deps.toml needs a [[component]] entry in
third_party/credits.toml. Its license files are committed under
third_party/notices/<dep>/. Run from the repo root. See third_party/README.md.

The in-app acknowledgements start with Eikon's own entry; every entry carries `isApp`.
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import sys
import tomllib
from pathlib import Path, PurePosixPath

CREDITS = Path("third_party") / "credits.toml"
NOTICES_DIR = Path("third_party") / "notices"
NOTICES_FILE = Path("THIRD_PARTY_NOTICES.md")
LICENSES_DIR = Path("licenses")
EIKON_URL = "https://github.com/getBoolean/eikon"
EIKON_LICENSE = "GPL-3.0-or-later"
VERSION_FILE = Path("VERSION")

_REQUIRED = {"name": str, "dep": str, "url": str, "license": str, "license_files": list}
_NESTED_REQUIRED = {"path": str, "license": str, "license_files": list}
_SPDX_OPERATORS = {"AND", "OR", "WITH"}


def _load_deps_module():
    if "eikon_deps" in sys.modules:
        return sys.modules["eikon_deps"]
    spec = importlib.util.spec_from_file_location("eikon_deps", Path(__file__).with_name("deps.py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules["eikon_deps"] = module  # dataclasses look their module up here
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules["eikon_deps"]
        raise
    return module


_deps = _load_deps_module()


def _label(component: dict, index: int) -> str:
    name = component.get("name") if isinstance(component, dict) else None
    return f"component {name!r}" if isinstance(name, str) else f"component {index}"


def load_manifest(repo_root: Path) -> tuple[list[dict], list[str]]:
    """Parse third_party/credits.toml. Return (components, problems). A missing file or
    empty manifest gives no components. Bad TOML or a missing or ill-typed key becomes
    a problem naming the component, not an exception."""
    path = repo_root / CREDITS
    if not path.is_file():
        return [], []
    try:
        data = tomllib.loads(path.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as err:
        return [], [f"{CREDITS}: {err}"]
    if set(data) - {"component"}:
        return [], [f"{CREDITS}: unknown keys {sorted(set(data) - {'component'})}"]
    entries = data.get("component", [])
    if not isinstance(entries, list):
        return [], [f"{CREDITS}: `component` must be an array of tables"]

    components, problems = [], []
    for i, entry in enumerate(entries, start=1):
        label = _label(entry, i)
        if not isinstance(entry, dict):
            problems.append(f"{CREDITS}: {label} is not a table")
            continue
        bad = [k for k, t in _REQUIRED.items() if not isinstance(entry.get(k), t)]
        extra = sorted(set(entry) - set(_REQUIRED) - {"nested"})
        nested = entry.get("nested", [])
        if not isinstance(nested, list) or not all(isinstance(n, dict) for n in nested):
            bad.append("nested")
            nested = []
        for j, part in enumerate(nested, start=1):
            bad += [f"nested[{j}].{k}" for k, t in _NESTED_REQUIRED.items() if not isinstance(part.get(k), t)]
            extra += [f"nested[{j}].{k}" for k in sorted(set(part) - set(_NESTED_REQUIRED))]
        for key in ("license_files",):
            if isinstance(entry.get(key), list) and not all(isinstance(f, str) for f in entry[key]):
                bad.append(key)
        for j, part in enumerate(nested, start=1):
            files = part.get("license_files")
            if isinstance(files, list) and not all(isinstance(f, str) for f in files):
                bad.append(f"nested[{j}].license_files")
        # Every part that ships needs a license and at least one license text.
        for prefix, table in [("", entry)] + [(f"nested[{j}].", n) for j, n in enumerate(nested, start=1)]:
            if isinstance(table.get("license"), str) and not spdx_ids(table["license"]):
                bad.append(f"{prefix}license (empty)")
            if isinstance(table.get("license_files"), list) and not table["license_files"]:
                bad.append(f"{prefix}license_files (empty)")
        if bad:
            problems.append(f"{CREDITS}: {label}: missing or ill-typed {', '.join(bad)}")
        if extra:
            problems.append(f"{CREDITS}: {label}: unknown keys {', '.join(extra)}")
        if not bad and not extra:
            components.append(entry)
    return components, problems


def spdx_ids(expression: str) -> set[str]:
    """License and exception ids in an SPDX expression (not the full grammar)."""
    return {t for t in re.split(r"[\s()]+", expression) if t and t.upper() not in _SPDX_OPERATORS}


def _safe_relative(value: str) -> PurePosixPath | None:
    """`value` as a relative path with no '..' parts, or None if it isn't one."""
    path = PurePosixPath(value)
    if not value or path.is_absolute() or ".." in path.parts or value.startswith("~"):
        return None
    return path


def _license_paths(component: dict) -> list[tuple[str, PurePosixPath | None]]:
    """(label, path relative to the component's notices dir) for every license file."""
    out = [(str(_safe_relative(f) or f), _safe_relative(f)) for f in component["license_files"]]
    for part in component.get("nested", []):
        base = _safe_relative(part["path"])
        for f in part["license_files"]:
            rel = _safe_relative(f)
            joined = base / rel if base is not None and rel is not None else None
            out.append((str(joined) if joined is not None else f"{part['path']}/{f}", joined))
    return out


def _license_file(repo_root: Path, dep: str, rel: PurePosixPath | None) -> Path | None:
    """The license file, if it is a regular file (not a symlink) inside
    third_party/notices/<dep>/; otherwise None."""
    if rel is None:
        return None
    base = (repo_root / NOTICES_DIR / dep).resolve()
    path = repo_root / NOTICES_DIR / dep / rel
    if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(base):
        return None
    return path


def _read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8").replace("\r\n", "\n").rstrip("\n") + "\n"


def _load_deps(repo_root: Path) -> tuple[dict, list[str]]:
    try:
        return {d.name: d for d in _deps.load(repo_root)}, []
    except _deps.DepError as err:
        return {}, [str(err)]


def check(repo_root: Path) -> list[str]:
    """Problems, one line each, naming the offending dependency, path or id. Empty means pass."""
    components, problems = load_manifest(repo_root)
    deps, dep_problems = _load_deps(repo_root)
    problems += dep_problems

    credited: dict[str, int] = {}
    for component in components:
        dep = component["dep"]
        credited[dep] = credited.get(dep, 0) + 1
        if dep not in deps:
            problems.append(f"{CREDITS}: {component['name']!r} credits {dep!r}, which is not in third_party/deps.toml")
        notices = repo_root / NOTICES_DIR / dep
        for label, rel in _license_paths(component):
            if rel is None:
                problems.append(f"{CREDITS}: {dep}: license path {label!r} must be relative, without '..'")
            elif _license_file(repo_root, dep, rel) is None:
                problems.append(f"{dep}: license file {NOTICES_DIR / dep / rel} is missing, or is a symlink")
        expressions = [component["license"]] + [p["license"] for p in component.get("nested", [])]
        for spdx in sorted(set().union(*(spdx_ids(e) for e in expressions))):
            if not (repo_root / LICENSES_DIR / f"{spdx}.txt").is_file():
                problems.append(f"{dep}: no license text {LICENSES_DIR / (spdx + '.txt')} for {spdx}")
    for dep, count in credited.items():
        if count > 1:
            problems.append(f"{CREDITS}: {dep} is credited {count} times")
    for dep in deps:
        if dep not in credited:
            problems.append(f"{dep}: in third_party/deps.toml but has no entry in {CREDITS}")

    notices_dir = repo_root / NOTICES_DIR
    for orphan in sorted(p.name for p in notices_dir.iterdir() if p.is_dir()) if notices_dir.is_dir() else []:
        if orphan not in credited:
            problems.append(f"{NOTICES_DIR / orphan}: no component in {CREDITS} uses it")

    if not problems:
        current = repo_root / NOTICES_FILE
        if not current.is_file() or current.read_text(encoding="utf-8") != generate_notices(repo_root):
            problems.append(f"{NOTICES_FILE} is out of date; run `uv run scripts/credits.py notices --write`")
    return problems


def _revision(dep) -> str:
    return f"{dep.repo} release {dep.tag}"


def _release_url(dep) -> str:
    return f"https://github.com/{dep.repo}/releases/tag/{dep.tag}"


def _license_texts(repo_root: Path, component: dict) -> list[tuple[str, str]]:
    dep = component["dep"]
    return [(label, _read_text(_license_file(repo_root, dep, rel))) for label, rel in _license_paths(component)]


def _require_clean(repo_root: Path) -> tuple[list[dict], dict]:
    components, problems = load_manifest(repo_root)
    deps, dep_problems = _load_deps(repo_root)
    problems += dep_problems
    problems += [f"{c['dep']}: not in third_party/deps.toml" for c in components if c["dep"] not in deps]
    for c in components:
        for label, rel in _license_paths(c):
            if _license_file(repo_root, c["dep"], rel) is None:
                problems.append(f"{c['dep']}: license file {label!r} is missing or outside {NOTICES_DIR / c['dep']}")
    if problems:
        raise ValueError("\n".join(problems))
    return components, deps


def generate_notices(repo_root: Path) -> str:
    """Markdown: Eikon itself, then each component in manifest order with its release,
    SPDX expression and full license texts, and where corresponding source is published."""
    components, deps = _require_clean(repo_root)
    lines = [
        "# Third-party notices",
        "",
        "<!-- Generated by scripts/credits.py from third_party/credits.toml. Do not edit. -->",
        "",
        "## Eikon",
        "",
        f"Eikon is licensed under GPL-3.0-or-later. Source: {EIKON_URL}. The full license text is in `LICENSE`.",
        "",
        "## Corresponding source",
        "",
        "The corresponding source for Eikon is the eikon repository at the release tag of the build. "
        "Each third-party library below is built from its fork at the release tag listed with it; "
        "that tag is where its corresponding source is published.",
        "",
        "## Third-party components",
        "",
    ]
    if not components:
        lines += ["Eikon includes no third-party components.", ""]
    for component in components:
        dep = deps[component["dep"]]
        lines += [
            f"### {component['name']}",
            "",
            f"- Upstream: {component['url']}",
            f"- Built from: {_revision(dep)} ({_release_url(dep)})",
            f"- License: {component['license']}",
        ]
        lines += [f"- {part['path']}: {part['license']}" for part in component.get("nested", [])]
        lines.append("")
        for label, text in _license_texts(repo_root, component):
            lines += [f"#### {label}", "", "```text", text.rstrip("\n"), "```", ""]
    return "\n".join(lines).rstrip("\n") + "\n"


def _app_entry(repo_root: Path) -> tuple[dict | None, list[str]]:
    """Eikon's own acknowledgements entry (isApp: true), or the problems that prevent it:
    a missing or empty VERSION, or a missing licenses/GPL-3.0-or-later.txt."""
    problems = []
    version_path = repo_root / VERSION_FILE
    license_path = repo_root / LICENSES_DIR / f"{EIKON_LICENSE}.txt"
    try:
        version = version_path.read_text(encoding="utf-8").strip() if version_path.is_file() else ""
    except OSError as err:
        version = ""
        problems.append(f"{VERSION_FILE}: {err.strerror}")
    else:
        if not version:
            problems.append(f"{VERSION_FILE}: missing or empty")
    try:
        license_text = _read_text(license_path) if license_path.is_file() else None
    except OSError as err:
        license_text = None
        problems.append(f"{LICENSES_DIR / license_path.name}: {err.strerror}")
    else:
        if license_text is None:
            problems.append(f"{LICENSES_DIR / license_path.name}: missing")
    if problems:
        return None, problems
    return {
        "name": "Eikon",
        "url": EIKON_URL,
        "revision": f"getBoolean/eikon {version}",
        "license": EIKON_LICENSE,
        "licenseText": license_text,
        "isApp": True,
    }, []


def generate_app_json(repo_root: Path, out: Path) -> None:
    """Write the acknowledgements JSON: Eikon's own entry first, then one object per
    component in manifest order. Every entry carries `isApp`."""
    app, problems = _app_entry(repo_root)
    try:
        components, deps = _require_clean(repo_root)
    except ValueError as err:
        raise ValueError("\n".join(problems + [str(err)])) from None
    if problems:
        raise ValueError("\n".join(problems))
    items = [app] + [
        {
            "name": c["name"],
            "url": c["url"],
            "revision": _revision(deps[c["dep"]]),
            "license": c["license"],
            "licenseText": "\n".join(f"{label}\n\n{text}" for label, text in _license_texts(repo_root, c)),
            "isApp": False,
        }
        for c in components
    ]
    out.parent.mkdir(parents=True, exist_ok=True)
    _write_atomic(out, json.dumps(items, indent=2, sort_keys=True, ensure_ascii=False) + "\n")


def _write_atomic(path: Path, text: str) -> None:
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        tmp.write_text(text, encoding="utf-8")
        tmp.replace(path)
    finally:
        tmp.unlink(missing_ok=True)


USAGE = "usage: credits.py check | notices [--write] | app-json <out>"


def main(argv: list[str]) -> int:
    root = Path.cwd()
    try:
        match argv:
            case ["check"]:
                problems = check(root)
                for p in problems:
                    print(p, file=sys.stderr)
                return 1 if problems else 0
            case ["notices"]:
                sys.stdout.write(generate_notices(root))
                return 0
            case ["notices", "--write"]:
                _write_atomic(root / NOTICES_FILE, generate_notices(root))
                print(f"Wrote {NOTICES_FILE}")
                return 0
            case ["app-json", out]:
                generate_app_json(root, Path(out))
                print(f"Wrote {out}")
                return 0
            case _:
                print(USAGE, file=sys.stderr)
                return 2
    except ValueError as err:
        print(err, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
