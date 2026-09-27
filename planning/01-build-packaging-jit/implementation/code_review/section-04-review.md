# Code Review: Section 04 - Credits pipeline (adapted to fork releases)

Judged against the adapted design (credits keyed by `dep`, license files in `third_party/notices/<dep>/`). The core guard is correct and the output is deterministic. No crash, data-loss or security bug.

1. HIGH: `license_files = []` and `license = ""` pass, so a component can ship with no license text.
2. MEDIUM: tests 3 and 4 leave stale notices, so they depend on the order of checks inside `check()`.
3. MEDIUM: `third_party/README.md` doesn't mention `third_party/notices/<dep>/` or regenerating the notices.
4. LOW: the placeholder fallback in `make project` is unreachable. What does a bare `xcodegen generate` do?
5. LOW: temp files aren't removed on a failed write.
6. LOW: symlinked license files can pull in content from outside the repo.
7. LOW: the app JSON loses the label of each nested license text.
8. LOW: deps.py is loaded under the generic module name "deps".
9. NIT: lowercase SPDX operators are treated as license ids.
10. NIT: a trailing slash in a nested path gives `//` in labels.
