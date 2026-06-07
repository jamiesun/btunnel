# Subnetra

**A pure-Zig, zero-dependency Layer-3 UDP tunnel that ships as a single static binary under 512KB.**

[![CI](https://github.com/jamiesun/subnetra/actions/workflows/ci.yml/badge.svg)](https://github.com/jamiesun/subnetra/actions/workflows/ci.yml)
[![Release](https://github.com/jamiesun/subnetra/actions/workflows/release.yml/badge.svg)](https://github.com/jamiesun/subnetra/actions/workflows/release.yml)
[![Latest release](https://img.shields.io/github/v/release/jamiesun/subnetra?sort=semver)](https://github.com/jamiesun/subnetra/releases/latest)
[![License: MIT](https://img.shields.io/github/license/jamiesun/subnetra)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.16.0-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/)
![Binary size](https://img.shields.io/badge/binary-%E2%89%A4512KB-44cc11)
[![Arch](https://img.shields.io/badge/arch-amd64%20%7C%20arm64%20%7C%20armv7%20%7C%20armv5-2b90d9)](https://github.com/jamiesun/subnetra/releases/latest)

**English** · [简体中文](README.zh-CN.md)

<p align="center">
  <img src="subnetra.png" alt="Subnetra — Layer-3 UDP tunnel, pure Zig, static binary: TUN ingress, encrypt &amp; seal, star relay, policy routing, spoke egress" width="100%">
</p>

> A virtual Layer-3 adaptive networking tool written in **pure Zig** (pinned to the
> 2026 latest standard library `std.posix`).
> Targets general Linux environments (including lightweight containers such as
> BusyBox / RouterOS Container), and runs natively on **macOS as a spoke**
> (`utun` + `poll(2)`): zero dependencies, zero dynamic allocation, strong stealth.

Subnetra builds a virtual subnet on top of a physical leased line, using a
**hub-and-spoke topology** and forwarding raw IP packets through a private UDP
tunnel. It does **not depend on any third-party network framework**:
the TUN device, encryption, anti-replay, and policy engine are all in-house,
producing a single, fully statically linked binary.

## ✨ Features

- **Zero-dependency single binary**: fully static linking against musl-libc; `ldd`
  reports `not a dynamic executable`; size ≤ 512KB.
- **Layered zero dynamic allocation**: the data plane (reactor / crypto) is strictly
  allocation-free, with buffers locked into resident memory at startup.
- **Single-threaded event-driven reactor**: Linux `epoll` edge-triggered
  (`EPOLLET`) or macOS `poll(2)`, selected at comptime; lock-free, with no
  concurrency contention.
- **Stateless obfuscation**: ChaCha20-Poly1305 full encryption; ciphertext has no
  fixed magic number; authentication failures are silently dropped — physically
  invisible to probing.
- **Transport security**: private per-peer pre-shared keys (one secret per hub
  link, never mesh-wide) + per-link directional keys +
  per-restart session epoch (fresh key each daemon lifetime) + 64-bit monotonic
  nonce (never reused) + per-session sliding-window anti-replay.
- **Lock-free RCU hot updates**: the policy tree is replaced wholesale via an atomic
  pointer swap; hot updates are zero-copy and jitter-free.
- **Multi-subnet policy engine**: CIDR longest-prefix matching, with Site-to-Site
  routing support.

## 📦 Project layout

```
build.zig            Dual-binary build (subnetra daemon + subnetra control tool), static musl cross-compile
build.zig.zon        Package manifest
config.example.json  Example config (copy to config.json to use)
deploy/              systemd unit + example hub/spoke configs (see docs/deployment.md)
src/
  root.zig     Core library, aggregates all modules
  config.zig   Config parsing + sanity check (MTU range / subnet overlap)
  policy.zig   CIDR parsing + longest-prefix match + lock-free RCU ActiveTree
  crypto.zig   ChaCha20-Poly1305 + monotonic nonce + sliding-window anti-replay
  reactor.zig  Packed private wire header + egress dispatch + readiness reactor
  os/          Comptime OS backend: linux.zig (epoll + /dev/net/tun), darwin.zig (poll(2) + utun), mod.zig (selector)
  sys.zig      Portable syscall shim (std.posix wrappers shared by both backends)
  peer.zig     Per-peer endpoint + crypto registry (keys, counters, anti-replay windows)
  netplan.zig  --print-network-plan host command emitter (Linux ip / macOS ifconfig+route)
  stats.zig    data-plane counters (rx/tx, per-reason drops) for `subnetra status`
  uds.zig      Control-plane Unix domain socket + command tokenizer
  main.zig     subnetra daemon entry point
  subnetra.zig    subnetra control tool entry point
tools/               Out-of-tree helper utilities, never shipped in the daemon (see tools/README.md)
  keygen.zig         Generate per-link 64-hex PSKs (zig build tool:keygen)
  config-lint.zig    Offline config.json validation, clock-independent (zig build tool:config-lint)
  wire-decode.zig    Offline read-only datagram inspector (zig build tool:wire-decode)
  doctor.sh          Environment preflight: /dev/net/tun, CAP_NET_ADMIN, ip, clock
docs/
  subnetra-develop.md  System requirements & architecture design (PRD & Architecture)
  PROTOCOL.md         Normative wire-protocol spec (v1) — the cross-impl interoperability contract
  deployment.md       Hub + two-spoke production deployment walkthrough (systemd, secrets, upgrade)
  macos-spoke-acceptance.md  Manual real-machine runbook certifying a macOS utun spoke
  routeros-container.md RouterOS Container deployment guide (veth, routes, LAN publishing)
```

## 🛠 Build

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

Artifacts are placed in `zig-out/bin/`: `subnetra` (daemon) and `subnetra` (control tool).

> **ARMv5 note:** ARMv5 has no hardware atomics (no `LDREX`/`STREX`), so the
> standard library's threaded I/O scaffolding references legacy `__sync_*`
> intrinsics that musl does not provide. Because Subnetra is strictly
> single-threaded (iron law #3), [`src/atomic_shim.zig`](src/atomic_shim.zig)
> supplies a provably-correct plain (non-atomic) implementation of those
> builtins. The shim is gated at comptime and only compiled in for pre-ARMv6
> targets — every other architecture is byte-for-byte unaffected.

## 📦 Container images & releases

Tagged releases (`vX.Y.Z`) are produced by
[`.github/workflows/release.yml`](.github/workflows/release.yml) and ship Linux
**static binary tarballs** and a **multi-arch container image** — each covering
`amd64`, `arm64`, `armv7`, and `armv5` — plus native **macOS spoke binaries**
(`arm64`, `amd64`; see [below](#macos-spoke-binary)).

```bash
# Pull the multi-arch image (Docker selects the right arch automatically)
docker pull ghcr.io/jamiesun/subnetra:latest

# Run the daemon: it needs NET_ADMIN + the TUN device, and a config.json
# mounted into its working directory (/etc/subnetra).
docker run -d --name subnetra \
    --cap-add=NET_ADMIN --device=/dev/net/tun \
    -v "$PWD/config.json":/etc/subnetra/config.json:ro \
    ghcr.io/jamiesun/subnetra:latest
```

The image ships a Docker `HEALTHCHECK` (`subnetra status`), so `docker ps` /
Compose / Kubernetes report the daemon `healthy` once it is serving its control
socket and `unhealthy` if it stops responding.

The image is built `FROM busybox:musl` for amd64, arm64 and arm/v7: it carries the
two static binaries plus `config.example.json` and a tiny BusyBox shell + core
utilities for in-container debugging. The daemon itself is fully static and needs
nothing from the base. Because no musl BusyBox publishes `linux/arm/v5`, the arm/v5
image is built independently `FROM scratch` (still static musl, but without a debug
shell) and stitched into the same `:latest`/`:version` manifest. The build stage
cross-compiles with Zig pinned to `$BUILDPLATFORM`, so no QEMU emulation is needed.
See [`Dockerfile`](Dockerfile) for the runtime image and
[`.devcontainer/Dockerfile`](.devcontainer/Dockerfile) for the dev/test toolchain.

### Offline / air-gapped install

Devices that cannot reach a container registry can use the per-arch
`docker load`-able image tarballs attached to each GitHub Release
(`subnetra-image-<version>-<arch>.tar.gz`):

```bash
# Copy the tarball for the target arch to the device, then:
docker load < subnetra-image-v0.1.0-arm64.tar.gz   # -> ghcr.io/jamiesun/subnetra:v0.1.0
docker run -d --name subnetra \
    --cap-add=NET_ADMIN --device=/dev/net/tun \
    -v "$PWD/config.json":/etc/subnetra/config.json:ro \
    ghcr.io/jamiesun/subnetra:v0.1.0
```

Verify any asset against the release's `SHA256SUMS.txt` before loading.

### macOS spoke binary

Each release also attaches native macOS binaries for running subnetra as a
**spoke** — `subnetra-<version>-macos-<arch>.tar.gz` for `arm64` (Apple Silicon)
and `amd64` (Intel). They are Mach-O binaries that link **only `libSystem`** (zero
third-party deps); per iron law #6 they are *minimal-dynamic* rather than fully
static, so the Linux ≤ 512 KB size gate does not apply and they are produced
without the Linux `ldd`-static check. Zig cross-compiles them on the Linux release
runner, so no Apple toolchain is involved.

```bash
tar -xzf subnetra-<version>-macos-arm64.tar.gz
cd subnetra-<version>-macos-arm64
# Gatekeeper quarantines downloaded binaries — clear it (or build from source):
xattr -d com.apple.quarantine subnetrad subnetra 2>/dev/null || true
./subnetra --print-network-plan --config config.json   # preview the host plan
sudo ./subnetrad --config config.json                  # utun creation needs root
```

Creating the `utun` interface and applying the `ifconfig`/`route` plan both
require root. macOS is supported as a **spoke** only (the hub stays
Linux/RouterOS), and these binaries are **runbook-certified**, not CI-gated —
follow [`docs/macos-spoke-acceptance.md`](docs/macos-spoke-acceptance.md) to
qualify a host.

### Cutting a release

The version is single-sourced in [`build.zig.zon`](build.zig.zon) (`.version`)
and injected into the daemon banner at build time. To publish `vX.Y.Z`: bump
`.version` to `X.Y.Z`, merge to `main`, then push a matching `vX.Y.Z` tag. The
release workflow refuses to publish if the tag and `build.zig.zon` disagree.

## 🧪 Local integration testing (dev container)

The privileged **integration harness** (a hub-and-spoke relay across network
namespaces) is Linux-only, so a reproducible Linux container is provided under
[`.devcontainer/`](.devcontainer/). It is a **development/test aid only**. The
data path also runs natively on **macOS as a spoke** — `utun` + `poll(2)`,
comptime-selected behind [`src/os/`](src/os/) — certified by the manual
[`docs/macos-spoke-acceptance.md`](docs/macos-spoke-acceptance.md) runbook; the
Linux static musl binary remains the CI- and release-gated production artifact.

Open the folder in any dev-container-aware editor, or run the preflight harness
headless:

```bash
# Build the Linux toolchain image (Debian-slim + pinned Zig 0.16.0)
docker build -t subnetra-dev -f .devcontainer/Dockerfile .

# Run the integration / preflight harness inside it
docker run --rm --privileged --device=/dev/net/tun \
    -v "$PWD":/workspace subnetra-dev test/integration/run.sh
```

[`test/integration/run.sh`](test/integration/run.sh) builds the binary on the
container's native arch, enforces the static-link and ≤ 512 KB constraints,
smoke-runs the daemon (`subnetrad --check`), cross-builds the other musl arch,
runs the unit tests, and then runs the **multi-point + relay end-to-end test**:
a 3-node hub-and-spoke star across network namespaces (one Hub relay + two
Spokes). It asserts end-to-end delivery spoke-A → Hub(relay) → spoke-B, on-wire
encryption (no plaintext marker leaks onto the underlay), a non-stalling RCU
policy hot-update under load, honest drop-counter observability, resilience under
underlay packet loss (netem) with full recovery, and endpoint roaming / NAT remap
(the Hub relearns a spoke that moves to a new underlay address, no handshake or
restart). It needs `--privileged` + `--device=/dev/net/tun`.

## 🚀 Usage

```bash
# v1 mandates a private, non-zero PSK per peer link (iron law #5, issue #13).
cp config.example.json config.json
# then set each peers[].psk to 32 random bytes as 64 hex chars, e.g.:
#   openssl rand -hex 32
# Use a DISTINCT key for every link (sharing one across peers is rejected with
# DuplicatePsk). There is no mesh-wide top-level "psk" any more; an old config
# that still carries one is rejected (InvalidPsk). Without a valid per-peer PSK
# the daemon refuses to start (config sanity: InvalidPsk).

# Start the daemon (reads config.json from the working directory)
./zig-out/bin/subnetrad

# Inject a policy dynamically (hot-updated over the UDS, no restart needed)
./subnetra policy add --src 192.168.1.0/24 --dst 192.168.2.0/24 --action forward --target 3
./subnetra policy show

# Runtime status & diagnostics: peers, traffic counters, and drop reasons.
# Exits non-zero when the daemon is not running, so scripts can detect it.
./subnetra status

./subnetra save
```

See [`config.example.json`](config.example.json) for a config example.

### Roles: auto-derive the policy from config (`role`)

Issue #21. Instead of hand-injecting `subnetra policy add` rules, set a `role` and
let the daemon derive the forwarding table at boot. Two roles cover the common
hub-and-spoke deployment; `role` defaults to `"manual"` (no derivation — inject
rules yourself, exactly as before, so existing configs are unchanged).

A home/office **spoke** that exposes its own overlay IP and routes everything
else through the relay needs only:

```json
{
  "role": "spoke",
  "virtual_subnet": "10.0.0.0/24",
  "local_id": 2,
  "local_tun_ip": "10.0.0.2/24",
  "local_routes": ["10.0.0.2/32"],
  "peers": [
    { "id": 1, "endpoint": "203.0.113.1:51820", "allowed_src": "10.0.0.0/24", "psk": "…64 hex…" }
  ]
}
```

This derives `10.0.0.2/32 → LOCAL` and `10.0.0.0/24 → hub(id 1)` automatically —
no `subnetra` calls. A `spoke` also turns on the **built-in NAT keepalive** by
default (`keepalive_secs = 20`, issue #96): it sends one tiny authenticated
datagram to its hub every interval so an idle spoke's NAT pinhole stays open and
the hub keeps a fresh route back — no external pinger. Set `keepalive_secs`
explicitly to tune it, or `0` to disable (hub/manual default to `0`). The matching
**hub** just lists its spokes; each peer's `allowed_src` becomes a forward rule to
that peer:

```json
{
  "role": "hub",
  "virtual_subnet": "10.0.0.0/24",
  "local_id": 1,
  "peers": [
    { "id": 2, "endpoint": "203.0.113.2:51820", "allowed_src": "10.0.0.2/32", "psk": "…64 hex…" },
    { "id": 3, "endpoint": "203.0.113.3:51820", "allowed_src": "10.0.0.3/32", "psk": "…64 hex…" }
  ]
}
```

Validation is strict (`subnetrad --check` enforces it): a `hub` rejects a peer
with a missing or overlapping `allowed_src`; a `spoke` requires exactly one hub
peer, at least one local target, and no `0.0.0.0/0` local route. Ready-to-edit
examples live in [`deploy/`](deploy/). You can still add extra `subnetra policy`
rules on top of a derived table at runtime.

### Host network setup (`--print-network-plan`)

subnetrad creates the TUN device but does **not** configure host addressing,
routes, or MTU itself (auto-apply is intentionally out of scope to preserve the
zero-dependency single-binary guarantee). Instead it can *print* the exact
commands for the loaded config so you can review and run them:

```bash
# Print the host networking plan for this node (defaults to a 1500-byte underlay).
./zig-out/bin/subnetrad --print-network-plan

# Override the underlay path MTU (e.g. behind a PPPoE/VPN underlay):
./zig-out/bin/subnetrad --print-network-plan --path-mtu 1420
```

The plan computes the safe tunnel MTU from the real wire overhead
(`header 20 + AEAD tag 16 + outer IPv4/UDP 28 = 64`, so max tunnel MTU =
`path_mtu − 64`) and **warns** if the configured `local_tun_mtu` exceeds it —
the classic cause of "small packets work, large transfers stall". It emits:

- `ip link set <tun> mtu <local_tun_mtu> up`
- `ip addr add <local_tun_ip> dev <tun>` (set the optional `local_tun_ip` config
  field, e.g. `"local_tun_ip": "10.0.0.2/24"`; otherwise a placeholder is shown)
- `ip route add <subnet> dev <tun>` for each peer's `allowed_src` (a permissive
  `0.0.0.0/0` is skipped so you never blackhole the default route)
- an optional TCP MSS clamp hint (nftables / iptables) to avoid PMTU blackholes

Output is deterministic and print-only; nothing on the host is modified.

### Observability & troubleshooting (`subnetra status`)

The data plane drops malformed, unauthenticated, replayed, spoofed, unrouted,
or oversized packets *silently by design* (stealth). `subnetra status` makes those
silent drops countable so you can tell *why* traffic is not flowing:

```text
subnetrad v0.1.0 [running]
mode=raw_direct local_id=1 udp_port=51820 tun=snr0 peers=2
peers:
  id=2 endpoint=203.0.113.2:51820 allowed_src=10.0.0.2/32
  id=3 endpoint=203.0.113.3:51820 allowed_src=10.0.0.3/32
traffic:
  tun_rx packets=... bytes=...
  udp_tx packets=... bytes=...
  udp_rx packets=... bytes=...
  tun_tx packets=... bytes=...
  relay  packets=... bytes=...
  endpoint_learned=..
  keepalive rx=.. tx=..
drops:
  tun: not_ipv4=.. no_route=.. drop_rule=.. local_loop=.. unknown_target=.. oversized=.. egress_err=.. send_err=..
  udp: unknown_peer=.. auth_or_invalid=.. not_ipv4=.. spoof=.. no_route=.. drop_rule=.. unknown_target=.. no_reflect=.. oversized=.. send_err=..
```

Common signals: a rising `udp: unknown_peer` means datagrams carry a header
`key_id` that matches no configured peer (the sender's mesh id is wrong, or the
traffic is unsolicited); `auth_or_invalid` means the PSK/epoch or wire format
does not match; `spoof` means a peer sent an inner source outside its
`allowed_src`; `no_route` means no policy rule matches the destination. A rising
`endpoint_learned` is benign — it counts authenticated peers seen at a new UDP
endpoint (roaming/NAT remap, issue #34). The `keepalive rx`/`tx` line counts the
built-in spoke→hub NAT keepalive (issue #96): `tx` on the emitting spoke, `rx` on
the receiving hub. PSKs and derived keys are never printed.

For monitoring and automation, `subnetra status --json` emits the same data as a
stable, versioned JSON object — including a derived per-peer `last_seen_age_seconds`
and `online` flag — so health can be scraped without parsing free-form text (and
still never serializes secrets). See [`docs/deployment.md`](docs/deployment.md) §6
for the schema.

### Production deployment (systemd)

For a complete hub + two-spoke production walkthrough — systemd unit (Linux) or
launchd plist (macOS spoke) with the right capabilities/permissions, secrets
handling, host networking, relay policy install, upgrade/rollback, and
firewall/NAT requirements — see [`docs/deployment.md`](docs/deployment.md).
Ready-to-edit artifacts live in [`deploy/`](deploy/) (`subnetrad.service`,
`net.subnetra.subnetrad.plist`, `hub.json`, `spoke-a.json`, `spoke-b.json`). For a
MikroTik Spoke, [`deploy/routeros/`](deploy/routeros/) has scripted
(`.rsc`) container bring-up/teardown — see
[`docs/routeros-container.md`](docs/routeros-container.md).

## 📊 Development status

Currently the framework, the pure-algorithm layer, and the syscall data path
(TUN, the readiness reactor, AF_UNIX control plane, daemon main loop) are
implemented and exercised end-to-end in the dev container, with a native macOS
`utun`/`poll(2)` spoke behind the comptime `src/os/` backend.

| Task | Module | Status |
|---|---|---|
| 1 Build config | `build.zig` | ✅ Done (static musl, ReleaseSmall, dual binaries) |
| 2 Config sanity | `config.zig` | ✅ Done (std.json parse + private per-peer hex PSK + CIDR; boundary fuse) |
| 3 Policy match | `policy.zig` | ✅ Done (CIDR / longest-prefix / RCU) |
| 4 System driver | `os/linux.zig`, `os/darwin.zig` | ✅ Done (comptime OS backend via `os/mod.zig`: Linux `/dev/net/tun` TUNSETIFF, macOS `utun` PF_SYSTEM/SYSPROTO_CONTROL with 4-byte AF framing; both non-blocking L3) |
| 5 Crypto pipeline | `crypto.zig` | ✅ Done (AEAD / per-link keys / session epoch / anti-replay) |
| 6 Core reactor | `reactor.zig`, `peer.zig`, `os/*` | ✅ Done (readiness loop behind `os.Poller` — Linux epoll ET, macOS `poll(2)`, comptime-selected; multi-peer registry with per-link keys + per-restart session epoch; seal/forward, open/anti-replay, source filter, inner-source binding, hub relay) |
| 7 Control-plane UDS | `uds.zig` | ✅ Done (tokenizer + AF_UNIX datagram listener; atomic RCU policy hot-swap, double-buffered) |
| 8 Control tool | `subnetra.zig` | ✅ Done (UDS delivery; `policy add` fire-and-forget, `policy show`/`save` read the daemon's reply; non-zero exit when the daemon is down) |
| 9 Daemon main loop + e2e | `main.zig`, `test/integration/run.sh` | ✅ Done (wires TUN + UDP + UDS + reactor; live multi-point + relay netns end-to-end test) |
| 10 Wire-protocol spec + KAT | `docs/PROTOCOL.md`, `tests/protocol-vectors.json`, `src/protocol_vectors.zig`, `src/protocol_conformance.zig` | ✅ Done (normative v1 spec; known-answer vectors generated from the live code via `zig build vectors`; drift sentinel pins the golden in `zig build test`) |
| 11 Native macOS spoke | `os/darwin.zig`, `netplan.zig`, `docs/macos-spoke-acceptance.md` | ✅ Done (#72: `utun` TunDevice + `poll(2)` reactor + platform `--print-network-plan` ifconfig/route; runbook-certified spoke to a Linux/RouterOS hub; CI/release gate stays Linux-only) |

> **Currently verifiable**: `zig build test` is all green (72 pass + 15
> Linux-only skips on a macOS host, 87 total; all run in the Linux dev
> container); produces a < 512KB static binary. A Linux dev container
> ([`.devcontainer/`](.devcontainer/)) runs an integration/preflight harness
> ([`test/integration/run.sh`](test/integration/run.sh)) that enforces the
> static-link and size constraints across both musl targets **and runs a live
> multi-point + relay end-to-end tunnel test** (3-node hub-and-spoke star across
> network namespaces): real delivery spoke-A → Hub(relay) → spoke-B, on-wire
> encryption, and RCU policy hot-update under load.

See [`docs/subnetra-develop.md`](docs/subnetra-develop.md) for the detailed
architecture, memory model, and acceptance checklist.

## 📄 License

[MIT](LICENSE) © 2026 jettwang

---

> 🔁 A Chinese mirror of this README lives at [`README.zh-CN.md`](README.zh-CN.md).
> **The two must be kept in sync: when you edit one, update the other in the same change.**
