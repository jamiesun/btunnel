# BTunnel development & local integration-test container.
#
# This image exists for ONE reason: give a reproducible Linux environment where
# BTunnel's syscall-heavy code (TUN device, epoll reactor, AF_UNIX control
# socket) can actually be built and exercised — something a macOS/Windows host
# cannot do natively. It is NOT a product dependency; the shipped artifact stays
# a single static musl binary with zero third-party dependencies.
#
# Debian-slim is chosen over Alpine on purpose: standard iproute2 / netns / ELF
# tooling behaves like a conventional Linux box, which keeps integration-test
# debugging signal high. (BusyBox/RouterOS compatibility is a separate deploy
# concern, not a dev-loop concern.)
FROM debian:stable-slim

ARG ZIG_VERSION=0.16.0
# Pinned upstream SHA256 sums (from https://ziglang.org/download/index.json).
ARG ZIG_SHA256_X86_64=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
ARG ZIG_SHA256_AARCH64=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17
# Provided automatically by BuildKit (amd64 / arm64).
ARG TARGETARCH

RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils \
        iproute2 iputils-ping tcpdump \
        binutils file \
        git; \
    rm -rf /var/lib/apt/lists/*

# Install the matching Zig 0.16.0 toolchain for the build platform so the
# integration test runs on its NATIVE architecture (no qemu-user emulation).
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) ZIG_ARCH=x86_64; ZIG_SHA="${ZIG_SHA256_X86_64}" ;; \
        arm64) ZIG_ARCH=aarch64; ZIG_SHA="${ZIG_SHA256_AARCH64}" ;; \
        *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    url="https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz"; \
    curl -fsSL "$url" -o /tmp/zig.tar.xz; \
    echo "${ZIG_SHA}  /tmp/zig.tar.xz" | sha256sum -c -; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm /tmp/zig.tar.xz; \
    ln -s /opt/zig/zig /usr/local/bin/zig; \
    zig version

WORKDIR /workspace
