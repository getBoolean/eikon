diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml
index 6379cb2..18cf8ae 100644
--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -27,6 +27,8 @@ jobs:
       - uses: astral-sh/setup-uv@c18668ad3cf93ea998bef934396af7bb5c839dc7 # v10.2.0
       - name: Script tests
         run: uv run pytest tests/
+      - name: Dependency manifest check
+        run: uv run scripts/deps.py check
       - name: Version check
         run: scripts/version.sh --check
 
diff --git a/Makefile b/Makefile
index 244b2e4..3c28527 100644
--- a/Makefile
+++ b/Makefile
@@ -9,12 +9,12 @@ stub = echo "$@: not implemented yet (section $(1))" >&2; exit 1
 
 .PHONY: help doctor bootstrap version generated project check \
 	test test-swift test-scripts archive ipa tipa deb package verify all \
-	publish apply-patches unpatch clean
+	publish fetch-deps verify-deps pin-dep clean
 
 help:
 	@echo "Targets: doctor bootstrap version generated project check test test-swift"
 	@echo "         test-scripts archive ipa tipa deb package verify all publish"
-	@echo "         apply-patches unpatch clean"
+	@echo "         fetch-deps verify-deps pin-dep NAME=<name> TAG=<tag> [ASSET=<asset>] clean"
 
 doctor:
 	@scripts/doctor.sh
@@ -43,6 +43,7 @@ check:
 	else \
 		echo "check: skipping credits check, scripts/credits.py not added yet (section 04)"; \
 	fi
+	@uv run scripts/deps.py check
 	@scripts/version.sh --check
 
 test: test-swift test-scripts
@@ -70,11 +71,16 @@ all: check test archive package verify
 publish:
 	@$(call stub,11)
 
-apply-patches:
-	@uv run scripts/apply_patches.py apply
+# Prebuilt libraries from the forks' GitHub releases (see third_party/README.md).
+fetch-deps:
+	@uv run scripts/deps.py fetch
 
-unpatch:
-	@uv run scripts/apply_patches.py restore
+verify-deps:
+	@uv run scripts/deps.py verify
+
+pin-dep:
+	@test -n "$(NAME)" -a -n "$(TAG)" || { echo "usage: make pin-dep NAME=<name> TAG=<tag> [ASSET=<asset>]" >&2; exit 1; }
+	@uv run scripts/deps.py pin "$(NAME)" --tag "$(TAG)" $(if $(ASSET),--asset "$(ASSET)")
 
 clean:
 	rm -rf build dist
