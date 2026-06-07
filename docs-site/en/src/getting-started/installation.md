# Installation

Subnetra ships as a **single static binary**. There is nothing to install
system-wide and no shared libraries to manage — pick whichever delivery method
fits your environment.

## Quick install (interactive)

On **Linux or macOS**, the fastest path is the install script. It detects your
OS and architecture, resolves the **latest** release, verifies the download
against the release `SHA256SUMS.txt`, and installs both `subnetra` and
`subnetrad` — pausing for you to confirm before it writes anything:

```bash
curl -fsSL https://raw.githubusercontent.com/jamiesun/subnetra/main/install.sh | sh
```

The script is interactive and **only installs the two binaries** — it never
touches your network, firewall, or services (Subnetra always leaves the host
plan to you). For an unattended run, accept the defaults with `--yes`:

```bash
curl -fsSL https://raw.githubusercontent.com/jamiesun/subnetra/main/install.sh | sh -s -- --yes
```

| Flag | Meaning |
|---|---|
| `--dir <path>` | Install location (default `/usr/local/bin`). |
| `--version <vX.Y.Z>` | Pin a specific release instead of the latest. |
| `--yes` | Skip every prompt (non-interactive). |

Prefer to install by hand, or on a platform the script does not cover? Use the
[release tarballs](#release-binaries) below, or browse every asset on the
**[Releases page](https://github.com/jamiesun/subnetra/releases/latest)**.

| Method | Best for | Notes |
|---|---|---|
| [Install script](#quick-install-interactive) | One-line Linux / macOS install | Resolves latest, verifies checksums, interactive |
| [Container image](#container-image) | Linux hosts, RouterOS / BusyBox containers | Multi-arch `amd64 / arm64 / armv7 / armv5` |
| [Release tarball](#release-binaries) | Bare Linux hosts, offline installs | `docker load`-able image tarballs also provided |
| [macOS spoke binary](#macos-spoke-binary) | Apple Silicon / Intel Macs (spoke only) | Runbook-certified, not CI-gated |
| [Build from source](#build-from-source) | Development, custom targets | Requires Zig 0.16.0+ |

The daemon needs two things at runtime regardless of method: the **`NET_ADMIN`**
capability (to create the TUN device) and access to **`/dev/net/tun`**.

## Container image

Tagged releases publish a multi-arch image to GHCR. Docker automatically selects
the right architecture:

```bash
docker pull ghcr.io/jamiesun/subnetra:latest

# The daemon needs NET_ADMIN + the TUN device, and a config.json mounted into
# its working directory (/etc/subnetra).
docker run -d --name subnetra \
    --cap-add=NET_ADMIN --device=/dev/net/tun \
    -v "$PWD/config.json":/etc/subnetra/config.json:ro \
    ghcr.io/jamiesun/subnetra:latest
```

The image ships a Docker `HEALTHCHECK` (`subnetra status`), so `docker ps` /
Compose / Kubernetes report the daemon `healthy` once it is serving its control
socket and `unhealthy` if it stops responding.

The `amd64`, `arm64` and `arm/v7` images are built `FROM busybox:musl` (they carry
the two static binaries, `config.example.json`, and a tiny BusyBox shell for
in-container debugging). The `arm/v5` image is built `FROM scratch` (still static
musl, no debug shell) and stitched into the same `:latest` / `:version` manifest.
See [Containers](../operations/containers.md) for Compose and Kubernetes details.

## Release binaries

Browse and download any release from the
**[Releases page](https://github.com/jamiesun/subnetra/releases/latest)**. Each
release (`vX.Y.Z`) attaches **static binary tarballs** for `amd64`, `arm64`,
`armv7`, and `armv5`. The Linux binaries are fully static against musl-libc —
`ldd` reports `not a dynamic executable`.

Asset names carry the version, so resolve it once, then download, verify, and
install:

```bash
ARCH=amd64   # one of: amd64 | arm64 | armv7 | armv5
VER=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
        https://github.com/jamiesun/subnetra/releases/latest | sed 's#.*/tag/##')

curl -fsSLO "https://github.com/jamiesun/subnetra/releases/download/$VER/subnetra-$VER-linux-$ARCH.tar.gz"
curl -fsSLO "https://github.com/jamiesun/subnetra/releases/download/$VER/SHA256SUMS.txt"
sha256sum --ignore-missing -c SHA256SUMS.txt        # verify before installing

tar -xzf "subnetra-$VER-linux-$ARCH.tar.gz"
cd "subnetra-$VER-linux-$ARCH"
sudo install -m 0755 subnetrad subnetra /usr/local/bin/
subnetrad --version
```

> The `releases/latest/download/<asset>` path always points at the current
> release, but asset names embed the version — so resolve `VER` as above, or just
> use the [install script](#quick-install-interactive).

### Offline / air-gapped install

Devices that cannot reach a container registry can use the per-arch
`docker load`-able image tarballs attached to each release
(`subnetra-image-<version>-<arch>.tar.gz`):

```bash
docker load < subnetra-image-v0.1.0-arm64.tar.gz   # -> ghcr.io/jamiesun/subnetra:v0.1.0
docker run -d --name subnetra \
    --cap-add=NET_ADMIN --device=/dev/net/tun \
    -v "$PWD/config.json":/etc/subnetra/config.json:ro \
    ghcr.io/jamiesun/subnetra:v0.1.0
```

## macOS spoke binary

Each release also attaches native macOS binaries for running Subnetra as a
**spoke** — `subnetra-<version>-macos-arm64.tar.gz` (Apple Silicon) and
`-amd64.tar.gz` (Intel). They are Mach-O binaries that link **only `libSystem`**
(zero third-party deps).

> The [install script](#quick-install-interactive) works on macOS too and clears
> the Gatekeeper quarantine attribute for you.

```bash
tar -xzf subnetra-<version>-macos-arm64.tar.gz
cd subnetra-<version>-macos-arm64
# Gatekeeper quarantines downloaded binaries — clear it (or build from source):
xattr -d com.apple.quarantine subnetrad subnetra 2>/dev/null || true

./subnetra --print-network-plan --config config.json   # preview the host plan
sudo ./subnetrad --config config.json                  # utun creation needs root
```

Creating the `utun` interface and applying the `ifconfig` / `route` plan both
require root. macOS is supported as a **spoke** only (the hub stays
Linux/RouterOS); see the [macOS Spoke](../operations/macos-spoke.md) guide.

## Build from source

Requires **Zig 0.16.0** or later.

```bash
# Native build (defaults to ReleaseSmall; pass -Doptimize=Debug for dev builds)
zig build

# Static cross-compile
zig build -Dtarget=x86_64-linux-musl     # amd64
zig build -Dtarget=aarch64-linux-musl    # arm64
zig build -Dtarget=arm-linux-musleabihf  # armv7 (hard float)
zig build -Dtarget=arm-linux-musleabi    # armv5 (soft float)

# Run tests
zig build test

# Run the daemon
zig build run
```

Artifacts are placed in `zig-out/bin/`: `subnetrad` (daemon) and `subnetra`
(control tool).

> **ARMv5 note:** ARMv5 has no hardware atomics, so the standard library's
> threaded I/O scaffolding references legacy `__sync_*` intrinsics that musl does
> not provide. Because Subnetra is strictly single-threaded,
> `src/atomic_shim.zig` supplies a provably-correct plain (non-atomic)
> implementation, gated at comptime and compiled in **only** for pre-ARMv6
> targets — every other architecture is byte-for-byte unaffected.

## Verify the install

```bash
# Linux: confirm the binary is fully static
ldd ./subnetrad          # -> "not a dynamic executable"
ls -lh ./subnetrad       # -> < 512 KB

# Any platform: print the version banner
./subnetrad --version
```

Next: head to the **[Quick Start](quickstart.md)** to bring up a hub and a spoke.
