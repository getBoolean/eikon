# Code Review Interview: Section 03 - Submodule and patch convention

**Date:** 2026-09-27

No items needed owner input.

## Auto-fixes
- #1: `_git` removes the repo-locating git variables (`GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_PREFIX`, `GIT_COMMON_DIR`, `GIT_OBJECT_DIRECTORY`) from its environment.
- #2: the default root is the script's own repo first, then cwd.
- #3: after init, the submodule's top-level must equal its path, or the tool fails before touching anything.
- #4: if fetching the SHA fails, fall back to a plain fetch of origin (with tags) and check again.
- #5: `.gitmodules` read errors (anything but "no match") fail.
- #6: submodule paths must be `third_party/<name>`; duplicate names fail.
- #7: if the recovery reset also fails, both errors are reported.
- #8: a file in `patches/<name>/` that isn't `*.patch` is an error.
- #9: the fixture checks the submodule out at the later upstream commit before each test, so `apply` must follow the gitlink.

## Let go
- The init and fetch paths remain without tests (few-tests rule).
