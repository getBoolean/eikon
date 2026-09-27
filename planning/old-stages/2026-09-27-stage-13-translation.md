# Stage 13: Integrated translation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While a game runs, Eikon captures the text it draws, translates it into the user's language, and shows the translation over the game. The user picks the translation engine: an online service with their own key, or an on-device model.

**Architecture:** Four layers, each testable alone.

1. **Capture** turns what the game draws into `EikonTextEvent`s. There are three sources, best first:
   - `kirikiri`: a hook in the stage 11 engine's text drawing. Exact text, exact position.
   - `wine`: hooks in Eikon's Wine build, in `win32u` text output (`NtGdiExtTextOutW`) and glyph requests (`NtGdiGetGlyphOutline`). Many visual-novel engines draw one glyph at a time through `GetGlyphOutline`, so the assembler (layer 2) rebuilds lines from glyphs. Eikon builds its own Wine, so this needs no injection into the game.
   - `ocr`: Apple's Vision text recognition on the presented frame. This covers engines that draw text from their own font textures, which includes Unity. It is the fallback, and it is off unless the user turns it on for a game.
2. **Assembly** merges glyphs and partial draws into whole lines. It drops repeats, and handles the typewriter effect, where a line is drawn again with one more character each time.
3. **Translation** sends finished lines to the chosen backend, with the previous few lines as context and the game's glossary. Results are cached.
4. **Overlay** shows the translation in a bar over the game view. It is shown, not drawn into the game.

**Tech Stack:** C for assembly and the cache (host-testable), Objective-C for backends and UI, SQLite, `NSURLSession`, Keychain, Vision, the Translation framework where available, and one bundled on-device model runtime (chosen in Task 3).

## Global Constraints

- Translation is off by default, for every game.
- With an online backend, the settings screen names the service that receives game text before the user turns it on. Only captured lines, their context lines, and the glossary are sent: no screenshots, file names, or titles. OCR runs on the device either way.
- API keys are stored in the Keychain, never in files or logs.
- Cache and glossary are local and keyed by a hash of the game's main executable or archive. No title is recorded.
- Test sentences are original text written for this repo. No game scripts.
- Tasks 1 to 3 need only stage 1. Task 4 also needs stage 12 Task 1 (app strings). Task 5 needs stage 11. Task 6 needs stages 5 and 12. Task 7 needs stage 5 or 11. Source language comes from stage 12's per-game locale.

---

### Task 1: Assembly and cache

**Files:**
- Create: `src/translate/eikon_text.h`
- Create: `src/translate/eikon_text.c`
- Create: `src/translate/eikon_tcache.c`
- Test: `tests/host/test_eikon_text.c`

**Interfaces:**
- Consumes: nothing
- Produces:

```c
typedef enum { EIKON_TEXT_KIRIKIRI, EIKON_TEXT_WINE, EIKON_TEXT_OCR } EikonTextSource;

typedef struct {
    EikonTextSource source;
    const char *utf8;     // one glyph, a run, or a whole line
    int x, y, w, h;       // client coordinates
    double t;             // seconds, monotonic
} EikonTextEvent;

typedef void (*EikonLineFn)(const char *utf8_line, void *ctx);

typedef struct EikonAssembler EikonAssembler;
EikonAssembler *eikon_assembler_new(EikonLineFn fn, void *ctx);
void eikon_assembler_push(EikonAssembler *a, const EikonTextEvent *e);
void eikon_assembler_tick(EikonAssembler *a, double now); // flushes idle lines
void eikon_assembler_free(EikonAssembler *a);

// Cache: key is (game hash, backend id, target language, source line).
int eikon_tcache_open(const char *path);
const char *eikon_tcache_get(const char *game, const char *backend, const char *lang, const char *line);
int eikon_tcache_put(const char *game, const char *backend, const char *lang, const char *line, const char *out);
```

Rules: events on the same baseline (within half a line height) that are less than 150 ms apart join one line. A line flushes after 300 ms with no new event. When a new line starts with the previous unflushed line's text, it replaces that line (typewriter effect). A flushed line that is the same as the last flushed line is dropped.

- [ ] **Step 1: Write the host test**

Cases:
- glyphs `日`, `本`, `語` at x = 0, 20, 40 on one baseline, 10 ms apart: one line, `日本語`
- typewriter draws `こ`, `こん`, `こんに`: one line, `こんに`
- the same line twice with a 1-second gap: emitted once
- two baselines: two lines, top first
- cache round trip, and a miss for a different target language

