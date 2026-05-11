#!/usr/bin/env bash
#
# Lab-side build & release script for Lightdash.
#
# Pulls the prebuilt /usr/app tree (plus prod-entrypoint.sh + dumb-init) from
# lightdash/lightdash:${LIGHTDASH_VERSION}, packages them as assets on a
# GitHub release, and pushes a slim runtime image to the configured registry.
#
# Required:
#   LIGHTDASH_VERSION  Lightdash docker tag (e.g. 0.2904.0). Required.
#   gh CLI on PATH; GitHub PAT in GITHUB_API_TOKEN (or GH_TOKEN / GITHUB_TOKEN)
#                      with `repo` scope.
#   docker logged in to $REGISTRY (SKIP_PUSH=1 to bypass).
#
# Optional env (defaults shown):
#   GH_REPO=kingfadzi/lightdash-el9
#   REGISTRY=docker.butterflycluster.com
#   REGISTRY_IMAGE=${REGISTRY}/lightdash/lightdash
#   RUNTIME_BASE_IMAGE=docker.butterflycluster.com/builder-images/almalinux9-node:20
#   SKIP_PUSH=0                                     # set to 1 to skip docker push
#   SKIP_RELEASE=0                                  # set to 1 to skip gh release upload
#   AUTO_INIT_REPO=1                                # 0 to fail instead of seeding empty repo

set -euo pipefail

# --- env / defaults ---------------------------------------------------------

: "${LIGHTDASH_VERSION:?LIGHTDASH_VERSION is required (e.g. 0.2904.0)}"
: "${GH_REPO:=kingfadzi/lightdash-el9}"
: "${REGISTRY:=docker.butterflycluster.com}"
: "${REGISTRY_IMAGE:=${REGISTRY}/lightdash/lightdash}"
: "${RUNTIME_BASE_IMAGE:=docker.butterflycluster.com/builder-images/almalinux9-node:20}"
: "${SKIP_PUSH:=0}"
: "${SKIP_RELEASE:=0}"
: "${AUTO_INIT_REPO:=1}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="${REPO_ROOT}/dist"

TAG="lightdash-${LIGHTDASH_VERSION}-el9"
RUNTIME_TAR="lightdash-runtime-${LIGHTDASH_VERSION}-el9.tar.gz"
RUNTIME_IMAGE_TAG="${REGISTRY_IMAGE}:${LIGHTDASH_VERSION}-el9"
BUILDER_TAG="lightdash-builder:${LIGHTDASH_VERSION}"
RELEASE_BASE_URL="https://github.com/${GH_REPO}/releases/download"

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo ">>> $*"; }

# --- preflight (fail fast) --------------------------------------------------

say "[0/6] Preflight"

[ -f "$REPO_ROOT/Dockerfile" ]         || die "missing $REPO_ROOT/Dockerfile"
[ -f "$REPO_ROOT/Dockerfile.runtime" ] || die "missing $REPO_ROOT/Dockerfile.runtime"
command -v docker >/dev/null           || die "docker not on PATH"
docker info >/dev/null 2>&1            || die "docker daemon unreachable"

if [ "$SKIP_RELEASE" != "1" ]; then
  command -v gh >/dev/null || die "gh CLI not on PATH (install or set SKIP_RELEASE=1)"
  export GH_TOKEN="${GH_TOKEN:-${GITHUB_API_TOKEN:-${GITHUB_TOKEN:-}}}"
  [ -n "$GH_TOKEN" ] || die "no GitHub token (set GITHUB_API_TOKEN, GH_TOKEN, or GITHUB_TOKEN)"
  if ! gh repo view "$GH_REPO" --json name >/dev/null 2>&1; then
    die "repo $GH_REPO not found or not accessible with this token"
  fi
  if ! gh api "/repos/${GH_REPO}/commits?per_page=1" >/dev/null 2>&1; then
    if [ "$AUTO_INIT_REPO" = "1" ]; then
      say "    repo $GH_REPO is empty, seeding with README to enable releases"
      readme=$(printf '# %s\n\nPrebuilt Lightdash artifacts for AlmaLinux 9 / RHEL 9. Releases are produced by build/build-release.sh.\n' "${GH_REPO##*/}" | base64 -w0)
      gh api -X PUT "/repos/${GH_REPO}/contents/README.md" \
        -f message="init: seed repo so releases can be created" \
        -f content="$readme" >/dev/null
    else
      die "repo $GH_REPO is empty — seed it with a commit, or set AUTO_INIT_REPO=1"
    fi
  fi
