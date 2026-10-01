# Section 15: Credits

Plan references: §15 (credits pipeline change), §12.6 (Credits screen), and the Credits rows of the testing strategy in §17.

## What this section delivers

1. `scripts/credits.py app-json` adds an entry for Eikon itself, placed first, and puts an `isApp` flag on every entry.
2. `tests/test_credits.py` gets tests for the new output.
3. A Swift `Acknowledgements` model and loader in EikonKit, with tests in EikonKitTests.
4. The SwiftUI `CreditsView` in the app, reached from the Credits sidebar item.

## Dependencies

- **section-12-strings-navigation** must be done first. It moves `Localizable.strings` to `App/en.lproj/`, reserves the `credits.*` key namespace, and creates `RootView` with a sidebar item for Credits. This section provides the view that item shows. If section 12 left a placeholder for that item, replace it with `CreditsView()`.
- Sections 13 (library UI) and 14 (device screen) can run in parallel with this one. None of them shares files with this section except the strings file and the `RootView` line above.
- Section 16 (landing) depends on this section.

## Background: how credits work today (from split 01)

- `scripts/credits.py` is run from the repo root through `uv`. It has three subcommands: `check`, `notices [--write]`, and `app-json <out>`.
- `make generated` runs `uv run scripts/credits.py app-json build/generated/Acknowledgements.json`. `make project` then passes that path to XcodeGen as `EIKON_ACKNOWLEDGEMENTS_JSON`, and `project.yml` bundles the file into the app as a resource. The app sees it as `Acknowledgements.json` at the root of `Bundle.main`. `scripts/archive.sh` refuses to archive if the file is missing.
- Today `generate_app_json(repo_root, out)` does the following:
  - It calls `_require_clean(repo_root)`. That function raises `ValueError` listing every problem it finds.
  - It builds one object per `[[component]]` in `third_party/credits.toml`, in manifest order. The keys are `name`, `url`, `revision` (`"<repo> release <tag>"`), `license` (an SPDX expression) and `licenseText` (each license file as `"<label>\n\n<text>"`, joined with `"\n"`).
  - It writes the objects with `json.dumps(items, indent=2, sort_keys=True, ensure_ascii=False) + "\n"` through `_write_atomic`.
  - There are no components yet, so the current output is `[]`.
- Useful helpers that already exist in `credits.py`:
  - `EIKON_URL = "https://github.com/getBoolean/eikon"`
  - `LICENSES_DIR = Path("licenses")`
  - `_read_text(path)`, which normalizes CRLF line endings to LF and ensures exactly one trailing newline
  - `_write_atomic`
- `generate_notices` already has an "Eikon" heading. It does not change in this section.
- The app version is in the `VERSION` file at the repo root, as `MAJOR.MINOR.PATCH` with possible surrounding whitespace. The shell scripts read it with `tr -d '[:space:]' <VERSION`.
- Eikon's own license text is committed at `licenses/GPL-3.0-or-later.txt`.
- In `tests/test_credits.py`, the `Project` helper wraps a `git_repo` fixture. It writes `licenses/GPL-3.0-or-later.txt` with the content `"license text\n"` and creates `third_party/deps.toml` and `third_party/credits.toml`. Use `add_dep(name)` and `credit(name)` to add a component. The helper does **not** write a `VERSION` file today.
- No existing test asserts that the app JSON is empty. If one turns up, change it to expect "only the app entry".

## Tests first

The owner's rule: keep tests few, test behavior only, and do not lock in implementation details or hard-coded values. Where possible, compare against values the test itself produced, such as the GPL file it wrote or the version it wrote.

### Python: `tests/test_credits.py`

- Extend the `Project` helper so the fixture repo has a `VERSION` file (for example `repo.write("VERSION", "1.2.3\n")`). Keep the version string in one place on the helper so tests can read it back.
- **Test (app entry only):** in a repo with no third-party components, call `credits.generate_app_json(project.root, out)` with an output path under the temp repo, then parse the JSON. Expect:
  - exactly one entry, with `isApp` true
  - its `licenseText` equal to the contents of the repo's `licenses/GPL-3.0-or-later.txt`, read back from the fixture rather than typed into the test
- **Test (app entry plus one component):** use `project.add_dep("libalpha")`, `project.credit("libalpha")` and `project.save()`, then generate. Expect:
  - two entries
  - the first entry is the app entry
  - exactly one entry has `isApp` true
  - the component's entry has `isApp` false, and its name is the credited name
- Update any existing test that expected an empty array. As of writing there is none.

Sketch:

```python
def test_app_json_has_only_the_app_entry_without_components(project):
    """One entry, marked as the app, carrying the repo's GPL text."""

def test_app_json_lists_components_after_the_app_entry(project):
    """App entry first; only it is marked as the app."""
```

