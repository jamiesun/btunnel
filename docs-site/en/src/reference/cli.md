# CLI Reference

Subnetra ships two binaries:

- **`subnetrad`** — the daemon (the data plane + control socket).
- **`subnetra`** — the control tool (talks to a running daemon over the control
  Unix domain socket).

## `subnetrad` (daemon)

```text
subnetrad [--config <path>] [--check] [--print-network-plan] [--path-mtu <n>]
          [--version | -V] [--help | -h]
```

| Flag | Argument | Description |
|---|---|---|
| `--config` | path | Path to `config.json`. Defaults to `config.json` in the working directory; falls back to a compiled-in default if absent. |
| `--check` | — | Parse the config, run every sanity rule, print the resolved banner, and exit **without** touching the network. Use it as a pre-flight (and as systemd's `ExecStartPre`). |
| `--print-network-plan` | — | Print the deterministic host networking plan (`ip`/`ifconfig`/`route` commands) for the loaded config and exit. Nothing on the host is modified. See [Host Network Plan](../configuration/network-plan.md). |
| `--path-mtu` | integer | Override the assumed underlay path MTU when printing the plan (default 1500). The safe tunnel MTU is `path_mtu − 64`. |
| `--version`, `-V` | — | Print the version banner and exit. |
| `--help`, `-h` | — | Print usage and exit. |

With no action flag, `subnetrad` runs the daemon: it creates the TUN device, binds
the UDP underlay and the control socket, and enters the reactor loop. Creating the
TUN device requires `CAP_NET_ADMIN` (Linux) or root (macOS `utun`).

```bash
# Validate, preview the host plan, then run
subnetrad --check --config /etc/subnetra/config.json
subnetrad --print-network-plan --config /etc/subnetra/config.json
sudo subnetrad --config /etc/subnetra/config.json
```

## `subnetra` (control tool)

```text
subnetra status [--json]
subnetra policy show
subnetra policy add --src <CIDR> --dst <CIDR> --action forward --target <id>
subnetra save
subnetra --version | --help
```

| Command | Description |
|---|---|
| `status` | Show daemon health, peers, traffic counters, and per-reason drop counters. Exits **non-zero** if the daemon is not running. |
| `status --json` | Emit the same data as a stable, **versioned** JSON object for monitoring. Never serializes secrets. See [Observability](../operations/observability.md). |
| `policy show` | Print the active policy tree (waits for the daemon's reply). |
| `policy add` | Inject one rule, hot-swapped via RCU with no restart (fire-and-forget). |
| `save` | Snapshot the active policy back to disk (waits for the daemon's reply). |
| `--version` / `--help` | Print version / usage. |

### `policy add` arguments

| Flag | Argument | Description |
|---|---|---|
| `--src` | CIDR | Match on the inner **source** prefix (e.g. `192.168.1.0/24`, or `0.0.0.0/0` for any). |
| `--dst` | CIDR | Match on the inner **destination** prefix (longest-prefix wins). |
| `--action` | `forward` | The action. (v1 routes by forwarding to a target; unrouted traffic is dropped.) |
| `--target` | mesh id | Where to send a match: a peer's mesh **id**, or **`0`** for *local delivery* to this node's own TUN. |

Examples:

```bash
# Site-to-Site: reach LAN 192.168.2.0/24 behind spoke id 3
subnetra policy add --src 192.168.1.0/24 --dst 192.168.2.0/24 --action forward --target 3

# Hub: relay overlay traffic to the right spoke
subnetra policy add --src 0.0.0.0/0 --dst 10.0.0.2/32 --action forward --target 2

# Spoke: deliver tunnelled traffic for the local overlay address to the local TUN
subnetra policy add --src 0.0.0.0/0 --dst 10.0.0.2/32 --action forward --target 0

subnetra policy show
subnetra save
```

> Rules injected at runtime layer on top of any policy derived from a
> [`role`](../configuration/roles.md). Use `subnetra save` to persist the active
> tree so it survives a restart.

## Environment

| Variable | Description |
|---|---|
| `SUBNETRA_SOCK` | Path to the control Unix domain socket. **Defaults to `/run/subnetra/subnetra.sock` (Linux) / `/var/run/subnetra.sock` (macOS)** — the same path the daemon binds and the systemd unit uses, so `subnetra` and `subnetrad` agree out of the box. Set this only to use a non-default path (both processes must match). |

```bash
# Usually unnecessary — the default already matches the daemon. Set it only
# when you run the daemon on a custom socket path:
export SUBNETRA_SOCK=/run/subnetra/subnetra.sock
sudo -E subnetra status
```

## Exit codes

- `subnetra status` returns **non-zero** when the daemon is down — convenient for
  health checks and the Docker `HEALTHCHECK`.
- `subnetrad --check` returns non-zero on an invalid config, so it can gate a
  service start.

## Out-of-tree tools

These helpers live under
[`tools/`](https://github.com/jamiesun/subnetra/tree/main/tools) and are **never**
shipped inside the daemon:

| Build step | Tool | Purpose |
|---|---|---|
| `zig build tool:keygen` | `keygen` | Generate per-link 64-hex PSKs |
| `zig build tool:config-lint` | `config-lint` | Offline `config.json` validation (clock-independent) |
| `zig build tool:wire-decode` | `wire-decode` | Offline, read-only datagram inspector |
| — | `tools/doctor.sh` | Environment preflight: `/dev/net/tun`, `CAP_NET_ADMIN`, `ip`, clock |
