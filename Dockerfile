# syntax=docker/dockerfile:1.7
#
# LAB-ONLY: extract the prebuilt Lightdash app from lightdash/lightdash:${VERSION}.
#
# Invoked exclusively by build/build-release.sh in the lab. The script does
# `docker build --target builder` then `docker create` + `docker cp` to pull
# /usr/app, /usr/bin/prod-entrypoint.sh and /usr/bin/dumb-init out, packages
# them as a GitHub release asset, and bakes the on-prem image from
# Dockerfile.runtime.
#
# Build (lab):
#   LIGHTDASH_VERSION=0.2904.0 ./build/build-release.sh

ARG LIGHTDASH_VERSION

# ---------- builder ----------
FROM lightdash/lightdash:${LIGHTDASH_VERSION} AS builder
CMD ["true"]

# ---------- runtime ----------
# Not used by on-prem flow (Dockerfile.runtime handles that). Present so
# `docker build` without --target produces a valid image.
FROM lightdash/lightdash:${LIGHTDASH_VERSION}