### Swift: `Packages/EikonKit/Tests/EikonKitTests/AcknowledgementsTests.swift`

Use the Swift Testing style that EikonKitTests already uses (`import Testing`, `@Test`, `#expect`, `@testable import EikonKit`).

- **Test:** decoding JSON in the generator's format gives the right entries, with the app entry first. Build the input in the test, with one component entry and one app entry, and put the app entry **second** so the test shows the model puts it first. Check that `isApp` and the other fields survive decoding.
- **Test:** malformed JSON gives an error value or a thrown error rather than a crash. Cover both invalid JSON and a valid JSON value of the wrong shape.

Tests go through the data-level entry point (see the model below) so they don't need a real bundle.

There are no UI tests for `CreditsView` (01 has no UI test target). A DEBUG preview covers its states instead.

## Implementation

### 1. `scripts/credits.py`: the app entry and `isApp`

Change `generate_app_json` so that:

- It prepends one entry for Eikon, built from:
  - `name`: `"Eikon"`
  - `url`: `EIKON_URL`
  - `revision`: `f"getBoolean/eikon {version}"`, where `version` is `VERSION` at the repo root with whitespace stripped
  - `license`: `"GPL-3.0-or-later"`
  - `licenseText`: `_read_text(repo_root / LICENSES_DIR / "GPL-3.0-or-later.txt")`
  - `isApp`: `True`
- Every component entry gets `"isApp": False`. All other fields stay as they are.
- A missing or empty `VERSION` file, or a missing GPL license file, raises `ValueError` with a one-line message that names the file. `main` already turns `ValueError` into exit code 1 with the message on stderr. Raise these alongside the `_require_clean` problems so there is still one failure path.
- The output format is unchanged: indent 2, `sort_keys=True`, UTF-8, trailing newline, atomic write.
- This generator is the only place the Eikon entry is defined. Do not hard-code Eikon in the Swift model or the view.
- Update the module docstring and the `generate_app_json` docstring to say that the app entry comes first and that every entry carries `isApp`.

A suggested small helper, which keeps the Eikon constants beside `EIKON_URL`:

```python
def _app_entry(repo_root: Path) -> dict:
    """Eikon's own acknowledgements entry (isApp: true). Raises ValueError if VERSION
    or licenses/GPL-3.0-or-later.txt is missing."""
```

After the change, `make generated` produces a one-element array. The rebuilt app then shows Eikon on the Credits screen.

### 2. EikonKit model: `Packages/EikonKit/Sources/EikonKit/Credits/Acknowledgements.swift`

Swift 6 language mode, iOS 15. Every type is `Sendable`.

```swift
public struct Acknowledgement: Decodable, Identifiable, Hashable, Sendable {
    public let name: String
    public let url: String          // kept as a string; the view builds a URL if it parses
    public let revision: String
    public let license: String      // SPDX expression
    public let licenseText: String
    public let isApp: Bool          // decodeIfPresent, default false
    public var id: String { ... }   // stable within one file, e.g. name + revision
}

public struct Acknowledgements: Sendable {
    /// App entry (or entries) first, then components in file order.
    public let entries: [Acknowledgement]
    public var app: Acknowledgement? { get }
    public var components: [Acknowledgement] { get }   // entries where !isApp

    /// Decodes the generator's format (a JSON array). Throws on malformed input.
    public static func decode(_ data: Data) throws -> Acknowledgements

    /// Reads `Acknowledgements.json` from the bundle. A missing resource or bad JSON
    /// is returned as a failure and never traps.
    public static func load(bundle: Bundle = .main) -> Result<Acknowledgements, AcknowledgementsError>
}

public enum AcknowledgementsError: Error, Sendable, Equatable {
    case missing
    case malformed
}
```

Behavior:

- Ordering is done in the model: a stable partition puts entries with `isApp` first and keeps file order otherwise. The generator already writes the app entry first, but the view must not depend on that.
- `load(bundle:)` looks up `Acknowledgements.json` with `bundle.url(forResource: "Acknowledgements", withExtension: "json")`. A missing resource gives `.missing`. A read or decode failure gives `.malformed`. No `try!` and no force unwraps.
- Decode `isApp` with `decodeIfPresent`, defaulting to `false`, so an older bundled file still loads.

### 3. App view: `App/Credits/CreditsView.swift`

A SwiftUI view for iOS 15 that uses `NavigationView`-era APIs. It is shown when Credits is selected in `RootView`'s sidebar.

- **Loading:** call `Acknowledgements.load(bundle: .main)` once, for example in `init` or `.task`. Keep the result in the view's state. The file is tiny and bundled, so a synchronous read is fine.
- **List:**
  - The app entry (`isApp == true`, which is Eikon) comes first.
  - Then one row per component, showing its name, SPDX license and revision.
  - Each row is a `NavigationLink` to the detail view.
