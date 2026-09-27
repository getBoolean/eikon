diff --git a/Makefile b/Makefile
index e0baa74..244b2e4 100644
--- a/Makefile
+++ b/Makefile
@@ -70,8 +70,11 @@ all: check test archive package verify
 publish:
 	@$(call stub,11)
 
-apply-patches unpatch:
-	@$(call stub,03)
+apply-patches:
+	@uv run scripts/apply_patches.py apply
+
+unpatch:
+	@uv run scripts/apply_patches.py restore
 
 clean:
 	rm -rf build dist
diff --git a/patches/.gitkeep b/patches/.gitkeep
new file mode 100644
index 0000000..e69de29
diff --git a/scripts/apply_patches.py b/scripts/apply_patches.py
new file mode 100644
index 0000000..cb971ad
--- /dev/null
+++ b/scripts/apply_patches.py
@@ -0,0 +1,150 @@
+"""Apply local patches to the third-party submodules, or restore them to their pins.
+
+    uv run scripts/apply_patches.py [--repo-root PATH] apply   [names...]
+    uv run scripts/apply_patches.py [--repo-root PATH] restore [names...]
+
+Patches live in patches/<name>/NNNN-*.patch and are applied in lexical order
+with `git apply`, to the working tree only. A submodule's HEAD never moves and
+the superproject never records a patched commit. See third_party/README.md.
+"""
+
+from __future__ import annotations
+
+import argparse
+import subprocess
+import sys
+from dataclasses import dataclass
+from pathlib import Path
+
+
+class PatchError(Exception):
+    pass
+
+
+@dataclass(frozen=True)
+class Submodule:
+    name: str
+    path: str  # relative to the superproject root
+
+
+def _git(cwd: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
+    result = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
+    if check and result.returncode != 0:
+        raise PatchError(f"git {' '.join(args)} failed in {cwd}:\n{result.stderr.strip()}")
+    return result
+
+
+def _submodules(repo_root: Path) -> list[Submodule]:
+    if not (repo_root / ".gitmodules").is_file():
+        return []
+    result = _git(
+        repo_root, "config", "-f", ".gitmodules", "--get-regexp", r"^submodule\..*\.path$",
+        check=False,
+    )
+    subs = []
+    for line in result.stdout.splitlines():
+        _, _, path = line.partition(" ")
+        path = path.strip()
+        if path:
+            subs.append(Submodule(name=Path(path).name, path=path))
+    return sorted(subs, key=lambda s: s.name)
+
+
+def _select(repo_root: Path, components: list[str] | None, *, check_orphans: bool) -> list[Submodule]:
+    subs = _submodules(repo_root)
+    known = {s.name: s for s in subs}
+    if components:
+        unknown = [c for c in components if c not in known]
+        if unknown:
+            raise PatchError(f"not a known submodule: {', '.join(unknown)}")
+        return [known[c] for c in components]
+    if check_orphans:
+        patches = repo_root / "patches"
+        orphans = sorted(
+            d.name for d in patches.iterdir() if d.is_dir() and d.name not in known
+        ) if patches.is_dir() else []
+        if orphans:
+            raise PatchError(
+                f"patches/ has directories with no matching submodule: {', '.join(orphans)}"
+            )
+    return subs
+
+
+def _pin(repo_root: Path, sub: Submodule) -> str:
+    """The pinned commit, from the superproject's gitlink."""
+    out = _git(repo_root, "ls-tree", "HEAD", "--", sub.path).stdout.split()
+    if len(out) < 3 or out[1] != "commit":
+        raise PatchError(f"{sub.name}: no gitlink for {sub.path} in HEAD")
+    return out[2]
+
+
+def _reset_to_pin(repo_root: Path, sub: Submodule) -> None:
+    sha = _pin(repo_root, sub)
+    work = repo_root / sub.path
+    if not (work / ".git").exists():
+        _git(repo_root, "submodule", "update", "--init", "--", sub.path)
+    if _git(work, "cat-file", "-e", f"{sha}^{{commit}}", check=False).returncode != 0:
+        _git(work, "fetch", "--quiet", "origin", sha)
+    _git(work, "checkout", "--quiet", "--detach", sha)
+    _git(work, "reset", "--quiet", "--hard", sha)
+    _git(work, "clean", "-ffdxq")
+
+
+def apply_all(repo_root: Path, components: list[str] | None = None) -> None:
+    """For each submodule (or the named ones): reset it to the commit pinned by the
+    superproject's gitlink with a clean working tree, then apply
+    patches/<name>/*.patch in lexical order with `git apply --check` and `git apply`.
+    Running it twice yields the same tree. A patch that fails aborts with the
+    component and patch name, and the submodule is left reset to its pin."""
+    for sub in _select(repo_root, components, check_orphans=not components):
+        _reset_to_pin(repo_root, sub)
+        patch_dir = repo_root / "patches" / sub.name
+        patches = sorted(patch_dir.glob("*.patch")) if patch_dir.is_dir() else []
+        work = repo_root / sub.path
+        for patch in patches:
+            for args in (("apply", "--check", str(patch)), ("apply", str(patch))):
+                result = _git(work, *args, check=False)
+                if result.returncode != 0:
+                    _reset_to_pin(repo_root, sub)
+                    raise PatchError(
+                        f"{sub.name}: patch {patch.name} does not apply; "
+                        f"{sub.name} is reset to its pin.\n{result.stderr.strip()}"
+                    )
+        print(f"{sub.name}: {len(patches)} patch(es) applied")
+
+
+def restore_all(repo_root: Path, components: list[str] | None = None) -> None:
+    """Reset submodules to their pinned commits with clean working trees (make unpatch)."""
+    for sub in _select(repo_root, components, check_orphans=False):
+        _reset_to_pin(repo_root, sub)
+        print(f"{sub.name}: restored to its pin")
+
+
+def _default_root() -> Path:
+    for start in (Path.cwd(), Path(__file__).resolve().parent):
+        result = _git(start, "rev-parse", "--show-toplevel", check=False)
+        if result.returncode == 0:
+            return Path(result.stdout.strip())
+    raise PatchError("not inside a git repository; pass --repo-root")
+
+
+def main(argv: list[str] | None = None) -> int:
+    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
+    parser.add_argument("--repo-root", type=Path, help="superproject root (default: git top-level)")
+    parser.add_argument("command", choices=["apply", "restore"])
+    parser.add_argument("names", nargs="*", help="component names (default: all)")
+    args = parser.parse_args(argv)
+    try:
+        root = (args.repo_root or _default_root()).resolve()
+        if args.command == "apply":
+            apply_all(root, args.names or None)
+        else:
+            restore_all(root, args.names or None)
+    except PatchError as err:
+        print(f"apply_patches.py: {err}", file=sys.stderr)
+        return 1
+    return 0
+
+
+if __name__ == "__main__":
+    sys.exit(main())
diff --git a/tests/conftest.py b/tests/conftest.py
index 45ee984..fccb709 100644
--- a/tests/conftest.py
+++ b/tests/conftest.py
@@ -8,6 +8,7 @@ from __future__ import annotations
 
 import os
 import subprocess
+import sys
 from collections.abc import Callable
 from pathlib import Path
 
@@ -89,11 +90,15 @@ def git_repo(make_repo: Callable[[str], GitRepo]) -> GitRepo:
 def run_script() -> Callable[..., subprocess.CompletedProcess[str]]:
     """run_script(script, *args, cwd=..., env=None) runs a script from the Eikon
     checkout (for example "scripts/version.sh") with its working directory set
-    to `cwd`, under the same isolated git environment as the fixture repos."""
+    to `cwd`, under the same isolated git environment as the fixture repos.
+    Python scripts run with the test interpreter, as `uv run` would."""
 
     def run(script: str, *args: str, cwd: Path, env: dict[str, str] | None = None):
+        command = [str(REPO_ROOT / script)]
+        if script.endswith(".py"):
+            command.insert(0, sys.executable)
         return subprocess.run(
-            [str(REPO_ROOT / script), *args],
+            [*command, *args],
             cwd=cwd,
             env=_env(env),
             capture_output=True,
diff --git a/tests/test_apply_patches.py b/tests/test_apply_patches.py
new file mode 100644
index 0000000..073a372
--- /dev/null
+++ b/tests/test_apply_patches.py
@@ -0,0 +1,142 @@
+"""Behaviour of scripts/apply_patches.py against a fixture superproject."""
+
+from __future__ import annotations
+
+import shutil
+from dataclasses import dataclass
+from pathlib import Path
+
+import pytest
+
+SCRIPT = "scripts/apply_patches.py"
+NAME = "libdemo"
+SUB = f"third_party/{NAME}"
+
+# Local-path submodule clones are refused by default; only the tests allow them.
+FILE_PROTOCOL = {
+    "GIT_CONFIG_COUNT": "1",
+    "GIT_CONFIG_KEY_0": "protocol.file.allow",
+    "GIT_CONFIG_VALUE_0": "always",
+}
+
+
+@dataclass
+class Fixture:
+    repo: object  # the superproject (a GitRepo)
+    pin: str  # the gitlink commit
+    patched: dict[str, bytes]  # the tree the patches were made from
+
+    @property
+    def root(self) -> Path:
+        return self.repo.path
+
+    @property
+    def sub(self) -> Path:
+        return self.repo.path / SUB
+
+    def git(self, *args: str) -> str:
+        return self.repo.git(*args).stdout
+
+    def sub_git(self, *args: str) -> str:
+        return self.repo.git("-C", SUB, *args).stdout
+
+
+def _snapshot(tree: Path) -> dict[str, bytes]:
+    return {
+        str(p.relative_to(tree)): p.read_bytes()
+        for p in sorted(tree.rglob("*"))
+        if p.is_file() and ".git" not in p.relative_to(tree).parts
+    }
+
+
+@pytest.fixture
+def project(make_repo, tmp_path) -> Fixture:
+    upstream = make_repo("upstream")
+    upstream.write("greeting.txt", "hello\n")
+    upstream.write("notes.txt", "one\ntwo\nthree\n")
+    upstream.commit("Initial import")
+    pin = upstream.git("rev-parse", "HEAD").stdout.strip()
+
+    # Patches made with format-patch against the pin, in a scratch clone.
+    scratch = tmp_path / "scratch"
+    upstream.git("clone", "-q", str(upstream.path), str(scratch))
+    patch_dir = tmp_path / "made-patches"
+    for number, (path, text) in enumerate(
+        [("greeting.txt", "hello, patched\n"), ("notes.txt", "one\ntwo, patched\nthree\n")],
+        start=1,
+    ):
+        (scratch / path).write_text(text)
+        upstream.git("-C", str(scratch), "commit", "-qam", f"Change {path}")
+        upstream.git(
+            "-C", str(scratch), "format-patch", "-1", "--start-number", str(number),
+            "-o", str(patch_dir),
+        )
+    patched = _snapshot(scratch)
+
+    root = make_repo("super")
+    root.git("-c", "protocol.file.allow=always", "submodule", "add", "-q", str(upstream.path), SUB)
+    root.git("config", "-f", ".gitmodules", f"submodule.{SUB}.ignore", "dirty")
+    shutil.copytree(patch_dir, root.path / "patches" / NAME)
+    root.commit("Add libdemo with patches")
+
+    # A later upstream commit: the tool must use the gitlink, not the tip.
+    upstream.write("later.txt", "after the pin\n")
+    upstream.commit("After the pin")
+
+    return Fixture(repo=root, pin=pin, patched=patched)
+
+
+def _run(run_script, fx: Fixture, *args: str):
+    return run_script(SCRIPT, "--repo-root", str(fx.root), *args, cwd=fx.root, env=FILE_PROTOCOL)
+
+
+def _at_clean_pin(fx: Fixture) -> bool:
+    head = fx.sub_git("rev-parse", "HEAD").strip()
+    return head == fx.pin and fx.sub_git("status", "--porcelain", "--ignored") == ""
+
+
+def test_apply_changes_the_tree_and_is_idempotent(project, run_script):
+    first = _run(run_script, project, "apply")
+    assert first.returncode == 0, first.stderr
+    after_first = _snapshot(project.sub)
+    assert after_first == project.patched
+
+    second = _run(run_script, project, "apply")
+    assert second.returncode == 0, second.stderr
+    assert _snapshot(project.sub) == after_first
+
+
+def test_apply_records_no_new_submodule_commit(project, run_script):
+    assert _run(run_script, project, "apply").returncode == 0
+
+    gitlink = project.git("ls-tree", "HEAD", SUB).split()[2]
+    assert project.sub_git("rev-parse", "HEAD").strip() == gitlink == project.pin
+    assert project.git("status", "--porcelain") == ""
+    assert project.git("diff", "--submodule") == ""
+
+
+def test_a_conflicting_patch_fails_cleanly(project, run_script):
+    bad = project.root / "patches" / NAME / "0003-change-missing-line.patch"
+    bad.write_text(
+        "diff --git a/greeting.txt b/greeting.txt\n"
+        "--- a/greeting.txt\n"
+        "+++ b/greeting.txt\n"
+        "@@ -1 +1 @@\n"
+        "-a line that is not there\n"
+        "+a replacement\n"
+    )
+
+    result = _run(run_script, project, "apply")
+    assert result.returncode != 0
+    output = result.stdout + result.stderr
+    assert NAME in output and bad.name in output
+    assert _at_clean_pin(project)
+
+
+def test_restore_returns_to_the_pin(project, run_script):
+    assert _run(run_script, project, "apply").returncode == 0
+    (project.sub / "stray-build-output.o").write_text("junk\n")
+
+    result = _run(run_script, project, "restore")
+    assert result.returncode == 0, result.stderr
+    assert _at_clean_pin(project)
diff --git a/third_party/README.md b/third_party/README.md
new file mode 100644
index 0000000..47a68eb
--- /dev/null
+++ b/third_party/README.md
@@ -0,0 +1,44 @@
+# Third-party components
+
+Eikon builds several upstream projects for iOS. This directory holds them as
+git submodules. Any local changes are kept as patch files, not as commits.
+
+## Location and pinning
+
+- Every upstream is a git submodule at `third_party/<name>`, pinned to a tag or commit.
+- `.gitmodules` sets `ignore = dirty` for every submodule, so applied (uncommitted) patches don't show up as changes in the superproject.
+
+## Patches
+
+- Local changes to an upstream live **only** in `patches/<name>/NNNN-short-description.patch`. `<name>` matches the submodule directory name, and `NNNN` is a zero-padded sequence number.
+- To make a patch, commit in the submodule temporarily, export with `git format-patch` against the pinned revision, then reset the submodule.
+- Patches apply in lexical order with `git apply`, to the working tree only. The submodule's `HEAD` never moves, and the superproject never records a patched commit. Never commit inside a submodule, and never bump a gitlink to a patched commit.
+- `make apply-patches` applies them. `make unpatch` resets every submodule to its pin with a clean tree. To work on some components only, name them: `uv run scripts/apply_patches.py apply|restore [names…]`.
+- A patch that doesn't apply stops the run with the component and patch name, and that submodule is reset to its pin.
+- When you bump a pin, regenerate or refresh that component's patches against the new revision in the same commit.
+
+## Out-of-tree builds
+
+Upstream builds must happen **out of tree**, under `build/`. Resetting a submodule fully cleans its working tree (`git clean -ffdx`), which deletes anything built inside it.
+
+## Credits in the same commit
+
+The commit that adds a submodule must also add:
+
+- its credits entry in `third_party/credits.toml`
+- its license texts under `licenses/`
+
+CI enforces this.
+
+## Notes for cross-compiling for iOS
+
+- Compiler: `CC="$(xcrun --sdk iphoneos -f clang) -target arm64-apple-ios15.0"`, with `-isysroot "$(xcrun --sdk iphoneos --show-sdk-path)"`.
+- Build systems:
+  - CMake: `CMAKE_SYSTEM_NAME=iOS`
+  - autotools: `--host=aarch64-apple-darwin`
+  - meson: a cross file with `subsystem='ios'`
+- Set `ac_cv_func_pipe2=no` for the iOS 27 SDK.
+- Homebrew's `bison` and `flex` are keg-only, so put them on `PATH` explicitly.
+- llvm-mingw is the host toolchain for Wine's PE side.
+- Dynamic libraries go in `Frameworks/<name>.framework`, with `@rpath` install names.
+- CI caches are keyed on the dependency build scripts, `patches/**` and the submodule SHAs.
