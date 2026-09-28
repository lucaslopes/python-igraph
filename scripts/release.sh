#!/bin/bash

# Guided release helper.
#
# Version-bump release:
#   ./scripts/release.sh patch|minor|major [-p|--push]
#
# The artifact workflow validates and downloads a completed python-igraph CI
# run, inspects every distribution, and reconciles it with the package index:
#   ./scripts/release.sh --preflight [artifact options]
#   ./scripts/release.sh --inspect [artifact options]
#   ./scripts/release.sh --publish [artifact options]

set -euo pipefail

readonly DEFAULT_REPOSITORY="lucaslopes/python-igraph"
readonly DEFAULT_DISTRIBUTION="lucas-igraph"
# The expected artifact version is the package version of this checkout.
DEFAULT_VERSION=$(sed -n 's/^__version_info__ = (\(.*\))$/\1/p' \
    "$(dirname "$0")/../src/igraph/version.py" 2>/dev/null | tr -d ' ' | tr ',' '.')
readonly DEFAULT_VERSION
readonly DEFAULT_PUBLISH_URL="https://upload.pypi.org/legacy/"
readonly DEFAULT_INDEX_JSON_BASE_URL="https://pypi.org/pypi"

usage() {
    cat <<'EOF'
Usage:
  ./scripts/release.sh patch|minor|major [-p|--push]
  ./scripts/release.sh --preflight|--inspect [options]
  ./scripts/release.sh --publish [options]

Version-bump release:
  patch|minor|major       Bump, build, commit, and tag the package version.
  -p, --push             Push main and the new tag to origin.

lucas-igraph artifact workflow:
  --preflight, --inspect Validate, download, inspect, and list candidates only.
                         Never asks for a token and never uploads.
  --publish              Run the same preflight, then ask silently for a token
                         immediately before publishing only new safe files.
  --repo OWNER/REPO      GitHub repository (default: lucaslopes/python-igraph).
  --run-id ID            Required GitHub Actions run ID.
  --expected-commit SHA  Required exact head SHA for the run.
  --distribution NAME    Expected distribution metadata name
                         (default: lucas-igraph).
  --version VERSION      Expected artifact version (default: the version in
                         src/igraph/version.py).
  --publish-url URL      uv upload endpoint. Also configurable through
                         UV_PUBLISH_URL (default: PyPI legacy upload URL).
  --index-json-base URL  JSON API base used for duplicate detection and
                         verification. Also configurable through
                         PYPI_JSON_BASE_URL (default: https://pypi.org/pypi).
  -h, --help             Show this help.

For TestPyPI or a private index, provide both endpoints explicitly, for example:
  UV_PUBLISH_URL=https://test.pypi.org/legacy/ \
  PYPI_JSON_BASE_URL=https://test.pypi.org/pypi \
  ./scripts/release.sh --preflight --run-id ID --expected-commit SHA

Security and safety:
  Tokens are never accepted as arguments or files. In --publish mode, an
  inherited UV_PUBLISH_TOKEN is ignored and the token is read silently inside
  a short-lived subshell. Pyodide and PyPy wheels are preserved but skipped.
EOF
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

canonicalize_name() {
    python3 - "$1" <<'PY'
import re
import sys

print(re.sub(r"[-_.]+", "-", sys.argv[1]).lower())
PY
}

lowercase() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

validate_endpoint_url() {
    local label="$1"
    local url="$2"
    python3 - "$label" "$url" <<'PY'
import sys
from urllib.parse import urlsplit

label, url = sys.argv[1:]
parsed = urlsplit(url)
if parsed.scheme not in {"http", "https"} or not parsed.netloc:
    raise SystemExit(f"Error: {label} must be an absolute HTTP(S) URL")
if parsed.username is not None or parsed.password is not None:
    raise SystemExit(f"Error: {label} must not contain credentials")
if parsed.query or parsed.fragment:
    raise SystemExit(f"Error: {label} must not contain a query or fragment")
PY
}

run_version_release() {
    local version_type="$1"
    shift
    local do_push=false
    local arg

    for arg in "$@"; do
        case "$arg" in
            -p|--push) do_push=true ;;
            *) die "unknown version-bump release argument: $arg" ;;
        esac
    done

    printf 'Releasing %s version to TestPyPI...\n' "$version_type"

    local current_version
    current_version=$(grep '^version = ' pyproject.toml | cut -d'"' -f2)
    [ -n "$current_version" ] || die "could not read version from pyproject.toml"
    printf 'Current version: %s\n' "$current_version"

    local major minor patch extra
    IFS='.' read -r major minor patch extra <<< "$current_version"
    [ -n "${major:-}" ] && [ -n "${minor:-}" ] && [ -n "${patch:-}" ] \
        && [ -z "${extra:-}" ] \
        || die "a version-bump release requires a three-component numeric version"
    [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ && "$patch" =~ ^[0-9]+$ ]] \
        || die "a version-bump release requires a three-component numeric version"

    local new_version
    case "$version_type" in
        patch) new_version="$major.$minor.$((patch + 1))" ;;
        minor) new_version="$major.$((minor + 1)).0" ;;
        major) new_version="$((major + 1)).0.0" ;;
        *) die "version type must be patch, minor, or major" ;;
    esac
    printf 'New version: %s\n' "$new_version"

    if [[ "${OSTYPE:-}" == darwin* ]]; then
        sed -i '' "s/^version = \".*\"/version = \"$new_version\"/" pyproject.toml
    else
        sed -i "s/^version = \".*\"/version = \"$new_version\"/" pyproject.toml
    fi

    echo "Updated pyproject.toml"
    echo "Building package..."
    uv build
    git add pyproject.toml
    git commit -m "Bump version to $new_version"

    local tag="v$new_version"
    git tag "$tag"
    printf 'Created tag: %s\n' "$tag"

    if [ "$do_push" = true ]; then
        printf "\nPushing branch 'main' and tag '%s' to origin...\n" "$tag"
        git push origin main
        git push origin "$tag"
        echo "Pushed to origin."
        printf '\nRelease %s prepared for TestPyPI!\n' "$new_version"
    else
        printf '\nRelease %s prepared for TestPyPI!\n\n' "$new_version"
        echo "Next steps:"
        echo "1. Review changes: git log --oneline -5"
        echo "2. Push changes: git push origin main"
        echo "3. Push tag: git push origin $tag"
        echo "4. Check GitHub Actions for automated publishing to TestPyPI"
        printf '\nOr push everything at once:\n'
        echo "git push origin main && git push origin $tag"
        printf '\nTag format: %s\n' "$tag"
        echo "This will trigger: TestPyPI workflow only"
        printf '\nNote: PyPI workflow is currently disabled\n'
        echo "To enable PyPI publishing later, uncomment .github/workflows/publish-pypi.yml.disabled"
    fi
}

