# BTunnel runtime / deployment image.
#
# This is the SHIPPING image, distinct from .devcontainer/Dockerfile (which is a
# fat dev/test box). The product contract is unchanged: a single static musl
# binary with zero third-party dependencies. So the final stage is `scratch` and
# contains nothing but the two binaries — no shell, no libc, no package manager.
#
# Multi-arch is produced WITHOUT qemu: the build stage is pinned to the native
# BUILDPLATFORM and Zig cross-compiles to the requested TARGETARCH. The final
# `scratch` stage only copies files, so it needs no emulation either.
#
# Runtime requirements (the binary is an L3 tunnel daemon):
#   docker run --rm \
#     --cap-add=NET_ADMIN --device=/dev/net/tun \
#     -v "$PWD/config.json:/etc/btunnel/config.json:ro" \
#     ghcr.io/jamiesun/btunnel:latest

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

# --- final stage: nothing but the static binaries ----------------------------
FROM scratch

COPY --from=build /src/zig-out/bin/btunnel /usr/local/bin/btunnel
COPY --from=build /src/zig-out/bin/ptctl /usr/local/bin/ptctl
COPY --from=build /src/config.example.json /etc/btunnel/config.example.json

# The daemon reads ./config.json from its working directory; mount the real
# config at /etc/btunnel/config.json.
WORKDIR /etc/btunnel

ENTRYPOINT ["/usr/local/bin/btunnel"]
