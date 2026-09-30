"""Read the host's real IPv6 state and tell stale addresses apart from live ones.

Shared by v6-ddns (so it never publishes a dead address) and v6-stale-sweep
(so the kernel stops preferring one for outbound traffic).

The key fact: an address is only reachable while the router still advertises the
prefix it sits in.  A router reboot that lands on a new /64 stops advertising the
old one but does NOT send a deprecating RA, so the old address stays "valid" in
the kernel until valid_lft expires -- measured at ~70 hours on this line.  A
device can therefore hold a syntactically perfect, completely dead address.
"""

import ipaddress
import json
import subprocess


def _run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout


def onlink_prefixes(iface):
    """Prefixes the router currently advertises as on-link (RA-derived routes).

    Empty when no RA has arrived yet -- callers must treat that as "cannot tell"
    rather than "everything is stale".
    """
    data = json.loads(_run(["ip", "-j", "-6", "route", "show", "dev", iface, "proto", "ra"]))
    nets = set()
    for route in data:
        dst = route.get("dst")
        if not dst or dst == "default":
            continue
        try:
            nets.add(ipaddress.ip_network(dst, strict=False))
        except ValueError:
            continue
    return nets


def global_addresses(iface):
    """Global addresses on iface, with the flags iproute2 reports."""
    data = json.loads(_run(["ip", "-j", "-6", "addr", "show", "dev", iface, "scope", "global"]))
    return [a for link in data for a in link.get("addr_info", []) if a.get("local")]


def _is_stale(addr, prefixes):
    """True when addr's /64 sits in no advertised prefix."""
    net = ipaddress.ip_network(f"{addr['local']}/64", strict=False)
    return not any(net.subnet_of(p) for p in prefixes)


def stale_addresses(iface):
    """Live-looking global addresses the router no longer routes.

    Returns [] when there is no on-link prefix to compare against: a router that
    is merely rebooting briefly advertises nothing, and treating that as "all
    addresses are dead" would be exactly backwards.
    """
    prefixes = onlink_prefixes(iface)
    if not prefixes:
        return []
    return [a for a in global_addresses(iface) if _is_stale(a, prefixes)]


def publishable(iface):
    """The address v6-ddns should publish, or None.

    Prefers the host-derived stable-privacy address (RFC 7217) over the SLAAC
    EUI-64 one (mngtmpaddr) so the record does not leak the MAC, and drops
    temporary (rotates), deprecated, and stale (unrouted) candidates.
    """
    prefixes = onlink_prefixes(iface)
    candidates = [
        a for a in global_addresses(iface)
        if not a.get("temporary") and not a.get("deprecated")
        and (not prefixes or not _is_stale(a, prefixes))
    ]
    if not candidates:
        return None
    candidates.sort(key=lambda a: a.get("mngtmpaddr", False))
    return candidates[0]["local"]
