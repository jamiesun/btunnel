# tools/

Out-of-tree **auxiliary utilities** for Subnetra (issue #57). Nothing here is part
of the shipped daemon. The goal is to keep useful helpers — key generation,
offline config validation, packet inspection, environment preflight — *outside*
the single static `subnetra` / `subnetra` binaries so the data plane stays minimal
and the iron laws in [`AGENT.md`](../AGENT.md) are never bent for a convenience
feature.

## Conventions (binding for every tool added here)

1. **Never shipped by default.** A bare `zig build` installs only `subnetra` and
   `subnetra`. Each Zig tool is exposed via its own `zig build tool:<name>` step and
   is **never** `installArtifact`-ed into the default install. Building a tool
   explicitly drops its binary under `zig-out/tools/`. This keeps the
   release artifacts and the ≤512KB static-size budget untouched.
2. **One-way dependency.** Tools MAY `@import("subnetra")` to reuse `config`,
   `crypto`, `protocol`, etc. The data plane under `src/` MUST NOT import anything
   from `tools/`. Reuse flows tools → core, never core → tools.
3. **Zero third-party dependencies.** Pure Zig standard library, or POSIX `sh`
   for non-Zig helpers. No vendored libraries, same as the daemon.
4. **No daemon behaviour change.** Tools are offline/read-only helpers. They do
   not open the tunnel socket, mutate host state, or alter the protocol.

## Build & test

```sh
zig build tool:keygen        # -> zig-out/tools/keygen
zig build tool:config-lint   # -> zig-out/tools/config-lint
zig build tool:wire-decode   # -> zig-out/tools/wire-decode
zig build tool:key-derive    # -> zig-out/tools/key-derive
zig build tool:config-gen    # -> zig-out/tools/config-gen
zig build tool:crypto-bench  # -> zig-out/tools/crypto-bench
zig build tool:forward-bench # -> zig-out/tools/forward-bench
zig build tool:udp-blast     # -> zig-out/tools/udp-blast
zig build tool:mtu-probe     # -> zig-out/tools/mtu-probe
zig build tools-test         # run the tools' unit tests (separate from `zig build test`)
```

## The tools

### `keygen` (issue #58)
Generate cryptographically-random per-link pre-shared keys, printed as 64-char
lowercase hex — the exact format `config.json`'s `peers[].psk` expects. Draws
from the OS CSPRNG and fails closed if no secure entropy source is available.

```sh
zig-out/tools/keygen              # one key
zig-out/tools/keygen --count 3    # one per peer link
```

### `config-lint` (issue #59)
Validate a `config.json` offline using the daemon's **own** parser and sanity
checks, so it can never drift from runtime behaviour. Unlike `subnetrad --check`,
it has **no dependency on a sane system clock** and never opens a socket, so it
is safe in CI / on a skewed-clock box. Exits non-zero on any failure and never
prints PSK material.

```sh
zig-out/tools/config-lint deploy/hub.json
```

### `wire-decode` (issues #60, #65)
Offline, read-only inspector for captured datagram(s). Reuses the live protocol +
crypto code to parse the header, derive the session key, and authenticate/decrypt
the body, then prints the header fields, an explicit `auth OK`/`auth FAIL` line,
and the inner IPv4 5-tuple.

```sh
# single datagram
zig-out/tools/wire-decode --data <hex> --psk <64hex> --to <local_id> [--from <id>]

# bulk: one hex datagram per line on stdin, key chosen by header key_id
tcpdump ... | extract-hex | \
  zig-out/tools/wire-decode --stream --key 1:2:<64hex> --key 2:1:<64hex>
```

In `--stream` mode each `--key sender:receiver:64hex` (repeatable, max 16) is a
directional link key; a record's key is selected by matching its header `key_id`
against the sender id. Output is one line per record (`auth OK` / `auth FAIL` /
`no key` / `skipped`) plus a final `decoded/auth_failed/no_key/skipped` tally.

> **Local diagnostic only.** It requires the link PSK, so it grants no capability
> an operator who already holds the secret lacks. Never paste a production PSK
> into a shared log. Printing `auth FAIL` is fine here because nothing is emitted
> to the network — it is not the daemon's on-wire silent-drop behaviour.

### `key-derive` (issue #64)
Reproduce the daemon's key schedule offline: from a link PSK plus sender/receiver
ids (and optional epoch) it prints the derived `link_key` and `session_key` using
the live `crypto` code, so the output can never drift from the runtime. Useful for
cross-checking captures and the published protocol vectors.

```sh
zig-out/tools/key-derive --psk <64hex> --from <id> --to <id> [--epoch <ns>]
```

> Requires the PSK; treat the output as secret. Local diagnostic only.

### `config-gen` (issue #63)
Scaffold a starting `config.json` for a hub or a spoke, with cryptographically
random, symmetric per-link PSKs already filled in. Emits placeholder endpoints
that intentionally fail `config-lint` until you replace them, so an unfinished
config can never be mistaken for a deployable one.

```sh
zig-out/tools/config-gen --role hub   --local-id 1 --peer-id 2
zig-out/tools/config-gen --role spoke --local-id 2 --peer-id 1
```

### `crypto-bench` (issue #66)
Micro-benchmark the data-plane crypto primitives (`seal`/`open`,
`deriveLinkKey`/`deriveSessionKey`) using the live code, reporting ops/sec,
throughput, and ns/op. A local performance sanity check — not shipped, not a test
gate. Build with `-Doptimize=ReleaseFast` for representative numbers.

```sh
zig build tool:crypto-bench -Doptimize=ReleaseFast
zig-out/tools/crypto-bench --iters 200000
```

### `forward-bench` (issue #101)
Micro-benchmark the data-plane **forwarding** hot path around the AEAD using the
live `reactor`/`policy`/`peer` primitives, with no network I/O. Times two
pipelines — tx (`ipv4Dst` → `PolicyTree.match` → `findById` → `encodeEgress`) and
rx relay (`parseKeyId` → `findById` → `decodeIngress` → `ipv4Src` →
`allowed_src.contains` → `ipv4Dst` → `match`) — and prints each against the raw
`seal`/`open` floor measured in the same run, so the parse+route+lookup
"forwarding tax" over crypto is visible directly. Complements `crypto-bench`
(the AEAD floor, #66) and the netns throughput baseline (#97). Not shipped, not a
test gate. Build with `-Doptimize=ReleaseFast` for representative numbers.

```sh
zig build tool:forward-bench -Doptimize=ReleaseFast
zig-out/tools/forward-bench --iters 200000
zig-out/tools/forward-bench --size 64 --iters 500000   # small-packet (pps-bound) view
```

### `udp-blast` (issue #97)
Saturating UDP load generator — the traffic source for the netns data-plane
benchmark (`test/integration/bench.sh`). Run inside a spoke's network namespace it
injects fixed-size datagrams into the overlay (`snr0`) as fast as the kernel accepts
them, so the daemon's real tun-read → seal → udp-send path (and, for the relay
variant, the hub's udp-recv → udp-send path) is exercised end to end; the achieved
pps/throughput is then read from each daemon's own `subnetra status` counters. It
reuses the daemon's endpoint parser, opens **its own** plain UDP client socket (never
the tunnel socket), and reports the offered load. Issue #97 explicitly allows a tiny
in-tree blaster; this keeps the CI baseline reproducible without an `iperf3` host
dependency. Not shipped; build `-Doptimize=ReleaseFast` for representative load.

```sh
zig build tool:udp-blast -Doptimize=ReleaseFast
# inside a spoke netns, blast the overlay for 5s (1400B inner = snr0 MTU):
zig-out/tools/udp-blast --dst 10.0.0.3:9 --secs 5
zig-out/tools/udp-blast --dst 10.0.0.1:9 --size 64 --secs 5   # small-packet (pps) view
```

### `mtu-probe` (issue #149)
Measure the **real** underlay path MTU between two nodes, then print the safe
`local_tun_mtu` for that path. Unlike kernel Path MTU Discovery it does **not**
trust ICMP "fragmentation needed" (routinely filtered — a *PMTU black hole*):
it probes actively end to end over plain UDP, binary-searching the largest
datagram that round-trips with the IPv4 Don't-Fragment bit set (an oversized
datagram is dropped, not fragmented, so the missing ACK is the signal). The
recommended MTU is derived from the live `netplan.TUNNEL_OVERHEAD`, so it can
never drift from the protocol. Two roles in one binary; opens its **own** plain
UDP socket (never the tunnel socket) and changes no host state.

```sh
zig build tool:mtu-probe
# on the far node (e.g. the hub, at its public endpoint):
zig-out/tools/mtu-probe --listen 18020
# on the near node — measure the path and read the recommended local_tun_mtu:
zig-out/tools/mtu-probe --probe 203.0.113.9:18020
zig-out/tools/mtu-probe --probe 203.0.113.9:18020 --ceil 9000 --verbose   # jumbo paths
```

### `doctor` (issue #61)
POSIX-`sh` environment preflight (BusyBox-friendly). Checks `/dev/net/tun`,
`CAP_NET_ADMIN`/root, the `ip` (iproute2) binary, and clock sanity before you
start the daemon. Read-only: it diagnoses and hints, it never changes anything.

```sh
sh tools/doctor.sh
```
