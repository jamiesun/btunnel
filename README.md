# BTunnel

**A pure-Zig, zero-dependency Layer-3 UDP tunnel that ships as a single static binary under 512KB.**

**English** · [简体中文](README.zh-CN.md)

> A virtual Layer-3 adaptive networking tool written in **pure Zig** (pinned to the
> 2026 latest standard library `std.posix`).
> Targets general Linux environments (including lightweight containers such as
> BusyBox / RouterOS Container): zero dependencies, zero dynamic allocation,
> strong stealth.

BTunnel builds a virtual subnet on top of a physical leased line, using a
**hub-and-spoke topology** and forwarding raw IP packets through a private UDP
tunnel. It does **not depend on any third-party network framework**:
the TUN device, encryption, anti-replay, and policy engine are all in-house,
producing a single, fully statically linked binary.

## ✨ Features

- **Zero-dependency single binary**: fully static linking against musl-libc; `ldd`
  reports `not a dynamic executable`; size ≤ 512KB.
- **Layered zero dynamic allocation**: the data plane (reactor / crypto) is strictly
  allocation-free, with buffers locked into resident memory at startup.
- **Single-threaded event-driven reactor**: based on Linux epoll edge-triggered
  (`EPOLLET`), lock-free, with no concurrency contention.
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
build.zig            Dual-binary build (btunnel daemon + ptctl control tool), static musl cross-compile
build.zig.zon        Package manifest
config.example.json  Example config (copy to config.json to use)
deploy/              systemd unit + example hub/spoke configs (see docs/deployment.md)
src/
  root.zig     Core library, aggregates all modules
  config.zig   Config parsing + sanity check (MTU range / subnet overlap)
  policy.zig   CIDR parsing + longest-prefix match + lock-free RCU ActiveTree
  crypto.zig   ChaCha20-Poly1305 + monotonic nonce + sliding-window anti-replay
  reactor.zig  Packed private wire header + egress dispatch + epoll reactor
  tun.zig      TUN device system driver
  netplan.zig  --print-network-plan: host TUN address/route/MTU/MSS command emitter
  stats.zig    data-plane counters (rx/tx, per-reason drops) for `ptctl status`
  uds.zig      Control-plane Unix domain socket + command tokenizer
  main.zig     btunnel daemon entry point
  ptctl.zig    ptctl control tool entry point
docs/
  btunnel-develop.md  System requirements & architecture design (PRD & Architecture)
  PROTOCOL.md         Normative wire-protocol spec (v1) — the cross-impl interoperability contract
  deployment.md       Hub + two-spoke production deployment walkthrough (systemd, secrets, upgrade)
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

Artifacts are placed in `zig-out/bin/`: `btunnel` (daemon) and `ptctl` (control tool).