validate_repository_and_run() {
    local repository="$1"
    local run_id="$2"
    local expected_commit="$3"

    [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
        || die "invalid GitHub repository: $repository"
    [[ "$run_id" =~ ^[0-9]+$ ]] || die "run ID must contain digits only"
    [[ "$expected_commit" =~ ^[0-9a-fA-F]{40}$ ]] \
        || die "expected commit must be a full 40-character SHA"

    local remote_repository
    remote_repository=$(gh api "repos/$repository" --jq .full_name) \
        || die "could not validate GitHub repository $repository"
    [ "$(lowercase "$remote_repository")" = "$(lowercase "$repository")" ] \
        || die "GitHub resolved repository as $remote_repository, expected $repository"

    local run_json
    run_json=$(gh run view "$run_id" --repo "$repository" \
        --json headSha,conclusion,workflowName,url) \
        || die "could not inspect GitHub Actions run $run_id in $repository"

    python3 - "$expected_commit" "$run_id" "$run_json" <<'PY'
import json
import sys

expected_commit = sys.argv[1].lower()
run_id = sys.argv[2]
try:
    run = json.loads(sys.argv[3])
except (json.JSONDecodeError, TypeError) as exc:
    raise SystemExit(f"Error: invalid gh run JSON: {exc}")

head_sha = str(run.get("headSha", "")).lower()
conclusion = str(run.get("conclusion", "")).lower()
if head_sha != expected_commit:
    raise SystemExit(
        f"Error: run {run_id} headSha is {head_sha or '<missing>'}, "
        f"expected {expected_commit}"
    )
if conclusion != "success":
    raise SystemExit(
        f"Error: run {run_id} conclusion is {conclusion or '<missing>'}, "
        "expected success"
    )

print(f"Validated workflow: {run.get('workflowName') or '<unknown>'}")
print(f"Run URL: {run.get('url') or '<unavailable>'}")
print(f"headSha: {head_sha}")
print("conclusion: success")
PY
}

inspect_distribution() {
    local path="$1"
    python3 - "$path" <<'PY'
from email.parser import BytesParser
from pathlib import Path
import re
import sys
import tarfile
import zipfile

path = Path(sys.argv[1])

if path.name.endswith(".whl"):
    with zipfile.ZipFile(path) as archive:
        matches = sorted(
            name for name in archive.namelist()
            if name.endswith(".dist-info/METADATA")
        )
        if len(matches) != 1:
            raise SystemExit(
                f"expected exactly one .dist-info/METADATA, found {len(matches)}"
            )
        metadata = archive.read(matches[0])
elif path.name.endswith(".tar.gz"):
    with tarfile.open(path, "r:gz") as archive:
        matches = sorted(
            (
                member for member in archive.getmembers()
                if member.isfile()
                and (member.name == "PKG-INFO" or member.name.endswith("/PKG-INFO"))
            ),
            key=lambda member: (member.name.count("/"), member.name),
        )
        if not matches:
            raise SystemExit("sdist contains no PKG-INFO")
        extracted = archive.extractfile(matches[0])
        if extracted is None:
            raise SystemExit("could not read sdist PKG-INFO")
        metadata = extracted.read()
else:
    raise SystemExit("unsupported distribution extension")

message = BytesParser().parsebytes(metadata)
name = message.get("Name", "").strip()
version = message.get("Version", "").strip()
if not name or not version:
    raise SystemExit("distribution metadata is missing Name or Version")
canonical_name = re.sub(r"[-_.]+", "-", name).lower()
print(f"{canonical_name}\t{version}")
PY
}

fetch_index_json() {
    local url="$1"
    local output="$2"
    local allow_missing="$3"
    local status

    if ! status=$(curl --silent --show-error --location \
        --output "$output" --write-out '%{http_code}' "$url"); then
        printf 'Error: network error while querying package index: %s\n' "$url" >&2
        return 1
    fi

    case "$status" in
        200)
            if ! python3 - "$output" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "rb") as handle:
        payload = json.load(handle)
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"invalid index JSON: {exc}")
if not isinstance(payload, dict) or not isinstance(payload.get("urls"), list):
    raise SystemExit("invalid index JSON: top-level 'urls' must be a list")
