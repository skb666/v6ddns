#!/usr/bin/env bash
#
# v6-ddns: 一条龙部署脚本
#
# 部署内容：
#   /usr/local/bin/v6-ddns              选址 + 更新 AAAA（以 SVCUSER 身份运行）
#   /usr/local/bin/v6-stale-sweep       清理前缀已不可路由的地址（需 root）
#   /usr/local/bin/alidns-dns01         certbot DNS-01 hook
#   /usr/local/lib/v6ddns/*.py          共享库
#   /etc/v6-ddns/env                    阿里云凭据（root:SVCUSER 0640）
#   /etc/systemd/system/v6-*.{service,timer}
#   /etc/nginx/conf.d/DOMAIN.conf       80 跳转 443
#
# 用法：
#   sudo ./v6-ddns-install.sh --domain example.com --token AKID,AKSECRET
#   sudo ./v6-ddns-install.sh --domain example.com --token AK,SK --issue-cert
#
# 选项：
#   --domain NAME      域名（必填）
#   --token AK,SK      阿里云 AccessKeyId,AccessKeySecret（必填，除非已有 /etc/v6-ddns/env）
#   --host LABEL       记录标签，默认 @（即根域）
#   --user NAME        服务运行用户，默认 SUDO_USER 或当前用户
#   --issue-cert       部署后申请证书（需已装 certbot + python3-certbot-nginx）
#   --no-nginx         跳过 nginx 配置
#   --dry-run          只打印将要执行的动作
#
set -euo pipefail

BINDIR=/usr/local/bin
LIBDIR=/usr/local/lib/v6ddns
UNITDIR=/etc/systemd/system
CONFDIR=/etc/v6-ddns
ENVFILE=$CONFDIR/env
NGINXDIR=/etc/nginx/conf.d

DOMAIN=""; TOKEN=""; HOST="@"; SVCUSER=""; ISSUE_CERT=0; DO_NGINX=1; DRY_RUN=0

die()  { printf '错误: %s\n' "$*" >&2; exit 1; }
info() { printf '  %s\n' "$*"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

while [ $# -gt 0 ]; do
  case $1 in
    --domain)      DOMAIN=${2:?--domain 需要参数}; shift 2 ;;
    --token)       TOKEN=${2:?--token 需要参数}; shift 2 ;;
    --host)        HOST=${2:?--host 需要参数}; shift 2 ;;
    --user)        SVCUSER=${2:?--user 需要参数}; shift 2 ;;
    --issue-cert)  ISSUE_CERT=1; shift ;;
    --no-nginx)    DO_NGINX=0; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             die "未知参数: $1" ;;
  esac
done

[ "$(id -u)" = 0 ] || die "请用 sudo 运行"
[ -n "$DOMAIN" ] || die "必须指定 --domain"
SVCUSER=${SVCUSER:-${SUDO_USER:-$(logname 2>/dev/null || echo root)}}
id -u "$SVCUSER" >/dev/null 2>&1 || die "用户 $SVCUSER 不存在"


step "前置检查"
for c in ip python3 systemctl; do
  command -v $c >/dev/null || die "缺少命令: $c"
  info "$c ✓"
done
if [ "$DRY_RUN" = 1 ]; then
  info "DRY-RUN: 不实际写入"
fi

step "凭据 $ENVFILE"
if [ -z "$TOKEN" ]; then
  [ -f "$ENVFILE" ] || die "既没有 --token，也没有已存在的 $ENVFILE"
  info "沿用现有 $ENVFILE"
else
  install -d -m750 -o root -g "$SVCUSER" "$CONFDIR"
  umask 077
  cat > "$ENVFILE" <<EOF
# v6-ddns credentials.  Installed as $ENVFILE, root:$SVCUSER 0640.
# Group-readable so the unprivileged v6-ddns.service (User=$SVCUSER) can read it.
# Token format: <AccessKeyId>,<AccessKeySecret>
V6DDNS_PROVIDER=alidns
V6DDNS_DOMAIN=$DOMAIN
V6DDNS_HOST=$HOST
V6DDNS_TOKEN=$TOKEN
EOF
  chown root:"$SVCUSER" "$ENVFILE"; chmod 640 "$ENVFILE"
  info "已写入 $ENVFILE (root:$SVCUSER 0640)"
