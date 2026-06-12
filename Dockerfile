# Subnetra runtime / deployment image.
#
# This is the SHIPPING image, distinct from .devcontainer/Dockerfile (which is a
# fat dev/test box). The product contract is unchanged: a single static musl
# binary with zero third-party dependencies. The final stage layers our two
# binaries onto $RUNTIME_BASE (default `busybox:musl`), which adds a tiny shell +
# core utilities for in-container debugging. The daemon itself needs nothing from
# the base — it is fully static.
#
# musl is mandatory. busybox:musl publishes amd64, arm64 and arm/v7 but NOT
# arm/v5, so arm/v5 is built INDEPENDENTLY with RUNTIME_BASE=scratch (a musl-pure
# image with no shell) and stitched into the same manifest by release.yml. Do not
# point RUNTIME_BASE at a glibc/uclibc busybox just to get an arm/v5 shell — that
# would break the "static musl, no third-party libc" contract.
#
# Multi-arch is produced WITHOUT qemu: the build stage is pinned to the native
# BUILDPLATFORM and Zig cross-compiles to the requested TARGETARCH. The final
# stage only copies files onto the matching-arch base layer, so it needs no
# emulation either.
#
# Runtime requirements (the binary is an L3 tunnel daemon):
#   docker run --rm \
#     --cap-add=NET_ADMIN --device=/dev/net/tun \
#     -v "$PWD/config.json:/etc/subnetra/config.json:ro" \
#     ghcr.io/jamiesun/subnetra:latest

# Runtime base for the final stage. Overridable so arm/v5 (which busybox:musl
# does not publish) can build independently with RUNTIME_BASE=scratch.
ARG RUNTIME_BASE=busybox:1.37.0-musl

# --- build stage: cross-compile the static binaries with Zig -----------------
FROM --platform=$BUILDPLATFORM debian:stable-slim AS build

ARG ZIG_VERSION=0.16.0
# Pinned upstream SHA256 sums (from https://ziglang.org/download/index.json).
ARG ZIG_SHA256_X86_64=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
ARG ZIG_SHA256_AARCH64=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17
# Provided automatically by BuildKit.
ARG BUILDARCH
ARG TARGETARCH
ARG TARGETVARIANT

RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils; \
    rm -rf /var/lib/apt/lists/*

# Install the Zig toolchain for the BUILD host arch (no emulation).
RUN set -eux; \
    case "${BUILDARCH}" in \
        amd64) ZIG_ARCH=x86_64;  ZIG_SHA="${ZIG_SHA256_X86_64}" ;; \
        arm64) ZIG_ARCH=aarch64; ZIG_SHA="${ZIG_SHA256_AARCH64}" ;; \
        *) echo "unsupported BUILDARCH=${BUILDARCH}" >&2; exit 1 ;; \
    esac; \
    url="https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz"; \
    curl -fsSL "$url" -o /tmp/zig.tar.xz; \
    echo "${ZIG_SHA}  /tmp/zig.tar.xz" | sha256sum -c -; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm /tmp/zig.tar.xz; \
    ln -s /opt/zig/zig /usr/local/bin/zig; \
    zig version

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src
COPY tests ./tests
COPY config.example.json ./

# Map the Docker TARGETARCH/TARGETVARIANT to a Zig musl triple + CPU model and
# cross-compile ReleaseSmall. Static-ness and the 512KB size budget are enforced
# by the CI integration suite (test/integration/run.sh); here we just produce the
# artifacts.
#   linux/amd64   -> x86_64-linux-musl
#   linux/arm64   -> aarch64-linux-musl
#   linux/arm/v7  -> arm-linux-musleabihf  -Dcpu=generic+v7a (hard float)
#   linux/arm/v5  -> arm-linux-musleabi    -Dcpu=arm926ej_s  (soft float, ARMv5TE)
# Genuine ARMv5 has no hardware atomics; src/atomic_shim.zig supplies the
# single-threaded __sync_* builtins (safe under iron law #3) so the v5 image runs
# on real ARMv5TE hardware, not just v6+.
RUN set -eux; \
    case "${TARGETARCH}/${TARGETVARIANT}" in \
        amd64/*)   ZIG_TARGET=x86_64-linux-musl;    ZIG_CPU= ;; \
        arm64/*)   ZIG_TARGET=aarch64-linux-musl;   ZIG_CPU= ;; \
        arm/v7)    ZIG_TARGET=arm-linux-musleabihf; ZIG_CPU="-Dcpu=generic+v7a" ;; \
        arm/v5)    ZIG_TARGET=arm-linux-musleabi;   ZIG_CPU="-Dcpu=arm926ej_s" ;; \
        *) echo "unsupported TARGETARCH=${TARGETARCH} TARGETVARIANT=${TARGETVARIANT}" >&2; exit 1 ;; \
    esac; \
    zig build -Dtarget="${ZIG_TARGET}" ${ZIG_CPU} -Doptimize=ReleaseSmall

# --- final stage: runtime base + the static binaries -------------------------
# $RUNTIME_BASE defaults to busybox:1.37.0-musl (shell + core utils on
# amd64/arm64/arm/v7); release.yml overrides it to `scratch` for the independent
# arm/v5 build. Either base is tiny and the daemon stays fully static.
FROM ${RUNTIME_BASE}

COPY --from=build /src/zig-out/bin/subnetrad /usr/local/bin/subnetrad
COPY --from=build /src/zig-out/bin/subnetra /usr/local/bin/subnetra
COPY --from=build /src/config.example.json /etc/subnetra/config.example.json

# The daemon reads ./config.json from its working directory; mount the real
# config at /etc/subnetra/config.json. Neither busybox:musl nor scratch ships a
# /run, so create /run/subnetra (via WORKDIR's implicit mkdir -p) for the default
# Linux control socket /run/subnetra/subnetra.sock, then settle the working dir
# at /etc/subnetra. (The daemon also best-effort-creates this dir on bind, but
# its parent /run must already exist.)
WORKDIR /run/subnetra
WORKDIR /etc/subnetra

# Liveness for orchestrators (docker/compose/k8s): `subnetra status` exits non-zero
# when the control socket is absent or the daemon is unresponsive. Exec form +
# absolute path so it works on both busybox:musl and the shell-less scratch base.
# It honors SUBNETRA_SOCK from the container environment.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["/usr/local/bin/subnetra", "status"]

ENTRYPOINT ["/usr/local/bin/subnetrad"]
