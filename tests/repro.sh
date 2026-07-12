#!/usr/bin/env bash
# Reproducibility check: build the image twice — second run with --no-cache,
# because a cache-served rebuild proves nothing — and require identical
# image IDs (the config digest, which covers all layer diff-ids and
# timestamps).
#
# The comparison is only meaningful if:
#   - both runs use the same BuildKit version (one local daemon here; CI
#     must pin its BuildKit) — compression and mediatype changes across
#     versions shift digests
#   - --provenance=false --sbom=false: attestation manifests embed wall
#     clock and differ on every build by design; attach them after the
#     comparison, not before
#   - the pins come from the existing image labels, so both runs build the
#     exact same source
#
# Expensive (two full compiles). Opt-in, not part of test.sh.
#
#   ./tests/repro.sh boringssl|openssl
set -euo pipefail

cd "$(dirname "$0")/.."

SSL_IMPL="${1:-boringssl}"
SSL_COMMIT="$(docker inspect --format '{{index .Config.Labels "org.angie-build.ssl-commit"}}' "angie:$SSL_IMPL")"
[ -n "$SSL_COMMIT" ] || { echo "no angie:$SSL_IMPL image with ssl-commit label — run ./build.sh first" >&2; exit 1; }
# Same principle for the angie version: rebuild exactly what the label
# says, even if the original build overrode ANGIE_VERSION via env.
ANGIE_VERSION="$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "angie:$SSL_IMPL")"
[ -n "$ANGIE_VERSION" ] || { echo "version label missing on angie:$SSL_IMPL" >&2; exit 1; }
# SOURCE_DATE_EPOCH + BUILD_CREATED with the same non-empty checks build.sh
# gets — an empty build arg would override the ARG default and die deep in
# stage-runtime instead of here.
. ./build-env.sh

build() {
    docker buildx build --load --no-cache \
        --provenance=false --sbom=false \
        --build-arg SSL_IMPL="$SSL_IMPL" \
        --build-arg SSL_COMMIT="$SSL_COMMIT" \
        --build-arg ANGIE_VERSION="$ANGIE_VERSION" \
        --build-arg SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
        --build-arg BUILD_CREATED="$BUILD_CREATED" \
        --build-arg BUILD_REVISION=repro \
        -t "angie-repro:$1" . >/dev/null 2>&1
}

echo "repro check: $SSL_IMPL @ $SSL_COMMIT (two --no-cache builds, be patient)"
build a
id_a="$(docker inspect --format '{{.Id}}' angie-repro:a)"
echo "build A: $id_a"
build b
id_b="$(docker inspect --format '{{.Id}}' angie-repro:b)"
echo "build B: $id_b"

if [ "$id_a" = "$id_b" ]; then
    docker rmi angie-repro:a angie-repro:b >/dev/null
    echo "REPRODUCIBLE: identical image ID"
else
    # keep both images for diagnosis; layer diff pinpoints the divergence
    echo "NOT REPRODUCIBLE: image IDs differ" >&2
    echo "--- diff_ids A vs B (images kept as angie-repro:a/b):" >&2
    diff <(docker inspect --format '{{json .RootFS.Layers}}' angie-repro:a | tr , '\n') \
         <(docker inspect --format '{{json .RootFS.Layers}}' angie-repro:b | tr , '\n') >&2 || true
    exit 1
fi