fi
umask 022

step "安装程序文件"
install -d -m755 "$LIBDIR" "$BINDIR" "$UNITDIR"
[ "$DO_NGINX" = 1 ] && install -d -m755 "$NGINXDIR"

	install -m644 /dev/stdin "$LIBDIR/alidns.py" <<'__V6DDNS_ALIDNS_PY__'
"""Minimal Alibaba Cloud DNS (alidns) RPC client -- stdlib only.

Shared by v6-ddns, v6-stale-sweep and the certbot DNS-01 hook so the HMAC-SHA1
signing exists in exactly one place.  Credentials come from the KEY=VALUE file
named by ENV_FILE (/etc/v6-ddns/env unless V6DDNS_ENV overrides it).
"""

import base64
import hashlib
import hmac
import json
import os
import pwd
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://dns.aliyuncs.com/"
VERSION = "2015-01-09"

# Per-user state directory, resolved from the calling user rather than from the
# script's own location, so the same files work when installed into
# /usr/local/bin and run by root or by an unprivileged systemd service.
CONFIG_HOME = os.environ.get("V6DDNS_HOME") or pwd.getpwuid(os.getuid()).pw_dir

# Credentials live outside any home directory so that root (the certbot hook)
# and an unprivileged service (User=skb) can both read one file with no identity
# games.  V6DDNS_ENV still overrides the location for unusual setups.
ENV_FILE = os.environ.get("V6DDNS_ENV") or "/etc/v6-ddns/env"
# State stays per-user: v6-dns runs unprivileged and must write it, and nothing
# outside the user's home needs to see it.
STATE_FILE = os.path.join(CONFIG_HOME, ".local", "state", "v6-ddns", "address")


class AlidnsError(Exception):
    def __init__(self, code, message, action=""):
        super().__init__(f"alidns {action} failed: {code}: {message}".strip())
        self.code = code


def load_env(path):
    cfg = {}
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, _, val = line.partition("=")
                cfg[key.strip()] = val.strip().strip("'\"")
    return cfg


def sign(params, secret, method="GET"):
    """AliRPC SignatureVersion 1.0.

    Two encoding passes: each key/value is encoded, then the joined string is
    encoded again -- which is why Alibaba echoes the timestamp as %253A
    (':' -> %3A -> %253A).  Verified against the live API.
    """
    enc = lambda s: urllib.parse.quote(str(s), safe="-._~")
    canonical = "&".join(f"{enc(k)}={enc(v)}" for k, v in sorted(params.items()))
    string_to_sign = f"{method}&%2F&{enc(canonical)}"
    mac = hmac.new((secret + "&").encode(), string_to_sign.encode(), hashlib.sha1).digest()
    return base64.b64encode(mac).decode()


