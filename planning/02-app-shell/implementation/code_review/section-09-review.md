# Section 09 code review (game drives and the library)

HIGH
1. Nothing schedules the second scan quiescence needs: imports, copies, retries and the worker's changed-while-hashing branch sit in "Waiting for copy" until the next scene activation. Fix: schedule a follow-up rescan when any location is waiting; seed an import's stamp as already settled.
2. Overlapping drives (a folder inside Documents, the same folder twice, a parent of a drive): doubles games, and "Delete files" can remove another drive's root. Fix: refuse overlapping add/relink; in remove, skip folders that are or contain another drive's root.
3. Silent merge isn't limited to provisional games (firstBuild && !hasSettings): undoes a split, merges an established game after an accepted suggestion or an engine-id attach. Fix: exact rule only, no fingerprints, no other locations; persist a provisional marker.

MEDIUM
4. Deleted games are dropped from knownGames, which defeats the matcher's rule-1 deleted guard (fingerprints written onto a deleted game). Fix: pass them with isDeleted.
5. The worker never checks that the folder is still in the state the scanner settled on; a partial copy can be fingerprinted. Fix: require before == lastSeen.contentStamp.
6. A transient detection error (try? → nil) hides a known game. Fix: keep the cached detection on throw.
7. Import accepts names the scanner never sees (dot names, Inbox on built-in) with .original/.replaceExisting. Fix: validate the final name in every mode.
8. relink can turn the built-in drive into a folder drive. Fix: guard .builtIn.
9. The worker can write after removal (fingerprint newer than deletedAt) or overwrite a user split/merge. Fix: re-check cancellation, compare-and-set the gameID.
10. knownGames/settings reads run under the index lock and stall main-actor reads. Fix: compute outside the lock.
11. A corrupt drives.json self-heals by losing every bookmark. Fix: set unreadable files aside.

LOW
12. Suspend doesn't stop a running scan. Fix: check between folders.
13. Scanner's detection-nil and stamp-failure branches overwrite .fingerprinting. Fix: check it first.
14. Dictionary(uniqueKeysWithValues:) over drives traps on duplicate ids.
15. copyfile / FileHandle follow a symlink swapped in after enumeration. Fix: COPYFILE_NOFOLLOW, O_NOFOLLOW + fstat.
16. Import racing a scan briefly shows the game missing (harmless; covered by 1).
