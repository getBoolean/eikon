#!/usr/bin/env python3
"""Validate a device report and file it under a deterministic name.

    uv run scripts/file_device_report.py [--out-dir DIR] [--check] <path | ->

Does not commit. An unknown schema keyword is an error, so the schema cannot
quietly depend on a check this validator does not implement.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCHEMA_PATH = ROOT / "device-reports" / "schema.json"
KNOWN_VERSIONS = {1}

ALLOWED_KEYWORDS = {
    "$defs",
    "$id",
    "$ref",
    "$schema",
    "additionalProperties",
    "const",
    "description",
    "items",
    "minimum",
    "pattern",
    "properties",
    "required",
    "title",
    "type",
}


class SchemaError(Exception):
    """The schema uses something this validator does not check."""


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate and file an Eikon device report.")
    parser.add_argument("path", help="Report JSON path, or - for stdin")
    parser.add_argument("--out-dir", type=Path, default=ROOT / "device-reports")
    parser.add_argument("--check", action="store_true", help="Validate only; print the path and write nothing")
    args = parser.parse_args()

    try:
        raw = sys.stdin.read() if args.path == "-" else Path(args.path).read_text(encoding="utf-8")
        report = json.loads(raw)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        print(error, file=sys.stderr)
        return 1

    version = report.get("schemaVersion") if isinstance(report, dict) else None
    if isinstance(version, bool) or not isinstance(version, int) or version not in KNOWN_VERSIONS:
        print(f"unknown schemaVersion: {version!r}", file=sys.stderr)
        return 1

    try:
        schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
        problems = validate(report, schema, "", schema)
    except SchemaError as error:
        print(error, file=sys.stderr)
        return 1
    if problems:
        for problem in problems:
            print(problem, file=sys.stderr)
        return 1

    target = args.out_dir / filename(report)
    body = json.dumps(report, sort_keys=True, indent=2, ensure_ascii=False) + "\n"
    if args.check:
        print(target)
        return 0

    args.out_dir.mkdir(parents=True, exist_ok=True)
    if target.exists():
        current = target.read_text(encoding="utf-8")
        if current != body:
            print(f"refusing to overwrite {target}", file=sys.stderr)
            return 1
        print(target)
        return 0

    descriptor, temporary = tempfile.mkstemp(dir=args.out_dir, suffix=".tmp")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(body)
        os.replace(temporary, target)
    except Exception:
        if os.path.exists(temporary):
            os.unlink(temporary)
        raise
    print(target)
    return 0


def filename(report: dict) -> str:
    generated = str(report["generatedAt"]).replace("Z", "+00:00")
    day = datetime.fromisoformat(generated).astimezone(timezone.utc).date().isoformat()
    canonical = json.dumps(report, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    digest = hashlib.sha256(canonical).hexdigest()[:8]
    model = report["device"]["modelIdentifier"]
    method = report["install"]["method"]
    return f"{day}-{model}-{method}-{digest}.json"


def validate(instance, schema: dict, pointer: str, root: dict) -> list[str]:
    reject_unknown_keywords(schema)
    if "$ref" in schema:
        name = schema["$ref"].removeprefix("#/$defs/")
        return validate(instance, root["$defs"][name], pointer, root)

    problems: list[str] = []
    if "type" in schema and not type_matches(instance, schema["type"]):
        problems.append(f"{pointer or '/'}: type")
        return problems
    if "const" in schema and instance != schema["const"]:
        problems.append(f"{pointer or '/'}: const")
    if "pattern" in schema and isinstance(instance, str) and re.search(schema["pattern"], instance) is None:
        problems.append(f"{pointer or '/'}: pattern")
    if "minimum" in schema and isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if instance < schema["minimum"]:
            problems.append(f"{pointer or '/'}: minimum")
    if isinstance(instance, dict) and any(key in schema for key in ("properties", "required", "additionalProperties")):
        problems.extend(validate_object(instance, schema, pointer, root))
    if "items" in schema and isinstance(instance, list):
        for index, item in enumerate(instance):
            problems.extend(validate(item, schema["items"], f"{pointer}/{index}", root))
    return problems


def validate_object(instance: dict, schema: dict, pointer: str, root: dict) -> list[str]:
    problems: list[str] = []
    properties = schema.get("properties", {})
    for key in schema.get("required", []):
        if key not in instance:
            problems.append(f"{pointer}/{escape(key)}: required")
    additional = schema.get("additionalProperties", True)
    for key, value in instance.items():
        child = f"{pointer}/{escape(key)}"
        if key in properties:
            problems.extend(validate(value, properties[key], child, root))
        elif additional is False:
            problems.append(f"{child}: additional property")
        elif isinstance(additional, dict):
            problems.extend(validate(value, additional, child, root))
    return problems


def type_matches(instance, declared) -> bool:
    names = [declared] if isinstance(declared, str) else list(declared)
    return any(one_type(instance, name) for name in names)


def one_type(instance, name: str) -> bool:
    if name == "object":
        return isinstance(instance, dict)
    if name == "array":
        return isinstance(instance, list)
    if name == "string":
        return isinstance(instance, str)
    if name == "boolean":
        return isinstance(instance, bool)
    if name == "integer":
        return isinstance(instance, int) and not isinstance(instance, bool)
    if name == "number":
        return isinstance(instance, (int, float)) and not isinstance(instance, bool)
    if name == "null":
        return instance is None
    raise SchemaError(f"unsupported type {name}")


def reject_unknown_keywords(schema: dict) -> None:
    unknown = set(schema) - ALLOWED_KEYWORDS
    if unknown:
        raise SchemaError(f"unsupported schema keyword: {', '.join(sorted(unknown))}")
    for key in ("properties", "$defs"):
        for child in schema.get(key, {}).values():
            if isinstance(child, dict):
                reject_unknown_keywords(child)
    additional = schema.get("additionalProperties")
    if isinstance(additional, dict):
        reject_unknown_keywords(additional)
    items = schema.get("items")
    if isinstance(items, dict):
        reject_unknown_keywords(items)


def escape(key: str) -> str:
    return key.replace("~", "~0").replace("/", "~1")


if __name__ == "__main__":
    sys.exit(main())
