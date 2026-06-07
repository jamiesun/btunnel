# Upgrade & Release

Subnetra is a single static binary with **no persistent on-disk data-plane state**,
so a node upgrade is mechanically "swap the binary and restart." The real risk is
**wire compatibility** across a mesh, and the procedure below manages it.

## Upgrade & rollback runbook

Because the transport is **fail-closed** — a datagram that fails AEAD
authentication is silently dropped — a mesh that is half-upgraded across a
wire-breaking boundary **silently partitions**: there is no error, only a climbing
`auth_or_invalid` drop counter on both sides.

Safe procedure:

1. **Read the release notes** for any wire-breaking change. If the wire is
   unchanged, nodes interoperate across the upgrade and ordering does not matter.
2. **Stage a canary.** Upgrade one spoke first and watch `subnetra status` on both
   it and the hub — `online` stays true and `auth_or_invalid` stays flat.
3. **Roll forward** the rest. The binary swap is atomic; restart is stateless (a
   fresh session epoch is derived each lifetime).
4. **Rollback** is the reverse binary swap + restart. No state migration is
   involved.

```bash
# Per node
sudo install -m 0755 subnetrad subnetra /usr/local/bin/
subnetrad --check --config /etc/subnetra/config.json
sudo systemctl restart subnetrad     # stateless restart; a new epoch is derived
subnetra status                      # confirm peers online, auth_or_invalid flat
```

> Keep the previous binary around for an instant rollback, and watch
> `auth_or_invalid` as your partition alarm during the rollout.

## Key rotation runbook

PSKs are per link. To rotate one link's key without a flag day, exploit that each
direction/epoch is keyed independently:

1. Generate a new PSK (`openssl rand -hex 32`).
2. Update **both** ends of the link to the new PSK.
3. Restart both daemons (or restart one and accept a brief `auth_or_invalid` blip
   until the other follows). Because there is no shared mesh key, only this one
   link is affected.

Watch `auth_or_invalid` during the change: a transient rise as the two ends cross
over is expected; a *sustained* rise means the two ends disagree on the key.

The full step-by-step is in
[`docs/deployment.md` §6 "Key rotation runbook"](https://github.com/jamiesun/subnetra/blob/main/docs/deployment.md).

## Cutting a release (maintainers)

The release version lives in **exactly one place**: the `.version` field of
[`build.zig.zon`](https://github.com/jamiesun/subnetra/blob/main/build.zig.zon). It
is injected into the daemon banner at build time via the `build_options` module —
**never hard-code a version string in `src/`**.

To publish `vX.Y.Z`:

1. Bump `.version` in `build.zig.zon` to the new `X.Y.Z` (semantic versioning).
2. Commit that bump on `main` via the normal PR flow.
3. Tag the commit `vX.Y.Z` — the tag **must** equal `v` + the `build.zig.zon`
   version. A guard job fails the release if they disagree, so a mismatched tag
   never ships.
4. Pushing the `v*` tag triggers
   [`.github/workflows/release.yml`](https://github.com/jamiesun/subnetra/blob/main/.github/workflows/release.yml),
   which builds the four-arch static binaries, the GHCR multi-arch image, the
   offline `docker load`-able per-arch image tarballs, and the macOS spoke
   binaries, and publishes them all to the GitHub Release with a combined
   `SHA256SUMS.txt`.

Do **not** create a `v*` tag without first bumping `build.zig.zon` to match. The
release process is documented in
[`docs/release.md`](https://github.com/jamiesun/subnetra/blob/main/docs/release.md).

## Verifying downloads

Every release ships a `SHA256SUMS.txt`. Verify any asset before installing or
`docker load`-ing it:

```bash
sha256sum -c SHA256SUMS.txt 2>/dev/null | grep subnetra-<version>-linux-amd64.tar.gz
```
