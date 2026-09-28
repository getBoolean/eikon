# Entitlements

Eikon ships one binary in two packages: an AltStore/TrollStore `.ipa` and a
Dopamine rootless `.deb`. They differ only in entitlements, one Info.plist stamp
(`EKPackageKind`), the bundle id, and container format. These plists are what
`scripts/package.sh` signs each artifact with, and what `scripts/verify_artifacts.py`
checks the signed artifacts against.

The `.ipa` covers both AltStore and TrollStore. AltStore re-signs it on install
and replaces its entitlements with the developer profile's, so the embedded set
below matters only for TrollStore, which preserves it. The deb uses its own
bundle id (`com.getboolean.eikon.rootless`) so a Dopamine install and a
TrollStore-installed ipa can coexist; the ipa keeps `com.getboolean.eikon`.

## Keys, and which install methods honour them

| Key | ipa | deb | Purpose and who honours it |
|---|---|---|---|
| `com.apple.private.security.no-sandbox` | – | ✓ | Runs outside the app sandbox. The deb keeps it; Dopamine honours it. The ipa does not: on the iPadOS 17.0 TrollStore install, that key left the process outside a container, and the sandbox SIGKILL'd it at exec (`outside of container && not a driver && !i_can_has_debugger`) before any UI. |
| `get-task-allow` | ✓ | – | Lets another process attach. TrollStore's enable-jit / "Open with JIT" attaches to set `CS_DEBUGGED`. AltStore's developer profile carries it too. The deb leaves it out (Dopamine doesn't need it, and on iOS 16+ it would force Developer Mode). |
| `com.apple.developer.kernel.increased-memory-limit` | ✓ | ✓ | Raises the per-app memory cap. A public App ID capability, so AltStore requests it from the developer account. |
| `com.apple.developer.kernel.extended-virtual-addressing` | ✓ | ✓ | Allows a larger virtual address space. Also a public App ID capability. |
| `com.apple.private.memorystatus` | ✓ | ✓ | Adjusts the memorystatus (jetsam) limits. A private key AltStore can't grant; it drops it when re-signing the ipa. |

## Unverified

- Whether the two `com.apple.developer.kernel.*` memory keys have any effect under Dopamine's ad-hoc signing. Evidence: the device report's `memory.availableBytes`.
- Whether an AltStore **free** team can be granted `increased-memory-limit` and `extended-virtual-addressing`. Evidence: the first ipa install. If a free team can't be granted a capability and the install fails, drop that key from `ipa.plist` and note it here.
- Whether a TrollStore-installed ipa is detected as `trollStore` and gets JIT from "Open with JIT". Evidence: a device report from that install.

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

## Developer Mode

The ipa carries `get-task-allow`, so on **iOS 16 and later it needs Developer Mode on**, both when installed via TrollStore and after AltStore re-signs it. The deb omits the key and needs no Developer Mode.

## One id per artifact

The `.ipa` keeps `com.getboolean.eikon` (AltStore rewrites it per account anyway). The `.deb` uses `com.getboolean.eikon.rootless`. Different ids let a Dopamine install and a TrollStore-installed ipa coexist on one device instead of shadowing each other. The executable is byte-identical across both; only `Info.plist` and the signature differ, so `make verify`'s same-binary check still holds.
