# Section 11 interview transcript

No items needed the user's input.

## Auto-fixes
- **#1** `clipboardNotice` reflects the latest report only; new `acknowledgeClipboardNotice()` clears it without dismissing the banner.
- **#2** `tryAlternative` re-checks the offer (the live banner's, or recomputed) before writing `route.override`.
- **#3** `refreshAlternative` documents that it should be wired to settled library decisions.
- **#6** `Dependencies.now` is `@MainActor`.
- **#7** Comment on the clipboard test's oversized repository URL.

## Let go (recorded for later sections)
- **#4** Unreadable/read-only crash history keeps the entry for this launch only; section 12's unreadable-file warning covers `CrashHistory`.
- **#5** Breadcrumbs beyond the last 20 and the clipboard fallback's missing breadcrumbs: matches the plan; section 16's manual check decides.
- Section 12 must handle a missing or invalid `EKRepositoryURL`.
