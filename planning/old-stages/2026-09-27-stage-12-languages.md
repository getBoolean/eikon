# Stage 12: Languages

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Games written for Japanese, Chinese, Korean, or other non-English Windows show their text and open their files correctly. The app's own screens can be translated.

**Architecture:** Three separate pieces.

1. **Guest locale, per game.** Older Windows programs use the system's "ANSI" code page for text and file names: 932 for Japanese, 936 for Simplified Chinese, 950 for Traditional Chinese, 949 for Korean, 1251 for Cyrillic, and 1252 for Western European. Wine takes the code page from the locale of the process that starts it. Each game gets a locale setting, and `eikon-wine` is started with the matching `LANG` and `LC_ALL` (for example `ja_JP.UTF-8`) and the matching Wine locale registry values. This does what Locale Emulator does on Windows, but for one process at a time.
2. **Fonts.** Games ask for Windows fonts by name, such as MS Gothic, MS Mincho, SimSun, and Gulim, and Wine does not ship them. Eikon bundles OFL-licensed CJK fonts and maps those names to them with Wine's `FontSubstitutes` registry key. The native Kirikiri engine (stage 11) gets the same fonts. Do not copy iOS system fonts into the guest; their license does not cover that use.
3. **App text.** The app's own strings move to `Localizable.strings`, with English as the base. Other languages are added as translated `.strings` files. No other app code changes are needed to add a language.

**Tech Stack:** Wine locale and registry, Noto Sans CJK or Source Han (SIL OFL 1.1), `NSLocalizedString`.

## Global Constraints

- The locales supported at first are `ja_JP` (932), `zh_CN` (936), `zh_TW` (950), `ko_KR` (949), `ru_RU` (1251), and `en_US` (1252). Adding one is a table row in `src/host/eikon_locale.c`, not new code.
- A game's locale is stored with its settings, keyed by a hash of its main executable or archive. No title is recorded.
- Fonts are OFL-licensed. Their license files ship in the deb.
- Guest tests are original. No program titles.
- Tasks 2 and 3 need stage 5's window. Task 4 needs stage 11. Task 1 needs only stage 1.

---

### Task 1: App strings

**Files:**
- Create: `Resources/en.lproj/Localizable.strings`
- Modify: `src/RootViewController.m` and every file with visible text
- Modify: `tests/test_shell_copy.py`
- Test: `tests/test_localization.py`

**Interfaces:**
- Consumes: stage 1's screen
- Produces: every visible string loaded through `NSLocalizedString(key, comment)`. Keys are stable English identifiers such as `shell.not_emulator`.

- [ ] **Step 1: Write the failing test**

```python
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def strings_keys(path):
    return set(re.findall(r'^"([^"]+)"\s*=', path.read_text(encoding="utf-8"), re.M))

def test_every_language_has_every_key():
    base = strings_keys(ROOT / "Resources" / "en.lproj" / "Localizable.strings")
    assert base
    for lproj in (ROOT / "Resources").glob("*.lproj"):
        assert strings_keys(lproj / "Localizable.strings") == base, lproj.name

def test_sources_use_keys_not_literals():
    for src in (ROOT / "src").rglob("*.m"):
        text = src.read_text(encoding="utf-8")
        assert not re.search(r'\.text\s*=\s*@"[A-Za-z]', text), src
```

Run: `python3 -m pytest tests/test_localization.py -v`

Expected: FAIL

- [ ] **Step 2: Move the strings**

Move stage 1's paragraphs into `en.lproj/Localizable.strings`. Change `tests/test_shell_copy.py` to read that file instead of `src/*.m`, and keep its assertions. `Not a working emulator` and `Not a jailbreak tool` must stay in the English file.

Run: `python3 -m pytest tests/ -v`

Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add Resources src tests/test_localization.py tests/test_shell_copy.py
git commit -m "Load the app's visible text from Localizable.strings."
```

### Task 2: Guest locale

**Files:**
- Create: `src/host/eikon_locale.h`
- Create: `src/host/eikon_locale.c`
- Create: `demos/windows/locale/main.c`
- Create: `demos/windows/locale/make_names.py`
- Test: `tests/host/test_eikon_locale.c`, `tests/test_locale_guest.py`

**Interfaces:**
- Consumes: stage 4's `eikon-wine` spawn
- Produces:

```c
typedef struct {
    const char *id;       // "ja_JP"
    unsigned codepage;    // 932
    const char *lang;     // "ja_JP.UTF-8"
} EikonLocale;