class Client:
    def __init__(self, key_id, secret):
        self.key_id, self.secret = key_id, secret

    @classmethod
    def from_env(cls, cfg_path, key="V6DDNS_TOKEN"):
        raw = load_env(cfg_path).get(key, "")
        key_id, _, secret = raw.partition(",")
        if not key_id or not secret:
            raise AlidnsError("NoCredential", f"{key} must be '<AccessKeyId>,<AccessKeySecret>'")
        return cls(key_id, secret)

    def call(self, action, **extra):
        params = {
            "AccessKeyId": self.key_id,
            "Action": action,
            "Format": "JSON",
            "SignatureMethod": "HMAC-SHA1",
            "SignatureNonce": f"{int(time.time() * 1000)}-{self.key_id[-6:]}",
            "SignatureVersion": "1.0",
            "Timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "Version": VERSION,
            **extra,
        }
        params["Signature"] = sign(params, self.secret)
        req = urllib.request.Request(
            API + "?" + urllib.parse.urlencode(params), headers={"User-Agent": "alidns-py/1"})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = json.loads(resp.read().decode())
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")
            try:
                body = json.loads(detail)
            except json.JSONDecodeError:
                raise AlidnsError(f"HTTP{exc.code}", detail[:300], action)
            raise AlidnsError(body.get("Code", f"HTTP{exc.code}"),
                              body.get("Message", ""), action)
        except urllib.error.URLError as exc:
            raise AlidnsError("NetworkError", str(exc.reason), action)
        # Some AliDNS failures come back as HTTP 200 with an error body.
        if "Code" in body:
            raise AlidnsError(body["Code"], body.get("Message", ""), action)
        return body

    def records(self, name, rtype):
        """All records of rtype at name.  A trailing dot silently matches nothing,
        so the root zone is addressed as "@.domain" (both forms verified live)."""
        reply = self.call("DescribeSubDomainRecords", SubDomain=name, Type=rtype)
        return (reply.get("DomainRecords") or {}).get("Record") or []

    def set_record(self, domain, rr, rtype, value, ttl=600):
        """Create or update.  AliDNS rejects a no-op update with
        DomainRecordDuplicate, so an unchanged value short-circuits here."""
        found = self.records(f"{rr}.{domain}", rtype)
        common = {"RR": rr, "Type": rtype, "Value": value, "TTL": int(ttl)}
        if found:
            if found[0].get("Value") == value:
                return f"unchanged {rr}.{domain} {rtype} id={found[0]['RecordId']}"
            self.call("UpdateDomainRecord", RecordId=found[0]["RecordId"], **common)
            return f"updated {rr}.{domain} {rtype} {found[0].get('Value')} -> {value}"
        created = self.call("AddDomainRecord", DomainName=domain, **common)
        return f"created {rr}.{domain} {rtype} id={created.get('RecordId')}"

    def delete_matching(self, domain, rr, rtype, value=None):
        """Delete records at rr.domain of rtype.  If value is given, only records
        whose value matches are removed; otherwise every record of that type."""
        gone = []
        for rec in self.records(f"{rr}.{domain}", rtype):
            if value is not None and rec.get("Value") != value:
                continue
            self.call("DeleteDomainRecord", RecordId=rec["RecordId"])
            gone.append(rec["RecordId"])
        return gone
__V6DDNS_ALIDNS_PY__
	info "已安装 $LIBDIR/alidns.py (mode 644)"
	install -m644 /dev/stdin "$LIBDIR/ipv6state.py" <<'__V6DDNS_IPV6STATE_PY__'
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
__V6DDNS_IPV6STATE_PY__
	info "已安装 $LIBDIR/ipv6state.py (mode 644)"
	install -m755 /dev/stdin "$BINDIR/v6-ddns" <<'__V6DDNS_V6DDNS__'
#!/usr/bin/env python3
"""Publish this host's stable-privacy IPv6 as a DNS AAAA record.

Detects the uplink's global IPv6 and updates DNS only when the address actually
changed.  stdlib only -- no packages to install, no root needed.

Credentials: /etc/v6-ddns/env  (root:skb 0640)
State:       ~/.local/state/v6-ddns/address

  v6-ddns            update DNS if the address changed
  v6-ddns --dry-run  report what would happen; touches no DNS and no state
  v6-ddns --print    print the detected address and exit
  v6-ddns --force    update even if the address is unchanged
"""

import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.realpath(__file__))), "lib", "v6ddns"))
import alidns
import ipv6state

ENV_FILE = alidns.ENV_FILE
STATE_FILE = alidns.STATE_FILE

DEFAULT_TTL = {"cloudflare": 120, "alidns": 600, "dnspod": 600}
UA = "v6-ddns/1"


def die(msg):
    print(f"v6-ddns: {msg}", file=sys.stderr)
    sys.exit(1)


def log(msg):
    print(f"v6-ddns: {msg}", file=sys.stderr)


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout


def load_config():
    cfg = {}
    try:
        with open(ENV_FILE) as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                cfg[key.strip()] = val.strip().strip("'\"")
    except FileNotFoundError:
        die(f"missing {ENV_FILE}")
    for key in ("V6DDNS_PROVIDER", "V6DDNS_DOMAIN", "V6DDNS_TOKEN"):
        if not cfg.get(key):
            die(f"{key} is not set in {ENV_FILE}")
    if not cfg.get("V6DDNS_HOST"):
        cfg["V6DDNS_HOST"] = "@"
    provider = cfg["V6DDNS_PROVIDER"].lower()
    if provider not in DEFAULT_TTL:
        die(f"unknown provider {provider!r}; use cloudflare, alidns or dnspod")
    cfg["V6DDNS_PROVIDER"] = provider
    cfg.setdefault("V6DDNS_TTL", str(DEFAULT_TTL[provider]))
    return cfg


