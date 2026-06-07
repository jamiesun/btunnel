# subnetra-spoke-down.rsc — scripted RouterOS Container Spoke teardown (issue #108)
#
# Reverses subnetra-spoke-up.rsc. Removes ONLY the objects that script created,
# all tagged with $tag, in dependency order (container, then route/NAT, then the
# veth + its address). Safe to run if some objects are already gone (each remove
# is guarded by [find], which is a no-op on an empty set).
#
# Usage: edit $tag / $vethName below to match the bring-up, then:
#   /import file-name=subnetra-spoke-down.rsc
#
# By default the veth is KEPT (set $removeVeth true to also remove it), so you
# can redeploy the container without re-creating the link.

:local tag        "subnetra-routeros-spoke"
:local vethName   "subnetra-veth"
:local removeVeth false

:local vethComment    ($tag . "-veth")
:local overlayComment ($tag . "-overlay")
:local snatComment    ($tag . "-self-snat")

:put ("subnetra: tearing down Spoke '" . $tag . "'")

# 1) container -----------------------------------------------------------------
:if ([:len [/container/find comment=$tag]] > 0) do={
  /container/stop [find comment=$tag]
  :delay 2s
  /container/remove [find comment=$tag]
  :put "  - container stopped + removed"
} else={ :put "  = no container, skipping" }

# 2) overlay route + optional self-SNAT ----------------------------------------
/ip/route/remove [find comment=$overlayComment]
/ip/firewall/nat/remove [find comment=$snatComment]
:put "  - overlay route + self-SNAT removed (if present)"

# 3) veth + its address (optional) ---------------------------------------------
:if ($removeVeth) do={
  /ip/address/remove [find comment=$vethComment]
  /interface/veth/remove [find name=$vethName]
  :put ("  - veth " . $vethName . " + address removed")
} else={ :put ("  . veth " . $vethName . " kept (set removeVeth=true to remove)") }

:put "subnetra: teardown done."
