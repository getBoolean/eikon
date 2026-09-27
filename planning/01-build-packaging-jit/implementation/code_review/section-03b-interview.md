# Code Review Interview: Section 03 (rework) - Third-party libraries from fork releases

**Date:** 2026-09-27

Before this review, the owner redirected the design twice: from submodules to forks with commit pins ("we should avoid submodules, they are a pain to work with"), then to fork releases ("we should use releases to distribute the libraries instead of pinning to a commit"). The review of the intermediate commit-pin design was superseded unapplied, together with that design.

No review items needed owner input.

## Auto-fixes
- #1, #2, #8: stamps move out of the trees to `build/deps/.stamps/<name>`. Each stamp holds the pin and a SHA-256 for every unpacked file, and is written last. A replacement first removes the stamp, moves the old tree aside, renames staging into place, writes the stamp, then deletes the old tree. `verify` re-hashes the files.
- #3: `check` rejects assets that look like tar archives in a format tarfile can't read. Only `.tar`, `.tar.gz`/`.tgz`, `.tar.xz`/`.txz`, `.tar.bz2`/`.tbz2`, `.zip` and plain single files are accepted.
- #4: `pin` compares the full parsed tables (every key), reads and writes bytes, and keeps line endings.
- #5: `pin` refuses a tag and asset that are already pinned but now hash differently; publish a new tag instead.
- #6: archive, network and filesystem errors become one-line errors naming the dependency; `.part` files are removed on any failure.
- #7: `verify` fails on directories in `build/deps` that aren't in the manifest. A `fetch` of all dependencies removes them, along with leftover staging directories.
- #9, #12: the README notes that zip drops the executable bit (prefer tar) and that forks must be public.
- #10: `pin` downloads straight into the cache.
- #11: a download shorter than its Content-Length is reported as truncated.
- Tests: test 1 also checks that editing an unpacked file fails `verify`. A new case checks that an archive with a member escaping the tree is rejected and leaves nothing unpacked.
