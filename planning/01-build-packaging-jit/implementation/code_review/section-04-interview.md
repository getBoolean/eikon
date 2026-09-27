# Code Review Interview: Section 04 - Credits pipeline

**Date:** 2026-09-27

The plan predates the owner's switch from submodules to fork releases. The adaptation follows that decision (recorded in section 03): credits entries name a `dep`, license files are committed under `third_party/notices/<dep>/`, the notices cite the fork release tag as the corresponding source, and CI no longer needs `submodules: true`.

No review items needed owner input.

## Auto-fixes
- #1: `license` must contain at least one SPDX id, and `license_files` must be non-empty, for components and for nested parts.
- #2: test 3 generates current notices before deleting the file; test 4 asserts that a problem names the bad path.
- #3: the "Credits in the same commit" section of `third_party/README.md` lists the notices directory and the regenerate step.
- #4: the `project` recipe requires the generated file (the placeholder fallback is removed). A bare `xcodegen generate` was checked by hand; the result is recorded in the section doc.
- #5: temp files are removed on failure.
- #6: license files must be regular files, not symlinks, and must resolve inside `third_party/notices/<dep>/`.
- #7: each license text in the app JSON starts with its label.
- #8: deps.py is loaded as `eikon_deps` and registered before it executes.
- #9: SPDX operators are matched case-insensitively.
- #10: labels are built from normalised paths.
