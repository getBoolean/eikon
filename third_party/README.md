# Third-party components

Eikon links several upstream projects built for iOS: FEX, Wine, Box64 and Kirikiroid2. It doesn't build them itself, and there are no submodules and no patch files. Instead:

- **Each upstream is a fork** on the owner's GitHub. Eikon's changes are commits on the fork's `eikon` branch. For development, the fork is cloned next to this repo (`../<fork>`).
- **The fork builds its library and publishes it as a GitHub release.** Each release tag names exactly which fork commit the binaries came from. It also keeps that commit reachable after a rebase, and it is where the GPL corresponding source is published.
- **Eikon pins a release.** `third_party/deps.toml` records the fork, the release tag, the asset name and the asset's SHA-256. The build downloads that asset into `build/deps/<name>/` and links against it.

## The manifest: `third_party/deps.toml`

Each dependency is one `[[dep]]` table:

- `name`: unpacks to `build/deps/<name>/`
- `repo`: the fork, as `owner/repo`
- `tag`: the release tag
- `asset`: the asset file: `.tar.gz`, `.tar.xz`, `.tar.bz2`, `.zip`, or a single file copied as-is. Prefer tar: zip extraction drops the executable bit. Other archive formats, such as `.tar.zst`, are rejected.
- `sha256`: the asset's hash; `fetch` refuses anything that doesn't match
- `upstream` (optional): the original project, for reference

## Commands

- `make fetch-deps`: downloads each pinned asset, checks its hash and unpacks it. Downloads are cached in `build/deps/.cache/` by hash, and a dependency that already matches its pin is skipped. Fetching everything also removes directories under `build/deps/` that no manifest entry owns.
- `make verify-deps`: checks that every dependency is unpacked from its pinned asset with no file changed since, and that `build/deps/` holds nothing else. Builds that link a dependency run this first.
- `make pin-dep NAME=<name> TAG=<tag> [ASSET=<asset>]`: downloads the release asset and writes its tag, asset and SHA-256 into the manifest. It refuses a release whose asset changed under an already-pinned tag. Commit the manifest change in eikon.
- `make check`: includes `deps.py check`, which validates the manifest without network access.

To act on some dependencies only, name them: `uv run scripts/deps.py fetch|verify [names…]`.

`EIKON_RELEASES_URL` replaces `https://github.com` as the download base. The tests use it; it is also handy for a mirror.

Downloads are unauthenticated, so the forks and their releases must be public.

## Releasing a new version of a library

1. In the fork, commit to the `eikon` branch and push. Rebasing onto a newer upstream is fine: each release's tag keeps the commits it was built from.
2. Build the library for iOS arm64 in the fork, using the notes below, and publish it as a release. The release notes name the fork commit and the upstream version it's based on. A release is never replaced once an Eikon commit pins it; publish a new tag instead.
3. In eikon, run `make pin-dep NAME=<name> TAG=<tag>`, then `make fetch-deps`, and commit the manifest.

Creating forks and publishing releases are outward-facing steps, so they need the owner's approval.

## Credits in the same commit

The commit that adds a dependency also adds:

- its credits entry in `third_party/credits.toml`
- its license texts under `licenses/`

CI enforces this. For GPL and LGPL libraries, the notices point to the fork's release tag as the corresponding source.

## Notes for building the libraries for iOS (in the forks)

- Compiler: `CC="$(xcrun --sdk iphoneos -f clang) -target arm64-apple-ios15.0"`, with `-isysroot "$(xcrun --sdk iphoneos --show-sdk-path)"`.
- Build systems:
  - CMake: `CMAKE_SYSTEM_NAME=iOS`
  - autotools: `--host=aarch64-apple-darwin`
  - meson: a cross file with `subsystem='ios'`
- Set `ac_cv_func_pipe2=no` for the iOS 27 SDK.
- Homebrew's `bison` and `flex` are keg-only, so put them on `PATH` explicitly.
- llvm-mingw is the host toolchain for Wine's PE side.
- Dynamic libraries ship as `<name>.framework` bundles with `@rpath` install names. Eikon embeds them in `Frameworks/`.
- Upstreams with their own git submodules (FEX, for example) need `git submodule update --init --recursive` in the fork before building.
