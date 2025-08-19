#!/bin/bash

# Release helper for python-igraph fork
# Usage: ./scripts/release.sh [major|minor|patch|build] [--push|-p] [--remote <name>] [--branch <name>]
# - major: X.Y.Z.B -> (X+1).0.0.0
# - minor: X.Y.Z.B -> X.(Y+1).0.0
# - patch: X.Y.Z.B -> X.Y.(Z+1).0
# - build: X.Y.Z.B -> X.Y.Z.(B+1)

set -euo pipefail

if [ $# -eq 0 ]; then
  echo "Usage: $0 [major|minor|patch|build] [--push|-p] [--remote <name>] [--branch <name>]" >&2
  exit 1
fi

VERSION_TYPE=$1; shift
if [[ ! "$VERSION_TYPE" =~ ^(major|minor|patch|build)$ ]]; then
  echo "Error: version type must be one of: major, minor, patch, build" >&2
  exit 1
fi

PUSH=false
REMOTE=origin
# default branch: current branch
BRANCH=$(git rev-parse --abbrev-ref HEAD)

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--push)
      PUSH=true; shift ;;
    --remote)
      REMOTE="$2"; shift 2 ;;
    --branch)
      BRANCH="$2"; shift 2 ;;
    *)
      echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

VERSION_FILE="src/igraph/version.py"
if [ ! -f "$VERSION_FILE" ]; then
  echo "Error: $VERSION_FILE not found" >&2
  exit 1
fi

# Extract current version tuple from version.py (up to 4 parts)
CURRENT_VERSION=$(python - <<'PY'
import re, pathlib, sys
text = pathlib.Path('src/igraph/version.py').read_text()
m = re.search(r'__version_info__\s*=\s*\(([^)]*)\)', text)
if not m:
    sys.exit(1)
parts = [int(x) for x in re.findall(r'\d+', m.group(1))[:4]]
while len(parts) < 4:
    parts.append(0)
print('.'.join(str(x) for x in parts))
PY
)
if [ -z "$CURRENT_VERSION" ]; then
  echo "Error: could not parse current version from $VERSION_FILE" >&2
  exit 1
fi

IFS='.' read -r MAJOR MINOR PATCH BUILD <<<"${CURRENT_VERSION}"
MAJOR=${MAJOR:-0}
MINOR=${MINOR:-0}
PATCH=${PATCH:-0}
BUILD=${BUILD:-0}

case "$VERSION_TYPE" in
  major)
    ((MAJOR+=1)); MINOR=0; PATCH=0; BUILD=0 ;;
  minor)
    ((MINOR+=1)); PATCH=0; BUILD=0 ;;
  patch)
    ((PATCH+=1)); BUILD=0 ;;
  build)
    ((BUILD+=1)) ;;
esac

NEW_VERSION="$MAJOR.$MINOR.$PATCH.$BUILD"
echo "Current version: $CURRENT_VERSION"
echo "New version:     $NEW_VERSION"

# Update version.py in-place
SED_EXPR="s/^__version_info__ = .*/__version_info__ = (${MAJOR}, ${MINOR}, ${PATCH}, ${BUILD})/"
if [[ "$OSTYPE" == "darwin"* ]]; then
  sed -i '' "$SED_EXPR" "$VERSION_FILE"
else
  sed -i "$SED_EXPR" "$VERSION_FILE"
fi

echo "Updated $VERSION_FILE"

# Commit and tag
git add "$VERSION_FILE"
git commit -m "Bump version to $NEW_VERSION"

TAG="$NEW_VERSION"
git tag "$TAG"
echo "Created tag: $TAG"

if $PUSH; then
  echo "Pushing $BRANCH and tag $TAG to $REMOTE..."
  git push "$REMOTE" "$BRANCH"
  git push "$REMOTE" "$TAG"
  echo "Done. GitHub Actions will build and publish to PyPI (job: publish_pypi)."
else
  echo
  echo "Next steps:"
  echo "- Push changes: git push $REMOTE $BRANCH"
  echo "- Push tag:     git push $REMOTE $TAG"
  echo
  echo "Pushing the tag will trigger GitHub Actions to build and publish to PyPI (job: publish_pypi)."
fi
