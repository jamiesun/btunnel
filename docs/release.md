# Release validation & gating

Issue #26. A Subnetra release candidate is **not** certified by `zig build test`
alone. Unit tests are the fast local check; a release must additionally pass the
**full privileged integration harness with the live network-namespace e2e**, and
that e2e must actually **run** — a skip is treated as a failure.

## TL;DR

```bash
# On a Linux host/container that has root, /dev/net/tun, ip, tcpdump, ping, zig:
sudo scripts/release-gate.sh
# exit 0  => release-certifiable (evidence block printed)
# exit !=0 => DO NOT release
```

The same gate runs automatically in CI on every `v*` tag via the `release-gate`
job in [`.github/workflows/release.yml`](../.github/workflows/release.yml); the
GitHub Release and the GHCR image are **blocked** until it passes.

## Fast local check (always available)

```bash
zig build test
```

This stays the lightweight everyday signal and is **not** sufficient for a
release. It runs no privileged e2e.

## Exact host / container requirements

The release gate runs `test/integration/run.sh` with `SUBNETRA_RELEASE_GATE=1`.
In that mode every missing prerequisite is a **hard failure** (not a skip):

| Requirement        | Why                                              | How to provide |
|--------------------|--------------------------------------------------|----------------|
| root / CAP_NET_ADMIN | create netns, veth pairs, TUN devices          | `sudo` |
| `/dev/net/tun`     | the daemon opens a TUN interface                 | `sudo modprobe tun`; container `--device=/dev/net/tun` |
| `ip` (iproute2)    | namespaces, links, addresses, routes             | distro package `iproute2` |
| `tcpdump`          | proves on-wire encryption (no plaintext leak)    | distro package `tcpdump` |
| `ping` (iputils)   | drives end-to-end delivery + RCU hot-update test | distro package `iputils-ping` |
| `zig` 0.16.0       | native + foreign cross-build                     | pinned tarball (see workflows) |

A privileged container is the simplest way to get all of this:

```bash
docker build -t subnetra-dev -f .devcontainer/Dockerfile .
docker run --rm --privileged --device=/dev/net/tun -v "$PWD":/workspace \
    -e SUBNETRA_RELEASE_GATE=1 subnetra-dev test/integration/run.sh
```

## What the gate proves

Run in order; any failure aborts the whole gate:

1. **Native build** (`ReleaseSmall`) — statically linked, `<= 512 KiB`.
2. **Daemon smoke run** — `subnetrad --check` accepts a valid config.
3. **Foreign cross-build** — the other musl arch, also static and within budget
   (build-only; not executed).
4. **Unit tests** — `zig build test` is green.
5. **Live netns relay e2e** — a 3-node hub-and-spoke star across network
   namespaces asserting: spoke-A → Hub(relay) → spoke-B delivery, on-wire
   encryption (plaintext marker absent on the underlay, present on the decrypted
   overlay), and that an RCU policy hot-update does not stall in-flight traffic.
   A second scenario proves a `role`-based config derives the full policy with
   zero runtime `subnetra` injection (issue #21).

## Evidence

On success the harness prints a machine-readable evidence block and, under
GitHub Actions, appends it to the job summary:

```
release_gate=1
git_commit=<short sha>
zig_version=0.16.0
native_target=x86_64-linux-musl
native_size_bytes=<size>
native_static=yes
foreign_target=aarch64-linux-musl
foreign_size_bytes=<size>
foreign_static=yes
size_budget_bytes=524288
unit_tests=pass
netns_e2e=pass
```

`netns_e2e=pass` is mandatory for a release. If it is anything else (including
`skipped`), the gate exits non-zero and the candidate must **not** be shipped.

## Pre-tag checklist

- [ ] `build.zig.zon` `.version` matches the tag you are about to push (the
      release workflow's `guard` job enforces this).
- [ ] `sudo scripts/release-gate.sh` exits 0 on a Linux host meeting the
      requirements above.
- [ ] The evidence block shows `unit_tests=pass` and `netns_e2e=pass`.
- [ ] Native and foreign `*_static=yes` and both sizes `<= 524288`.
- [ ] Push the tag; confirm the `release-gate` job is green before the
      `release` / `image` jobs publish anything.
