"""Filing a device report: schema check, a stable name, and rejection."""

import json
import subprocess
import sys
from datetime import datetime
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
FILER = ROOT / "scripts" / "file_device_report.py"
FIXTURE = ROOT / "tests" / "fixtures" / "device-report.json"
SCHEMA = ROOT / "device-reports" / "schema.json"


def _report():
    return json.loads(FIXTURE.read_text(encoding="utf-8"))


def _date_prefix(report) -> str:
    text = report["generatedAt"].replace("Z", "+00:00")
    return datetime.fromisoformat(text).date().isoformat()


def _run(*args, stdin=None):
    return subprocess.run(
        [sys.executable, str(FILER), *args],
        input=stdin,
        text=True,
        capture_output=True,
        cwd=ROOT,
    )


def test_fixture_validates_against_the_schema(tmp_path):
    result = _run("--check", "--out-dir", str(tmp_path), str(FIXTURE))
    assert result.returncode == 0
    assert list(tmp_path.iterdir()) == []


def test_filing_a_valid_report_is_idempotent(tmp_path):
    report = _report()
    filed = _run("--out-dir", str(tmp_path), str(FIXTURE))
    assert filed.returncode == 0
    written = list(tmp_path.glob("*.json"))
    assert len(written) == 1
    assert written[0].name.startswith(_date_prefix(report))
    assert filed.stdout.strip() == str(written[0])
    assert json.loads(written[0].read_text(encoding="utf-8")) == report

    again = _run("--out-dir", str(tmp_path), str(FIXTURE))
    assert again.returncode == 0
    assert list(tmp_path.glob("*.json")) == written

    from_stdin = _run("--out-dir", str(tmp_path), "-", stdin=FIXTURE.read_text(encoding="utf-8"))
    assert from_stdin.returncode == 0
    assert list(tmp_path.glob("*.json")) == written
    assert from_stdin.stdout.strip() == str(written[0])


def _rejected(kind: str):
    schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
    report = _report()
    if kind == "missing":
        report.pop(schema["required"][0])
    elif kind == "extra":
        report["notASchemaField"] = 1
    else:
        report["schemaVersion"] = report["schemaVersion"] + 1000
    return report


@pytest.mark.parametrize("kind", ["missing", "extra", "version"])
def test_rejections_write_nothing(tmp_path, kind):
    result = _run("--out-dir", str(tmp_path), "-", stdin=json.dumps(_rejected(kind)))
    assert result.returncode != 0
    assert list(tmp_path.iterdir()) == []
