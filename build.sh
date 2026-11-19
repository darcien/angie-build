#!/usr/bin/env bash
# Build the production image. The SSL library pin is resolved here, outside
# docker: a "fetch master HEAD" inside a cached layer would silently rebuild
# nothing.
#
#   ./build.sh boringssl                 # pin = current master HEAD
#   ./build.sh boringssl <commit>        # explicit pin (full 40-hex hash)
#   ./build.sh openssl openssl-4.0.1     # tag required; 4.0+ for ECH + QUIC API
#
# Tags: angie:<impl> (moving, local convenience) and a release tag carrying
# version + flavor + pin. Tag hashes are convenience; the image labels are
# the authoritative provenance. angie-builder:<impl> images hold the ECH
# test clients and keygen tools for tests/test.sh; they contain test keys
# and a toolchain, so they stay local.
set -euo pipefail

SSL_IMPL="${1:-boringssl}"
ANGIE_VERSION="${ANGIE_VERSION:-1.12.4}"

# Resolved before the case: both release tags embed it. "unversioned" only
# happens outside a git checkout — tolerated for local experiments. A dirty
# tree stamps "-dirty": the revision label is the audit trail, and a clean
# HEAD hash on an image built from uncommitted changes would be a lie.
BUILD_REVISION="$(git rev-parse HEAD 2>/dev/null || echo unversioned)"
[ -z "$(git status --porcelain 2>/dev/null)" ] || BUILD_REVISION="$BUILD_REVISION-dirty"
# Short form for tags keeps the -dirty marker (truncation would drop it).
REV_SHORT="${BUILD_REVISION:0:7}"
case "$BUILD_REVISION" in *-dirty) REV_SHORT="$REV_SHORT-dirty" ;; esac

case "$SSL_IMPL" in
    boringssl)
        # The stamp must be content-addressed: a branch/tag name in the image
        # label records nothing. Resolve names via ls-remote; reject short
        # hashes (ls-remote cannot expand them — pass the full 40-hex hash).
        ref="${2:-HEAD}"
        if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
            SSL_COMMIT="$ref"
        else
            matches="$(git ls-remote https://boringssl.googlesource.com/boringssl "$ref")"
            if [ "$(grep -c . <<<"$matches")" -gt 1 ]; then
                echo "ambiguous ref '$ref' matches multiple refs:" >&2
                echo "$matches" >&2
                exit 1
            fi
            SSL_COMMIT="$(cut -f1 <<<"$matches")"
        fi
        [[ "$SSL_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
            || { echo "cannot resolve '$ref' to a full commit hash" >&2; exit 1; }
        RELEASE_TAG="$ANGIE_VERSION-boringssl.$(date +%Y%m%d).${SSL_COMMIT:0:7}"
        ;;
    openssl)
        SSL_COMMIT="${2:?openssl needs an explicit tag, e.g. openssl-4.0.1}"
        # Date + repo short hash, same monotonic scheme as boringssl: a
        # SNAPSHOT_DATE bump or conf change rebuilds different contents,
        # and without these the same tag would quietly start naming a
        # different image.
        RELEASE_TAG="$ANGIE_VERSION-$SSL_COMMIT.$(date +%Y%m%d).$REV_SHORT"
        ;;
    *)
        echo "usage: $0 boringssl|openssl [commit-or-tag]" >&2
        exit 1
        ;;
esac

# SOURCE_DATE_EPOCH + BUILD_CREATED from the shared helper (single source:
# the Dockerfile ARG default; repro.sh sources the same file).
. ./build-env.sh

echo "SSL_IMPL=$SSL_IMPL SSL_COMMIT=$SSL_COMMIT ANGIE_VERSION=$ANGIE_VERSION"
echo "TAG=angie:$RELEASE_TAG REVISION=$BUILD_REVISION"

docker build \
    --build-arg SSL_IMPL="$SSL_IMPL" \
    --build-arg SSL_COMMIT="$SSL_COMMIT" \
    --build-arg ANGIE_VERSION="$ANGIE_VERSION" \
    --build-arg SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    --build-arg BUILD_REVISION="$BUILD_REVISION" \
    --build-arg BUILD_CREATED="$BUILD_CREATED" \
    -t "angie:$SSL_IMPL" \
    -t "angie:$RELEASE_TAG" \
    .

# tests/test.sh runs the ECH clients (bssl client, openssl s_client) and the
# key generation from the builder stages — the macOS host has no ECH-capable
# tooling. Same cache, so this tag is near-free.
docker build \
    --target "build-$SSL_IMPL" \
    --build-arg SSL_COMMIT="$SSL_COMMIT" \
    --build-arg ANGIE_VERSION="$ANGIE_VERSION" \
    --build-arg SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    -t "angie-builder:$SSL_IMPL" \
    .
