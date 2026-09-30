# Section 11 code review (crash report controller)

Overall matches the plan: consume → history → banner order, alternative rule, privacy (display name only in CrashBanner.gameName). No crash/data-loss bugs in this section.

1. MEDIUM - clipboardNotice sticks across reports and only dismiss() (which also drops the banner) clears it.
2. MEDIUM - tryAlternative trusts a possibly stale banner copy's alternative.
3. LOW-MEDIUM - refreshAlternative can flicker the offer during rescans; document settled-decisions wiring.
4. LOW - consume deletes evidence before history persists; if history is unreadable/read-only the entry lives only this launch. Surface history.unreadableFiles (section 12).
5. LOW - breadcrumbs beyond the last 20 are dropped silently and the clipboard fallback carries no breadcrumbs.
6. LOW - Dependencies.now not @MainActor like its siblings.
7. LOW - comment the deliberately impossible repository URL in the clipboard test.
Note: section 12 must handle a missing/invalid EKRepositoryURL.
