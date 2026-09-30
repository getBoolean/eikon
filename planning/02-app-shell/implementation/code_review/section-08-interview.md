# Section 08 interview transcript

## Asked the user
- **#2 Corrupt gates.json disables persistence forever** → user chose **Self-heal**. Decode failure starts empty and writable; `PersistedFile.save` still refuses newer-format files. Added test `corruptFileIsReplacedOnNextRecord`.
- **#5 Dev builds reuse CFBundleVersion** → user chose **Add commit**. `BuildStamp.app` is "version (build) commit" (commit omitted when "unknown").

## Auto-fixes
- **#1** `BuildStamp.live()`: if version, build or OS build reads "unknown", the app stamp gets a per-process UUID, so a pass never carries over to a later build (it still counts in the run that measured it).
- **#3** `states()`/`current()` resolve duplicate names first-wins (fresh decoded entry precedes raw undecodable ones).
- **#4** `onChange` runs on a private serial queue (`eikon.gates.onChange`), one call at a time.
- **#6** `GateEntry` gets a public init.
- **#7** `GatesDocument` doc comment: new per-gate fields need a `format` bump.

## Let go
- None.
