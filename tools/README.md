# tools/

Out-of-tree **auxiliary utilities** for BTunnel (issue #57). Nothing here is part
of the shipped daemon. The goal is to keep useful helpers — key generation,
offline config validation, packet inspection, environment preflight — *outside*
the single static `btunnel` / `ptctl` binaries so the data plane stays minimal
and the iron laws in [`AGENT.md`](../AGENT.md) are never bent for a convenience
feature.

## Conventions (binding for every tool added here)

1. **Never shipped by default.** A bare `zig build` installs only `btunnel` and
   `ptctl`. Each Zig tool is exposed via its own `zig build tool:<name>` step and
   is **never** `installArtifact`-ed into the default install. Building a tool
   explicitly drops its binary under `zig-out/tools/`. This keeps the
   release artifacts and the ≤512KB static-size budget untouched.
2. **One-way dependency.** Tools MAY `@import("btunnel")` to reuse `config`,
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
checks, so it can never drift from runtime behaviour. Unlike `btunnel --check`,
it has **no dependency on a sane system clock** and never opens a socket, so it
is safe in CI / on a skewed-clock box. Exits non-zero on any failure and never
prints PSK material.

```sh
zig-out/tools/config-lint deploy/hub.json
```

### `wire-decode` (issue #60)
Offline, read-only inspector for a single captured datagram. Reuses the live
protocol + crypto code to parse the header, derive the session key, and
authenticate/decrypt the body, then prints the header fields, an explicit
`auth OK`/`auth FAIL` line, and the inner IPv4 5-tuple.

```sh
zig-out/tools/wire-decode --data <hex> --psk <64hex> --to <local_id> [--from <id>]
```

> **Local diagnostic only.** It requires the link PSK, so it grants no capability
> an operator who already holds the secret lacks. Never paste a production PSK
> into a shared log. Printing `auth FAIL` is fine here because nothing is emitted
> to the network — it is not the daemon's on-wire silent-drop behaviour.

### `doctor` (issue #61)
POSIX-`sh` environment preflight (BusyBox-friendly). Checks `/dev/net/tun`,
`CAP_NET_ADMIN`/root, the `ip` (iproute2) binary, and clock sanity before you
start the daemon. Read-only: it diagnoses and hints, it never changes anything.

```sh
sh tools/doctor.sh
```
