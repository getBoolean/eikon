"""Apply local patches to the third-party submodules, or restore them to their pins.

    uv run scripts/apply_patches.py [--repo-root PATH] apply   [names...]
    uv run scripts/apply_patches.py [--repo-root PATH] restore [names...]

Patches live in patches/<name>/NNNN-*.patch and are applied in lexical order
with `git apply`, to the working tree only. A submodule's HEAD never moves and
the superproject never records a patched commit. See third_party/README.md.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


class PatchError(Exception):
    pass


@dataclass(frozen=True)
class Submodule:
    name: str
    path: str  # relative to the superproject root


# Variables that would point git at a repository other than the one found from
# cwd (set inside hooks, `git submodule foreach` and some wrappers).
_REPO_VARS = (
    "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX",
    "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
)
_ENV = {k: v for k, v in os.environ.items() if k not in _REPO_VARS}


def _git(cwd: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(["git", *args], cwd=cwd, env=_ENV, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise PatchError(f"git {' '.join(args)} failed in {cwd}:\n{result.stderr.strip()}")
    return result


def _submodules(repo_root: Path) -> list[Submodule]:
    if not (repo_root / ".gitmodules").is_file():
        return []
    result = _git(
        repo_root, "config", "-f", ".gitmodules", "--get-regexp", r"^submodule\..*\.path$",
        check=False,
    )
    if result.returncode not in (0, 1):  # 1 means no submodule paths
        raise PatchError(f"could not read .gitmodules:\n{result.stderr.strip()}")
    subs: dict[str, Submodule] = {}
    for line in result.stdout.splitlines():
        _, _, path = line.partition(" ")
        path = path.strip()
        parts = Path(path).parts
        if len(parts) != 2 or parts[0] != "third_party":
            raise PatchError(f"submodule path {path!r} is not third_party/<name>")
        if parts[1] in subs:
            raise PatchError(f"two submodules are named {parts[1]!r}")
        subs[parts[1]] = Submodule(name=parts[1], path=path)
    return sorted(subs.values(), key=lambda s: s.name)


def _select(repo_root: Path, components: list[str] | None, *, check_orphans: bool) -> list[Submodule]:
    subs = _submodules(repo_root)
    known = {s.name: s for s in subs}
    if components:
        unknown = [c for c in components if c not in known]
        if unknown:
            raise PatchError(f"not a known submodule: {', '.join(unknown)}")
        return [known[c] for c in components]
    if check_orphans:
        patches = repo_root / "patches"
        orphans = sorted(
            d.name for d in patches.iterdir() if d.is_dir() and d.name not in known
        ) if patches.is_dir() else []
        if orphans:
            raise PatchError(
                f"patches/ has directories with no matching submodule: {', '.join(orphans)}"
            )
    return subs


def _pin(repo_root: Path, sub: Submodule) -> str:
    """The pinned commit, from the superproject's gitlink."""
    out = _git(repo_root, "ls-tree", "HEAD", "--", sub.path).stdout.split()
    if len(out) < 3 or out[1] != "commit":
        raise PatchError(f"{sub.name}: no gitlink for {sub.path} in HEAD")
    return out[2]


def _reset_to_pin(repo_root: Path, sub: Submodule) -> None:
    sha = _pin(repo_root, sub)
    work = repo_root / sub.path
    if not (work / ".git").exists():
        _git(repo_root, "submodule", "update", "--init", "--", sub.path)
    # Every later command runs in `work`; make sure that is the submodule's own
    # repository, not a plain directory of the superproject.
    top = _git(work, "rev-parse", "--show-toplevel", check=False) if work.is_dir() else None
    if top is None or top.returncode != 0 or Path(top.stdout.strip()).resolve() != work.resolve():
        raise PatchError(f"{sub.name}: {sub.path} is not a checked-out submodule")

    def has_pin() -> bool:
        return _git(work, "cat-file", "-e", f"{sha}^{{commit}}", check=False).returncode == 0

    if not has_pin():
        # Not every server lets clients fetch an unadvertised commit by SHA.
        if _git(work, "fetch", "--quiet", "origin", sha, check=False).returncode != 0:
            _git(work, "fetch", "--quiet", "--tags", "origin")
        if not has_pin():
            raise PatchError(f"{sub.name}: pinned commit {sha} is not available from origin")
    _git(work, "checkout", "--quiet", "--detach", sha)
    _git(work, "reset", "--quiet", "--hard", sha)
    _git(work, "clean", "-ffdxq")


def apply_all(repo_root: Path, components: list[str] | None = None) -> None:
    """For each submodule (or the named ones): reset it to the commit pinned by the
    superproject's gitlink with a clean working tree, then apply
    patches/<name>/*.patch in lexical order with `git apply --check` and `git apply`.
    Running it twice yields the same tree. A patch that fails aborts with the
    component and patch name, and the submodule is left reset to its pin."""
    for sub in _select(repo_root, components, check_orphans=not components):
        _reset_to_pin(repo_root, sub)
        patch_dir = repo_root / "patches" / sub.name
        files = sorted(patch_dir.iterdir()) if patch_dir.is_dir() else []
        stray = [f.name for f in files if f.suffix != ".patch" or not f.is_file()]
        if stray:
            raise PatchError(f"{sub.name}: not a .patch file in {patch_dir}: {', '.join(stray)}")
        work = repo_root / sub.path
        for patch in files:
            for args in (("apply", "--check", str(patch)), ("apply", str(patch))):
                result = _git(work, *args, check=False)
                if result.returncode != 0:
                    message = f"{sub.name}: patch {patch.name} does not apply"
                    try:
                        _reset_to_pin(repo_root, sub)
                    except PatchError as reset_err:
                        raise PatchError(
                            f"{message}, and resetting to the pin also failed.\n"
                            f"{result.stderr.strip()}\n{reset_err}"
                        ) from reset_err
                    raise PatchError(
                        f"{message}; {sub.name} is reset to its pin.\n{result.stderr.strip()}"
                    )
        print(f"{sub.name}: {len(files)} patch(es) applied")


def restore_all(repo_root: Path, components: list[str] | None = None) -> None:
    """Reset submodules to their pinned commits with clean working trees (make unpatch)."""
    for sub in _select(repo_root, components, check_orphans=False):
        _reset_to_pin(repo_root, sub)
        print(f"{sub.name}: restored to its pin")


def _default_root() -> Path:
    for start in (Path(__file__).resolve().parent, Path.cwd()):
        result = _git(start, "rev-parse", "--show-toplevel", check=False)
        if result.returncode == 0:
            return Path(result.stdout.strip())
    raise PatchError("not inside a git repository; pass --repo-root")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo-root", type=Path, help="superproject root (default: git top-level)")
    parser.add_argument("command", choices=["apply", "restore"])
    parser.add_argument("names", nargs="*", help="component names (default: all)")
    args = parser.parse_args(argv)
    try:
        root = (args.repo_root or _default_root()).resolve()
        if args.command == "apply":
            apply_all(root, args.names or None)
        else:
            restore_all(root, args.names or None)
    except PatchError as err:
        print(f"apply_patches.py: {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
