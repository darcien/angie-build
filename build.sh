#!/usr/bin/env bash
# Build the testbed image. Resolves the SSL library pin OUTSIDE docker so a
# cached layer can never silently serve a stale "master HEAD".
#
#   ./build.sh boringssl                 # pin = current master HEAD
#   ./build.sh boringssl <commit>        # explicit pin
#   ./build.sh openssl openssl-4.0.1     # tag required; 4.0+ for ECH + QUIC API
set -euo pipefail

SSL_IMPL="${1:-boringssl}"
ANGIE_VERSION="${ANGIE_VERSION:-1.11.8}"

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
        ;;
    openssl)
        SSL_COMMIT="${2:?openssl needs an explicit tag, e.g. openssl-4.0.1}"
        ;;
    *)
        echo "usage: $0 boringssl|openssl [commit-or-tag]" >&2
        exit 1
        ;;
esac

echo "SSL_IMPL=$SSL_IMPL SSL_COMMIT=$SSL_COMMIT ANGIE_VERSION=$ANGIE_VERSION"

docker build \
    --build-arg SSL_IMPL="$SSL_IMPL" \
    --build-arg SSL_COMMIT="$SSL_COMMIT" \
    --build-arg ANGIE_VERSION="$ANGIE_VERSION" \
    -t "angie-testbed:$SSL_IMPL" \
    .

# tests/test.sh runs the ECH clients (bssl client, openssl s_client) from the
# builder stages — macOS host has no ECH-capable client. Tag it; same cache,
# near-free.
docker build \
    --target "build-$SSL_IMPL" \
    --build-arg SSL_COMMIT="$SSL_COMMIT" \
    --build-arg ANGIE_VERSION="$ANGIE_VERSION" \
    -t "angie-testbed:builder-$SSL_IMPL" \
    .