const EikonLocale *eikon_locale_find(const char *id); // NULL if unknown
// Fills envp entries LANG and LC_ALL for posix_spawn.
int eikon_locale_env(const EikonLocale *locale, char **envp, size_t cap);
```

- [ ] **Step 1: Host test**

`tests/host/test_eikon_locale.c` checks every row: `ja_JP` is 932, `zh_CN` 936, `zh_TW` 950, `ko_KR` 949, `ru_RU` 1251, `en_US` 1252, and an unknown id returns `NULL`.

- [ ] **Step 2: The guest**

`demos/windows/locale/main.c` is i386 and uses only `A` (ANSI) APIs, as older games do. It:

1. writes `GetACP()` in decimal to `acp.txt`
2. opens a file whose name is the Shift-JIS bytes of `テスト.txt` with `CreateFileA`, and fails if the open fails
3. converts the Shift-JIS bytes of `日本語` with `MultiByteToWideChar(CP_ACP, ...)`, and writes the result as UTF-16LE to `wide.txt`

`make_names.py` creates `テスト.txt` in the guest root. `tests/test_locale_guest.py` checks that the source uses `CreateFileA`, `GetACP`, and `MultiByteToWideChar`.

- [ ] **Step 3: Oracle and device**

Desktop oracle: `LANG=ja_JP.UTF-8 wine locale.exe`. Expected: `acp.txt` is `932`, and `wide.txt` decodes to `日本語`.

Device: button `Run locale`, with the game locale set to `ja_JP`. Same files expected. The log gains `locale=0`.

- [ ] **Step 4: Commit**

```bash
git add src/host/eikon_locale.h src/host/eikon_locale.c demos/windows/locale tests/host/test_eikon_locale.c tests/test_locale_guest.py
git commit -m "Start each guest with its own Windows code page."
```

### Task 3: Fonts

**Files:**
- Create: `Resources/fonts/` (font files and their `OFL.txt`)
- Create: `src/host/eikon_fonts.c`
- Create: `demos/windows/fonts/main.c`
- Modify: `docs/build-wine-ios.md`

**Interfaces:**
- Consumes: Task 2
- Produces: a guest font directory and `FontSubstitutes` entries for MS Gothic, MS PGothic, MS UI Gothic, MS Mincho, MS PMincho, Meiryo, SimSun, SimHei, NSimSun, MingLiU, PMingLiU, Gulim, Dotum, and Batang

- [ ] **Step 1: Bundle and map**

Bundle a sans and a serif CJK family. Record the exact files, versions, and sizes in `docs/build-wine-ios.md`, since CJK fonts are large and add to the deb. `eikon_fonts.c` writes the registry entries into the prefix on first run. Sans names map to the sans family, and Mincho, SimSun, MingLiU, and Batang map to the serif family.

- [ ] **Step 2: Guest**

`demos/windows/fonts/main.c` creates `MS Gothic` with `CreateFontA` and `SHIFTJIS_CHARSET`. It draws `日本語` with `ExtTextOutW` into a memory DC and checks that `GetGlyphIndicesW` finds no missing glyphs (`0xFFFF`) for those three characters. It writes `glyphs=ok` or `glyphs=missing:<n>` to `fonts.txt`.

Device: button `Run fonts`. Expected `glyphs=ok`, and log `fonts=0`.

- [ ] **Step 3: Commit**

```bash
git add Resources/fonts src/host/eikon_fonts.c demos/windows/fonts docs/build-wine-ios.md
git commit -m "Bundle CJK fonts and map Windows font names to them."
```

### Task 4: Native Kirikiri

**Files:**
- Modify: `src/kirikiri/EikonKirikiriView.m`
- Modify: `demos/kirikiri/data/startup.tjs`

**Interfaces:**
- Consumes: stage 11, and Task 3's fonts
- Produces: the stage 11 engine loads fonts from the Task 3 set, and reads a Shift-JIS script without a BOM when the game's locale is `ja_JP`

- [ ] **Step 1: Add a Shift-JIS script and run it**

Add `demos/kirikiri/data/sjis.tjs`, saved as Shift-JIS without a BOM, which draws `日本語`. `startup.tjs` loads it. Expected on device: both lines render.

- [ ] **Step 2: Commit**

```bash
git add src/kirikiri demos/kirikiri
git commit -m "Use the shared CJK fonts and code page in native Kirikiri."
```
