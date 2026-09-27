# 09 · Languages

## Purpose

Games written for Japanese, Chinese, Korean, and other non-English versions of Windows show their text and open their files correctly on every route. The app's own interface can be translated.

## Read first

- `planning/requirements.md`: Goal 5. "Languages", "Games to support" (most games are Japanese), "Licensing" (credit bundled fonts).
- `planning/deep_project_interview.md`.
- `planning/03-native-kirikiri/spec.md` (encoding hook), `planning/08-wine-media/spec.md`, `planning/02-app-shell/spec.md` (settings, externalized strings).

## Scope

**In:**
- **Per-game code page and locale** (Japanese 932, Simplified Chinese 936, Traditional Chinese 950, Korean 949, Cyrillic, Western), stored in 02's settings and keyed by hash. Suggest a default from detection heuristics, with Japanese as the fallback.
- **Wine:** apply the per-game ANSI/OEM code page, locale, and time zone so non-Unicode programs behave as they would on that Windows version. File names in archives and on disk decode correctly.
- **Fonts:** bundle open-licensed CJK fonts (such as OFL Noto CJK). Map Windows font names that games ask for (MS Gothic, MS Mincho, MS UI Gothic, SimSun, Gulim, and so on) to them. Credit the fonts.
- **Native Kirikiri:** script and archive encoding (Shift-JIS default, per-game override), and font mapping.
- **Native Ren'Py (10):** define what it needs (mostly fonts, since Ren'Py is UTF-8). 10 applies it.
- **App localization:** move the app's text into a localizable catalog, and add a process and tests for missing keys. Which languages ship is the owner's call. At least English, with the process ready for more.

**Out:** translating game text (11).

## Needs

- 03 and 08 (routes that render text), and 02 (settings).

## Provides

- Encoding and font services, which 11 relies on to capture and redraw text correctly. The code-page setting also syncs through 12.

## Done when

- Original test content in Japanese, Chinese, and Korean (non-Unicode Windows programs, and a Shift-JIS `.xp3`) shows correct text and opens files with non-ASCII names on each available route.
- The app runs in a second language through the catalog.
