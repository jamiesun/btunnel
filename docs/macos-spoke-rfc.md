# RFC: native macOS spoke (MVP) — design proposal

> **Status: DRAFT / DESIGN-ONLY — NOT APPROVED, NO CODE AUTHORIZED.**
> This document proposes *how* subnetra could run natively on macOS as a **spoke**.
> It ships **no implementation** and changes **no `src/` behaviour**. Two of the
> iron laws in [`AGENT.md`](../AGENT.md) (§3 "Linux epoll reactor" and §6 "fully
> static against musl-libc") are written around Linux primitives and physically
> cannot hold on macOS. Per the project's own governance, **no macOS backend code
> may begin until the maintainer signs off on the iron-law amendments in §2.** The
> authoritative *what* remains [`docs/subnetra-develop.md`](subnetra-develop.md); the
> normative v1 wire contract remains [`docs/PROTOCOL.md`](PROTOCOL.md). Where this
> RFC and either of those disagree, **they win and this RFC is wrong.**

## 1. Purpose and scope

subnetrad today is **Linux-first by construction**, not by accident:

- `src/tun.zig` opens `/dev/net/tun` and issues the `TUNSETIFF` ioctl
  (`tun.zig:13,21,67`) — a Linux-only device model.
- `src/reactor.zig` is an **edge-triggered `epoll`** loop (`reactor.zig:279-285`,
  `EPOLL.IN | EPOLL.ET`); 14 `epoll*` references, 133 `linux.*` calls.
- `src/uds.zig` (143 `linux.*`), `src/main.zig` (28), `src/config.zig`,
  `src/subnetra.zig`, `src/peer.zig` all call `std.os.linux.*` **raw syscalls**
  directly.

**Pain (the real one):** the maintainer's daily-driver OS is macOS. Running
subnetrad only inside Colima/Docker (a Linux VM) means the **Mac host routing table
never enters the tunnel** — there is an extra NAT hop and no native route
injection. That is not equivalent to "my laptop is a spoke on the overlay."

**Collapse point if not done:** subnetra stays a server-to-server tool that the
maintainer cannot natively dogfood from their primary workstation. Adoption as a
*daily* mesh tool stalls.

**Scope of this MVP (deliberately narrow):**

- macOS runs **only as a spoke**, connecting to an **existing Linux/RouterOS
  hub**. No macOS hub, no `launchd`/`systemd` equivalent, no automatic route
  table mutation in the first cut.
- Deliver: `--check`, config parsing, UDP data plane, UDS control plane, a
  `utun` device, and `subnetra status` working on a real Mac, reaching a Linux/
  RouterOS node with `ping`/MTU intact.
- Out of scope: see §9.

**Current runtime status (measured on aarch64 macOS, 2026-06-06):**

```
$ zig build -Dtarget=aarch64-macos      # → Mach-O 64-bit executable arm64 (compiles)
$ ./zig-out/bin/subnetrad --check
thread … panic: index out of bounds: index 65548, len 65536
    src/main.zig:133  return bt.config.Config.fromJson(allocator, buf[0..total]);
```

It **compiles but does not run**: `loadConfig` calls `linux.read` (`main.zig:124`),
which on XNU dispatches a *different* syscall, so the return value is
misinterpreted and `total` overruns the 64 KB config buffer. This single panic is
the canonical symptom of the systemic issue — **the tree speaks the raw Linux
syscall ABI, which is meaningless on macOS** (§3).

## 2. The constraints any macOS port MUST satisfy (and the two that need amending)

The iron laws are restated here as acceptance gates. Five hold unchanged on
macOS; **two are written around Linux primitives and must be made
platform-relative before any code lands.** That amendment is the sign-off gate
(§10, Q1).

Unchanged, must keep passing:

1. **Zero third-party dependencies (iron law #1).** `utun`, `kqueue`/`poll` are
   reached through `std.posix`/`std.c` — no new libraries. Still true on macOS.
2. **Layered zero allocation (iron law #2).** The macOS data path stays
   allocation-free: the readiness array (`pollfd`) and packet buffers are sized
   at startup, never per-packet.
3. **Stateless / handshake-free (iron law #8).** Unchanged — a macOS spoke is
   still a statically configured peer.
4. **PSK + anti-replay (iron law #5).** Crypto/`reactor` ingress is unchanged;
   the platform split is below the crypto layer.
5. **TDD (iron law #7).** Holds, but the acceptance *mechanism* changes (§8):
   macOS cannot use the Linux privileged-netns harness.

**Require a maintainer-approved amendment:**

6. **Iron law #3 — reactor primitive.** Today: *"One thread, Linux `epoll`
   edge-triggered."* macOS has no `epoll`. **Proposed amendment:** *"One thread,
   lock-free, allocation-free readiness loop: `epoll` (edge-triggered) on Linux,
   `poll(2)`/`kqueue` on macOS. The single-thread, no-lock, no-per-packet-alloc
   invariant is the law; the specific syscall is platform-selected."* Rationale in
   §4 — for subnetra's fd model the choice is performance-neutral.
7. **Iron law #6 — binary form.** Today: *"Fully static against musl-libc, `ldd`
   → `not a dynamic executable`, ≤ 512 KB."* macOS **cannot** statically link
   `libSystem` (Apple does not ship a static libc); every Mach-O links
   `libSystem.dylib`. **Proposed amendment:** *"Linux: fully static musl, ≤ 512 KB.
   macOS: minimal-dynamic — links **only** `libSystem` (still zero third-party
   deps), with its own recorded size baseline. The `ldd`-static check is a
   Linux-only gate."*

> A macOS backend that lands **without** these two amendments signed off would
> *silently violate named iron laws*. That is worse than not shipping macOS. The
> amendment is therefore Gate 0 — the same governance posture as the v2 RFC.

## 3. Why this is a backend split, not a `-Dtarget` flag

The 65548-byte panic in §1 is not one bug; it is the visible tip of a tree-wide
pattern. `std.os.linux.read/open/close/ioctl/socket/epoll_*` emit **raw Linux
syscall numbers**. On XNU those numbers map to unrelated calls, so the binary
"runs" but corrupts immediately. The fix has two layers:

- **Portable syscalls** — `read`, `open`, `close`, `socket`, `bind`, `sendto`,
  `recvfrom`, `setsockopt`, `fcntl`, UDS accept/connect — already have per-OS
  wrappers in **`std.posix.*`**. Migrating the tree from `std.os.linux.*` to
  `std.posix.*` makes the config/UDP/UDS/control plane correct on macOS **and is
  a pure improvement on Linux** (idiomatic, identical syscalls). This is broad
  (`reactor`, `uds`, `main`, `peer`, `config`, `subnetra`) but mechanical.
- **Genuinely Linux-only primitives** — `epoll`, `/dev/net/tun` + `TUNSETIFF` —
  have no portable wrapper and become the **platform backend** (§4, §6).

**Mechanism: compile-time backend selection, never a runtime branch.**

```
src/os/linux.zig   ← epoll reactor + /dev/net/tun (today's code, moved behind the iface)
src/os/darwin.zig  ← poll reactor + utun
src/os/mod.zig     ← pub const backend = switch (builtin.os.tag) { .linux => linux, .macos => darwin, ... };
```

The per-packet data path (TUN read → decode → policy → encode → UDP write, and
the reverse) is **shared** and contains **zero `if (darwin)`**. Only `TunDevice`,
the readiness primitive, and the network-plan printer are backend-resolved, at
`comptime`. This is what keeps the platform split from polluting the data plane
(the explicit failure mode the maintainer flagged).

## 4. The fd model: `poll` on macOS, `epoll` stays on Linux

The decisive design fact, verified in `src/reactor.zig`:

- The reactor struct holds **`tun_fd`**, a **single `udp_fd`** (`reactor.zig:222-223`),
  and an optional UDS `control` listener (`:228`).
- **All peers multiplex over that one UDP socket** — ingress demuxes by `key_id`
  in the wire header (`recvfrom(self.udp_fd, …)` `:382`; peer lookup in the
  registry), *not* one socket per peer.
- `epoll` registers exactly those ~3 fds (`:284-285`).

So the reactor watches **~3 file descriptors whether it is a 1-peer spoke or an
N-peer hub.** `epoll`'s headline advantage — `O(ready)` vs `poll`'s `O(n)` at
large fd counts — **never triggers in subnetra**, because `n ≈ 3`.

Consequences:

- **macOS uses `poll(2)` for the MVP, and that is not a "downgrade."** At 3 fds,
  `poll ≈ kqueue ≈ epoll`; there is no measurable difference. `poll` is POSIX,
  single-threaded, and allocation-free (a fixed 3–4 entry `pollfd` array). It
  lets the MVP ship **without writing a `kqueue` backend**.
- **Linux keeps `epoll` — and the reason is *not* "fd scalability."** It is kept
  because (a) it is the named iron law and the documented performance narrative,
  (b) `EPOLLET` + drain-to-`EAGAIN` batching (`reactor.zig:325,382`) is working
  and **CI-certified on the only platform that ships to production** (RouterOS/
  BusyBox), and (c) changing it buys nothing and risks a regression. **We do not
  drag Linux down to a common denominator.**
- **`kqueue` is deferred**, not rejected — it is a later hub/perf milestone, and
  even then it is a refinement, not a requirement, for the spoke.

> Both backends honour one contract: *"readiness event → drain the fd to
> `EAGAIN`."* Linux gets that via `EPOLLET`; macOS `poll` is level-triggered but
> the same drain loop is correct (and safe) under it. The shared data path does
> not change.

## 5. Where the platform boundary sits (data-plane integration)

```
                         ┌───────────────── shared, platform-agnostic ─────────────────┐
TUN read ─▶ decode/auth ─▶ policy match ─▶ encode/seal ─▶ UDP write   (reactor core, unchanged logic)
UDP read ─▶ decode/auth ─▶ policy match ─▶ encode/seal ─▶ TUN write
                         └───────────────────────────────────────────────────────────┘
   ▲ TunDevice.read/write          ▲ readiness.wait()             ▲ network-plan printer
   │                               │                              │
   └── os.backend.TunDevice        └── os.backend.Reactor         └── os.backend.printNetworkPlan
       linux: /dev/net/tun             linux: epoll (ET)              linux: ip route/addr/link
       darwin: utun                    darwin: poll(2)                darwin: ifconfig/route
```

Only the three left-hand seams are backend-resolved (at `comptime`). Crypto,
anti-replay, the policy/RCU tree, the peer registry, framing, and the UDS command
set are shared verbatim.

## 6. macOS TUN: `utun` (vs `/dev/net/tun` + `TUNSETIFF`)

The macOS `TunDevice` backend creates a `utun` interface by `connect`-ing a
`PF_SYSTEM` / `SYSPROTO_CONTROL` socket to the kernel control named
`com.apple.net.utun_control` (no `/dev` node, no `TUNSETIFF`). Two behavioural
deltas the shared code must tolerate (both isolated inside the backend):

- **4-byte address-family prefix.** A `utun` frame is prefixed with a 4-byte
  protocol family (`AF_INET`, big-endian) ahead of the IP packet. Linux `tun`
  with `IFF_NO_PI` has no such prefix. The darwin backend **strips it on read and
  prepends it on write**, so the reactor core still sees a bare L3 IP packet —
  the resident `rx`/`tx` buffers and MTU math are unchanged above the seam.
- **Interface naming.** `utun` names are kernel-assigned (`utunN`); the backend
  reports the resolved name to the control plane and the network-plan printer.

## 7. Host network plan: `--print-network-plan`, per platform

The MVP keeps the project's current **print-only** stance (Linux already prints
`ip …` and does not auto-mutate routes). On macOS the printer emits the
equivalent `ifconfig utunN <inner-ip> <peer-ip> mtu <mtu> up` and `route add -net
<cidr> -interface utunN` recipe for the operator to apply. **No automatic route
table mutation in the MVP** — same posture as Linux, and it sidesteps the macOS
privilege/SIP surface for the first cut.

## 8. Test plan (TDD + the honest acceptance gate)

**Unit (host-runnable, `zig build test`):**

- The `std.posix` migration is verified by the existing unit suite continuing to
  pass on Linux **and** newly passing on macOS (config parse, CIDR, RCU, crypto,
  nonce/anti-replay are all OS-agnostic logic).
- The `os.backend` interface is `comptime`-mockable: a fake `TunDevice` and a fake
  readiness source let the reactor core be driven deterministically on either OS,
  with a failing allocator wired to the data-plane line to assert **zero
  allocation** (same discipline as today).

**The hard constraint — CI cannot fully gate macOS:**

- The Linux acceptance harness (`test/integration/run.sh`) is **privileged
  network namespaces**, which are Linux-only. GitHub macOS runners have **no
  netns** and cannot create a `utun` without elevated privileges/entitlements.
- Therefore macOS acceptance is a **documented manual real-machine runbook**, not
  a CI job, for the MVP: on a real Mac, start subnetrad, confirm a `utun` comes up,
  reach an existing Linux/RouterOS hub, and verify `ping`, path MTU, and
  `subnetra status`. The **release gate stays Linux-only**; the macOS artifact is
  certified by the runbook until a hosted-mac acceptance path exists.

> This is the part the "1–2 weeks to be as solid as Linux" estimate understates:
> the code is ~1 week of work, but you do **not** get the same CI safety net on
> macOS. The plan accepts that explicitly rather than pretending otherwise.

## 9. Rollout / non-goals

**Phased order (each step is its own issue; see the tracking issue):**

1. **Gate 0** — amend iron laws #3 and #6 (§2). *No code before this.*
2. Migrate portable syscalls `std.os.linux.* → std.posix.*` (fixes the §1 panic,
   unlocks config/UDP/UDS on macOS, improves Linux).
3. Introduce the `comptime` OS backend boundary (`src/os/{linux,darwin}.zig`);
   move the existing epoll + `/dev/net/tun` code behind it unchanged.
4. macOS `utun` `TunDevice` backend (§6).
5. macOS `poll(2)` readiness backend; Linux keeps `epoll` (§4).
6. Platform-aware `--print-network-plan` (§7).
7. macOS spoke manual real-machine acceptance runbook (§8).

**Non-goals (MVP):** macOS **hub**; automatic route-table mutation; a `launchd`
unit; `kqueue` (deferred to a later milestone); shipping a macOS binary in the
release assets *until* §2/Q3 is decided; Windows/BSD. The `epoll`/`/dev/net/tun`
Linux paths are **not deleted** — they move behind the backend interface byte-for-byte.

## 10. Decisions required from the maintainer (before any code)

- **Q1 (Gate 0)** — approve the two iron-law amendments in §2 (#3 reactor becomes
  platform-relative; #6 macOS is minimal-dynamic `libSystem`-only with its own
  size baseline)? *Everything else blocks on this.*
- **Q2** — accept **`poll(2)` for the macOS MVP and defer `kqueue`** (§4), or
  require `kqueue` up front?
- **Q3** — macOS **distribution**: ship a macOS build in the GitHub Release assets
  now (needs its own size baseline, and later possibly signing/notarization), or
  keep macOS **source-build-only** until the runbook proves it?
- **Q4** — is **print-only** `--print-network-plan` acceptable for the MVP (no
  auto-route, matching Linux today), or is auto-apply required?
- **Go/No-Go** — approve the macOS **spoke** MVP to proceed *test-first* in the
  §9 order, or revise scope.

Until these are answered and this RFC is approved, no macOS backend code is
written and the iron laws stand as currently worded.