def uplink(iface):
    """Interface holding the default IPv6 route (or the configured one)."""
    if iface:
        return iface
    for line in run(["ip", "-6", "route", "show", "default"]).splitlines():
        fields = line.split()
        if "dev" in fields:
            return fields[fields.index("dev") + 1]
    die("no default IPv6 route")


def detect(iface):
    """The address to publish.

    Ignores temporary (RFC 4941, rotates) and deprecated addresses, plus any
    address whose prefix the router no longer advertises -- a router reboot on a
    new /64 leaves the old address looking valid for up to valid_lft (~70h here)
    while being completely unroutable, and it would otherwise win the tie-break
    simply by being older.
    """
    addr = ipv6state.publishable(iface)
    if not addr:
        die(f"no usable global IPv6 on {iface}")
    return addr


def fqdn(cfg):
    host = cfg["V6DDNS_HOST"]
    if host in ("@", ""):
        return cfg["V6DDNS_DOMAIN"]
    return f"{host}.{cfg['V6DDNS_DOMAIN']}"


def warn_duplicates(records, name):
    """Only record[0] gets updated; a leftover stale AAAA breaks clients."""
    if len(records) > 1:
        log(f"WARNING: {len(records)} AAAA records exist for {name}; only the first is "
            f"kept in sync -- delete the others or clients will round-robin onto a "
            f"stale address")


