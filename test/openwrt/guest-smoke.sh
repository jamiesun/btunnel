#!/bin/sh
#
# Runs INSIDE a booted OpenWrt (x86-64, under qemu) — driven by test/openwrt/run.sh.
# It is the real-userland half of the OpenWrt deployment test: it exercises
# deploy/openwrt/subnetrad.init under the actual procd + BusyBox, which the
# Ubuntu netns e2e and the qemu-user cross smoke can never touch.
#
# Output contract: prints "SMOKE: PASS/FAIL <what>" lines and a final
# "SMOKE_RESULT=<n>" line (0 == every assertion passed) that the host expect
# driver scrapes. POSIX sh / BusyBox ash only.

HOST_IP=10.0.2.2                       # qemu user-net gateway == the host runner
HTTP_PORT="${HTTP_PORT:-8000}"
BASE="http://${HOST_IP}:${HTTP_PORT}"
fails=0

say()   { echo "SMOKE: $*"; }
check() { if [ "$1" -eq 0 ]; then say "PASS $2"; else say "FAIL $2"; fails=$((fails + 1)); fi; }

cd /tmp 2>/dev/null || { echo "SMOKE_RESULT=99"; exit 99; }

say "fetching artifacts from ${BASE}"
for f in subnetrad subnetra subnetrad.init spoke.json bad.json; do
	if ! uclient-fetch -q -O "/tmp/$f" "${BASE}/$f"; then
		say "FATAL cannot fetch $f"
		echo "SMOKE_RESULT=98"
		exit 98
	fi
done

cp /tmp/subnetrad      /usr/sbin/subnetrad   && chmod 0755 /usr/sbin/subnetrad
cp /tmp/subnetra       /usr/bin/subnetra     && chmod 0755 /usr/bin/subnetra
cp /tmp/subnetrad.init /etc/init.d/subnetrad && chmod 0755 /etc/init.d/subnetrad
mkdir -p /etc/subnetra

# 1. the static musl binary actually executes on OpenWrt's userland.
/usr/sbin/subnetrad --version >/dev/null 2>&1
check $? "subnetrad --version runs on OpenWrt"

# 2. `enable` registers the procd START symlink (START=95 in the init script).
/etc/init.d/subnetrad enable
[ -e /etc/rc.d/S95subnetrad ]
check $? "enable creates /etc/rc.d/S95subnetrad"

# 3. NEGATIVE PATH: a config that fails --check must be refused before any daemon
#    is spawned (the fail-fast gate that keeps procd from respawn-looping garbage).
cp /tmp/bad.json /etc/subnetra/config.json
out=$(/etc/init.d/subnetrad start 2>&1)
echo "$out" | grep -q "failed --check"
check $? "bad config: start refuses via the --check gate"
sleep 1
if /etc/init.d/subnetrad running 2>/dev/null; then
	say "FAIL bad config left a daemon running"
	fails=$((fails + 1))
else
	say "PASS bad config did not start a daemon"
fi
/etc/init.d/subnetrad stop >/dev/null 2>&1

# 4. ensure a WORKING /dev/net/tun. The daemon's open() needs the tun DRIVER
#    actually loaded — a bare device node without the module yields OpenFailed.
#    (This is exactly what bit us under fast KVM: opkg's postinst had not insmod'd
#    the module yet, but a stray mknod made the node "exist".) So gate on
#    /sys/module/tun, load the module explicitly (offline first, then via opkg),
#    and only mknod the node once the driver is present so it is actually backed.
load_tun() {
	[ -d /sys/module/tun ] && return 0
	insmod tun 2>/dev/null;   [ -d /sys/module/tun ] && return 0
	modprobe tun 2>/dev/null; [ -d /sys/module/tun ] && return 0
	ko=$(find /lib/modules -name 'tun.ko*' 2>/dev/null | head -1)
	[ -n "$ko" ] && insmod "$ko" 2>/dev/null
	[ -d /sys/module/tun ]
}
if ! load_tun; then
	say "tun driver absent; installing kmod-tun via opkg"
	opkg update           >/tmp/opkg.log 2>&1 || say "opkg update reported errors"
	opkg install kmod-tun >>/tmp/opkg.log 2>&1 || say "opkg install kmod-tun reported errors"
	load_tun || true
fi
if [ -d /sys/module/tun ]; then
	[ -e /dev/net/tun ] || { mkdir -p /dev/net; mknod /dev/net/tun c 10 200 2>/dev/null; }
fi
if [ -d /sys/module/tun ] && [ -e /dev/net/tun ]; then tun_ok=0; else tun_ok=1; fi
check $tun_ok "/dev/net/tun backed by the loaded tun driver"
if [ "$tun_ok" -ne 0 ]; then
	say "tun diagnostics (opkg tail + modules on disk):"
	tail -15 /tmp/opkg.log 2>/dev/null
	find /lib/modules -name 'tun*' 2>/dev/null
fi

# 5. POSITIVE PATH: a valid config starts and procd supervises a live daemon that
#    opens its own snr0 TUN. Poll for BOTH conditions to absorb fast-KVM vs
#    slow-TCG timing and any procd respawn backoff (it never touches addr/routes).
cp /tmp/spoke.json /etc/subnetra/config.json
/etc/init.d/subnetrad restart >/dev/null 2>&1
running=1; have_snr0=1; i=0
while [ $i -lt 15 ]; do
	if /etc/init.d/subnetrad running 2>/dev/null; then running=0; else running=1; fi
	if ip link show snr0 >/dev/null 2>&1; then have_snr0=0; else have_snr0=1; fi
	[ $running -eq 0 ] && [ $have_snr0 -eq 0 ] && break
	sleep 1; i=$((i + 1))
done
check $running   "good config: procd supervises a running subnetrad"
check $have_snr0 "daemon created the snr0 tun device"

say "recent subnetra log lines:"
logread 2>/dev/null | grep -i subnetra | tail -6
/etc/init.d/subnetrad stop >/dev/null 2>&1

echo "SMOKE_RESULT=${fails}"
