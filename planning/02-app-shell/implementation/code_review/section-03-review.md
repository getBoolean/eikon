# Code Review: Section 03 - Identity

Overall the code follows the plan closely: matcher rule order, scheme gating, 4-hop link resolution with lowest-member cycle breaking, value-type settings forks, GEN8 field offsets and FileHasher all check out.

## HIGH
1. Rule 4 (name similarity) can silently attach to the wrong game: no minimum name-set size, and engines reaching rule 4 (BGI, Kirikiri with generic version info, default Unity builds) have engine-standard top-level layouts, so unrelated games can reach Jaccard >= 0.8 and attach silently when the other game is not live here. Suggest a minimum union size, more engine-standard generic names, or make rule 4 suggest-only.
2. OS metadata files (.DS_Store, ._* AppleDouble, Thumbs.db, desktop.ini) enter the exact signal and name set, so rule 2 fails exactly on moves between drives. Filter them in FingerprintBuilder.

## MEDIUM
3. An unreadable key file is silently dropped from the exact signal, giving a bogus listing-only fingerprint. Throw instead; ideally re-locate the key file at fingerprint time (stale DetectionResult.keyFile).
4. LibrarySecret.loadOrCreate is check-then-write; concurrent creators can each write a different secret. Use no-replace creation. Prefer SymmetricKey(size:) over SecRandomCopyBytes.
5. IdentityLedger.merge resolves b but not a.
6. Merge appends A's fingerprints after B's, so the cap drops B's newest builds.

## LOW
7. The fileSize test adds a file instead of changing an existing file's size; subdirectory size changes are not in the exact signal (document the gap).
8. Engine-id prefix uses detection.engine even for exe version info; a reclassification changes engineID.
9. LocationKey.folderName is publicly mutable, bypassing normalization.
10. unityAppInfo drops empty lines, so an empty company line shifts the product.
11. Document that match() expects resolved ids.
