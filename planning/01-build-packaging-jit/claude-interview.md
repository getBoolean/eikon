# Interview: 01 · Build, packaging, and JIT enablement

Date: 2026-09-27. Asked after the research in `claude-research.md`.

## Research scope (before the interview)

**Q0a. Is there existing code to research?**
Survey the toolchain as proposed. `eikon-source` is for hosting the deb file only.

**Q0b. Web research topics?**
All four:
- Dopamine 2 and TrollStore JIT
- Build system choice
- Entitlements and signing
- Sileo repo on GitHub Pages

## Round 1

**Q1. Build system and UI stack (the spec's open decision)?**
XcodeGen with xcconfig files and a Makefile, and SwiftUI. The app is SwiftUI, with UIKit view controllers for render and input surfaces.

**Q2. TrollStore enable-jit needs `get-task-allow`, which needs Developer Mode on iOS 16+. How should the `.tipa` handle that?**
"TrollStore/AltStore sideloaded apps require Developer Mode already."
Include `get-task-allow`. Developer Mode is already a prerequisite, so it adds no new burden.

**Q3. Which devices are available for Dopamine and TrollStore testing?**
- iPhone 13 mini on iOS 27
- iPad Pro on iPadOS 17.0 (confirmed in Q7 as the 12.9" 6th gen, M2)

**Q4. Where should debs live once they exceed GitHub's 100 MB file limit?**
As GitHub Release assets on `eikon`, with the index on Pages. `Packages` uses absolute `Filename` URLs.

## Round 2

**Q5. How should the deb be verified, given there is no Dopamine 2 device?**
With Dopamine 3 on the iPad (iPadOS 17.0), if Dopamine 3 supports it. Dopamine 3 uses the same check-in JIT mechanism. Dopamine 2 proper stays desktop-verified.

**Q6. Should the deb and `.tipa` include `platform-application`?**
The owner first asked for an explanation. Claude explained:
- It marks the binary as a platform binary.
- It only matters for platform-only private services, cross-process work and root helpers, all of which the project rules out.
- It moves the app to a stricter IOKit sandbox profile, so Metal would need AGX and IOSurface exceptions.
- It can cost the data container unless `storage.AppDataContainers` is added.
- It tightens library validation.

Answer: **No, leave it out.** Record it as "considered, not needed" in the entitlements notes.

**Q7. Which iPad exactly?**
iPad Pro 12.9" 6th generation (M2).

**Q8. How should builds and publishing run?**
GitHub Actions plus a local Makefile:
- CI builds all three artifacts on tags and creates the GitHub Release.
- A deploy key lets CI update the `eikon-source` index.
- `make all` and `make publish` also work locally.

**Q9. What should the no-JIT build do about TXM (iOS 26+, including the iPhone 13 mini on iOS 27)?**
Detect and report only:
- `CS_DEBUGGED`, whether TXM is present, and the probe result.
- Mark JIT "unusable under TXM".
- The blessing protocol is deferred to 05 and 14.

**Q10. What version should the first published build carry?**
0.1.0. The old 1.0.0 index entry is replaced; its deb was never uploaded.

## Round 3

**Q11. How should device reports be produced and kept?**
The app exports JSON through a Copy/Share action. It covers:
- device, iOS, chip, TXM
- install method, build, flavor
- JIT state, source and probe result

A script validates each report and files it in the repo under `device-reports/`. Later splits add their gate fields.

**Q12. What test tooling should the project use?**
Swift Testing for app logic on the simulator, and pytest through uv for scripts and artifact checks.

**Q13. How should the credits pipeline be proven, given 01 adds no upstream code?**
"Limit the tests we add. We want tests to cover features and prevent bugs, not lock in implementation or hard-coded values."
This became a standing preference, saved to memory. The plan keeps tests few and behavioral. For credits, that means showing the check passes with a credited submodule and fails without one. No tests pin file contents or constants.

**Q14. What is the minimum iOS for each artifact?**
iOS 15.0 for all three.

**Q15. What should the main build do when it ends up without JIT?**
Keep running. Show the likely cause for its install method:
- Dopamine: the "Allow JIT in Apps" toggle, Choicy, or Dopamine 2.0.
- TrollStore: the version or the URL scheme setting.

Offer a "Retry JIT" button on TrollStore. Later splits gate JIT routes on the detection API.

**Q16. Should the no-JIT build offer a StikDebug button?**
No, detect only.

## Round 4 (mid-planning)

**Q17. Owner: "Maybe we should combine the JIT and no-JIT builds and handle it appropriately."**
Claude laid out the trade-offs.

- **For:** one archive, no flavor configurations, and graceful fallback when JIT is missing on the deb or `.tipa`. AltStore with JIT from an enabler before TXM can use FEX.
- **Against:** bigger packages once Box64 and the signed Mach-O Wine ship everywhere, and a rewrite of the requirements.

Answer: **Yes, one build, and update the requirements.** `requirements.md`, the manifest, the 01 spec and the specs for 02, 03, 05, 06, 08, 13 and 14 were updated.

This supersedes the flavor parts of Q9 and Q16. The AltStore install still never requests JIT and offers no StikDebug button. TXM with only `CS_DEBUGGED` counts as "JIT present but not usable".