Compile with the system compiler against `eikon_text.c`, `eikon_tcache.c`, and `-lsqlite3`. Expected exit 0.

- [ ] **Step 2: Implement until it passes**

- [ ] **Step 3: Commit**

```bash
git add src/translate tests/host/test_eikon_text.c
git commit -m "Assemble drawn text into lines and cache translations."
```

### Task 2: Backend interface and online backends

**Files:**
- Create: `src/translate/EikonTranslator.h`
- Create: `src/translate/EikonFakeTranslator.m`
- Create: `src/translate/EikonDeepLTranslator.m`
- Create: `src/translate/EikonLLMTranslator.m`
- Create: `src/translate/EikonKeychain.m`
- Test: `tests/test_translate_requests.py`

**Interfaces:**
- Consumes: Task 1's cache
- Produces:

```objc
@protocol EikonTranslator <NSObject>
@property (readonly) NSString *backendID;   // "fake", "deepl", "llm", "apple", "local"
@property (readonly) BOOL sendsTextOffDevice;
- (void)translateLine:(NSString *)line
              context:(NSArray<NSString *> *)previousLines
             glossary:(NSDictionary<NSString *, NSString *> *)glossary
                 from:(NSString *)sourceLanguage   // BCP 47, from stage 12's locale
                   to:(NSString *)targetLanguage   // device language by default
           completion:(void (^)(NSString *_Nullable out, NSError *_Nullable error))completion;
@end
```

- `fake` returns `[<to>] ` plus the input. It is used for device acceptance, so no key is needed to test.
- `deepl` calls `POST /v2/translate` on `api.deepl.com` or `api-free.deepl.com`, chosen by the key type, with the header `Authorization: DeepL-Auth-Key <key>`. The glossary is sent as a DeepL glossary when there is one.
- `llm` calls the Anthropic Messages API (`POST https://api.anthropic.com/v1/messages`, headers `x-api-key` and `anthropic-version: 2023-06-01`). The model id is a setting, defaulting to `claude-sonnet-5`; the user can choose a faster, cheaper model such as `claude-haiku-4-5`. The system prompt asks for a translation of the last line only, keeping names as the glossary gives them, and returning the translation and nothing else. Context lines are included, marked as context.

Every backend first checks the Task 1 cache, and stores what it gets back.

- [ ] **Step 1: Request tests**

Each online backend has a class method that builds its `NSURLRequest` without sending it. `tests/test_translate_requests.py` checks the source of these builders for the URL, the headers, and that the key comes from `EikonKeychain`. A device check with the `fake` backend covers the rest.

- [ ] **Step 2: Implement and commit**

```bash
git add src/translate tests/test_translate_requests.py Makefile
git commit -m "Add the translator interface and the online backends."
```

### Task 3: On-device backend

**Files:**
- Create: `src/translate/EikonAppleTranslator.m`
- Create: `src/translate/EikonLocalTranslator.m`
- Create: `docs/translation-models.md`
- Create: `tests/translation/ja-en.tsv`, `tests/translation/zh-en.tsv`, `tests/translation/ko-en.tsv`

**Interfaces:**
- Consumes: Task 2's protocol
- Produces: `apple`, which uses Apple's Translation framework and exists only on iOS 18 and later, and `local`, a bundled model that works on every supported iOS version. Dopamine devices run iOS 15 or 16, so `local` is the on-device choice there.

- [ ] **Step 1: Write the test sets**

Each `.tsv` has 50 original source sentences in visual-novel style (dialogue, narration, and a few names), each with a reference English translation. Write them for this repo. Do not copy them from games.

- [ ] **Step 2: Choose the local model**

Compare at least two options:
- a dedicated translation model per language pair, such as Opus-MT (Marian) run with CTranslate2
- a small multilingual LLM run with llama.cpp on Metal

For each, record in `docs/translation-models.md`: license, download size, peak memory, seconds per line on the test device, and quality on the three test sets (chrF against the references, plus a short note after reading the output). Pick one.

Models are downloaded on demand into `EikonDataURL()/models/`, never shipped in the deb. The download screen shows the size before starting.

- [ ] **Step 3: Implement both backends and commit**

