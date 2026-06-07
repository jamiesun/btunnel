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

### `doctor` (issue #61)
POSIX-`sh` environment preflight (BusyBox-friendly). Checks `/dev/net/tun`,
`CAP_NET_ADMIN`/root, the `ip` (iproute2) binary, and clock sanity before you
start the daemon. Read-only: it diagnoses and hints, it never changes anything.

```sh
sh tools/doctor.sh
```
