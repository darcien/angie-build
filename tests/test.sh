#!/usr/bin/env bash
# Acceptance harness for the production image.
#
#   ./tests/test.sh boringssl|openssl
#
# Owns everything the image must not contain: it generates cert + ECH keys
# at test time via the builder images, mounts keys + test conf into the
# production image, starts it with the documented hardening flags, then
# runs the functional matrix and the hardening assertions.
#
# Success criteria per flavor: ECH accepted by both client families
# (cross-implementation deliberately — each library's client catches the
# other's server bugs), HTTP/3 served, negative ECH control, workers
# non-root, read-only rootfs, no secrets in the image, graceful stop.
set -euo pipefail

cd "$(dirname "$0")/.."

SSL_IMPL="${1:-boringssl}"
case "$SSL_IMPL" in
    boringssl|openssl) ;;
    *) echo "usage: $0 boringssl|openssl" >&2; exit 1 ;;
esac
IMAGE="angie:$SSL_IMPL"
# Flavor-suffixed: a fixed name means two concurrent flavor runs docker-rm
# each other's live container (port 8443 still serializes them, but the
# failure mode becomes an honest bind error instead of a silent kill).
NAME="angie-harness-$SSL_IMPL"
HOST_URL="https://localhost:8443/status"
CONTAINER_HOST="host.docker.internal:8443"

# Digest-pinned: third-party image executing on this Docker host with network
# access — a mutable tag is a supply-chain hole. amd64-only; runs under
# Rosetta on Apple Silicon (no arm64 curl+http3 image found — checked
# curlimages/curl, alpine edge, ymuski).
CURL_HTTP3_IMAGE="badouralix/curl-http3@sha256:dc619967690485f13ed61312e025714b0852f1394c16c8f7c4e39a4942feaec5"

# The documented run flags (README). The matrix runs against exactly these,
# so the documentation cannot drift from what is tested.
RUN_FLAGS=(
    --read-only --tmpfs /run --tmpfs /var/cache/angie:rw,size=64m
    --security-opt no-new-privileges
    --cap-drop=ALL
    --cap-add=NET_BIND_SERVICE --cap-add=SETUID --cap-add=SETGID
    --cap-add=CHOWN
)

echo "== 0. preflight"
# Both builder images are needed regardless of $SSL_IMPL: ECH test clients
# are cross-implementation by design.
for img in "$IMAGE" angie-builder:boringssl angie-builder:openssl; do
    docker image inspect "$img" >/dev/null 2>&1 \
        || { echo "missing image $img — run ./build.sh for both impls first" >&2; exit 1; }
done
docker rm -f "$NAME" >/dev/null 2>&1 || true

certs="$(mktemp -d)"
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$certs"' EXIT

echo "== 1. keygen at test time (builder image — keys never exist in any image layer)"
# Self-signed cert (system openssl CLI, present in both builders) + ECH key
# in the combined PEM angie expects (PKCS#8 private key + base64
# ECHConfigList). ech.list (binary ECHConfigList) is kept for the clients.
# Cert generation is flavor-independent — once, before the case; the
# branches differ only in ECH keygen tooling.
docker run --rm -v "$certs:/out" "angie-builder:$SSL_IMPL" bash -ec '
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -nodes -days 365 -keyout /out/server.key -out /out/server.crt \
        -subj "/CN=testbed.local" \
        -addext "subjectAltName=DNS:testbed.local,DNS:localhost" 2>/dev/null
    chmod 644 /out/server.key /out/server.crt'
case "$SSL_IMPL" in
boringssl)
    # bssl generate-ech emits a raw 32-byte X25519 key: wrap in the fixed
    # RFC 8410 PKCS#8 DER prefix, base64 both into the two PEM blocks.
    docker run --rm -v "$certs:/out" "angie-builder:$SSL_IMPL" bash -ec '
        /build/boringssl/build/bssl generate-ech \
            -out-ech-config-list /out/ech.list \
            -out-ech-config /tmp/ech.config \
            -out-private-key /tmp/ech.priv \
            -public-name public.testbed.local -config-id 0
        { printf "\060\056\002\001\000\060\005\006\003\053\145\156\004\042\004\040"
          cat /tmp/ech.priv; } > /tmp/ech.p8
        { echo "-----BEGIN PRIVATE KEY-----"
          openssl base64 -in /tmp/ech.p8
          echo "-----END PRIVATE KEY-----"
          echo "-----BEGIN ECHCONFIG-----"
          openssl base64 -in /out/ech.list
          echo "-----END ECHCONFIG-----"; } > /out/ech.key
        openssl pkey -in /out/ech.key -noout
        chmod 644 /out/ech.key /out/ech.list'
    ;;
