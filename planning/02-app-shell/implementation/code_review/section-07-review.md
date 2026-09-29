# Code Review: Section 07 - Sessions and crash

Matches the plan; C additions async-signal-safe; no title/fingerprint leakage. Findings:

1. HIGH: the length-trimming test never overflows (20 crumbs ≈ 2k chars), so trimming is untested.
2. HIGH (latent): fd reuse race between append/record and close; a slot could be pwritten into an unrelated file.
3. MEDIUM: a corrupt history.json is replaced by an empty document on the next add.
4. MEDIUM: tests hard-code internal breadcrumb event codes.
5. MEDIUM: the query round-trip test doesn't check the full field set.
6. LOW-MEDIUM: a backwards clock step counts any memory warning as recent.
7. LOW: arm overwrites an unconsumed sentinel; setPhase silently no-ops; disarm/consume don't fsync the directory; consume deletes evidence before history.add.
8. LOW: C and Swift share the layout only through hard-coded offsets.
9. LOW: reader accepts a valid slot at the wrong index; truncated file untested.
