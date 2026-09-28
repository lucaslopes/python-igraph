from __future__ import annotations

import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import textwrap
import zipfile

import pytest

# scripts/release.sh is a bash tool for a POSIX release machine; Windows
# cannot execute it directly.
pytestmark = pytest.mark.skipif(
    sys.platform == "win32", reason="the release helper is a bash script"
)


ROOT = Path(__file__).resolve().parents[1]
RELEASE_SCRIPT = ROOT / "scripts" / "release.sh"
_VERSION_INFO = (ROOT / "src" / "igraph" / "version.py").read_text()
VERSION = ".".join(
    part.strip()
    for part in _VERSION_INFO.split("__version_info__ = (", 1)[1].split(")", 1)[0].split(",")
)
RUN_ID = "1234567890"
COMMIT = "0123456789abcdef0123456789abcdef01234567"


def _metadata() -> bytes:
    return (
        "Metadata-Version: 2.1\n"
        "Name: lucas-igraph\n"
        f"Version: {VERSION}\n"
        "\n"
    ).encode()


def _wheel(directory: Path, filename: str) -> None:
    path = directory / filename
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr(f"lucas_igraph-{VERSION}.dist-info/METADATA", _metadata())


def _sdist(directory: Path) -> None:
    path = directory / f"lucas_igraph-{VERSION}.tar.gz"
    payload = _metadata()
    info = tarfile.TarInfo(f"lucas_igraph-{VERSION}/PKG-INFO")
    info.size = len(payload)
    with tarfile.open(path, "w:gz") as archive:
        archive.addfile(info, io.BytesIO(payload))


def _executable(path: Path, source: str) -> None:
    path.write_text(textwrap.dedent(source))
    path.chmod(0o755)


def test_preflight_filters_unsupported_and_already_published_files(tmp_path: Path) -> None:
    fixtures = tmp_path / "fixtures"
    bin_dir = tmp_path / "bin"
    fixtures.mkdir()
    bin_dir.mkdir()

    existing = f"lucas_igraph-{VERSION}-cp39-abi3-manylinux_2_28_x86_64.whl"
    candidate = f"lucas_igraph-{VERSION}-cp39-abi3-win_amd64.whl"
    pyodide = f"lucas_igraph-{VERSION}-cp312-abi3-pyodide_2024_0_wasm32.whl"
    pypy = f"lucas_igraph-{VERSION}-pp311-pypy311_pp73-manylinux_2_28_x86_64.whl"
    for filename in (existing, candidate, pyodide, pypy):
        _wheel(fixtures, filename)
    _sdist(fixtures)

    index_json = tmp_path / "index.json"
    index_json.write_text(
        json.dumps(
            {
                "urls": [
                    {
                        "filename": existing,
                        "digests": {"sha256": "abc123"},
                    }
                ]
            }
        )
    )

    _executable(
        bin_dir / "gh",
        f"""\
        #!/bin/bash
        set -eu
        if [ "$1" = api ]; then
            printf '%s\n' 'lucaslopes/python-igraph'
        elif [ "$1 $2" = 'run view' ]; then
            printf '%s\n' '{json.dumps({"headSha": COMMIT, "conclusion": "success", "workflowName": "Build", "url": "https://example.invalid/run"})}'
        elif [ "$1 $2" = 'run download' ]; then
            destination=''
            while [ "$#" -gt 0 ]; do
                if [ "$1" = --dir ]; then destination="$2"; break; fi
                shift
            done
            cp "$RELEASE_TEST_FIXTURES"/* "$destination"/
        else
            exit 97
        fi
        """,
    )
    _executable(
        bin_dir / "curl",
        """\
        #!/bin/bash
        set -eu
        output=''
        while [ "$#" -gt 0 ]; do
            if [ "$1" = --output ]; then output="$2"; shift 2; continue; fi
            shift
        done
        status="${RELEASE_TEST_HTTP_STATUS:-200}"
        if [ "$status" = 200 ]; then
            cp "$RELEASE_TEST_INDEX_JSON" "$output"
        fi
        printf '%s' "$status"
        """,
    )
    uv_marker = tmp_path / "uv-called"
    _executable(
        bin_dir / "uv",
        """\
        #!/bin/bash
        : > "$RELEASE_TEST_UV_MARKER"
        exit 98
        """,
    )

    env = os.environ.copy()
    env.update(
        {
            "PATH": f"{bin_dir}:{env['PATH']}",
            "RELEASE_TEST_FIXTURES": str(fixtures),
            "RELEASE_TEST_INDEX_JSON": str(index_json),
            "RELEASE_TEST_UV_MARKER": str(uv_marker),
            "UV_PUBLISH_TOKEN": "must-not-be-used",
        }
    )
    # The sanitizer CI job preloads libasan/libubsan for the extension under
    # test; the shell helpers started here must not inherit that preload.
    env.pop("LD_PRELOAD", None)
    result = subprocess.run(
        [str(RELEASE_SCRIPT), "--preflight", "--run-id", RUN_ID, "--expected-commit", COMMIT],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert f"skipped: {pyodide} — Pyodide" in result.stdout
    assert f"skipped: {pypy} — PyPy wheel metadata is incompatible" in result.stdout
    assert f"skipped: {existing} — already published" in result.stdout
    assert f"  {candidate}\n" in result.stdout
    assert f"  lucas_igraph-{VERSION}.tar.gz\n" in result.stdout
    assert "No token was requested and no upload was attempted." in result.stdout
    assert "Token:" not in result.stdout + result.stderr
    assert not uv_marker.exists()
    env["RELEASE_TEST_HTTP_STATUS"] = "404"
    missing_result = subprocess.run(
        [str(RELEASE_SCRIPT), "--preflight", "--run-id", RUN_ID, "--expected-commit", COMMIT],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    assert missing_result.returncode == 0, missing_result.stderr
    assert "returned no existing files" in missing_result.stdout
    assert f"  {existing}\n" in missing_result.stdout
    assert "Token:" not in missing_result.stdout + missing_result.stderr
    assert not uv_marker.exists()

    env["RELEASE_TEST_HTTP_STATUS"] = "500"
    api_failure = subprocess.run(
        [str(RELEASE_SCRIPT), "--publish", "--run-id", RUN_ID, "--expected-commit", COMMIT],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    assert api_failure.returncode != 0
    assert "package index returned HTTP 500" in api_failure.stderr
    assert "refusing to upload" in api_failure.stderr
    assert "Token:" not in api_failure.stdout + api_failure.stderr
    assert not uv_marker.exists()