def request(url, data=None, headers=None):
    req = urllib.request.Request(url, data=data, headers={"User-Agent": UA, **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        die(f"{url} -> HTTP {exc.code}: {exc.read().decode('utf-8', 'replace')[:600]}")
    except urllib.error.URLError as exc:
        die(f"{url} -> {exc.reason}")
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        die(f"{url} -> non-JSON response: {body[:200]}")


# --- providers ---------------------------------------------------------------


def cloudflare(cfg, addr):
    fq = fqdn(cfg)
    base = "https://api.cloudflare.com/client/v4"
    auth = {"Authorization": f"Bearer {cfg['V6DDNS_TOKEN']}", "Content-Type": "application/json"}

    def api(path, method="GET", payload=None):
        reply = request(base + path, data=json.dumps(payload).encode() if payload else None,
                        headers=auth)
        if not reply.get("success"):
            die(f"cloudflare {path} failed: {reply.get('errors')}")
        return reply["result"]

    zones = api(f"/zones?name={urllib.parse.quote(cfg['V6DDNS_DOMAIN'])}")
    if not zones:
        die(f"cloudflare zone {cfg['V6DDNS_DOMAIN']} not found (check the token)")
    zid = zones[0]["id"]
    existing = api(f"/zones/{zid}/dns_records?type=AAAA&name={urllib.parse.quote(fq)}")
    warn_duplicates(existing, fq)
    record = {"type": "AAAA", "name": fq, "content": addr, "ttl": int(cfg["V6DDNS_TTL"])}
    if existing:
        api(f"/zones/{zid}/dns_records/{existing[0]['id']}", "PUT", record)
        return f"updated AAAA {fq} (id {existing[0]['id']})"
    created = api(f"/zones/{zid}/dns_records", "POST", record)
    return f"created AAAA {fq} (id {created['id']})"


def alidns_provider(cfg, addr):
    name = fqdn(cfg)
    client = alidns.Client.from_env(ENV_FILE)
    found = client.records(f"{cfg['V6DDNS_HOST']}.{cfg['V6DDNS_DOMAIN']}", "AAAA")
    warn_duplicates(found, name)
    outcome = client.set_record(cfg["V6DDNS_DOMAIN"], cfg["V6DDNS_HOST"], "AAAA", addr,
                                cfg["V6DDNS_TTL"])
    return f"AAAA {name} {outcome}"


def dnspod(cfg, addr):
    creds = cfg["V6DDNS_TOKEN"]
    if "," not in creds:
        die("V6DDNS_TOKEN for dnspod must be '<ID>,<Token>'")
    auth = f"login_token={creds}&format=json&lang=en&error_on_empty=no"

    def call(action, extra):
        body = urllib.parse.urlencode(extra).encode()
        reply = request(f"https://dnsapi.cn/{action}?{auth}", data=body,
                        headers={"Content-Type": "application/x-www-form-urlencoded",
                                 "Accept": "application/json"})
        status = reply.get("status", {})
        if str(status.get("code")) != "1":
            die(f"dnspod {action} failed: {status.get('message')}")
        return reply

    where = {"domain": cfg["V6DDNS_DOMAIN"], "sub_domain": cfg["V6DDNS_HOST"]}
    found = call("Record.List", {**where, "record_type": "AAAA"}).get("records") or []
    warn_duplicates(found, fqdn(cfg))
    if found:
        call("Record.Modify", {
            **where,
            "record_id": found[0]["id"],
            "record_type": "AAAA",
            "record_line": found[0]["line"],
            "value": addr,
            "ttl": int(cfg["V6DDNS_TTL"]),
        })
        return f"updated AAAA {fqdn(cfg)} (id {found[0]['id']})"
    call("Record.Create", {**where, "record_type": "AAAA", "record_line": "默认", "value": addr,
                            "ttl": int(cfg["V6DDNS_TTL"])})
    return f"created AAAA {fqdn(cfg)}"


PROVIDERS = {"cloudflare": cloudflare, "alidns": alidns_provider, "dnspod": dnspod}


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--print", dest="show", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--iface", default=os.environ.get("V6DDNS_IFACE", ""))
    args = ap.parse_args()

    iface = uplink(args.iface)
    if args.show:
        print(detect(iface))
        return

    cfg = load_config()
    addr = detect(iface)
    previous = None
    try:
        previous = open(STATE_FILE).read().strip()
    except FileNotFoundError:
        pass

    if previous == addr and not args.force:
        log(f"{addr} unchanged")
        return
    if args.dry_run:
        print(f"would publish {fqdn(cfg)} AAAA {addr}"
              f"{'' if previous is None else f' (was {previous})'} via {cfg['V6DDNS_PROVIDER']}")
        return

    outcome = PROVIDERS[cfg["V6DDNS_PROVIDER"]](cfg, addr)
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(STATE_FILE, "w") as fh:
        fh.write(addr + "\n")
    log(outcome)


if __name__ == "__main__":
    main()
__V6DDNS_V6DDNS__
	info "已安装 $BINDIR/v6-ddns (mode 755)"
	install -m755 /dev/stdin "$BINDIR/alidns-dns01" <<'__V6DDNS_ALIYUN_HOOK__'
#!/usr/bin/env python3
"""certbot DNS-01 hook for Alibaba Cloud DNS.

Used because HTTP-01 cannot work here: b-b.icu is AAAA-only, and Let's Encrypt's
validation nodes time out reaching this China Telecom residential IPv6 from the
outside (26/26 probes from other networks succeed, so the path itself is fine).

  auth     create/update the _acme-challenge TXT record
  cleanup  delete it

certbot invocation (the env file is world-independent, so no V6DDNS_HOME needed):
  --manual-auth-hook    '/usr/local/bin/alidns-dns01 auth'
  --manual-cleanup-hook '/usr/local/bin/alidns-dns01 cleanup'

Reads the domain and credentials from /etc/v6-ddns/env.
"""

import os
import sys

# The env file is in /etc, so root (certbot) and skb (the DDNS service) read the
# same one with no identity games and no per-user path juggling.
sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.realpath(__file__))), "lib", "v6ddns"))
import alidns

ENV_FILE = alidns.ENV_FILE
PREFIX = "_acme-challenge"


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "auth"
    domain = os.environ.get("CERTBOT_DOMAIN")
    validation = os.environ.get("CERTBOT_VALIDATION", "")
    if not domain:
        sys.exit("alidns-dns01: CERTBOT_DOMAIN is not set")

    cfg = alidns.load_env(ENV_FILE)
    zone = cfg["V6DDNS_DOMAIN"]
    client = alidns.Client.from_env(ENV_FILE)

    if mode == "auth":
        if not validation:
            sys.exit("alidns-dns01: CERTBOT_VALIDATION is not set")
        print(client.set_record(zone, PREFIX, "TXT", validation))
    elif mode == "cleanup":
        gone = client.delete_matching(zone, PREFIX, "TXT", validation or None)
        print(f"removed {len(gone)} TXT record(s)" if gone else "nothing to remove")
    else:
        sys.exit(f"alidns-dns01: unknown mode {mode!r} (expected auth or cleanup)")


