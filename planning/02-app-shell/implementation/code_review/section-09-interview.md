# Section 09 interview transcript

No items needed the user's input: every finding had a clear fix consistent with the plan or with safety. All were applied as auto-fixes.

## Auto-fixes
- **#1** `LibraryController` schedules a follow-up `rescan()` (quiescence + 1s, coalesced, cancelled on suspend) whenever a location is `waitingForQuiescence`. An import seeds the new location's content stamp as already settled (the copy is complete).
- **#2** `DriveManager.add`/`relink` refuse a folder that is, contains, or lies inside another drive (new `DriveRefusal.overlapsDrive`). `remove(game:)` skips any folder that overlaps another drive's root. Test assertion added: a folder inside `Documents/` is refused.
- **#3** New persisted `GameLocation.isProvisional`: set only by a quick-pass `.newGame`, cleared by merge, split and the full pass. The silent merge now needs an exact match, a provisional location, no other locations, no settings and no fingerprints.
- **#4** Deleted games are passed to the matcher as `isDeleted` rather than dropped.
- **#5** The worker requires the pre-build stamp to equal the stamp the scanner settled on; otherwise the location waits for quiescence again.
- **#6** A detection that throws keeps the cached result; only a clean `nil` means "not recognized".
- **#7** Import validates the final folder name in every naming mode (`.nameTaken`).
- **#8** Relinking the built-in drive is refused.
- **#9** `identify` drops its result if the location was cancelled or its game id changed while it ran.
- **#10** Settings reads (`LibraryIdentity.catalog`) happen outside the index lock.
- **#11** An index file that can't be read (and isn't from a newer build) is renamed to `<name>.unreadable-<time>` instead of being overwritten.
- **#12** A scan stops between folders once a session starts.
- **#13** The scanner leaves a `.fingerprinting` location's identity to the worker.
- **#14** Drive-state dictionary tolerates duplicate ids.
- **#15** Copies never follow symlinks (`COPYFILE_NOFOLLOW`; fallback opens with `O_NOFOLLOW` and checks for a regular file).

## Let go
- **#16** Import racing a scan can briefly mark the location missing; the follow-up scan (#1) corrects it.