`apple` reports itself unavailable below iOS 18, and the settings screen hides it.

```bash
git add src/translate docs/translation-models.md tests/translation Makefile
git commit -m "Add the on-device translation backends."
```

### Task 4: Settings and overlay

**Files:**
- Create: `src/translate/EikonTranslationSettings.m`
- Create: `src/translate/EikonOverlayView.m`
- Modify: `Resources/en.lproj/Localizable.strings`

**Interfaces:**
- Consumes: Tasks 1 to 3
- Produces:
  - a global settings screen: backend picker, API key fields, model id for `llm`, target language (defaulting to the device language), and model downloads for `local`
  - per-game settings: translation on or off, OCR on or off, source language (defaulting to stage 12's locale), and a glossary editor
  - `EikonOverlayView`, a bar at the bottom of the game view showing the latest line and its translation. Tapping the bar pauses it and shows the last 20 lines. Tapping a line lets the user add a glossary entry.

- [ ] **Step 1: Build the screens**

When the user picks a backend with `sendsTextOffDevice == YES`, show a one-time notice naming the service before it is enabled. All strings go through `Localizable.strings` (stage 12).

- [ ] **Step 2: Commit**

```bash
git add src/translate Resources
git commit -m "Add translation settings and the overlay."
```

### Task 5: Capture from native Kirikiri

**Files:**
- Modify: `src/kirikiri/EikonKirikiriView.m`
- Create or modify: a patch in `patches/<engine>/` that reports each `drawText` call

**Interfaces:**
- Consumes: stage 11, and Tasks 1 and 4
- Produces: `EIKON_TEXT_KIRIKIRI` events from the engine's text drawing

- [ ] **Step 1: Hook and test**

Device: run stage 11's archive with translation on and the `fake` backend. Expected overlay: `こんにちは、世界。` and `[en] こんにちは、世界。`. Log `translate_kirikiri=ok`. Then repeat with `llm` or `deepl` and a real key, and check that the English makes sense.

- [ ] **Step 2: Commit**

```bash
git add src/kirikiri patches
git commit -m "Capture native Kirikiri text for translation."
```

### Task 6: Capture from Wine

**Files:**
- Create: `src/host/win32u_text_darwin.c`
- Create: `demos/windows/text/main.c`

**Interfaces:**
- Consumes: stage 5's win32u driver and app channel, and Tasks 1 and 4
- Produces: `EIKON_TEXT_WINE` events for `ExtTextOutW`, `ExtTextOutA` (converted with the game's code page), and `GetGlyphOutlineW` / `GetGlyphOutlineA` with `GGO_BITMAP` or `GGO_GRAY*_BITMAP` formats. Glyph events use the pen position the game draws at when Wine knows it, and otherwise the order of requests.

- [ ] **Step 1: Guest**

`demos/windows/text/main.c` draws `日本語のテスト` twice: once with one `ExtTextOutW` call, and once one character at a time through `GetGlyphOutlineW`, blitting each glyph, 30 ms apart. It uses stage 12's `ja_JP` locale and fonts.

- [ ] **Step 2: Device**

With the `fake` backend, the overlay shows the line once for each drawing method, and both lines are identical. Log `translate_wine=ok`.

- [ ] **Step 3: Commit**

```bash
git add src/host/win32u_text_darwin.c demos/windows/text
git commit -m "Capture Wine text drawing for translation."
```

### Task 7: OCR fallback

**Files:**
- Create: `src/translate/EikonOCRCapture.m`

**Interfaces:**
- Consumes: the presented frame (stage 5's bitmap, or stage 6's Metal layer through a snapshot), and Tasks 1 and 4
- Produces: `EIKON_TEXT_OCR` events from `VNRecognizeTextRequest`, at most twice a second, and only when the frame has changed

- [ ] **Step 1: Record language support**

At run time, log `VNRecognizeTextRequest`'s supported recognition languages for this iOS version into `probe.log` as `ocr_languages=`. Japanese and Korean may not be available on iOS 15. If the game's source language is missing, the per-game OCR switch is disabled and says why.

- [ ] **Step 2: Device**

Run the Task 6 guest with Wine capture turned off and OCR on. Expected: the overlay shows the line, allowing OCR errors, and log `translate_ocr=ok`.

- [ ] **Step 3: Commit**

```bash
git add src/translate
git commit -m "Add OCR capture as the translation fallback."
```