diff --git a/scripts/apply_patches.py b/scripts/apply_patches.py
deleted file mode 100644
index fdc6f3a..0000000
--- a/scripts/apply_patches.py
+++ /dev/null
@@ -1,188 +0,0 @@
-"""Apply local patches to the third-party submodules, or restore them to their pins.
-
-    uv run scripts/apply_patches.py [--repo-root PATH] apply   [names...]
-    uv run scripts/apply_patches.py [--repo-root PATH] restore [names...]
-
-Patches live in patches/<name>/NNNN-*.patch and are applied in lexical order
-with `git apply`, to the working tree only. A submodule's HEAD never moves and
-the superproject never records a patched commit. See third_party/README.md.
-"""
-
-from __future__ import annotations
-
-import argparse
-import os
-import subprocess
-import sys
-from dataclasses import dataclass
-from pathlib import Path
-
-
-class PatchError(Exception):
-    pass
-
-
-@dataclass(frozen=True)
-class Submodule:
-    name: str
-    path: str  # relative to the superproject root
-
-
-# Variables that would point git at a repository other than the one found from
-# cwd (set inside hooks, `git submodule foreach` and some wrappers).
-_REPO_VARS = (
-    "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX",
-    "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
-)
-_ENV = {k: v for k, v in os.environ.items() if k not in _REPO_VARS}
-
-
-def _git(cwd: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
-    result = subprocess.run(["git", *args], cwd=cwd, env=_ENV, capture_output=True, text=True)
-    if check and result.returncode != 0:
-        raise PatchError(f"git {' '.join(args)} failed in {cwd}:\n{result.stderr.strip()}")
-    return result
-
-
-def _submodules(repo_root: Path) -> list[Submodule]:
-    if not (repo_root / ".gitmodules").is_file():
-        return []
-    result = _git(
-        repo_root, "config", "-f", ".gitmodules", "--get-regexp", r"^submodule\..*\.path$",
-        check=False,
-    )
-    if result.returncode not in (0, 1):  # 1 means no submodule paths
-        raise PatchError(f"could not read .gitmodules:\n{result.stderr.strip()}")
-    subs: dict[str, Submodule] = {}
-    for line in result.stdout.splitlines():
-        _, _, path = line.partition(" ")
-        path = path.strip()
-        parts = Path(path).parts
-        if len(parts) != 2 or parts[0] != "third_party":
-            raise PatchError(f"submodule path {path!r} is not third_party/<name>")
-        if parts[1] in subs:
-            raise PatchError(f"two submodules are named {parts[1]!r}")
-        subs[parts[1]] = Submodule(name=parts[1], path=path)
-    return sorted(subs.values(), key=lambda s: s.name)
-
-
-def _select(repo_root: Path, components: list[str] | None, *, check_orphans: bool) -> list[Submodule]:
-    subs = _submodules(repo_root)
-    known = {s.name: s for s in subs}
-    if components:
-        unknown = [c for c in components if c not in known]
-        if unknown:
-            raise PatchError(f"not a known submodule: {', '.join(unknown)}")
-        return [known[c] for c in components]
-    if check_orphans:
-        patches = repo_root / "patches"
-        orphans = sorted(
-            d.name for d in patches.iterdir() if d.is_dir() and d.name not in known
-        ) if patches.is_dir() else []
-        if orphans:
-            raise PatchError(
-                f"patches/ has directories with no matching submodule: {', '.join(orphans)}"
-            )
-    return subs
-
-
-def _pin(repo_root: Path, sub: Submodule) -> str:
-    """The pinned commit, from the superproject's gitlink."""
-    out = _git(repo_root, "ls-tree", "HEAD", "--", sub.path).stdout.split()
-    if len(out) < 3 or out[1] != "commit":
-        raise PatchError(f"{sub.name}: no gitlink for {sub.path} in HEAD")
-    return out[2]
-
-
-def _reset_to_pin(repo_root: Path, sub: Submodule) -> None:
-    sha = _pin(repo_root, sub)
-    work = repo_root / sub.path
-    if not (work / ".git").exists():
-        _git(repo_root, "submodule", "update", "--init", "--", sub.path)
-    # Every later command runs in `work`; make sure that is the submodule's own
-    # repository, not a plain directory of the superproject.
-    top = _git(work, "rev-parse", "--show-toplevel", check=False) if work.is_dir() else None
-    if top is None or top.returncode != 0 or Path(top.stdout.strip()).resolve() != work.resolve():
-        raise PatchError(f"{sub.name}: {sub.path} is not a checked-out submodule")
-
-    def has_pin() -> bool:
-        return _git(work, "cat-file", "-e", f"{sha}^{{commit}}", check=False).returncode == 0
-
-    if not has_pin():
-        # Not every server lets clients fetch an unadvertised commit by SHA.
-        if _git(work, "fetch", "--quiet", "origin", sha, check=False).returncode != 0:
-            _git(work, "fetch", "--quiet", "--tags", "origin")
-        if not has_pin():
-            raise PatchError(f"{sub.name}: pinned commit {sha} is not available from origin")
-    _git(work, "checkout", "--quiet", "--detach", sha)
-    _git(work, "reset", "--quiet", "--hard", sha)
-    _git(work, "clean", "-ffdxq")
-
-
-def apply_all(repo_root: Path, components: list[str] | None = None) -> None:
-    """For each submodule (or the named ones): reset it to the commit pinned by the
-    superproject's gitlink with a clean working tree, then apply
-    patches/<name>/*.patch in lexical order with `git apply --check` and `git apply`.
-    Running it twice yields the same tree. A patch that fails aborts with the
-    component and patch name, and the submodule is left reset to its pin."""
-    for sub in _select(repo_root, components, check_orphans=not components):
-        _reset_to_pin(repo_root, sub)
-        patch_dir = repo_root / "patches" / sub.name
-        files = sorted(patch_dir.iterdir()) if patch_dir.is_dir() else []
-        stray = [f.name for f in files if f.suffix != ".patch" or not f.is_file()]
-        if stray:
-            raise PatchError(f"{sub.name}: not a .patch file in {patch_dir}: {', '.join(stray)}")
-        work = repo_root / sub.path
-        for patch in files:
-            for args in (("apply", "--check", str(patch)), ("apply", str(patch))):
-                result = _git(work, *args, check=False)
-                if result.returncode != 0:
-                    message = f"{sub.name}: patch {patch.name} does not apply"
-                    try:
-                        _reset_to_pin(repo_root, sub)
-                    except PatchError as reset_err:
-                        raise PatchError(
-                            f"{message}, and resetting to the pin also failed.\n"
-                            f"{result.stderr.strip()}\n{reset_err}"
-                        ) from reset_err
-                    raise PatchError(
-                        f"{message}; {sub.name} is reset to its pin.\n{result.stderr.strip()}"
-                    )
-        print(f"{sub.name}: {len(files)} patch(es) applied")
-
-
-def restore_all(repo_root: Path, components: list[str] | None = None) -> None:
-    """Reset submodules to their pinned commits with clean working trees (make unpatch)."""
-    for sub in _select(repo_root, components, check_orphans=False):
-        _reset_to_pin(repo_root, sub)
-        print(f"{sub.name}: restored to its pin")
-
-
-def _default_root() -> Path:
-    for start in (Path(__file__).resolve().parent, Path.cwd()):
-        result = _git(start, "rev-parse", "--show-toplevel", check=False)
-        if result.returncode == 0:
-            return Path(result.stdout.strip())
-    raise PatchError("not inside a git repository; pass --repo-root")
-
-
-def main(argv: list[str] | None = None) -> int:
-    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
-    parser.add_argument("--repo-root", type=Path, help="superproject root (default: git top-level)")
-    parser.add_argument("command", choices=["apply", "restore"])
-    parser.add_argument("names", nargs="*", help="component names (default: all)")
-    args = parser.parse_args(argv)
-    try:
-        root = (args.repo_root or _default_root()).resolve()
-        if args.command == "apply":
-            apply_all(root, args.names or None)
-        else:
-            restore_all(root, args.names or None)
-    except PatchError as err:
-        print(f"apply_patches.py: {err}", file=sys.stderr)
-        return 1
-    return 0
-
-
-if __name__ == "__main__":
-    sys.exit(main())
diff --git a/scripts/deps.py b/scripts/deps.py
new file mode 100644
index 0000000..d7b66d5
--- /dev/null
+++ b/scripts/deps.py
@@ -0,0 +1,296 @@
+"""Prebuilt third-party libraries, downloaded from GitHub releases of the forks.
+
+    uv run scripts/deps.py [--repo-root PATH] COMMAND
+
+Commands:
+    check                         validate third_party/deps.toml (no network)
+    fetch [names]                 download, check and unpack each pinned release asset
+    verify [names]                each dependency is unpacked from its pinned asset
+    pin NAME --tag TAG [--asset]  pin NAME to a release: record its tag, asset and SHA-256
+
+Assets unpack into build/deps/<name>/. Downloads come from
+https://github.com/<repo>/releases/download/<tag>/<asset>, or from
+$EIKON_RELEASES_URL in place of https://github.com. See third_party/README.md.
+"""
+
+from __future__ import annotations
+
+import argparse
+import hashlib
+import os
+import re
+import shutil
+import subprocess
+import sys
+import tarfile
+import tempfile
+import tomllib
+import urllib.parse
+import urllib.request
+import zipfile
+from dataclasses import dataclass
+from pathlib import Path
+
+MANIFEST = Path("third_party") / "deps.toml"
+DEPS_DIR = Path("build") / "deps"
+STAMP = ".eikon-dep"
+DEFAULT_RELEASES_URL = "https://github.com"
+
+_PATTERNS = {
+    "name": re.compile(r"^[a-z0-9][a-z0-9._-]*$"),
+    "repo": re.compile(r"^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$"),
+    "tag": re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$"),
+    "asset": re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$"),
+    "sha256": re.compile(r"^[0-9a-f]{64}$"),
+}
+_OPTIONAL = ("upstream",)
+_TAR_SUFFIXES = (".tar", ".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.bz2", ".tbz2")
+
+
+class DepError(Exception):
+    pass
+
+
+@dataclass(frozen=True)
+class Dep:
+    name: str
+    repo: str
+    tag: str
+    asset: str
+    sha256: str
+
+
+def _parse(text: str) -> list[Dep]:
+    try:
+        data = tomllib.loads(text)
+    except tomllib.TOMLDecodeError as err:
+        raise DepError(f"{MANIFEST}: {err}") from err
+    if set(data) - {"dep"}:
+        raise DepError(f"{MANIFEST}: unknown keys {sorted(set(data) - {'dep'})}")
+    entries = data.get("dep", [])
+    if not isinstance(entries, list) or not all(isinstance(e, dict) for e in entries):
+        raise DepError(f"{MANIFEST}: `dep` must be an array of tables ([[dep]])")
+
+    problems: list[str] = []
+    deps: list[Dep] = []
+    for i, entry in enumerate(entries, start=1):
+        label = f"{MANIFEST} entry {i}" + (f" ({entry['name']})" if isinstance(entry.get("name"), str) else "")
+        extra = sorted(set(entry) - set(_PATTERNS) - set(_OPTIONAL))
+        if extra:
+            problems.append(f"{label}: unknown keys {', '.join(extra)}")
+        bad = [
+            key for key, pattern in _PATTERNS.items()
+            if not isinstance(entry.get(key), str) or not pattern.match(entry[key])
+        ]
+        bad += [key for key in _OPTIONAL if key in entry and not isinstance(entry[key], str)]
+        if bad:
+            problems.append(f"{label}: missing or malformed {', '.join(bad)}")
+            continue
+        deps.append(Dep(**{key: entry[key] for key in _PATTERNS}))
+
+    names = [d.name for d in deps]
+    for name in sorted({n for n in names if names.count(n) > 1}):
+        problems.append(f"{MANIFEST}: two dependencies are named {name!r}")
+    if problems:
+        raise DepError("\n".join(problems))
+    return deps
+
+
+def load(repo_root: Path) -> list[Dep]:
+    """Read and validate the manifest. A missing or empty manifest has no dependencies."""
+    path = repo_root / MANIFEST
+    return _parse(path.read_text()) if path.is_file() else []
+
+
+def _select(deps: list[Dep], names: list[str]) -> list[Dep]:
+    if not names:
+        return deps
+    known = {d.name: d for d in deps}
+    unknown = [n for n in names if n not in known]
+    if unknown:
+        raise DepError(f"not in {MANIFEST}: {', '.join(unknown)}")
+    return [known[n] for n in names]
+
+
+def _url(repo: str, tag: str, asset: str) -> str:
+    base = os.environ.get("EIKON_RELEASES_URL", DEFAULT_RELEASES_URL).rstrip("/")
+    quote = lambda s: urllib.parse.quote(s, safe="")  # noqa: E731
+    return f"{base}/{repo}/releases/download/{quote(tag)}/{quote(asset)}"
+
+
+def _download(url: str, dest: Path) -> str:
+    """Download `url` to `dest`; return its SHA-256."""
+    dest.parent.mkdir(parents=True, exist_ok=True)
+    digest = hashlib.sha256()
+    tmp = dest.with_name(dest.name + ".part")
+    try:
+        with urllib.request.urlopen(url, timeout=60) as response, tmp.open("wb") as out:
+            while chunk := response.read(1 << 20):
+                digest.update(chunk)
+                out.write(chunk)
+    except OSError as err:  # URLError and HTTPError are OSErrors
+        tmp.unlink(missing_ok=True)
+        raise DepError(f"could not download {url}: {err}") from err
+    tmp.replace(dest)
+    return digest.hexdigest()
+
+
+def _sha256(path: Path) -> str:
+    digest = hashlib.sha256()
+    with path.open("rb") as f:
+        while chunk := f.read(1 << 20):
+            digest.update(chunk)
+    return digest.hexdigest()
+
+
+def _cached_asset(repo_root: Path, dep: Dep) -> Path:
+    """The pinned asset in the download cache, downloading it if needed."""
+    cached = repo_root / DEPS_DIR / ".cache" / dep.sha256 / dep.asset
+    if cached.is_file() and _sha256(cached) == dep.sha256:
+        return cached
+    got = _download(_url(dep.repo, dep.tag, dep.asset), cached)
+    if got != dep.sha256:
+        cached.unlink(missing_ok=True)
+        raise DepError(
+            f"{dep.name}: {dep.asset} from {dep.repo} {dep.tag} has SHA-256 {got}, "
+            f"but {MANIFEST} pins {dep.sha256}"
+        )
+    return cached
+
+
+def _unpack(archive: Path, dest: Path) -> None:
+    name = archive.name
+    if name.endswith(_TAR_SUFFIXES):
+        with tarfile.open(archive) as tar:
+            tar.extractall(dest, filter="data")
+    elif name.endswith(".zip"):
+        with zipfile.ZipFile(archive) as zf:
+            for member in zf.namelist():
+                target = (dest / member).resolve()
+                if not target.is_relative_to(dest.resolve()):
+                    raise DepError(f"{archive.name}: member {member!r} escapes the archive")
+            zf.extractall(dest)
+    else:
+        shutil.copy2(archive, dest / name)
+
+
+def _stamp(dep: Dep) -> str:
+    return f"{dep.repo} {dep.tag} {dep.asset} {dep.sha256}\n"
+
+
+def _is_current(repo_root: Path, dep: Dep) -> bool:
+    stamp = repo_root / DEPS_DIR / dep.name / STAMP
+    return stamp.is_file() and stamp.read_text() == _stamp(dep)
+
+
+def fetch(repo_root: Path, names: list[str]) -> None:
+    """Download, check and unpack each pinned asset into build/deps/<name>/.
+    A dependency already unpacked from its pinned asset is left alone."""
+    for dep in _select(load(repo_root), names):
+        if _is_current(repo_root, dep):
+            print(f"{dep.name}: up to date ({dep.tag})")
+            continue
+        archive = _cached_asset(repo_root, dep)
+        deps_dir = repo_root / DEPS_DIR
+        staging = Path(tempfile.mkdtemp(prefix=f".{dep.name}-", dir=deps_dir))
+        try:
+            _unpack(archive, staging)
+            (staging / STAMP).write_text(_stamp(dep))
+            final = deps_dir / dep.name
+            if final.exists():
+                shutil.rmtree(final)
+            staging.rename(final)
+        finally:
+            if staging.exists():
+                shutil.rmtree(staging)
+        print(f"{dep.name}: unpacked {dep.asset} from {dep.repo} {dep.tag}")
+
+
+def verify(repo_root: Path, names: list[str]) -> None:
+    """Every dependency is unpacked from its pinned asset."""
+    stale = [d.name for d in _select(load(repo_root), names) if not _is_current(repo_root, d)]
+    if stale:
+        raise DepError(f"not unpacked from the pinned release: {', '.join(stale)}; run `make fetch-deps`")
+    print("all dependencies match their pins")
+
+
+def pin(repo_root: Path, name: str, tag: str, asset: str | None) -> None:
+    """Point NAME at release TAG (and ASSET, if given), recording the asset's SHA-256."""
+    deps = load(repo_root)
+    (old,) = _select(deps, [name])
+    new = Dep(name=old.name, repo=old.repo, tag=tag, asset=asset or old.asset, sha256="0" * 64)
+    for key in ("tag", "asset"):
+        if not _PATTERNS[key].match(getattr(new, key)):
+            raise DepError(f"{name}: malformed {key} {getattr(new, key)!r}")
+
+    with tempfile.TemporaryDirectory() as tmp:
+        sha = _download(_url(new.repo, new.tag, new.asset), Path(tmp) / new.asset)
+    new = Dep(**{**new.__dict__, "sha256": sha})
+
+    # Rewrite only this dependency's tag, asset and sha256 lines, then check that
+    # the parsed result differs from the old manifest in exactly those values.
+    manifest = repo_root / MANIFEST
+    text = manifest.read_text()
+    tables = re.split(r"(?m)^(?=\[\[dep\]\])", text)
+    name_re = re.compile(rf'(?m)^\s*name\s*=\s*"{re.escape(name)}"\s*(#.*)?$')
+    hits = [i for i, t in enumerate(tables) if name_re.search(t)]
+    if len(hits) != 1:
+        raise DepError(f"{name}: could not find its table in {MANIFEST}")
+    table = tables[hits[0]]
+    for key in ("tag", "asset", "sha256"):
+        line_re = re.compile(rf'(?m)^(\s*{key}\s*=\s*")[^"\n]*(")')
+        table, count = line_re.subn(lambda m, v=getattr(new, key): f"{m.group(1)}{v}{m.group(2)}", table)
+        if count != 1:
+            raise DepError(f"{name}: could not find its {key} line in {MANIFEST}")
+    tables[hits[0]] = table
+    new_text = "".join(tables)
+    expected = [new if d.name == name else d for d in deps]
+    if _parse(new_text) != expected:
+        raise DepError(f"{name}: rewriting {MANIFEST} would change more than this pin; edit it by hand")
+
+    tmp = manifest.with_name(manifest.name + ".tmp")
+    tmp.write_text(new_text)
+    tmp.replace(manifest)
+    print(f"{name}: pinned {new.repo} {new.tag} {new.asset} ({sha})")
+
+
+def _default_root() -> Path:
+    for start in (Path(__file__).resolve().parent, Path.cwd()):
+        result = subprocess.run(
+            ["git", "rev-parse", "--show-toplevel"], cwd=start, capture_output=True, text=True
+        )
+        if result.returncode == 0:
+            return Path(result.stdout.strip())
+    raise DepError("not inside a git repository; pass --repo-root")
+
+
+def main(argv: list[str] | None = None) -> int:
+    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
+    parser.add_argument("--repo-root", type=Path, help="Eikon checkout (default: git top-level)")
+    sub = parser.add_subparsers(dest="command", required=True)
+    sub.add_parser("check")
+    for command in ("fetch", "verify"):
+        sub.add_parser(command).add_argument("names", nargs="*")
+    pin_parser = sub.add_parser("pin")
+    pin_parser.add_argument("name")
+    pin_parser.add_argument("--tag", required=True)
+    pin_parser.add_argument("--asset")
+    args = parser.parse_args(argv)
+    try:
+        root = (args.repo_root or _default_root()).resolve()
+        if args.command == "check":
+            print(f"{MANIFEST}: {len(load(root))} dependencies, valid")
+        elif args.command == "fetch":
+            fetch(root, args.names)
+        elif args.command == "verify":
+            verify(root, args.names)
+        else:
+            pin(root, args.name, args.tag, args.asset)
+    except DepError as err:
+        print(f"deps.py: {err}", file=sys.stderr)
+        return 1
+    return 0
+
+
+if __name__ == "__main__":
+    sys.exit(main())
diff --git a/tests/test_apply_patches.py b/tests/test_apply_patches.py
deleted file mode 100644
index 948ef14..0000000
--- a/tests/test_apply_patches.py
+++ /dev/null
@@ -1,145 +0,0 @@
-"""Behaviour of scripts/apply_patches.py against a fixture superproject."""
-
-from __future__ import annotations
-
-import shutil
-from dataclasses import dataclass
-from pathlib import Path
-
-import pytest
-
-SCRIPT = "scripts/apply_patches.py"
-NAME = "libdemo"
-SUB = f"third_party/{NAME}"
-
-# Local-path submodule clones are refused by default; only the tests allow them.
-FILE_PROTOCOL = {
-    "GIT_CONFIG_COUNT": "1",
-    "GIT_CONFIG_KEY_0": "protocol.file.allow",
-    "GIT_CONFIG_VALUE_0": "always",
-}
-
-
-@dataclass
-class Fixture:
-    repo: object  # the superproject (a GitRepo)
-    pin: str  # the gitlink commit
-    patched: dict[str, bytes]  # the tree the patches were made from
-
-    @property
-    def root(self) -> Path:
-        return self.repo.path
-
-    @property
-    def sub(self) -> Path:
-        return self.repo.path / SUB
-
-    def git(self, *args: str) -> str:
-        return self.repo.git(*args).stdout
-
-    def sub_git(self, *args: str) -> str:
-        return self.repo.git("-C", SUB, *args).stdout
-
-
-def _snapshot(tree: Path) -> dict[str, bytes]:
-    return {
-        str(p.relative_to(tree)): p.read_bytes()
-        for p in sorted(tree.rglob("*"))
-        if p.is_file() and ".git" not in p.relative_to(tree).parts
-    }
-
-
-@pytest.fixture
-def project(make_repo, tmp_path) -> Fixture:
-    upstream = make_repo("upstream")
-    upstream.write("greeting.txt", "hello\n")
-    upstream.write("notes.txt", "one\ntwo\nthree\n")
-    upstream.commit("Initial import")
-    pin = upstream.git("rev-parse", "HEAD").stdout.strip()
-
-    # Patches made with format-patch against the pin, in a scratch clone.
-    scratch = tmp_path / "scratch"
-    upstream.git("clone", "-q", str(upstream.path), str(scratch))
-    patch_dir = tmp_path / "made-patches"
-    for number, (path, text) in enumerate(
-        [("greeting.txt", "hello, patched\n"), ("notes.txt", "one\ntwo, patched\nthree\n")],
-        start=1,
-    ):
-        (scratch / path).write_text(text)
-        upstream.git("-C", str(scratch), "commit", "-qam", f"Change {path}")
-        upstream.git(
-            "-C", str(scratch), "format-patch", "-1", "--start-number", str(number),
-            "-o", str(patch_dir),
-        )
-    patched = _snapshot(scratch)
-
-    root = make_repo("super")
-    root.git("-c", "protocol.file.allow=always", "submodule", "add", "-q", str(upstream.path), SUB)
-    root.git("config", "-f", ".gitmodules", f"submodule.{SUB}.ignore", "dirty")
-    shutil.copytree(patch_dir, root.path / "patches" / NAME)
-    root.commit("Add libdemo with patches")
-
-    # Move the submodule to a later upstream commit: the tool must use the
-    # gitlink, not whatever the submodule has checked out.
-    upstream.write("later.txt", "after the pin\n")
-    upstream.commit("After the pin")
-    root.git("-C", SUB, "fetch", "-q", "origin")
-    root.git("-C", SUB, "checkout", "-q", "--detach", "origin/HEAD")
-
-    return Fixture(repo=root, pin=pin, patched=patched)
-
-
-def _run(run_script, fx: Fixture, *args: str):
-    return run_script(SCRIPT, "--repo-root", str(fx.root), *args, cwd=fx.root, env=FILE_PROTOCOL)
-
-
-def _at_clean_pin(fx: Fixture) -> bool:
-    head = fx.sub_git("rev-parse", "HEAD").strip()
-    return head == fx.pin and fx.sub_git("status", "--porcelain", "--ignored") == ""
-
-
-def test_apply_changes_the_tree_and_is_idempotent(project, run_script):
-    first = _run(run_script, project, "apply")
-    assert first.returncode == 0, first.stderr
-    after_first = _snapshot(project.sub)
-    assert after_first == project.patched
-
-    second = _run(run_script, project, "apply")
-    assert second.returncode == 0, second.stderr
-    assert _snapshot(project.sub) == after_first
-
-
-def test_apply_records_no_new_submodule_commit(project, run_script):
-    assert _run(run_script, project, "apply").returncode == 0
-
-    gitlink = project.git("ls-tree", "HEAD", SUB).split()[2]
-    assert project.sub_git("rev-parse", "HEAD").strip() == gitlink == project.pin
-    assert project.git("status", "--porcelain") == ""
-    assert project.git("diff", "--submodule") == ""
-
-
-def test_a_conflicting_patch_fails_cleanly(project, run_script):
-    bad = project.root / "patches" / NAME / "0003-change-missing-line.patch"
-    bad.write_text(
-        "diff --git a/greeting.txt b/greeting.txt\n"
-        "--- a/greeting.txt\n"
-        "+++ b/greeting.txt\n"
-        "@@ -1 +1 @@\n"
-        "-a line that is not there\n"
-        "+a replacement\n"
-    )
-
-    result = _run(run_script, project, "apply")
-    assert result.returncode != 0
-    output = result.stdout + result.stderr
-    assert NAME in output and bad.name in output
-    assert _at_clean_pin(project)
-
-
-def test_restore_returns_to_the_pin(project, run_script):
-    assert _run(run_script, project, "apply").returncode == 0
-    (project.sub / "stray-build-output.o").write_text("junk\n")
-
-    result = _run(run_script, project, "restore")
-    assert result.returncode == 0, result.stderr
-    assert _at_clean_pin(project)
diff --git a/tests/test_deps.py b/tests/test_deps.py
new file mode 100644
index 0000000..088410f
--- /dev/null
+++ b/tests/test_deps.py
@@ -0,0 +1,130 @@
+"""Behaviour of scripts/deps.py: prebuilt libraries from fork releases."""
+
+from __future__ import annotations
+
+import hashlib
+import io
+import tarfile
+import tomllib
+from dataclasses import dataclass
+from pathlib import Path
+
+import pytest
+
+SCRIPT = "scripts/deps.py"
+NAME = "libdemo"
+REPO = "example/libdemo"
+ASSET = "libdemo-ios-arm64.tar.gz"
+
+
+@dataclass
+class Fixture:
+    root: Path  # the eikon checkout
+    releases: Path  # stands in for https://github.com
+    files: dict[str, bytes]  # what the pinned asset contains
+
+    @property
+    def manifest(self) -> Path:
+        return self.root / "third_party" / "deps.toml"
+
+    @property
+    def unpacked(self) -> Path:
+        return self.root / "build" / "deps" / NAME
+
+    def publish(self, tag: str, files: dict[str, bytes]) -> str:
+        """Publish a release asset; return its SHA-256."""
+        buf = io.BytesIO()
+        with tarfile.open(fileobj=buf, mode="w:gz") as tar:
+            for name, data in files.items():
+                info = tarfile.TarInfo(name)
+                info.size = len(data)
+                tar.addfile(info, io.BytesIO(data))
+        path = self.releases / REPO / "releases" / "download" / tag / ASSET
+        path.parent.mkdir(parents=True, exist_ok=True)
+        path.write_bytes(buf.getvalue())
+        return hashlib.sha256(buf.getvalue()).hexdigest()
+
+    def pin(self, entries: list[dict[str, str]]) -> None:
+        lines = []
+        for entry in entries:
+            lines.append("[[dep]]")
+            lines += [f'{key} = "{value}"' for key, value in entry.items()]
+            lines.append("")
+        self.manifest.write_text("\n".join(lines))
+
+    def snapshot(self) -> dict[str, bytes]:
+        return {
+            str(p.relative_to(self.unpacked)): p.read_bytes()
+            for p in sorted(self.unpacked.rglob("*"))
+            if p.is_file() and not p.name.startswith(".")
+        }
+
+
+@pytest.fixture
+def project(git_repo, tmp_path) -> Fixture:
+    files = {"lib/libdemo.a": b"archive bytes\n", "include/demo.h": b"int demo(void);\n"}
+    fx = Fixture(root=git_repo.path, releases=tmp_path / "releases", files=files)
+    fx.manifest.parent.mkdir(parents=True)
+    sha = fx.publish("v1", files)
+    fx.pin([{"name": NAME, "repo": REPO, "tag": "v1", "asset": ASSET, "sha256": sha}])
+    return fx
+
+
+def _run(run_script, fx: Fixture, *args: str):
+    return run_script(
+        SCRIPT, "--repo-root", str(fx.root), *args,
+        cwd=fx.root, env={"EIKON_RELEASES_URL": fx.releases.as_uri()},
+    )
+
+
+def test_fetch_unpacks_the_pinned_release_and_is_repeatable(project, run_script):
+    assert _run(run_script, project, "check").returncode == 0
+
+    first = _run(run_script, project, "fetch")
+    assert first.returncode == 0, first.stderr
+    assert project.snapshot() == project.files
+    assert _run(run_script, project, "verify").returncode == 0
+
+    second = _run(run_script, project, "fetch")
+    assert second.returncode == 0, second.stderr
+    assert project.snapshot() == project.files
+
+
+def test_an_asset_that_does_not_match_its_pin_is_rejected(project, run_script):
+    # The release asset is replaced after it was pinned.
+    project.publish("v1", {"lib/libdemo.a": b"replaced\n"})
+
+    result = _run(run_script, project, "fetch")
+    assert result.returncode != 0
+    assert NAME in result.stdout + result.stderr
+    assert not project.unpacked.exists()
+    assert _run(run_script, project, "verify").returncode != 0
+
+
+def test_pin_records_a_release_and_fetch_uses_it(project, run_script):
+    new_files = {"lib/libdemo.a": b"version two\n"}
+    sha = project.publish("v2", new_files)
+
+    result = _run(run_script, project, "pin", NAME, "--tag", "v2")
+    assert result.returncode == 0, result.stderr
+    pinned = tomllib.loads(project.manifest.read_text())["dep"][0]
+    assert (pinned["tag"], pinned["sha256"]) == ("v2", sha)
+
+    assert _run(run_script, project, "fetch").returncode == 0
+    assert project.snapshot() == new_files
+
+
+@pytest.mark.parametrize(
+    "entries",
+    [
+        [{"name": NAME, "repo": REPO, "tag": "v1", "asset": ASSET, "sha256": "abc"}],
+        [
+            {"name": NAME, "repo": REPO, "tag": "v1", "asset": ASSET, "sha256": "a" * 64},
+            {"name": NAME, "repo": REPO, "tag": "v2", "asset": ASSET, "sha256": "b" * 64},
+        ],
+    ],
+    ids=["short-hash", "duplicate-name"],
+)
+def test_check_rejects_an_invalid_manifest(project, run_script, entries):
+    project.pin(entries)
+    assert _run(run_script, project, "check").returncode != 0
diff --git a/third_party/README.md b/third_party/README.md
index 47a68eb..cea963f 100644
--- a/third_party/README.md
+++ b/third_party/README.md
@@ -1,36 +1,51 @@
 # Third-party components
 
-Eikon builds several upstream projects for iOS. This directory holds them as
-git submodules. Any local changes are kept as patch files, not as commits.
+Eikon links several upstream projects built for iOS: FEX, Wine, Box64 and Kirikiroid2. It doesn't build them itself, and there are no submodules and no patch files. Instead:
 
-## Location and pinning
+- **Each upstream is a fork** on the owner's GitHub. Eikon's changes are commits on the fork's `eikon` branch. For development, the fork is cloned next to this repo (`../<fork>`).
+- **The fork builds its library and publishes it as a GitHub release.** Each release tag names exactly which fork commit the binaries came from. It also keeps that commit reachable after a rebase, and it is where the GPL corresponding source is published.
+- **Eikon pins a release.** `third_party/deps.toml` records the fork, the release tag, the asset name and the asset's SHA-256. The build downloads that asset into `build/deps/<name>/` and links against it.
 
-- Every upstream is a git submodule at `third_party/<name>`, pinned to a tag or commit.
-- `.gitmodules` sets `ignore = dirty` for every submodule, so applied (uncommitted) patches don't show up as changes in the superproject.
+## The manifest: `third_party/deps.toml`
 
-## Patches
+Each dependency is one `[[dep]]` table:
 
-- Local changes to an upstream live **only** in `patches/<name>/NNNN-short-description.patch`. `<name>` matches the submodule directory name, and `NNNN` is a zero-padded sequence number.
-- To make a patch, commit in the submodule temporarily, export with `git format-patch` against the pinned revision, then reset the submodule.
-- Patches apply in lexical order with `git apply`, to the working tree only. The submodule's `HEAD` never moves, and the superproject never records a patched commit. Never commit inside a submodule, and never bump a gitlink to a patched commit.
-- `make apply-patches` applies them. `make unpatch` resets every submodule to its pin with a clean tree. To work on some components only, name them: `uv run scripts/apply_patches.py apply|restore [names…]`.
-- A patch that doesn't apply stops the run with the component and patch name, and that submodule is reset to its pin.
-- When you bump a pin, regenerate or refresh that component's patches against the new revision in the same commit.
+- `name`: unpacks to `build/deps/<name>/`
+- `repo`: the fork, as `owner/repo`
+- `tag`: the release tag
+- `asset`: the asset file: `.tar.gz`, `.tar.xz`, `.tar.bz2`, `.zip`, or a single file copied as-is
+- `sha256`: the asset's hash; `fetch` refuses anything that doesn't match
+- `upstream` (optional): the original project, for reference
 
-## Out-of-tree builds
+## Commands
 
-Upstream builds must happen **out of tree**, under `build/`. Resetting a submodule fully cleans its working tree (`git clean -ffdx`), which deletes anything built inside it.
+- `make fetch-deps`: downloads each pinned asset, checks its hash and unpacks it. Downloads are cached in `build/deps/.cache/` by hash, and a dependency that is already unpacked from its pin is skipped.
+- `make verify-deps`: checks that every dependency is unpacked from its pinned asset. Builds that link a dependency run this first.
+- `make pin-dep NAME=<name> TAG=<tag> [ASSET=<asset>]`: downloads the release asset and writes its tag, asset and SHA-256 into the manifest. Commit that change in eikon.
+- `make check`: includes `deps.py check`, which validates the manifest without network access.
+
+To act on some dependencies only, name them: `uv run scripts/deps.py fetch|verify [names…]`.
+
+`EIKON_RELEASES_URL` replaces `https://github.com` as the download base. The tests use it; it is also handy for a mirror.
+
+## Releasing a new version of a library
+
+1. In the fork, commit to the `eikon` branch and push. Rebasing onto a newer upstream is fine: each release's tag keeps the commits it was built from.
+2. Build the library for iOS arm64 in the fork, using the notes below, and publish it as a release. The release notes name the fork commit and the upstream version it's based on. A release is never replaced once an Eikon commit pins it; publish a new tag instead.
+3. In eikon, run `make pin-dep NAME=<name> TAG=<tag>`, then `make fetch-deps`, and commit the manifest.
+
+Creating forks and publishing releases are outward-facing steps, so they need the owner's approval.
 
 ## Credits in the same commit
 
-The commit that adds a submodule must also add:
+The commit that adds a dependency also adds:
 
 - its credits entry in `third_party/credits.toml`
 - its license texts under `licenses/`
 
-CI enforces this.
+CI enforces this. For GPL and LGPL libraries, the notices point to the fork's release tag as the corresponding source.
 
-## Notes for cross-compiling for iOS
+## Notes for building the libraries for iOS (in the forks)
 
 - Compiler: `CC="$(xcrun --sdk iphoneos -f clang) -target arm64-apple-ios15.0"`, with `-isysroot "$(xcrun --sdk iphoneos --show-sdk-path)"`.
 - Build systems:
@@ -40,5 +55,5 @@ CI enforces this.
 - Set `ac_cv_func_pipe2=no` for the iOS 27 SDK.
 - Homebrew's `bison` and `flex` are keg-only, so put them on `PATH` explicitly.
 - llvm-mingw is the host toolchain for Wine's PE side.
-- Dynamic libraries go in `Frameworks/<name>.framework`, with `@rpath` install names.
-- CI caches are keyed on the dependency build scripts, `patches/**` and the submodule SHAs.
+- Dynamic libraries ship as `<name>.framework` bundles with `@rpath` install names. Eikon embeds them in `Frameworks/`.
+- Upstreams with their own git submodules (FEX, for example) need `git submodule update --init --recursive` in the fork before building.
diff --git a/third_party/deps.toml b/third_party/deps.toml
new file mode 100644
index 0000000..e9f6648
--- /dev/null
+++ b/third_party/deps.toml
@@ -0,0 +1,10 @@
+# Prebuilt libraries Eikon links, each a release asset of a fork on GitHub.
+# See third_party/README.md. Managed with `uv run scripts/deps.py`.
+#
+# [[dep]]
+# name     = "fexcore"                            # unpacks to build/deps/<name>/
+# repo     = "getBoolean/FEX"                     # the fork that publishes the release
+# tag      = "eikon-fexcore-1"                    # the release tag
+# asset    = "fexcore-ios-arm64.tar.xz"           # the release asset (.tar.*, .zip, or a single file)
+# sha256   = "<64 hex characters>"                # the asset's hash; fetch refuses anything else
+# upstream = "https://github.com/FEX-Emu/FEX"     # optional; the original project