if __name__ == "__main__":
    try:
        main()
    except alidns.AlidnsError as exc:
        sys.exit(f"alidns-dns01: {exc}")
__V6DDNS_ALIYUN_HOOK__
	info "已安装 $BINDIR/alidns-dns01 (mode 755)"
	install -m755 /dev/stdin "$BINDIR/v6-stale-sweep" <<'__V6DDNS_V6STALE__'
#!/usr/bin/env python3
"""Delete global IPv6 addresses whose prefix the router no longer advertises.

Needs root, since it mutates the address list.  Safe by construction:

  * Never acts when there is no on-link prefix to compare against -- a router
    mid-reboot briefly advertises nothing, and calling every address dead at
    that moment would be exactly backwards.
  * Only considers scope global addresses on the uplink interface.
  * Touches nothing when the current prefix is the only one present, which is
    the normal case, so this is a no-op on virtually every run.

Usage: v6-stale-sweep [interface]   (default: interface owning the default v6 route)
"""

import os
import subprocess
import sys

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.realpath(__file__))), "lib", "v6ddns"))
import ipv6state  # noqa: E402


def log(msg):
    print(f"v6-stale-sweep: {msg}", file=sys.stderr)


def default_iface():
    for line in ipv6state._run(["ip", "-6", "route", "show", "default"]).splitlines():
        fields = line.split()
        if "dev" in fields:
            return fields[fields.index("dev") + 1]
    return None


def main():
    if os.geteuid() != 0:
        sys.exit("v6-stale-sweep: must run as root")
    iface = sys.argv[1] if len(sys.argv) > 1 else default_iface()
    if not iface:
        sys.exit("v6-stale-sweep: no interface given and no default IPv6 route")

    prefixes = ipv6state.onlink_prefixes(iface)
    if not prefixes:
        log(f"{iface}: no on-link prefix advertised right now, leaving addresses alone")
        return

    stale = [a for a in ipv6state.global_addresses(iface) if ipv6state._is_stale(a, prefixes)]
    if not stale:
        log(f"{iface}: clean, advertised {', '.join(sorted(map(str, prefixes)))}")
        return

    for addr in stale:
        spec = f"{addr['local']}/{addr.get('prefixlen', 64)}"
        try:
            subprocess.run(["ip", "-6", "addr", "del", spec, "dev", iface],
                           capture_output=True, text=True, check=True)
            log(f"deleted {spec} (its prefix is no longer advertised)")
        except subprocess.CalledProcessError as exc:
            log(f"could not delete {spec}: {exc.stderr.strip() or exc}")


if __name__ == "__main__":
    main()
__V6DDNS_V6STALE__
	info "已安装 $BINDIR/v6-stale-sweep (mode 755)"
	install -m644 /dev/stdin "$UNITDIR/v6-ddns.service" <<'__V6DDNS_DDNS_SERVICE__'
[Unit]
Description=Publish this host's stable-privacy IPv6 as a DNS AAAA record
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/v6-ddns
# Runs unprivileged.  The script resolves its config from the calling user, so
# User= is what makes ~/.config/v6-ddns/env and ~/.local/state reachable.
User=@USER@
Group=@USER@
NoNewPrivileges=true
PrivateTmp=true
# ProtectHome is deliberately not set: the config and state files live in the
# user's home, so sandboxing it would break the service outright.
__V6DDNS_DDNS_SERVICE__
	sed -i "s|@USER@|$SVCUSER|g" "$UNITDIR/v6-ddns.service"
	info "已安装 $UNITDIR/v6-ddns.service (mode 644)"
	install -m644 /dev/stdin "$UNITDIR/v6-ddns.timer" <<'__V6DDNS_DDNS_TIMER__'
[Unit]
Description=Check for IPv6 address changes every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Unit=v6-ddns.service

[Install]
WantedBy=timers.target
__V6DDNS_DDNS_TIMER__
	info "已安装 $UNITDIR/v6-ddns.timer (mode 644)"
	install -m644 /dev/stdin "$UNITDIR/v6-stale-sweep.service" <<'__V6DDNS_SWEEP_SERVICE__'
