#!/bin/sh
# doctor — offline environment preflight for subnetra (issue #61).
#
# Checks the host prerequisites the daemon needs BEFORE you start it, so a
# first-run failure on a constrained box (BusyBox / RouterOS container) is a
# plain-language report instead of an opaque startup error. It is read-only: it
# diagnoses and hints, it never changes the system, never opens a socket, and is
# NOT part of the shipped daemon.
#
# POSIX sh, BusyBox-friendly (no bashisms). Exit 0 if every hard check PASSes,
# non-zero if any hard check FAILs. WARNs never fail the run.
#
# Usage: tools/doctor.sh

hard_fail=0

pass() { printf 'PASS  %s\n' "$1"; }
warn() { printf 'WARN  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; hard_fail=1; }

# 1. /dev/net/tun — the daemon opens this to create the virtual L3 device.
if [ -c /dev/net/tun ]; then
    pass "/dev/net/tun present"
else
    fail "/dev/net/tun missing — load the module: modprobe tun (or mknod /dev/net/tun c 10 200)"
fi

# 2. CAP_NET_ADMIN — required to create the TUN device and program routes.
#    Best-effort: prefer an explicit capability probe, fall back to uid 0.
uid="$(id -u 2>/dev/null || echo unknown)"
if [ "$uid" = "0" ]; then
    pass "running as root (CAP_NET_ADMIN available)"
elif command -v capsh >/dev/null 2>&1 && capsh --print 2>/dev/null | grep -q 'cap_net_admin'; then
    pass "CAP_NET_ADMIN present (non-root)"
else
    fail "no CAP_NET_ADMIN — run as root or grant the capability (e.g. setcap cap_net_admin+ep ./subnetrad)"
fi

# 3. iproute2 `ip` — used to bring the interface up and program addresses/routes.
if command -v ip >/dev/null 2>&1; then
    pass "iproute2 'ip' found at $(command -v ip)"
else
    fail "'ip' (iproute2) not found — install iproute2 / busybox ip"
fi

# 4. Clock sanity — the stateless epoch model rejects a node whose wall clock ran
#    backward across a restart (AGENT.md iron law #8; see docs/deployment.md). We
#    cannot verify true sync offline, so this is a WARN, not a hard FAIL.
year="$(date -u +%Y 2>/dev/null || echo 0)"
if [ "$year" -ge 2024 ] 2>/dev/null; then
    synced=""
    if command -v timedatectl >/dev/null 2>&1 && timedatectl show 2>/dev/null | grep -q 'NTPSynchronized=yes'; then
        synced="yes"
    elif [ -e /etc/adjtime ] || command -v chronyc >/dev/null 2>&1 || command -v ntpd >/dev/null 2>&1 || command -v ntpdate >/dev/null 2>&1; then
        synced="likely"
    fi
    if [ -n "$synced" ]; then
        pass "clock looks sane (UTC year $year, time source detected)"
    else
        warn "clock UTC year is $year but no NTP/RTC sync source detected — ensure time is kept (see docs/deployment.md)"
    fi
else
    fail "system clock implausible (UTC year $year) — set the time/NTP before starting subnetrad"
fi

echo
if [ "$hard_fail" -eq 0 ]; then
    echo "doctor: all hard checks PASSED"
else
    echo "doctor: one or more hard checks FAILED"
fi
exit "$hard_fail"
