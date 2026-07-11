#!/usr/bin/env bash
# Testbed checks against a running container:
#   docker run --rm -p 8443:8443/tcp -p 8443:8443/udp angie-testbed:<impl>
# (UDP publish required for QUIC.)
#
# Success criteria per SSL_IMPL (plan.md): ECH accepted by BOTH client
# families (cross-implementation on purpose), HTTP/3 served, -V names the
# pinned library, no dynamic libssl/libcrypto (guard 3 covers the last two
# at build time).
set -euo pipefail

SSL_IMPL="${1:-boringssl}"
IMAGE="angie-testbed:$SSL_IMPL"
HOST_URL="https://localhost:8443/"
CONTAINER_HOST="host.docker.internal:8443"
CONTAINER_URL="https://$CONTAINER_HOST/"

# Digest-pinned: third-party image executing on this Docker host with network
# access — a mutable tag is a supply-chain hole. amd64-only; runs under
# Rosetta on Apple Silicon (no arm64 curl+http3 image found — checked
# curlimages/curl, alpine edge, ymuski).
CURL_HTTP3_IMAGE="badouralix/curl-http3@sha256:dc619967690485f13ed61312e025714b0852f1394c16c8f7c4e39a4942feaec5"

# Preflight: test 3 needs BOTH builder images regardless of $SSL_IMPL
# (cross-implementation clients by design) — fail here with a clear message,
# not mid-run with docker "No such image".
for img in "$IMAGE" angie-testbed:builder-boringssl angie-testbed:builder-openssl; do
    docker image inspect "$img" >/dev/null 2>&1 \
        || { echo "missing image $img — run ./build.sh for both impls first" >&2; exit 1; }
done

echo "== 1. plain TLS sanity + negative ECH control (host curl — no ECH, no h3 on macOS)"
# Without ECH the server witness must be empty ("ech=" at end of body). This
# is what makes the ech=1 positives in test 3 meaningful: an always-on
# witness (config regression, angie behavior change) fails here.
body="$(curl -sk "$HOST_URL")" \
    || { echo "no answer on 8443 — is the container running?" >&2; exit 1; }
echo "$body"
grep -qE 'ech=$' <<<"$body"

echo "== 2. HTTP/3 (containerized curl with h3)"
docker run --rm --platform linux/amd64 "$CURL_HTTP3_IMAGE" \
    curl -sk --http3-only "$CONTAINER_URL" | grep -F 'proto=HTTP/3.0'

echo "== 3. ECH (cross-implementation clients; ECHConfigList from the image — no DNS)"
# Both client families against whichever server image runs — cross-library
# on purpose (same-library-both-ends hides spec-level bugs). Requires both
# builder images (build.sh tags them).
# Witnesses, both checked per client:
#   client: bssl "Encrypted ClientHello: yes" / s_client "ECH: success"
#   server: body ech=1 ($ssl_encrypted_hello)
ech_list="$(mktemp)"
ca_crt="$(mktemp)"
trap 'rm -f "$ech_list" "$ca_crt"' EXIT
docker run --rm "$IMAGE" cat /etc/angie/certs/ech.list > "$ech_list"
docker run --rm "$IMAGE" cat /etc/angie/certs/server.crt > "$ca_crt"

echo "-- 3a. bssl client (BoringSSL family)"
out="$(printf 'GET / HTTP/1.0\r\nHost: testbed.local\r\n\r\n' | \
    docker run --rm -i -v "$ech_list:/ech.list:ro" \
        angie-testbed:builder-boringssl \
        /build/boringssl/build/bssl client -connect "$CONTAINER_HOST" \
            -server-name testbed.local -ech-config-list /ech.list 2>&1)"
echo "$out" | grep -F 'Encrypted ClientHello: yes'
echo "$out" | grep -F 'ech=1'

echo "-- 3b. openssl s_client (OpenSSL family)"
# Without -CAfile the status is "ECH: BAD NAME" even though ECH succeeded
# (self-signed cert fails name verify). -quiet suppresses the ECH status
# line but is the mode where the HTTP body comes back; hence two runs.
# -tls1_3 is required against the BoringSSL server: OpenSSL offers TLS 1.2
# in the inner ClientHello by default and BoringSSL rejects a non-1.3-only
# inner with INVALID_CLIENT_HELLO_INNER (verified; browsers send 1.3-only).
s_client() {
    docker run --rm -i -v "$ech_list:/ech.list:ro" -v "$ca_crt:/ca.crt:ro" \
        angie-testbed:builder-openssl bash -c '
            b64="$(openssl base64 -in /ech.list | tr -d "\n")"
            exec /build/openssl/.openssl/bin/openssl s_client \
                -connect '"$CONTAINER_HOST"' -servername testbed.local \
                -ech_config_list "$b64" -CAfile /ca.crt -tls1_3 \
                -no_ign_eof '"$1"' 2>&1'
}
printf 'GET / HTTP/1.0\r\nHost: testbed.local\r\n\r\n' | s_client "" \
    | grep -F 'ECH: success'
printf 'GET / HTTP/1.0\r\nHost: testbed.local\r\n\r\n' | s_client "-quiet" \
    | grep -F 'ech=1'
echo "ECH OK (both client families, client + server witnesses)"
