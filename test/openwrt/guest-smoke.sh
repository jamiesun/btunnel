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

# 4. ensure /dev/net/tun (offline insmod first; opkg only as a fallback so the
#    test does not hard-depend on the network mirror being reachable).
[ -e /dev/net/tun ] || insmod tun 2>/dev/null
if [ ! -e /dev/net/tun ]; then
	say "kmod-tun not built in; fetching via opkg"
	opkg update >/dev/null 2>&1 && opkg install kmod-tun >/dev/null 2>&1
fi
mkdir -p /dev/net
[ -e /dev/net/tun ] || mknod /dev/net/tun c 10 200 2>/dev/null
[ -e /dev/net/tun ]
check $? "/dev/net/tun available"

# 5. POSITIVE PATH: a valid config starts and procd supervises a live daemon.
cp /tmp/spoke.json /etc/subnetra/config.json
/etc/init.d/subnetrad restart >/dev/null 2>&1
sleep 4
if /etc/init.d/subnetrad running 2>/dev/null; then
	say "PASS good config: procd supervises a running subnetrad"
else
	say "FAIL good config: subnetrad not running under procd"
	fails=$((fails + 1))
fi

# 6. the daemon created its own snr0 tun device (it never touches addresses/routes).
ip link show snr0 >/dev/null 2>&1
check $? "daemon created the snr0 tun device"

say "recent subnetra log lines:"
logread 2>/dev/null | grep -i subnetra | tail -6
/etc/init.d/subnetrad stop >/dev/null 2>&1

echo "SMOKE_RESULT=${fails}"
