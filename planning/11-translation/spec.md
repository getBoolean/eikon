# 11 · Translation

## Purpose

Capture the text a game shows, translate it into the user's language with a backend the user picks, and show the translation over the game while it runs. Users can correct recurring terms.

## Read first

- `planning/requirements.md`: Goal 6. "Translation", "Constraints" (privacy), "Test data" (game text sent to backends during testing).
- `planning/deep_project_interview.md`.
- `planning/09-languages/spec.md`, plus the capture hooks named in `03`, `08`, and `10`.

## Scope

**In:**
- **Capture,** best source first:
  - native Kirikiri: the message layer text (03's hook)
  - native Ren'Py: dialogue and menu text (10's hook)
  - Wine: text drawing calls (GDI/Uniscribe/DirectWrite and similar) in Eikon's Wine, plus engine-specific hooks where generic capture fails
  - OCR of the game view as a last resort. Check which iOS versions support Japanese, Chinese, and Korean recognition.
  - Cleanup: de-duplication, merging lines that belong together, ruby and furigana, and control codes.
- **Backends:**
  - Online, with the user's own key: an LLM through the Anthropic API (glossary and recent context in the prompt), plus others such as DeepL.
  - On device: Apple's Translation framework where the iOS version supports it. The Dopamine range (iOS 15–16.6.1) predates it, so provide a downloadable model or explain why none is available.
- Store keys in the Keychain. Cache translations keyed by text hash.
- **Glossary:** per-game corrections for recurring terms (such as character names), applied before and after translation. Store it in a **CRDT-ready shape** so 12 can sync it.
- **Overlay:** show the translation over the game, with positioning, style, show/hide, and a history log. Taps must not reach the game when the overlay handles them.
- **Privacy:** translation is off until the user turns it on for a game. The screen names the service that would receive game text. Nothing is sent except through a backend the user turned on. No game text in logs.

**Out:** code pages and fonts (09), and syncing the glossary (12).

## Needs

- 09 (correct decoding), and capture points from 03, 08, and 10.

## Provides

- The glossary data (12).

## Done when

- Original Japanese test content on each available route is captured, translated by a real online backend and by an on-device backend, and shown as an overlay.
- A glossary correction changes the output.
- No text leaves the device while translation is off. A test proves this.
