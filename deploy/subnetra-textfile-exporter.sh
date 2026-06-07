#!/bin/sh
# subnetra-textfile-exporter.sh — render `subnetra status --json` as Prometheus
# node_exporter *textfile collector* metrics (issue #110).
#
# It is a host-side contrib script: it runs the daemon's read-only status command,
# turns the stable JSON (issue #105) into a .prom file, and writes it atomically
# into node_exporter's textfile-collector directory. There is NO embedded HTTP
# server in the daemon and none here — your existing node_exporter scrapes the
# file. Zero daemon change, zero new binary deps.
#
# Requires: jq, and a subnetra build with `status --json` (>= the #105 release).
#
# Usage (one-shot; drive it from cron or the bundled systemd timer):
#   OUTPUT=/var/lib/node_exporter/textfile_collector/subnetra.prom \
#     deploy/subnetra-textfile-exporter.sh
#
# Environment:
#   OUTPUT        target .prom file (default
#                 /var/lib/node_exporter/textfile_collector/subnetra.prom)
#   SUBNETRA_BIN  subnetra CLI (default: subnetra on PATH)
#   SUBNETRA_SOCK control socket, passed through to the CLI if set
#
# On any failure to read status it still publishes `subnetra_up 0` (so "the
# exporter ran but the daemon is down" is itself alertable) and exits 0.

set -eu

OUTPUT="${OUTPUT:-/var/lib/node_exporter/textfile_collector/subnetra.prom}"
SUBNETRA_BIN="${SUBNETRA_BIN:-subnetra}"

command -v jq >/dev/null 2>&1 || { echo "subnetra-textfile-exporter: jq not found" >&2; exit 1; }

dir="$(dirname "$OUTPUT")"
mkdir -p "$dir"
tmp="$(mktemp "${OUTPUT}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

emit_down() {
  {
    echo "# HELP subnetra_up 1 if the exporter read subnetra status, 0 otherwise."
    echo "# TYPE subnetra_up gauge"
    echo "subnetra_up 0"
  } > "$tmp"
  mv -f "$tmp" "$OUTPUT"
  trap - EXIT
  exit 0
}

# Read status JSON (best-effort); fall through to down on any error/empty/error-object.
json="$("$SUBNETRA_BIN" status --json 2>/dev/null)" || emit_down
[ -n "$json" ] || emit_down
printf '%s' "$json" | jq -e 'has("schema_version")' >/dev/null 2>&1 || emit_down

printf '%s' "$json" | jq -r '
  "# HELP subnetra_up 1 if the exporter read subnetra status, 0 otherwise.",
  "# TYPE subnetra_up gauge",
  "subnetra_up 1",
  "# HELP subnetra_schema_version status --json schema version.",
  "# TYPE subnetra_schema_version gauge",
  "subnetra_schema_version \(.schema_version)",
  "# HELP subnetra_build_info Daemon identity; constant 1, details in labels.",
  "# TYPE subnetra_build_info gauge",
  "subnetra_build_info{version=\"\(.version)\",mode=\"\(.mode)\",tun=\"\(.tun)\",local_id=\"\(.local_id)\",listen_port=\"\(.listen_port)\"} 1",

  "# HELP subnetra_peer_online 1 if the peer was seen within the daemon freshness window.",
  "# TYPE subnetra_peer_online gauge",
  ( .peers[] | "subnetra_peer_online{id=\"\(.id)\",allowed_src=\"\(.allowed_src)\"} \(if .online then 1 else 0 end)" ),

  "# HELP subnetra_peer_last_seen_age_seconds Seconds since the peers last authenticated packet.",
  "# TYPE subnetra_peer_last_seen_age_seconds gauge",
  ( .peers[] | select(.last_seen_age_seconds != null) | "subnetra_peer_last_seen_age_seconds{id=\"\(.id)\",allowed_src=\"\(.allowed_src)\"} \(.last_seen_age_seconds)" ),

  # Every counter from stats.Counters, drift-proof: new counters appear automatically.
  ( .counters | to_entries[] | "# TYPE subnetra_\(.key)_total counter\nsubnetra_\(.key)_total \(.value)" )
' > "$tmp"

mv -f "$tmp" "$OUTPUT"
trap - EXIT
