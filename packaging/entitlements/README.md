# Entitlements

Eikon ships one binary in three packages. They differ only in entitlements, one
Info.plist stamp (`EKPackageKind`) and container format. These plists are what
`scripts/package.sh` signs each artifact with, and what `scripts/verify_artifacts.py`
checks the signed artifacts against.

## Keys, and which install methods honour them

| Key | deb | tipa | ipa | Purpose and who honours it |
|---|---|---|---|---|
| `com.apple.private.security.no-sandbox` | ✓ | ✓ | – | Runs outside the app sandbox. Honoured by Dopamine and TrollStore installs (ad-hoc / TrollStore signing). AltStore can't grant it, so the ipa leaves it out. |
| `get-task-allow` | – | ✓ | ✓ | Lets another process attach. TrollStore's enable-jit helper attaches to set `CS_DEBUGGED`. AltStore's developer profile carries it too. The deb leaves it out (Dopamine doesn't need it, and on iOS 16+ it would force Developer Mode). |
| `com.apple.developer.kernel.increased-memory-limit` | ✓ | ✓ | ✓ | Raises the per-app memory cap. A public App ID capability, so AltStore requests it from the developer account. |
| `com.apple.developer.kernel.extended-virtual-addressing` | ✓ | ✓ | ✓ | Allows a larger virtual address space. Also a public App ID capability. |
| `com.apple.private.memorystatus` | ✓ | ✓ | – | Adjusts the memorystatus (jetsam) limits. A private key AltStore can't grant, so the ipa leaves it out. |

## Unverified

- Whether the two `com.apple.developer.kernel.*` memory keys have any effect under Dopamine's ad-hoc signing. Evidence: the device report's `memory.availableBytes`.
- Whether an AltStore **free** team can be granted `increased-memory-limit` and `extended-virtual-addressing`. Evidence: the first ipa install. If a free team can't be granted a capability and the install fails, drop that key from `ipa.plist` and note it here.

Later splits add rows here: section 08 for the memory evidence, sections 05 and 07 for address space.

## Why `platform-application` is not used

It brings a stricter IOKit sandbox (Metal would then need explicit GPU exceptions), it can cost the app its data container, and nothing Eikon does needs it.

## Forbidden in every artifact

`scripts/verify_artifacts.py` fails the build if any artifact's main executable carries one of these:

| Key | Why it's forbidden |
|---|---|
| `dynamic-codesigning` | Crashes on iOS 15+ / A12+, and TrollStore bans it. Eikon never relies on RWX or `MAP_JIT`. |
| `com.apple.private.cs.debugger` | Eikon never attaches a debugger, calls `ptrace`, or uses task-for-pid. |
| `com.apple.private.skip-library-validation` | Not needed; Eikon loads only its own signed code. |
| `com.apple.private.persona-mgmt` | Not needed. |
| `platform-application` | See above. |

## `.tipa` and Developer Mode

The tipa carries `get-task-allow`, so on **iOS 16 and later it needs Developer Mode on**. Without it the app may not launch. The deb omits the key for exactly this reason, and the README documents the requirement.
