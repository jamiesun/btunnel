# subnetra spoke — dual-WAN failover for the hub tunnel (RouterOS / MikroTik)
# =============================================================================
# WHY THIS IS A ROUTING-LAYER JOB ("plan A")
#   subnetra opens ONE unconnected UDP socket bound to 0.0.0.0 and sends each
#   datagram to the hub with sendto() (src/main.zig openUdp + src/reactor.zig
#   sendTo). It never pins a WAN — the OS routing table chooses the egress and
#   the source IP per packet. So multi-WAN failover for a spoke is done in the
#   router, not the daemon. The hub's authenticated endpoint learning (issue #34,
#   maybeLearnEndpoint) then re-learns the spoke's new public source after a
#   switch, so the overlay recovers with no daemon restart and no reconfig.
#
# OBSERVED FAILURE ON THIS SITE (office_wifi, 2026-06-07) — READ THIS FIRST
#   The interesting part: the main WAN was NOT down. From the router over the
#   main WAN (bridge_wan, table main):
#       ping 1.1.1.1            -> 0%   loss   (general internet is FINE)
#       ping 135.149.57.15 hub  -> 100% loss   (the hub is unreachable)
#       ping 114.114.114.114    -> 100% loss
#   Meanwhile the appswan WAN reaches the hub fine (the Mac/id=4 rides appswan
#   and pinged the hub at 0% / ~59ms during this outage). So this is a
#   HUB-SPECIFIC blackhole on the main WAN's upstream (lasted 8h), not a generic
#   WAN outage.
#
#   CONSEQUENCE: a generic internet canary (1.1.1.1 / 8.8.8.8 / 114) CANNOT drive
#   this failover — it stays "up" while the hub is unreachable, so it would never
#   trigger. The only reliable signal is the HUB's own reachability over each WAN.
#
# PARAMETERS (values below are this site's real config)
#   HUB_PUBLIC_IP   135.149.57.15      hub public IP = the tunnel destination
#   PRIMARY_WAN     bridge_wan         main WAN (gw 10.201.0.1, table main) <- id=3 today
#   BACKUP_WAN      appswan_vpn        SSTP point-to-point WAN (currently reaches hub)
#   The container spoke (id=3) egresses table `main`; the existing hub /32 route
#   pins it to bridge_wan. The Mac (id=4) rides appswan via bridge_appswan mangle
#   marks and is NOT affected by anything below.
#   NAT note: the catch-all `srcnat action=masquerade` (DefConf, no out-interface)
#   already masquerades any egress, INCLUDING appswan_vpn — so routing id=3 over
#   appswan needs no extra NAT rule.
# =============================================================================


# #############################################################################
# OPTION B  (RECOMMENDED for this site — simple, no-flap, fixes id=3 now)
# Prefer the WAN that actually reaches the hub (appswan), fall back to main.
# appswan_vpn is an interface (SSTP) route: if the tunnel drops, RouterOS marks
# its route inactive automatically and the main-WAN backup engages — no probe,
# no flap. Apply THIS block, or Option A below, not both.
# #############################################################################

# idempotent cleanup
/ip route remove [find comment="subnetra-hub-backup"]
# primary hub route via appswan (currently the only WAN that reaches the hub)
/ip route add dst-address=135.149.57.15/32 gateway=appswan_vpn distance=1 comment="subnetra-hub-backup"
# demote the existing main-WAN hub route to backup
/ip route set [find dst-address=135.149.57.15/32 gateway=bridge_wan] distance=2 comment="subnetra-hub-primary-main"

# REVERT OPTION B (restore main WAN as the hub path):
#   /ip route remove [find comment="subnetra-hub-backup"]
#   /ip route set [find comment="subnetra-hub-primary-main"] distance=1 comment=""


# #############################################################################
# OPTION A  (ADVANCED — keep main WAN primary, auto-failover only when the
# main-WAN path TO THE HUB is down). Needs a HUB-AWARE probe that is pinned to
# the main WAN independently of the data route, so the probe never rides the
# route it switches (that self-reference is what makes naive failover flap).
# Do NOT apply together with Option B.
# #############################################################################
#
# # dedicated probe table; hub /32 in it is ALWAYS via the main WAN
# /routing table add name=wanprobe fib
# /ip route add dst-address=135.149.57.15/32 gateway=bridge_wan routing-table=wanprobe distance=1 comment="subnetra-hub-probe"
# # mark the ROUTER's own pings to the hub into the probe table (output chain only,
# # so the CONTAINER's tunnel traffic in the forward chain is NOT affected):
# /ip firewall mangle add chain=output action=mark-routing dst-address=135.149.57.15 \
#   new-routing-mark=wanprobe passthrough=no comment="subnetra-hub-probe"
# # data-plane backup via appswan (wins only once the primary is demoted):
# /ip route add dst-address=135.149.57.15/32 gateway=appswan_vpn distance=2 comment="subnetra-hub-backup"
# /ip route set [find dst-address=135.149.57.15/32 gateway=bridge_wan routing-table=main] comment="subnetra-hub-primary"
# # netwatch probes the hub; its pings are forced onto bridge_wan via wanprobe,
# # so the probe status reflects main-WAN->hub health and never flaps:
# /tool netwatch add host=135.149.57.15 interval=15s timeout=2s comment="subnetra-wan-failover" \
#   down-script="/ip route set [find comment=\"subnetra-hub-primary\"] distance=10 ; :log warning \"subnetra: main WAN cannot reach hub, failing over to appswan_vpn\"" \
#   up-script="/ip route set [find comment=\"subnetra-hub-primary\"] distance=1 ; :log info \"subnetra: main WAN->hub restored\""
#
# REVERT OPTION A:
#   /tool netwatch remove [find comment="subnetra-wan-failover"]
#   /ip firewall mangle remove [find comment="subnetra-hub-probe"]
#   /ip route remove [find comment="subnetra-hub-backup"]
#   /ip route remove [find comment="subnetra-hub-probe"]
#   /ip route set [find comment="subnetra-hub-primary"] distance=1 comment=""
#   /routing table remove [find name="wanprobe"]


# =============================================================================
# AFTER APPLYING (either option)
#   * The container's public source IP changes to the new WAN; the hub re-learns
#     id=3's endpoint automatically (#34) within one keepalive (~15s). No restart.
#   * The existing `subnetra-hub-keepalive` netwatch (host 10.66.0.1) is the NAT
#     pinhole keepalive — leave it in place; it is separate from failover.
#   * Verify:  /tool netwatch print   (subnetra-hub-keepalive should flip to up)
#     and on the hub:  subnetra status   (id=3 last_seen should go fresh).
#   * `check-gateway=ping` is deliberately NOT used anywhere here — it tests the
#     gateway, not the end-to-end hub path, and would miss this exact failure.
#
# APPLYING VIA roswire (review first; this mutates production routing):
#   roswire --allow-write --profile office_wifi script put subnetra-wan-failover \
#       --source @deploy/routeros-spoke-wan-failover.rsc
#   # then run the stored script once, or paste the Option B block directly.
# =============================================================================
