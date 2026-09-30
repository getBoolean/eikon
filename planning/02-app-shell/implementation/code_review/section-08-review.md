# Section 08 code review (gate store)

Overall: matches the plan on expiry table, current() contents, newer-format read-only, tolerant decoding, lock/onChange, Swift 6. No crash/data-loss/concurrency bugs.

1. MEDIUM - BuildStamp.live(): "unknown" app/OS fallbacks give a constant stamp, so passes never expire if build identity can't be read. Fix: treat unknown stamps as never equal.
2. MEDIUM - init catch sets readOnly on any load error, so a corrupt gates.json disables persistence forever (never self-heals); PersistedFile.save already refuses newer-format files. Fix: don't mark read-only on decode failure, rely on save's check.
3. LOW-MEDIUM - record() can't replace an undecodable raw entry with the same name; TolerantList writes raw entries last, and last-wins uniquing in states()/current() would prefer the stale one in a build that decodes both. Fix: first-wins uniquing.
4. LOW - onChange dispatched to concurrent global queue; notifications can overlap/reorder. Fix: private serial queue.
5. LOW - Dev builds with same CFBundleVersion don't expire passes. Consider adding AppInfo.commit to BuildStamp.app.
6. LOW - GateEntry has no public init.
7. LOW - Unknown fields inside `result` are dropped on rewrite; document that new stored fields need a format bump.
