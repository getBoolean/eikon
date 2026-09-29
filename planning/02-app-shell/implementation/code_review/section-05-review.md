# Code Review: Section 05 - Settings store

Core sound: LWW merge laws hold, only the own file is written, lock/queue use is correct under Swift 6. Findings:

1. HIGH: numbered fingerprint slots chosen deterministically ("first empty") collide across devices; LWW drops one device's fingerprint, and equal fingerprints can land in different slots (duplicates).
2. HIGH: JSONValue decodes every number as Double, so unknown integer values above 2^53 are rounded on rewrite.
3. MEDIUM: unknown top-level/per-entry fields and undecodable own-file entries are dropped on rewrite.
4. MEDIUM: fork path replaces replica-id before the new file (with forkedFrom) is written; a crash in the debounce window loses the fork marker.
5. MEDIUM: no flush on deinit; pending debounced writes are lost.
6. MEDIUM: HybridClock can overflow on a far-future remote timestamp or non-finite date.
7. MEDIUM: scope mismatches trap via precondition.
8. LOW-MEDIUM: persist failure is not retried.
9. LOW: replica-id restored from backup onto a second device duplicates the replica.
10. LOW: reloadReplicaFiles doesn't mark the own file dirty.
11. LOW: no numeric set/read/reopen test.