- **No components:** when `components` is empty, show a caption under the app entry: "Eikon includes no third-party components yet" (`credits.noThirdParty`).
- **Missing or malformed JSON:** show a single error row (`credits.loadError`). The view never crashes, and it shows nothing else.
- **Detail:** a scrolling view that shows:
  - the entry's name, license and revision
  - its URL as a `Link` when `URL(string:)` succeeds, and otherwise as plain text
  - the full `licenseText` in a monospaced font with `.textSelection(.enabled)`
- **Previews (DEBUG):**
  - the app entry only
  - the app entry plus a component
  - the error state

  Build the preview data with `Acknowledgements.decode` on inline JSON. The previews exist so that a missing string key shows up as a raw key.

To keep the view easy to preview, you can split it into an outer view that loads the file and an inner view that takes a `Result<Acknowledgements, AcknowledgementsError>`.

### 4. Strings: `App/en.lproj/Localizable.strings`

Add these keys under the `credits.*` namespace, unless section 12 already added them:

- `credits.title`, for the "Credits" navigation title (reuse the sidebar label key if section 12 defined one)
- `credits.noThirdParty`: "Eikon includes no third-party components yet"
- `credits.loadError`: a short sentence saying the acknowledgements could not be loaded
- labels for the detail fields: `credits.license`, `credits.revision`, `credits.source`

Look up every string with `NSLocalizedString` / `LocalizedStringKey`, never inline literals. Entry names, SPDX ids, revisions and license texts are data, so they are shown as they are.

### 5. Wiring

- `RootView`'s Credits destination shows `CreditsView()`.
- No changes to `project.yml`, the Makefile or `archive.sh`. The JSON is already bundled through `make project` and `make generated`.
- Pick up the new EikonKit source file with the existing package target. No change to `Package.swift` is needed.

## Files

Modify:
- `/Volumes/WD_SN770_1T/dev/GitHub/eikon/scripts/credits.py`
- `/Volumes/WD_SN770_1T/dev/GitHub/eikon/tests/test_credits.py`
- `/Volumes/WD_SN770_1T/dev/GitHub/eikon/App/en.lproj/Localizable.strings` (created by section 12)
- `/Volumes/WD_SN770_1T/dev/GitHub/eikon/App/RootView.swift` (created by section 12; only the Credits destination)

Create:
- `/Volumes/WD_SN770_1T/dev/GitHub/eikon/Packages/EikonKit/Sources/EikonKit/Credits/Acknowledgements.swift`
- `/Volumes/WD_SN770_1T/dev/GitHub/eikon/Packages/EikonKit/Tests/EikonKitTests/AcknowledgementsTests.swift`
- `/Volumes/WD_SN770_1T/dev/GitHub/eikon/App/Credits/CreditsView.swift`

## Done when

- `make test-scripts` passes, including the two new credits tests.
- `make test-swift` passes, including the two `Acknowledgements` tests.
- After `make generated`, `build/generated/Acknowledgements.json` contains exactly one entry, Eikon, with `isApp: true`, the GPL text, and a revision of `getBoolean/eikon <VERSION>`.
- `make check` still passes. The notices output is unchanged.
- In the app, Credits shows Eikon first and the "no third-party components yet" caption. The detail shows the selectable GPL text and the repository link.

## As built

**Files.** As planned:
- `scripts/credits.py`, with `_app_entry`, `EIKON_LICENSE` and `VERSION_FILE`
- `tests/test_credits.py` (2 new tests; `Project` writes `VERSION` with `Project.version`)
- `Packages/EikonKit/Sources/EikonKit/Credits/Acknowledgements.swift`
- `Packages/EikonKit/Tests/EikonKitTests/AcknowledgementsTests.swift`:
  - 2 tests, one of them parameterized over 3 malformed inputs
  - the decode test also checks that an entry without `isApp` reads as a component
- `App/Credits/CreditsView.swift`
- `RootView`'s placeholder view was removed

**Generator.**
- Problems with `VERSION` or `licenses/GPL-3.0-or-later.txt` are reported together with `_require_clean`'s problems, in one `ValueError`. This covers missing or empty files and read errors.
- `make generated` writes one entry: Eikon, `isApp: true`, revision `getBoolean/eikon <VERSION>`.
- `make check` and the notices output are unchanged.

**View.**
- `CreditsView` loads the file once, into a `static let`. iOS 15 builds sidebar destinations eagerly, so `@State` initialization would re-read the file on every update.
- `CreditsContent` takes the load result, and the previews render it.
- The "no third-party components" caption is the app section's footer. It shows only when the app entry exists.
- The detail view shows license, revision and source, then the selectable license text. The entry's name is the navigation title.
- The URL is linked only when it parses with a scheme.

**Verification:** `make test` passes, along with `make generated` and `make check`. The Credits screen itself was not checked on the simulator; that is left for section 16's device pass.