[Unit]
Description=Drop global IPv6 addresses whose prefix the router stopped advertising
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
# Needs root: it mutates the kernel address list.
ExecStart=/usr/local/bin/v6-stale-sweep
# A failure here is worth seeing in the journal but must never block v6-ddns.
SuccessExitStatus=0
__V6DDNS_SWEEP_SERVICE__
	info "已安装 $UNITDIR/v6-stale-sweep.service (mode 644)"
	install -m644 /dev/stdin "$UNITDIR/v6-stale-sweep.timer" <<'__V6DDNS_SWEEP_TIMER__'
[Unit]
Description=Check for unrouted IPv6 addresses every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Unit=v6-stale-sweep.service

[Install]
WantedBy=timers.target
__V6DDNS_SWEEP_TIMER__
	info "已安装 $UNITDIR/v6-stale-sweep.timer (mode 644)"
if [ "$DO_NGINX" = 1 ]; then
	install -m644 /dev/stdin "$NGINXDIR/$DOMAIN.conf" <<'__V6DDNS_NGINX_VHOST__'
# @DOMAIN@ -- install as /etc/nginx/conf.d/@DOMAIN@.conf
#
# Deliberately does NOT declare default_server, so it coexists with the Debian
# default site in sites-enabled: requests for @DOMAIN@ match by server_name here,
# anything else keeps falling through to the stock catch-all vhost.
#
# Port 80 only redirects; the certificate is issued via DNS-01, so nothing has
# to stay reachable there for renewal.  Cert paths come from:
#   sudo certbot certonly --manual --preferred-challenges dns ...
# Install order matters -- the certificate must exist before nginx loads this.

server {
	listen 80;
	listen [::]:80;
	server_name @DOMAIN@;

	# The certificate is issued via DNS-01, so nothing here needs to be reachable
	# for renewal -- port 80 is free to redirect unconditionally.  $request_uri
	# carries the query string across; $host keeps the hostname, dropping :80.
	return 301 https://$host$request_uri;
}

server {
	listen 443 ssl;
	listen [::]:443 ssl;
	server_name @DOMAIN@;

	root /var/www/html;
	index index.html index.htm index.nginx-debian.html;

	ssl_certificate     /etc/letsencrypt/live/@DOMAIN@/fullchain.pem;
	ssl_certificate_key /etc/letsencrypt/live/@DOMAIN@/privkey.pem;

	# Session/cipher/protocol settings come from this file -- declaring them here
	# too is a hard "directive is duplicate" error at nginx -t.
	include /etc/letsencrypt/options-ssl-nginx.conf;
	ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

	location / {
		try_files $uri $uri/ =404;
	}
}
__V6DDNS_NGINX_VHOST__
	sed -i "s|@DOMAIN@|$DOMAIN|g" "$NGINXDIR/$DOMAIN.conf"
	info "已安装 nginx vhost (mode 644)"
fi

step "启用 systemd 服务"
systemctl daemon-reload
systemctl enable --now v6-ddns.timer v6-stale-sweep.timer
systemctl list-timers 'v6-*' --no-pager || true
info "证书有效期 $(cat /etc/letsencrypt/live/$DOMAIN/fullchain.pem 2>/dev/null | openssl x509 -enddate -noout 2>/dev/null | cut -d= -f2)"

step "完成"
if [ "$ISSUE_CERT" = 1 ]; then
  step "申请证书 (DNS-01)"
  certbot certonly --manual --preferred-challenges dns \
    --manual-auth-hook    "$BINDIR/alidns-dns01 auth" \
    --manual-cleanup-hook "$BINDIR/alidns-dns01 cleanup" \
    -d "$DOMAIN"
  echo 'renew_hook = systemctl reload nginx' >> "/etc/letsencrypt/renewal/$DOMAIN.conf"
  nginx -t && systemctl reload nginx
fi

step "验证"
"$BINDIR/v6-ddns" --print | sed 's/^/  当前地址: /'
systemctl --no-pager --full status v6-ddns.service 2>/dev/null | head -3 || true
printf '\n剩余手动步骤:\n'
printf '  1. 路由器 ACL: 放行 TCP 80 443（以及你需要的其他端口）\n'
printf '  2. 手机蜂窝网络测试: curl -6 -I https://%s/\n' "$DOMAIN"
printf '  3. 建议: sudo cupsctl --listen-ip-address=127.0.0.1  （631 不该公网可达）\n'
