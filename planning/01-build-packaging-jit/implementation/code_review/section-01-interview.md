# Code Review Interview: Section 01 - Skeleton and tooling

**Date:** 2026-09-27

No items needed owner input; all were low-risk and clear.

## Auto-fixes (applied without asking)
- #1 bootstrap.sh: install `ldid-procursus` unless `brew list --formula ldid-procursus` succeeds.
- #2 conftest.py: `GIT_CONFIG_GLOBAL=/dev/null` for fixture git commands and scripts under test.
- #3 version.sh: an empty `EIKON_BUILD_NUMBER` counts as unset (`${EIKON_BUILD_NUMBER:-}`).
- #4 version.sh: trim only leading/trailing whitespace; a multi-line or inner-space VERSION fails.
- #5 version.sh: capture the tag list first so a git failure stops `--check`.
- #6 version.sh: `diff-index` errors fail instead of adding `-dirty`.
- #7 version.sh: `chmod 644` before the `mv`.
- #8 doctor.sh: anchor the `-M` option match.
- #9 doctor.sh: print a warning line for Python when uv is missing.
- #10 .gitignore: removed the duplicate `deep_implement_config.json` line.
- #11 README: reword the JIT summary line to agree with the AltStore bullet.
- #12 tests: helpers become fixtures (`make_repo`, `run_script`); no imports from conftest.

## Let go
- #13 Makefile test-swift: section 02 already replaces that recipe; noted for section 02.