for position, entry in enumerate(payload["urls"]):
    if not isinstance(entry, dict) or not isinstance(entry.get("filename"), str):
        raise SystemExit(
            f"invalid index JSON: urls[{position}] has no string filename"
        )
PY
            then
                printf 'Error: package index returned invalid JSON for %s\n' "$url" >&2
                return 1
            fi
            return 0
            ;;
        404)
            if [ "$allow_missing" = true ]; then
                printf '{"urls": []}\n' > "$output"
                return 0
            fi
            printf 'Error: package version is absent from the index: %s\n' "$url" >&2
            return 1
            ;;
        *)
            printf 'Error: package index returned HTTP %s for %s\n' "$status" "$url" >&2
            return 1
            ;;
    esac
}

print_index_files() {
    local json_path="$1"
    python3 - "$json_path" <<'PY'
import json
import sys

with open(sys.argv[1], "rb") as handle:
    payload = json.load(handle)
for entry in sorted(payload.get("urls", []), key=lambda item: item.get("filename", "")):
    filename = entry.get("filename", "")
    digest = entry.get("digests", {}).get("sha256", "<sha256 unavailable>")
    if filename:
        print(f"{filename}\t{digest}")
PY
}

index_filenames() {
    local json_path="$1"
    python3 - "$json_path" <<'PY'
import json
import sys

with open(sys.argv[1], "rb") as handle:
    payload = json.load(handle)
for entry in payload.get("urls", []):
    filename = entry.get("filename")
    if filename:
        print(filename)
PY
}

