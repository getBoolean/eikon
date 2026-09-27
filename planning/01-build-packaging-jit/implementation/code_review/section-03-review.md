# Code Review: Section 03 - Submodule and patch convention

The implementation matches the plan: the README bullets, `.gitkeep`, the CLI with `--repo-root`, the orphan and unknown-name errors, a no-op without `.gitmodules`, and four behavioural tests.

1. HIGH: `_git` inherits `GIT_DIR`, `GIT_WORK_TREE` and similar variables (from hooks, `submodule foreach`, CI wrappers), so `reset --hard` and `clean -ffdx` could hit the superproject.
2. MEDIUM: `_default_root` checks cwd before the script's own repo; the spec's order is the reverse.
3. MEDIUM: a successful `submodule update --init` might leave no repo at the path (`update=none`), and `clean -ffdx` would then run in a plain superproject directory.
4. LOW: fetching an unadvertised SHA fails on some servers; fall back to a plain fetch.
5. LOW: a malformed `.gitmodules` is treated as "no submodules".
6. LOW: component-name collisions; paths not directly under `third_party/`.
7. LOW: a failing recovery reset replaces the error that names the patch.
8. LOW: non-`.patch` files in `patches/<name>/` are silently ignored.
9. Tests: the post-pin upstream commit proves nothing, because the submodule is never moved off the pin.
