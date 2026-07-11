# syntax=docker/dockerfile:1@sha256:87999aa3d42bdc6bea60565083ee17e86d1f3339802f543c0d03998580f9cb89
#
# angie + static SSL testbed image.
# SSL_IMPL=boringssl|openssl selects the library; same runtime stage for both.
# SSL_COMMIT must be resolved OUTSIDE the build (see build.sh) and is stamped
# into an image label — a "fetch HEAD" inside a cached layer rebuilds nothing.
#
# Every input is pinned: tarballs by sha256 (ARGs below, next to the RUN that
# verifies them), git by full commit hash, images by digest. Mutable tags
# would break "same inputs, same label". Renovate/Dependabot can bump the
# FROM digests and ARG versions in place.

ARG SSL_IMPL=boringssl

FROM debian:bookworm@sha256:30482e873082e906a4908c10529180aefb6f77620aea7404b909829fadc5d168 AS base
# Guard 1: libssl-dev must never enter this environment — with it present, a
# wrong -I/-L silently falls back to system OpenSSL and configure cannot tell.
# The openssl CLI package (for the self-signed cert) does not pull libssl-dev.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gcc make libpcre2-dev zlib1g-dev openssl \
    && rm -rf /var/lib/apt/lists/* \
    && if dpkg -s libssl-dev >/dev/null 2>&1; then \
        echo 'guard 1 FAILED: libssl-dev present in build env' >&2; exit 1; fi

ARG ANGIE_VERSION=1.11.8
# sha256 of angie-${ANGIE_VERSION}.tar.gz. Cross-checked against the
# GPG-signed apt Sources index (angie_${ANGIE_VERSION}.orig.tar.gz — same
# content, independent provenance). Update together with ANGIE_VERSION.
ARG ANGIE_SHA256=849897c78f79c3b04d035778e34993a92188e6bd2c0c3ba8ce3ad5eb1505ebd3
WORKDIR /build
RUN curl -fsSL -o angie.tar.gz \
        "https://download.angie.software/files/angie-${ANGIE_VERSION}.tar.gz" \
    && echo "${ANGIE_SHA256}  angie.tar.gz" | sha256sum -c - \
    && tar xzf angie.tar.gz && mv "angie-${ANGIE_VERSION}" angie \
    && rm angie.tar.gz

# Self-signed cert for the testbed. ECH keys are generated later, in the
# builder stage — they need the bssl tool.
RUN mkdir /build/certs && openssl req -x509 -newkey ec \
        -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 365 \
        -keyout /build/certs/server.key -out /build/certs/server.crt \
        -subj "/CN=testbed.local" \
        -addext "subjectAltName=DNS:testbed.local,DNS:localhost"


FROM base AS build-boringssl
RUN apt-get update && apt-get install -y --no-install-recommends \
        cmake ninja-build git g++ \
    && rm -rf /var/lib/apt/lists/* \
    && if dpkg -s libssl-dev >/dev/null 2>&1; then \
        echo 'guard 1 FAILED: libssl-dev pulled in by build deps' >&2; exit 1; fi

# BoringSSL commit hash, resolved outside the build (build.sh).
ARG SSL_COMMIT
RUN test -n "$SSL_COMMIT" || { echo 'SSL_COMMIT build arg required' >&2; exit 1; }
# Shallow fetch-by-SHA (googlesource allows it): content-addressed — we get
# exactly the stamped commit or a hard error, and no dependence on ref state
# at fetch time. build.sh guarantees SSL_COMMIT is a full 40-hex hash.
RUN git init /build/boringssl \
    && git -C /build/boringssl fetch --depth 1 \
        https://boringssl.googlesource.com/boringssl "$SSL_COMMIT" \
    && git -C /build/boringssl checkout --detach FETCH_HEAD
# No Go: only needed for BoringSSL tests (BUILDING.md). Build only the
# targets we need — the default target includes tests, which trip
# gcc-12 -Werror false positives and waste time.
RUN cmake -S /build/boringssl -B /build/boringssl/build \
        -GNinja -DCMAKE_BUILD_TYPE=Release \
    && ninja -C /build/boringssl/build ssl crypto bssl

# Lib layout varies by BoringSSL vintage: build/ssl + build/crypto (older) or
# top of build/ (newer). Detect; a wrong -L must be a hard error, not a
# silent fallback.
RUN if [ -f /build/boringssl/build/ssl/libssl.a ]; then \
        printf -- '-L/build/boringssl/build/ssl -L/build/boringssl/build/crypto' \
            > /build/ssl-ldflags; \
    elif [ -f /build/boringssl/build/libssl.a ]; then \
        printf -- '-L/build/boringssl/build' > /build/ssl-ldflags; \
    else \
        echo 'libssl.a not found in BoringSSL build tree' >&2; exit 1; \
    fi

# Guard 2: preflight — prove the -I path serves BoringSSL headers.
RUN printf '#include <openssl/base.h>\n#ifndef OPENSSL_IS_BORINGSSL\n#error not boringssl\n#endif\n' \
        | cc -I/build/boringssl/include -fsyntax-only -x c -

# BoringSSL contains C++ → needs -lstdc++, and it must come AFTER
# -lssl -lcrypto: --with-ld-opt lands before the feature-test libs, where the
# linker drops it and the C++ runtime symbols in the static archives stay
# undefined — configure then reports "OpenSSL library ... not found". Patch
# the feature libs instead; grep proves the patch took (hard error if the
# upstream string changes).
RUN sed -i 's/-lssl -lcrypto \$NGX_LIBDL/-lssl -lcrypto -lstdc++ $NGX_LIBDL/' \
        /build/angie/auto/lib/openssl/conf \
    && grep -q -- '-lcrypto -lstdc++' /build/angie/auto/lib/openssl/conf

# Absolute paths only: configure's relative-path fallback is the
# silent-failure trap.
RUN cd /build/angie && ./configure \
        --prefix=/usr/local/angie \
        --sbin-path=/usr/sbin/angie \
        --conf-path=/etc/angie/angie.conf \
        --pid-path=/run/angie.pid \
        --error-log-path=/dev/stderr \
        --http-log-path=/dev/stdout \
        --with-http_ssl_module \
        --with-http_v3_module \
        --with-cc-opt="-I/build/boringssl/include" \
        --with-ld-opt="$(cat /build/ssl-ldflags)" \
        || { cat objs/autoconf.err >&2; exit 1; } \
    && make -j"$(nproc)"

# Guard 3: binary names BoringSSL, no dynamic libssl/libcrypto.
RUN /build/angie/objs/angie -V 2>&1 | grep -qi boringssl \
    && ! ldd /build/angie/objs/angie | grep -qE 'libssl|libcrypto'

# ECH key (spike resolved). ssl_encrypted_hello_key expects one PEM file:
# PKCS#8 PrivateKey followed by an ECHCONFIG block holding the base64
# ECHConfigList (draft-farrell-tls-pemesni; angie strips the list's 2-byte
# length prefix itself). bssl generate-ech emits a raw 32-byte X25519 key,
# so wrap it in the fixed RFC 8410 PKCS#8 DER prefix (printf octal:
# 30 2e 02 01 00 30 05 06 03 2b 65 6e 04 22 04 20). ech.list is kept for
# test clients (-ech-config-list). openssl pkey validates the key wrap;
# the runtime-stage `angie -t` validates the whole file.
RUN /build/boringssl/build/bssl generate-ech \
        -out-ech-config-list /build/certs/ech.list \
        -out-ech-config /build/certs/ech.config \
        -out-private-key /build/certs/ech.priv \
        -public-name public.testbed.local \
        -config-id 0 \
    && { printf '\060\056\002\001\000\060\005\006\003\053\145\156\004\042\004\040'; \
         cat /build/certs/ech.priv; } > /build/certs/ech.p8 \
    && { echo '-----BEGIN PRIVATE KEY-----'; \
         openssl base64 -in /build/certs/ech.p8; \
         echo '-----END PRIVATE KEY-----'; \
         echo '-----BEGIN ECHCONFIG-----'; \
         openssl base64 -in /build/certs/ech.list; \
         echo '-----END ECHCONFIG-----'; } > /build/certs/ech.key \
    && openssl pkey -in /build/certs/ech.key -noout \
    && rm /build/certs/ech.p8 /build/certs/ech.priv


FROM base AS build-openssl
# OpenSSL 4.0+ ships ECH (RFC 9849) and the QUIC TLS API angie's
# NGX_QUIC_OPENSSL_API path uses (>= 3.5). SSL_COMMIT = OpenSSL tag,
# e.g. "openssl-4.0.1".
# OpenSSL's Configure is perl and needs more than bookworm's perl-base
# (FindBin et al). perl does not pull libssl-dev; guard 1 re-checked anyway.
RUN apt-get update && apt-get install -y --no-install-recommends perl \
    && rm -rf /var/lib/apt/lists/* \
    && if dpkg -s libssl-dev >/dev/null 2>&1; then \
        echo 'guard 1 FAILED: libssl-dev pulled in by build deps' >&2; exit 1; fi

ARG SSL_COMMIT
RUN test -n "$SSL_COMMIT" || { echo 'SSL_COMMIT build arg required' >&2; exit 1; }
# sha256 of ${SSL_COMMIT}.tar.gz, keyed to openssl-4.0.1 — matches the
# .sha256 published with the release (GitHub tag names pin intent, not
# content; release assets are re-uploadable). Update together with the tag.
ARG OPENSSL_SHA256=2db3f3a0d6ea4b59e1f094ace2c8cd536dffb87cdc39084c5afa1e6f7f37dd09
RUN curl -fsSL -o openssl.tar.gz \
        "https://github.com/openssl/openssl/releases/download/${SSL_COMMIT}/${SSL_COMMIT}.tar.gz" \
    && echo "${OPENSSL_SHA256}  openssl.tar.gz" | sha256sum -c - \
    && mkdir /build/openssl \
    && tar xzf openssl.tar.gz -C /build/openssl --strip-components=1 \
    && rm openssl.tar.gz

# Native --with-openssl: angie builds it in-tree during make — no
# header-shadow trick, no silent-fallback class. ECH ships in 4.0 as a
# default feature; enable-ech is a valid Configure flag and pins the intent
# (a no-ech build would then hard-fail).
RUN cd /build/angie && ./configure \
        --prefix=/usr/local/angie \
        --sbin-path=/usr/sbin/angie \
        --conf-path=/etc/angie/angie.conf \
        --pid-path=/run/angie.pid \
        --error-log-path=/dev/stderr \
        --http-log-path=/dev/stdout \
        --with-http_ssl_module \
        --with-http_v3_module \
        --with-openssl=/build/openssl \
        --with-openssl-opt="enable-ech" \
    && make -j"$(nproc)"

# Guard 3 (adapted): -V must name the pinned OpenSSL version; ldd unchanged.
RUN /build/angie/objs/angie -V 2>&1 | grep -qF "${SSL_COMMIT#openssl-}" \
    && ! ldd /build/angie/objs/angie | grep -qE 'libssl|libcrypto'

# ECH key: `openssl ech` (4.0+) emits exactly the PEM format angie expects
# (PKCS#8 key + ECHConfigList, RFC 9934) — no wrapping needed, unlike the
# BoringSSL branch. Use the in-tree binary: the system openssl (3.0) has no
# ech command. ech.list (binary ECHConfigList) is extracted for test
# clients; the runtime-stage `angie -t` validates ech.key.
RUN /build/openssl/.openssl/bin/openssl ech \
        -public_name public.testbed.local \
        -out /build/certs/ech.key \
    && sed -n '/BEGIN ECHCONFIG/,/END ECHCONFIG/p' /build/certs/ech.key \
        | grep -v ECHCONFIG | openssl base64 -d > /build/certs/ech.list \
    && [ -s /build/certs/ech.list ]


FROM build-${SSL_IMPL} AS build


FROM debian:bookworm-slim@sha256:60eac759739651111db372c07be67863818726f754804b8707c90979bda511df AS runtime
# SSL is static; only pcre2 + zlib are dynamic.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libpcre2-8-0 zlib1g \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /usr/local/angie /etc/angie/certs

COPY --from=build /build/angie/objs/angie /usr/sbin/angie
COPY --from=build /build/certs/ /etc/angie/certs/
COPY conf/angie.conf /etc/angie/angie.conf

RUN /usr/sbin/angie -t

# Stamping is mandatory: HEAD builds are not reproducible; the label is the
# only record of what is in the binary.
ARG SSL_IMPL
ARG SSL_COMMIT
ARG ANGIE_VERSION
LABEL org.angie-build.ssl-impl="${SSL_IMPL}" \
      org.angie-build.ssl-commit="${SSL_COMMIT}" \
      org.angie-build.angie-version="${ANGIE_VERSION}"

EXPOSE 8443/tcp 8443/udp
CMD ["/usr/sbin/angie", "-g", "daemon off;"]
