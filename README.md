# angie-build

A hardened, reproducible container image for
[angie](https://github.com/webserver-llc/angie), linked statically against
an SSL library with ECH support, serving ECH and full QUIC/HTTP3. Two
flavors: BoringSSL (pinned to a master commit) and tagged OpenSSL 4.x.

Why? Mainly for learning and tinkering. I've been using angie on Debian,
which links against OpenSSL 3.x, and features like ECH require angie to be
built with a different SSL library.

## Build

```sh
./build.sh boringssl             # pins BoringSSL master HEAD, stamps it in labels
./build.sh boringssl <commit>    # explicit pin (full 40-hex hash)
./build.sh openssl openssl-4.0.1 # tag required; 4.0+ for ECH and the QUIC API
```

Each build produces three tags:

- `angie:<flavor>` — moving tag
- `angie:<version>-<flavor>...` — dated release tag
- `angie-builder:<flavor>` — ECH test clients and keygen tooling for the
  harness; contains test keys and a toolchain, so it stays local

The image labels are the authoritative provenance: OCI
`version`/`revision`/`created` plus `ssl-impl`/`ssl-commit`. A build from
a dirty tree stamps `<hash>-dirty`.

## Run

The image ships no keys. Mount them (`server.crt`, `server.key`, and for
ECH an `ech.key` plus an `http.d` conf with `ssl_encrypted_hello_key`):

```sh
docker run -p 443:443/tcp -p 443:443/udp \
  --read-only --tmpfs /run --tmpfs /var/cache/angie:rw,size=64m \
  --security-opt no-new-privileges \
  --cap-drop=ALL --cap-add=NET_BIND_SERVICE --cap-add=SETUID \
  --cap-add=SETGID --cap-add=CHOWN \
  -v /path/to/certs:/etc/angie/certs:ro \
  [-v /path/to/http.d:/etc/angie/http.d:ro] \
  angie:<flavor>
```

The UDP publish is required for QUIC. These flags are the tested minimum:
the acceptance harness runs against exactly them, so if the image passes
its tests, it runs read-only with these four capabilities and no others.
Serving ECH in production also needs key rotation and a DNS HTTPS record;
that is deployment work the image does not do for you — it consumes the
mounted PEM.

## Trying it out

The test harness does all of this automatically; this is the by-hand
version, for seeing each moving part. Only docker is needed — key
generation runs in the builder image, so the host needs no TLS tooling.
The openssl flavor is used here because its keygen is one command; the
BoringSSL variant of every step is in `tests/test.sh`.

Generate a self-signed certificate and an ECH key:

```sh
mkdir -p demo/certs demo/http.d
docker run --rm -v "$PWD/demo/certs:/out" angie-builder:openssl bash -c '
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -nodes -days 365 -keyout /out/server.key -out /out/server.crt \
      -subj "/CN=demo.local" -addext "subjectAltName=DNS:demo.local"
  /build/openssl/.openssl/bin/openssl ech \
      -public_name public.demo.local -out /out/ech.key
  chmod 644 /out/*'
```

ECH is deploy-time configuration, so give the server a conf that loads
the key:

```sh
cat > demo/http.d/demo.conf <<'EOF'
server {
    listen 443 ssl;
    listen 443 quic reuseport;

    ssl_certificate         /etc/angie/certs/server.crt;
    ssl_certificate_key     /etc/angie/certs/server.key;
    ssl_encrypted_hello_key /etc/angie/certs/ech.key;

    location / { return 200 "ech=$ssl_encrypted_hello\n"; }
}
EOF
```

Run it (same flags as above, plus a host port):

```sh
docker run -d --name angie-demo -p 8443:443/tcp -p 8443:443/udp \
  --read-only --tmpfs /run --tmpfs /var/cache/angie:rw,size=64m \
  --security-opt no-new-privileges \
  --cap-drop=ALL --cap-add=NET_BIND_SERVICE --cap-add=SETUID \
  --cap-add=SETGID --cap-add=CHOWN \
  -v "$PWD/demo/certs:/etc/angie/certs:ro" \
  -v "$PWD/demo/http.d:/etc/angie/http.d:ro" \
  angie:openssl
```

Plain TLS first. An ordinary client sends no ECH, so the witness must be
empty — that's the negative control that makes the positive result below
mean something:

```sh
$ curl -sk https://localhost:8443/
ech=
```

Now with ECH. The client needs the ECHConfigList; in the real world it
comes from a DNS HTTPS record you publish, here it is read straight out
of `ech.key` (base64, between the ECHCONFIG markers). `-CAfile` because
name verification against a self-signed cert would otherwise report
`ECH: BAD NAME` even after a successful handshake:

```sh
docker run --rm -v "$PWD/demo/certs:/certs:ro" angie-builder:openssl bash -c '
  b64=$(sed -n "/BEGIN ECHCONFIG/,/END ECHCONFIG/p" /certs/ech.key \
        | grep -v ECHCONFIG | tr -d "\n")
  printf "GET / HTTP/1.0\r\nHost: demo.local\r\n\r\n" \
    | /build/openssl/.openssl/bin/openssl s_client \
        -connect host.docker.internal:8443 -servername demo.local \
        -ech_config_list "$b64" -CAfile /certs/server.crt \
        -tls1_3 -no_ign_eof 2>/dev/null' | grep -E 'ECH|ech='
```

It prints the client's verdict, including the name that was hidden and
the one that was visible on the wire:

```
ECH: success: 1
ECH: inner: demo.local
ECH: outer: public.demo.local
```

(The server's own witness is the `ech=` variable in the response body;
s_client only returns the body in `-quiet` mode, which in turn hides the
ECH status line — `tests/test.sh` runs it both ways.) HTTP/3, if
curiosity persists (amd64 image; runs under Rosetta on Apple Silicon):

```sh
docker run --rm --platform linux/amd64 badouralix/curl-http3 \
  curl -sk --http3-only https://host.docker.internal:8443/
```

Cleanup:

```sh
docker rm -f angie-demo && rm -rf demo
```

## Test

```sh
./tests/test.sh <flavor>    # needs both builder images (cross-implementation ECH clients)
./tests/repro.sh <flavor>   # double-build reproducibility check (slow)
```

The harness generates throwaway keys at test time via the builder images,
mounts them together with `tests/http.d/`, and asserts:

- plain TLS, with a negative ECH control
- HTTP/3
- ECH via both client families (`bssl client` and `openssl s_client` —
  each library's client catches the other's server bugs)
- workers running as uid 101
- no version in the Server header
- image contents matching the committed mtree manifest (type, mode,
  ownership, symlink targets)
- no PEM key material in any layer
- provenance labels
- a graceful stop

If a deliberate change alters the image contents, rerun with
`REBASELINE=1` to regenerate the manifest, review the printed diff, and
commit it.

## Supply chain and reproducibility

Every build input is pinned:

- source tarballs by sha256, verified before untar
- BoringSSL by full commit hash, resolved outside docker by build.sh
- base and test images by digest
- apt by snapshot.debian.org date — https from the first byte, with the
  committed `isrg-root-x1.pem` as the pinned CA
- the build timestamp by `SOURCE_DATE_EPOCH`

The bump procedure for each pin lives in the comment next to it in the
Dockerfile.

Two builds from the same pins produce byte-identical images;
`tests/repro.sh` proves it with a `--no-cache` double build. The compile
is hardened explicitly (FORTIFY, stack protector, full RELRO, PIE) and the
build fails if the flags did not take — Debian's compiler defaults alone
provide almost none of this.

Builds on this machine are arm64 proofs. The deployable amd64 image needs
a CI or cross-build story that does not exist yet; nothing built on a
laptop should be promoted.

## Layout

- `Dockerfile` — multi-stage dual build, `SSL_IMPL=boringssl|openssl`
- `build.sh` — resolves the SSL pin outside docker, builds, stamps
- `build-env.sh` — shared pins derived from the Dockerfile
- `conf/` — shipped default config (TLS on 443, `http.d/` include)
- `tests/` — acceptance harness, test config, expected image manifests
- `isrg-root-x1.pem` — CA root pinned for apt's https to snapshot.debian.org