openssl)
    # In-tree openssl 4.0 emits the combined PEM directly (system openssl
    # 3.0 has no ech command).
    docker run --rm -v "$certs:/out" "angie-builder:$SSL_IMPL" bash -ec '
        /build/openssl/.openssl/bin/openssl ech \
            -public_name public.testbed.local -out /out/ech.key
        sed -n "/BEGIN ECHCONFIG/,/END ECHCONFIG/p" /out/ech.key \
            | grep -v ECHCONFIG | openssl base64 -d > /out/ech.list
        [ -s /out/ech.list ]
        chmod 644 /out/ech.key /out/ech.list'
    ;;
esac

echo "== 2. start container with documented hardening flags"
docker run -d --name "$NAME" \
    -p 8443:443/tcp -p 8443:443/udp \
    "${RUN_FLAGS[@]}" \
    -v "$certs:/etc/angie/certs:ro" \
    -v "$PWD/tests/http.d:/etc/angie/http.d:ro" \
    "$IMAGE" >/dev/null
for i in $(seq 1 20); do
    curl -sk --max-time 1 "$HOST_URL" >/dev/null 2>&1 && break
    [ "$i" = 20 ] && { echo "container never answered on 8443:" >&2; docker logs "$NAME" >&2; exit 1; }
    sleep 0.5
done

echo "== 3. plain TLS + negative ECH control (host curl — no ECH on macOS)"
# Without ECH the witness must be empty ("ech=" at end). This is what makes
# the ech=1 positives below meaningful: an always-on witness fails here.
body="$(curl -sk "$HOST_URL")"
echo "$body"
grep -qE 'ech=$' <<<"$body"
# server_tokens off: Server header must not leak the version.
curl -skI "$HOST_URL" | grep -i '^server:' | grep -qv '[0-9]' \
    || { echo 'Server header leaks version (server_tokens?)' >&2; exit 1; }

echo "== 4. HTTP/3 (containerized curl with h3)"
docker run --rm --platform linux/amd64 "$CURL_HTTP3_IMAGE" \
    curl -sk --http3-only "https://$CONTAINER_HOST/status" | grep -F 'proto=HTTP/3.0'

echo "== 5. ECH (cross-implementation clients; ECHConfigList from keygen — no DNS)"
echo "-- 5a. bssl client (BoringSSL family)"
out="$(printf 'GET /status HTTP/1.0\r\nHost: testbed.local\r\n\r\n' | \
    docker run --rm -i -v "$certs:/certs:ro" \
        angie-builder:boringssl \
        /build/boringssl/build/bssl client -connect "$CONTAINER_HOST" \
            -server-name testbed.local -ech-config-list /certs/ech.list 2>&1)"
echo "$out" | grep -F 'Encrypted ClientHello: yes'
echo "$out" | grep -F 'ech=1'

echo "-- 5b. openssl s_client (OpenSSL family)"
# Without -CAfile the status is "ECH: BAD NAME" even though ECH succeeded
# (self-signed cert fails name verify). -quiet suppresses the ECH status
# line but is the mode where the HTTP body comes back; hence two runs.
# -tls1_3 is required against the BoringSSL server: OpenSSL offers TLS 1.2
# in the inner ClientHello by default and BoringSSL rejects a non-1.3-only
# inner with INVALID_CLIENT_HELLO_INNER (verified; browsers send 1.3-only).
s_client() {
    docker run --rm -i -v "$certs:/certs:ro" \
        angie-builder:openssl bash -c '
            b64="$(openssl base64 -in /certs/ech.list | tr -d "\n")"
            exec /build/openssl/.openssl/bin/openssl s_client \
                -connect '"$CONTAINER_HOST"' -servername testbed.local \
                -ech_config_list "$b64" -CAfile /certs/server.crt -tls1_3 \
                -no_ign_eof '"$1"' 2>&1'
}
printf 'GET /status HTTP/1.0\r\nHost: testbed.local\r\n\r\n' | s_client "" \
    | grep -F 'ECH: success'
printf 'GET /status HTTP/1.0\r\nHost: testbed.local\r\n\r\n' | s_client "-quiet" \
    | grep -F 'ech=1'

echo "== 6. hardening assertions"
echo "-- 6a. workers run as angie (uid 101), master as root"
# docker top resolves uids against the docker VM's passwd — host-dependent
# names. Read numeric uids from /proc via a probe sharing the pid namespace
# (the distroless image has no shell to exec into; the builder image is
# local by preflight).
top="$(docker run --rm --pid="container:$NAME" angie-builder:boringssl bash -c \
    'for p in /proc/[0-9]*; do printf "%s %s\n" "$(stat -c %u "$p")" "$(tr "\0" " " < "$p/cmdline")"; done')"
echo "$top"
grep -E '^101 .*worker process' <<<"$top" >/dev/null \
    || { echo 'no worker running as uid 101 (angie)' >&2; exit 1; }
! grep -E '^0 .*worker process' <<<"$top" >/dev/null \
    || { echo 'worker running as root' >&2; exit 1; }

