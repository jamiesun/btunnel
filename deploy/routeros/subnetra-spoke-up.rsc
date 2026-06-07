# subnetra-spoke-up.rsc — scripted RouterOS Container Spoke bring-up (issue #108)
#
# Brings up the RouterOS-side plumbing for a Subnetra Spoke container in one
# reviewable, idempotent step: the veth pair, its addresses, the overlay route
# into the container, the container itself, and (optionally) the narrow
# self-SNAT for RouterOS-originated diagnostics. It then prints the exact
# verification commands. See docs/routeros-container.md for the full model and
# the host-side image-archive build (§2), which this script does NOT do.
#
# Usage (review first, then run on the RouterOS device):
#   1. Edit the parameters in the ":local" block below to match your config.json
#      / `config-gen` output (overlay subnet, the published LAN, the uploaded
#      image archive filename). Defaults mirror docs/routeros-container.md.
#   2. Upload this file and the image archive to the device's storage.
#   3. /import file-name=subnetra-spoke-up.rsc
#
# Idempotent: re-running skips objects that already exist (matched by comment /
# name), so it is safe to run again after a partial setup. Teardown is the
# companion script subnetra-spoke-down.rsc.
#
# This script changes ONLY: one veth + its /30 address, one overlay route, one
# container, and (if enabled) one srcnat rule — all tagged with $tag so they are
# easy to find and remove. It does not touch any existing routing or NAT.

:local tag              "subnetra-routeros-spoke"

# --- veth (RouterOS <-> container link) ---------------------------------------
:local vethName         "subnetra-veth"
# container side (becomes the veth "address")
:local vethContainerCidr "172.30.66.2/30"
# RouterOS side (becomes the veth "gateway")
:local vethRouterGw      "172.30.66.1"
# RouterOS-side address installed on the veth
:local vethRouterCidr    "172.30.66.1/30"
# container side again, used as the overlay route gateway
:local vethContainerIp   "172.30.66.2"

# --- overlay + LAN ------------------------------------------------------------
# $overlaySubnet MUST equal `virtual_subnet` in config.json (config-gen --subnet).
:local overlaySubnet    "10.66.0.0/24"
# $lanCidr: the LAN this Spoke publishes (config.json local_routes); "" = none.
:local lanCidr          ""
# $routerLanAddr: this router's own LAN address, used only when $enableSelfSnat.
:local routerLanAddr    "192.168.88.1"

# --- container ----------------------------------------------------------------
# $imageFile: the uploaded legacy Docker archive (built per docs §2).
:local imageFile        "subnetra-routeros-spoke.legacy.tar.gz"
:local rootDir          "subnetra-routeros-spoke-root"

# --- optional: narrow SNAT for RouterOS self-originated diagnostics -----------
# Off by default. When true, RouterOS pings to overlay IPs are rewritten from the
# veth source to $routerLanAddr so the Hub does not reject them as "spoof".
:local enableSelfSnat   false

# =============================================================================
# Derived tags — do not edit.
:local vethComment    ($tag . "-veth")
:local overlayComment ($tag . "-overlay")
:local snatComment    ($tag . "-self-snat")

:put ("subnetra: bringing up Spoke '" . $tag . "' (overlay " . $overlaySubnet . ")")

# 1) veth ----------------------------------------------------------------------
:if ([:len [/interface/veth/find name=$vethName]] = 0) do={
  /interface/veth/add name=$vethName address=$vethContainerCidr gateway=$vethRouterGw comment=$vethComment
  :put ("  + veth " . $vethName . " (" . $vethContainerCidr . " gw " . $vethRouterGw . ")")
} else={ :put ("  = veth " . $vethName . " exists, skipping") }

# 2) RouterOS-side address on the veth -----------------------------------------
:if ([:len [/ip/address/find comment=$vethComment]] = 0) do={
  /ip/address/add address=$vethRouterCidr interface=$vethName comment=$vethComment
  :put ("  + ip address " . $vethRouterCidr . " on " . $vethName)
} else={ :put "  = veth ip address exists, skipping" }

# 3) overlay route RouterOS -> container ---------------------------------------
:if ([:len [/ip/route/find comment=$overlayComment]] = 0) do={
  /ip/route/add dst-address=$overlaySubnet gateway=$vethContainerIp comment=$overlayComment
  :put ("  + route " . $overlaySubnet . " via " . $vethContainerIp)
} else={ :put "  = overlay route exists, skipping" }

# 4) container -----------------------------------------------------------------
:if ([:len [/container/find comment=$tag]] = 0) do={
  /container/add file=$imageFile interface=$vethName root-dir=$rootDir logging=yes start-on-boot=yes comment=$tag
  :put ("  + container from " . $imageFile . " on " . $vethName)
  :delay 1s
  /container/start [find comment=$tag]
  :put "  > container started"
} else={
  :put "  = container exists; (re)starting"
  /container/start [find comment=$tag]
}

# 5) optional narrow self-SNAT -------------------------------------------------
:if ($enableSelfSnat) do={
  :if ([:len [/ip/firewall/nat/find comment=$snatComment]] = 0) do={
    :local masq [/ip/firewall/nat/find chain=srcnat action=masquerade]
    :if ([:len $masq] > 0) do={
      /ip/firewall/nat/add chain=srcnat src-address=$vethRouterGw dst-address=$overlaySubnet \
        out-interface=$vethName action=src-nat to-addresses=$routerLanAddr comment=$snatComment \
        place-before=[:pick $masq 0]
    } else={
      /ip/firewall/nat/add chain=srcnat src-address=$vethRouterGw dst-address=$overlaySubnet \
        out-interface=$vethName action=src-nat to-addresses=$routerLanAddr comment=$snatComment
    }
    :put ("  + self-SNAT " . $vethRouterGw . " -> " . $routerLanAddr)
  } else={ :put "  = self-SNAT exists, skipping" }
} else={ :put "  . self-SNAT disabled (set enableSelfSnat=true to enable)" }

# 6) verification --------------------------------------------------------------
:put ""
:put "subnetra: bring-up done. Verify:"
:put ("  /container/print detail where comment=\"" . $tag . "\"")
:put ("  /log/print where message~\"subnetra\"")
:put ("  /tool/ping 10.66.0.1 count=5        # overlay reach to the Hub")
:if ([:len $lanCidr] > 0) do={
  :put ("  # Hub peer allowed_src for this Spoke must be " . $lanCidr)
}
:put ("  # Spoke down/cleanup: /import file-name=subnetra-spoke-down.rsc")
