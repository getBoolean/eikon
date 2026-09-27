# Third-party components

Eikon builds several upstream projects for iOS. This directory holds them as
git submodules. Any local changes are kept as patch files, not as commits.

## Location and pinning

- Every upstream is a git submodule at `third_party/<name>`, pinned to a tag or commit.
- `.gitmodules` sets `ignore = dirty` for every submodule, so applied (uncommitted) patches don't show up as changes in the superproject.

## Patches

- Local changes to an upstream live **only** in `patches/<name>/NNNN-short-description.patch`. `<name>` matches the submodule directory name, and `NNNN` is a zero-padded sequence number.
- To make a patch, commit in the submodule temporarily, export with `git format-patch` against the pinned revision, then reset the submodule.
- Patches apply in lexical order with `git apply`, to the working tree only. The submodule's `HEAD` never moves, and the superproject never records a patched commit. Never commit inside a submodule, and never bump a gitlink to a patched commit.
- `make apply-patches` applies them. `make unpatch` resets every submodule to its pin with a clean tree. To work on some components only, name them: `uv run scripts/apply_patches.py apply|restore [names…]`.
- A patch that doesn't apply stops the run with the component and patch name, and that submodule is reset to its pin.
- When you bump a pin, regenerate or refresh that component's patches against the new revision in the same commit.

## Out-of-tree builds

Upstream builds must happen **out of tree**, under `build/`. Resetting a submodule fully cleans its working tree (`git clean -ffdx`), which deletes anything built inside it.

## Credits in the same commit

The commit that adds a submodule must also add:

- its credits entry in `third_party/credits.toml`
- its license texts under `licenses/`

CI enforces this.

## Notes for cross-compiling for iOS

- Compiler: `CC="$(xcrun --sdk iphoneos -f clang) -target arm64-apple-ios15.0"`, with `-isysroot "$(xcrun --sdk iphoneos --show-sdk-path)"`.
- Build systems:
  - CMake: `CMAKE_SYSTEM_NAME=iOS`
  - autotools: `--host=aarch64-apple-darwin`
  - meson: a cross file with `subsystem='ios'`
- Set `ac_cv_func_pipe2=no` for the iOS 27 SDK.
- Homebrew's `bison` and `flex` are keg-only, so put them on `PATH` explicitly.
- llvm-mingw is the host toolchain for Wine's PE side.
- Dynamic libraries go in `Frameworks/<name>.framework`, with `@rpath` install names.
- CI caches are keyed on the dependency build scripts, `patches/**` and the submodule SHAs.