fi

# --- prepare dist -----------------------------------------------------------

rm -rf "$DIST"
mkdir -p "$DIST/staging/usr/bin"

# --- build ------------------------------------------------------------------

say "[1/6] Building builder stage ($BUILDER_TAG)"
docker build \
  --target builder \
  --build-arg LIGHTDASH_VERSION="$LIGHTDASH_VERSION" \
  -f "$REPO_ROOT/Dockerfile" \
  -t "$BUILDER_TAG" \
  "$REPO_ROOT"

say "[2/6] Extracting /usr/app + prod-entrypoint.sh + dumb-init"
CID=$(docker create "$BUILDER_TAG")
trap 'docker rm -f "$CID" >/dev/null 2>&1 || true' EXIT
docker cp "$CID:/usr/app"                    "$DIST/staging/usr/app"
docker cp "$CID:/usr/bin/prod-entrypoint.sh" "$DIST/staging/usr/bin/prod-entrypoint.sh"
docker cp "$CID:/usr/bin/dumb-init"          "$DIST/staging/usr/bin/dumb-init"

[ -d "$DIST/staging/usr/app/packages/backend" ] || die "extracted /usr/app missing packages/backend"
[ -f "$DIST/staging/usr/bin/dumb-init" ]        || die "dumb-init not extracted"

say "[3/6] Packaging runtime tarball ($RUNTIME_TAR)"
if command -v pigz >/dev/null; then
  COMPRESS=(--use-compress-program "pigz -p $(nproc)")
else
  COMPRESS=(-z)
fi
tar "${COMPRESS[@]}" -cf "$DIST/$RUNTIME_TAR" -C "$DIST/staging" .
rm -rf "$DIST/staging"

say "[4/6] Generating SHA256SUMS"
( cd "$DIST" && sha256sum "$RUNTIME_TAR" > SHA256SUMS )
cat "$DIST/SHA256SUMS"

# --- release ----------------------------------------------------------------

if [ "$SKIP_RELEASE" = "1" ]; then
  say "[5/6] SKIP_RELEASE=1, skipping gh release upload"
else
  say "[5/6] Publishing GitHub release $TAG to $GH_REPO"
  if gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
    echo "    release $TAG exists, reusing"
  else
    gh release create "$TAG" \
      --repo "$GH_REPO" \
      --title "Lightdash ${LIGHTDASH_VERSION} (EL9 prebuilt)" \
      --notes "Prebuilt Lightdash ${LIGHTDASH_VERSION} runtime tree (/usr/app + prod-entrypoint.sh + dumb-init), repackaged from lightdash/lightdash:${LIGHTDASH_VERSION}. Binary-compatible with RHEL 9 / AlmaLinux 9 (glibc 2.34)."
  fi
  gh release upload "$TAG" \
    --repo "$GH_REPO" \
    --clobber \
    "$DIST/$RUNTIME_TAR" \
    "$DIST/SHA256SUMS"
fi

# --- runtime image ----------------------------------------------------------

say "[6/6] Building runtime image $RUNTIME_IMAGE_TAG (pulls from $RELEASE_BASE_URL)"
TARBALL_SHA256=$(awk -v t="$RUNTIME_TAR" '$2 == t {print $1}' "$DIST/SHA256SUMS")
[ -n "$TARBALL_SHA256" ] || die "could not extract sha for $RUNTIME_TAR from SHA256SUMS"
docker build \
  -f "$REPO_ROOT/Dockerfile.runtime" \
  --build-arg RUNTIME_BASE_IMAGE="$RUNTIME_BASE_IMAGE" \
  --build-arg LIGHTDASH_VERSION="$LIGHTDASH_VERSION" \
  --build-arg RELEASE_BASE_URL="$RELEASE_BASE_URL" \
  --build-arg RUNTIME_TARBALL_SHA256="$TARBALL_SHA256" \
  -t "$RUNTIME_IMAGE_TAG" \
  "$REPO_ROOT"

if [ "$SKIP_PUSH" = "1" ]; then
  say "SKIP_PUSH=1, skipping docker push"
else
  say "Pushing $RUNTIME_IMAGE_TAG"
  docker push "$RUNTIME_IMAGE_TAG"
fi

say "Done."
echo "    Release : https://github.com/${GH_REPO}/releases/tag/${TAG}"
echo "    Image   : ${RUNTIME_IMAGE_TAG}"