array_contains() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

print_index_state_from_file() {
    local json_path="$1"
    local count
    count=$(index_filenames "$json_path" | wc -l | tr -d ' ')
    if [ "$count" -gt 0 ]; then
        echo "Files currently present in the package index (filename, sha256):"
        print_index_files "$json_path" | while IFS=$'\t' read -r filename digest; do
            printf '  %s  sha256=%s\n' "$filename" "$digest"
        done
    else
        echo "No files for this version are currently present in the package index."
    fi
}

run_artifact_release() {
    local mode="$1"
    shift

    local repository="${GH_REPOSITORY:-$DEFAULT_REPOSITORY}"
    local run_id="${GH_RUN_ID:-}"
    local expected_commit="${EXPECTED_COMMIT:-}"
    local distribution="${RELEASE_DISTRIBUTION:-$DEFAULT_DISTRIBUTION}"
    local version="${RELEASE_VERSION:-$DEFAULT_VERSION}"
    local publish_url="${UV_PUBLISH_URL:-$DEFAULT_PUBLISH_URL}"
    local index_json_base_url="${PYPI_JSON_BASE_URL:-$DEFAULT_INDEX_JSON_BASE_URL}"
    local publish_url_explicit=false
    local index_url_explicit=false

    [ -n "${UV_PUBLISH_URL:-}" ] && publish_url_explicit=true
    [ -n "${PYPI_JSON_BASE_URL:-}" ] && index_url_explicit=true

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --repo) [ "$#" -ge 2 ] || die "--repo requires a value"; repository="$2"; shift 2 ;;
            --run-id) [ "$#" -ge 2 ] || die "--run-id requires a value"; run_id="$2"; shift 2 ;;
            --expected-commit) [ "$#" -ge 2 ] || die "--expected-commit requires a value"; expected_commit="$2"; shift 2 ;;
            --distribution) [ "$#" -ge 2 ] || die "--distribution requires a value"; distribution="$2"; shift 2 ;;
            --version) [ "$#" -ge 2 ] || die "--version requires a value"; version="$2"; shift 2 ;;
            --publish-url) [ "$#" -ge 2 ] || die "--publish-url requires a value"; publish_url="$2"; publish_url_explicit=true; shift 2 ;;
            --index-json-base) [ "$#" -ge 2 ] || die "--index-json-base requires a value"; index_json_base_url="$2"; index_url_explicit=true; shift 2 ;;
            -h|--help) usage; return 0 ;;
            *) die "unknown artifact workflow argument: $1" ;;
        esac
    done

    [ -n "$run_id" ] || die "pass --run-id (or GH_RUN_ID) for the CI run that built the artifacts"
    [ -n "$expected_commit" ] || die "pass --expected-commit (or EXPECTED_COMMIT) for the release commit"
    [ -n "$distribution" ] || die "distribution name cannot be empty"
    [ -n "$version" ] || die "version cannot be empty"
    [ -n "$publish_url" ] || die "publish URL cannot be empty"
    [ -n "$index_json_base_url" ] || die "index JSON base URL cannot be empty"

    if [ "$publish_url" != "$DEFAULT_PUBLISH_URL" ] && [ "$index_url_explicit" = false ]; then
        die "a non-default publish URL requires an explicit --index-json-base or PYPI_JSON_BASE_URL"
    fi
    if [ "$index_json_base_url" != "$DEFAULT_INDEX_JSON_BASE_URL" ] \
        && [ "$publish_url_explicit" = false ]; then
        die "a non-default index JSON base requires an explicit --publish-url or UV_PUBLISH_URL"
    fi

    require_command gh
    require_command curl
    require_command python3
    if [ "$mode" = publish ]; then
        require_command uv
    fi

    # Never consume a credential inherited by this long-lived shell process.
    unset UV_PUBLISH_TOKEN || true

    local canonical_expected
    canonical_expected=$(canonicalize_name "$distribution")
    [[ "$canonical_expected" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] \
        || die "distribution name is not safe for an index URL: $distribution"
    [[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._+!-]*$ ]] \
        || die "version is not safe for an index URL: $version"
    validate_endpoint_url "publish URL" "$publish_url"
    validate_endpoint_url "index JSON base URL" "$index_json_base_url"
    local index_url="${index_json_base_url%/}/$canonical_expected/$version/json"

    echo "Artifact release mode: $mode"
    printf 'Repository: %s\nRun ID: %s\nExpected commit: %s\n' \
        "$repository" "$run_id" "$expected_commit"
    printf 'Expected distribution: %s %s\n' "$canonical_expected" "$version"
    printf 'Publish URL: %s\nIndex JSON: %s\n' "$publish_url" "$index_url"

    validate_repository_and_run "$repository" "$run_id" "$expected_commit"

    local release_dir
    release_dir=$(mktemp -d "/tmp/lucas-igraph-release.${run_id}.XXXXXX") \
        || die "could not create a temporary release directory"
    local download_dir="$release_dir/download"
    mkdir -p "$download_dir"
    printf 'Preserved artifact workspace: %s\n' "$release_dir"

    echo "Downloading GitHub Actions artifacts..."
    gh run download "$run_id" --repo "$repository" --dir "$download_dir" \
        || die "artifact download failed; workspace preserved at $release_dir"

    local -a artifacts=()
    local path
    while IFS= read -r -d '' path; do
        artifacts+=("$path")
    done < <(find "$download_dir" -type f \( -name '*.whl' -o -name '*.tar.gz' \) -print0)
    [ "${#artifacts[@]}" -gt 0 ] \
        || die "download contained no .whl or .tar.gz distributions; workspace preserved at $release_dir"

    local -a eligible=()
    local -a artifact_names=()
    local basename metadata metadata_name metadata_version lower_basename
    echo "Inspecting embedded distribution metadata:"
    for path in "${artifacts[@]}"; do
        basename=$(basename "$path")
        if array_contains "$basename" ${artifact_names[@]+"${artifact_names[@]}"}; then
            die "duplicate artifact filename $basename; refusing an ambiguous upload (workspace preserved at $release_dir)"
        fi
        artifact_names+=("$basename")
        if ! metadata=$(inspect_distribution "$path"); then
            die "invalid distribution artifact: $path (workspace preserved at $release_dir)"
        fi
        IFS=$'\t' read -r metadata_name metadata_version <<< "$metadata"
        [ "$metadata_name" = "$canonical_expected" ] \
            || die "$basename metadata name is $metadata_name, expected $canonical_expected"
        [ "$metadata_version" = "$version" ] \
            || die "$basename metadata version is $metadata_version, expected $version"
        printf '  valid: %s (%s %s)\n' "$basename" "$metadata_name" "$metadata_version"

        lower_basename=$(lowercase "$basename")
        if [[ "$lower_basename" == *pyodide* ]]; then
            printf '  skipped: %s — Pyodide platform files are not supported by PyPI; original preserved\n' "$basename"
        elif [[ "$lower_basename" =~ (^|[-_.])pp[0-9]+([-_.]|$) ]]; then
            printf '  skipped: %s — PyPy wheel metadata is incompatible (license-file/Metadata-Version); original preserved\n' "$basename"
        else
            eligible+=("$path")
        fi
    done

    local before_json="$release_dir/index-before.json"
    fetch_index_json "$index_url" "$before_json" true \
        || die "package-index inspection failed; refusing to upload (artifacts preserved at $release_dir)"
    local -a published=()
    local filename
    while IFS= read -r filename; do
        [ -n "$filename" ] && published+=("$filename")
    done < <(index_filenames "$before_json")

    if [ "${#published[@]}" -gt 0 ]; then
        echo "Already published files (never re-uploaded):"
        print_index_files "$before_json" | while IFS=$'\t' read -r filename digest; do
            printf '  %s  sha256=%s\n' "$filename" "$digest"
        done
    else
        echo "The index returned no existing files for $canonical_expected $version."
    fi

    local -a candidates=()
    for path in ${eligible[@]+"${eligible[@]}"}; do
        basename=$(basename "$path")
        if array_contains "$basename" ${published[@]+"${published[@]}"}; then
            printf '  skipped: %s — already published\n' "$basename"
        else
            candidates+=("$path")
        fi
    done

    if [ "${#candidates[@]}" -eq 0 ]; then
        echo "No new safe files remain. Nothing will be uploaded and no token is needed."
        printf 'Artifacts remain available at: %s\n' "$release_dir"
        return 0
    fi

    echo "Final candidate files:"
    for path in "${candidates[@]}"; do
        printf '  %s\n' "$(basename "$path")"
    done

    if [ "$mode" = preflight ]; then
        echo "Preflight complete. No token was requested and no upload was attempted."
        printf 'Artifacts remain available at: %s\n' "$release_dir"
        return 0
    fi

    echo "Publishing requires a PyPI-compatible API token. Input is hidden."
    local publish_status=0
    (
        local token
        trap 'unset token UV_PUBLISH_TOKEN' EXIT
        IFS= read -r -s -p 'Token: ' token < /dev/tty
        printf '\n' > /dev/tty
        [ -n "$token" ] || die "empty token; upload cancelled"
        export UV_PUBLISH_TOKEN="$token"
        export UV_PUBLISH_URL="$publish_url"
        uv publish "${candidates[@]}"
    ) || publish_status=$?

    local after_json="$release_dir/index-after.json"
    if [ "$publish_status" -ne 0 ]; then
        printf 'uv publish failed with status %s. Treating the upload as potentially partial.\n' "$publish_status" >&2
        echo "There will be no automatic retry." >&2
        if fetch_index_json "$index_url" "$after_json" true; then
            print_index_state_from_file "$after_json"
        else
            echo "Could not refresh package-index state after the partial failure." >&2
        fi
        printf 'Artifacts and index snapshots are preserved at: %s\n' "$release_dir" >&2
        echo "Re-run --preflight first; it will select only filenames still absent from the index." >&2
        return "$publish_status"
    fi

    fetch_index_json "$index_url" "$after_json" false \
        || die "post-upload package-index verification failed; do not retry blindly (artifacts preserved at $release_dir)"
    local -a after_names=()
    while IFS= read -r filename; do
        [ -n "$filename" ] && after_names+=("$filename")
    done < <(index_filenames "$after_json")

    local missing_after_upload=false
    for path in "${candidates[@]}"; do
        basename=$(basename "$path")
        if ! array_contains "$basename" ${after_names[@]+"${after_names[@]}"}; then
            printf 'Error: successful uv exit but index verification is missing %s\n' "$basename" >&2
            missing_after_upload=true
        fi
    done

    print_index_state_from_file "$after_json"
    printf 'Artifacts and index snapshots are preserved at: %s\n' "$release_dir"
    [ "$missing_after_upload" = false ] \
        || die "post-upload verification was incomplete; do not retry blindly"
    echo "Upload and package-index verification completed successfully."
}

main() {
    if [ "$#" -eq 0 ]; then
        usage
        exit 1
    fi

    case "$1" in
        patch|minor|major)
            local version_type="$1"
            shift
            run_version_release "$version_type" "$@"
            ;;
        --preflight|--inspect)
            shift
            run_artifact_release preflight "$@"
            ;;
        --publish)
            shift
            run_artifact_release publish "$@"
            ;;
        -h|--help)
            usage
            ;;
        *)
            die "unknown mode: $1 (use --help)"
            ;;
    esac
}

main "$@"