echo "-- 6b. no secrets in image (manifest diff + PEM grep)"
# Primary check: an mtree manifest of the whole image (type, mode, uid/gid,
# symlink target — this also catches setuid bits, ownership drift, and raw
# DER keys that a PEM grep cannot see) diffed against the committed
# expected manifest. Arch names are normalized over the whole line so
# link= targets normalize too; one manifest per flavor, because boringssl
# ships libstdc++/libgcc_s. Generated by bsdtar inside the builder image —
# host tar versions drift, the builder's is pinned. A missing or deviating
# manifest fails the run; to accept a reviewed change:
#   REBASELINE=1 ./tests/test.sh <flavor>   # prints the diff, then accepts
expected="tests/testdata/files-$SSL_IMPL.mtree"
c="$(docker create "$IMAGE")"
docker export "$c" \
    | docker run -i --rm "angie-builder:$SSL_IMPL" \
        bsdtar -cf - --format=mtree --options='!all,type,mode,uid,gid,link' @- \
    | grep -v '^#' \
    | sed -E 's/aarch64|x86_64|x86-64/ARCH/g' \
    | LC_ALL=C sort > "$certs/files.mtree"
docker rm "$c" >/dev/null
[ -s "$certs/files.mtree" ] || { echo 'mtree manifest came out empty' >&2; exit 1; }
if [ ! -f "$expected" ] || ! diff -u "$expected" "$certs/files.mtree"; then
    if [ "${REBASELINE:-}" = 1 ]; then
        mkdir -p "$(dirname "$expected")"
        cp "$certs/files.mtree" "$expected"
        echo "NOTE: rebaselined $expected — review the diff above, commit it"
    else
        echo "image contents deviate from $expected (REBASELINE=1 to accept a reviewed change)" >&2
        exit 1
    fi
fi
! grep -E '^\./etc/angie/certs/.' "$certs/files.mtree" \
    || { echo 'files present under /etc/angie/certs' >&2; exit 1; }
# Second, independent check: grep every saved blob for a PEM private key
# header. Full dashed form only — the binary's SSL parser string constants
# contain bare "PRIVATE KEY" (verified, 8 hits); the dashed form is
# composed at runtime and appears only in an actual key file. Layer blobs
# are raw tars under overlay2 but gzip under containerd-snapshotter (zstd
# is a real containerd option too), so any blob format we cannot scan is a
# failure — otherwise a storage-driver change would quietly turn this
# check into a no-op.
saved="$certs/saved"; mkdir "$saved"
docker save "$IMAGE" | tar -x -C "$saved"
blobs=0
while IFS= read -r f; do
    blobs=$((blobs+1))
    magic="$(od -An -tx1 -N4 "$f" | tr -d ' ')"
    if [ "${magic:0:4}" = 1f8b ]; then
        unpack="gzip -dc"
    elif dd if="$f" bs=1 skip=257 count=5 2>/dev/null | grep -q '^ustar$'; then
        unpack="cat"    # raw tar
    elif [ "$magic" = 28b52ffd ]; then
        echo "zstd blob $f — sweep cannot scan it; add zstd handling" >&2; exit 1
    elif [ "${magic:0:2}" = 7b ]; then
        unpack="cat"    # '{' — JSON manifest/config blob, plain text scans fine
    elif [[ "$f" == */blobs/* || "$f" == *.tar ]]; then
        echo "layer blob $f has an unrecognized format ($magic); refusing to skip it" >&2; exit 1
    else
        unpack="cat"    # small metadata (oci-layout, repositories, …)
    fi
    # grep -c, not -q: -q exits on first match, the unpacker takes SIGPIPE,
    # and under pipefail a HIT would read as pipeline failure → miss.
    hits="$($unpack "$f" | grep -ac -- '-----BEGIN [A-Z ]*PRIVATE KEY-----' || true)"
    [ "$hits" = 0 ] || { echo "PEM private key block found in $f" >&2; exit 1; }
done < <(find "$saved" -type f)
[ "$blobs" -gt 0 ] || { echo 'docker save produced no files; nothing was scanned' >&2; exit 1; }

echo "-- 6c. provenance labels present"
docker inspect --format '{{index .Config.Labels "org.angie-build.ssl-commit"}}' "$IMAGE" \
    | grep -q . || { echo 'ssl-commit label missing' >&2; exit 1; }

echo "-- 6d. graceful stop (SIGQUIT; drain works without CAP_KILL — verified)"
start=$(date +%s)
docker stop -t 10 "$NAME" >/dev/null
dur=$(( $(date +%s) - start ))
code="$(docker inspect --format '{{.State.ExitCode}}' "$NAME")"
docker rm "$NAME" >/dev/null
[ "$code" = 0 ] && [ "$dur" -lt 10 ] \
    || { echo "stop not graceful: exit=$code dur=${dur}s" >&2; exit 1; }

echo "ok ($SSL_IMPL): TLS, negative ECH control, h3, ECH via both clients, hardening"
