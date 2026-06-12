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
plan to you). If Subnetra is already present in the target directory, it shows
the installed version and asks before overwriting. For an unattended run, accept
the defaults with `--yes`:

```bash
curl -fsSL https://raw.githubusercontent.com/jamiesun/subnetra/main/install.sh | sh -s -- --yes
```

| Flag | Meaning |
|---|---|
| `--dir <path>` | Install location (default `/usr/local/bin`). |
| `--version <vX.Y.Z>` | Pin a specific release instead of the latest. |
| `--service` | Also install the (disabled) systemd/launchd service unit. |
| `--yes` | Skip every prompt (non-interactive). |

To run Subnetra as a managed service, add `--service`: it installs the hardened
`systemd` (Linux) or `launchd` (macOS) unit **disabled** — it never starts it and
never touches your network — then prints the steps to finish and enable it. See
[Deployment](../operations/deployment.md) for the full service setup.

Prefer to install by hand, or on a platform the script does not cover? Use the
[release tarballs](#release-binaries) below, or browse every asset on the
**[Releases page](https://github.com/jamiesun/subnetra/releases/latest)**.

| Method | Best for | Notes |
|---|---|---|
| [Install script](#quick-install-interactive) | One-line Linux / macOS install | Resolves latest, verifies checksums, interactive |
| [Container image](#container-image) | Linux hosts, RouterOS / BusyBox containers | Multi-arch `amd64 / arm64 / armv7 / armv5` |
| [Release tarball](#release-binaries) | Bare Linux hosts, offline installs | `docker load`-able image tarballs also provided |
| [macOS spoke binary](#macos-spoke-binary) | Apple Silicon / Intel Macs (spoke only) | Runbook-certified, not CI-gated |
| [OpenWrt router](../operations/openwrt.md) | MIPS / ARM home & SOHO routers (spoke) | Static musl binary + procd service |
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
`armv7`, `armv5`, `mipsel`, and `mips`. The Linux binaries are fully static
against musl-libc — `ldd` reports `not a dynamic executable`.

> **MIPS / OpenWrt:** `mipsel` is little-endian (ramips/mt7621/mt7628, most
> modern OpenWrt devices) and `mips` is big-endian (ath79/Atheros). See the
> [OpenWrt Spoke](../operations/openwrt.md) guide for picking the right one and
> the procd service.

Asset names carry the version, so resolve it once, then download, verify, and
install:

```bash
ARCH=amd64   # one of: amd64 | arm64 | armv7 | armv5 | mipsel | mips
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
docker load < subnetra-image-<version>-arm64.tar.gz   # -> ghcr.io/jamiesun/subnetra:<version>
docker run -d --name subnetra \
    --cap-add=NET_ADMIN --device=/dev/net/tun \
    -v "$PWD/config.json":/etc/subnetra/config.json:ro \
    ghcr.io/jamiesun/subnetra:<version>
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
zig build -Dtarget=mipsel-linux-musl     # mipsel (LE: ramips/mt7621 — OpenWrt)
zig build -Dtarget=mips-linux-musl       # mips (BE: ath79/Atheros — OpenWrt)

# Run tests
zig build test

# Run the daemon
zig build run
```

Artifacts are placed in `zig-out/bin/`: `subnetrad` (daemon) and `subnetra`
(control tool).

### Tuning the peer cap

The peer registry and parsed config are fixed-capacity, zero-allocation arrays,
so the maximum number of mesh peers a node can hold is a **compile-time** build
option (`-Dmax-peers`) — not a runtime config field. It defaults to **16** and
is capped at **128**:

```bash
zig build -Dmax-peers=64                       # raise the local peer cap to 64
zig build -Dmax-peers=128 -Dtarget=aarch64-linux-musl   # combine with a target
```

A `hub` manages at most this many spokes. This is a **per-node** sizing knob —
it is never negotiated on the wire, so a spoke that only talks to one hub can
keep the default 16 even when the hub is built with a larger cap. The
control-plane policy-table size (`MAX_POLICY_ENTRIES`) is **derived** from this
value, so raising the cap grows the policy capacity automatically; the default
of 16 reproduces the historical 256-entry table exactly.

Raising it much higher trades memory and latency for capacity: the reactor is a
single-threaded, per-packet `O(N)` scan over peers (and, with `obfuscate` on, a
trial de-obfuscation per inbound datagram), so very large meshes are better
served by **splitting into several hubs** than by one hub with hundreds of
spokes.

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