> **ARMv5 note:** ARMv5 has no hardware atomics (no `LDREX`/`STREX`), so the
> standard library's threaded I/O scaffolding references legacy `__sync_*`
> intrinsics that musl does not provide. Because BTunnel is strictly
> single-threaded (iron law #3), [`src/atomic_shim.zig`](src/atomic_shim.zig)
> supplies a provably-correct plain (non-atomic) implementation of those
> builtins. The shim is gated at comptime and only compiled in for pre-ARMv6
> targets — every other architecture is byte-for-byte unaffected.

## 📦 Container images & releases

Tagged releases (`vX.Y.Z`) are produced by
[`.github/workflows/release.yml`](.github/workflows/release.yml) and ship **both**
static binary tarballs **and** a multi-arch container image, each covering four
architectures: `amd64`, `arm64`, `armv7`, and `armv5`.

```bash
# Pull the multi-arch image (Docker selects the right arch automatically)
docker pull ghcr.io/jamiesun/btunnel:latest

# Run the daemon: it needs NET_ADMIN + the TUN device, and a config.json
# mounted into its working directory (/etc/btunnel).
docker run -d --name btunnel \
    --cap-add=NET_ADMIN --device=/dev/net/tun \
    -v "$PWD/config.json":/etc/btunnel/config.json:ro \
    ghcr.io/jamiesun/btunnel:latest
```

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
(`btunnel-image-<version>-<arch>.tar.gz`):

```bash
# Copy the tarball for the target arch to the device, then:
docker load < btunnel-image-v0.1.0-arm64.tar.gz   # -> ghcr.io/jamiesun/btunnel:v0.1.0
docker run -d --name btunnel \
    --cap-add=NET_ADMIN --device=/dev/net/tun \
    -v "$PWD/config.json":/etc/btunnel/config.json:ro \
    ghcr.io/jamiesun/btunnel:v0.1.0
```

Verify any asset against the release's `SHA256SUMS.txt` before loading.

### Cutting a release

The version is single-sourced in [`build.zig.zon`](build.zig.zon) (`.version`)
and injected into the daemon banner at build time. To publish `vX.Y.Z`: bump
`.version` to `X.Y.Z`, merge to `main`, then push a matching `vX.Y.Z` tag. The
release workflow refuses to publish if the tag and `build.zig.zon` disagree.

## 🧪 Local integration testing (dev container)

The syscall-heavy data path (TUN device, epoll reactor, AF_UNIX control socket)
can only run on Linux, so a reproducible Linux container is provided under
[`.devcontainer/`](.devcontainer/). It is a **development/test aid only** — the
shipped artifact is still a single static musl binary with zero third-party
dependencies.

Open the folder in any dev-container-aware editor, or run the preflight harness
headless:

```bash
# Build the Linux toolchain image (Debian-slim + pinned Zig 0.16.0)
docker build -t btunnel-dev -f .devcontainer/Dockerfile .

# Run the integration / preflight harness inside it
docker run --rm --privileged --device=/dev/net/tun \
    -v "$PWD":/workspace btunnel-dev test/integration/run.sh
```

[`test/integration/run.sh`](test/integration/run.sh) builds the binary on the
container's native arch, enforces the static-link and ≤ 512 KB constraints,
smoke-runs the daemon (`btunnel --check`), cross-builds the other musl arch,
runs the unit tests, and then runs the **multi-point + relay end-to-end test**:
a 3-node hub-and-spoke star across network namespaces (one Hub relay + two
Spokes). It asserts end-to-end delivery spoke-A → Hub(relay) → spoke-B, on-wire
encryption (no plaintext marker leaks onto the underlay), and a non-stalling RCU
policy hot-update under load. It needs `--privileged` + `--device=/dev/net/tun`.

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
./zig-out/bin/btunnel

# Inject a policy dynamically (hot-updated over the UDS, no restart needed)
./ptctl policy add --src 192.168.1.0/24 --dst 192.168.2.0/24 --action forward --target 3
./ptctl policy show

# Runtime status & diagnostics: peers, traffic counters, and drop reasons.
# Exits non-zero when the daemon is not running, so scripts can detect it.
./ptctl status

./ptctl save
```

See [`config.example.json`](config.example.json) for a config example.

### Roles: auto-derive the policy from config (`role`)

Issue #21. Instead of hand-injecting `ptctl policy add` rules, set a `role` and
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
no `ptctl` calls. The matching **hub** just lists its spokes; each peer's
`allowed_src` becomes a forward rule to that peer:

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

Validation is strict (`btunnel --check` enforces it): a `hub` rejects a peer
with a missing or overlapping `allowed_src`; a `spoke` requires exactly one hub
peer, at least one local target, and no `0.0.0.0/0` local route. Ready-to-edit
examples live in [`deploy/`](deploy/). You can still add extra `ptctl policy`
rules on top of a derived table at runtime.

### Host network setup (`--print-network-plan`)

btunnel creates the TUN device but does **not** configure host addressing,
routes, or MTU itself (auto-apply is intentionally out of scope to preserve the
zero-dependency single-binary guarantee). Instead it can *print* the exact
commands for the loaded config so you can review and run them:

```bash
# Print the host networking plan for this node (defaults to a 1500-byte underlay).
./zig-out/bin/btunnel --print-network-plan

# Override the underlay path MTU (e.g. behind a PPPoE/VPN underlay):
./zig-out/bin/btunnel --print-network-plan --path-mtu 1420
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

### Observability & troubleshooting (`ptctl status`)

The data plane drops malformed, unauthenticated, replayed, spoofed, unrouted,
or oversized packets *silently by design* (stealth). `ptctl status` makes those
silent drops countable so you can tell *why* traffic is not flowing:

```text
btunnel v0.1.0 [running]
mode=raw_direct local_id=1 udp_port=51820 tun=btun0 peers=2
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
endpoint (roaming/NAT remap, issue #34). PSKs and derived keys are never printed.

### Production deployment (systemd)

For a complete hub + two-spoke production walkthrough — systemd unit with the
right capabilities and sandboxing, secrets handling, host networking, relay
policy install, upgrade/rollback, and firewall/NAT requirements — see
[`docs/deployment.md`](docs/deployment.md). Ready-to-edit artifacts live in
[`deploy/`](deploy/) (`btunnel.service`, `hub.json`, `spoke-a.json`,
`spoke-b.json`).

## 📊 Development status

Currently the framework, the pure-algorithm layer, and the syscall data path
(TUN, epoll reactor, AF_UNIX control plane, daemon main loop) are implemented
and exercised end-to-end in the dev container.

| Task | Module | Status |
|---|---|---|
| 1 Build config | `build.zig` | ✅ Done (static musl, ReleaseSmall, dual binaries) |
| 2 Config sanity | `config.zig` | ✅ Done (std.json parse + private per-peer hex PSK + CIDR; boundary fuse) |
| 3 Policy match | `policy.zig` | ✅ Done (CIDR / longest-prefix / RCU) |
| 4 System driver | `tun.zig` | ✅ Done (TUNSETIFF ioctl, non-blocking L3 fd) |
| 5 Crypto pipeline | `crypto.zig` | ✅ Done (AEAD / per-link keys / session epoch / anti-replay) |
| 6 Core reactor | `reactor.zig`, `peer.zig` | ✅ Done (epoll ET loop; multi-peer registry with per-link keys + per-restart session epoch; seal/forward, open/anti-replay, source filter, inner-source binding, hub relay) |
| 7 Control-plane UDS | `uds.zig` | ✅ Done (tokenizer + AF_UNIX datagram listener; atomic RCU policy hot-swap, double-buffered) |
| 8 Control tool | `ptctl.zig` | ✅ Done (UDS delivery; `policy add` fire-and-forget, `policy show`/`save` read the daemon's reply; non-zero exit when the daemon is down) |
| 9 Daemon main loop + e2e | `main.zig`, `test/integration/run.sh` | ✅ Done (wires TUN + UDP + UDS + reactor; live multi-point + relay netns end-to-end test) |
| 10 Wire-protocol spec + KAT | `docs/PROTOCOL.md`, `tests/protocol-vectors.json`, `src/protocol_vectors.zig`, `src/protocol_conformance.zig` | ✅ Done (normative v1 spec; known-answer vectors generated from the live code via `zig build vectors`; drift sentinel pins the golden in `zig build test`) |

> **Currently verifiable**: `zig build test` is all green (60 pass + 12
> Linux-only skips on a macOS host, 72 total; all run in the Linux dev
> container); produces a < 512KB static binary. A Linux dev container
> ([`.devcontainer/`](.devcontainer/)) runs an integration/preflight harness
> ([`test/integration/run.sh`](test/integration/run.sh)) that enforces the
> static-link and size constraints across both musl targets **and runs a live
> multi-point + relay end-to-end tunnel test** (3-node hub-and-spoke star across
> network namespaces): real delivery spoke-A → Hub(relay) → spoke-B, on-wire
> encryption, and RCU policy hot-update under load.

See [`docs/btunnel-develop.md`](docs/btunnel-develop.md) for the detailed
architecture, memory model, and acceptance checklist.

## 📄 License

[MIT](LICENSE) © 2026 jettwang

---

> 🔁 A Chinese mirror of this README lives at [`README.zh-CN.md`](README.zh-CN.md).
> **The two must be kept in sync: when you edit one, update the other in the same change.**
