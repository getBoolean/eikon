#!/usr/bin/env python3
"""Verify the three install artifacts in dist/ and that they share one binary.

    uv run scripts/verify_artifacts.py dist/

Expectations come from the repo (VERSION, packaging/entitlements/<kind>.plist),
not from constants in this file. The only policy list here is the forbidden
entitlements. Reports every failure, grouped by artifact, before exiting 1.
"""

from __future__ import annotations

import hashlib
import plistlib
import struct
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENTITLEMENTS_DIR = ROOT / "packaging" / "entitlements"

FORBIDDEN = [
    "dynamic-codesigning",
    "com.apple.private.cs.debugger",
    "com.apple.private.skip-library-validation",
    "com.apple.private.persona-mgmt",
    "platform-application",
]

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
CPU_TYPE_ARM64 = 0x0100000C
LC_SEGMENT_64 = 0x19
LC_UUID = 0x1B
LC_CODE_SIGNATURE = 0x1D
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSSLOT_CODEDIRECTORY = 0
CSSLOT_RESOURCEDIR = 3


class VerifyError(Exception):
    """A tool or artifact could not be processed at all."""


def run(*args: str) -> bytes:
    result = subprocess.run(args, capture_output=True)
    if result.returncode != 0:
        raise VerifyError(f"{' '.join(args)} failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


# --- Mach-O parsing -------------------------------------------------------

class MachO:
    """The arm64 image of a Mach-O file: its load commands, parsed lazily."""

    def __init__(self, path: Path) -> None:
        self.path = path
        data = path.read_bytes()
        self.base, self.size = _arm64_slice(data)
        self.data = data

    def _macho(self) -> bytes:
        return self.data[self.base:self.base + self.size]

    def load_commands(self):
        macho = self._macho()
        (magic,) = struct.unpack_from("<I", macho, 0)
        if magic != MH_MAGIC_64:
            raise VerifyError(f"{self.path}: not a 64-bit little-endian Mach-O")
        ncmds = struct.unpack_from("<I", macho, 16)[0]
        offset = 32  # mach_header_64
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from("<II", macho, offset)
            yield cmd, offset, cmdsize
            offset += cmdsize

    def uuid(self) -> bytes | None:
        macho = self._macho()
        for cmd, offset, _ in self.load_commands():
            if cmd == LC_UUID:
                return macho[offset + 8:offset + 24]
        return None

    def segment_hashes(self) -> dict[str, str]:
        """sha256 per segment file range, excluding __LINKEDIT (holds the signature)."""
        macho = self._macho()
        hashes: dict[str, str] = {}
        for cmd, offset, _ in self.load_commands():
            if cmd != LC_SEGMENT_64:
                continue
            name = macho[offset + 8:offset + 24].rstrip(b"\x00").decode("ascii", "replace")
            fileoff, filesize = struct.unpack_from("<QQ", macho, offset + 32)
            if name == "__LINKEDIT":
                continue
            chunk = macho[fileoff:fileoff + filesize]
            hashes[name] = hashlib.sha256(chunk).hexdigest()
        return hashes

    def code_signature(self) -> bytes | None:
        macho = self._macho()
        for cmd, offset, _ in self.load_commands():
            if cmd == LC_CODE_SIGNATURE:
                dataoff, datasize = struct.unpack_from("<II", macho, offset + 8)
                return macho[dataoff:dataoff + datasize]
        return None

    def resource_seal_present(self) -> bool:
        """The CodeDirectory has a non-zero hash in the resource-directory special slot."""
        signature = self.code_signature()
        if signature is None:
            return False
        directory = _code_directory(signature)
        if directory is None:
            return False
        magic, length = struct.unpack_from(">II", directory, 0)
        hash_offset, ident_offset, n_special = struct.unpack_from(">III", directory, 16)
        hash_size = directory[36]
        if n_special < CSSLOT_RESOURCEDIR:
            return False
        slot_start = hash_offset - CSSLOT_RESOURCEDIR * hash_size
        seal = directory[slot_start:slot_start + hash_size]
        return len(seal) == hash_size and any(seal)


def _arm64_slice(data: bytes) -> tuple[int, int]:
    (magic,) = struct.unpack_from(">I", data, 0)
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        count = struct.unpack_from(">I", data, 4)[0]
        wide = magic == FAT_MAGIC_64
        entry = 32 if wide else 20
        for i in range(count):
            base = 8 + i * entry
            cputype = struct.unpack_from(">I", data, base)[0]
            if wide:
                offset, size = struct.unpack_from(">QQ", data, base + 8)
            else:
                offset, size = struct.unpack_from(">II", data, base + 8)
            if cputype == CPU_TYPE_ARM64:
                return offset, size
        raise VerifyError("fat Mach-O has no arm64 slice")
    return 0, len(data)


def _code_directory(signature: bytes) -> bytes | None:
    if len(signature) < 12 or struct.unpack_from(">I", signature, 0)[0] != CSMAGIC_EMBEDDED_SIGNATURE:
        return None
    count = struct.unpack_from(">I", signature, 8)[0]
    for i in range(count):
        slot_type, offset = struct.unpack_from(">II", signature, 12 + i * 8)
        if slot_type == CSSLOT_CODEDIRECTORY:
            return signature[offset:]
    return None


def is_macho(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            head = handle.read(4)
    except OSError:
        return False
    if len(head) < 4:
        return False
    magic_le = struct.unpack("<I", head)[0]
    magic_be = struct.unpack(">I", head)[0]
    return magic_le == MH_MAGIC_64 or magic_be in (FAT_MAGIC, FAT_MAGIC_64)


# --- Artifact discovery and extraction ------------------------------------

def find_artifacts(dist: Path) -> dict[str, Path]:
    patterns = {"ipa": "*.ipa", "tipa": "*.tipa", "deb": "*.deb"}
    found: dict[str, Path] = {}
    problems = []
    for kind, pattern in patterns.items():
        matches = sorted(dist.glob(pattern))
        if len(matches) != 1:
            problems.append(f"expected exactly one {pattern} in {dist}, found {len(matches)}")
        else:
            found[kind] = matches[0]
    if problems:
        raise VerifyError("; ".join(problems))
    return found


def extract(artifact: Path, kind: str, dest: Path) -> Path:
    if kind in ("ipa", "tipa"):
        with zipfile.ZipFile(artifact) as archive:
            names = archive.namelist()
            archive.extractall(dest)
        _stash_zip_names(dest, names)
        return dest / "Payload" / "Eikon.app"
    run("dpkg-deb", "-x", str(artifact), str(dest))
    return dest / "var" / "jb" / "Applications" / "Eikon.app"


def _stash_zip_names(dest: Path, names: list[str]) -> None:
    (dest / ".zip-entries").write_text("\n".join(names), encoding="utf-8")


def zip_entries(dest: Path) -> list[str]:
    return (dest / ".zip-entries").read_text(encoding="utf-8").splitlines()


# --- Checks ---------------------------------------------------------------

def app_executable(app: Path) -> Path:
    info = plistlib.loads((app / "Info.plist").read_bytes())
    return app / info["CFBundleExecutable"]


def read_info(app: Path) -> dict:
    return plistlib.loads((app / "Info.plist").read_bytes())


def check_layout(kind: str, dest: Path, app: Path) -> list[str]:
    problems: list[str] = []
    if kind in ("ipa", "tipa"):
        for name in zip_entries(dest):
            top = name.split("/", 1)[0]
            if top not in ("Payload", "") and not name.startswith("Payload/"):
                problems.append(f"{kind}: entry outside Payload/: {name}")
    else:
        allowed_prefixes = (("var", "jb"),)
        for path in dest.rglob("*"):
            if path.name == ".zip-entries":
                continue
            parts = path.relative_to(dest).parts
            # var and var/jb themselves are allowed; everything else lives under var/jb/.
            if parts in (("var",),) or parts == ("var", "jb"):
                continue
            if parts[:2] not in allowed_prefixes:
                problems.append(f"deb: path outside var/jb/: {'/'.join(parts)}")
    return problems


def check_deb_control(deb: Path, app: Path, version: str) -> list[str]:
    fields = {}
    for line in run("dpkg-deb", "-f", str(deb)).decode().splitlines():
        if ":" in line:
            key, _, value = line.partition(":")
            fields[key.strip()] = value.strip()
    info = read_info(app)
    problems = []
    if fields.get("Architecture") != "iphoneos-arm64":
        problems.append(f"deb: Architecture is {fields.get('Architecture')!r}, expected iphoneos-arm64")
    if fields.get("Package") != info.get("CFBundleIdentifier"):
        problems.append(f"deb: Package {fields.get('Package')!r} != bundle id {info.get('CFBundleIdentifier')!r}")
    if fields.get("Version") != version:
        problems.append(f"deb: Version {fields.get('Version')!r} != VERSION {version!r}")
    return problems


def check_version_and_stamp(kind: str, app: Path, version: str) -> list[str]:
    info = read_info(app)
    problems = []
    if info.get("CFBundleShortVersionString") != version:
        problems.append(f"{kind}: CFBundleShortVersionString {info.get('CFBundleShortVersionString')!r} != {version!r}")
    if info.get("EKPackageKind") != kind:
        problems.append(f"{kind}: EKPackageKind {info.get('EKPackageKind')!r} != {kind!r}")
    return problems


def check_hygiene(kind: str, dest: Path, app: Path) -> list[str]:
    problems = []
    names = zip_entries(dest) if kind in ("ipa", "tipa") else [
        str(p.relative_to(dest)) for p in dest.rglob("*") if p.name != ".zip-entries"
    ]
    for name in names:
        base = name.rstrip("/").rsplit("/", 1)[-1]
        if base.startswith("._") or base == ".DS_Store" or name.startswith("__MACOSX/") or "/__MACOSX/" in name:
            problems.append(f"{kind}: junk file {name}")
    return problems


def entitlements_of(executable: Path) -> dict:
    output = run("ldid", "-e", str(executable))
    if not output.strip():
        return {}
    return plistlib.loads(output)


def check_signature(kind: str, app: Path, expected: dict) -> list[str]:
    problems: list[str] = []
    executable = app_executable(app)
    entitlements = entitlements_of(executable)

    # The three artifacts differ only in entitlements, so each set must match its
    # plist exactly: a missing key, a wrong value, or an extra key all fail.
    for key in sorted(set(expected) | set(entitlements)):
        if key not in entitlements:
            problems.append(f"{kind}: missing entitlement {key}={expected[key]!r}")
        elif key not in expected:
            problems.append(f"{kind}: unexpected entitlement {key}={entitlements[key]!r}")
        elif entitlements[key] != expected[key]:
            problems.append(f"{kind}: entitlement {key}={entitlements[key]!r}, expected {expected[key]!r}")
    for key in FORBIDDEN:
        if key in entitlements:
            problems.append(f"{kind}: forbidden entitlement {key}")

    macho = MachO(executable)
    if not macho.resource_seal_present():
        problems.append(f"{kind}: main executable has no sealed resource directory")
    if not (app / "_CodeSignature" / "CodeResources").is_file():
        problems.append(f"{kind}: bundle has no _CodeSignature/CodeResources")

    for path in app.rglob("*"):
        if path.is_file() and path != executable and is_macho(path):
            nested = MachO(path)
            if nested.code_signature() is None:
                problems.append(f"{kind}: nested Mach-O not signed: {path.relative_to(app)}")
            if entitlements_of(path):
                problems.append(f"{kind}: nested Mach-O carries entitlements: {path.relative_to(app)}")
    return problems



# --- Driver ---------------------------------------------------------------

def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print("usage: verify_artifacts.py <dist-dir>", file=sys.stderr)
        return 2
    dist = Path(argv[0])
    version = (ROOT / "VERSION").read_text().strip()

    try:
        artifacts = find_artifacts(dist)
        expected = {kind: plistlib.loads((ENTITLEMENTS_DIR / f"{kind}.plist").read_bytes())
                    for kind in artifacts}
    except (VerifyError, OSError) as error:
        print(f"verify: {error}", file=sys.stderr)
        return 1

    problems: list[str] = []
    identities: dict[str, tuple[bytes | None, dict[str, str], str]] = {}
    build_versions: dict[str, str] = {}

    with tempfile.TemporaryDirectory() as tmp:
        for kind, artifact in artifacts.items():
            dest = Path(tmp) / kind
            dest.mkdir()
            try:
                app = extract(artifact, kind, dest)
                if not app.is_dir():
                    problems.append(f"{kind}: no Eikon.app in {artifact.name}")
                    continue
                problems += check_layout(kind, dest, app)
                if kind == "deb":
                    problems += check_deb_control(artifact, app, version)
                problems += check_version_and_stamp(kind, app, version)
                problems += check_hygiene(kind, dest, app)
                problems += check_signature(kind, app, expected[kind])
                executable = app_executable(app)
                macho = MachO(executable)
                identities[kind] = (macho.uuid(), macho.segment_hashes(), artifact.name)
                build_versions[kind] = read_info(app).get("CFBundleVersion", "")
            except (VerifyError, OSError, KeyError, struct.error) as error:
                problems.append(f"{kind}: {error}")

        problems += compare_binaries(identities)
        if len(set(build_versions.values())) > 1:
            problems.append(f"CFBundleVersion differs across artifacts: {build_versions}")

    if problems:
        for problem in problems:
            print(f"verify: {problem}", file=sys.stderr)
        return 1

    print(f"verify: {', '.join(a.name for a in artifacts.values())} — same binary, version {version}, OK")
    return 0


def compare_binaries(identities: dict[str, tuple[bytes | None, dict[str, str], str]]) -> list[str]:
    if len(identities) < 2:
        return []
    problems = []
    uuids = {kind: uuid for kind, (uuid, _, _) in identities.items()}
    if len(set(uuids.values())) != 1 or None in uuids.values():
        problems.append(f"main executables have different LC_UUID: {uuids}")
    segment_names = set().union(*(hashes.keys() for _, hashes, _ in identities.values()))
    for name in sorted(segment_names):
        values = {kind: hashes.get(name) for kind, (_, hashes, _) in identities.items()}
        if len(set(values.values())) != 1:
            problems.append(f"segment {name} differs across artifacts: {values}")
    return problems


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
